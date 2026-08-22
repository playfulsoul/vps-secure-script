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

test_home=$(mktemp -d)
test_uid=$(id -u)
test_gid=$(id -g)
chmod 733 "$test_home"
if vps_ssh_secure_home "$test_home" "$test_uid" "$test_gid"; then
    actual=$(vps_path_mode "$test_home")
    assert_eq '711' "$actual" "SSH key import removes group and other write access from the home"
else
    fail "SSH key import must secure the target home"
fi

mkdir "$test_home/.ssh"
printf '%s\n' 'ssh-ed25519 AAAAnew new' > "$test_home/.ssh/authorized_keys"
chmod 700 "$test_home/.ssh"
chmod 600 "$test_home/.ssh/authorized_keys"
if vps_ssh_paths_verify "$test_home" "$test_uid" "$test_gid"; then
    pass "SSH key verification accepts secure ownership and modes"
else
    fail "SSH key verification rejected secure ownership and modes"
fi

chmod 640 "$test_home/.ssh/authorized_keys"
if vps_ssh_paths_verify "$test_home" "$test_uid" "$test_gid" 2>/dev/null; then
    fail "SSH key verification must reject an unsafe authorized_keys mode"
else
    pass "SSH key verification rejects an unsafe authorized_keys mode"
fi

rm -f "$key_file" "$existing" "$imported" "$merged"
rm -rf -- "$test_home"

finish_tests
