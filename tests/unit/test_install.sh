#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

temporary_root=$(mktemp -d)
VPS_INSTALL_ROOT="$temporary_root/lib/vps-secure" \
VPS_BIN_DIR="$temporary_root/bin" \
    "$PROJECT_ROOT/install.sh" >/dev/null

assert_file_exists "$temporary_root/lib/vps-secure/bin/vps" "installer copies the CLI"
assert_file_exists "$temporary_root/lib/vps-secure/modules/builtin/security-firewall/module.conf" \
    "installer copies built-in modules"
actual=$("$temporary_root/bin/vps" --version)
assert_eq 'vps-secure 2.0.0-beta.1' "$actual" "installed command runs through the symlink"

rm -rf "$temporary_root"
finish_tests
