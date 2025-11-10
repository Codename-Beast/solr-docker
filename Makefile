.PHONY: help init preflight init-permissions config start stop restart logs health dashboard backup create-core test security-scan benchmark clean destroy \
        monitoring-up monitoring-down grafana prometheus alertmanager metrics \
        tenant-create tenant-delete tenant-list tenant-backup tenant-backup-all

# Default target
help:
	@echo "=========================================="
	@echo "Solr Moodle Docker - Available Commands"
	@echo "=========================================="
	@echo "Main Operations:"
	@echo "  make init           - Initialize environment (.env file)"
	@echo "  make config         - Generate configuration files"
	@echo "  make start          - Start all services (Solr + Monitoring)"
	@echo "  make stop           - Stop all services"
	@echo "  make restart        - Restart all services"
	@echo "  make logs           - Show Solr logs (follow)"
	@echo "  make health         - Check Solr health"
	@echo "  make dashboard      - Show comprehensive status dashboard"
	@echo "  make create-core    - Create Moodle core"
	@echo "  make backup         - Create backup of Solr core"
	@echo ""
	@echo "Monitoring:"
	@echo "  make monitoring-up  - Start monitoring stack only"
	@echo "  make monitoring-down- Stop monitoring stack"
	@echo "  make grafana        - Open Grafana in browser"
	@echo "  make prometheus     - Open Prometheus in browser"
	@echo "  make alertmanager   - Open Alertmanager in browser"
	@echo "  make metrics        - Show Solr metrics"
	@echo ""
	@echo "Testing & Security:"
	@echo "  make test           - Run integration test suite"
	@echo "  make security-scan  - Run Trivy security scan"
	@echo "  make benchmark      - Run performance benchmarks"
	@echo ""
	@echo "Multi-Tenancy (Optional):"
	@echo "  make tenant-create TENANT=<id>    - Create new tenant"
	@echo "  make tenant-delete TENANT=<id>    - Delete tenant (BACKUP=true for backup)"
	@echo "  make tenant-list                  - List all tenants"
	@echo "  make tenant-backup TENANT=<id>    - Backup single tenant"
	@echo "  make tenant-backup-all            - Backup all tenants"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean          - Stop and remove containers"
	@echo "  make destroy        - Remove everything (⚠ DESTRUCTIVE)"
	@echo "=========================================="

# Initialize environment
init:
	@if [ ! -f .env ]; then \
		echo "Creating .env file from .env.example..."; \
		cp .env.example .env; \
		echo "✓ Created .env file"; \
		echo "⚠ Please edit .env and set your passwords!"; \
	else \
		echo ".env file already exists"; \
	fi

# Pre-flight checks
preflight:
	@./scripts/preflight-check.sh

# Initialize Solr directories with correct permissions
init-permissions:
	@./scripts/init-solr-permissions.sh

# Generate configuration files
config:
	@./scripts/generate-config.sh

# Start services (with pre-flight checks)
# Note: Permission initialization not needed with Docker named volumes
start: preflight
	@./scripts/start.sh

# Stop services
stop:
	@./scripts/stop.sh

# Restart services
restart: stop start

# Show logs
logs:
	@./scripts/logs.sh

# Health check
health:
	@./scripts/health.sh

# Dashboard (comprehensive status)
dashboard:
	@./scripts/dashboard.sh

# Create core
create-core:
	@./scripts/create-core.sh

# Backup
backup:
	@./scripts/backup.sh

# Start monitoring stack
monitoring-up:
	@echo "Starting monitoring stack..."
	@docker compose up -d prometheus grafana alertmanager solr-exporter
	@echo "✓ Monitoring stack started"
	@echo "  Grafana:      http://localhost:3000"
	@echo "  Prometheus:   http://localhost:9090"
	@echo "  Alertmanager: http://localhost:9093"

# Stop monitoring stack
monitoring-down:
	@echo "Stopping monitoring stack..."
	@docker compose stop prometheus grafana alertmanager solr-exporter
	@echo "✓ Monitoring stack stopped"

# Open Grafana
grafana:
	@. .env 2>/dev/null || true; \
	PORT=$${GRAFANA_PORT:-3000}; \
	echo "Opening Grafana at http://localhost:$$PORT"; \
	command -v xdg-open >/dev/null && xdg-open "http://localhost:$$PORT" || \
	command -v open >/dev/null && open "http://localhost:$$PORT" || \
	echo "Please open http://localhost:$$PORT in your browser"

# Open Prometheus
prometheus:
	@. .env 2>/dev/null || true; \
	PORT=$${PROMETHEUS_PORT:-9090}; \
	echo "Opening Prometheus at http://localhost:$$PORT"; \
	command -v xdg-open >/dev/null && xdg-open "http://localhost:$$PORT" || \
	command -v open >/dev/null && open "http://localhost:$$PORT" || \
	echo "Please open http://localhost:$$PORT in your browser"

# Open Alertmanager
alertmanager:
	@. .env 2>/dev/null || true; \
	PORT=$${ALERTMANAGER_PORT:-9093}; \
	echo "Opening Alertmanager at http://localhost:$$PORT"; \
	command -v xdg-open >/dev/null && xdg-open "http://localhost:$$PORT" || \
	command -v open >/dev/null && open "http://localhost:$$PORT" || \
	echo "Please open http://localhost:$$PORT in your browser"

# Show metrics
metrics:
	@. .env 2>/dev/null || true; \
	PORT=$${EXPORTER_PORT:-9854}; \
	echo "Fetching Solr metrics..."; \
	curl -s "http://localhost:$$PORT/metrics" | head -50; \
	echo ""; \
	echo "(Showing first 50 lines. Full metrics at http://localhost:$$PORT/metrics)"

# Integration tests
test:
	@./tests/integration-test.sh

# Security scanning
security-scan:
	@./scripts/security-scan.sh

# Performance benchmark
benchmark:
	@./scripts/benchmark.sh

# Clean up containers
clean:
	@echo "Stopping and removing containers..."
	@docker compose down
	@echo "✓ Containers removed"

# Destroy everything
destroy:
	@echo "⚠ WARNING: This will delete all data!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		docker compose down -v; \
		rm -rf data/* backups/* logs/*; \
		echo "✓ All data destroyed"; \
	else \
		echo "Cancelled"; \
	fi

###############################################################################
# Multi-Tenancy Management
###############################################################################

# Create a new tenant
tenant-create:
	@if [ -z "$(TENANT)" ]; then \
		echo "❌ Error: TENANT parameter required"; \
		echo "Usage: make tenant-create TENANT=<tenant_id>"; \
		echo "Example: make tenant-create TENANT=tenant1"; \
		exit 1; \
	fi
	@./scripts/tenant-create.sh $(TENANT)

# Delete a tenant
tenant-delete:
	@if [ -z "$(TENANT)" ]; then \
		echo "❌ Error: TENANT parameter required"; \
		echo "Usage: make tenant-delete TENANT=<tenant_id> [BACKUP=true]"; \
		echo "Example: make tenant-delete TENANT=tenant1 BACKUP=true"; \
		exit 1; \
	fi
	@BACKUP=$(BACKUP) ./scripts/tenant-delete.sh $(TENANT)

# List all tenants
tenant-list:
	@./scripts/tenant-list.sh

# Backup a single tenant
tenant-backup:
	@if [ -z "$(TENANT)" ]; then \
		echo "❌ Error: TENANT parameter required"; \
		echo "Usage: make tenant-backup TENANT=<tenant_id>"; \
		echo "Example: make tenant-backup TENANT=tenant1"; \
		exit 1; \
	fi
	@./scripts/tenant-backup.sh $(TENANT)

# Backup all tenants
tenant-backup-all:
	@./scripts/tenant-backup.sh --all
