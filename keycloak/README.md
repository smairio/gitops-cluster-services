# Keycloak - Identity and Access Management

## Overview

Keycloak provides Identity and Access Management (IAM) for the cluster services. It enables Single Sign-On (SSO) via OIDC for applications like AWX, ArgoCD, and others.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                                   │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                       keycloak namespace                              │ │
│  │                                                                       │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │ │
│  │  │                   Keycloak (Quay.io Official)                   │ │ │
│  │  │  - User Management                                              │ │ │
│  │  │  - OIDC/OAuth2 Provider                                         │ │ │
│  │  │  - Realm Management (awx-realm)                                 │ │ │
│  │  └─────────────────────────────────────────────────────────────────┘ │ │
│  │                             │                                         │ │
│  │                             │ PostgreSQL Connection                   │ │
│  │                             ▼                                         │ │
│  └─────────────────────────────┼─────────────────────────────────────────┘ │
│                                │                                            │
│                                ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                       postgres namespace                              │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │ │
│  │  │  PostgreSQL Cluster (CloudNativePG)                             │ │ │
│  │  │  - Database: keycloak                                           │ │ │
│  │  │  - User: keycloak (managed role)                                │ │ │
│  │  └─────────────────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  Ingress: keycloak.dev.tests.software                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `app.yaml` | ArgoCD Application with multi-source configuration |
| `values.yaml` | Helm values for Keycloak (Codecentric chart) |
| `manifests/namespace.yaml` | Keycloak namespace definition |
| `manifests/externalsecrets.yaml` | ExternalSecrets for admin and DB credentials |
| `manifests/db-init-job.yaml` | Job to create keycloak database |
| `manifests/ingress.yaml` | Ingress for external access |

## Configuration

### app.yaml - Multi-Source ArgoCD Application

```yaml
sources:
  # 1. Keycloak Helm chart from Codecentric
  - repoURL: https://codecentric.github.io/helm-charts
    chart: keycloakx
    targetRevision: 7.1.7

  # 2. Values from git repository
  - repoURL: https://github.com/smairio/gitops-cluster-services.git
    ref: values

  # 3. Additional manifests (namespace, secrets, db-init, ingress)
  - repoURL: https://github.com/smairio/gitops-cluster-services.git
    path: keycloak/manifests
```

### values.yaml Key Settings

| Setting | Value | Description |
|---------|-------|-------------|
| `image.repository` | `quay.io/keycloak/keycloak` | Official Keycloak image |
| `image.tag` | `26.0` | Keycloak version |
| `database.vendor` | `postgres` | External PostgreSQL |
| `database.hostname` | `postgres-cluster-rw.postgres.svc` | CloudNativePG service |
| `proxy.mode` | `xforwarded` | TLS terminated at ingress |
| `cache.stack` | `custom` | Local cache for single replica |

### Secrets from Vault

| ExternalSecret | Vault Path | Purpose |
|----------------|------------|---------|
| `keycloak-admin-secret` | `khalil/argocd/keycloak-admin` | Admin password |
| `keycloak-postgres-secret` | `khalil/argocd/keycloak-postgres` | Database connection |
| `postgres-superuser` | (from postgres namespace) | For db-init job |

## Sync Wave Order

```
wave -3: externalsecrets.yaml  (keycloak-postgres-secret)
wave -2: externalsecrets.yaml  (keycloak-admin-secret)
wave -1: db-init-job.yaml      (create database)
wave  0: keycloak deployment   (Helm chart)
```

## Database Initialization

The `db-init-job.yaml` runs before Keycloak and:

1. Connects to PostgreSQL using superuser credentials
2. Creates the `keycloak` database if it doesn't exist
3. Grants privileges to the `keycloak` role
4. Is idempotent (safe to re-run)

## OIDC Integration

### Configured Clients

| Client | Realm | Purpose |
|--------|-------|---------|
| `awx` | `awx-realm` | SSO for AWX automation platform |
| `argocd` | (optional) | SSO for ArgoCD |

### Setup Script

The `scripts/keycloak-awx-setup.sh` script automates:

1. Creating the `awx-realm`
2. Creating the AWX client with proper redirect URIs
3. Creating OIDC user accounts
4. Configuring AWX OIDC settings via API

## Accessing Keycloak

### Admin Console

```
URL: https://keycloak.dev.tests.software
User: admin
Password: (from Vault: khalil/argocd/keycloak-admin)
```

### Internal Service (for pods)

```
URL: http://keycloak-keycloakx-http.keycloak.svc.cluster.local:80
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n keycloak
kubectl logs -n keycloak -l app.kubernetes.io/name=keycloakx
```

### Check Database Connection

```bash
kubectl exec -n keycloak deploy/keycloak-keycloakx -- \
  /opt/keycloak/bin/kc.sh show-config | grep -i postgres
```

### Check Secrets

```bash
kubectl get secrets -n keycloak
kubectl get externalsecrets -n keycloak
```

### Verify Database Init Job

```bash
kubectl get jobs -n keycloak
kubectl logs -n keycloak job/keycloak-db-init
```

## Node Placement

Keycloak runs on general worker nodes:

```yaml
nodeSelector:
  node-type: general
tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "general"
    effect: "NoSchedule"
```

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Codecentric Helm Chart](https://github.com/codecentric/helm-charts/tree/master/charts/keycloakx)
- [Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/)
