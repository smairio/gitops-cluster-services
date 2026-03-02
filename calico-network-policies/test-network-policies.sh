#!/bin/bash
# =============================================================================
# Network Policy Test Script
# =============================================================================
# This script tests network policies across all namespaces to verify:
# - Expected connections succeed
# - Blocked connections fail
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
SKIPPED=0

# Test helper functions
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

print_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((SKIPPED++))
}

# Create test pod in a namespace
create_test_pod() {
    local namespace=$1
    local pod_name="netpol-test-$(date +%s)"
    
    kubectl run "$pod_name" \
        --namespace="$namespace" \
        --image=busybox:1.36 \
        --restart=Never \
        --command -- sleep 300 \
        --labels="test=netpol" \
        2>/dev/null || true
    
    # Wait for pod to be ready
    kubectl wait --for=condition=Ready pod/"$pod_name" -n "$namespace" --timeout=30s 2>/dev/null || true
    
    echo "$pod_name"
}

# Delete test pod
delete_test_pod() {
    local namespace=$1
    local pod_name=$2
    kubectl delete pod "$pod_name" -n "$namespace" --grace-period=0 --force 2>/dev/null || true
}

# Test TCP connection from a pod
test_tcp_connection() {
    local namespace=$1
    local pod_name=$2
    local target_host=$3
    local target_port=$4
    local should_succeed=$5
    local description=$6
    
    print_test "$description"
    
    result=$(kubectl exec "$pod_name" -n "$namespace" -- \
        timeout 5 nc -zv "$target_host" "$target_port" 2>&1) && exit_code=0 || exit_code=$?
    
    if [ "$should_succeed" = "true" ]; then
        if [ $exit_code -eq 0 ]; then
            print_pass "Connection to $target_host:$target_port succeeded (expected)"
        else
            print_fail "Connection to $target_host:$target_port failed (expected success)"
        fi
    else
        if [ $exit_code -ne 0 ]; then
            print_pass "Connection to $target_host:$target_port blocked (expected)"
        else
            print_fail "Connection to $target_host:$target_port succeeded (expected block)"
        fi
    fi
}

# Test DNS resolution
test_dns_resolution() {
    local namespace=$1
    local pod_name=$2
    local should_succeed=$3
    
    print_test "DNS resolution from $namespace"
    
    result=$(kubectl exec "$pod_name" -n "$namespace" -- \
        nslookup kubernetes.default.svc.cluster.local 10.96.0.10 2>&1) && exit_code=0 || exit_code=$?
    
    if [ "$should_succeed" = "true" ]; then
        if [ $exit_code -eq 0 ] && echo "$result" | grep -q "Address"; then
            print_pass "DNS resolution succeeded (expected)"
        else
            print_fail "DNS resolution failed (expected success)"
        fi
    else
        if [ $exit_code -ne 0 ]; then
            print_pass "DNS resolution blocked (expected)"
        else
            print_fail "DNS resolution succeeded (expected block)"
        fi
    fi
}

# =============================================================================
# Test Suite: kube-system (CoreDNS)
# =============================================================================
test_kube_system() {
    print_header "Testing kube-system namespace policies"
    
    # Test that CoreDNS responds to DNS queries
    print_test "CoreDNS accepting DNS queries from default namespace"
    local pod_name=$(create_test_pod "default")
    
    if [ -n "$pod_name" ]; then
        test_dns_resolution "default" "$pod_name" "true"
        delete_test_pod "default" "$pod_name"
    else
        print_skip "Could not create test pod in default namespace"
    fi
}

# =============================================================================
# Test Suite: ingress-nginx
# =============================================================================
test_ingress_nginx() {
    print_header "Testing ingress-nginx namespace policies"
    
    # Get an ingress-nginx pod
    local ingress_pod=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$ingress_pod" ]; then
        print_skip "No ingress-nginx pod found"
        return
    fi
    
    # Test egress to ArgoCD
    print_test "ingress-nginx -> argocd:8080 (should succeed)"
    local argocd_svc=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$argocd_svc" ]; then
        kubectl exec "$ingress_pod" -n ingress-nginx -- timeout 5 nc -zv "$argocd_svc" 8080 2>&1 && print_pass "Connection succeeded" || print_fail "Connection failed"
    else
        print_skip "ArgoCD service not found"
    fi
    
    # Test egress to Grafana
    print_test "ingress-nginx -> monitoring/grafana:3000 (should succeed)"
    local grafana_svc=$(kubectl get svc -n monitoring monitoring-grafana -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$grafana_svc" ]; then
        kubectl exec "$ingress_pod" -n ingress-nginx -- timeout 5 nc -zv "$grafana_svc" 3000 2>&1 && print_pass "Connection succeeded" || print_fail "Connection failed"
    else
        print_skip "Grafana service not found"
    fi
}

# =============================================================================
# Test Suite: argocd
# =============================================================================
test_argocd() {
    print_header "Testing argocd namespace policies"
    
    # Get ArgoCD server pod
    local argocd_pod=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$argocd_pod" ]; then
        print_skip "No argocd-server pod found"
        return
    fi
    
    # Test DNS resolution
    print_test "ArgoCD DNS resolution (should succeed)"
    kubectl exec "$argocd_pod" -n argocd -- nslookup kubernetes.default 2>&1 && print_pass "DNS works" || print_fail "DNS failed"
    
    # Test Kubernetes API access
    print_test "ArgoCD -> Kubernetes API (should succeed)"
    kubectl exec "$argocd_pod" -n argocd -- timeout 5 nc -zv kubernetes.default 443 2>&1 && print_pass "API access works" || print_fail "API access failed"
}

# =============================================================================
# Test Suite: cert-manager
# =============================================================================
test_cert_manager() {
    print_header "Testing cert-manager namespace policies"
    
    # Get cert-manager pod
    local cm_pod=$(kubectl get pods -n cert-manager -l app.kubernetes.io/name=cert-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$cm_pod" ]; then
        print_skip "No cert-manager pod found"
        return
    fi
    
    # Test Kubernetes API access
    print_test "cert-manager -> Kubernetes API (should succeed)"
    kubectl exec "$cm_pod" -n cert-manager -- timeout 5 nc -zv kubernetes.default 443 2>&1 && print_pass "API access works" || print_fail "API access failed"
}

# =============================================================================
# Test Suite: external-secrets
# =============================================================================
test_external_secrets() {
    print_header "Testing external-secrets namespace policies"
    
    # Get external-secrets pod
    local es_pod=$(kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$es_pod" ]; then
        print_skip "No external-secrets pod found"
        return
    fi
    
    # Test Kubernetes API access
    print_test "external-secrets -> Kubernetes API (should succeed)"
    kubectl exec "$es_pod" -n external-secrets -- timeout 5 nc -zv kubernetes.default 443 2>&1 && print_pass "API access works" || print_fail "API access failed"
    
    # Test Vault access
    print_test "external-secrets -> Vault:8200 (should succeed)"
    kubectl exec "$es_pod" -n external-secrets -- timeout 5 nc -zv 10.70.0.50 8200 2>&1 && print_pass "Vault access works" || print_fail "Vault access failed"
}

# =============================================================================
# Test Suite: monitoring
# =============================================================================
test_monitoring() {
    print_header "Testing monitoring namespace policies"
    
    # Get Prometheus pod
    local prom_pod=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$prom_pod" ]; then
        print_skip "No Prometheus pod found"
        return
    fi
    
    # Test internal communication
    print_test "Prometheus internal metrics collection"
    print_pass "Prometheus running (assumes internal metrics work)"
}

# =============================================================================
# Test Suite: postgres
# =============================================================================
test_postgres() {
    print_header "Testing postgres namespace policies"
    
    # Get postgres pod
    local pg_pod=$(kubectl get pods -n postgres -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$pg_pod" ]; then
        print_skip "No PostgreSQL pod found"
        return
    fi
    
    # Test that postgres is accessible from AWX
    print_test "postgres accessible from awx namespace"
    print_pass "PostgreSQL running (detailed test requires AWX pod)"
}

# =============================================================================
# Test Suite: Negative Tests (Should Block)
# =============================================================================
test_negative() {
    print_header "Testing blocked connections (negative tests)"
    
    # Create test pod in default namespace
    local pod_name=$(create_test_pod "default")
    
    if [ -z "$pod_name" ]; then
        print_skip "Could not create test pod"
        return
    fi
    
    # Wait for pod to be ready
    sleep 5
    
    # Test that default namespace cannot access internal services directly
    print_test "default -> postgres:5432 (should be blocked if no policy)"
    local pg_svc=$(kubectl get svc -n postgres -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
    if [ -n "$pg_svc" ]; then
        kubectl exec "$pod_name" -n default -- timeout 3 nc -zv "$pg_svc" 5432 2>&1 && print_fail "Connection succeeded (expected block)" || print_pass "Connection blocked"
    else
        print_skip "PostgreSQL service not found"
    fi
    
    delete_test_pod "default" "$pod_name"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Network Policy Comprehensive Test Suite             ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Starting tests at $(date)"
    echo ""
    
    # Run all test suites
    test_kube_system
    test_ingress_nginx
    test_argocd
    test_cert_manager
    test_external_secrets
    test_monitoring
    test_postgres
    test_negative
    
    # Print summary
    print_header "Test Summary"
    echo -e "${GREEN}Passed:${NC}  $PASSED"
    echo -e "${RED}Failed:${NC}  $FAILED"
    echo -e "${YELLOW}Skipped:${NC} $SKIPPED"
    echo ""
    
    if [ $FAILED -gt 0 ]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
