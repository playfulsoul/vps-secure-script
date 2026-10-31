#!/usr/bin/env bash
# Variables and mocks are consumed by sourced menu functions.
# shellcheck disable=SC2034,SC2329
set -u
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
VPS_PLATFORM_ROOT=$PROJECT_ROOT
VERSION=$(<"$PROJECT_ROOT/VERSION")
# shellcheck source=../../core/ui.sh
source "$PROJECT_ROOT/core/ui.sh"
# shellcheck source=../../core/modules.sh
source "$PROJECT_ROOT/core/modules.sh"
# Source the real advanced menu functions without executing the CLI entry point.
functions_file=$(mktemp)
trap 'rm -f -- "$functions_file"' EXIT
sed -n '/^interactive_module() {/,/^command_module() {/p' "$PROJECT_ROOT/bin/vps" | sed '$d' > "$functions_file"
# shellcheck disable=SC1090
source "$functions_file"

if printf y | vps_ui_confirm test; then
    fail 'confirmation must reject an unterminated answer at EOF'
else
    pass 'confirmation rejects an unterminated answer at EOF'
fi
if printf 'y\n' | vps_ui_confirm test; then
    pass 'confirmation accepts a complete explicit yes'
else
    fail 'confirmation must accept a complete explicit yes'
fi

# Bound broken menu loops without adding a platform-specific timeout dependency.
read_count=0
read() {
    if [[ ${1:-} == -r && ${2:-} == -p ]]; then
        read_count=$((read_count + 1))
        (( read_count < 2 )) || exit 71
    fi
    # Preserve the caller flags; production menu reads already use -r.
    # shellcheck disable=SC2162
    builtin read "$@"
}
vps_ui_header() { :; }
vps_ui_section() { :; }
vps_ui_menu_item() { :; }
vps_ui_status_dashboard() { :; }
vps_update_notice() { :; }
vps_ui_pause() { :; }

for menu in vps_ui_main_menu vps_ui_applications_menu interactive_advanced_menu; do
    if (read_count=0; "$menu" </dev/null) >/dev/null 2>&1; then
        pass "$menu exits on EOF without repeating the menu"
    else
        fail "$menu must exit on EOF"
    fi
done
if (read_count=0; interactive_module system.bbr </dev/null) >/dev/null 2>&1; then
    pass 'advanced module exits on EOF'
else
    fail 'advanced module must exit on EOF'
fi
unset -f read

vps_module_run() { printf 'EXECUTED:%s:%s\n' "$1" "$2"; }
manifest=$(vps_module_find system.bbr)
actions=$(vps_manifest_value "$manifest" actions)
IFS=, read -r -a action_list <<< "$actions"
status_choice=0
apply_choice=0
for ((i=0; i<${#action_list[@]}; i++)); do
    [[ ${action_list[i]} != status ]] || status_choice=$((i + 1))
    [[ ${action_list[i]} != apply ]] || apply_choice=$((i + 1))
done
actual=$(printf '%s\n0\n' "$status_choice" | interactive_module system.bbr 'BBR 状态测试')
assert_contains "$actual" 'BBR 状态测试：查看状态' 'advanced module result preserves its complete name'
assert_contains "$actual" 'EXECUTED:system.bbr:status' 'advanced module actually dispatches the selected status action'
actual=$(printf '%s\ny' "$apply_choice" | interactive_module system.bbr 'BBR 状态测试')
if [[ "$actual" == *'EXECUTED:system.bbr:apply'* ]]; then
    fail 'advanced module must not apply after an incomplete EOF confirmation'
else
    pass 'advanced module rejects incomplete EOF confirmation before apply'
fi
finish_tests
