#!/bin/bash
# =============================================================================
# Test Ingress Connectivity
# =============================================================================
# This script tests all ingress endpoints to verify NetworkPolicies are correct
# =============================================================================

set -e

DOMAIN_BASE="dev.tests.software"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "  Ingress Connectivity Test"
echo "=============================================="
echo ""

declare -A services=(
  ["argo"]="ArgoCD"
  ["awx"]="AWX"
  ["kibana"]="Kibana"
  ["keycloak"]="Keycloak"
  ["grafana"]="Grafana"
  ["prometheus"]="Prometheus"
)

all_passed=true

for subdomain in "${!services[@]}"; do
  service="${services[$subdomain]}"
  url="https://${subdomain}.${DOMAIN_BASE}"
  
  printf "%-15s %-35s " "$service" "$url"
  
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$url" --max-time 10 2>/dev/null || echo "000")
  
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "303" ]]; then
    echo -e "${GREEN}✓ $HTTP_CODE${NC}"
  elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    # Auth required = service is up
    echo -e "${YELLOW}⚠ $HTTP_CODE (Auth Required)${NC}"
  elif [[ "$HTTP_CODE" == "000" ]]; then
    echo -e "${RED}✗ Connection Failed${NC}"
    all_passed=false
  else
    echo -e "${RED}✗ $HTTP_CODE${NC}"
    all_passed=false
  fi
done

echo ""
echo "=============================================="

if $all_passed; then
  echo -e "${GREEN}All ingress endpoints are accessible!${NC}"
  exit 0
else
  echo -e "${RED}Some ingress endpoints failed!${NC}"
  echo ""
  echo "Troubleshooting:"
  echo "  1. Check NetworkPolicies: kubectl get networkpolicies -A"
  echo "  2. Check ingress: kubectl get ingress -A"
  echo "  3. Check certificates: kubectl get certificates -A"
  exit 1
fi
