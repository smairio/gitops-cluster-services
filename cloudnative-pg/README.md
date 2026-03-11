# CloudNativePG Operator

## Overview

CloudNativePG is a Kubernetes operator that manages PostgreSQL clusters natively in Kubernetes. This component installs the operator itself, which then manages PostgreSQL cluster instances defined in `postgres-bootstrap/`.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                              │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    cnpg-system namespace                     │   │
│  │  ┌─────────────────────────────────────────────────────┐    │   │
│  │  │           CloudNativePG Operator                    │    │   │
│  │  │  - Watches Cluster CRDs                             │    │   │
│  │  │  - Manages PostgreSQL instances                     │    │   │
│  │  │  - Handles failover & replication                   │    │   │
│  │  │  - Orchestrates backups via plugins                 │    │   │
│  │  └─────────────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              │ Watches                              │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    postgres namespace                        │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │   │
│  │  │ Primary  │  │ Replica  │  │ Replica  │ (managed by CNPG) │   │
│  │  │ postgres │  │ postgres │  │ postgres │                   │   │
│  │  └──────────┘  └──────────┘  └──────────┘                   │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `app.yaml` | ArgoCD Application that deploys the operator via Helm |
| `values.yaml` | Helm values for operator configuration |

## Configuration

### app.yaml

```yaml
source:
  repoURL: https://cloudnative-pg.github.io/charts
  chart: cloudnative-pg
  targetRevision: 0.27.0
```

- **Chart**: Official CloudNativePG Helm chart
- **Version**: 0.27.0
- **Namespace**: `cnpg-system`
- **Sync Wave**: `-3` (deploys early, before database clusters)

### values.yaml

```yaml
nodeSelector:
  node-type: general
tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "general"
    effect: "NoSchedule"
```

- **Node Placement**: Operator runs on `general` worker nodes
- **Tolerations**: Configured to schedule on tainted nodes

## Relationship with Other Components

| Component | Relationship |
|-----------|--------------|
| `postgres-bootstrap/` | Creates the actual PostgreSQL clusters managed by this operator |
| `barman-cloud-plugin/` | Provides backup functionality via Barman Cloud |
| `keycloak/`, `awx/` | Applications that use PostgreSQL databases |

## Why CloudNativePG?

1. **Kubernetes-Native**: Designed specifically for Kubernetes, not a port of traditional PostgreSQL
2. **Declarative**: Define clusters as YAML, Kubernetes handles the rest
3. **Automated Failover**: Built-in HA with automatic primary election
4. **Backup Integration**: Native support for S3-compatible backup via plugins
5. **Monitoring**: Built-in metrics for Prometheus

## Custom Resource Definitions (CRDs)

The operator installs these CRDs:

| CRD | Purpose |
|-----|---------|
| `clusters.postgresql.cnpg.io` | PostgreSQL cluster definition |
| `backups.postgresql.cnpg.io` | On-demand backup requests |
| `scheduledbackups.postgresql.cnpg.io` | Scheduled backup configuration |
| `poolers.postgresql.cnpg.io` | Connection pooling (PgBouncer) |

## Sync Order

```
sync-wave: -3  →  cloudnative-pg (operator)
sync-wave: -2  →  barman-cloud-plugin (backup plugin)
sync-wave: 0   →  postgres-bootstrap (actual database cluster)
sync-wave: 1   →  keycloak, awx (applications using postgres)
```

## Troubleshooting

### Check Operator Status

```bash
kubectl get pods -n cnpg-system
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg
```

### Check CRDs

```bash
kubectl get crds | grep cnpg
```

### Check Managed Clusters

```bash
kubectl get clusters -A
kubectl describe cluster postgres-cluster -n postgres
```

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [GitHub Repository](https://github.com/cloudnative-pg/cloudnative-pg)
- [Helm Chart](https://github.com/cloudnative-pg/charts)
