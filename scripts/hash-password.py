#!/usr/bin/env python3
"""
Solr Password Hashing Utility
Version: 2.3.1
Algorithm: Double SHA-256 with random salt

This script implements Double SHA-256 hashing:
1. Generate random salt (32 bytes)
2. Binary concatenation: salt_bytes + password_bytes
3. First SHA-256: sha256(salt_bytes + password_bytes)
4. Second SHA-256: sha256(hash1) - Double SHA-256!
5. Base64 encode: hash2 and salt
6. Format: "HASH_B64 SALT_B64" (hash first, then salt)

Note: This is NOT idempotent by design (random salt).
For idempotency, use verify_and_reuse() to check existing hashes.
"""

import hashlib
import base64
import sys
import os
import secrets
import argparse
import json


def generate_random_salt(length=32):
    """
    Generate cryptographically secure random salt.
    Same as: openssl rand 32

    Args:
        length: Salt length in bytes (default: 32)

    Returns:
        bytes: Random salt
    """
    return secrets.token_bytes(length)


def hash_password(password, salt=None):
    """
    Hash password using Double SHA-256 algorithm.

    Algorithm:
    1. salt_bytes (random or provided)
    2. password_bytes = password.encode('utf-8')
    3. combined = salt_bytes + password_bytes  # Binary concatenation
    4. hash1 = sha256(combined)                 # First SHA-256
    5. hash2 = sha256(hash1)                    # Second SHA-256 (Double!)
    6. return "base64(hash2) base64(salt)"      # Hash first, salt second!

    Args:
        password: Plain text password
        salt: Optional salt bytes. If None, generates random salt.

    Returns:
        str: Solr hash in format "HASH_B64 SALT_B64"
    """
    if salt is None:
        salt = generate_random_salt(32)

    # Convert password to bytes
    password_bytes = password.encode('utf-8')

    # Binary concatenation: salt + password
    combined = salt + password_bytes

    # First SHA-256
    hash1 = hashlib.sha256(combined).digest()

    # Second SHA-256 (Double SHA-256!)
    hash2 = hashlib.sha256(hash1).digest()

    # Base64 encode
    hash_b64 = base64.b64encode(hash2).decode('utf-8')
    salt_b64 = base64.b64encode(salt).decode('utf-8')

    # Format: "HASH SALT" (hash first, then salt!)
    return f"{hash_b64} {salt_b64}"


def verify_password(password, existing_hash):
    """
    Verify if password matches existing hash.

    Algorithm:
    1. Extract salt from existing hash
    2. Decode salt from base64
    3. Hash password with extracted salt
    4. Compare with existing hash

    Args:
        password: Plain text password
        existing_hash: Existing hash in format "HASH_B64 SALT_B64"

    Returns:
        bool: True if password matches, False otherwise
    """
    try:
        # Parse existing hash: "HASH SALT"
        parts = existing_hash.strip().split(' ')
        if len(parts) != 2:
            return False

        hash_b64, salt_b64 = parts

        # Decode salt from base64
        salt = base64.b64decode(salt_b64)

        # Generate new hash with extracted salt
        new_hash = hash_password(password, salt=salt)

        # Compare
        return new_hash == existing_hash

    except Exception:
        return False


def load_existing_hashes(security_json_path):
    """
    Load existing password hashes from security.json.

    Args:
        security_json_path: Path to security.json file

    Returns:
        dict: Username -> hash mapping, or empty dict if file not found
    """
    if not os.path.exists(security_json_path):
        return {}

    try:
        with open(security_json_path, 'r') as f:
            security_data = json.load(f)

        credentials = security_data.get('authentication', {}).get('credentials', {})
        return credentials

    except (json.JSONDecodeError, IOError):
        return {}


def verify_and_reuse(username, password, security_json_path):
    """
    Check if existing hash matches password, and re-use if it does.
    This implements idempotency logic.

    Args:
        username: Username to check
        password: Plain text password
        security_json_path: Path to security.json

    Returns:
        str: Existing hash if it matches, or new hash if it doesn't
    """
    existing_hashes = load_existing_hashes(security_json_path)
    existing_hash = existing_hashes.get(username)

    if existing_hash and verify_password(password, existing_hash):
        return existing_hash
    else:
        # Generate new hash
        return hash_password(password)


def main():
    parser = argparse.ArgumentParser(
        description='Solr Password Hasher',
        epilog='Algorithm: Double SHA-256 with random salt'
    )
    parser.add_argument('password', nargs='?', help='Password to hash')
    parser.add_argument('--verify', nargs=2, metavar=('PASSWORD', 'HASH'),
                        help='Verify password against hash')
    parser.add_argument('--reuse', nargs=3, metavar=('USERNAME', 'PASSWORD', 'SECURITY_JSON'),
                        help='Verify and reuse existing hash if it matches')
    parser.add_argument('--salt-bytes', type=int, default=32,
                        help='Salt size in bytes (default: 32)')

    args = parser.parse_args()

    if args.verify:
        password, expected_hash = args.verify
        if verify_password(password, expected_hash):
            print("✓ Password matches hash")
            sys.exit(0)
        else:
            print("✗ Password does NOT match hash")
            sys.exit(1)

    elif args.reuse:
        username, password, security_json_path = args.reuse
        hash_result = verify_and_reuse(username, password, security_json_path)
        print(hash_result)
        sys.exit(0)

    elif args.password:
        # Generate new hash with random salt
        hashed = hash_password(args.password)
        print(hashed)
        sys.exit(0)

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()
