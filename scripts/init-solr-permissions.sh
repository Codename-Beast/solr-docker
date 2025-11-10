#!/usr/bin/env bash
# Initialize Solr directories with correct permissions
# Only touches Solr-specific directories: logs, data, backups

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

# Function to run command with sudo if needed
# Try without sudo first, fall back to sudo if permission denied
run_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        # Already root, no sudo needed
        "$@"
    else
        # Try without sudo first
        "$@" 2>/dev/null || {
            # If failed, try with sudo
            sudo "$@"
        }
    fi
}

# Create and set permissions for each Solr directory
for dir in "${SOLR_DIRS[@]}"; do
    dir_path="$PROJECT_DIR/$dir"

    # Create directory if it doesn't exist
    if [ ! -d "$dir_path" ]; then
        log_info "Creating directory: $dir"
        run_cmd mkdir -p "$dir_path"
    fi

    # Get current owner
    current_owner=$(stat -c '%u:%g' "$dir_path" 2>/dev/null || echo "unknown")

    # Set ownership to Solr user
    if [ "$current_owner" != "${SOLR_UID}:${SOLR_GID}" ]; then
        log_info "Setting ownership: $dir → ${SOLR_UID}:${SOLR_GID}"
        run_cmd chown -R ${SOLR_UID}:${SOLR_GID} "$dir_path"
    else
        log_success "Ownership OK: $dir (already ${SOLR_UID}:${SOLR_GID})"
    fi

    # Set permissions: 755 (rwxr-xr-x)
    log_info "Setting permissions: $dir → 755"
    run_cmd chmod -R 755 "$dir_path"
done

echo ""
log_success "All Solr directories initialized!"
echo ""
echo "Directories prepared:"
for dir in "${SOLR_DIRS[@]}"; do
    echo "  ✓ $dir/ (owned by ${SOLR_UID}:${SOLR_GID})"
done
echo ""
echo "These directories are now writable by Solr container."
echo "No other directories were modified."
echo "========================================"
