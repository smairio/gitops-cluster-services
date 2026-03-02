# Calico Network Policies for Ingress

This folder contains Kubernetes NetworkPolicies (compatible with Calico CNI) to secure ingress traffic to backend services.

## Structure

| File | Description |
|------|-------------|
| `00-default-deny.yaml` | Default deny all policies for each namespace |
| `01-ingress-nginx.yaml` | Allow ingress-nginx to receive external traffic and reach backends |
| `02-backend-allow-ingress.yaml` | Allow backend services to receive traffic from ingress-nginx |
| `03-dns-egress.yaml` | Allow DNS resolution for all namespaces |

## How It Works

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│                    ingress-nginx                            │
│  (receives external HTTP/HTTPS on ports 80, 443)           │
└─────────────────────────────────────────────────────────────┘
    │
    │  NetworkPolicy allows egress to specific namespaces
    ▼
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│  argocd  │   awx    │ elastic  │ keycloak │ grafana  │prometheus│
│  :8080   │  :8052   │  :5601   │  :8080   │  :3000   │  :9090   │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
    │
    │  Each namespace has "allow-from-ingress-nginx" policy
    ▼
Backend receives traffic only from ingress-nginx namespace
```

## Testing Ingress

### Quick Test (all endpoints)

```bash
for domain in argo awx kibana keycloak grafana prometheus; do
  echo -n "${domain}.dev.tests.software: "
  curl -sk -o /dev/null -w "%{http_code}" "https://${domain}.dev.tests.software" --max-time 5
  echo ""
done
```

### Individual Tests

```bash
# ArgoCD
curl -sk https://argo.dev.tests.software

# AWX
curl -sk https://awx.dev.tests.software

# Kibana
curl -sk https://kibana.dev.tests.software

# Keycloak
curl -sk https://keycloak.dev.tests.software

# Grafana
curl -sk https://grafana.dev.tests.software

# Prometheus
curl -sk https://prometheus.dev.tests.software
```

## Applying Manually (for testing)

```bash
# Apply all policies
kubectl apply -f calico-network-policies/manifests/

# Check policies
kubectl get networkpolicies -A

# Delete all policies (to restore access)
kubectl delete -f calico-network-policies/manifests/
```

## Troubleshooting

### Check if policies are applied

```bash
kubectl get networkpolicies -A
```

### Describe a specific policy

```bash
kubectl describe networkpolicy -n <namespace> <policy-name>
```

### Check pod labels (needed for policy selectors)

```bash
kubectl get pods -n argocd --show-labels
kubectl get pods -n awx --show-labels
kubectl get pods -n elastic-system --show-labels
kubectl get pods -n keycloak --show-labels
kubectl get pods -n monitoring --show-labels
```

### Temporarily disable policies (for debugging)

```bash
# Delete default deny to allow all traffic
kubectl delete networkpolicy default-deny-all -n <namespace>
```
