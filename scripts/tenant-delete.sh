#!/bin/bash

###############################################################################
# Tenant Deletion Script v3.4.0
# Deletes a tenant (Solr core + user + RBAC configuration)
# Optional: Creates backup before deletion
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

    if [ -z "$tenant_id" ]; then
        log_error "Tenant ID cannot be empty"
        echo ""
        echo "Usage: $0 <tenant_id> [BACKUP=true|false]"
        echo "Example: $0 tenant1 BACKUP=true"
        exit 1
    fi
}

check_tenant_exists() {
    local tenant_id=$1
    local core_name="moodle_${tenant_id}"

    # Check if core exists
    if ! docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&core=${core_name}" | grep -q "\"${core_name}\""; then
        log_error "Tenant '${tenant_id}' does not exist (core: ${core_name})"
        log_info "Use './scripts/tenant-list.sh' to see all tenants"
        exit 1
    fi
}

###############################################################################
# Backup
###############################################################################

create_backup() {
    local tenant_id=$1
    local core_name="moodle_${tenant_id}"

    log_info "Creating backup for tenant: ${tenant_id}"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="tenant_${tenant_id}_${timestamp}"
    local backup_dir="$PROJECT_ROOT/backups"

    # Create backup directory
    mkdir -p "$backup_dir"

    # Create Solr snapshot
    log_info "Creating Solr snapshot..."
    if ! docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/replication?command=backup&name=${backup_name}" > /dev/null; then
        log_error "Failed to create Solr snapshot"
        return 1
    fi

    # Wait for backup to complete
    log_info "Waiting for backup to complete..."
    sleep 5

    # Copy backup files
    log_info "Copying backup files..."
    local data_dir="$PROJECT_ROOT/data/${core_name}"
    if [ -d "$data_dir" ]; then
        tar czf "$backup_dir/${backup_name}.tar.gz" \
            -C "$PROJECT_ROOT/data" \
            "$core_name" \
            2>/dev/null || log_warning "Some files could not be backed up"
    fi

    # Backup credentials
    if [ -f "$PROJECT_ROOT/.env.${tenant_id}" ]; then
        cp "$PROJECT_ROOT/.env.${tenant_id}" "$backup_dir/${backup_name}_credentials.env"
        log_success "Credentials backed up"
    fi

    log_success "Backup created: ${backup_name}.tar.gz"
    echo "   Location: $backup_dir/${backup_name}.tar.gz"
    return 0
}

###############################################################################
# Core Deletion
###############################################################################

delete_core() {
    local tenant_id=$1
    local core_name="moodle_${tenant_id}"

    log_info "Deleting Solr core: ${core_name}"

    # Unload core
    if ! docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=UNLOAD&core=${core_name}&deleteIndex=true&deleteDataDir=true&deleteInstanceDir=true" > /dev/null; then
        log_error "Failed to unload core ${core_name}"
        return 1
    fi

    # Remove data directory
    log_info "Removing data directory..."
    local data_dir="$PROJECT_ROOT/data/${core_name}"
    if [ -d "$data_dir" ]; then
        rm -rf "$data_dir"
        log_success "Data directory removed"
    fi

    log_success "Core ${core_name} deleted successfully"
    return 0
}

###############################################################################
# User & RBAC Removal
###############################################################################

remove_user_and_rbac() {
    local tenant_id=$1
    local username="${tenant_id}_customer"
    local core_name="moodle_${tenant_id}"
    local role_name="${tenant_id}_role"

    log_info "Removing user and RBAC configuration for tenant: ${tenant_id}"

    # CRITICAL FIX v3.3.0: Use transactional updates to prevent race conditions
    # All security.json modifications are now atomic and protected by file locking

    # Begin transaction
    begin_transaction
    trap 'rollback_transaction' ERR

    # Step 1: Remove permission for tenant's core
    log_info "Removing permissions for core: ${core_name}"
    log_operation "REMOVE_PERMISSION ${tenant_id}-access"
    if ! remove_permission "${tenant_id}-access"; then
        log_warning "Permission not found or already removed"
        # Continue - not critical
    fi

    # Step 2: Remove user-role mapping
    log_info "Removing role: ${role_name}"
    log_operation "REMOVE_USER_ROLE $username"
    if ! remove_user_role "$username"; then
        log_warning "User role not found or already removed"
        # Continue - not critical
    fi

    # Step 3: Remove user credentials
    log_info "Removing user: ${username}"
    log_operation "REMOVE_CREDENTIAL $username"
    if ! remove_credential "$username"; then
        log_warning "User credential not found or already removed"
        # Continue - not critical
    fi

    # CRITICAL FIX v3.3.2: Keep transaction open until after Solr restart verification
    # This ensures we can rollback if Solr fails to start with the new config

    # OPTIMIZED v3.3.2: Graceful Solr-only restart (minimized downtime)
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

    log_success "User and RBAC configuration removed successfully"
    return 0
}

###############################################################################
# Credentials Cleanup
###############################################################################

archive_credentials() {
    local tenant_id=$1
    local env_file="$PROJECT_ROOT/.env.${tenant_id}"

    if [ -f "$env_file" ]; then
        log_info "Archiving credentials file..."
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        local archive_name=".env.${tenant_id}.deleted_${timestamp}"
        mv "$env_file" "$PROJECT_ROOT/$archive_name"
        log_success "Credentials archived: $archive_name"
    else
        log_warning "Credentials file not found: $env_file"
    fi
}

###############################################################################
# Confirmation Prompt
###############################################################################

confirm_deletion() {
    local tenant_id=$1
    local backup_enabled=$2

    echo ""
    log_warning "You are about to DELETE tenant: ${tenant_id}"
    echo ""
    echo "   Core:       moodle_${tenant_id}"
    echo "   User:       ${tenant_id}_customer"
    echo "   Backup:     $([ "$backup_enabled" = true ] && echo "✅ Enabled" || echo "❌ Disabled")"
    echo ""
    log_warning "This action CANNOT be undone (unless backup is enabled)"
    echo ""
    read -rp "Type 'DELETE' to confirm: " confirmation

    if [ "$confirmation" != "DELETE" ]; then
        log_info "Deletion cancelled"
        exit 0
    fi
}

###############################################################################
# Main Function
###############################################################################

main() {
    local tenant_id=${1:-}
    local backup_enabled=${BACKUP:-false}

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           Solr Multi-Tenancy: Delete Tenant                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Validate input
    validate_tenant_id "$tenant_id"
    check_tenant_exists "$tenant_id"

    # Confirm deletion
    confirm_deletion "$tenant_id" "$backup_enabled"

    # Create backup if requested
    if [ "$backup_enabled" = true ]; then
        if ! create_backup "$tenant_id"; then
            log_error "Backup failed. Aborting deletion."
            exit 1
        fi
    else
        log_warning "Backup disabled. Data will be permanently lost."
    fi

    # Delete core
    if ! delete_core "$tenant_id"; then
        log_error "Failed to delete core. Security configuration not modified."
        exit 1
    fi

    # Remove user and RBAC
    if ! remove_user_and_rbac "$tenant_id"; then
        log_error "Failed to remove security configuration"
        log_warning "Core was deleted but security.json may contain stale entries"
        exit 1
    fi

    # Archive credentials
    archive_credentials "$tenant_id"

    # Success summary
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                  ✅ SUCCESS                                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    log_success "Tenant '${tenant_id}' deleted successfully!"
    echo ""
    if [ "$backup_enabled" = true ]; then
        echo "📦 Backup available in: backups/"
        echo "   To restore, manually extract and recreate the tenant"
    fi
    echo ""
    echo "📝 Next Steps:"
    echo "   1. View remaining tenants: make tenant-list"
    echo "   2. Remove from Moodle configuration if applicable"
    echo ""
}

main "$@"
