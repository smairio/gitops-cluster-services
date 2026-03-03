# Network Policy Implementation Report

## Kubernetes Cluster Security Hardening

**Date:** March 2, 2026  
**Environment:** Production Kubernetes Cluster  
**Cluster Version:** v1.31.14  
**CNI Plugin:** Calico v3.28.2  
**Total Nodes:** 7 (1 Master + 3 App Workers + 3 ELK Workers)

---

## 1. Executive Summary

This report documents the implementation of comprehensive Calico Network Policies across all namespaces in the Kubernetes cluster. The objective was to enforce zero-trust network security by implementing namespace-level isolation while maintaining required application connectivity.

**Key Achievements:**
- Implemented 17 network policy manifests covering 12 namespaces
- All 19 connectivity tests passing
- Fixed critical issue with Metricbeat unable to collect node metrics from kube-state-metrics
- Ensured all 7 nodes are now reporting metrics to Elasticsearch

---

## 2. Problem Statement

Prior to this implementation, the cluster had minimal network policy enforcement, resulting in:

1. **Unrestricted Pod-to-Pod Communication:** Any pod could communicate with any other pod across namespaces
2. **Security Risk:** Potential lateral movement in case of pod compromise
3. **Compliance Gap:** Missing network segmentation required for security standards
4. **Observability Issue:** Metricbeat was only detecting 3 of 7 nodes due to blocked access to kube-state-metrics

---

## 3. Solution Architecture

### 3.1 Namespace Coverage

Network policies were implemented for the following namespaces:

| Namespace | Policy Count | Description |
|-----------|--------------|-------------|
| ingress-nginx | 2 | External traffic + backend egress |
| argocd | 3 | GitOps server + internal communication |
| monitoring | 3 | Prometheus, Grafana, Alertmanager |
| elastic-system | 4 | Elasticsearch, Kibana, Filebeat, Metricbeat |
| keycloak | 2 | Identity provider |
| awx | 2 | Ansible automation |
| postgres | 2 | PostgreSQL database |
| cert-manager | 1 | TLS certificate management |
| cnpg-system | 1 | CloudNative-PG operator |
| external-secrets | 1 | Vault secret synchronization |
| kube-system | 1 | Core cluster components |

### 3.2 Policy Design Principles

1. **Default Deny Implicit:** By creating any NetworkPolicy with a policyType, non-matching traffic is denied
2. **Least Privilege:** Only required ports and destinations are allowed
3. **Namespace Isolation:** Cross-namespace traffic requires explicit rules
4. **Egress Control:** Outbound traffic is restricted to necessary destinations

---

## 4. Implementation Details

### 4.1 Ingress Controller Policies

The ingress-nginx namespace required bidirectional policies:

**Ingress (External Traffic):**
- Ports 80, 443, 8443 from any source
- Port 10254 from monitoring namespace (metrics scraping)

**Egress (Backend Services):**
- ArgoCD: ports 80, 443, 8080
- Monitoring: ports 80, 3000, 9090
- Elastic-system: port 5601 (Kibana)
- Keycloak: ports 8080, 8443
- AWX: ports 80, 8052

### 4.2 Elastic Stack Policies

Critical fix implemented for Metricbeat connectivity:

**Issue Identified:**  
Metricbeat-state pod was unable to reach kube-state-metrics in the monitoring namespace, resulting in only 3/7 nodes being reported.

**Root Cause:**  
- Missing egress rule from elastic-system to monitoring namespace on port 8080
- Missing ingress rule on monitoring namespace to accept traffic from elastic-system

**Solution Applied:**
```yaml
# Added to elastic-system egress policy
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
  ports:
    - protocol: TCP
      port: 8080

# Added to monitoring ingress policy
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: elastic-system
  ports:
    - protocol: TCP
      port: 8080
```

### 4.3 Database Access Policies

PostgreSQL access restricted to:
- AWX namespace (port 5432)
- Keycloak namespace (port 5432)
- CNPG-system namespace (operator management)

All other namespaces are blocked from direct database access.

### 4.4 External Service Access

Policies configured for external connectivity:

| Namespace | Destination | Port | Purpose |
|-----------|-------------|------|---------|
| cert-manager | Let's Encrypt ACME | 443 | Certificate issuance |
| external-secrets | Vault (10.70.0.50) | 8200 | Secret synchronization |
| argocd | GitHub/GitLab | 443, 22 | Git repository sync |

---

## 5. Testing and Validation

### 5.1 Connectivity Test Script

A comprehensive test script was developed to validate all network policies:

```
Test Categories:
- DNS Connectivity (kube-dns access)
- Ingress-NGINX Egress Tests
- ArgoCD Connectivity
- AWX/Keycloak PostgreSQL Access
- CNPG Operator Access
- External Secrets Vault Access
- Cert-Manager ACME Access
- Monitoring Internal Connectivity
- Elastic Stack Internal Connectivity
- Negative Tests (blocked connections)
```

### 5.2 Test Results

**Final Test Summary:**
```
Passed:  19
Failed:  0
Skipped: 0

All connectivity tests passed!
Network policies are correctly configured.
```

### 5.3 Negative Test Verification

Confirmed that unauthorized access is properly blocked:
- ✓ default → postgres:5432 (blocked)
- ✓ default → argocd-redis:6379 (blocked)
- ✓ default → alertmanager:9093 (blocked)

---

## 6. Files Delivered

| File | Description |
|------|-------------|
| 01-ingress-nginx.yaml | Ingress controller policies |
| 02-backend-allow-ingress.yaml | Backend service ingress from nginx |
| 03-awx-keycloak-egress.yaml | Application egress rules |
| 04-elastic-internal.yaml | Elasticsearch stack policies |
| 05-monitoring-internal.yaml | Prometheus/Grafana policies |
| 06-argocd-internal.yaml | GitOps server policies |
| 07-keycloak-complete.yaml | Identity provider policies |
| 08-postgres-complete.yaml | Database policies |
| 09-cert-manager.yaml | Certificate manager policies |
| 10-cnpg-system.yaml | PostgreSQL operator policies |
| 11-external-secrets.yaml | Secret sync policies |
| 12-kube-system.yaml | Core component policies |
| test-connectivity.sh | Validation test script |

---

## 7. Recommendations

1. **GitOps Integration:** Enable ArgoCD sync for calico-network-policies to automate deployment
2. **Monitoring:** Add network policy metrics to Grafana dashboards
3. **Regular Audits:** Run connectivity tests after any policy changes
4. **Documentation:** Keep this report updated with any policy modifications

---

## 8. Conclusion

The network policy implementation successfully achieved the security hardening objectives while maintaining full application functionality. The critical issue with Metricbeat metrics collection was identified and resolved, ensuring complete observability across all 7 cluster nodes.
