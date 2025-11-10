#!/usr/bin/env bash
# Initialize Solr directories with correct permissions
# Only touches Solr-specific directories: logs, data, backups
# Debian/Ubuntu compatible version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

# Solr runs as UID:GID 8983:8983 inside container
SOLR_UID=8983
SOLR_GID=8983

# Only these directories are managed (Solr-specific only!)
SOLR_DIRS=("logs" "data" "backups")

echo "========================================"
echo "  Solr Permissions Initialization"
echo "========================================"
echo ""
log_info "Preparing directories for Solr container (UID:GID ${SOLR_UID}:${SOLR_GID})"
echo ""

# Detect OS for stat command compatibility
OS_TYPE="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE="$ID"
fi

# Function to get file ownership in a cross-platform way
# Works on Debian/Ubuntu, Fedora/RHEL, and macOS
get_owner() {
    local path="$1"
    if [ -d "$path" ] || [ -f "$path" ]; then
        # Try GNU stat (Linux)
        if stat -c '%u:%g' "$path" 2>/dev/null; then
            return 0
        # Try BSD stat (macOS)
        elif stat -f '%u:%g' "$path" 2>/dev/null; then
            return 0
        # Fallback to ls parsing (works everywhere)
        else
            local uid gid
            uid=$(ls -ldn "$path" | awk '{print $3}')
            gid=$(ls -ldn "$path" | awk '{print $4}')
            echo "${uid}:${gid}"
            return 0
        fi
    fi
    echo "unknown"
    return 1
}

# Function to run command with sudo if needed
# Try without sudo first, fall back to sudo if permission denied
run_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        # Already root, no sudo needed
        "$@"
    else
        # Try without sudo first
        if ! "$@" 2>/dev/null; then
            # If failed, check if sudo is available
            if command -v sudo >/dev/null 2>&1; then
                log_warn "Permission denied, trying with sudo..."
                sudo "$@"
            else
                log_error "Permission denied and sudo not available"
                log_error "Please run this script as root or install sudo"
                return 1
            fi
        fi
    fi
}

# Detect if running in Docker volume mode
# If directories don't exist yet, Docker will create them
# This is expected and not an error
USING_DOCKER_VOLUMES=false
if command -v docker >/dev/null 2>&1; then
    if docker volume ls 2>/dev/null | grep -q "${CUSTOMER_NAME:-solr}"; then
        USING_DOCKER_VOLUMES=true
        log_info "Detected Docker volumes in use"
    fi
fi

# Create and set permissions for each Solr directory
for dir in "${SOLR_DIRS[@]}"; do
    dir_path="$PROJECT_DIR/$dir"

    # Create directory if it doesn't exist
    if [ ! -d "$dir_path" ]; then
        log_info "Creating directory: $dir"
        if ! run_cmd mkdir -p "$dir_path"; then
            if [ "$USING_DOCKER_VOLUMES" = true ]; then
                log_warn "Cannot create $dir (Docker will create it as volume)"
                continue
            else
                log_error "Failed to create $dir"
                exit 1
            fi
        fi
    fi

    # Get current owner using cross-platform function
    current_owner=$(get_owner "$dir_path")

    # Set ownership to Solr user
    if [ "$current_owner" != "${SOLR_UID}:${SOLR_GID}" ]; then
        log_info "Setting ownership: $dir → ${SOLR_UID}:${SOLR_GID} (current: $current_owner)"
        if ! run_cmd chown -R ${SOLR_UID}:${SOLR_GID} "$dir_path"; then
            log_error "Failed to set ownership for $dir"
            exit 1
        fi
    else
        log_success "Ownership OK: $dir (already ${SOLR_UID}:${SOLR_GID})"
    fi

    # Set permissions: 755 (rwxr-xr-x)
    log_info "Setting permissions: $dir → 755"
    if ! run_cmd chmod -R 755 "$dir_path"; then
        log_error "Failed to set permissions for $dir"
        exit 1
    fi
done

echo ""
log_success "All Solr directories initialized!"
echo ""
echo "Directories prepared:"
for dir in "${SOLR_DIRS[@]}"; do
    dir_path="$PROJECT_DIR/$dir"
    if [ -d "$dir_path" ]; then
        current_owner=$(get_owner "$dir_path")
        echo "  ✓ $dir/ (owned by ${current_owner})"
    else
        echo "  ⚠ $dir/ (will be created by Docker)"
    fi
done
echo ""
echo "These directories are now writable by Solr container."
echo "No other directories were modified."
echo ""
echo "OS detected: $OS_TYPE"
echo "========================================"
