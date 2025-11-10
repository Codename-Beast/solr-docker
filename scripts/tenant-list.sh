#!/bin/bash

###############################################################################
# Tenant List Script
# Lists all tenants with their cores, users, and statistics
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo -e "${RED}❌ Error: .env file not found.${NC}"
    exit 1
fi

###############################################################################
# Helper Functions
###############################################################################

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

###############################################################################
# Core Detection
###############################################################################

get_all_cores() {
    docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&wt=json" | \
        jq -r '.status | keys[]' 2>/dev/null || echo ""
}

get_tenant_cores() {
    # Filter cores that match multi-tenant pattern (moodle_*)
    get_all_cores | grep '^moodle_' || true
}

extract_tenant_id() {
    local core_name=$1
    # Extract tenant ID from core name (moodle_tenant1 -> tenant1)
    echo "$core_name" | sed 's/^moodle_//'
}

###############################################################################
# Core Statistics
###############################################################################

get_core_stats() {
    local core_name=$1

    # Get core statistics from Solr
    local stats
    stats=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/admin/luke?wt=json&numTerms=0" 2>/dev/null || echo "{}")

    # Extract document count
    local num_docs
    num_docs=$(echo "$stats" | jq -r '.index.numDocs // 0' 2>/dev/null || echo "0")

    # Get index size
    local index_path
    index_path=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&core=${core_name}&wt=json" 2>/dev/null | \
        jq -r ".status.\"${core_name}\".index.sizeInBytes // 0" 2>/dev/null || echo "0")

    # Convert bytes to MB
    local size_mb
    size_mb=$(awk "BEGIN {printf \"%.1f\", $index_path / 1024 / 1024}")

    echo "${num_docs}|${size_mb}"
}

###############################################################################
# User Detection
###############################################################################

get_tenant_user() {
    local tenant_id=$1
    local username="${tenant_id}_customer"

    # Check if user exists in security.json
    if docker compose exec -T solr cat /var/solr/data/security.json | \
        jq -e ".authentication.credentials.\"${username}\"" > /dev/null 2>&1; then
        echo "$username"
    else
        echo "N/A"
    fi
}

###############################################################################
# Health Check
###############################################################################

check_core_health() {
    local core_name=$1

    # Try to query the core
    if docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/select?q=*:*&rows=0" > /dev/null 2>&1; then
        echo "✅ Healthy"
    else
        echo "❌ Error"
    fi
}

###############################################################################
# Display Functions
###############################################################################

format_number() {
    local num=$1
    printf "%'d" "$num" 2>/dev/null || echo "$num"
}

print_table_header() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                  Active Tenants                                        ║"
    echo "╚════════════════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    printf "%-15s %-20s %-20s %-12s %-10s %-15s\n" \
        "TENANT ID" "CORE NAME" "USER ACCOUNT" "DOCUMENTS" "SIZE (MB)" "STATUS"
    echo "────────────────────────────────────────────────────────────────────────────────────────"
}

print_tenant_row() {
    local tenant_id=$1
    local core_name=$2
    local username=$3
    local num_docs=$4
    local size_mb=$5
    local status=$6

    printf "%-15s %-20s %-20s %-12s %-10s %-15s\n" \
        "$tenant_id" "$core_name" "$username" "$(format_number "$num_docs")" "$size_mb" "$status"
}

print_summary() {
    local total_tenants=$1
    local total_docs=$2
    local total_size=$3

    echo "────────────────────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "📊 Summary:"
    echo "   Total Tenants:    ${total_tenants}"
    echo "   Total Documents:  $(format_number "$total_docs")"
    echo "   Total Size:       ${total_size} MB"
    echo ""
}

###############################################################################
# Detailed View
###############################################################################

print_detailed_view() {
    local tenant_id=$1
    local core_name=$2

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Tenant Details: ${tenant_id}"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Core information
    local core_info
    core_info=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&core=${core_name}&wt=json" 2>/dev/null || echo "{}")

    echo "🗃️  Core Information:"
    echo "   Name:         ${core_name}"
    echo "   Instance Dir: $(echo "$core_info" | jq -r ".status.\"${core_name}\".instanceDir // \"N/A\"")"
    echo "   Data Dir:     $(echo "$core_info" | jq -r ".status.\"${core_name}\".dataDir // \"N/A\"")"
    echo "   Start Time:   $(echo "$core_info" | jq -r ".status.\"${core_name}\".startTime // \"N/A\"" | cut -d'T' -f1)"
    echo ""

    # Index statistics
    local stats
    stats=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/admin/luke?wt=json&numTerms=0" 2>/dev/null || echo "{}")

    echo "📈 Index Statistics:"
    echo "   Documents:       $(format_number "$(echo "$stats" | jq -r '.index.numDocs // 0')")"
    echo "   Deleted Docs:    $(format_number "$(echo "$stats" | jq -r '.index.deletedDocs // 0')")"
    echo "   Unique Fields:   $(echo "$stats" | jq -r '.index.numFields // 0')"
    echo "   Index Version:   $(echo "$stats" | jq -r '.index.version // "N/A"')"
    echo ""

    # User information
    local username
    username=$(get_tenant_user "$tenant_id")

    echo "👤 User Account:"
    echo "   Username:     ${username}"
    if [ "$username" != "N/A" ]; then
        local role
        role=$(docker compose exec -T solr cat /var/solr/data/security.json | \
            jq -r ".authorization.\"user-role\".\"${username}\" // []" 2>/dev/null | jq -r '.[]')
        echo "   Role:         ${role:-N/A}"
        echo "   Credentials:  .env.${tenant_id}"
    fi
    echo ""

    # Connection test
    echo "🔌 Connection Test:"
    if [ "$username" != "N/A" ] && [ -f "$PROJECT_ROOT/.env.${tenant_id}" ]; then
        # shellcheck disable=SC1090
        source "$PROJECT_ROOT/.env.${tenant_id}"
        if curl -sf -u "${TENANT_USER}:${TENANT_PASSWORD}" \
            "http://localhost:${SOLR_PORT}/solr/${core_name}/select?q=*:*&rows=0" > /dev/null 2>&1; then
            echo "   Status:       ✅ Can connect and query"
        else
            echo "   Status:       ❌ Connection failed"
        fi
    else
        echo "   Status:       ⚠️  Credentials file not found"
    fi
    echo ""
}

###############################################################################
# Main Function
###############################################################################

main() {
    local detailed=${1:-}

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        Solr Multi-Tenancy: List Tenants                    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Get all tenant cores
    local cores
    cores=$(get_tenant_cores)

    if [ -z "$cores" ]; then
        log_warning "No multi-tenant cores found"
        echo ""
        echo "Cores matching pattern 'moodle_*' are considered tenants."
        echo "To create a tenant, run: make tenant-create TENANT=<tenant_id>"
        echo ""

        # Check for single-tenant core
        local all_cores
        all_cores=$(get_all_cores)
        if echo "$all_cores" | grep -q '^moodle$'; then
            log_info "Found single-tenant core: 'moodle' (not multi-tenant)"
        fi
        exit 0
    fi

    # Count tenants
    local total_tenants
    total_tenants=$(echo "$cores" | wc -l)

    # Detailed view for single tenant
    if [ "$detailed" = "--detailed" ] || [ "$total_tenants" -eq 1 ]; then
        local core_name
        core_name=$(echo "$cores" | head -n1)
        local tenant_id
        tenant_id=$(extract_tenant_id "$core_name")
        print_detailed_view "$tenant_id" "$core_name"
        exit 0
    fi

    # Table view for multiple tenants
    print_table_header

    local total_docs=0
    local total_size=0

    while IFS= read -r core_name; do
        local tenant_id
        tenant_id=$(extract_tenant_id "$core_name")

        local username
        username=$(get_tenant_user "$tenant_id")

        local stats
        stats=$(get_core_stats "$core_name")
        local num_docs
        num_docs=$(echo "$stats" | cut -d'|' -f1)
        local size_mb
        size_mb=$(echo "$stats" | cut -d'|' -f2)

        local status
        status=$(check_core_health "$core_name")

        print_tenant_row "$tenant_id" "$core_name" "$username" "$num_docs" "$size_mb" "$status"

        total_docs=$((total_docs + num_docs))
        total_size=$(awk "BEGIN {printf \"%.1f\", $total_size + $size_mb}")
    done <<< "$cores"

    print_summary "$total_tenants" "$total_docs" "$total_size"

    echo "💡 Tips:"
    echo "   - View details:     ./scripts/tenant-list.sh --detailed"
    echo "   - Create tenant:    make tenant-create TENANT=<tenant_id>"
    echo "   - Delete tenant:    make tenant-delete TENANT=<tenant_id> BACKUP=true"
    echo "   - Backup tenant:    make tenant-backup TENANT=<tenant_id>"
    echo ""
}

main "$@"
