#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

VPS_PLATFORM_ROOT=$PROJECT_ROOT
VERSION=$(<"$PROJECT_ROOT/VERSION")
# shellcheck source=../../core/ui.sh
source "$PROJECT_ROOT/core/ui.sh"

vps_ui_header() { printf 'MENU_HEADER\n'; }
vps_ui_section() { :; }
vps_update_channel() { printf 'beta\n'; }
vps_update_check() { return 20; }
vps_ui_confirm() { return "${confirm_status:-0}"; }
vps_ui_pause() { printf 'WAIT_FOR_ENTER\n'; read -r _; }
vps_update_backup_list() { :; }
vps_report_command() { :; }

assert_not_contains_text() {
    local haystack=$1
    local needle=$2
    local message=$3

    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$message (unexpected text: $needle)"
    else
        pass "$message"
    fi
}

vps_ui_restart_platform() {
    printf 'RESTART_NEW_ENTRY\n'
    return 0
}

vps_update_apply() {
    printf 'UPDATE_APPLY\n'
    VPS_PLATFORM_RESTART_REQUIRED=yes
    return 0
}

actual=$(printf '2\n' | vps_ui_update_menu)
assert_contains "$actual" 'UPDATE_APPLY' \
    "successful interactive update runs the installer"
assert_contains "$actual" 'RESTART_NEW_ENTRY' \
    "successful interactive update restarts the installed entry"
assert_not_contains_text "$actual" 'WAIT_FOR_ENTER' \
    "successful interactive update does not return through the old pause"
assert_eq 1 "$(grep -c '^MENU_HEADER$' <<< "$actual")" \
    "successful interactive update does not redraw the old maintenance menu"

vps_update_apply() {
    printf 'NO_UPDATE\n'
    VPS_PLATFORM_RESTART_REQUIRED=no
    return 0
}

actual=$(printf '2\n\n0\n' | vps_ui_update_menu)
assert_contains "$actual" 'NO_UPDATE' \
    "no-op update remains in the current process"
assert_contains "$actual" 'WAIT_FOR_ENTER' \
    "no-op update pauses before returning to the maintenance menu"
assert_not_contains_text "$actual" 'RESTART_NEW_ENTRY' \
    "no-op update does not restart the platform"
assert_eq 2 "$(grep -c '^MENU_HEADER$' <<< "$actual")" \
    "no-op update redraws the current maintenance menu"

vps_update_apply() {
    printf 'UPDATE_FAILED\n'
    VPS_PLATFORM_RESTART_REQUIRED=no
    return 40
}

actual=$(printf '2\n\n0\n' | vps_ui_update_menu)
assert_contains "$actual" 'UPDATE_FAILED' \
    "failed interactive update reports the failure path"
assert_contains "$actual" 'WAIT_FOR_ENTER' \
    "failed interactive update pauses before returning"
assert_not_contains_text "$actual" 'RESTART_NEW_ENTRY' \
    "failed interactive update does not restart the platform"

vps_update_rollback() {
    printf 'ROLLBACK_APPLY\n'
    VPS_PLATFORM_RESTART_REQUIRED=yes
    return 0
}

actual=$(printf '4\n' | vps_ui_update_menu)
assert_contains "$actual" 'ROLLBACK_APPLY' \
    "successful interactive restore runs the restore transaction"
assert_contains "$actual" 'RESTART_NEW_ENTRY' \
    "successful interactive restore restarts the restored entry"
assert_not_contains_text "$actual" 'WAIT_FOR_ENTER' \
    "successful interactive restore does not return through the old pause"

# Exercise the real restart helper in a subshell: a missing new entry must end
# the old process cleanly instead of redrawing a stale menu.
unset -f vps_ui_restart_platform
# shellcheck source=../../core/ui.sh
source "$PROJECT_ROOT/core/ui.sh"
actual=$(VPS_ENTRY="$test_root/missing-entry" vps_ui_restart_platform 2>&1)
assert_contains "$actual" '无法自动启动新入口' \
    "missing restart entry gives a direct recovery instruction"

new_entry="$test_root/new-vps"
printf '%s\n' '#!/usr/bin/env bash' "printf 'NEW_ENTRY_STARTED\\n'" > "$new_entry"
chmod +x "$new_entry"
actual=$(VPS_ENTRY="$new_entry" vps_ui_restart_platform 2>&1)
assert_contains "$actual" '正在启动已安装的平台版本' \
    "restart helper tells the user that the installed version is starting"
assert_contains "$actual" 'NEW_ENTRY_STARTED' \
    "restart helper replaces the stale process with the installed entry"

finish_tests
