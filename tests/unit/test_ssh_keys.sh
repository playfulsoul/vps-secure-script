#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/ssh_keys.sh
source "$PROJECT_ROOT/core/ssh_keys.sh"

if vps_github_username_valid playfulsoul; then
    pass "GitHub username validation accepts a normal account"
else
    fail "GitHub username validation rejected a normal account"
fi

if vps_github_username_valid '-unsafe'; then
    fail "GitHub username validation must reject a leading hyphen"
else
    pass "GitHub username validation rejects a leading hyphen"
fi

key_file=$(mktemp)
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEexamplekeymaterial test@example' > "$key_file"
if vps_validate_public_key_file "$key_file"; then
    pass "public key validation accepts an OpenSSH public key"
else
    fail "public key validation rejected an OpenSSH public key"
fi

printf '%s\n' '<html>Not Found</html>' > "$key_file"
if vps_validate_public_key_file "$key_file"; then
    fail "public key validation must reject an HTML response"
else
    pass "public key validation rejects an HTML response"
fi

existing=$(mktemp)
imported=$(mktemp)
merged=$(mktemp)
printf '%s\n' 'ssh-ed25519 AAAAexisting old' > "$existing"
printf '%s\n' 'ssh-ed25519 AAAAexisting old' 'ssh-ed25519 AAAAnew new' > "$imported"
vps_merge_authorized_keys "$existing" "$imported" "$merged"
actual=$(grep -c '^ssh-ed25519 AAAAexisting old$' "$merged")
assert_eq '1' "$actual" "authorized_keys merge removes exact duplicates"
assert_contains "$(<"$merged")" 'ssh-ed25519 AAAAnew new' "authorized_keys merge preserves a new key"
rm -f "$key_file" "$existing" "$imported" "$merged"

finish_tests
