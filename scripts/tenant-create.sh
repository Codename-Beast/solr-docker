#!/bin/bash

###############################################################################
# Tenant Creation Script v3.4.0
# Creates a new isolated tenant (Solr core + user + RBAC configuration)
###############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load common functions (v3.4.0 - Centralized utilities)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# CRITICAL: Load atomic security manager (v3.3.0 - Race condition fix)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/security-json-manager.sh"

###############################################################################
# Pre-flight Checks (v3.4.0)
###############################################################################

# Check if Solr container is running
require_container_running "solr"

###############################################################################
# Validation
###############################################################################

validate_tenant_id() {
    local tenant_id=$1

    # Check if empty
    if [ -z "$tenant_id" ]; then
        log_error "Tenant ID cannot be empty"
        echo ""
        echo "Usage: $0 <tenant_id>"
        echo "Example: $0 tenant1"
        exit 1
    fi

    # Check format (lowercase alphanumeric + underscores only)
    if ! [[ "$tenant_id" =~ ^[a-z0-9_]+$ ]]; then
        log_error "Invalid tenant ID format. Use lowercase letters, numbers, and underscores only."
        exit 1
    fi

    # Check length
    if [ ${#tenant_id} -gt 30 ]; then
        log_error "Tenant ID too long (max 30 characters)"
        exit 1
    fi
}

check_tenant_exists() {
    local tenant_id=$1
    local core_name="moodle_${tenant_id}"

    # Check if core exists
    if docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&core=${core_name}" | grep -q "\"${core_name}\""; then
        log_error "Tenant '${tenant_id}' already exists (core: ${core_name})"
        log_info "Use './scripts/tenant-delete.sh ${tenant_id}' to remove it first"
        exit 1
    fi

    # Check if credentials file exists
    if [ -f "$PROJECT_ROOT/.env.${tenant_id}" ]; then
        log_warning "Credentials file .env.${tenant_id} already exists"
        read -rp "Overwrite? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Aborted"
            exit 0
        fi
    fi
}

###############################################################################
# Password Generation
###############################################################################

generate_password() {
    # Generate a 32-character random password with high entropy
    # Uses /dev/urandom for cryptographic randomness
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=-' < /dev/urandom | head -c 32
}

hash_password() {
    local password=$1

    # Double SHA-256 hash
    echo -n "$password" | sha256sum | awk '{print $1}' | \
        xxd -r -p | sha256sum | awk '{print $1}'
}

###############################################################################
# Core Creation
###############################################################################

create_core() {
    local tenant_id=$1
    local core_name="moodle_${tenant_id}"

    log_info "Creating Solr core: ${core_name}"

    # Create core using Moodle configset
    if ! docker compose exec -T solr solr create_core \
        -c "$core_name" \
        -d /opt/solr/server/solr/configsets/moodle \
        -p 8983; then
        log_error "Failed to create core ${core_name}"
        return 1
    fi

    log_success "Core ${core_name} created successfully"
    return 0
}

###############################################################################
# User & RBAC Configuration
###############################################################################

add_user_and_rbac() {
    local tenant_id=$1
    local username="${tenant_id}_customer"
    local password=$2
    local hashed_password=$3
    local core_name="moodle_${tenant_id}"
    local role_name="${tenant_id}_role"

    log_info "Configuring user and RBAC for tenant: ${tenant_id}"

    # CRITICAL FIX v3.3.0: Use transactional updates to prevent race conditions
    # All security.json modifications are now atomic and protected by file locking

    # Begin transaction
    begin_transaction
    trap 'rollback_transaction' ERR

    # Step 1: Add user credentials
    log_info "Adding user: ${username}"
    log_operation "ADD_CREDENTIAL $username"
    if ! add_credential "$username" "SHA256:${hashed_password}"; then
        log_error "Failed to add credential"
        rollback_transaction
        return 1
    fi

    # Step 2: Add user-role mapping
    log_info "Assigning role: ${role_name}"
    log_operation "ADD_USER_ROLE $username $role_name"
    if ! add_user_role "$username" "$role_name"; then
        log_error "Failed to assign role"
        rollback_transaction
        return 1
    fi

    # Step 3: Add permission for tenant's core
    log_info "Setting up permissions for core: ${core_name}"
    local permission="{
        \"name\": \"${tenant_id}-access\",
        \"role\": \"${role_name}\",
        \"collection\": \"${core_name}\",
        \"path\": \"/*\"
    }"
    log_operation "ADD_PERMISSION ${tenant_id}-access"
    if ! add_permission "$permission"; then
        log_error "Failed to add permission"
        rollback_transaction
        return 1
    fi

    # CRITICAL FIX v3.3.2: Keep transaction open until after Solr restart verification
    # This ensures we can rollback if Solr fails to start with the new config

    # OPTIMIZED v3.3.1: Graceful Solr-only restart (minimized downtime)
    log_info "Reloading Solr to apply security changes (graceful restart)..."

    # Stop Solr gracefully (10s timeout)
    docker compose stop -t 10 solr >/dev/null 2>&1

    # Start Solr
    docker compose start solr >/dev/null 2>&1

    # v3.4.0: Use centralized wait_for_solr function with configurable timeout
    if ! wait_for_solr "${SOLR_STARTUP_TIMEOUT}"; then
        log_error "Rolling back security.json changes..."
        rollback_transaction
        trap - ERR
        return 1
    fi

    # Now commit transaction - Solr successfully loaded new config
    commit_transaction
    trap - ERR
    log_success "User and RBAC configured successfully"
    return 0
}

###############################################################################
# Credentials Storage
###############################################################################

save_credentials() {
    local tenant_id=$1
    local username=$2
    local password=$3
    local core_name="moodle_${tenant_id}"
    local env_file="$PROJECT_ROOT/.env.${tenant_id}"

    log_info "Saving credentials to: .env.${tenant_id}"

    cat > "$env_file" <<EOF
# Tenant Credentials
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# WARNING: Keep this file secure! Do not commit to version control.

TENANT_ID=${tenant_id}
TENANT_CORE=${core_name}
TENANT_USER=${username}
TENANT_PASSWORD=${password}
TENANT_URL=http://localhost:${SOLR_PORT}/solr/${core_name}

# Moodle Configuration Example:
# \$CFG->solr_server_hostname = 'localhost';
# \$CFG->solr_server_port = '${SOLR_PORT}';
# \$CFG->solr_indexname = '${core_name}';
# \$CFG->solr_server_username = '${username}';
# \$CFG->solr_server_password = '${password}';
EOF

    chmod 600 "$env_file"
    log_success "Credentials saved securely (chmod 600)"
}

###############################################################################
# Validation Test
###############################################################################

test_tenant_access() {
    local tenant_id=$1
    local username=$2
    local password=$3
    local core_name="moodle_${tenant_id}"

    log_info "Testing tenant access..."

    # Test query with tenant credentials
    if curl -sf -u "${username}:${password}" \
        "http://localhost:${SOLR_PORT}/solr/${core_name}/select?q=*:*&rows=0" > /dev/null; then
        log_success "Tenant access verified: ${username} can query ${core_name}"
    else
        log_error "Failed to verify tenant access"
        return 1
    fi

    # Test that tenant CANNOT access other cores (if they exist)
    log_info "Verifying access isolation..."
    local other_cores
    other_cores=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&wt=json" | \
        jq -r '.status | keys[]' | grep -v "^${core_name}$" || true)

    if [ -n "$other_cores" ]; then
        local test_core
        test_core=$(echo "$other_cores" | head -n 1)
        if curl -sf -u "${username}:${password}" \
            "http://localhost:${SOLR_PORT}/solr/${test_core}/select?q=*:*&rows=0" > /dev/null 2>&1; then
            log_warning "Security issue: Tenant can access other cores!"
            return 1
        else
            log_success "Access isolation verified: Tenant cannot access other cores"
        fi
    fi

    return 0
}

###############################################################################
# Main Function
###############################################################################

main() {
    local tenant_id=${1:-}

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           Solr Multi-Tenancy: Create Tenant                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Validate input
    validate_tenant_id "$tenant_id"
    check_tenant_exists "$tenant_id"

    local core_name="moodle_${tenant_id}"
    local username="${tenant_id}_customer"

    # Generate password
    log_info "Generating secure password..."
    local password
    password=$(generate_password)
    local hashed_password
    hashed_password=$(hash_password "$password")
    log_success "Password generated (32 characters, high entropy)"

    # Create core
    if ! create_core "$tenant_id"; then
        log_error "Tenant creation failed at core creation step"
        exit 1
    fi

    # Configure user and RBAC
    if ! add_user_and_rbac "$tenant_id" "$username" "$password" "$hashed_password"; then
        log_error "Tenant creation failed at RBAC configuration step"
        log_warning "Core ${core_name} was created but security not configured"
        log_info "Run: ./scripts/tenant-delete.sh ${tenant_id}"
        exit 1
    fi

    # Save credentials
    save_credentials "$tenant_id" "$username" "$password"

    # Test access
    if ! test_tenant_access "$tenant_id" "$username" "$password"; then
        log_error "Tenant creation completed but access test failed"
        log_warning "Check security.json configuration manually"
        exit 1
    fi

    # Success summary
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                  ✅ SUCCESS                                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    log_success "Tenant '${tenant_id}' created successfully!"
    echo ""
    echo "📋 Connection Details:"
    echo "   Tenant ID:  ${tenant_id}"
    echo "   Core:       ${core_name}"
    echo "   User:       ${username}"
    echo "   Password:   ${password}"
    echo "   URL:        http://localhost:${SOLR_PORT}/solr/${core_name}"
    echo ""
    echo "🔐 Credentials saved to: .env.${tenant_id}"
    echo ""
    echo "📝 Next Steps:"
    echo "   1. Configure your application (Moodle) with these credentials"
    echo "   2. Load credentials: source .env.${tenant_id}"
    echo "   3. Test connection: curl -u \"\$TENANT_USER:\$TENANT_PASSWORD\" \"\$TENANT_URL/select?q=*:*\""
    echo "   4. View all tenants: make tenant-list"
    echo ""
}

main "$@"
