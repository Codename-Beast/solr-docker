#!/usr/bin/env bash
# Solr Configuration Generator v2.3.1
# Generates security.json and other configuration files
# Uses Double SHA-256 algorithm for password hashing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Allow CONFIG_DIR to be overridden via .env (v3.4.1)
# Default: $PROJECT_DIR/config
# Override: Set SOLR_CONFIG_DIR in .env
if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env" 2>/dev/null || true
fi
CONFIG_DIR="${SOLR_CONFIG_DIR:-$PROJECT_DIR/config}"

LOCKFILE="/tmp/solr-config-generation.lock"

# Load common library
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "Error: Failed to load common.sh library"
    exit 1
}

# Setup error handling
setup_error_handling

# ============================================================================
# MAIN CONFIGURATION GENERATION
# ============================================================================

generate_config() {
    log_info "Starting configuration generation"

    # Load environment variables
    if [ ! -f "$PROJECT_DIR/.env" ]; then
        die ".env file not found. Copy .env.example to .env and configure it."
    fi

    load_env "$PROJECT_DIR/.env"

    # Validate required environment variables
    require_env "CUSTOMER_NAME"
    require_env "SOLR_ADMIN_USER"
    require_env "SOLR_ADMIN_PASSWORD"
    require_env "SOLR_SUPPORT_USER"
    require_env "SOLR_SUPPORT_PASSWORD"
    require_env "SOLR_CUSTOMER_USER"
    require_env "SOLR_CUSTOMER_PASSWORD"

    require_command "python3"

    # Generate password hashes with Double SHA-256
    # Uses --reuse to check existing hashes and reuse if password matches
    log_info "Generating password hashes..."
    local admin_hash support_hash customer_hash
    local security_json="$CONFIG_DIR/security.json"

    # Use --reuse to implement idempotency
    # If security.json exists and password matches, reuse existing hash
    # Otherwise generate new hash
    admin_hash=$(retry_command 3 1 python3 "$SCRIPT_DIR/hash-password.py" --reuse "$SOLR_ADMIN_USER" "$SOLR_ADMIN_PASSWORD" "$security_json") || die "Failed to hash admin password"
    support_hash=$(retry_command 3 1 python3 "$SCRIPT_DIR/hash-password.py" --reuse "$SOLR_SUPPORT_USER" "$SOLR_SUPPORT_PASSWORD" "$security_json") || die "Failed to hash support password"
    customer_hash=$(retry_command 3 1 python3 "$SCRIPT_DIR/hash-password.py" --reuse "$SOLR_CUSTOMER_USER" "$SOLR_CUSTOMER_PASSWORD" "$security_json") || die "Failed to hash customer password"

    log_success "Password hashes generated (re-used existing if unchanged)"

    # Generate core name from customer name or domain
    local core_name
    core_name=$(echo "${CUSTOMER_NAME}_core" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g')

    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"

    # Generate security.json with version tracking
    log_info "Generating security.json..."
    cat > "$CONFIG_DIR/security.json" <<EOF
{
  "_meta": {
    "version": "2.3.1",
    "generated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "generator": "generate-config.sh",
    "customer": "${CUSTOMER_NAME}",
    "algorithm": "Double SHA-256"
  },
  "authentication": {
    "blockUnknown": true,
    "class": "solr.BasicAuthPlugin",
    "credentials": {
      "${SOLR_ADMIN_USER}": "${admin_hash}",
      "${SOLR_SUPPORT_USER}": "${support_hash}",
      "${SOLR_CUSTOMER_USER}": "${customer_hash}"
    },
    "realm": "Solr Authentication",
    "forwardCredentials": false
  },
  "authorization": {
    "class": "solr.RuleBasedAuthorizationPlugin",
    "permissions": [
      { "name": "health-check-ping", "path": "/admin/ping", "role": null },
      { "name": "health-check-detailed", "path": "/admin/health", "role": null },
      { "name": "health-check-simple", "path": "/admin/healthcheck", "role": null },
      { "name": "security-read", "role": "admin" },
      { "name": "security-edit", "role": "admin" },
      { "name": "schema-edit", "role": "admin" },
      { "name": "config-edit", "role": "admin" },
      { "name": "collection-admin-edit", "role": "admin" },
      { "name": "core-admin-read", "role": "admin" },
      { "name": "core-admin-edit", "role": "admin" },
      { "name": "metrics", "path": "/admin/metrics", "role": ["admin", "support"] },
      { "name": "backup", "path": "/admin/cores", "role": ["admin"] },
      { "name": "logging", "path": "/admin/logging", "role": ["admin", "support"] },
      { "name": "read", "collection": "${core_name}", "role": ["admin", "support", "customer"] },
      { "name": "update", "collection": "${core_name}", "role": ["admin", "customer"] }
    ],
    "user-role": {
      "${SOLR_ADMIN_USER}": ["admin"],
      "${SOLR_SUPPORT_USER}": ["support"],
      "${SOLR_CUSTOMER_USER}": ["customer"]
    }
  }
}
EOF

    log_success "Generated: config/security.json"

    # Language files are already in lang/ directory - no need to copy
    log_success "Language files ready in lang/ directory"

    # Generate empty synonyms and protwords if they don't exist
    touch "$CONFIG_DIR/synonyms.txt"
    touch "$CONFIG_DIR/protwords.txt"

    log_success "Generated: synonyms.txt and protwords.txt"

    echo ""
    echo "=========================================="
    log_success "Configuration files generated successfully"
    echo "=========================================="
    echo "Core name: $core_name"
    echo "Config directory: $CONFIG_DIR"
    echo "Version: 2.3.1"
    echo "Algorithm: Double SHA-256 with hash reuse"
    echo ""
    echo "Next steps:"
    echo "  1. Review config/security.json"
    echo "  2. Run: make start"
    echo "=========================================="
}

# ============================================================================
# MAIN EXECUTION (with file locking)
# ============================================================================

main() {
    log_info "Solr Configuration Generator v2.3.1"

    # Run generation with file locking to prevent race conditions
    with_lock "$LOCKFILE" generate_config
}

main "$@"
