#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Load environment
if [ -f ".env" ]; then
    source ".env"
fi

CONTAINER_NAME="${CUSTOMER_NAME}_solr"

# Follow logs
docker logs -f "$CONTAINER_NAME" "$@"
