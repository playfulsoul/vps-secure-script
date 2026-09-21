#!/usr/bin/env bash

set -u
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
test_root=$(mktemp -d)
test_root=$(cd -- "$test_root" && pwd -P)
trap 'rm -rf -- "$test_root"' EXIT
VPS_PLATFORM_ROOT=$PROJECT_ROOT
VERSION=$(<"$PROJECT_ROOT/VERSION")
# shellcheck source=../../core/ui.sh
source "$PROJECT_ROOT/core/ui.sh"
vps_ui_header() { printf 'MENU_HEADER\n'; }
vps_update_channel() { printf 'beta\n'; }
# Replace only the terminal wait with a deterministic input-consuming wait.
# The result wrapper and menu dispatch remain real, including on failure.
vps_ui_pause() { printf 'WAIT_FOR_ENTER\n'; read -r _; }
vps_report_command() { printf 'REPORT_ENTRY\n'; return "${report_status:-0}"; }

for report_status in 0 40; do
    actual=$(printf '5\n\n0\n' | vps_ui_update_menu)
    assert_contains "$actual" $'REPORT_ENTRY\n' "report selection calls the shared command entry"
    if [[ "$report_status" == 0 ]]; then
        assert_contains "$actual" '[完成]' "successful report is identified as complete"
    else
        assert_contains "$actual" '[未完成]' "report failure is not shown as success"
    fi
    assert_contains "$actual" $'WAIT_FOR_ENTER\nMENU_HEADER' \
        "result pauses before returning to the maintenance menu"
done

# Exercise the real CLI, real report generation and return to the main menu.
actual=$(printf '8\n5\n0\n0\n' | VPS_STATE_DIR="$test_root/state" \
    "$PROJECT_ROOT/bin/vps")
assert_contains "$actual" '诊断报告已保存:' "numeric menu creates a real report"
assert_contains "$actual" '默认已排除服务器身份、网络入口、认证材料和原始日志' \
    "numeric menu displays the shared redaction boundary"
assert_contains "$actual" '分享前请自行打开检查' "numeric menu displays the share-review reminder"
report_count=$(find "$test_root/state/reports" -type f | wc -l | tr -d ' ')
assert_eq 1 "$report_count" "one menu selection creates exactly one report"
finish_tests
