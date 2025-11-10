#!/bin/bash

###############################################################################
# Multi-Tenancy Integration Tests
# Tests tenant creation, isolation, management, and deletion
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL=0
PASSED=0
FAILED=0

# Test tenant IDs
TEST_TENANT1="test_tenant_$$_1"
TEST_TENANT2="test_tenant_$$_2"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
    set +a
fi

###############################################################################
# Helper Functions
###############################################################################

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

test_case() {
    local name=$1
    local command=$2

    TOTAL=$((TOTAL + 1))
    echo -n "  [ $TOTAL ] $name ... "

    if eval "$command" >/dev/null 2>&1; then
        log_success "PASS"
        PASSED=$((PASSED + 1))
    else
        log_error "FAIL"
        FAILED=$((FAILED + 1))
    fi
}

###############################################################################
# Cleanup Functions
###############################################################################

cleanup_test_tenants() {
    log_info "Cleaning up test tenants..."

    # Delete test tenants (without backup)
    for tenant in "$TEST_TENANT1" "$TEST_TENANT2"; do
        if docker compose exec -T solr curl -sf -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
            "http://localhost:8983/solr/admin/cores?action=STATUS&core=moodle_${tenant}" 2>/dev/null | \
            grep -q "\"moodle_${tenant}\""; then
            log_info "  Deleting tenant: $tenant"
            echo "DELETE" | BACKUP=false "$PROJECT_ROOT/scripts/tenant-delete.sh" "$tenant" >/dev/null 2>&1 || true
        fi
    done

    # Remove credentials files
    rm -f "$PROJECT_ROOT/.env.${TEST_TENANT1}" "$PROJECT_ROOT/.env.${TEST_TENANT2}"
    rm -f "$PROJECT_ROOT/.env.${TEST_TENANT1}.deleted_"* "$PROJECT_ROOT/.env.${TEST_TENANT2}.deleted_"*

    log_success "Cleanup completed"
}

trap cleanup_test_tenants EXIT

###############################################################################
# Test Categories
###############################################################################

test_tenant_creation() {
    echo ""
    log_info "Testing Tenant Creation..."
    echo ""

    # Test 1: Create first tenant
    test_case "Create tenant ${TEST_TENANT1}" \
        "$PROJECT_ROOT/scripts/tenant-create.sh ${TEST_TENANT1}"

    # Test 2: Verify core was created
    test_case "Verify core moodle_${TEST_TENANT1} exists" \
        "docker compose exec -T solr curl -sf -u \"${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}\" \
        'http://localhost:8983/solr/admin/cores?action=STATUS&core=moodle_${TEST_TENANT1}' | \
        grep -q '\"moodle_${TEST_TENANT1}\"'"

    # Test 3: Verify credentials file was created
    test_case "Verify credentials file .env.${TEST_TENANT1} exists" \
        "test -f \"$PROJECT_ROOT/.env.${TEST_TENANT1}\""

    # Test 4: Verify user was created in security.json
    test_case "Verify user ${TEST_TENANT1}_customer exists" \
        "docker compose exec -T solr cat /var/solr/data/security.json | \
        jq -e '.authentication.credentials.\"${TEST_TENANT1}_customer\"' >/dev/null"

    # Test 5: Verify RBAC role was assigned
    test_case "Verify RBAC role ${TEST_TENANT1}_role assigned" \
        "docker compose exec -T solr cat /var/solr/data/security.json | \
        jq -e '.authorization.\"user-role\".\"${TEST_TENANT1}_customer\"' >/dev/null"

    # Test 6: Verify permission for core was created
    test_case "Verify permission for core moodle_${TEST_TENANT1}" \
        "docker compose exec -T solr cat /var/solr/data/security.json | \
        jq -e '.authorization.permissions[] | select(.name == \"${TEST_TENANT1}-access\")' >/dev/null"

    # Test 7: Create second tenant
    test_case "Create tenant ${TEST_TENANT2}" \
        "$PROJECT_ROOT/scripts/tenant-create.sh ${TEST_TENANT2}"

    # Test 8: Verify second core exists
    test_case "Verify core moodle_${TEST_TENANT2} exists" \
        "docker compose exec -T solr curl -sf -u \"${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}\" \
        'http://localhost:8983/solr/admin/cores?action=STATUS&core=moodle_${TEST_TENANT2}' | \
        grep -q '\"moodle_${TEST_TENANT2}\"'"
}

test_tenant_access() {
    echo ""
    log_info "Testing Tenant Access..."
    echo ""

    # Load tenant1 credentials
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/.env.${TEST_TENANT1}"
    local tenant1_user="$TENANT_USER"
    local tenant1_pass="$TENANT_PASSWORD"

    # Load tenant2 credentials
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/.env.${TEST_TENANT2}"
    local tenant2_user="$TENANT_USER"
    local tenant2_pass="$TENANT_PASSWORD"

    # Test 1: Tenant1 can access own core
    test_case "Tenant1 can query moodle_${TEST_TENANT1}" \
        "curl -sf -u \"${tenant1_user}:${tenant1_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT1}/select?q=*:*&rows=0' >/dev/null"

    # Test 2: Tenant2 can access own core
    test_case "Tenant2 can query moodle_${TEST_TENANT2}" \
        "curl -sf -u \"${tenant2_user}:${tenant2_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT2}/select?q=*:*&rows=0' >/dev/null"

    # Test 3: Admin can access tenant1 core
    test_case "Admin can query moodle_${TEST_TENANT1}" \
        "curl -sf -u \"${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT1}/select?q=*:*&rows=0' >/dev/null"

    # Test 4: Admin can access tenant2 core
    test_case "Admin can query moodle_${TEST_TENANT2}" \
        "curl -sf -u \"${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT2}/select?q=*:*&rows=0' >/dev/null"
}

test_tenant_isolation() {
    echo ""
    log_info "Testing Tenant Isolation (Security)..."
    echo ""

    # Load credentials
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/.env.${TEST_TENANT1}"
    local tenant1_user="$TENANT_USER"
    local tenant1_pass="$TENANT_PASSWORD"

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/.env.${TEST_TENANT2}"
    local tenant2_user="$TENANT_USER"
    local tenant2_pass="$TENANT_PASSWORD"

    # Test 1: Tenant1 CANNOT access tenant2's core (should fail = pass)
    test_case "Tenant1 CANNOT query moodle_${TEST_TENANT2} (isolation)" \
        "! curl -sf -u \"${tenant1_user}:${tenant1_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT2}/select?q=*:*&rows=0' >/dev/null 2>&1"

    # Test 2: Tenant2 CANNOT access tenant1's core (should fail = pass)
    test_case "Tenant2 CANNOT query moodle_${TEST_TENANT1} (isolation)" \
        "! curl -sf -u \"${tenant2_user}:${tenant2_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT1}/select?q=*:*&rows=0' >/dev/null 2>&1"

    # Test 3: Tenant1 CANNOT access admin APIs (should fail = pass)
    test_case "Tenant1 CANNOT access admin/cores API (privilege)" \
        "! curl -sf -u \"${tenant1_user}:${tenant1_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS' >/dev/null 2>&1"

    # Test 4: Tenant2 CANNOT create cores (should fail = pass)
    test_case "Tenant2 CANNOT create cores (privilege)" \
        "! curl -sf -u \"${tenant2_user}:${tenant2_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/admin/cores?action=CREATE&name=malicious_core' >/dev/null 2>&1"
}

test_tenant_data_isolation() {
    echo ""
    log_info "Testing Data Isolation..."
    echo ""

    # Load credentials
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/.env.${TEST_TENANT1}"
    local tenant1_user="$TENANT_USER"
    local tenant1_pass="$TENANT_PASSWORD"

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/.env.${TEST_TENANT2}"
    local tenant2_user="$TENANT_USER"
    local tenant2_pass="$TENANT_PASSWORD"

    # Index a test document in tenant1's core
    log_info "  Indexing test document in tenant1..."
    curl -sf -u "${tenant1_user}:${tenant1_pass}" \
        "http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT1}/update?commit=true" \
        -H 'Content-Type: application/json' \
        -d '[{"id":"test_doc_tenant1","title":"Test Document Tenant 1"}]' >/dev/null 2>&1

    # Index a different document in tenant2's core
    log_info "  Indexing test document in tenant2..."
    curl -sf -u "${tenant2_user}:${tenant2_pass}" \
        "http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT2}/update?commit=true" \
        -H 'Content-Type: application/json' \
        -d '[{"id":"test_doc_tenant2","title":"Test Document Tenant 2"}]' >/dev/null 2>&1

    sleep 2  # Wait for commit

    # Test 1: Tenant1 can find own document
    test_case "Tenant1 can find document 'test_doc_tenant1'" \
        "curl -sf -u \"${tenant1_user}:${tenant1_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT1}/select?q=id:test_doc_tenant1' | \
        grep -q 'test_doc_tenant1'"

    # Test 2: Tenant2 can find own document
    test_case "Tenant2 can find document 'test_doc_tenant2'" \
        "curl -sf -u \"${tenant2_user}:${tenant2_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT2}/select?q=id:test_doc_tenant2' | \
        grep -q 'test_doc_tenant2'"

    # Test 3: Tenant1 does NOT see tenant2's document in their core
    test_case "Tenant1's core does NOT contain 'test_doc_tenant2'" \
        "! curl -sf -u \"${tenant1_user}:${tenant1_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT1}/select?q=id:test_doc_tenant2' | \
        grep -q 'test_doc_tenant2'"

    # Test 4: Tenant2 does NOT see tenant1's document in their core
    test_case "Tenant2's core does NOT contain 'test_doc_tenant1'" \
        "! curl -sf -u \"${tenant2_user}:${tenant2_pass}\" \
        'http://localhost:${SOLR_PORT}/solr/moodle_${TEST_TENANT2}/select?q=id:test_doc_tenant1' | \
        grep -q 'test_doc_tenant1'"
}

test_tenant_management() {
    echo ""
    log_info "Testing Tenant Management..."
    echo ""

    # Test 1: List tenants shows both test tenants
    test_case "tenant-list.sh shows ${TEST_TENANT1}" \
        "$PROJECT_ROOT/scripts/tenant-list.sh | grep -q '${TEST_TENANT1}'"

    test_case "tenant-list.sh shows ${TEST_TENANT2}" \
        "$PROJECT_ROOT/scripts/tenant-list.sh | grep -q '${TEST_TENANT2}'"

    # Test 2: Backup tenant
    test_case "Backup ${TEST_TENANT1}" \
        "$PROJECT_ROOT/scripts/tenant-backup.sh ${TEST_TENANT1}"

    # Test 3: Verify backup file exists
    test_case "Backup file for ${TEST_TENANT1} exists" \
        "find \"$PROJECT_ROOT/backups\" -name \"tenant_${TEST_TENANT1}_*.tar.gz\" | grep -q ."

    # Test 4: Delete tenant with backup
    test_case "Delete ${TEST_TENANT1} with backup" \
        "echo 'DELETE' | BACKUP=true $PROJECT_ROOT/scripts/tenant-delete.sh ${TEST_TENANT1}"

    # Test 5: Verify core was deleted
    test_case "Verify core moodle_${TEST_TENANT1} was deleted" \
        "! docker compose exec -T solr curl -sf -u \"${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}\" \
        'http://localhost:8983/solr/admin/cores?action=STATUS&core=moodle_${TEST_TENANT1}' | \
        grep -q '\"moodle_${TEST_TENANT1}\"'"

    # Test 6: Verify user was removed from security.json
    test_case "Verify user ${TEST_TENANT1}_customer was removed" \
        "! docker compose exec -T solr cat /var/solr/data/security.json | \
        jq -e '.authentication.credentials.\"${TEST_TENANT1}_customer\"' >/dev/null 2>&1"

    # Test 7: Verify credentials file was archived
    test_case "Verify credentials file was archived" \
        "test -f \"$PROJECT_ROOT/.env.${TEST_TENANT1}.deleted_\"* || \
        ! test -f \"$PROJECT_ROOT/.env.${TEST_TENANT1}\""

    # Test 8: Delete second tenant without backup
    test_case "Delete ${TEST_TENANT2} without backup" \
        "echo 'DELETE' | BACKUP=false $PROJECT_ROOT/scripts/tenant-delete.sh ${TEST_TENANT2}"
}

###############################################################################
# Main Function
###############################################################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        Multi-Tenancy Integration Test Suite                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    log_info "Starting multi-tenant integration tests..."
    log_warning "This will create and delete test tenants: ${TEST_TENANT1}, ${TEST_TENANT2}"
    echo ""

    # Pre-checks
    if ! docker compose ps | grep -q solr; then
        log_error "Solr is not running. Please start services first: make start"
        exit 1
    fi

    # Run test categories
    test_tenant_creation
    test_tenant_access
    test_tenant_isolation
    test_tenant_data_isolation
    test_tenant_management

    # Summary
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "Test Summary"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "   Total:    $TOTAL"
    echo "   Passed:   $PASSED"
    echo "   Failed:   $FAILED"
    echo ""

    if [ $FAILED -eq 0 ]; then
        log_success "All multi-tenant tests passed! 🎉"
        exit 0
    else
        log_error "Some multi-tenant tests failed"
        exit 1
    fi
}

main "$@"
