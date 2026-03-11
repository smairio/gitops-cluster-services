# Monitoring Stack (Prometheus + Grafana)

## Overview

The monitoring stack provides observability for the Kubernetes cluster using Prometheus for metrics collection and Grafana for visualization. This uses the kube-prometheus-stack Helm chart.

> **Note**: Currently disabled (`app.yaml.disabled`). Rename to `app.yaml` to enable.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                                   │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                      monitoring namespace                             │ │
│  │                                                                       │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │ │
│  │  │   Grafana    │  │ Prometheus   │  │   Prometheus Operator    │   │ │
│  │  │   (UI)       │  │   Server     │  │   (manages CRDs)         │   │ │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘   │ │
│  │                           │                                          │ │
│  │                           │ scrapes                                  │ │
│  │                           ▼                                          │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │ │
│  │  │ Alertmanager │  │  kube-state  │  │   node-exporter          │   │ │
│  │  │              │  │   -metrics   │  │   (DaemonSet on ALL)     │   │ │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘   │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  Ingress:                                                                   │
│  - grafana.dev.tests.software                                               │
│  - prometheus.dev.tests.software                                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `app.yaml.disabled` | ArgoCD Application (disabled) |
| `values.yaml` | Helm values for kube-prometheus-stack |
| `externalsecret-admin.yaml` | ExternalSecret for Grafana admin credentials |
| `ingress.yaml` | Ingress for Grafana (grafana.dev.tests.software) |
| `prometheus-ingress.yaml` | Ingress for Prometheus UI |

## Components

| Component | Purpose | Node Placement |
|-----------|---------|----------------|
| **Grafana** | Visualization dashboards | `general` nodes |
| **Prometheus** | Metrics collection & storage | `general` nodes |
| **Alertmanager** | Alert routing & notifications | `general` nodes |
| **Prometheus Operator** | Manages Prometheus CRDs | `general` nodes |
| **kube-state-metrics** | Kubernetes object metrics | `general` nodes |
| **node-exporter** | Node-level metrics | **ALL nodes** (DaemonSet) |

## Configuration

### Node Placement

All components except `node-exporter` run on `general` worker nodes:

```yaml
nodeSelector:
  node-type: general
tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "general"
    effect: "NoSchedule"
```

The `node-exporter` runs on ALL nodes (including ELK nodes) to collect metrics from every machine:

```yaml
prometheus-node-exporter:
  tolerations:
    - key: "dedicated"
      operator: "Exists"
```

### Grafana Authentication

Credentials are stored in Vault and synced via ExternalSecret:

| Secret | Vault Path | Keys |
|--------|------------|------|
| `grafana-admin` | `khalil/argocd/grafana` | `admin_user`, `admin_password` |

## Accessing

### Grafana

```
URL: https://grafana.dev.tests.software
```

### Prometheus

```
URL: https://prometheus.dev.tests.software
```

## Enabling the Stack

```bash
# Rename to enable
cd gitops-cluster-services/monitoring
mv app.yaml.disabled app.yaml
git add app.yaml
git commit -m "Enable monitoring stack"
git push
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n monitoring
```

### Check Prometheus Targets

```bash
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Open http://localhost:9090/targets
```

### Check Grafana Logs

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana
```

### Verify Secrets

```bash
kubectl get externalsecrets -n monitoring
kubectl get secrets -n monitoring grafana-admin
```

## Helm Chart

Uses `kube-prometheus-stack` which includes:

- Prometheus
- Grafana
- Alertmanager
- node-exporter
- kube-state-metrics
- Pre-configured Kubernetes dashboards
- ServiceMonitor CRDs for auto-discovery

## References

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Prometheus Documentation](https://prometheus.io/docs/introduction/overview/)
