#!/usr/bin/env bash
# Common Shell Script Library v3.4.0
# Provides: Retry logic, logging, error handling, file locking, Solr utilities
# Usage: source /path/to/common.sh

# ============================================================================
# COLOR CONSTANTS
# ============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[✗]${NC} $*" >&2
}

log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

die() {
    log_error "$*"
    exit 1
}

# Trap errors and cleanup
setup_error_handling() {
    set -euo pipefail
    trap 'error_handler $? $LINENO' ERR
}

error_handler() {
    local exit_code=$1
    local line_no=$2
    log_error "Script failed at line $line_no with exit code $exit_code"
}

# ============================================================================
# RETRY LOGIC
# ============================================================================

# Retry a command with exponential backoff
# Usage: retry_command <max_attempts> <initial_delay> <command> [args...]
#
# Example:
#   retry_command 5 2 curl -sf http://localhost:8983/solr/admin/ping
#
# Parameters:
#   max_attempts:   Maximum number of retry attempts (e.g., 5)
#   initial_delay:  Initial delay in seconds (doubles each retry, e.g., 2)
#   command:        Command to execute with all its arguments
#
# Returns:
#   0 if command succeeds, 1 if all retries exhausted
retry_command() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local command=("$@")
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_debug "Attempt $attempt/$max_attempts: ${command[*]}"

        if "${command[@]}"; then
            log_debug "Command succeeded on attempt $attempt"
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_warn "Attempt $attempt failed. Retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi

        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts: ${command[*]}"
    return 1
}

# Simple retry wrapper for curl with sensible defaults
# Usage: retry_curl <url> [curl_options...]
retry_curl() {
    retry_command 5 2 curl --max-time 10 --retry 0 "$@"
}

# Retry with fixed delay (no exponential backoff)
# Usage: retry_fixed <max_attempts> <delay> <command> [args...]
retry_fixed() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local command=("$@")
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_debug "Attempt $attempt/$max_attempts: ${command[*]}"

        if "${command[@]}"; then
            log_debug "Command succeeded on attempt $attempt"
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_warn "Attempt $attempt failed. Retrying in ${delay}s..."
            sleep "$delay"
        fi

        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts: ${command[*]}"
    return 1
}

# ============================================================================
# FILE LOCKING
# ============================================================================

# Acquire exclusive file lock
# Usage: acquire_lock <lockfile> [timeout_seconds]
#
# Example:
#   acquire_lock "/tmp/myapp.lock" 30
#   # ... critical section ...
#   release_lock "/tmp/myapp.lock"
#
# Returns:
#   0 on success, 1 on timeout
acquire_lock() {
    local lockfile=$1
    local timeout=${2:-300}  # Default 5 minutes
    local elapsed=0

    # Create lockfile directory if needed
    mkdir -p "$(dirname "$lockfile")"

    log_debug "Acquiring lock: $lockfile (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        # Try to create lockfile exclusively
        if (set -o noclobber; echo $$ > "$lockfile") 2>/dev/null; then
            log_debug "Lock acquired: $lockfile (PID: $$)"
            return 0
        fi

        # Check if lock is stale (process doesn't exist)
        if [ -f "$lockfile" ]; then
            local lock_pid
            lock_pid=$(cat "$lockfile" 2>/dev/null || echo "")
            if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log_warn "Removing stale lock (PID $lock_pid no longer exists)"
                rm -f "$lockfile"
                continue
            fi
        fi

        log_debug "Waiting for lock... (${elapsed}s/${timeout}s)"
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "Failed to acquire lock after ${timeout}s: $lockfile"
    return 1
}

# Release file lock
# Usage: release_lock <lockfile>
release_lock() {
    local lockfile=$1

    if [ -f "$lockfile" ]; then
        local lock_pid
        lock_pid=$(cat "$lockfile" 2>/dev/null || echo "")

        # Only remove lock if we own it
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$lockfile"
            log_debug "Lock released: $lockfile"
        else
            log_warn "Lock not owned by this process ($$), not removing: $lockfile"
        fi
    fi
}

# Execute command with automatic locking
# Usage: with_lock <lockfile> <command> [args...]
with_lock() {
    local lockfile=$1
    shift
    local command=("$@")

    if acquire_lock "$lockfile"; then
        # Ensure lock is released on exit
        trap "release_lock '$lockfile'" EXIT INT TERM

        "${command[@]}"
        local exit_code=$?

        release_lock "$lockfile"
        trap - EXIT INT TERM

        return $exit_code
    else
        die "Failed to acquire lock: $lockfile"
    fi
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

# Check if command exists
require_command() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: $cmd"
    fi
}

# Check if file exists
require_file() {
    local file=$1
    if [ ! -f "$file" ]; then
        die "Required file not found: $file"
    fi
}

# Check if directory exists
require_dir() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        die "Required directory not found: $dir"
    fi
}

# Check if environment variable is set
require_env() {
    local var=$1
    if [ -z "${!var:-}" ]; then
        die "Required environment variable not set: $var"
    fi
}

# ============================================================================
# DOCKER HELPERS
# ============================================================================

# Wait for docker container to be healthy
# Usage: wait_for_container <container_name> [timeout_seconds]
wait_for_container() {
    local container=$1
    local timeout=${2:-120}
    local elapsed=0

    log_info "Waiting for container to be healthy: $container"

    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not-found")

        case $status in
            healthy)
                log_success "Container is healthy: $container"
                return 0
                ;;
            starting)
                log_debug "Container is starting... (${elapsed}s/${timeout}s)"
                ;;
            unhealthy)
                log_warn "Container is unhealthy: $container"
                return 1
                ;;
            not-found)
                log_debug "Container not found yet: $container"
                ;;
            *)
                # No healthcheck defined
                log_debug "Container running (no healthcheck): $container"
                if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                    return 0
                fi
                ;;
        esac

        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "Container health check timeout after ${timeout}s: $container"
    return 1
}

# Check if docker compose service is running
# Usage: is_service_running <service_name>
is_service_running() {
    local service=$1
    docker compose ps "$service" 2>/dev/null | grep -q "Up"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

# Load environment variables from .env file
load_env() {
    local env_file="${1:-.env}"

    if [ -f "$env_file" ]; then
        log_debug "Loading environment from: $env_file"
        # Export all variables from .env
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    else
        log_warn "Environment file not found: $env_file"
    fi
}

# Get project directory (assumes scripts/lib/common.sh structure)
get_project_dir() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    echo "$script_dir"
}

# ============================================================================
# SOLR UTILITIES (v3.4.0 - Multi-Tenancy Support)
# ============================================================================

# Configurable timeouts (loaded from .env with sensible defaults)
SOLR_STARTUP_TIMEOUT="${SOLR_STARTUP_TIMEOUT:-90}"
SOLR_HEALTH_CHECK_INTERVAL="${SOLR_HEALTH_CHECK_INTERVAL:-2}"
SOLR_PROGRESS_INTERVAL="${SOLR_PROGRESS_INTERVAL:-10}"
CONTAINER_CHECK_TIMEOUT="${CONTAINER_CHECK_TIMEOUT:-30}"
BACKUP_LOCK_TIMEOUT="${BACKUP_LOCK_TIMEOUT:-300}"
TRANSACTION_LOCK_TIMEOUT="${TRANSACTION_LOCK_TIMEOUT:-300}"

# Check if a specific container is running (fast check for tenant scripts)
# Usage: check_container_running "solr" || die "Solr not running"
check_container_running() {
    local container_name=$1
    local timeout=${2:-5}
    local waited=0

    log_debug "Checking if container '$container_name' is running..."

    while [ $waited -lt $timeout ]; do
        if docker compose ps "$container_name" 2>/dev/null | grep -q 'Up'; then
            log_debug "Container '$container_name' is running"
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Check if container is running, exit with helpful message if not
# Usage: require_container_running "solr"
require_container_running() {
    local container_name=$1

    if ! check_container_running "$container_name" 5; then
        log_error "Container '$container_name' is not running"
        log_error ""
        log_error "Start it with one of these commands:"
        log_error "  make start"
        log_error "  docker compose up -d $container_name"
        log_error ""
        log_error "Check status with:"
        log_error "  docker compose ps"
        log_error "  docker compose logs $container_name"
        exit 1
    fi
}

# Wait for Solr to become ready with progress indication
# Usage: wait_for_solr [timeout] [on_timeout_callback]
# Returns: 0 on success, 1 on timeout
wait_for_solr() {
    local max_wait=${1:-$SOLR_STARTUP_TIMEOUT}
    local on_timeout_callback=${2:-}
    local waited=0
    local last_msg_time=0
    local check_interval=${SOLR_HEALTH_CHECK_INTERVAL}
    local progress_interval=${SOLR_PROGRESS_INTERVAL}

    log_info "Waiting for Solr to be ready (timeout: ${max_wait}s)..."

    # Validate credentials are set
    if [ -z "${SOLR_ADMIN_USER:-}" ] || [ -z "${SOLR_ADMIN_PASSWORD:-}" ]; then
        log_error "SOLR_ADMIN_USER and SOLR_ADMIN_PASSWORD must be set in .env"
        return 1
    fi

    while ! docker compose exec -T solr curl -sf \
        -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://localhost:8983/solr/admin/info/system" > /dev/null 2>&1; do

        sleep "$check_interval"
        waited=$((waited + check_interval))

        # Progress update at regular intervals
        if [ $((waited - last_msg_time)) -ge $progress_interval ] && [ $waited -lt $max_wait ]; then
            echo "   Still waiting... (${waited}s/${max_wait}s)"
            last_msg_time=$waited
        fi

        if [ $waited -ge $max_wait ]; then
            log_error "Solr did not become ready within ${max_wait} seconds"
            log_error ""
            log_error "Troubleshooting steps:"
            log_error "  1. Check container status:"
            log_error "     docker compose ps solr"
            log_error ""
            log_error "  2. Check Solr logs:"
            log_error "     docker compose logs solr"
            log_error "     docker compose logs --tail 50 solr"
            log_error ""
            log_error "  3. Check if container is out of memory:"
            log_error "     docker stats solr --no-stream"
            log_error ""
            log_error "  4. Try increasing timeout in .env:"
            log_error "     SOLR_STARTUP_TIMEOUT=$((max_wait + 30))"

            # Call optional callback (e.g., rollback transaction)
            if [ -n "$on_timeout_callback" ] && type "$on_timeout_callback" &>/dev/null; then
                log_error ""
                log_error "Executing cleanup: $on_timeout_callback"
                $on_timeout_callback
            fi

            return 1
        fi
    done

    log_success "Solr is ready (took ${waited}s)"
    return 0
}

# Validate tenant ID format
# Usage: validate_tenant_id "prod" || die "Invalid tenant ID"
validate_tenant_id() {
    local tenant_id=$1

    # Allow alphanumeric, underscore, hyphen (3-32 chars)
    if ! [[ "$tenant_id" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        log_error "Invalid tenant ID: $tenant_id"
        log_error "Requirements:"
        log_error "  - 3-32 characters"
        log_error "  - Only letters, numbers, underscore, hyphen"
        log_error "  - No spaces or special characters"
        return 1
    fi
    return 0
}

# ============================================================================
# EXPORT FUNCTIONS (for subshells)
# ============================================================================

export -f log_info log_success log_warn log_error log_debug
export -f die setup_error_handling error_handler
export -f retry_command retry_curl retry_fixed
export -f acquire_lock release_lock with_lock
export -f require_command require_file require_dir require_env
export -f wait_for_container is_service_running
export -f load_env get_project_dir
export -f check_container_running require_container_running wait_for_solr validate_tenant_id

# Export configuration variables
export SOLR_STARTUP_TIMEOUT SOLR_HEALTH_CHECK_INTERVAL SOLR_PROGRESS_INTERVAL
export CONTAINER_CHECK_TIMEOUT BACKUP_LOCK_TIMEOUT TRANSACTION_LOCK_TIMEOUT
