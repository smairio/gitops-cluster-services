# PostgreSQL Backup and Recovery Guide

This document explains the backup and disaster recovery process for the CloudNativePG cluster using the Barman Cloud Plugin.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Backup Process](#backup-process)
- [Recovery Process](#recovery-process)
- [Point-in-Time Recovery (PITR)](#point-in-time-recovery-pitr)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

All backups are stored in a **single folder** with unique Backup IDs:

```
awx-postgres-backups/
└── postgres-cluster/
    ├── base/                         # All base backups (with unique IDs)
    │   ├── 20260130T100000/          # Backup 1
    │   │   ├── backup.info
    │   │   └── data.tar.gz
    │   ├── 20260130T120000/          # Backup 2
    │   └── 20260130T140000/          # Backup 3
    └── wals/                         # WAL files for PITR
        └── 0000000100000000/
            ├── 000000010000000000000001.gz
            ├── 000000010000000000000002.gz
            └── ...
```

---

## Backup Process

### 1. On-Demand Backup

Create a backup:

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: backup-$(date +%Y%m%d-%H%M%S)
  namespace: postgres
spec:
  method: plugin
  cluster:
    name: postgres-cluster
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
```

### 2. Check Backup Status

```bash
kubectl get backup -n postgres
```

Example output:
```
NAME                    AGE   CLUSTER            METHOD   PHASE       ERROR
backup-20260130-100519  77s   postgres-cluster   plugin   completed
```

### 3. List All Backups

```bash
kubectl get backup -n postgres -o custom-columns=\
NAME:.metadata.name,\
PHASE:.status.phase,\
BACKUP_ID:.status.backupId,\
STARTED:.status.startedAt,\
STOPPED:.status.stoppedAt
```

Example output:
```
NAME                    PHASE       BACKUP_ID         STARTED                  STOPPED
backup-20260130-100519  completed   20260130T100519   2026-01-30T10:05:19Z    2026-01-30T10:05:45Z
backup-20260130-120000  completed   20260130T120000   2026-01-30T12:00:00Z    2026-01-30T12:00:30Z
```

### 4. Scheduled Backups (Optional)

Create a ScheduledBackup resource:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: daily-backup
  namespace: postgres
spec:
  schedule: "0 0 2 * * *"  # Every day at 2:00 AM
  backupOwnerReference: self
  cluster:
    name: postgres-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

---

## Recovery Process

### Step 1: Switch to Recovery Mode

Edit `postgres-bootstrap/app.yaml`:

```yaml
source:
  path: postgres-bootstrap/overlays/recovery  # Change from overlays/init
```

### Step 2: Configure Recovery Target (Optional)

Edit `postgres-bootstrap/overlays/recovery/kustomization.yaml`:

```yaml
# Option 1: Restore to LATEST point (default)
recoveryTarget: {}

# Option 2: Restore specific BACKUP by ID
recoveryTarget:
  backupID: "20260130T120000"

# Option 3: Restore to specific TIME (PITR)
recoveryTarget:
  targetTime: "2026-01-30T12:00:00Z"
```

### Step 3: Commit and Push

```bash
git add -A
git commit -m "switch to recovery mode"
git push
```

### Step 4: Delete Existing Resources

```bash
# Delete ArgoCD applications
kubectl delete applications -n argocd awx postgres-bootstrap

# Delete namespaces
kubectl delete namespace awx postgres --force --grace-period=0

# Delete PVCs if needed
kubectl delete pvc -n postgres --all
```

### Step 5: Sync ArgoCD

ArgoCD will automatically sync, or force it:

```bash
kubectl patch application cluster-services -n argocd --type=merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### Step 6: Monitor Recovery

```bash
# Watch recovery progress
kubectl get cluster,pods -n postgres -w

# Check logs
kubectl logs -n postgres postgres-cluster-1 -c postgres -f
```

### Step 7: After Recovery - Switch Back to Init

**IMPORTANT**: After successful recovery:

```yaml
source:
  path: postgres-bootstrap/overlays/init  # Switch back
```

Commit and push. The cluster will continue running without re-initializing.

---

## Point-in-Time Recovery (PITR)

PITR allows you to restore to any point in time between backups.

### Example: Restore to Specific Time

Edit `overlays/recovery/kustomization.yaml`:

```yaml
- op: add
  path: /spec/bootstrap
  value:
    recovery:
      source: postgres-cluster-backup
      recoveryTarget:
        targetTime: "2026-01-30T15:30:00Z"
```

### Example: Restore Specific Backup

```yaml
recoveryTarget:
  backupID: "20260130T120000"
```

---

## Troubleshooting

### Check Cluster Status

```bash
kubectl get cluster -n postgres
kubectl describe cluster postgres-cluster -n postgres
```

### Check Pod Logs

```bash
kubectl logs -n postgres postgres-cluster-1 -c postgres
```

### Check Plugin Sidecar Logs

```bash
kubectl logs -n postgres postgres-cluster-1 -c barman-cloud
```

### Common Issues

#### 1. Backup Not Found

```bash
# List all backups
kubectl get backup -n postgres
```

#### 2. WAL Archive Check Failed

The recovery overlay uses `skipEmptyWalArchiveCheck: enabled` annotation to allow recovery to the same archive folder.

#### 3. Recovery Stuck

Check the pod logs:
```bash
kubectl logs -n postgres postgres-cluster-1-full-recovery -f
```

---

## Quick Reference

| Action | Command |
|--------|---------|
| Create backup | `kubectl apply -f backup.yaml` |
| List backups | `kubectl get backup -n postgres` |
| Get backup details | `kubectl describe backup <name> -n postgres` |
| Check cluster | `kubectl get cluster -n postgres` |
| View logs | `kubectl logs -n postgres postgres-cluster-1 -c postgres` |
