#!/usr/bin/env bash
###############################################################################
# Atomic Security.json Manager v3.4.0
# Provides file-locking and transactional updates to prevent race conditions
###############################################################################

set -euo pipefail

# Configuration (v3.4.0: Configurable from .env)
SECURITY_JSON="${SECURITY_JSON:-/var/solr/data/security.json}"
LOCK_DIR="/tmp/security-json-lock"
LOCK_TIMEOUT="${TRANSACTION_LOCK_TIMEOUT:-300}"  # v3.4.0: Configurable (default: 5min)
BACKUP_DIR="/var/solr/backup/security"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

###############################################################################
# Locking Mechanism
###############################################################################

acquire_lock() {
    local timeout=${1:-$LOCK_TIMEOUT}
    local elapsed=0
    local backoff=1

    while [ $elapsed -lt $timeout ]; do
        # Try to create lock directory atomically
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            # Store lock metadata
            echo "$$" > "$LOCK_DIR/pid"
            echo "$(date +%s)" > "$LOCK_DIR/timestamp"
            echo "$(hostname)" > "$LOCK_DIR/hostname"
            echo "$(whoami)" > "$LOCK_DIR/user"
            return 0
        fi

        # Lock exists - check if it's stale
        if [ -f "$LOCK_DIR/pid" ]; then
            local lock_pid
            lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")

            if [ -n "$lock_pid" ]; then
                # Check if process still exists
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    local lock_age=$(($(date +%s) - $(cat "$LOCK_DIR/timestamp" 2>/dev/null || echo 0)))
                    log_warning "Removing stale lock (PID $lock_pid, age: ${lock_age}s)"
                    rm -rf "$LOCK_DIR"
                    continue
                fi
            fi
        fi

        # Wait with exponential backoff
        if [ $elapsed -eq 0 ]; then
            echo "⏳ Waiting for lock..."
        fi
        sleep "$backoff"
        elapsed=$((elapsed + backoff))
        backoff=$((backoff * 2))
        [ $backoff -gt 10 ] && backoff=10  # Cap at 10s

        if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            echo "   Still waiting... (${elapsed}s/${timeout}s)"
        fi
    done

    log_error "Could not acquire lock after ${timeout}s"
    return 1
}

release_lock() {
    if [ -d "$LOCK_DIR" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")

        # Only remove if we own the lock
        if [ "$lock_pid" = "$$" ]; then
            rm -rf "$LOCK_DIR"
        else
            log_warning "Lock owned by different process ($lock_pid vs $$)"
        fi
    fi
}

###############################################################################
# Backup Management
###############################################################################

create_backup() {
    local description=${1:-manual}

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/security_${timestamp}_${description}.json"

    if [ -f "$SECURITY_JSON" ]; then
        cp "$SECURITY_JSON" "$backup_file"

        # Calculate checksum
        local checksum
        checksum=$(sha256sum "$backup_file" | awk '{print $1}')

        # Store metadata
        cat > "${backup_file}.meta" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "description": "$description",
  "checksum": "$checksum",
  "pid": $$,
  "hostname": "$(hostname)",
  "user": "$(whoami)"
}
EOF

        echo "  ✓ Backup created: $(basename "$backup_file")"
        return 0
    else
        log_warning "No security.json to backup"
        return 1
    fi
}

rotate_backups() {
    local retention_days=${1:-30}

    if [ -d "$BACKUP_DIR" ]; then
        local deleted_count=0
        while IFS= read -r file; do
            rm "$file"
            rm -f "${file}.meta"
            deleted_count=$((deleted_count + 1))
        done < <(find "$BACKUP_DIR" -name "security_*.json" -type f -mtime "+${retention_days}" 2>/dev/null)

        if [ $deleted_count -gt 0 ]; then
            echo "  ✓ Rotated $deleted_count old backup(s)"
        fi
    fi
}

###############################################################################
# Atomic Update Operations
###############################################################################

atomic_update() {
    local jq_filter=$1
    local description=$2
    shift 2
    local jq_args=("$@")

    echo "🔒 Acquiring lock for: $description"

    if ! acquire_lock; then
        log_error "Failed to acquire lock"
        return 1
    fi

    # NOTE: Lock is explicitly released before each return (trap EXIT doesn't work in functions)

    # Create backup before modification
    create_backup "$(echo "$description" | tr ' ' '_')"

    # Create temporary file
    local temp_file="${SECURITY_JSON}.tmp.$$"

    # Apply jq filter
    if jq "${jq_args[@]}" "$jq_filter" "$SECURITY_JSON" > "$temp_file" 2>&1; then
        # Validate result
        if jq empty "$temp_file" 2>/dev/null; then
            # Additional validation: check required fields
            if ! jq -e '.authentication.credentials | length > 0' "$temp_file" >/dev/null 2>&1; then
                log_error "Validation failed - no credentials after update"
                rm "$temp_file"
                release_lock
                return 1
            fi

            # Atomic move (rename is atomic on same filesystem)
            mv "$temp_file" "$SECURITY_JSON"
            chmod 600 "$SECURITY_JSON"
            chown 8983:8983 "$SECURITY_JSON" 2>/dev/null || true

            log_success "$description"
            release_lock
            return 0
        else
            log_error "Invalid JSON after update"
            rm "$temp_file"
            release_lock
            return 1
        fi
    else
        log_error "jq filter failed"
        cat "$temp_file" 2>&1 | head -5
        rm -f "$temp_file"
        release_lock
        return 1
    fi
}

###############################################################################
# High-Level Operations
###############################################################################

add_credential() {
    local username=$1
    local password_hash=$2

    atomic_update \
        --arg user "$username" \
        --arg hash "$password_hash" \
        '.authentication.credentials[$user] = $hash' \
        "Add credential for user: $username"
}

remove_credential() {
    local username=$1

    atomic_update \
        --arg user "$username" \
        'del(.authentication.credentials[$user])' \
        "Remove credential for user: $username"
}

add_user_role() {
    local username=$1
    local role=$2

    atomic_update \
        --arg user "$username" \
        --arg role "$role" \
        '.authorization."user-role"[$user] = [$role]' \
        "Add role $role to user: $username"
}

remove_user_role() {
    local username=$1

    atomic_update \
        --arg user "$username" \
        'del(.authorization."user-role"[$user])' \
        "Remove user from roles: $username"
}

add_permission() {
    local permission_json=$1

    atomic_update \
        --argjson perm "$permission_json" \
        '.authorization.permissions += [$perm]' \
        "Add permission: $(echo "$permission_json" | jq -r '.name')"
}

remove_permission() {
    local permission_name=$1

    atomic_update \
        --arg name "$permission_name" \
        '.authorization.permissions |= map(select(.name != $name))' \
        "Remove permission: $permission_name"
}

###############################################################################
# Transaction Support (Multi-Step Operations)
###############################################################################

begin_transaction() {
    TRANSACTION_ID="tx_$$_$(date +%s)"
    TRANSACTION_LOG="/tmp/security_transaction_${TRANSACTION_ID}.log"
    TRANSACTION_BACKUP="${SECURITY_JSON}.tx_backup.${TRANSACTION_ID}"

    # Acquire lock for entire transaction (v3.4.0: Use configurable timeout)
    if ! acquire_lock "${TRANSACTION_LOCK_TIMEOUT:-300}"; then
        log_error "Failed to acquire lock for transaction (timeout: ${TRANSACTION_LOCK_TIMEOUT:-300}s)"
        return 1
    fi

    # CRITICAL FIX v3.3.2: Add error handling to release lock on failure
    # Create transaction backup
    if [ -f "$SECURITY_JSON" ]; then
        if ! cp "$SECURITY_JSON" "$TRANSACTION_BACKUP" 2>/dev/null; then
            log_error "Failed to create transaction backup"
            release_lock
            return 1
        fi
    fi

    if ! echo "BEGIN TRANSACTION $TRANSACTION_ID at $(date -Iseconds)" > "$TRANSACTION_LOG" 2>/dev/null; then
        log_error "Failed to create transaction log"
        rm -f "$TRANSACTION_BACKUP"
        release_lock
        return 1
    fi
    echo "  Backup: $TRANSACTION_BACKUP" >> "$TRANSACTION_LOG"

    echo "🔄 Transaction $TRANSACTION_ID started"
}

log_operation() {
    if [ -n "${TRANSACTION_ID:-}" ]; then
        echo "$(date +%s) $*" >> "$TRANSACTION_LOG"
    fi
}

rollback_transaction() {
    if [ -z "${TRANSACTION_ID:-}" ]; then
        log_warning "No active transaction to rollback"
        return 1
    fi

    log_error "Rolling back transaction $TRANSACTION_ID"

    # Restore from backup
    if [ -f "$TRANSACTION_BACKUP" ]; then
        cp "$TRANSACTION_BACKUP" "$SECURITY_JSON"
        chmod 600 "$SECURITY_JSON"
        chown 8983:8983 "$SECURITY_JSON" 2>/dev/null || true
        log_success "Restored from transaction backup"
    else
        log_warning "Transaction backup not found!"
    fi

    # Log rollback
    echo "ROLLBACK at $(date -Iseconds)" >> "$TRANSACTION_LOG"

    # Archive transaction log
    mkdir -p "/var/solr/logs/transactions" 2>/dev/null || true
    mv "$TRANSACTION_LOG" "/var/solr/logs/transactions/rollback_${TRANSACTION_ID}.log" 2>/dev/null || true

    # Cleanup
    rm -f "$TRANSACTION_BACKUP"
    release_lock

    unset TRANSACTION_ID
    unset TRANSACTION_LOG
    unset TRANSACTION_BACKUP

    return 1
}

commit_transaction() {
    if [ -z "${TRANSACTION_ID:-}" ]; then
        log_warning "No active transaction to commit"
        return 1
    fi

    log_success "Committing transaction $TRANSACTION_ID"

    # Log commit
    echo "COMMIT at $(date -Iseconds)" >> "$TRANSACTION_LOG"

    # Archive transaction log
    mkdir -p "/var/solr/logs/transactions" 2>/dev/null || true
    mv "$TRANSACTION_LOG" "/var/solr/logs/transactions/commit_${TRANSACTION_ID}.log" 2>/dev/null || true

    # Remove backup (transaction successful)
    rm -f "$TRANSACTION_BACKUP"

    # Release lock
    release_lock

    unset TRANSACTION_ID
    unset TRANSACTION_LOG
    unset TRANSACTION_BACKUP

    return 0
}

###############################################################################
# Export functions for use in other scripts
###############################################################################

export -f acquire_lock release_lock
export -f create_backup rotate_backups
export -f atomic_update
export -f add_credential remove_credential
export -f add_user_role remove_user_role
export -f add_permission remove_permission
export -f begin_transaction log_operation rollback_transaction commit_transaction
