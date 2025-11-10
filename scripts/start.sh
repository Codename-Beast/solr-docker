#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Starting Solr Moodle Docker"
echo "=========================================="

# Check if .env exists
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "Error: .env file not found"
    echo "Please copy .env.example to .env and configure it"
    exit 1
fi

# Load environment
source "$PROJECT_DIR/.env"

# Allow CONFIG_DIR to be overridden (v3.4.1)
CONFIG_DIR="${SOLR_CONFIG_DIR:-$PROJECT_DIR/config}"

# Check if config files exist
if [ ! -f "$CONFIG_DIR/security.json" ]; then
    echo "Configuration files not found. Generating..."
    "$SCRIPT_DIR/generate-config.sh"
fi

# Start Docker Compose
cd "$PROJECT_DIR"
echo "Starting Docker services..."
docker compose up -d

# Wait for Solr to be healthy
echo "Waiting for Solr to be healthy..."
for i in {1..30}; do
    if docker compose ps | grep -q "healthy"; then
        echo "✓ Solr is healthy!"
        break
    fi
    echo "  Waiting... ($i/30)"
    sleep 2
done

# Show status
echo ""
echo "=========================================="
docker compose ps
echo "=========================================="
echo ""
echo "Solr is running at: http://localhost:${SOLR_PORT:-8983}/solr"
echo "Admin UI: http://localhost:${SOLR_PORT:-8983}/solr/#/"
echo ""
echo "Credentials:"
echo "  Admin:    ${SOLR_ADMIN_USER}/${SOLR_ADMIN_PASSWORD}"
echo "  Support:  ${SOLR_SUPPORT_USER}/${SOLR_SUPPORT_PASSWORD}"
echo "  Customer: ${SOLR_CUSTOMER_USER}/${SOLR_CUSTOMER_PASSWORD}"
echo ""
echo "Monitoring:"
echo "  Grafana:      http://localhost:${GRAFANA_PORT:-3000}"
echo "  Prometheus:   http://localhost:${PROMETHEUS_PORT:-9090}"
echo "  Alertmanager: http://localhost:${ALERTMANAGER_PORT:-9093}"
echo "  Metrics:      http://localhost:${EXPORTER_PORT:-9854}/metrics"
echo ""
echo "Quick commands:"
echo "  make grafana        - Open Grafana dashboard"
echo "  make metrics        - Show current metrics"
echo "  make health         - Check health status"
echo "=========================================="
