# PostgreSQL Bootstrap - CloudNativePG with Kustomize Overlays

This setup provides a Kustomize-based PostgreSQL deployment with two modes:
- **Init Mode**: Create a fresh PostgreSQL cluster
- **Recovery Mode**: Restore from S3 backup (PITR supported)

## Directory Structure

```
postgres-bootstrap/
├── app.yaml                          # ArgoCD Application
├── base/
│   ├── kustomization.yaml            # Base kustomization
│   ├── namespace.yaml                # Namespace definition
│   ├── externalsecret.yaml           # Vault credentials
│   └── cluster.yaml                  # Shared cluster config
└── overlays/
    ├── init/
    │   └── kustomization.yaml        # Fresh cluster bootstrap
    └── recovery/
        └── kustomization.yaml        # Recovery from backup
```

## Prerequisites

1. **Vault Secret**: Store PostgreSQL credentials in Vault:
   ```bash
   vault kv put secret/khalil/argocd/postgres \
     username=postgres \
     password=<your-secure-password>
   ```

2. **S3 Credentials**: Already configured via barman-cloud-plugin ExternalSecret

3. **CloudNativePG Operator**: Must be installed in `cnpg-system` namespace

4. **Barman Cloud Plugin**: Must be installed for backups

## How to Deploy

### Option 1: Fresh Cluster (Init Mode)

1. Ensure `app.yaml` has path set to `postgres-bootstrap/overlays/init`
2. Push to git and let ArgoCD sync, OR apply manually:
   ```bash
   kubectl apply -f postgres-bootstrap/app.yaml
   ```

### Option 2: Restore from Backup (Recovery Mode)

1. Edit `app.yaml` and change path to `postgres-bootstrap/overlays/recovery`
2. (Optional) For Point-in-Time Recovery, edit the overlay:
   ```yaml
   recoveryTarget:
     targetTime: "2026-01-29T10:00:00Z"  # ISO8601 timestamp
   ```
3. Push to git and let ArgoCD sync

## Switching Between Modes

⚠️ **IMPORTANT**: You cannot switch from init to recovery on an existing cluster!

To restore from backup:
1. Delete the existing cluster: `kubectl delete cluster postgres-cluster -n postgres`
2. Change `app.yaml` path to `overlays/recovery`
3. Push and sync

## Point-in-Time Recovery (PITR)

To restore to a specific point in time, edit the recovery overlay:

```yaml
# overlays/recovery/kustomization.yaml
patches:
  - target:
      kind: Cluster
      name: postgres-cluster
    patch: |-
      - op: add
        path: /spec/bootstrap
        value:
          recovery:
            source: postgres-cluster-backup
            recoveryTarget:
              # Restore to specific time
              targetTime: "2026-01-29T10:30:00Z"
              # OR restore to specific backup ID
              # backupID: "20260129T100000"
```

## Monitoring

Check cluster status:
```bash
# Cluster status
kubectl get cluster -n postgres

# Pod status
kubectl get pods -n postgres

# Backup status
kubectl get backups -n postgres

# Scheduled backups
kubectl get scheduledbackups -n postgres
```

## Manual Backup

Trigger an on-demand backup:
```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d%H%M%S)
  namespace: postgres
spec:
  cluster:
    name: postgres-cluster
EOF
```

## Credentials

Access PostgreSQL credentials:
```bash
# Get superuser password
kubectl get secret postgres-superuser -n postgres -o jsonpath='{.data.password}' | base64 -d

# Get connection string
kubectl get secret postgres-cluster-app -n postgres -o jsonpath='{.data.uri}' | base64 -d
```
