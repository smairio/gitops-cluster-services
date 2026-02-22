#!/bin/bash
# =============================================================================
# Elasticsearch Snapshot Utility Script
# =============================================================================
# Usage: ./snapshot-utils.sh <command>
#
# Commands:
#   list          - List all available snapshots
#   details       - Show details of a specific snapshot
#   restore       - Restore a snapshot with rename (safe)
#   restore-full  - Full restore (replaces existing data)
#   status        - Check restore progress
#   manual        - Trigger a manual snapshot
#   cleanup       - Delete restored data streams
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get Elasticsearch password
get_es_password() {
    kubectl get secret elk-es-elastic-user -n elastic-system \
        -o jsonpath='{.data.elastic}' | base64 -d
}

# Execute curl command inside ES pod
es_curl() {
    local method="${1:-GET}"
    local endpoint="$2"
    local data="$3"
    local ES_PASSWORD=$(get_es_password)
    
    if [ -n "$data" ]; then
        kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
            curl -sk -u "elastic:${ES_PASSWORD}" \
            -X "$method" "https://localhost:9200${endpoint}" \
            -H 'Content-Type: application/json' \
            -d "$data"
    else
        kubectl exec -n elastic-system elk-es-default-0 -c elasticsearch -- \
            curl -sk -u "elastic:${ES_PASSWORD}" \
            -X "$method" "https://localhost:9200${endpoint}"
    fi
}

# List all snapshots
cmd_list() {
    echo -e "${BLUE}=== Available Snapshots ===${NC}"
    echo ""
    es_curl GET "/_cat/snapshots/s3-backups?v&s=start_epoch:desc"
    echo ""
}

# Show snapshot details
cmd_details() {
    local snapshot="$1"
    if [ -z "$snapshot" ]; then
        echo -e "${YELLOW}Usage: $0 details <snapshot-name>${NC}"
        echo ""
        echo "Available snapshots:"
        es_curl GET "/_cat/snapshots/s3-backups?v&s=start_epoch:desc&h=id,status,start_time"
        exit 1
    fi
    
    echo -e "${BLUE}=== Snapshot Details: $snapshot ===${NC}"
    es_curl GET "/_snapshot/s3-backups/${snapshot}?pretty"
}

# Restore with rename (safe)
cmd_restore() {
    local snapshot="$1"
    local indices="${2:-filebeat-*,metricbeat-*}"
    
    if [ -z "$snapshot" ]; then
        echo -e "${YELLOW}Usage: $0 restore <snapshot-name> [indices]${NC}"
        echo ""
        echo "Examples:"
        echo "  $0 restore elk-snap-2026.02.17-xxx"
        echo "  $0 restore elk-snap-2026.02.17-xxx 'filebeat-*'"
        echo ""
        echo "Available snapshots:"
        es_curl GET "/_cat/snapshots/s3-backups?v&s=start_epoch:desc&h=id,status,start_time"
        exit 1
    fi
    
    echo -e "${GREEN}=== Restoring Snapshot: $snapshot ===${NC}"
    echo -e "${YELLOW}Restoring indices: $indices${NC}"
    echo -e "${YELLOW}Data will be prefixed with 'restored-'${NC}"
    echo ""
    
    es_curl POST "/_snapshot/s3-backups/${snapshot}/_restore?pretty" "{
        \"indices\": \"${indices}\",
        \"include_global_state\": false,
        \"rename_pattern\": \"(.+)\",
        \"rename_replacement\": \"restored-\$1\"
    }"
    
    echo ""
    echo -e "${GREEN}✓ Restore initiated! Check progress with: $0 status${NC}"
    echo -e "${YELLOW}→ Access data in Kibana using index pattern: restored-*${NC}"
}

# Full restore (replaces existing)
cmd_restore_full() {
    local snapshot="$1"
    local indices="${2:-filebeat-8.15.3,metricbeat-8.15.3}"
    
    if [ -z "$snapshot" ]; then
        echo -e "${YELLOW}Usage: $0 restore-full <snapshot-name> [data-streams]${NC}"
        exit 1
    fi
    
    echo -e "${RED}⚠️  WARNING: This will DELETE existing data streams!${NC}"
    echo -e "${YELLOW}Data streams to delete: $indices${NC}"
    read -p "Are you sure? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
    
    echo -e "${BLUE}Step 1: Stopping ILM...${NC}"
    es_curl POST "/_ilm/stop"
    echo ""
    
    echo -e "${BLUE}Step 2: Deleting existing data streams...${NC}"
    es_curl DELETE "/_data_stream/${indices}"
    echo ""
    
    echo -e "${BLUE}Step 3: Restoring from snapshot...${NC}"
    es_curl POST "/_snapshot/s3-backups/${snapshot}/_restore?pretty" "{
        \"indices\": \"${indices}\",
        \"include_global_state\": false
    }"
    echo ""
    
    echo -e "${BLUE}Step 4: Resuming ILM...${NC}"
    es_curl POST "/_ilm/start"
    echo ""
    
    echo -e "${GREEN}✓ Full restore complete!${NC}"
}

# Check restore status
cmd_status() {
    echo -e "${BLUE}=== Cluster Health ===${NC}"
    es_curl GET "/_cluster/health?pretty"
    echo ""
    
    echo -e "${BLUE}=== Active Recoveries ===${NC}"
    local recovery=$(es_curl GET "/_recovery?active_only=true&pretty")
    if [ "$recovery" == "{}" ]; then
        echo -e "${GREEN}No active recoveries - restore complete!${NC}"
    else
        echo "$recovery"
    fi
    echo ""
    
    echo -e "${BLUE}=== Data Streams ===${NC}"
    es_curl GET "/_cat/indices?v&s=index&h=index,health,docs.count,store.size"
}

# Trigger manual snapshot
cmd_manual() {
    echo -e "${BLUE}=== Triggering Manual Snapshot ===${NC}"
    es_curl POST "/_slm/policy/daily-snapshot/_execute?pretty"
    echo ""
    echo -e "${GREEN}✓ Snapshot triggered! Check status with: $0 list${NC}"
}

# Cleanup restored data
cmd_cleanup() {
    echo -e "${YELLOW}=== Restored Data Streams ===${NC}"
    es_curl GET "/_cat/indices/restored-*?v&h=index,docs.count,store.size"
    echo ""
    
    read -p "Delete all restored-* data streams? (yes/no): " confirm
    
    if [ "$confirm" == "yes" ]; then
        es_curl DELETE "/_data_stream/restored-*"
        echo ""
        echo -e "${GREEN}✓ Restored data streams deleted${NC}"
    else
        echo "Aborted."
    fi
}

# Help
cmd_help() {
    echo "Elasticsearch Snapshot Utility"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list                    List all available snapshots"
    echo "  details <snapshot>      Show details of a specific snapshot"
    echo "  restore <snapshot>      Restore with 'restored-' prefix (safe)"
    echo "  restore-full <snapshot> Full restore (deletes existing data)"
    echo "  status                  Check restore progress and cluster health"
    echo "  manual                  Trigger a manual snapshot now"
    echo "  cleanup                 Delete restored-* data streams"
    echo "  help                    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 details elk-snap-2026.02.17-xxx"
    echo "  $0 restore elk-snap-2026.02.17-xxx"
    echo "  $0 restore elk-snap-2026.02.17-xxx 'filebeat-*'"
    echo "  $0 status"
}

# Main
case "${1:-help}" in
    list)       cmd_list ;;
    details)    cmd_details "$2" ;;
    restore)    cmd_restore "$2" "$3" ;;
    restore-full) cmd_restore_full "$2" "$3" ;;
    status)     cmd_status ;;
    manual)     cmd_manual ;;
    cleanup)    cmd_cleanup ;;
    help|*)     cmd_help ;;
esac
