#!/usr/bin/env bash
# Pre-flight Checks for Solr Deployment v2.5.0
# Validates configuration and environment before deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common library
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "Error: Failed to load common.sh library"
    exit 1
}

# ============================================================================
# CONFIGURATION
# ============================================================================

FAILED_CHECKS=0
WARNING_CHECKS=0
PASSED_CHECKS=0

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_pass() {
    log_success "$1"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
}

check_fail() {
    log_error "$1"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
}

check_warn() {
    log_warn "$1"
    WARNING_CHECKS=$((WARNING_CHECKS + 1))
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

cat <<'EOF'
═══════════════════════════════════════════════════════════════
  Solr Pre-Flight Checks v2.5.0
═══════════════════════════════════════════════════════════════
EOF

echo ""
echo "Running pre-deployment validation checks..."
echo ""

# ============================================================================
# CHECK 1: System Requirements
# ============================================================================

log_info "Check 1: System Requirements"
echo ""

# Docker installed
if command -v docker >/dev/null 2>&1; then
    docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
    check_pass "Docker installed (version: $docker_version)"
else
    check_fail "Docker not found - Install Docker first"
fi

# Docker Compose v2 installed
if docker compose version >/dev/null 2>&1; then
    compose_version=$(docker compose version --short 2>/dev/null || docker compose version | awk '{print $NF}')
    check_pass "Docker Compose v2 installed (version: $compose_version)"
else
    check_fail "Docker Compose v2 not found - Required for this project"
fi

# Docker daemon running
if docker info >/dev/null 2>&1; then
    check_pass "Docker daemon is running"
else
    check_fail "Docker daemon is not running - Start Docker first"
fi

echo ""

# ============================================================================
# CHECK 2: Configuration Files
# ============================================================================

log_info "Check 2: Configuration Files"
echo ""

# .env file exists
if [ -f "$PROJECT_DIR/.env" ]; then
    check_pass ".env file exists"

    # Load .env for subsequent checks
    # shellcheck disable=SC1091
    set -a
    source "$PROJECT_DIR/.env" 2>/dev/null || true
    set +a
else
    check_fail ".env file not found - Run 'make init' first"
fi

# Allow CONFIG_DIR to be overridden (v3.4.1)
CONFIG_DIR="${SOLR_CONFIG_DIR:-$PROJECT_DIR/config}"

# security.json generated
if [ -f "$CONFIG_DIR/security.json" ]; then
    check_pass "security.json exists"
else
    check_warn "security.json not found - Run 'make config' to generate"
fi

# Required scripts exist
required_scripts=(
    "generate-config.sh"
    "start.sh"
    "stop.sh"
    "health.sh"
    "create-core.sh"
)

for script in "${required_scripts[@]}"; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        if [ -x "$SCRIPT_DIR/$script" ]; then
            check_pass "Script $script is executable"
        else
            check_warn "Script $script exists but is not executable"
        fi
    else
        check_fail "Required script $script not found"
    fi
done

echo ""

# ============================================================================
# CHECK 3: Password Security
# ============================================================================

log_info "Check 3: Password Security"
echo ""

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env" 2>/dev/null || true

    # Check admin password
    if [ -n "${SOLR_ADMIN_PASSWORD:-}" ]; then
        if [[ "$SOLR_ADMIN_PASSWORD" == *"changeme"* ]]; then
            check_fail "SOLR_ADMIN_PASSWORD contains 'changeme' - Change to secure password!"
        elif [ ${#SOLR_ADMIN_PASSWORD} -lt 12 ]; then
            check_warn "SOLR_ADMIN_PASSWORD is shorter than 12 characters (weak)"
        else
            check_pass "SOLR_ADMIN_PASSWORD is set and appears secure"
        fi
    else
        check_fail "SOLR_ADMIN_PASSWORD not set in .env"
    fi

    # Check support password
    if [ -n "${SOLR_SUPPORT_PASSWORD:-}" ]; then
        if [[ "$SOLR_SUPPORT_PASSWORD" == *"changeme"* ]]; then
            check_fail "SOLR_SUPPORT_PASSWORD contains 'changeme' - Change to secure password!"
        elif [ ${#SOLR_SUPPORT_PASSWORD} -lt 12 ]; then
            check_warn "SOLR_SUPPORT_PASSWORD is shorter than 12 characters (weak)"
        else
            check_pass "SOLR_SUPPORT_PASSWORD is set and appears secure"
        fi
    else
        check_fail "SOLR_SUPPORT_PASSWORD not set in .env"
    fi

    # Check customer password
    if [ -n "${SOLR_CUSTOMER_PASSWORD:-}" ]; then
        if [[ "$SOLR_CUSTOMER_PASSWORD" == *"changeme"* ]]; then
            check_fail "SOLR_CUSTOMER_PASSWORD contains 'changeme' - Change to secure password!"
        elif [ ${#SOLR_CUSTOMER_PASSWORD} -lt 12 ]; then
            check_warn "SOLR_CUSTOMER_PASSWORD is shorter than 12 characters (weak)"
        else
            check_pass "SOLR_CUSTOMER_PASSWORD is set and appears secure"
        fi
    else
        check_fail "SOLR_CUSTOMER_PASSWORD not set in .env"
    fi
fi

echo ""

# ============================================================================
# CHECK 4: Port Availability
# ============================================================================

log_info "Check 4: Port Availability"
echo ""

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env" 2>/dev/null || true

    # Check Solr port
    solr_port=${SOLR_PORT:-8983}
    if lsof -Pi :$solr_port -sTCP:LISTEN -t >/dev/null 2>&1; then
        check_warn "Port $solr_port (Solr) is already in use"
    else
        check_pass "Port $solr_port (Solr) is available"
    fi

    # Check Health API port
    health_port=${HEALTH_API_PORT:-8888}
    if lsof -Pi :$health_port -sTCP:LISTEN -t >/dev/null 2>&1; then
        check_warn "Port $health_port (Health API) is already in use"
    else
        check_pass "Port $health_port (Health API) is available"
    fi

    # Check Grafana port (if monitoring enabled)
    grafana_port=${GRAFANA_PORT:-3000}
    if lsof -Pi :$grafana_port -sTCP:LISTEN -t >/dev/null 2>&1; then
        check_warn "Port $grafana_port (Grafana) is already in use"
    else
        check_pass "Port $grafana_port (Grafana) is available"
    fi

    # Check Prometheus port (if monitoring enabled)
    prometheus_port=${PROMETHEUS_PORT:-9090}
    if lsof -Pi :$prometheus_port -sTCP:LISTEN -t >/dev/null 2>&1; then
        check_warn "Port $prometheus_port (Prometheus) is already in use"
    else
        check_pass "Port $prometheus_port (Prometheus) is available"
    fi
fi

echo ""

# ============================================================================
# CHECK 5: Disk Space
# ============================================================================

log_info "Check 5: Disk Space"
echo ""

# Get available disk space in GB
if command -v df >/dev/null 2>&1; then
    available_gb=$(df -BG "$PROJECT_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//' || echo "0")

    if [ "$available_gb" -ge 50 ]; then
        check_pass "Sufficient disk space available (${available_gb}GB)"
    elif [ "$available_gb" -ge 20 ]; then
        check_warn "Limited disk space available (${available_gb}GB) - Consider 50GB+"
    else
        check_warn "Low disk space (${available_gb}GB) - Recommended: 20GB+"
    fi

    # Check inode availability
    available_inodes=$(df -i "$PROJECT_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    if [ "$available_inodes" -ge 100000 ]; then
        check_pass "Sufficient inodes available ($(printf "%'d" $available_inodes))"
    else
        check_warn "Limited inodes available ($(printf "%'d" $available_inodes))"
    fi
else
    check_warn "Cannot check disk space (df command not available)"
fi

echo ""

# ============================================================================
# CHECK 6: Memory
# ============================================================================

log_info "Check 6: Memory Configuration"
echo ""

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env" 2>/dev/null || true

    # Get total system memory
    if command -v free >/dev/null 2>&1; then
        total_mem_gb=$(free -g | awk '/^Mem:/{print $2}' | grep -E '^[0-9]+$' || echo "0")

        # Default to 0 if empty or invalid
        total_mem_gb=${total_mem_gb:-0}

        if [ "$total_mem_gb" -ge 4 ]; then
            check_pass "Sufficient RAM available (${total_mem_gb}GB)"
        elif [ "$total_mem_gb" -gt 0 ]; then
            check_warn "Limited RAM available (${total_mem_gb}GB) - Recommend 4GB+"
        else
            check_warn "Cannot determine system RAM (showing as 0GB)"
        fi

        # Check heap size configuration
        heap_size=${SOLR_HEAP_SIZE:-2g}
        heap_gb=$(echo "$heap_size" | sed 's/[^0-9]//g')
        heap_gb=${heap_gb:-2}  # Default to 2 if empty

        mem_limit=${SOLR_MEMORY_LIMIT:-4g}
        limit_gb=$(echo "$mem_limit" | sed 's/[^0-9]//g')
        limit_gb=${limit_gb:-4}  # Default to 4 if empty

        # Validate heap is 50-60% of memory limit
        if [ "$limit_gb" -gt 0 ]; then
            heap_percent=$((heap_gb * 100 / limit_gb))

            if [ $heap_percent -ge 45 ] && [ $heap_percent -le 65 ]; then
                check_pass "SOLR_HEAP_SIZE (${heap_size}) is ${heap_percent}% of SOLR_MEMORY_LIMIT (${mem_limit}) - Good!"
            else
                check_warn "SOLR_HEAP_SIZE (${heap_size}) is ${heap_percent}% of SOLR_MEMORY_LIMIT (${mem_limit}) - Recommend 50-60%"
            fi
        fi

        # Check if memory limit exceeds system RAM (only if we have valid total_mem_gb)
        if [ "$total_mem_gb" -gt 0 ]; then
            if [ "$limit_gb" -gt "$total_mem_gb" ]; then
                check_warn "SOLR_MEMORY_LIMIT (${mem_limit}) exceeds system RAM (${total_mem_gb}GB)"
            else
                check_pass "SOLR_MEMORY_LIMIT (${mem_limit}) is within system RAM (${total_mem_gb}GB)"
            fi
        fi
    else
        check_warn "Cannot check memory (free command not available)"
    fi
else
    check_warn "Cannot check memory (no .env file)"
fi

echo ""

# ============================================================================
# CHECK 7: Docker Network
# ============================================================================

log_info "Check 7: Docker Network"
echo ""

# Check if networks already exist (from previous deployment)
if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env" 2>/dev/null || true

    customer_name=${CUSTOMER_NAME:-default}

    if docker network ls | grep -q "${customer_name}_frontend"; then
        check_warn "Network ${customer_name}_frontend already exists (from previous deployment)"
    else
        check_pass "Network ${customer_name}_frontend does not exist (will be created)"
    fi

    if docker network ls | grep -q "${customer_name}_backend"; then
        check_warn "Network ${customer_name}_backend already exists (from previous deployment)"
    else
        check_pass "Network ${customer_name}_backend does not exist (will be created)"
    fi
fi

echo ""

# ============================================================================
# CHECK 8: Python Dependencies (for config generation)
# ============================================================================

log_info "Check 8: Python Dependencies"
echo ""

if command -v python3 >/dev/null 2>&1; then
    python_version=$(python3 --version | awk '{print $2}')
    check_pass "Python 3 installed (version: $python_version)"

    # Check if required Python modules are available
    if python3 -c "import hashlib, base64, json" 2>/dev/null; then
        check_pass "Required Python modules available (hashlib, base64, json)"
    else
        check_fail "Required Python modules not available"
    fi
else
    check_fail "Python 3 not found - Required for password hashing"
fi

echo ""

# ============================================================================
# FINAL SUMMARY
# ============================================================================

echo "═══════════════════════════════════════════════════════════════"
echo "  Pre-Flight Check Summary"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Results:"
echo "  ✅ Passed:   $PASSED_CHECKS checks"
echo "  ⚠️  Warnings: $WARNING_CHECKS checks"
echo "  ❌ Failed:   $FAILED_CHECKS checks"
echo ""

if [ $FAILED_CHECKS -eq 0 ]; then
    if [ $WARNING_CHECKS -eq 0 ]; then
        log_success "All checks passed! Ready for deployment. 🚀"
        echo ""
        echo "Next Steps:"
        echo "  1. Review configuration: cat .env"
        echo "  2. Generate configs:     make config"
        echo "  3. Start services:       make start"
        echo "  4. Create core:          make create-core"
        echo "  5. Health check:         make health"
        exit 0
    else
        log_warn "Checks passed with warnings. Review warnings before deploying."
        echo ""
        echo "You can proceed, but address warnings when possible."
        echo ""
        echo "Next Steps:"
        echo "  1. Address warnings (optional)"
        echo "  2. Generate configs:     make config"
        echo "  3. Start services:       make start"
        exit 0
    fi
else
    log_error "Pre-flight checks failed! Fix errors before deploying."
    echo ""
    echo "Fix the errors above and run this check again:"
    echo "  ./scripts/preflight-check.sh"
    echo ""
    exit 1
fi
