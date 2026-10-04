#!/usr/bin/env bash
set -u
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# Load the actual CLI dispatch and menus, executing only the read-only version command.
# shellcheck source=../../bin/vps
source "$PROJECT_ROOT/bin/vps" --version >/dev/null
vps_ui_header() { :; }
vps_ui_status_dashboard() { :; }
vps_update_notice() { :; }
vps_ui_pause() { :; }
# All module execution is replaced. Real manifests, menu dispatch and pure validators remain.
vps_module_run() {
    printf 'CALL'
    printf '<%s>' "$@"
    printf '\n'
    printf 'ACTION:%s:%s\n' "$1" "$2"
    printf 'ARG:%s\n' "${@:3}"
    [[ "$2" != plan || ${FAIL_PLAN:-no} != yes ]]
}

assert_no_apply() {
    if [[ "$1" == *':apply'* ]]; then fail "$2"; else pass "$2"; fi
}

node_index=$(vps_module_list | awk -F '\t' '$1 == "applications.reality-node" {print NR}')
[[ -n "$node_index" ]] || exit 1
prefix=$(printf '9\n%s\n7\n' "$node_index")
valid=$'8.8.8.8\n24443\n8443\ntarget.example\n'
actual=$(printf '%s\n%sy\n0\n0\n0\n' "$prefix" "$valid" | vps_ui_main_menu)
assert_contains "$actual" 'Single REALITY node (applications.reality-node)' 'real advanced menu reaches the reported module'
assert_contains "$actual" '需要先准备本机 HTTPS 目标和公开可信证书' 'wizard states HTTPS and certificate prerequisite'
assert_contains "$actual" '不会自动申请证书或接管网站' 'wizard does not promise automatic target preparation'
assert_eq 1 "$(grep -c '^ACTION:applications.reality-node:apply$' <<< "$actual")" 'generic installation applies exactly once after confirmation'
assert_contains "$actual" 'CALL<applications.reality-node><apply><--public-address><8.8.8.8><--node-port><24443><--target-host><127.0.0.1><--target-port><8443><--server-name><target.example>' 'apply itself receives every argument in order'
for pair in $'--public-address\nARG:8.8.8.8' $'--node-port\nARG:24443' $'--target-host\nARG:127.0.0.1' $'--target-port\nARG:8443' $'--server-name\nARG:target.example'; do
    assert_contains "$actual" "ARG:$pair" 'wizard forwards an exact named argument'
done
assert_eq 1 "$(grep -c '^ACTION:applications.reality-node:plan$' <<< "$actual")" 'shared plan and confirmation path is not duplicated'

actual=$(printf '4\n4\n2\n%sy\n0\n0\n0\n' "$valid" | vps_ui_main_menu)
assert_eq 1 "$(grep -c '^ACTION:applications.reality-node:apply$' <<< "$actual")" 'original dedicated menu still installs'
actual=$(printf '7\n8.8.8.8\n\n8443\ntarget.example\ny\n0\n' | interactive_module applications.reality-node)
assert_contains "$actual" $'ARG:--node-port\nARG:443' 'blank optional entrance uses existing default'

for ending in $'n\n' $'\n' '' 'y'; do
    actual=$(printf '%s\n%s%s' "$prefix" "$valid" "$ending" | vps_ui_main_menu)
    assert_no_apply "$actual" 'declined, empty or truncated confirmation never applies'
done
# EOF at each prompt, including unterminated input; full parent menus must terminate too.
for partial in '' $'8.8.8.8\n' $'8.8.8.8\n24443\n' $'8.8.8.8\n24443\n8443\n' "${valid%$'\n'}"; do
    actual=$(printf '%s\n%s' "$prefix" "$partial" | vps_ui_main_menu)
    assert_no_apply "$actual" 'EOF exits without applying or looping'
    actual=$(printf '%s\n%sq\n' "$prefix" "$partial" | vps_ui_main_menu)
    assert_no_apply "$actual" 'cancel or invalid partial input cannot apply'
done
actual=$(printf '0\n' | interactive_module applications.reality-node)
assert_no_apply "$actual" 'return from generic menu never applies'

for invalid in \
    $'\n24443\n8443\ntarget.example\n' \
    $'8.8.8.8\n24443\n\ntarget.example\n' \
    $'8.8.8.8\n24443\n8443\n\n' \
    $'127.0.0.1\n24443\n8443\ntarget.example\n' \
    $'8.8.8.8\nnot-a-port\n8443\ntarget.example\n' \
    $'8.8.8.8\n65536\n8443\ntarget.example\n' \
    $'8.8.8.8\n24443\n0\ntarget.example\n' \
    $'8.8.8.8\n8443\n8443\ntarget.example\n' \
    $'8.8.8.8\n24443\n8443\nhttps://target.example\n'; do
    actual=$(printf '7\n%sy\n0\n' "$invalid" | interactive_module applications.reality-node)
    assert_contains "$actual" '未执行安装' 'missing or invalid input has readable safe rejection'
    assert_no_apply "$actual" 'invalid arguments never reach apply even with queued confirmation'
done
actual=$(printf '7\n%sy\n0\n' "$valid" | FAIL_PLAN=yes interactive_module applications.reality-node)
assert_no_apply "$actual" 'failed shared plan blocks installation'
actual=$(
    # Called indirectly by the real installation wizard.
    # shellcheck disable=SC2329
    python3() { return 127; }
    printf '7\n%sy\n0\n' "$valid" | interactive_module applications.reality-node
)
assert_contains "$actual" '未执行安装' 'missing validator runtime gives actionable rejection'
assert_no_apply "$actual" 'unavailable validator never falls through to apply'
actual=$(printf '4\n4\n2\n' | vps_ui_main_menu)
assert_no_apply "$actual" 'EOF also unwinds the dedicated menu and its parents'

actual=$(printf '1\n0\n' | interactive_module applications.reality-node)
assert_contains "$actual" 'ACTION:applications.reality-node:check' 'other node actions retain generic dispatch'
# Choose another module action from its real manifest rather than hard-code its index.
docker_actions=$(vps_manifest_value "$(vps_module_find applications.docker)" actions)
docker_apply=$(tr ',' '\n' <<< "$docker_actions" | awk '$0 == "apply" {print NR}')
actual=$(printf '%s\ny\n0\n' "$docker_apply" | interactive_module applications.docker)
assert_contains "$actual" 'ACTION:applications.docker:apply' 'other generic module confirmed install remains available'
actual=$(printf '%s\nn\n0\n' "$docker_apply" | interactive_module applications.docker)
assert_no_apply "$actual" 'other generic module cancellation remains safe'
actual=$(printf '%s\ny' "$docker_apply" | interactive_module applications.docker)
assert_no_apply "$actual" 'other generic module incomplete EOF confirmation is rejected'

actual=$(run_module_command applications.reality-node apply 2>&1)
status=$?
assert_eq 64 "$status" 'noninteractive CLI still requires --yes'
assert_no_apply "$actual" 'CLI without confirmation cannot apply'
actual=$(run_module_command applications.reality-node apply --yes --target-port 8443)
assert_contains "$actual" 'ACTION:applications.reality-node:apply' 'explicit noninteractive CLI retains dispatch without wizard'
assert_contains "$actual" $'ARG:--target-port\nARG:8443' 'CLI arguments remain unmodified for module validation'
if python3 -I -B - "$PROJECT_ROOT/modules/builtin/applications-reality-node" <<'PY'
import contextlib
import io
import sys
from unittest.mock import Mock, patch
sys.path.insert(0, sys.argv[1])
import module
node = Mock()
node.locked.side_effect = contextlib.nullcontext
with patch.object(module.preflight, 'platform_check'), patch.object(module.os, 'geteuid', return_value=0), \
     patch.object(module, 'Node', return_value=node), patch.object(module, 'install_signal_handlers'), \
     patch.object(module.os, 'umask'), contextlib.redirect_stderr(io.StringIO()):
    assert module.main(['apply']) == 64
    assert module.main(['preflight']) == 64
    assert module.main(['apply', '--target-port', 'bad']) == 64
    node.install.assert_not_called()
PY
then
    pass 'real module CLI keeps missing/invalid argument exit code without installing'
else
    fail 'real module CLI argument contract changed'
fi
finish_tests
