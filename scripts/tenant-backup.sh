#!/bin/bash

###############################################################################
# Tenant Backup Script v3.4.0
# Creates backups for one or all tenants
###############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load common functions (v3.4.0 - Centralized utilities)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

###############################################################################
# Pre-flight Checks (v3.4.0)
###############################################################################

# Check if Solr container is running
require_container_running "solr"

###############################################################################
# Backup Locking (v3.3.1 - Prevent concurrent backups of same tenant)
###############################################################################

acquire_backup_lock() {
    local tenant_id=$1
    local lock_dir="/tmp/backup_${tenant_id}.lock"
    local timeout=${BACKUP_LOCK_TIMEOUT:-300}  # v3.4.0: Configurable from .env (default: 5min)
    local elapsed=0
    local backoff=2

    while [ $elapsed -lt $timeout ]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            echo "$$" > "$lock_dir/pid"
            echo "$(date +%s)" > "$lock_dir/timestamp"
            return 0
        fi

        # Check for stale lock
        if [ -f "$lock_dir/pid" ]; then
            local lock_pid
            lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
            if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                local lock_age=$(($(date +%s) - $(cat "$lock_dir/timestamp" 2>/dev/null || echo 0)))
                echo "⚠️  Removing stale backup lock (PID $lock_pid, age: ${lock_age}s)"
                rm -rf "$lock_dir"
                continue
            fi
        fi

        if [ $elapsed -eq 0 ]; then
            echo "⏳ Another backup is running for ${tenant_id}, waiting..."
        fi
        sleep "$backoff"
        elapsed=$((elapsed + backoff))
    done

    return 1
}

release_backup_lock() {
    local tenant_id=$1
    local lock_dir="/tmp/backup_${tenant_id}.lock"

    if [ -d "$lock_dir" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -rf "$lock_dir"
        fi
    fi
}

###############################################################################
# Validation
###############################################################################

check_tenant_exists() {
    local tenant_id=$1
    local core_name="moodle_${tenant_id}"

    # Check if core exists
    if ! docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&core=${core_name}" | grep -q "\"${core_name}\""; then
        log_error "Tenant '${tenant_id}' does not exist (core: ${core_name})"
        return 1
    fi
    return 0
}

get_all_tenant_ids() {
    docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/cores?action=STATUS&wt=json" | \
        jq -r '.status | keys[]' 2>/dev/null | \
        grep '^moodle_' | \
        sed 's/^moodle_//' || true
}

###############################################################################
# Backup Operations
###############################################################################

backup_tenant() {
    local tenant_id=$1
    local core_name="moodle_${tenant_id}"

    log_info "Creating backup for tenant: ${tenant_id}"

    # CRITICAL FIX v3.3.1: Acquire lock to prevent concurrent backups of same tenant
    if ! acquire_backup_lock "$tenant_id"; then
        log_error "Could not acquire backup lock for ${tenant_id} (timeout after 5min)"
        log_error "Another backup may be running, or a stale lock exists"
        return 1
    fi
    # NOTE: Lock will be explicitly released before each return (trap EXIT doesn't work in functions)

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="tenant_${tenant_id}_${timestamp}"
    local backup_dir="$PROJECT_ROOT/backups"

    # Create backup directory
    mkdir -p "$backup_dir"

    # CRITICAL FIX v3.3.0: Force commit before backup for consistency
    log_info "  [1/6] Flushing pending commits..."
    if ! docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/update?commit=true&waitSearcher=true" >/dev/null 2>&1; then
        log_error "Commit failed - aborting backup to prevent inconsistent state"
        release_backup_lock "$tenant_id"  # CRITICAL FIX v3.3.2: Release lock before return
        return 1
    fi
    sleep 2  # Wait for commit to complete

    # Get pre-backup metadata
    log_info "  [2/6] Collecting metadata..."
    local doc_count
    doc_count=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/admin/luke?wt=json&numTerms=0" 2>/dev/null | \
        jq -r '.index.numDocs // 0' || echo "0")

    log_info "    Documents: $(printf "%'d" "$doc_count" 2>/dev/null || echo "$doc_count")"

    # Step 3: Create Solr snapshot
    log_info "  [3/6] Creating Solr snapshot..."
    local snapshot_response
    if ! snapshot_response=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/replication?command=backup&name=${backup_name}&wt=json" 2>&1); then
        log_error "Failed to create Solr snapshot"
        log_error "Response: $snapshot_response"
        release_backup_lock "$tenant_id"  # CRITICAL FIX v3.3.2: Release lock before return
        return 1
    fi

    # Check for errors in response
    if echo "$snapshot_response" | jq -e '.error' > /dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$snapshot_response" | jq -r '.error.msg')
        log_error "Solr backup error: $error_msg"
        release_backup_lock "$tenant_id"  # CRITICAL FIX v3.3.2: Release lock before return
        return 1
    fi

    # Step 4: Wait for backup to complete
    log_info "  [4/6] Waiting for backup to complete..."
    sleep 5

    # Step 5: Archive backup files
    log_info "  [5/6] Archiving backup files..."
    local data_dir="$PROJECT_ROOT/data/${core_name}"
    if [ -d "$data_dir" ]; then
        if tar czf "$backup_dir/${backup_name}.tar.gz" \
            -C "$PROJECT_ROOT/data" \
            "$core_name" 2>/dev/null; then
            log_success "  Archive created: ${backup_name}.tar.gz"
        else
            log_warning "  Some files could not be archived (may be in use)"
        fi
    else
        log_error "Data directory not found: $data_dir"
        release_backup_lock "$tenant_id"  # CRITICAL FIX v3.3.2: Release lock before return
        return 1
    fi

    # Step 6: Backup credentials & metadata
    log_info "  [6/6] Backing up credentials & metadata..."

    # Create metadata file
    cat > "$backup_dir/${backup_name}.meta.json" <<EOF
{
  "tenant_id": "${tenant_id}",
  "core_name": "${core_name}",
  "backup_name": "${backup_name}",
  "timestamp": "$(date -Iseconds)",
  "solr_version": "${SOLR_VERSION}",
  "document_count": ${doc_count},
  "backup_type": "consistent",
  "includes": ["core_data", "credentials"]
}
EOF
    if [ -f "$PROJECT_ROOT/.env.${tenant_id}" ]; then
        cp "$PROJECT_ROOT/.env.${tenant_id}" "$backup_dir/${backup_name}_credentials.env"
        chmod 600 "$backup_dir/${backup_name}_credentials.env"
        log_success "  Credentials saved: ${backup_name}_credentials.env"
    else
        log_warning "  Credentials file not found: .env.${tenant_id}"
    fi

    # Get backup size
    local backup_size
    if [ -f "$backup_dir/${backup_name}.tar.gz" ]; then
        backup_size=$(du -h "$backup_dir/${backup_name}.tar.gz" | cut -f1)
    else
        backup_size="N/A"
    fi

    # Get document count
    local doc_count
    doc_count=$(docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/${core_name}/admin/luke?wt=json&numTerms=0" 2>/dev/null | \
        jq -r '.index.numDocs // 0' || echo "0")

    log_success "Backup completed for tenant: ${tenant_id}"
    echo ""
    echo "   Tenant:       ${tenant_id}"
    echo "   Core:         ${core_name}"
    echo "   Documents:    $(printf "%'d" "$doc_count" 2>/dev/null || echo "$doc_count")"
    echo "   Backup Name:  ${backup_name}"
    echo "   Size:         ${backup_size}"
    echo "   Location:     backups/${backup_name}.tar.gz"
    echo ""

    release_backup_lock "$tenant_id"  # CRITICAL FIX v3.3.2: Release lock before return
    return 0
}

backup_all_tenants() {
    log_info "Starting backup for all tenants..."
    echo ""

    local tenant_ids
    tenant_ids=$(get_all_tenant_ids)

    if [ -z "$tenant_ids" ]; then
        log_warning "No multi-tenant cores found"
        return 1
    fi

    local total_tenants
    total_tenants=$(echo "$tenant_ids" | wc -l)
    local success_count=0
    local failed_count=0

    log_info "Found ${total_tenants} tenant(s) to backup"
    echo ""

    local counter=1
    while IFS= read -r tenant_id; do
        echo "────────────────────────────────────────────────────────────────"
        echo "Backup ${counter}/${total_tenants}"
        echo "────────────────────────────────────────────────────────────────"
        echo ""

        if backup_tenant "$tenant_id"; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
            log_error "Failed to backup tenant: ${tenant_id}"
        fi

        counter=$((counter + 1))
        echo ""
    done <<< "$tenant_ids"

    # Summary
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    Backup Summary                          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "   Total Tenants:    ${total_tenants}"
    echo "   Successful:       ${success_count}"
    echo "   Failed:           ${failed_count}"
    echo ""

    if [ $failed_count -eq 0 ]; then
        log_success "All backups completed successfully!"
    else
        log_warning "Some backups failed. Check logs above for details."
    fi

    return 0
}

###############################################################################
# Backup Management
###############################################################################

list_backups() {
    local tenant_id=${1:-}
    local backup_dir="$PROJECT_ROOT/backups"

    if [ ! -d "$backup_dir" ]; then
        log_warning "No backups found (backups/ directory does not exist)"
        return 0
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    Available Backups                       ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    local pattern="tenant_*.tar.gz"
    if [ -n "$tenant_id" ]; then
        pattern="tenant_${tenant_id}_*.tar.gz"
    fi

    local backups
    backups=$(find "$backup_dir" -name "$pattern" -type f 2>/dev/null | sort -r || true)

    if [ -z "$backups" ]; then
        log_warning "No backups found"
        if [ -n "$tenant_id" ]; then
            echo "   Filter: tenant_${tenant_id}"
        fi
        return 0
    fi

    printf "%-40s %-15s %-20s\n" "BACKUP NAME" "SIZE" "DATE"
    echo "────────────────────────────────────────────────────────────────────────────"

    while IFS= read -r backup_file; do
        local basename
        basename=$(basename "$backup_file" .tar.gz)
        local size
        size=$(du -h "$backup_file" | cut -f1)
        local date
        date=$(stat -c %y "$backup_file" 2>/dev/null | cut -d' ' -f1 || echo "N/A")

        printf "%-40s %-15s %-20s\n" "$basename" "$size" "$date"
    done <<< "$backups"

    echo ""
    local backup_count
    backup_count=$(echo "$backups" | wc -l)
    echo "   Total backups: ${backup_count}"
    echo ""
}

clean_old_backups() {
    local days=${1:-30}
    local backup_dir="$PROJECT_ROOT/backups"

    log_info "Cleaning backups older than ${days} days..."

    if [ ! -d "$backup_dir" ]; then
        log_info "No backups directory found"
        return 0
    fi

    local old_backups
    old_backups=$(find "$backup_dir" -name "tenant_*.tar.gz" -type f -mtime +${days} 2>/dev/null || true)

    if [ -z "$old_backups" ]; then
        log_info "No old backups found"
        return 0
    fi

    local count
    count=$(echo "$old_backups" | wc -l)

    echo ""
    echo "Found ${count} backup(s) older than ${days} days:"
    echo "$old_backups" | while IFS= read -r file; do
        echo "   - $(basename "$file")"
    done
    echo ""

    read -rp "Delete these backups? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo "$old_backups" | while IFS= read -r file; do
            rm -f "$file"
            # Also remove credentials file if exists
            local cred_file="${file%.tar.gz}_credentials.env"
            [ -f "$cred_file" ] && rm -f "$cred_file"
        done
        log_success "Deleted ${count} old backup(s)"
    else
        log_info "Cleanup cancelled"
    fi
}

###############################################################################
# Main Function
###############################################################################

usage() {
    echo ""
    echo "Usage: $0 [OPTIONS] [TENANT_ID]"
    echo ""
    echo "Options:"
    echo "   --all             Backup all tenants"
    echo "   --list [tenant]   List available backups (optionally filter by tenant)"
    echo "   --clean [days]    Clean backups older than N days (default: 30)"
    echo ""
    echo "Examples:"
    echo "   $0 tenant1                # Backup single tenant"
    echo "   $0 --all                  # Backup all tenants"
    echo "   $0 --list                 # List all backups"
    echo "   $0 --list tenant1         # List backups for tenant1"
    echo "   $0 --clean 7              # Delete backups older than 7 days"
    echo ""
}

main() {
    local mode="single"
    local tenant_id=""
    local clean_days=30

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)
                mode="all"
                shift
                ;;
            --list)
                mode="list"
                shift
                tenant_id="${1:-}"
                [ -n "$tenant_id" ] && shift
                ;;
            --clean)
                mode="clean"
                shift
                clean_days="${1:-30}"
                [ -n "$clean_days" ] && shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                tenant_id="$1"
                shift
                ;;
        esac
    done

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        Solr Multi-Tenancy: Tenant Backup                   ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    case "$mode" in
        single)
            if [ -z "$tenant_id" ]; then
                log_error "Tenant ID required"
                usage
                exit 1
            fi

            if ! check_tenant_exists "$tenant_id"; then
                exit 1
            fi

            if backup_tenant "$tenant_id"; then
                log_success "Backup operation completed successfully"
            else
                log_error "Backup operation failed"
                exit 1
            fi
            ;;

        all)
            if backup_all_tenants; then
                log_success "Backup operation completed"
            else
                log_error "Backup operation failed"
                exit 1
            fi
            ;;

        list)
            list_backups "$tenant_id"
            ;;

        clean)
            clean_old_backups "$clean_days"
            ;;
    esac

    echo ""
}

main "$@"
