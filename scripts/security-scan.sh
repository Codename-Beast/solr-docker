#!/usr/bin/env bash
# Security Scanning with Trivy v3.1.0
# Scans Docker images, configurations, and filesystem for vulnerabilities

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

TRIVY_VERSION=${TRIVY_VERSION:-latest}
SEVERITY=${SEVERITY:-CRITICAL,HIGH}
EXIT_CODE=${EXIT_CODE:-0}  # 0 = don't fail on findings, 1 = fail

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_trivy_installed() {
    if ! command -v trivy &>/dev/null; then
        log_warn "Trivy not installed. Installing..."
        install_trivy
    else
        log_success "Trivy is installed"
        trivy --version
    fi
}

install_trivy() {
    log_info "Installing Trivy..."

    # Detect OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        brew install aquasecurity/trivy/trivy
    else
        log_error "Unsupported OS: $OSTYPE"
        log_error "Please install Trivy manually: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
        exit 1
    fi

    log_success "Trivy installed successfully"
}

# ============================================================================
# SCAN FUNCTIONS
# ============================================================================

scan_docker_compose() {
    log_info "Scanning docker-compose.yml for misconfigurations..."
    echo ""

    trivy config \
        --severity "$SEVERITY" \
        --exit-code "$EXIT_CODE" \
        --format table \
        "$PROJECT_DIR/docker-compose.yml"

    echo ""
    log_success "Docker Compose scan complete"
}

scan_filesystem() {
    log_info "Scanning filesystem for vulnerabilities..."
    echo ""

    trivy fs \
        --severity "$SEVERITY" \
        --exit-code "$EXIT_CODE" \
        --format table \
        --skip-dirs node_modules \
        --skip-dirs .git \
        "$PROJECT_DIR"

    echo ""
    log_success "Filesystem scan complete"
}

scan_docker_images() {
    log_info "Scanning Docker images for vulnerabilities..."
    echo ""

    # Load .env to get Solr version
    if [ -f "$PROJECT_DIR/.env" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/.env"
    fi

    local solr_version=${SOLR_VERSION:-9.9.0}

    log_info "Scanning solr:${solr_version}..."
    trivy image \
        --severity "$SEVERITY" \
        --exit-code "$EXIT_CODE" \
        --format table \
        "solr:${solr_version}"

    echo ""

    # Scan other images from docker-compose
    local images=(
        "alpine:3.20"
        "python:3.11-alpine"
        "prom/prometheus:v2.48.0"
        "grafana/grafana:10.2.2"
        "prom/alertmanager:v0.26.0"
    )

    for image in "${images[@]}"; do
        log_info "Scanning $image..."
        trivy image \
            --severity "$SEVERITY" \
            --exit-code "$EXIT_CODE" \
            --format table \
            "$image" || true
        echo ""
    done

    log_success "Docker image scans complete"
}

scan_secrets() {
    log_info "Scanning for exposed secrets..."
    echo ""

    trivy fs \
        --scanners secret \
        --severity "$SEVERITY" \
        --exit-code "$EXIT_CODE" \
        --format table \
        "$PROJECT_DIR"

    echo ""
    log_success "Secret scan complete"
}

generate_report() {
    log_info "Generating comprehensive security report..."

    local report_dir="$PROJECT_DIR/security-reports"
    mkdir -p "$report_dir"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    # JSON report for docker-compose
    trivy config \
        --severity "$SEVERITY" \
        --format json \
        --output "$report_dir/docker-compose-${timestamp}.json" \
        "$PROJECT_DIR/docker-compose.yml" || true

    # JSON report for filesystem
    trivy fs \
        --severity "$SEVERITY" \
        --format json \
        --output "$report_dir/filesystem-${timestamp}.json" \
        "$PROJECT_DIR" || true

    # SARIF report (for GitHub)
    trivy config \
        --severity "$SEVERITY" \
        --format sarif \
        --output "$report_dir/trivy-results-${timestamp}.sarif" \
        "$PROJECT_DIR" || true

    log_success "Reports generated in: $report_dir"
    echo ""
    echo "Reports:"
    ls -lh "$report_dir" | grep "${timestamp}"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    cat <<'EOF'
═══════════════════════════════════════════════════════════════
  Security Scanning with Trivy v3.1.0
═══════════════════════════════════════════════════════════════
EOF

    echo ""

    # Check Trivy installation
    check_trivy_installed

    echo ""
    echo "Scan Configuration:"
    echo "  Severity: $SEVERITY"
    echo "  Exit Code on Findings: $EXIT_CODE"
    echo ""

    # Menu
    PS3="Select scan type (or 'q' to quit): "
    options=(
        "Full Scan (All)"
        "Docker Compose Configuration"
        "Filesystem"
        "Docker Images"
        "Secrets Detection"
        "Generate Reports"
        "Quit"
    )

    select opt in "${options[@]}"; do
        case $opt in
            "Full Scan (All)")
                log_info "Running full security scan..."
                echo ""
                scan_docker_compose
                echo ""
                scan_filesystem
                echo ""
                scan_docker_images
                echo ""
                scan_secrets
                echo ""
                generate_report
                break
                ;;
            "Docker Compose Configuration")
                scan_docker_compose
                break
                ;;
            "Filesystem")
                scan_filesystem
                break
                ;;
            "Docker Images")
                scan_docker_images
                break
                ;;
            "Secrets Detection")
                scan_secrets
                break
                ;;
            "Generate Reports")
                generate_report
                break
                ;;
            "Quit")
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid option. Try again."
                ;;
        esac
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    log_success "Security scan complete!"
    echo ""
    echo "Recommendations:"
    echo "  - Review findings above"
    echo "  - Update Docker images: docker compose pull"
    echo "  - Check security-reports/ directory for detailed reports"
    echo "  - Run regularly: Add to CI/CD pipeline"
    echo ""
}

# Allow non-interactive mode
if [ "${1:-}" = "--all" ]; then
    check_trivy_installed
    scan_docker_compose
    scan_filesystem
    scan_docker_images
    scan_secrets
    generate_report
    exit 0
fi

main "$@"
