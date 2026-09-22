#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VERSION=$(<"$PROJECT_ROOT/VERSION")

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
assert_contains "$actual" "vps-secure $VERSION (build sha256-" \
    "installed command reports its preserved build identity"
assert_file_exists "$temporary_root/lib/vps-secure/BUILD_ID" \
    "installer preserves the build identity"
assert_file_exists "$temporary_root/lib/vps-secure/BUILD_MANIFEST.sha256" \
    "installer preserves the source manifest behind the build identity"
installed_build=$(<"$temporary_root/lib/vps-secure/BUILD_ID")
assert_contains "$actual" "$installed_build" \
    "installed status matches the identity recorded during installation"

temporary_root=$(cd "$temporary_root" && pwd -P)
VPS_STATE_DIR="$temporary_root/report-state" "$temporary_root/bin/vps" report --output installed.txt >/dev/null
assert_file_exists "$temporary_root/report-state/reports/installed.txt" \
    "installed CLI generates a diagnostic report"
report=$(<"$temporary_root/report-state/reports/installed.txt")
assert_contains "$report" "完整构建身份: $installed_build" \
    "installed report uses the preserved content build identity"

rm -rf "$temporary_root"
finish_tests
