#!/usr/bin/env bash
###############################################################################
# Security.json Validator v3.3.0
# Validates security.json integrity before/after Solr operations
###############################################################################

set -euo pipefail

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

SECURITY_JSON="${1:-/var/solr/data/security.json}"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Security.json Validation v3.3.0                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
log_info "Validating: $SECURITY_JSON"
echo ""

###############################################################################
# 1. Check file exists
###############################################################################
log_info "[1/7] Checking file existence..."
if [ ! -f "$SECURITY_JSON" ]; then
    log_error "security.json not found at: $SECURITY_JSON"
    exit 1
fi
log_success "File exists"

###############################################################################
# 2. Validate JSON syntax
###############################################################################
log_info "[2/7] Validating JSON syntax..."
if ! jq empty "$SECURITY_JSON" 2>/dev/null; then
    log_error "Invalid JSON syntax in security.json"
    echo ""
    echo "Syntax error details:"
    jq . "$SECURITY_JSON" 2>&1 | head -10
    exit 1
fi
log_success "JSON syntax valid"

###############################################################################
# 3. Validate structure
###############################################################################
log_info "[3/7] Validating structure..."

# Check authentication block
if ! jq -e '.authentication' "$SECURITY_JSON" >/dev/null 2>&1; then
    log_error "Missing .authentication block"
    exit 1
fi
log_success "Authentication block present"

# Check authorization block
if ! jq -e '.authorization' "$SECURITY_JSON" >/dev/null 2>&1; then
    log_error "Missing .authorization block"
    exit 1
fi
log_success "Authorization block present"

###############################################################################
# 4. Validate credentials
###############################################################################
log_info "[4/7] Validating credentials..."

CRED_COUNT=$(jq '.authentication.credentials | length' "$SECURITY_JSON")
if [ "$CRED_COUNT" -lt 1 ]; then
    log_error "No credentials defined (found: $CRED_COUNT)"
    exit 1
fi
log_success "Found $CRED_COUNT credential(s)"

# Check for admin user
if jq -e '.authentication.credentials.admin' "$SECURITY_JSON" >/dev/null 2>&1; then
    log_success "Admin user present"
else
    log_warning "No 'admin' user found"
fi

# List all users
echo ""
echo "   Users:"
jq -r '.authentication.credentials | keys[]' "$SECURITY_JSON" | while read -r user; do
    echo "     - $user"
done
echo ""

###############################################################################
# 5. Check for security issues
###############################################################################
log_info "[5/7] Checking for security issues..."

# Check for suspicious patterns (weak passwords)
if jq -r '.authentication.credentials | to_entries[] | .value' "$SECURITY_JSON" | \
   grep -qi "changeme\|password123\|admin123\|SHA256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"; then
    log_warning "Potential default/weak password detected"
else
    log_success "No obvious weak passwords detected"
fi

# Check password hash format
INVALID_HASH_COUNT=0
while IFS= read -r hash; do
    if ! [[ "$hash" =~ ^SHA256:[a-f0-9]{64}$ ]]; then
        INVALID_HASH_COUNT=$((INVALID_HASH_COUNT + 1))
    fi
done < <(jq -r '.authentication.credentials | to_entries[] | .value' "$SECURITY_JSON")

if [ $INVALID_HASH_COUNT -gt 0 ]; then
    log_warning "$INVALID_HASH_COUNT credential(s) have invalid hash format"
else
    log_success "All password hashes have valid format"
fi

###############################################################################
# 6. Validate permissions
###############################################################################
log_info "[6/7] Validating permissions..."

PERM_COUNT=$(jq '.authorization.permissions | length' "$SECURITY_JSON" 2>/dev/null || echo "0")
if [ "$PERM_COUNT" -lt 1 ]; then
    log_warning "No permissions defined"
else
    log_success "Found $PERM_COUNT permission(s)"
fi

###############################################################################
# 7. Validate user-role mappings
###############################################################################
log_info "[7/7] Validating user-role mappings..."

ROLE_COUNT=$(jq '.authorization."user-role" | length' "$SECURITY_JSON" 2>/dev/null || echo "0")
if [ "$ROLE_COUNT" -lt 1 ]; then
    log_warning "No user-role mappings defined"
else
    log_success "Found $ROLE_COUNT user-role mapping(s)"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  Validation Summary                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Calculate and display checksum
CHECKSUM=$(sha256sum "$SECURITY_JSON" | awk '{print $1}')
echo "  File:        $SECURITY_JSON"
echo "  Size:        $(du -h "$SECURITY_JSON" | cut -f1)"
echo "  Users:       $CRED_COUNT"
echo "  Permissions: $PERM_COUNT"
echo "  Roles:       $ROLE_COUNT"
echo "  Checksum:    ${CHECKSUM:0:16}..."
echo ""

log_success "security.json is valid"
echo ""
exit 0
