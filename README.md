# GitOps Cluster Services

ArgoCD-managed applications for the HA Kubernetes cluster.

## Structure

```
gitops-cluster-services/
├── monitoring/           # Prometheus + Grafana stack
│   ├── app.yaml         # ArgoCD Application
│   ├── values.yaml      # Helm values
│   ├── ingress.yaml     # Grafana ingress
│   ├── externalsecret-admin.yaml    # Grafana admin credentials
│   └── externalsecret-domain.yaml   # Domain from Vault
├── redis/               # Redis with Sentinel
│   ├── app.yaml         # ArgoCD Application
│   ├── values.yaml      # Helm values (1 master + 2 replicas)
│   └── externalsecret.yaml          # Redis password
└── cloudnative-pg/      # CloudNative PostgreSQL Operator
    ├── app.yaml         # ArgoCD Application
    └── values.yaml      # Helm values
```

## Vault Secrets Required

Add these secrets to Vault for ESO to sync:

| Vault Path | Key | Description |
|------------|-----|-------------|
| `secret/prod/ha-k8s` | `DOMAIN_NAME` | Base domain (e.g., `dev.tests.software`) |
| `secret/prod/monitoring/grafana` | `admin_user` | Grafana admin username |
| `secret/prod/monitoring/grafana` | `admin_password` | Grafana admin password |
| `secret/prod/redis` | `password` | Redis authentication password |

### Add secrets to Vault

```bash
# Grafana credentials
vault kv put secret/prod/monitoring/grafana \
  admin_user="admin" \
  admin_password="your-secure-password"

# Redis password
vault kv put secret/prod/redis \
  password="your-redis-password"
```

## Deploy with ArgoCD

### Option 1: Add repo and apply apps manually

```bash
# Add this repo to ArgoCD
argocd repo add https://github.com/smairio/gitops-cluster-services.git

# Apply ExternalSecrets first (they create the K8s secrets)
kubectl apply -f monitoring/externalsecret-admin.yaml
kubectl apply -f monitoring/externalsecret-domain.yaml
kubectl apply -f redis/externalsecret.yaml

# Wait for secrets to sync
kubectl get secret -n monitoring grafana-admin
kubectl get secret -n redis redis-auth

# Apply ArgoCD Applications
kubectl apply -f monitoring/app.yaml
kubectl apply -f monitoring/ingress.yaml
kubectl apply -f redis/app.yaml
kubectl apply -f cloudnative-pg/app.yaml
```

### Option 2: App of Apps (recommended)

Create a root application that deploys all services:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-services
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/smairio/gitops-cluster-services.git
    targetRevision: main
    path: .
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Save as `app-of-apps.yaml` and apply:

```bash
kubectl apply -f app-of-apps.yaml
```

### Option 3: ArgoCD CLI

```bash
argocd app create cluster-services \
  --repo https://github.com/smairio/gitops-cluster-services.git \
  --path . \
  --dest-server https://kubernetes.default.svc \
  --directory-recurse \
  --sync-policy automated
```

## Access

| Service | URL |
|---------|-----|
| Grafana | `https://grafana.dev.tests.software` |
| Prometheus | Internal: `http://monitoring-prometheus:9090` |
| Redis | Internal: `redis-master.redis.svc:6379` |

## Components

### Monitoring (kube-prometheus-stack)

- **Prometheus**: Metrics collection and alerting
- **Grafana**: Dashboards and visualization
- **Alertmanager**: Alert routing and notifications
- **ServiceMonitors**: Auto-discovery of metrics endpoints

### Redis

- **Architecture**: 1 Master + 2 Replicas with Sentinel
- **Sentinel**: Automatic failover and service discovery
- **Persistence**: 10Gi per node
- **Metrics**: Enabled for Prometheus scraping

### CloudNative PostgreSQL

- **Operator**: Manages PostgreSQL clusters
- **Features**: HA, backup, recovery, connection pooling

## File Naming Convention

| File | Purpose |
|------|---------|
| `app.yaml` | ArgoCD Application definition |
| `values.yaml` | Helm chart values |
| `ingress.yaml` | Kubernetes Ingress resource |
| `externalsecret.yaml` | Main ExternalSecret |
| `externalsecret-*.yaml` | Additional ExternalSecrets with suffix |
