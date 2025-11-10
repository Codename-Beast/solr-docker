#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

SOLR_PORT=${SOLR_PORT:-8983}
CONTAINER_NAME="${CUSTOMER_NAME}_solr"
CORE_NAME="${CUSTOMER_NAME}_core"
BACKUP_NAME="backup_$(date +%Y%m%d_%H%M%S)"

echo "=========================================="
echo "Solr Backup"
echo "=========================================="

# Check if core exists
if ! curl -sf -u "$SOLR_ADMIN_USER:$SOLR_ADMIN_PASSWORD" \
    "http://localhost:$SOLR_PORT/solr/admin/cores?action=STATUS&core=$CORE_NAME&wt=json" | \
    grep -q "\"$CORE_NAME\""; then
    echo "Error: Core '$CORE_NAME' does not exist"
    exit 1
fi

echo "Creating backup: $BACKUP_NAME"
echo "Core: $CORE_NAME"

# Create backup
docker exec "$CONTAINER_NAME" solr create_backup \
    -c "$CORE_NAME" \
    -d /var/solr/backups \
    -n "$BACKUP_NAME"

echo ""
echo "✓ Backup created successfully"
echo "Backup location: ./backups/$BACKUP_NAME"

# Cleanup old backups if retention is set
if [ -n "$BACKUP_RETENTION_DAYS" ] && [ "$BACKUP_RETENTION_DAYS" -gt 0 ]; then
    echo "Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
    find "$PROJECT_DIR/backups" -name "backup_*" -type d -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null || true
fi

echo "=========================================="
