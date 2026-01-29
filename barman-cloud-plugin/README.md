# Barman Cloud Plugin

This folder contains the Barman Cloud CNPG-I Plugin configuration for PostgreSQL backups to Hetzner Object Storage.

## Overview

Starting with CloudNativePG v1.26, the native `barmanObjectStore` backup method is **deprecated** in favor of the Barman Cloud Plugin (CNPG-I architecture).

## Components

| File | Description |
|------|-------------|
| `app.yaml` | ArgoCD Application for Helm chart installation |
| `values.yaml` | Helm values for the plugin |
| `externalsecret-s3.yaml` | Pulls S3 credentials from Vault |
| `objectstore.yaml` | ObjectStore CRD for Hetzner S3 configuration |

## Hetzner Object Storage

### Endpoints

| Location | Endpoint URL |
|----------|-------------|
| Falkenstein | `https://fsn1.your-objectstorage.com` |
| Nuremberg | `https://nbg1.your-objectstorage.com` |
| Helsinki | `https://hel1.your-objectstorage.com` |

### Bucket URL Format

```
https://<bucket-name>.<location>.your-objectstorage.com/<file-name>
```

## Prerequisites

### 1. Create Hetzner S3 Bucket

1. Go to [Hetzner Console](https://console.hetzner.com/)
2. Create a new Object Storage bucket (e.g., `postgres-backups`)
3. Generate S3 credentials (Access Key + Secret Key)

### 2. Store Credentials in Vault

```bash
vault kv put secret/khalil/argocd/hetzner-s3 \
  access_key_id="YOUR_ACCESS_KEY" \
  secret_access_key="YOUR_SECRET_KEY"
```

### 3. Update ObjectStore Configuration

Edit `objectstore.yaml` to match your bucket name and region:

```yaml
spec:
  configuration:
    destinationPath: s3://your-bucket-name/
    endpointURL: https://fsn1.your-objectstorage.com  # Your region
```

## Usage with PostgreSQL Cluster

Once the plugin is installed, configure your PostgreSQL cluster to use it:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-postgres
spec:
  instances: 3
  
  # Enable WAL archiving with the plugin
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: hetzner-s3-store  # Reference to ObjectStore
  
  storage:
    size: 20Gi
```

## Scheduled Backups

Create a ScheduledBackup resource:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: daily-backup
spec:
  schedule: "0 0 0 * * *"  # Daily at midnight (6-field cron with seconds)
  backupOwnerReference: self
  cluster:
    name: my-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

## Recovery

To restore from backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-postgres-restored
spec:
  instances: 3
  
  bootstrap:
    recovery:
      source: source-cluster
  
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: hetzner-s3-store
  
  externalClusters:
  - name: source-cluster
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: hetzner-s3-store
        serverName: my-postgres  # Original cluster name
  
  storage:
    size: 20Gi
```

## Troubleshooting

### Check Plugin Status

```bash
kubectl get pods -n cnpg-system | grep barman
```

### Check ObjectStore

```bash
kubectl get objectstore -n cnpg-system
kubectl describe objectstore hetzner-s3-store -n cnpg-system
```

### Check ExternalSecret

```bash
kubectl get externalsecret -n cnpg-system
kubectl get secret hetzner-s3-credentials -n cnpg-system
```
