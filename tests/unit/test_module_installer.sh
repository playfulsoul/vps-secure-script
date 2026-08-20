#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d)
VPS_PLATFORM_ROOT=$PROJECT_ROOT
VPS_STATE_DIR="$TEST_ROOT/state"
VPS_INSTALLED_MODULE_DIR="$TEST_ROOT/modules"
export VPS_PLATFORM_ROOT VPS_STATE_DIR VPS_INSTALLED_MODULE_DIR
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/modules.sh
source "$PROJECT_ROOT/core/modules.sh"
# shellcheck source=../../core/runtime.sh
source "$PROJECT_ROOT/core/runtime.sh"
# shellcheck source=../../core/installer.sh
source "$PROJECT_ROOT/core/installer.sh"

vps_require_root() {
    return 0
}

mkdir -p "$TEST_ROOT/package"
printf '%s\n' \
    'id=monitoring.example' \
    'name=Example monitoring module' \
    'version=1.0.0' \
    'category=monitoring' \
    'entry=module.sh' \
    'trust=official' \
    'privilege=unprivileged' \
    'actions=status' > "$TEST_ROOT/package/module.conf"
printf '%s\n' '#!/usr/bin/env bash' 'printf "example module\n"' > "$TEST_ROOT/package/module.sh"
tar -czf "$TEST_ROOT/module.tar.gz" -C "$TEST_ROOT/package" .
checksum=$(vps_sha256 "$TEST_ROOT/module.tar.gz")

if vps_install_module_archive "$TEST_ROOT/module.tar.gz" "$checksum" >/dev/null; then
    pass "verified local module archive is installed"
else
    fail "verified local module archive is installed"
fi

assert_file_exists "$VPS_INSTALLED_MODULE_DIR/monitoring.example/module.conf" \
    "installed module manifest is present"

actual=$(vps_module_list)
assert_contains "$actual" 'monitoring.example' "installed module is discovered by the registry"

if vps_install_module_archive "$TEST_ROOT/module.tar.gz" \
    '0000000000000000000000000000000000000000000000000000000000000000' >/dev/null 2>&1; then
    fail "module archive with a mismatched checksum is rejected"
else
    pass "module archive with a mismatched checksum is rejected"
fi

finish_tests
