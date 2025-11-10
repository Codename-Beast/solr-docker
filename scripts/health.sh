#!/usr/bin/env bash
# Solr Health Check v2.3.0
# Comprehensive health check with retry logic

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common library
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "Error: Failed to load common.sh library"
    exit 1
}

# Setup error handling
setup_error_handling

# ============================================================================
# CONFIGURATION
# ============================================================================

# Load environment
load_env "$PROJECT_DIR/.env" 2>/dev/null || true

SOLR_PORT=${SOLR_PORT:-8983}
SOLR_BIND_IP=${SOLR_BIND_IP:-127.0.0.1}
SOLR_HOST="${SOLR_BIND_IP}:${SOLR_PORT}"
CUSTOMER_NAME=${CUSTOMER_NAME:-solr}

# Health check configuration
readonly CHECK_TIMEOUT=10
readonly CHECK_RETRIES=3
readonly CHECK_DELAY=2

# ============================================================================
# HEALTH CHECK FUNCTIONS
# ============================================================================

check_container_running() {
    log_info "Checking if Solr container is running..."

    if docker compose ps "${CUSTOMER_NAME}_solr" 2>/dev/null | grep -q "Up"; then
        log_success "Container is running"
        return 0
    else
        log_error "Solr container is not running"
        return 1
    fi
}

check_ping_endpoint() {
    log_info "Checking ping endpoint..."

    if retry_curl -sf "http://$SOLR_HOST/solr/admin/ping?wt=json" >/dev/null; then
        log_success "Ping endpoint responding"
        return 0
    else
        log_error "Ping endpoint not responding"
        return 1
    fi
}

check_system_api() {
    log_info "Checking system API..."

    if [ -z "$SOLR_ADMIN_USER" ] || [ -z "$SOLR_ADMIN_PASSWORD" ]; then
        log_warn "Admin credentials not set, skipping system API check"
        return 0
    fi

    if retry_curl -sf -u "$SOLR_ADMIN_USER:$SOLR_ADMIN_PASSWORD" \
        "http://$SOLR_HOST/solr/admin/info/system?wt=json" >/dev/null; then
        log_success "System API responding"
        return 0
    else
        log_error "System API not responding (check credentials)"
        return 1
    fi
}

check_health_api() {
    log_info "Checking Health API..."

    local health_port=${HEALTH_API_PORT:-8888}

    if retry_curl -sf "http://localhost:${health_port}/health" >/dev/null; then
        log_success "Health API responding"
        return 0
    else
        log_warn "Health API not responding (may not be deployed)"
        return 0  # Non-critical
    fi
}

get_detailed_health() {
    log_info "Fetching detailed health information..."

    local health_data
    if health_data=$(retry_curl -s "http://$SOLR_HOST/solr/admin/health?wt=json" 2>/dev/null); then
        if command -v python3 &>/dev/null; then
            echo "$health_data" | python3 -m json.tool 2>/dev/null || echo "$health_data"
        else
            echo "$health_data"
        fi
    else
        log_warn "Detailed health not available"
    fi
}

get_core_status() {
    log_info "Checking cores..."

    if [ -z "$SOLR_ADMIN_USER" ] || [ -z "$SOLR_ADMIN_PASSWORD" ]; then
        log_warn "Admin credentials not set, skipping core status check"
        return 0
    fi

    local cores_data
    if cores_data=$(retry_curl -sf -u "$SOLR_ADMIN_USER:$SOLR_ADMIN_PASSWORD" \
        "http://$SOLR_HOST/solr/admin/cores?action=STATUS&wt=json" 2>/dev/null); then

        if command -v python3 &>/dev/null; then
            echo "$cores_data" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    cores = data.get('status', {})
    if not cores:
        print('  No cores found')
    else:
        for core_name, core_info in cores.items():
            docs = core_info.get('index', {}).get('numDocs', 'N/A')
            size = core_info.get('index', {}).get('sizeInBytes', 'N/A')
            print(f'  ✓ {core_name}: {docs} documents, {size} bytes')
except Exception as e:
    print(f'  Error parsing core status: {e}')
" 2>/dev/null
        else
            echo "  (Python not available for parsing)"
        fi
    else
        log_warn "Unable to fetch core status"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo "=========================================="
    log_info "Solr Health Check v2.3.0"
    echo "=========================================="
    echo "Customer: $CUSTOMER_NAME"
    echo "Solr Host: $SOLR_HOST"
    echo ""

    local exit_code=0

    # Run all checks
    check_container_running || exit_code=1
    check_ping_endpoint || exit_code=1
    check_system_api || exit_code=1
    check_health_api  # Non-critical

    echo ""
    echo "=========================================="
    echo "Detailed Information:"
    echo "=========================================="

    get_detailed_health
    echo ""
    get_core_status

    echo ""
    echo "=========================================="
    if [ $exit_code -eq 0 ]; then
        log_success "Health check completed successfully"
    else
        log_error "Health check failed"
    fi
    echo "=========================================="

    exit $exit_code
}

main "$@"
