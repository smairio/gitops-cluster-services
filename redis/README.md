# Redis Deployment

This folder contains the Redis deployment configuration for the Kubernetes cluster.

## Architecture Overview

We deploy **Bitnami Redis** in **standalone mode** (single master, no replication).

### Redis Configuration

- **Architecture**: Standalone (single node)
- **Nodes**: 1 master
- **Sentinel**: Disabled
- **Replication**: Disabled
- **Persistence**: 10Gi
- **Authentication**: Password stored in Vault

### Service Endpoint

```
redis-master.redis.svc.cluster.local:6379
```

### Connecting to Redis

```bash
# From within the cluster
redis-cli -h redis-master.redis.svc.cluster.local -a <password>

# Test connection
kubectl run redis-test --rm -it --restart=Never --image=redis:alpine -n redis -- \
  redis-cli -h redis-master.redis.svc.cluster.local -a <password> PING
```

## Vault Secrets

Redis authentication is managed via Vault and External Secrets Operator:

- **Vault Path**: `secret/khalil/argocd/redis`
- **Secret Key**: `password`
- **Kubernetes Secret**: `redis-auth` in `redis` namespace

## AWX and Redis

### Important: AWX Uses Bundled Redis

**The AWX Operator does NOT support external Redis.** AWX uses a built-in Redis sidecar container that communicates via unix socket (`/var/run/redis/redis.sock`).

There is **no way to disable the Redis sidecar** in the current AWX operator. The Redis deployment in this folder is for **other applications only**, not AWX.

### AWX Redis Architecture

```
┌─────────────────────────────────────────┐
│             AWX Pod                      │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │ awx-web │  │awx-task │  │  redis  │  │
│  │         │  │         │  │(sidecar)│  │
│  └────┬────┘  └────┬────┘  └────┬────┘  │
│       │            │            │        │
│       └────────────┴────────────┘        │
│              unix socket                 │
│         /var/run/redis/redis.sock        │
└─────────────────────────────────────────┘
```

## Files in This Directory

| File | Description |
|------|-------------|
| `app.yaml` | ArgoCD Application definition with multi-source (Helm + ExternalSecret) |
| `values.yaml` | Redis Helm chart values (standalone mode) |
| `externalsecret.yaml` | ExternalSecret to pull password from Vault |

## Troubleshooting

### Check Redis Pod Status
```bash
kubectl get pods -n redis
```

### Check Redis Logs
```bash
kubectl logs -n redis redis-master-0
```

### Test Redis Connection
```bash
kubectl run redis-test --rm -it --restart=Never --image=redis:alpine -n redis -- \
  redis-cli -h redis-master.redis.svc.cluster.local -a <password> PING
```
