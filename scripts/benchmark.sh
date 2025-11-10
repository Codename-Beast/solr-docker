#!/usr/bin/env bash
# Performance Benchmark for Solr v3.1.0
# Measures baseline performance metrics for comparison

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

SOLR_PORT=${SOLR_PORT:-8983}
SOLR_HOST="localhost:${SOLR_PORT}"
CUSTOMER_NAME=${CUSTOMER_NAME:-default}
CORE_NAME="${CUSTOMER_NAME}_core"

# Benchmark configuration
WARMUP_QUERIES=${WARMUP_QUERIES:-100}
BENCHMARK_QUERIES=${BENCHMARK_QUERIES:-1000}
CONCURRENT_USERS=${CONCURRENT_USERS:-10}

# Results directory
RESULTS_DIR="$PROJECT_DIR/benchmark-results"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.txt"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_dependencies() {
    log_info "Checking dependencies..."

    # Check for Apache Bench (ab)
    if ! command -v ab &>/dev/null; then
        log_error "Apache Bench (ab) not found"
        log_info "Install: apt-get install apache2-utils (Debian/Ubuntu)"
        log_info "         yum install httpd-tools (RHEL/CentOS)"
        log_info "         brew install httpd (macOS)"
        exit 1
    fi

    # Check for curl
    if ! command -v curl &>/dev/null; then
        log_error "curl not found"
        exit 1
    fi

    # Check if jq is available (optional)
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - JSON parsing will be limited"
    fi

    log_success "All dependencies available"
}

check_solr_running() {
    log_info "Checking if Solr is running..."

    if ! curl -sf "http://${SOLR_HOST}/solr/admin/ping" >/dev/null 2>&1; then
        log_error "Solr is not running or not accessible"
        log_info "Start Solr: make start"
        exit 1
    fi

    log_success "Solr is running"
}

get_credentials() {
    if [ -z "${SOLR_CUSTOMER_USER:-}" ] || [ -z "${SOLR_CUSTOMER_PASSWORD:-}" ]; then
        log_error "Credentials not set in .env"
        log_info "Set SOLR_CUSTOMER_USER and SOLR_CUSTOMER_PASSWORD in .env"
        exit 1
    fi
}

# ============================================================================
# BENCHMARK FUNCTIONS
# ============================================================================

benchmark_ping() {
    log_info "Benchmark 1: Ping Endpoint"
    echo ""

    ab -n "$BENCHMARK_QUERIES" -c "$CONCURRENT_USERS" \
        "http://${SOLR_HOST}/solr/admin/ping" \
        2>&1 | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
}

benchmark_simple_query() {
    log_info "Benchmark 2: Simple Query (*:*)"
    echo ""

    local auth="${SOLR_CUSTOMER_USER}:${SOLR_CUSTOMER_PASSWORD}"
    local url="http://${SOLR_HOST}/solr/${CORE_NAME}/select?q=*:*&rows=10"

    ab -n "$BENCHMARK_QUERIES" -c "$CONCURRENT_USERS" \
        -A "$auth" \
        "$url" \
        2>&1 | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
}

benchmark_facet_query() {
    log_info "Benchmark 3: Facet Query"
    echo ""

    local auth="${SOLR_CUSTOMER_USER}:${SOLR_CUSTOMER_PASSWORD}"
    local url="http://${SOLR_HOST}/solr/${CORE_NAME}/select?q=*:*&rows=0&facet=true&facet.field=id"

    ab -n "$BENCHMARK_QUERIES" -c "$CONCURRENT_USERS" \
        -A "$auth" \
        "$url" \
        2>&1 | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
}

benchmark_search_query() {
    log_info "Benchmark 4: Search Query (with filter)"
    echo ""

    local auth="${SOLR_CUSTOMER_USER}:${SOLR_CUSTOMER_PASSWORD}"
    local url="http://${SOLR_HOST}/solr/${CORE_NAME}/select?q=test&fq=id:*&rows=20&sort=id+desc"

    ab -n "$BENCHMARK_QUERIES" -c "$CONCURRENT_USERS" \
        -A "$auth" \
        "$url" \
        2>&1 | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
}

measure_jvm_memory() {
    log_info "Measuring JVM Memory Usage..."
    echo ""

    local auth="${SOLR_ADMIN_USER:-admin}:${SOLR_ADMIN_PASSWORD}"

    if [ -z "${SOLR_ADMIN_PASSWORD:-}" ]; then
        log_warn "Admin password not set, skipping JVM metrics"
        return
    fi

    local jvm_info
    if jvm_info=$(curl -sf -u "$auth" "http://${SOLR_HOST}/solr/admin/info/system?wt=json" 2>/dev/null); then
        if command -v jq &>/dev/null; then
            echo "$jvm_info" | jq -r '
                "JVM Memory:",
                "  Heap Used:    \(.jvm.memory.raw.used / 1024 / 1024 | floor) MB",
                "  Heap Max:     \(.jvm.memory.raw.max / 1024 / 1024 | floor) MB",
                "  Heap %:       \((.jvm.memory.raw.used / .jvm.memory.raw.max * 100) | floor)%"
            ' | tee -a "$REPORT_FILE"
        else
            echo "JVM Info (JSON):" | tee -a "$REPORT_FILE"
            echo "$jvm_info" | tee -a "$REPORT_FILE"
        fi
    fi

    echo "" | tee -a "$REPORT_FILE"
}

measure_core_stats() {
    log_info "Measuring Core Statistics..."
    echo ""

    local auth="${SOLR_ADMIN_USER:-admin}:${SOLR_ADMIN_PASSWORD}"

    if [ -z "${SOLR_ADMIN_PASSWORD:-}" ]; then
        log_warn "Admin password not set, skipping core stats"
        return
    fi

    local core_status
    if core_status=$(curl -sf -u "$auth" "http://${SOLR_HOST}/solr/admin/cores?action=STATUS&core=${CORE_NAME}&wt=json" 2>/dev/null); then
        if command -v jq &>/dev/null; then
            echo "$core_status" | jq -r "
                .status.${CORE_NAME} |
                \"Core Statistics:\",
                \"  Documents:    \\(.index.numDocs // 0)\",
                \"  Segments:     \\(.index.segmentCount // 0)\",
                \"  Size (MB):    \\((.index.sizeInBytes // 0) / 1024 / 1024 | floor)\",
                \"  Deletions:    \\(.index.deletions // 0)\"
            " | tee -a "$REPORT_FILE"
        else
            echo "Core Status (JSON):" | tee -a "$REPORT_FILE"
            echo "$core_status" | tee -a "$REPORT_FILE"
        fi
    fi

    echo "" | tee -a "$REPORT_FILE"
}

generate_summary() {
    log_info "Generating Summary..."
    echo ""

    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "  Performance Benchmark Summary"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Timestamp: $(date)"
        echo "Solr Version: ${SOLR_VERSION:-Unknown}"
        echo "Core: ${CORE_NAME}"
        echo ""
        echo "Benchmark Configuration:"
        echo "  Warmup Queries:        $WARMUP_QUERIES"
        echo "  Benchmark Queries:     $BENCHMARK_QUERIES"
        echo "  Concurrent Users:      $CONCURRENT_USERS"
        echo ""
        echo "System Information:"
        docker stats --no-stream "${CUSTOMER_NAME}_solr" 2>/dev/null || echo "  (Container stats not available)"
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
    } | tee -a "$REPORT_FILE"

    echo ""
    log_success "Benchmark complete!"
    log_info "Full report saved to: $REPORT_FILE"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    cat <<'EOF'
═══════════════════════════════════════════════════════════════
  Solr Performance Benchmark v3.1.0
═══════════════════════════════════════════════════════════════
EOF

    echo ""

    # Pre-checks
    check_dependencies
    check_solr_running
    get_credentials

    echo ""
    log_info "Starting performance benchmark..."
    echo ""
    echo "Configuration:"
    echo "  Solr Host:             $SOLR_HOST"
    echo "  Core:                  $CORE_NAME"
    echo "  Warmup Queries:        $WARMUP_QUERIES"
    echo "  Benchmark Queries:     $BENCHMARK_QUERIES"
    echo "  Concurrent Users:      $CONCURRENT_USERS"
    echo "  Report File:           $REPORT_FILE"
    echo ""

    read -p "Press Enter to start benchmark (Ctrl+C to cancel)..."

    # Header
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "  Solr Performance Benchmark Report"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Date: $(date)"
        echo "Solr Version: ${SOLR_VERSION:-Unknown}"
        echo ""
    } > "$REPORT_FILE"

    # Warmup
    log_info "Warming up ($WARMUP_QUERIES requests)..."
    ab -n "$WARMUP_QUERIES" -c 5 "http://${SOLR_HOST}/solr/admin/ping" >/dev/null 2>&1
    log_success "Warmup complete"
    echo ""

    # Run benchmarks
    measure_jvm_memory
    measure_core_stats
    benchmark_ping
    benchmark_simple_query
    benchmark_facet_query
    benchmark_search_query
    measure_jvm_memory  # After benchmarks

    # Summary
    generate_summary

    echo ""
    echo "Tips:"
    echo "  - Compare results over time to detect performance regressions"
    echo "  - Review GC logs: docker exec solr cat /var/solr/logs/gc.log"
    echo "  - Check Grafana dashboards: http://localhost:3000"
    echo "  - Optimize heap if needed: See MEMORY_TUNING.md"
    echo ""
}

main "$@"
