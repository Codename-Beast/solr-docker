#!/usr/bin/env bash
# Docker Secrets Setup v2.3.0
# Creates Docker secrets for sensitive data
# Usage: ./setup-secrets.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common library
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "Error: Failed to load common.sh library"
    exit 1
}

setup_error_handling

# ============================================================================
# CONFIGURATION
# ============================================================================

SECRETS_DIR="$PROJECT_DIR/.secrets"
USE_DOCKER_SWARM=false

# ============================================================================
# SECRETS MANAGEMENT FUNCTIONS
# ============================================================================

check_secrets_support() {
    log_info "Checking Docker Secrets support..."

    # Check if we're running in Swarm mode
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        log_success "Docker Swarm is active - using native secrets"
        USE_DOCKER_SWARM=true
        return 0
    fi

    log_info "Docker Swarm not active - using file-based secrets"
    USE_DOCKER_SWARM=false
    return 0
}

create_secrets_directory() {
    log_info "Creating secrets directory..."

    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    log_success "Secrets directory created: $SECRETS_DIR"
}

create_secret_file() {
    local secret_name=$1
    local secret_value=$2
    local secret_file="$SECRETS_DIR/${secret_name}"

    echo -n "$secret_value" > "$secret_file"
    chmod 600 "$secret_file"

    log_success "Created secret file: $secret_name"
}

create_swarm_secret() {
    local secret_name=$1
    local secret_value=$2

    # Check if secret already exists
    if docker secret ls --format '{{.Name}}' | grep -q "^${secret_name}$"; then
        log_warn "Secret already exists: $secret_name (skipping)"
        return 0
    fi

    # Create secret
    echo -n "$secret_value" | docker secret create "$secret_name" - >/dev/null

    log_success "Created Docker secret: $secret_name"
}

create_secret() {
    local secret_name=$1
    local secret_value=$2

    if [ "$USE_DOCKER_SWARM" = true ]; then
        create_swarm_secret "$secret_name" "$secret_value"
    else
        create_secret_file "$secret_name" "$secret_value"
    fi
}

load_secrets_from_env() {
    log_info "Loading secrets from environment..."

    load_env "$PROJECT_DIR/.env"

    # Validate required variables
    require_env "SOLR_ADMIN_PASSWORD"
    require_env "SOLR_SUPPORT_PASSWORD"
    require_env "SOLR_CUSTOMER_PASSWORD"
    require_env "GRAFANA_ADMIN_PASSWORD"

    log_success "Environment loaded"
}

setup_solr_secrets() {
    log_info "Setting up Solr secrets..."

    create_secret "solr_admin_password" "$SOLR_ADMIN_PASSWORD"
    create_secret "solr_support_password" "$SOLR_SUPPORT_PASSWORD"
    create_secret "solr_customer_password" "$SOLR_CUSTOMER_PASSWORD"

    log_success "Solr secrets created"
}

setup_grafana_secrets() {
    log_info "Setting up Grafana secrets..."

    create_secret "grafana_admin_password" "$GRAFANA_ADMIN_PASSWORD"

    log_success "Grafana secrets created"
}

setup_prometheus_secrets() {
    log_info "Setting up Prometheus secrets..."

    # Optional: Remote write credentials
    if [ -n "${PROMETHEUS_REMOTE_WRITE_USER:-}" ]; then
        create_secret "prometheus_remote_user" "$PROMETHEUS_REMOTE_WRITE_USER"
        create_secret "prometheus_remote_password" "$PROMETHEUS_REMOTE_WRITE_PASSWORD"
        log_success "Prometheus remote write secrets created"
    else
        log_info "No Prometheus remote write credentials configured (optional)"
    fi
}

generate_secrets_usage_doc() {
    log_info "Generating secrets usage documentation..."

    cat > "$SECRETS_DIR/README.md" <<'EOF'
# Docker Secrets Usage

This directory contains Docker secrets for the Solr Moodle Docker stack.

## Security Notice

**⚠️ IMPORTANT:** Never commit files in this directory to version control!

This directory is gitignored by default.

## Created Secrets

- `solr_admin_password` - Solr admin user password
- `solr_support_password` - Solr support user password
- `solr_customer_password` - Solr customer user password
- `grafana_admin_password` - Grafana admin password
- `prometheus_remote_user` - (Optional) Prometheus remote write username
- `prometheus_remote_password` - (Optional) Prometheus remote write password

## Using Secrets in Docker Compose

### File-based Secrets (Docker Compose)

Add to your `docker-compose.yml`:

```yaml
secrets:
  solr_admin_password:
    file: .secrets/solr_admin_password
  solr_support_password:
    file: .secrets/solr_support_password
  # ... more secrets

services:
  solr:
    secrets:
      - solr_admin_password
      - solr_support_password
    # Access secrets at: /run/secrets/<secret_name>
```

### Docker Swarm Secrets

If using Docker Swarm mode, secrets are managed by Swarm:

```yaml
secrets:
  solr_admin_password:
    external: true
```

## Rotating Secrets

To rotate a secret:

1. Update the password in `.env`
2. For Swarm: Remove old secret and create new one
   ```bash
   docker secret rm solr_admin_password
   ```
3. Re-run `./scripts/setup-secrets.sh`
4. Restart services to pick up new secrets

## Backup

**IMPORTANT:** Backup this directory securely! Without these secrets, you cannot access your Solr installation.

Recommended: Use encrypted backup solution (e.g., GPG, Vault, AWS Secrets Manager)

## Migration to External Secrets Manager

For production, consider migrating to:
- HashiCorp Vault
- AWS Secrets Manager
- Azure Key Vault
- Google Secret Manager

See: https://docs.docker.com/engine/swarm/secrets/
EOF

    log_success "Generated: $SECRETS_DIR/README.md"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo "=========================================="
    log_info "Docker Secrets Setup v2.3.0"
    echo "=========================================="
    echo ""

    check_secrets_support
    create_secrets_directory
    load_secrets_from_env

    echo ""
    setup_solr_secrets
    setup_grafana_secrets
    setup_prometheus_secrets

    echo ""
    generate_secrets_usage_doc

    echo ""
    echo "=========================================="
    log_success "Secrets setup completed successfully"
    echo "=========================================="
    echo ""
    echo "Secrets location: $SECRETS_DIR"
    echo ""
    if [ "$USE_DOCKER_SWARM" = true ]; then
        echo "Mode: Docker Swarm (native secrets)"
        echo "View secrets: docker secret ls"
    else
        echo "Mode: File-based secrets"
        echo "Secrets directory: $SECRETS_DIR/"
    fi
    echo ""
    echo "⚠️  IMPORTANT:"
    echo "  - Never commit .secrets/ directory to version control"
    echo "  - Backup secrets securely"
    echo "  - Rotate secrets regularly"
    echo ""
    echo "Next steps:"
    echo "  1. Review secrets in $SECRETS_DIR/"
    echo "  2. (Optional) Enable secrets in docker-compose.yml"
    echo "  3. Restart services to apply secrets"
    echo "=========================================="
}

main "$@"
