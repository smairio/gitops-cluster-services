# Redis Deployment

This folder contains the Redis deployment configuration for the Kubernetes cluster.

## Architecture Overview

We deploy **Bitnami Redis** with Sentinel for high availability. This Redis instance is used for:
- General caching needs across the cluster
- Future applications requiring Redis (not AWX - see note below)

### Redis Configuration

- **Architecture**: Replication with Sentinel
- **Nodes**: 1 master + 1-2 replicas (configurable)
- **Sentinel Quorum**: 2
- **Persistence**: 10Gi per node
- **Authentication**: Password stored in Vault

### Service Endpoints

| Service | Description | Use Case |
|---------|-------------|----------|
| `redis.redis.svc.cluster.local:6379` | Load-balanced to all nodes | Read-only operations |
| `redis-node-0.redis-headless.redis.svc.cluster.local:6379` | Direct to node-0 | Write operations (if node-0 is master) |
| `redis-headless.redis.svc.cluster.local:6379` | Headless service | StatefulSet DNS discovery |

### Connecting to Redis Master

For applications that need to write to Redis, you have two options:

#### Option 1: Direct Pod Connection (Simple, not HA)
```
redis-node-0.redis-headless.redis.svc.cluster.local:6379
```
⚠️ This assumes node-0 is always the master. If failover occurs, you'll need to update the connection.

#### Option 2: Sentinel-Aware Connection (HA)
For applications that support Redis Sentinel:
```
sentinel://redis-node-0.redis-headless.redis.svc.cluster.local:26379?master=mymaster
```
This allows automatic master discovery and failover.

### Query Current Master
```bash
# Get current master from Sentinel
kubectl exec -n redis redis-node-0 -- redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# Check replication status
kubectl exec -n redis redis-node-0 -- redis-cli -a <password> INFO replication
```

## Vault Secrets

Redis authentication is managed via Vault and External Secrets Operator:

- **Vault Path**: `secret/khalil/argocd/redis`
- **Secret Key**: `password`
- **Kubernetes Secret**: `redis-auth` in `redis` namespace

## AWX and Redis

### Important: AWX Uses Bundled Redis

**The AWX Operator does NOT support external Redis.** AWX uses a built-in Redis sidecar container that communicates via unix socket (`/var/run/redis/redis.sock`).

Attempting to configure AWX with external Redis via `extra_settings` will cause issues:
1. The sidecar Redis container is always created
2. Internal communication uses unix socket, not TCP
3. Settings like `BROKER_URL` and `CACHES` can be overridden but may cause conflicts

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

### Why External Redis Doesn't Work with AWX

1. **Unix Socket Design**: AWX is hardcoded to use unix socket for Redis IPC
2. **Operator Templates**: The `redis.conf` is generated with `unixsocket` settings
3. **No External Redis Spec**: AWX operator has no `redis_configuration_secret` like it has for PostgreSQL
4. **Sidecar Always Created**: Even with external Redis settings, the sidecar container is created

### Recommendations for AWX

✅ **Use the bundled Redis sidecar** (default behavior)
- Works out of the box
- No configuration needed
- Reliable and tested

❌ **Don't attempt external Redis** unless you:
- Fork the AWX operator
- Modify deployment templates
- Handle all the edge cases

## Files in This Directory

| File | Description |
|------|-------------|
| `app.yaml` | ArgoCD Application definition with multi-source (Helm + ExternalSecret) |
| `values.yaml` | Redis Helm chart values |
| `externalsecret.yaml` | ExternalSecret to pull password from Vault |

## Troubleshooting

### Check Redis Pod Status
```bash
kubectl get pods -n redis
```

### Check Redis Logs
```bash
kubectl logs -n redis redis-node-0 -c redis
```

### Test Redis Connection
```bash
kubectl run redis-test --rm -it --restart=Never --image=redis:alpine -n redis -- \
  redis-cli -h redis-node-0.redis-headless.redis.svc.cluster.local -a <password> PING
```

### Check Sentinel Status
```bash
kubectl exec -n redis redis-node-0 -- redis-cli -p 26379 INFO sentinel
```

### Force Master Failover
```bash
kubectl exec -n redis redis-node-0 -- redis-cli -p 26379 SENTINEL failover mymaster
```
