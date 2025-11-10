#!/usr/bin/env bash
# Automated Backup Script for Cron v2.3.0
# Runs backups on schedule
# Usage: Called by crond in backup-cron container

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common library
# shellcheck source=scripts/lib/common.sh
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    source "$SCRIPT_DIR/lib/common.sh"
else
    # Fallback logging if common.sh not available
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[✓] $*"; }
    log_error() { echo "[✗] $*" >&2; }
    log_warn() { echo "[⚠] $*" >&2; }
    die() { log_error "$*"; exit 1; }
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

BACKUP_DIR="${BACKUP_DIR:-/var/solr/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
MIN_BACKUP_SIZE_MB="${MIN_BACKUP_SIZE_MB:-1}"
SOLR_HOST="${SOLR_HOST:-solr:8983}"
CUSTOMER_NAME="${CUSTOMER_NAME:-solr}"

# ============================================================================
# BACKUP FUNCTIONS
# ============================================================================

perform_backup() {
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_name="backup_${CUSTOMER_NAME}_${timestamp}"
    local backup_path="$BACKUP_DIR/$backup_name"

    log_info "Starting backup: $backup_name"

    # Create backup directory
    mkdir -p "$BACKUP_DIR"

    # Get list of cores
    local cores
    if ! cores=$(curl -sf "http://$SOLR_HOST/solr/admin/cores?action=STATUS&wt=json" | \
        grep -o '"name":"[^"]*"' | cut -d'"' -f4); then
        log_error "Failed to list Solr cores"
        return 1
    fi

    if [ -z "$cores" ]; then
        log_warn "No cores found to backup"
        return 0
    fi

    # Backup each core
    local core_count=0
    for core in $cores; do
        log_info "Backing up core: $core"

        # Trigger backup via Solr API
        if curl -sf "http://$SOLR_HOST/solr/$core/replication?command=backup&location=$BACKUP_DIR&name=${backup_name}_${core}" >/dev/null; then
            log_success "Backed up core: $core"
            core_count=$((core_count + 1))
        else
            log_error "Failed to backup core: $core"
        fi
    done

    # Verify backup exists and has reasonable size
    if [ -d "$backup_path" ]; then
        local backup_size_mb
        backup_size_mb=$(du -sm "$backup_path" 2>/dev/null | cut -f1)

        if [ "${backup_size_mb:-0}" -lt "$MIN_BACKUP_SIZE_MB" ]; then
            log_warn "Backup size ($backup_size_mb MB) is smaller than expected"
        fi

        log_success "Backup completed: $backup_name (${backup_size_mb} MB, $core_count cores)"
    else
        log_error "Backup directory not created"
        return 1
    fi

    return 0
}

cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."

    local deleted_count=0

    # Find and delete old backups
    while IFS= read -r -d '' backup_dir; do
        log_info "Deleting old backup: $(basename "$backup_dir")"
        rm -rf "$backup_dir"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

    if [ $deleted_count -gt 0 ]; then
        log_success "Deleted $deleted_count old backup(s)"
    else
        log_info "No old backups to delete"
    fi
}

check_disk_space() {
    log_info "Checking disk space..."

    local available_gb
    available_gb=$(df -BG "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')

    if [ "${available_gb:-0}" -lt 1 ]; then
        log_error "Low disk space: ${available_gb}GB available"
        return 1
    fi

    log_success "Disk space available: ${available_gb}GB"
    return 0
}

send_backup_notification() {
    local status=$1
    local message=$2

    # Optional: Send notification via webhook
    if [ -n "${BACKUP_WEBHOOK_URL:-}" ]; then
        curl -sf -X POST "$BACKUP_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"status\": \"$status\", \"message\": \"$message\", \"customer\": \"$CUSTOMER_NAME\", \"timestamp\": \"$(date -Iseconds)\"}" \
            >/dev/null 2>&1 || log_warn "Failed to send backup notification"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log_info "=========================================="
    log_info "Automated Backup - $(date)"
    log_info "=========================================="
    log_info "Customer: $CUSTOMER_NAME"
    log_info "Backup directory: $BACKUP_DIR"
    log_info "Retention: $RETENTION_DAYS days"
    echo ""

    # Check prerequisites
    if ! check_disk_space; then
        send_backup_notification "error" "Backup failed: Low disk space"
        exit 1
    fi

    # Perform backup
    if perform_backup; then
        log_success "Backup successful"
        cleanup_old_backups
        send_backup_notification "success" "Backup completed successfully"
        exit 0
    else
        log_error "Backup failed"
        send_backup_notification "error" "Backup failed"
        exit 1
    fi
}

# Run main function
main "$@"
