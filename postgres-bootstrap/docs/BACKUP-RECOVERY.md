# PostgreSQL Backup and Recovery Guide

This document explains the backup and disaster recovery process for the CloudNativePG cluster using the Barman Cloud Plugin v0.10.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Backup Process](#backup-process)
- [Recovery Process](#recovery-process)
- [Configuration Files](#configuration-files)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Kubernetes Cluster                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────────┐     ┌──────────────────────┐                      │
│  │  postgres-cluster-1  │     │  Barman Cloud Plugin │                      │
│  │  ┌────────────────┐  │     │  (Sidecar Container) │                      │
│  │  │   PostgreSQL   │  │     │                      │                      │
│  │  │    Primary     │◄─┼─────┤  - WAL Archiving     │                      │
│  │  └────────────────┘  │     │  - Base Backups      │                      │
│  └──────────────────────┘     │  - Recovery          │                      │
│                               └──────────┬───────────┘                      │
│                                          │                                   │
└──────────────────────────────────────────┼───────────────────────────────────┘
                                           │
                                           ▼
                              ┌────────────────────────┐
                              │   Hetzner S3 Storage   │
                              │                        │
                              │  s3://awx-postgres-    │
                              │  backups/clusters/     │
                              │  postgres-cluster/     │
                              │                        │
                              │  ├── base/             │
                              │  │   └── 20260130T.../│
                              │  │       ├── backup.info
                              │  │       └── data.tar.gz
                              │  └── wals/             │
                              │      └── 000000010.../│
                              │          ├── 000...01.gz
                              │          ├── 000...02.gz
                              │          └── ...       │
                              └────────────────────────┘
```

---

## Backup Process

### 1. On-Demand Backup

Create a backup using the plugin method:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-backup-20260130-100519
  namespace: postgres
spec:
  cluster:
    name: postgres-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

Apply with:
```bash
kubectl apply -f backup.yaml
```

Or use a one-liner:
```bash
BACKUP_NAME="postgres-backup-$(date +%Y%m%d-%H%M%S)"
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BACKUP_NAME
  namespace: postgres
spec:
  cluster:
    name: postgres-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
```

### 2. Check Backup Status

```bash
kubectl get backup -n postgres
```

Expected output:
```
NAME                              AGE   CLUSTER            METHOD   PHASE       ERROR
postgres-backup-20260130-100519   77s   postgres-cluster   plugin   completed
```

### 3. Verify Backup in S3

```bash
# List base backups
aws s3 ls s3://awx-postgres-backups/clusters/postgres-cluster/postgres-cluster/base/ \
  --endpoint-url=https://fsn1.your-objectstorage.com

# List WAL files
aws s3 ls s3://awx-postgres-backups/clusters/postgres-cluster/postgres-cluster/wals/ \
  --recursive --endpoint-url=https://fsn1.your-objectstorage.com
```

### 4. Scheduled Backups

Add to your Cluster spec:

```yaml
spec:
  backup:
    barmanObjectStore:
      # ... configuration
    retentionPolicy: "7d"
```

---

## Recovery Process

### Automatic S3 Cleanup

The recovery overlay includes an **ArgoCD PreSync hook** that automatically cleans up S3 before each recovery attempt. This prevents the "WAL archive conflict" error.

The cleanup job (`pre-recovery-cleanup.yaml`) runs before the Cluster is created and removes any leftover files from previous recovery attempts.

### Step 1: Update Configuration to Recovery Mode

Edit `postgres-bootstrap/app.yaml`:

```yaml
# Change from:
spec:
  source:
    path: postgres-bootstrap/overlays/init

# To:
spec:
  source:
    path: postgres-bootstrap/overlays/recovery
```

### Step 2: Commit and Push

```bash
git add -A
git commit -m "switch to recovery mode"
git push
```

### Step 3: Delete Existing Resources (Disaster Simulation)

```bash
# Delete all ArgoCD applications
kubectl delete applications -n argocd --all --force --grace-period=0

# Delete namespaces
kubectl delete namespace awx postgres --force --grace-period=0
```

### Step 4: Re-apply Root Application

```bash
kubectl apply -f root.yaml
```

### Step 5: Monitor Recovery

```bash
# Watch postgres recovery
kubectl get cluster,pods -n postgres -w

# Check recovery job logs
kubectl logs -n postgres -l job-name -c full-recovery
```

### Step 6: After Recovery - Switch Back to Init Mode

**IMPORTANT**: After successful recovery, switch back to init overlay:

```yaml
spec:
  source:
    path: postgres-bootstrap/overlays/init
```

This prevents re-running recovery on an already running cluster.

---

## Configuration Files

### Init Overlay (`overlays/init/kustomization.yaml`)

Used for creating a **new** PostgreSQL cluster:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: postgres

resources:
  - ../../base

patches:
  - target:
      kind: Cluster
      name: postgres-cluster
    patch: |-
      - op: add
        path: /spec/bootstrap
        value:
          initdb:
            database: awx
            owner: awx
            secret:
              name: postgres-awx-owner
            postInitSQL:
              - CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

### Recovery Overlay (`overlays/recovery/kustomization.yaml`)

Used for **restoring** from S3 backup:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: postgres

resources:
  - ../../base

patches:
  - target:
      kind: Cluster
      name: postgres-cluster
    patch: |-
      # Bootstrap from backup
      - op: add
        path: /spec/bootstrap
        value:
          recovery:
            source: postgres-cluster-backup
            recoveryTarget: {}
      
      # Define external cluster (backup source)
      - op: add
        path: /spec/externalClusters
        value:
          - name: postgres-cluster-backup
            plugin:
              name: barman-cloud.cloudnative-pg.io
              parameters:
                barmanObjectName: hetzner-s3-store
                serverName: postgres-cluster
      
      # Use different serverName for recovered cluster's archives
      - op: replace
        path: /spec/plugins
        value:
          - name: barman-cloud.cloudnative-pg.io
            isWALArchiver: true
            parameters:
              barmanObjectName: hetzner-s3-store
              serverName: postgres-cluster-recovered
```

### Base Cluster Configuration (`base/cluster.yaml`)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: postgres
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.2
  
  # Enable Barman Cloud Plugin for WAL archiving
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true  # REQUIRED for v0.10+
      parameters:
        barmanObjectName: hetzner-s3-store
  
  # Managed roles - password synced from Vault
  managed:
    roles:
      - name: awx
        ensure: present
        login: true
        passwordSecret:
          name: postgres-awx-owner
  
  storage:
    size: 10Gi
    storageClass: hcloud-volumes
  
  walStorage:
    size: 2Gi
    storageClass: hcloud-volumes
```

---

## Troubleshooting

### Error: "could not locate required checkpoint record"

**Cause**: Backup requires WAL files that are missing from S3.

**Solution**: 
1. Ensure WAL archiving is continuous
2. Don't delete WAL files from S3
3. Create a new backup if WALs are corrupted

### Error: "unexpected failure invoking barman-cloud-wal-archive"

**Cause**: WAL conflict - new cluster trying to archive to same location as backup source.

**Solution**: Use different `serverName` for recovered cluster:

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: hetzner-s3-store
        serverName: postgres-cluster-recovered  # Different from source
```

### Error: "Expected empty archive"

**Cause**: Recovery trying to write to an archive with existing WAL files.

**Solution**: Same as above - use different `serverName` in recovery overlay.

### Backup Shows No WAL Files

**Cause**: `isWALArchiver: true` not set in plugin configuration.

**Solution**: Ensure plugin configuration includes:
```yaml
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true  # This is required!
```

---

## Important Notes

1. **Recovery is ONE-TIME**: The recovery overlay is only for bootstrapping. After recovery completes, switch back to init overlay.

2. **Never Delete WAL Files**: WAL files are essential for backup consistency. Deleting them makes backups unrestorable.

3. **ServerName Matters**: 
   - Source backup: `serverName: postgres-cluster`
   - Recovered cluster: `serverName: postgres-cluster-recovered`
   
4. **Verify Before Disaster**: Test recovery periodically in a staging environment.

5. **Backup Retention**: Configure retention policy to manage S3 storage costs.

---

## Quick Reference Commands

```bash
# Create backup
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-backup-$(date +%Y%m%d-%H%M%S)
  namespace: postgres
spec:
  cluster:
    name: postgres-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

# Check backups
kubectl get backup -n postgres

# Check cluster status
kubectl get cluster -n postgres

# Check WAL archiving
kubectl logs -n postgres postgres-cluster-1 -c plugin-barman-cloud --tail=20

# List S3 contents
kubectl run s3-list --rm -it --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=<your-key>" \
  --env="AWS_SECRET_ACCESS_KEY=<your-secret>" \
  -- s3 ls s3://awx-postgres-backups/ --recursive \
  --endpoint-url=https://fsn1.your-objectstorage.com
```
