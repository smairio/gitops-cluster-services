# Barman Cloud Plugin Storage Configuration

This document explains the Barman Cloud Plugin configuration, common issues we encountered, and the solutions implemented.

## Table of Contents

- [What is Barman Cloud Plugin?](#what-is-barman-cloud-plugin)
- [Our Configuration](#our-configuration)
- [Issues Encountered and Solutions](#issues-encountered-and-solutions)
- [Best Practices for v0.10+](#best-practices-for-v010)
- [S3 Bucket Structure](#s3-bucket-structure)
- [ExternalSecrets Integration](#externalsecrets-integration)

---

## What is Barman Cloud Plugin?

The Barman Cloud Plugin is a CNPG-I (CloudNativePG Interface) plugin that provides:

1. **WAL Archiving**: Continuous archiving of Write-Ahead Log files to S3
2. **Base Backups**: Full database backups stored in S3
3. **Point-in-Time Recovery (PITR)**: Restore to any point in time using base backup + WAL files
4. **Disaster Recovery**: Full cluster restoration from S3 backups

### Plugin Version

We are using **Barman Cloud Plugin v0.10.0**:

```bash
kubectl get pods -n cnpg-system -o jsonpath='{.items[*].spec.containers[*].image}' | grep barman
# Output: ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.10.0
```

---

## Our Configuration

### ObjectStore Definition (`base/objectstore.yaml`)

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: hetzner-s3-store
  namespace: postgres
spec:
  configuration:
    # S3 bucket path
    destinationPath: s3://awx-postgres-backups/clusters/postgres-cluster
    
    # Hetzner S3 endpoint
    endpointURL: https://fsn1.your-objectstorage.com
    
    # S3 credentials from Kubernetes secret
    s3Credentials:
      accessKeyId:
        name: hetzner-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: hetzner-s3-credentials
        key: ACCESS_SECRET_KEY
    
    # WAL compression
    wal:
      compression: gzip
      maxParallel: 2
    
    # Backup compression
    data:
      compression: gzip
      immediateCheckpoint: false

  # Sidecar container configuration
  instanceSidecarConfiguration:
    retentionPolicyIntervalSeconds: 1800
    logLevel: info
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "500m"
```

### Cluster Plugin Configuration (`base/cluster.yaml`)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
spec:
  # ... other configuration ...
  
  # Barman Cloud Plugin for WAL archiving
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true  # CRITICAL: Required for v0.10+
      parameters:
        barmanObjectName: hetzner-s3-store
```

---

## Issues Encountered and Solutions

### Issue 1: WAL Files Not Being Archived

**Symptom**: 
- Backups created but no WAL files in S3
- Recovery failed with "could not locate required checkpoint record"

**Root Cause**: 
Missing `isWALArchiver: true` in the plugin configuration.

**Solution**:
```yaml
# BEFORE (broken):
plugins:
  - name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: hetzner-s3-store

# AFTER (working):
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true  # <-- This was missing!
    parameters:
      barmanObjectName: hetzner-s3-store
```

### Issue 2: Recovery Failed - "Expected empty archive"

**Symptom**:
```
Error while restoring: unexpected failure invoking barman-cloud-wal-archive: exit status 1
```

**Root Cause**:
When recovering, the new cluster tried to archive WAL files to the **same location** as the backup source. The archive already had WAL files, causing a conflict.

**Solution**:
Use a **different serverName** for the recovered cluster:

```yaml
# Recovery overlay configuration
patches:
  - target:
      kind: Cluster
      name: postgres-cluster
    patch: |-
      # Source for recovery (READ from postgres-cluster)
      - op: add
        path: /spec/externalClusters
        value:
          - name: postgres-cluster-backup
            plugin:
              name: barman-cloud.cloudnative-pg.io
              parameters:
                barmanObjectName: hetzner-s3-store
                serverName: postgres-cluster  # READ from here
      
      # Plugin config (WRITE to postgres-cluster-recovered)
      - op: replace
        path: /spec/plugins
        value:
          - name: barman-cloud.cloudnative-pg.io
            isWALArchiver: true
            parameters:
              barmanObjectName: hetzner-s3-store
              serverName: postgres-cluster-recovered  # WRITE here (different!)
```

**S3 Structure After Recovery**:
```
s3://awx-postgres-backups/clusters/postgres-cluster/
├── postgres-cluster/           # Original cluster archives (READ)
│   ├── base/
│   │   └── 20260130T083428/
│   └── wals/
│       └── 0000000100000000/
│           ├── 000...01.gz
│           └── ...
└── postgres-cluster-recovered/ # Recovered cluster archives (WRITE)
    └── wals/
        └── 0000000100000000/
            ├── 000...01.gz
            └── ...
```

### Issue 3: Backup Incomplete - Missing WAL Files

**Symptom**:
- Backup.info shows `end_wal=000000010000000000000009`
- But only WAL files up to `000...08` exist in S3
- Recovery fails with "WAL not found"

**Root Cause**:
Deleted the cluster before WAL archiving completed. The backup requires WAL files that were never archived.

**Why This Happened**:
1. Created backup at time T
2. Backup recorded `end_wal=09` in backup.info
3. WAL 09 was in progress but not yet archived to S3
4. Deleted the cluster immediately
5. WAL 09 was lost forever
6. Backup became orphaned and unrestorable

**Solution**:
1. **Wait for WAL archiving** before deleting cluster
2. **Never delete WAL files** from S3
3. After creating backup, verify WAL files exist:

```bash
# Check backup requirements
aws s3 cp s3://awx-postgres-backups/.../backup.info - | grep end_wal
# end_wal=00000001000000000000000D

# Verify WAL file exists
aws s3 ls s3://awx-postgres-backups/.../wals/0000000100000000/ | grep 00D
# Should show: 00000001000000000000000D.gz
```

### Issue 4: Wrong S3 Credentials

**Symptom**:
```
Error: Unable to locate credentials
```

**Root Cause**:
ExternalSecret was looking for wrong keys in Vault.

**Solution**:
Ensure Vault keys match ExternalSecret configuration:

```yaml
# ExternalSecret expects:
data:
  - secretKey: ACCESS_KEY_ID
    remoteRef:
      key: khalil/argocd/hetzner-s3
      property: ACCESS_KEY_ID  # Must match Vault key exactly
  - secretKey: ACCESS_SECRET_KEY
    remoteRef:
      key: khalil/argocd/hetzner-s3
      property: ACCESS_SECRET_KEY  # Must match Vault key exactly
```

---

## Best Practices for v0.10+

### 1. Always Set `isWALArchiver: true`

```yaml
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true  # Required!
    parameters:
      barmanObjectName: hetzner-s3-store
```

### 2. Use Different ServerName for Recovery

```yaml
# For recovery, use:
externalClusters:
  - name: source-backup
    plugin:
      parameters:
        serverName: postgres-cluster  # Source (read)

plugins:
  - name: barman-cloud.cloudnative-pg.io
    parameters:
      serverName: postgres-cluster-recovered  # Target (write)
```

### 3. Verify Backup Completeness

After creating a backup:

```bash
# 1. Check backup status
kubectl get backup -n postgres

# 2. Get backup WAL requirement
kubectl run s3-check --rm -it --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=..." --env="AWS_SECRET_ACCESS_KEY=..." \
  -- s3 cp s3://awx-postgres-backups/.../backup.info - \
  --endpoint-url=https://fsn1.your-objectstorage.com | grep end_wal

# 3. Verify that WAL file exists
kubectl run s3-list --rm -it --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=..." --env="AWS_SECRET_ACCESS_KEY=..." \
  -- s3 ls s3://awx-postgres-backups/.../wals/ --recursive \
  --endpoint-url=https://fsn1.your-objectstorage.com
```

### 4. Resource Allocation for Sidecar

For production, increase sidecar resources:

```yaml
instanceSidecarConfiguration:
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"  # Prevent OOM during large WAL operations
      cpu: "500m"
```

### 5. Never Delete WAL Files Manually

WAL files are **critical** for backup consistency. Deleting them makes all backups that depend on them unrestorable.

---

## S3 Bucket Structure

```
s3://awx-postgres-backups/
└── clusters/
    └── postgres-cluster/
        └── postgres-cluster/          # serverName folder
            ├── base/                   # Base backups
            │   └── 20260130T083428/    # Timestamp folder
            │       ├── backup.info    # Backup metadata
            │       └── data.tar.gz    # Compressed data
            └── wals/                   # WAL archives
                └── 0000000100000000/   # Timeline folder
                    ├── 000000010000000000000001.gz
                    ├── 000000010000000000000002.gz
                    ├── 000000010000000000000003.gz
                    └── ...
```

### Backup.info Contents

```
backup_name=backup-20260130083422
begin_wal=00000001000000000000000D
end_wal=00000001000000000000000D
begin_time=2026-01-30 08:34:28.903398+00:00
end_time=2026-01-30 08:34:51.080094+00:00
status=DONE
```

---

## ExternalSecrets Integration

### S3 Credentials from Vault

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hetzner-s3-credentials
  namespace: postgres
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: hetzner-s3-credentials
    creationPolicy: Owner
  data:
    - secretKey: ACCESS_KEY_ID
      remoteRef:
        key: khalil/argocd/hetzner-s3
        property: ACCESS_KEY_ID
    - secretKey: ACCESS_SECRET_KEY
      remoteRef:
        key: khalil/argocd/hetzner-s3
        property: ACCESS_SECRET_KEY
```

### Vault Secret Structure

```bash
vault kv put khalil/argocd/hetzner-s3 \
  ACCESS_KEY_ID="MVTY059W806YTCS2R0DB" \
  ACCESS_SECRET_KEY="8fWj6s8AKJ0gZC4p5UGuowbtbCfiUqoYilqmJ5ck"
```

---

## Summary of Changes Made

| Issue | What Was Wrong | What We Changed |
|-------|----------------|-----------------|
| No WAL archiving | Missing `isWALArchiver` | Added `isWALArchiver: true` to plugins |
| Recovery WAL conflict | Same serverName for source and target | Different `serverName` in recovery overlay |
| Sidecar OOM | Low memory limits | Increased to 512Mi/500m |
| S3 access denied | Wrong bucket name | Fixed to `awx-postgres-backups` |
| Credentials error | Mismatched Vault keys | Aligned ExternalSecret with Vault keys |
| Incomplete backup | Deleted cluster too fast | Now verify WAL completeness before deletion |

---

## Files Modified

1. **`base/cluster.yaml`**: Added `isWALArchiver: true`
2. **`base/objectstore.yaml`**: Increased sidecar resources
3. **`overlays/recovery/kustomization.yaml`**: Added different `serverName` for recovered cluster
4. **`base/externalsecret-s3.yaml`**: Aligned with Vault key names
