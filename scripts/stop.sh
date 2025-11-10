#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Stopping Solr Moodle Docker"
echo "=========================================="

cd "$PROJECT_DIR"
docker compose down

echo "✓ Solr stopped successfully"
