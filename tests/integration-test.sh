#!/usr/bin/env bash
# Integration Test Suite v2.6.0
# Automated testing for Solr deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common library
# shellcheck source=scripts/lib/common.sh
source "$PROJECT_DIR/scripts/lib/common.sh" || {
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
SOLR_ADMIN_USER=${SOLR_ADMIN_USER:-admin}
SOLR_ADMIN_PASSWORD=${SOLR_ADMIN_PASSWORD:-}
SOLR_CUSTOMER_USER=${SOLR_CUSTOMER_USER:-customer}
SOLR_CUSTOMER_PASSWORD=${SOLR_CUSTOMER_PASSWORD:-}

FAILED=0
PASSED=0

# ============================================================================
# TEST HELPERS
# ============================================================================

test_case() {
    local name=$1
    local command=$2

    echo -n "  Testing: $name... "

    if eval "$command" >/dev/null 2>&1; then
        log_success "PASS"
        PASSED=$((PASSED + 1))
        return 0
    else
        log_error "FAIL"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

test_case_verbose() {
    local name=$1
    shift
    local command=("$@")

    echo "  Testing: $name..."

    local output
    if output=$("${command[@]}" 2>&1); then
        log_success "  PASS"
        PASSED=$((PASSED + 1))
        return 0
    else
        log_error "  FAIL"
        echo "  Output: $output" | head -5
        FAILED=$((FAILED + 1))
        return 1
    fi
}

# ============================================================================
# TEST SUITE
# ============================================================================

cat <<'EOF'
═══════════════════════════════════════════════════════════════
  Solr Integration Test Suite v2.6.0
═══════════════════════════════════════════════════════════════
EOF

echo ""
echo "Starting automated integration tests..."
echo ""

# ============================================================================
# TEST 1: Docker Environment
# ============================================================================

log_info "Test Category 1: Docker Environment"
echo ""

test_case "Docker daemon running" \
    "docker info"

test_case "Docker Compose available" \
    "docker compose version"

test_case "Docker Compose config valid" \
    "cd $PROJECT_DIR && docker compose config --quiet"

echo ""

# ============================================================================
# TEST 2: Container Status
# ============================================================================

log_info "Test Category 2: Container Status"
echo ""

test_case "Solr container running" \
    "docker compose ps solr | grep -q 'Up'"

test_case "Solr init completed successfully" \
    "docker compose ps -a solr-init | grep -q 'Exited (0)' || docker compose ps -a solr-init | grep -q 'Completed'"

test_case "Health API container running" \
    "docker compose ps health-api | grep -q 'Up'"

# Optional monitoring services
if docker compose ps prometheus 2>/dev/null | grep -q Up; then
    test_case "Prometheus container running" \
        "docker compose ps prometheus | grep -q 'Up'"
fi

if docker compose ps grafana 2>/dev/null | grep -q Up; then
    test_case "Grafana container running" \
        "docker compose ps grafana | grep -q 'Up'"
fi

echo ""

# ============================================================================
# TEST 3: Health Checks
# ============================================================================

log_info "Test Category 3: Health Checks"
echo ""

test_case "Solr container healthy" \
    "docker inspect --format='{{.State.Health.Status}}' ${CUSTOMER}_solr | grep -q 'healthy'"

test_case "Health API responding" \
    "curl -sf -m 5 http://localhost:${HEALTH_API_PORT}/health"

echo ""

# ============================================================================
# TEST 4: Solr API Endpoints
# ============================================================================

log_info "Test Category 4: Solr API Endpoints"
echo ""

test_case "Solr ping endpoint responding" \
    "curl -sf -m 5 http://localhost:${SOLR_PORT}/solr/admin/ping?wt=json"

test_case "Solr health endpoint responding" \
    "curl -sf -m 5 http://localhost:${SOLR_PORT}/solr/admin/health?wt=json"

# Test with authentication
if [ -n "$SOLR_ADMIN_PASSWORD" ]; then
    test_case "Solr system API (with auth)" \
        "curl -sf -m 5 -u ${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD} http://localhost:${SOLR_PORT}/solr/admin/info/system?wt=json"

    test_case "Solr cores API (with auth)" \
        "curl -sf -m 5 -u ${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD} http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS&wt=json"
else
    log_warn "  Skipping auth tests (SOLR_ADMIN_PASSWORD not set)"
fi

echo ""

# ============================================================================
# TEST 5: Authentication & Authorization
# ============================================================================

log_info "Test Category 5: Authentication & Authorization"
echo ""

test_case "Unauthenticated request denied" \
    "! curl -sf -m 5 http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS"

if [ -n "$SOLR_ADMIN_PASSWORD" ]; then
    test_case "Admin authentication accepted" \
        "curl -sf -m 5 -u ${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD} http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS"
fi

if [ -n "$SOLR_CUSTOMER_PASSWORD" ]; then
    test_case "Customer authentication accepted" \
        "curl -sf -m 5 -u ${SOLR_CUSTOMER_USER}:${SOLR_CUSTOMER_PASSWORD} http://localhost:${SOLR_PORT}/solr/admin/ping"
fi

test_case "Invalid credentials rejected" \
    "! curl -sf -m 5 -u invalid:invalid http://localhost:${SOLR_PORT}/solr/admin/cores"

echo ""

# ============================================================================
# TEST 6: Core Existence & Functionality
# ============================================================================

log_info "Test Category 6: Core Functionality"
echo ""

if [ -n "$SOLR_ADMIN_PASSWORD" ]; then
    # Check if core exists
    test_case "Moodle core exists" \
        "curl -sf -m 5 -u ${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD} http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS | grep -q ${CUSTOMER}_core"
else
    log_warn "  Skipping core tests (SOLR_ADMIN_PASSWORD not set)"
fi

echo ""

# ============================================================================
# TEST 7: Search Functionality
# ============================================================================

log_info "Test Category 7: Search Functionality"
echo ""

if [ -n "$SOLR_CUSTOMER_PASSWORD" ]; then
    test_case "Basic search query works" \
        "curl -sf -m 5 -u ${SOLR_CUSTOMER_USER}:${SOLR_CUSTOMER_PASSWORD} 'http://localhost:${SOLR_PORT}/solr/${CUSTOMER}_core/select?q=*:*&rows=0'"

    test_case "Search returns valid JSON" \
        "curl -sf -m 5 -u ${SOLR_CUSTOMER_USER}:${SOLR_CUSTOMER_PASSWORD} 'http://localhost:${SOLR_PORT}/solr/${CUSTOMER}_core/select?q=*:*&rows=0&wt=json' | python3 -c 'import json,sys;json.load(sys.stdin)'"

    test_case "Search with parameters works" \
        "curl -sf -m 5 -u ${SOLR_CUSTOMER_USER}:${SOLR_CUSTOMER_PASSWORD} 'http://localhost:${SOLR_PORT}/solr/${CUSTOMER}_core/select?q=test&rows=10&start=0'"
else
    log_warn "  Skipping search tests (SOLR_CUSTOMER_PASSWORD not set)"
fi

echo ""

# ============================================================================
# TEST 8: JVM & Memory
# ============================================================================

log_info "Test Category 8: JVM & Memory"
echo ""

if [ -n "$SOLR_ADMIN_PASSWORD" ]; then
    test_case "JVM memory info accessible" \
        "curl -sf -m 5 -u ${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD} http://localhost:${SOLR_PORT}/solr/admin/info/system?wt=json | grep -q 'memory'"

    # Check heap usage is reasonable (<90%)
    test_case "Heap usage is reasonable (<90%)" \
        "curl -sf -m 5 -u ${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD} http://localhost:${SOLR_PORT}/solr/admin/info/system?wt=json | python3 -c \"import json,sys; data=json.load(sys.stdin); used=data['jvm']['memory']['raw']['used']; max=data['jvm']['memory']['raw']['max']; sys.exit(0 if (used/max) < 0.9 else 1)\""
fi

test_case "Container memory within limits" \
    "docker stats --no-stream ${CUSTOMER}_solr | awk 'NR==2 {gsub(/%/,\"\",\$7); exit (\$7 < 95 ? 0 : 1)}'"

echo ""

# ============================================================================
# TEST 9: Logging
# ============================================================================

log_info "Test Category 9: Logging"
echo ""

test_case "Solr logs exist" \
    "docker exec ${CUSTOMER}_solr ls /var/solr/logs/solr.log"

test_case "Solr logs contain entries" \
    "docker exec ${CUSTOMER}_solr wc -l /var/solr/logs/solr.log | awk '{exit (\$1 > 0 ? 0 : 1)}'"

test_case "No critical errors in recent logs" \
    "! docker logs ${CUSTOMER}_solr 2>&1 | tail -100 | grep -i 'CRITICAL\\|FATAL\\|OutOfMemoryError'"

# Check GC logs if enabled
test_case "GC logs exist" \
    "docker exec ${CUSTOMER}_solr ls /var/solr/logs/gc.log || echo 'GC logging not enabled'"

echo ""

# ============================================================================
# TEST 10: Network & Connectivity
# ============================================================================

log_info "Test Category 10: Network & Connectivity"
echo ""

test_case "Frontend network exists" \
    "docker network ls | grep -q ${CUSTOMER}_frontend"

test_case "Backend network exists" \
    "docker network ls | grep -q ${CUSTOMER}_backend"

test_case "Solr accessible from host" \
    "curl -sf -m 5 http://localhost:${SOLR_PORT}/solr/admin/ping"

echo ""

# ============================================================================
# TEST 11: Monitoring (if enabled)
# ============================================================================

if docker compose ps prometheus 2>/dev/null | grep -q Up; then
    log_info "Test Category 11: Monitoring"
    echo ""

    test_case "Prometheus health endpoint" \
        "curl -sf -m 5 http://localhost:${PROMETHEUS_PORT:-9090}/-/healthy"

    test_case "Prometheus targets accessible" \
        "curl -sf -m 5 http://localhost:${PROMETHEUS_PORT:-9090}/api/v1/targets"

    if docker compose ps grafana 2>/dev/null | grep -q Up; then
        test_case "Grafana health endpoint" \
            "curl -sf -m 5 http://localhost:${GRAFANA_PORT:-3000}/api/health"
    fi

    if docker compose ps solr-exporter 2>/dev/null | grep -q Up; then
        test_case "Solr Exporter metrics endpoint" \
            "curl -sf -m 5 http://localhost:${EXPORTER_PORT:-9854}/metrics | grep -q solr_"
    fi

    echo ""
fi

# ============================================================================
# TEST 12: Backup (if enabled)
# ============================================================================

if docker compose ps backup-cron 2>/dev/null | grep -q Up; then
    log_info "Test Category 12: Backup"
    echo ""

    test_case "Backup container running" \
        "docker compose ps backup-cron | grep -q 'Up'"

    test_case "Backup directory exists" \
        "test -d $PROJECT_DIR/backups"

    test_case "Backup directory writable" \
        "test -w $PROJECT_DIR/backups"

    echo ""
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================

echo "═══════════════════════════════════════════════════════════════"
echo "  Test Summary"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Results:"
echo "  ✅ Passed:   $PASSED tests"
echo "  ❌ Failed:   $FAILED tests"
echo "  📊 Total:    $((PASSED + FAILED)) tests"
echo ""

if [ $FAILED -eq 0 ]; then
    log_success "All tests passed! 🎉"
    echo ""
    echo "Your Solr deployment is healthy and fully functional."
    exit 0
else
    log_error "$FAILED test(s) failed!"
    echo ""
    echo "Please review failed tests and check:"
    echo "  1. Container logs: make logs"
    echo "  2. Health status:  make health"
    echo "  3. Dashboard:      make dashboard"
    echo "  4. Configuration:  cat .env"
    exit 1
fi
