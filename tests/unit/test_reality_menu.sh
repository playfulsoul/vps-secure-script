#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
VPS_PLATFORM_ROOT=$PROJECT_ROOT
VERSION=$(<"$PROJECT_ROOT/VERSION")
# shellcheck source=../../core/modules.sh
source "$PROJECT_ROOT/core/modules.sh"
# shellcheck source=../../core/ui.sh
source "$PROJECT_ROOT/core/ui.sh"
vps_ui_header() { printf 'MENU_HEADER\n'; }
vps_ui_pause() { :; }
vps_module_run() { printf 'ACTION:%s:%s\n' "$1" "$2"; printf 'ARG:%s\n' "${@:3}"; }

actual=$(printf '4\n3\n5\n0\n0\n' | vps_ui_applications_menu)
assert_contains "$actual" 'ACTION:applications.reality-node:status' 'application slot four reaches node status'
assert_contains "$actual" 'ACTION:applications.reality-node:verify' 'node check dispatches without claiming public-client validation'
assert_contains "$actual" '1Panel 管理面板' 'existing application choices remain visible'
assert_contains "$actual" '远程图形桌面' 'remote desktop menu remains available'

actual=$(printf '4\n8.8.8.8\n24443\n8443\ntarget.example\ny\n0\n' | vps_ui_reality_menu)
assert_contains "$actual" 'ACTION:applications.reality-node:apply' 'confirmed installation dispatches shared apply action'
assert_contains "$actual" $'ARG:--public-address\nARG:8.8.8.8' 'explicit public endpoint is not replaced by loopback'
assert_contains "$actual" $'ARG:--node-port\nARG:24443' 'alternate node entrance is preserved'

actual=$(printf '11\nn\n0\n' | vps_ui_reality_menu)
assert_contains "$actual" '已取消' 'uninstall cancellation is visible'
if [[ "$actual" == *'ACTION:applications.reality-node:uninstall'* ]]; then
    fail 'uninstall requires explicit menu confirmation'
else
    pass 'uninstall requires explicit menu confirmation'
fi

actual=$(printf '6\ny\n12\ny\n0\n' | vps_ui_reality_menu)
assert_contains "$actual" 'ARG:--upgrade' 'upgrade uses configure contract'
assert_contains "$actual" 'ARG:--export-client' 'protected export uses configure contract'
finish_tests
