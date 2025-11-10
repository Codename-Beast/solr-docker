#!/usr/bin/env bash
# Solr Health Dashboard v2.6.0
# Shows comprehensive status of all services at a glance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common library
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "Error: Failed to load common.sh library"
    exit 1
}

# Load environment
load_env "$PROJECT_DIR/.env" 2>/dev/null || true

# ============================================================================
# CONFIGURATION
# ============================================================================

CUSTOMER=${CUSTOMER_NAME:-default}
SOLR_PORT=${SOLR_PORT:-8983}
HEALTH_API_PORT=${HEALTH_API_PORT:-8888}
GRAFANA_PORT=${GRAFANA_PORT:-3000}
PROMETHEUS_PORT=${PROMETHEUS_PORT:-9090}

# Colors
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_header() {
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}$1${NC}"
    echo "───────────────────────────────────────────────────────────────"
}

# ============================================================================
# STATUS FUNCTIONS
# ============================================================================

get_container_status() {
    print_section "📦 Container Status"

    if ! docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null; then
        log_error "No containers running or docker-compose.yml not found"
        return 1
    fi
}

get_health_status() {
    print_section "🏥 Health Checks"

    local containers
    containers=$(docker compose ps -q 2>/dev/null | tr '\n' ' ')

    if [ -z "$containers" ]; then
        log_warn "No containers running"
        return
    fi

    for container in $containers; do
        local name
        name=$(docker inspect --format='{{.Name}}' "$container" 2>/dev/null | sed 's/\///')

        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

        if [ "$health" != "none" ]; then
            case $health in
                healthy)
                    echo -e "  ${GREEN}✅${NC} $name: $health"
                    ;;
                starting)
                    echo -e "  ${YELLOW}⏳${NC} $name: $health"
                    ;;
                unhealthy)
                    echo -e "  ${RED}❌${NC} $name: $health"
                    ;;
                *)
                    echo -e "  ${BLUE}❓${NC} $name: $health"
                    ;;
            esac
        else
            # Check if container is running (no healthcheck defined)
            local state
            state=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "false")

            if [ "$state" = "true" ]; then
                echo -e "  ${GREEN}✅${NC} $name: running (no healthcheck)"
            else
                echo -e "  ${RED}❌${NC} $name: not running"
            fi
        fi
    done
}

get_resource_usage() {
    print_section "💻 Resource Usage"

    local containers
    containers=$(docker compose ps -q 2>/dev/null | tr '\n' ' ')

    if [ -z "$containers" ]; then
        log_warn "No containers running"
        return
    fi

    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}" \
        $containers 2>/dev/null || log_error "Failed to get resource stats"
}

get_api_status() {
    print_section "🌐 API Health Checks"

    # Health API
    if curl -sf -m 2 "http://localhost:${HEALTH_API_PORT}/health" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅${NC} Health API: http://localhost:${HEALTH_API_PORT}/health"
    else
        echo -e "  ${RED}❌${NC} Health API: Not responding"
    fi

    # Solr Admin
    if curl -sf -m 2 "http://localhost:${SOLR_PORT}/solr/admin/ping" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅${NC} Solr Admin: http://localhost:${SOLR_PORT}/solr/"
    else
        echo -e "  ${RED}❌${NC} Solr Admin: Not responding"
    fi

    # Grafana (if running)
    if docker compose ps grafana 2>/dev/null | grep -q Up; then
        if curl -sf -m 2 "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅${NC} Grafana: http://localhost:${GRAFANA_PORT}"
        else
            echo -e "  ${RED}❌${NC} Grafana: Not responding"
        fi
    fi

    # Prometheus (if running)
    if docker compose ps prometheus 2>/dev/null | grep -q Up; then
        if curl -sf -m 2 "http://localhost:${PROMETHEUS_PORT}/-/healthy" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅${NC} Prometheus: http://localhost:${PROMETHEUS_PORT}"
        else
            echo -e "  ${RED}❌${NC} Prometheus: Not responding"
        fi
    fi
}

get_system_info() {
    print_section "📊 System Information"

    # Disk usage
    local disk_usage
    disk_usage=$(df -h "$PROJECT_DIR" 2>/dev/null | tail -1)

    echo "  Disk Space:"
    echo "    $(echo "$disk_usage" | awk '{print "Available: " $4 ", Used: " $3 " (" $5 ")"}')"

    # Docker volumes
    echo ""
    echo "  Docker Volumes:"
    docker volume ls --format "    {{.Name}}: {{.Driver}}" 2>/dev/null | grep "^    ${CUSTOMER}" || echo "    None found for customer: $CUSTOMER"

    # Network
    echo ""
    echo "  Docker Networks:"
    docker network ls --format "    {{.Name}}: {{.Driver}}" 2>/dev/null | grep "^    ${CUSTOMER}" || echo "    None found for customer: $CUSTOMER"
}

get_recent_logs() {
    print_section "📝 Recent Log Events (Last 10 lines per service)"

    local services=("solr" "health-api")

    # Add monitoring services if running
    if docker compose ps grafana 2>/dev/null | grep -q Up; then
        services+=("grafana")
    fi
    if docker compose ps prometheus 2>/dev/null | grep -q Up; then
        services+=("prometheus")
    fi

    for service in "${services[@]}"; do
        if docker compose ps "$service" 2>/dev/null | grep -q Up; then
            echo ""
            echo "  ▶ $service:"
            docker compose logs --tail=5 "$service" 2>/dev/null | sed 's/^/    /' || echo "    (no logs)"
        fi
    done
}

get_quick_metrics() {
    print_section "📈 Quick Metrics"

    # Try to get Solr metrics
    local admin_user=${SOLR_ADMIN_USER:-admin}
    local admin_pass=${SOLR_ADMIN_PASSWORD:-}

    if [ -n "$admin_pass" ]; then
        # Get core status
        local core_status
        if core_status=$(curl -sf -u "$admin_user:$admin_pass" \
            "http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS&wt=json" 2>/dev/null); then

            echo "  Solr Cores:"
            echo "$core_status" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    cores = data.get('status', {})
    if not cores:
        print('    No cores found')
    else:
        for core_name, core_info in cores.items():
            docs = core_info.get('index', {}).get('numDocs', 'N/A')
            size_bytes = core_info.get('index', {}).get('sizeInBytes', 0)
            size_mb = size_bytes / 1024 / 1024 if size_bytes else 0
            print(f'    ✓ {core_name}: {docs:,} docs, {size_mb:.2f} MB')
except Exception as e:
    print(f'    Error parsing: {e}')
" 2>/dev/null || echo "    (parsing error)"
        else
            echo "  Solr Cores: (authentication required or Solr not responding)"
        fi

        # Get JVM memory
        local jvm_info
        if jvm_info=$(curl -sf -u "$admin_user:$admin_pass" \
            "http://localhost:${SOLR_PORT}/solr/admin/info/system?wt=json" 2>/dev/null); then

            echo ""
            echo "  JVM Memory:"
            echo "$jvm_info" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    mem = data.get('jvm', {}).get('memory', {}).get('raw', {})
    used_mb = mem.get('used', 0) / 1024 / 1024
    max_mb = mem.get('max', 0) / 1024 / 1024
    percent = (used_mb / max_mb * 100) if max_mb > 0 else 0
    print(f'    Used: {used_mb:.0f} MB / {max_mb:.0f} MB ({percent:.1f}%)')
except Exception as e:
    print(f'    Error parsing: {e}')
" 2>/dev/null || echo "    (parsing error)"
        fi
    else
        echo "  Solr Metrics: (credentials not set in .env)"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    clear

    print_header "Solr Health Dashboard v2.6.0"

    echo ""
    echo "Customer: ${CUSTOMER}"
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"

    get_container_status
    get_health_status
    get_resource_usage
    get_api_status
    get_quick_metrics
    get_system_info

    # Optional: Recent logs (can be verbose)
    if [ "${SHOW_LOGS:-false}" = "true" ]; then
        get_recent_logs
    fi

    echo ""
    print_header "Dashboard Complete"
    echo ""

    # Summary
    local running_containers
    running_containers=$(docker compose ps -q 2>/dev/null | wc -l)

    if [ "$running_containers" -gt 0 ]; then
        log_success "$running_containers container(s) running"
    else
        log_error "No containers running"
    fi

    echo ""
    echo "Tips:"
    echo "  - Run with logs:    SHOW_LOGS=true $0"
    echo "  - Watch mode:       watch -n 5 $0"
    echo "  - Detailed health:  make health"
    echo "  - View logs:        make logs"
    echo ""
}

main "$@"
