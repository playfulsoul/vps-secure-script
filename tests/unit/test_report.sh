#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
CLI="$PROJECT_ROOT/bin/vps"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root=$(mktemp -d)
test_root=$(cd -- "$test_root" && pwd -P)
trap 'chmod -R u+rwX "$test_root" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/state/modules/security-ssh/transactions/tx-1" \
    "$test_root/third-party/example"

sensitive_ipv4='198.51.100.77'
sensitive_ipv6='2001:db8:abcd::77'
sensitive_host='private-vps.example.net'
sensitive_user='operator-secret'
sensitive_domain='entry.private.example'
sensitive_port='32876'
sensitive_public_key='ssh-ed25519 AAAAC3NzaSensitivePublicKey fixture@example'
sensitive_token='token=tok_fixture_secret'
sensitive_password='password=pw_fixture_secret'
sensitive_cookie='cookie=session_fixture_secret'
sensitive_ban='203.0.113.88'
sensitive_node='vless://uuid-secret@entry.private.example:443?security=tls'
sensitive_auth='Failed password for operator-secret from 203.0.113.88 port 55123'
sensitive_private='-----BEGIN OPENSSH PRIVATE KEY-----'

cat > "$test_root/os-release" <<EOF
ID=debian
VERSION_ID="12"
HOST_URL="$sensitive_domain"
SECRET="$sensitive_token"
EOF
cat > "$test_root/third-party/example/module.conf" <<EOF
id=example.private
name=$sensitive_host $sensitive_user
version=1.0.0
category=diagnostics
entry=module.sh
trust=third-party
privilege=unprivileged
actions=status
EOF
cat > "$test_root/third-party/example/module.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'raw status must never execute'
EOF
chmod +x "$test_root/third-party/example/module.sh"
printf '%s\n' "$test_root/state/modules/security-ssh/transactions/tx-1" \
    > "$test_root/state/modules/security-ssh/last_transaction"

cat > "$test_root/bin/sshd" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'port 22' 'port $sensitive_port'
EOF
chmod +x "$test_root/bin/sshd"

# Keep socket and unavailable-sshd cases independent of the host running this
# test. A real Debian VPS commonly has both ss and /usr/sbin/sshd available.
cat > "$test_root/bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$test_root/bin/unavailable-sshd" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$test_root/bin/ss" "$test_root/bin/unavailable-sshd"

call_log="$test_root/calls.log"
for command_name in apt-get curl wget service ufw fail2ban-client hostname reboot shutdown; do
    cat > "$test_root/bin/$command_name" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$command_name' >> '$call_log'
exit 99
EOF
    chmod +x "$test_root/bin/$command_name"
done

actual=$($CLI help)
assert_contains "$actual" 'vps report' "CLI help discovers the report command"

cli_output=$(PATH="$test_root/bin:$PATH" \
    VPS_STATE_DIR="$test_root/state" \
    VPS_OS_RELEASE_FILE="$test_root/os-release" \
    VPS_SSHD_BIN="$test_root/bin/sshd" \
    VPS_SYSTEMD_RUNTIME_DIR="$test_root/no-systemd" \
    VPS_MODULE_PATH="$PROJECT_ROOT/modules/builtin:$test_root/third-party" \
    SSH_CONNECTION="$sensitive_ipv4 55123 192.0.2.10 $sensitive_port" \
    VPS_FIXTURE_IPV6="$sensitive_ipv6" \
    VPS_FIXTURE_PUBLIC_KEY="$sensitive_public_key" \
    VPS_FIXTURE_PRIVATE_KEY="$sensitive_private" \
    VPS_FIXTURE_PASSWORD="$sensitive_password" \
    VPS_FIXTURE_COOKIE="$sensitive_cookie" \
    VPS_FIXTURE_NODE="$sensitive_node" \
    VPS_FIXTURE_AUTH="$sensitive_auth" \
    "$CLI" report --output diagnostic.txt)

assert_contains "$cli_output" '诊断报告已保存:' "report command prints only the saved location and guidance"
assert_contains "$cli_output" '默认已排除服务器身份、网络入口、认证材料和原始日志' \
    "terminal output explains the redaction boundary"
assert_contains "$cli_output" '分享前请自行打开检查' "terminal output asks the user to review before sharing"
report_file="$test_root/state/reports/diagnostic.txt"
assert_file_exists "$report_file" "report command creates the requested report"

mode=$(stat -c %a "$report_file" 2>/dev/null || stat -f %Lp "$report_file")
assert_eq '600' "$mode" "report permissions are limited to the current administrator"
report=$(<"$report_file")
assert_contains "$report" 'VPS Secure 脱敏诊断报告' "report uses a stable Chinese title"
assert_contains "$report" '[平台]' "report has a stable platform section"
assert_contains "$report" '[模块登记健康摘要]' "report has a bounded module health section"
assert_contains "$report" '最近事务: 存在' "report records transaction existence without its path"
assert_contains "$report" 'SSH 端口确认: 2 个；包含默认端口: 是' \
    "report keeps useful SSH counts without disclosing ports"
assert_contains "$report" '分享前请自行检查' "report includes the share-review warning"

for secret in \
    "$sensitive_ipv4" "$sensitive_ipv6" "$sensitive_host" "$sensitive_user" \
    "$sensitive_domain" "$sensitive_port" "$sensitive_public_key" "$sensitive_private" \
    "$sensitive_token" "$sensitive_password" "$sensitive_cookie" "$sensitive_ban" \
    "$sensitive_node" "$sensitive_auth" "$test_root"; do
    if grep -Fq -- "$secret" "$report_file"; then
        fail "default report excludes sensitive fixture: $secret"
    else
        pass "default report excludes sensitive fixture"
    fi
done

if LC_ALL=C od -An -tx1 "$report_file" | awk '
    {
        for (i = 1; i <= NF; i++) {
            value = ("0x" $i) + 0
            if ((value >= 0 && value <= 8) || value == 11 || value == 12 ||
                (value >= 14 && value <= 31) || value == 127) exit 1
        }
    }
'; then
    pass "report contains no terminal control characters"
else
    fail "report contains terminal control characters"
fi

NO_COLOR=1 PATH="$test_root/bin:$PATH" \
    VPS_STATE_DIR="$test_root/state" \
    VPS_OS_RELEASE_FILE="$test_root/os-release" \
    VPS_SSHD_BIN="$test_root/bin/sshd" \
    VPS_SYSTEMD_RUNTIME_DIR="$test_root/no-systemd" \
    VPS_MODULE_PATH="$PROJECT_ROOT/modules/builtin:$test_root/third-party" \
    SSH_CONNECTION="$sensitive_ipv4 55123 192.0.2.10 $sensitive_port" \
    "$CLI" report --output no-color.txt >/dev/null
if cmp -s "$report_file" "$test_root/state/reports/no-color.txt"; then
    pass "NO_COLOR and non-interactive report content are consistent"
else
    fail "NO_COLOR must not change non-interactive report content"
fi

if [[ -s "$call_log" ]]; then
    fail "report must not execute install, network, service, upload, or host-identity commands"
else
    pass "report does not execute mutating, network, upload, or host-identity commands"
fi

failure_state="$test_root/failure-state"
failure_output=$(PATH="$test_root/bin:$PATH" \
    SSH_CONNECTION='' \
    VPS_STATE_DIR="$failure_state" \
    VPS_OS_RELEASE_FILE="$test_root/missing-os-release" \
    VPS_SSHD_BIN="$test_root/bin/unavailable-sshd" \
    VPS_MODULE_PATH="$test_root/missing-modules" \
    "$CLI" report --output degraded.txt)
assert_contains "$failure_output" '诊断报告已保存:' \
    "failed subchecks do not prevent report creation"
degraded=$(<"$failure_state/reports/degraded.txt")
assert_contains "$degraded" '系统族与版本: unknown unknown' \
    "unavailable platform details are explicitly unknown"
assert_contains "$degraded" 'SSH 端口确认: 未知' \
    "unavailable SSH details are explicitly unknown"
assert_contains "$degraded" '已登记模块: 未知' \
    "unavailable module registration is explicitly unknown"

if VPS_STATE_DIR="$test_root/state" "$CLI" report --output '../escape.txt' >/dev/null 2>&1; then
    fail "report rejects directory traversal"
else
    pass "report rejects directory traversal"
fi

printf 'original-content\n' > "$test_root/state/reports/existing.txt"
if VPS_STATE_DIR="$test_root/state" "$CLI" report --output existing.txt >/dev/null 2>&1; then
    fail "report refuses to overwrite an existing file"
else
    pass "report refuses to overwrite an existing file"
fi
assert_eq 'original-content' "$(<"$test_root/state/reports/existing.txt")" \
    "existing report content remains unchanged"

printf 'outside-original\n' > "$test_root/outside-target.txt"
ln -s "$test_root/outside-target.txt" "$test_root/state/reports/linked.txt"
if VPS_STATE_DIR="$test_root/state" "$CLI" report --output linked.txt >/dev/null 2>&1; then
    fail "report refuses a symlink output target"
else
    pass "report refuses a symlink output target"
fi
assert_eq 'outside-original' "$(<"$test_root/outside-target.txt")" \
    "symlink output refusal preserves the linked file"

symlink_state="$test_root/symlink-state"
mkdir -p "$symlink_state" "$test_root/outside"
ln -s "$test_root/outside" "$symlink_state/reports"
if VPS_STATE_DIR="$symlink_state" "$CLI" report --output symlink.txt >/dev/null 2>&1; then
    fail "report rejects a symlink report directory"
else
    pass "report rejects a symlink report directory"
fi
if [[ -e "$test_root/outside/symlink.txt" ]]; then
    fail "symlink rejection must not create an outside report"
else
    pass "symlink rejection leaves the outside directory unchanged"
fi

mkdir -m 700 "$test_root/ancestor-real"
ln -s "$test_root/ancestor-real" "$test_root/ancestor-link"
if VPS_STATE_DIR="$test_root/ancestor-link/state" \
    "$CLI" report --output ancestor.txt >/dev/null 2>&1; then
    fail "report rejects a symlink ancestor"
else
    pass "report rejects a symlink ancestor"
fi
if [[ -e "$test_root/ancestor-real/state/reports/ancestor.txt" ]]; then
    fail "symlink ancestor rejection must not create an external report"
else
    pass "symlink ancestor rejection leaves the resolved target unchanged"
fi

world_state="$test_root/world-state"
mkdir -m 700 "$world_state"
chmod 777 "$world_state"
world_state_mode_before=$(stat -c %a "$world_state" 2>/dev/null || stat -f %Lp "$world_state")
if VPS_STATE_DIR="$world_state" "$CLI" report --output world.txt >/dev/null 2>&1; then
    fail "report rejects a world-writable state root"
else
    pass "report rejects a world-writable state root"
fi
world_state_mode_after=$(stat -c %a "$world_state" 2>/dev/null || stat -f %Lp "$world_state")
assert_eq "$world_state_mode_before" "$world_state_mode_after" \
    "untrusted state-root permissions are not changed"
if [[ -e "$world_state/reports" ]]; then
    fail "untrusted state root must not receive a reports directory"
else
    pass "untrusted state root remains otherwise unchanged"
fi

world_parent="$test_root/world-parent"
mkdir -m 700 "$world_parent" "$world_parent/state"
chmod 777 "$world_parent"
if VPS_STATE_DIR="$world_parent/state" \
    "$CLI" report --output parent.txt >/dev/null 2>&1; then
    fail "report rejects a state root beneath an untrusted parent"
else
    pass "report rejects a state root beneath an untrusted parent"
fi
if [[ -e "$world_parent/state/reports" ]]; then
    fail "untrusted parent must not receive report output"
else
    pass "untrusted parent and its state directory remain unchanged"
fi

world_reports_state="$test_root/world-reports-state"
mkdir -m 700 "$world_reports_state" "$world_reports_state/reports"
chmod 777 "$world_reports_state/reports"
printf 'keep\n' > "$world_reports_state/reports/original.txt"
world_reports_mode_before=$(stat -c %a "$world_reports_state/reports" 2>/dev/null || \
    stat -f %Lp "$world_reports_state/reports")
if VPS_STATE_DIR="$world_reports_state" \
    "$CLI" report --output world.txt >/dev/null 2>&1; then
    fail "report rejects a world-writable existing reports directory"
else
    pass "report rejects a world-writable existing reports directory"
fi
world_reports_mode_after=$(stat -c %a "$world_reports_state/reports" 2>/dev/null || \
    stat -f %Lp "$world_reports_state/reports")
assert_eq "$world_reports_mode_before" "$world_reports_mode_after" \
    "existing untrusted reports permissions are not changed"
assert_eq 'keep' "$(<"$world_reports_state/reports/original.txt")" \
    "existing content in an untrusted reports directory is preserved"

if [[ "$(uname -s)" == Linux && $EUID -eq 0 ]]; then
    foreign_state="$test_root/foreign-state"
    mkdir -m 700 "$foreign_state"
    chown 65534 "$foreign_state"
    if VPS_STATE_DIR="$foreign_state" "$CLI" report --output foreign.txt >/dev/null 2>&1; then
        fail "report rejects a state root owned by another user"
    else
        pass "report rejects a state root owned by another user"
    fi
    chown "$EUID" "$foreign_state"
fi

printf 'not-a-directory\n' > "$test_root/path-component"
if VPS_STATE_DIR="$test_root/path-component/state" \
    "$CLI" report --output unwritable.txt >/dev/null 2>&1; then
    fail "report stops when its controlled directory cannot be created"
else
    pass "report stops safely for an unavailable output directory"
fi

if (( EUID != 0 )); then
    unwritable_state="$test_root/unwritable-state"
    mkdir "$unwritable_state"
    chmod 500 "$unwritable_state"
    if VPS_STATE_DIR="$unwritable_state" \
        "$CLI" report --output unwritable.txt >/dev/null 2>&1; then
        fail "report stops for an unwritable controlled directory"
    else
        pass "report stops for an unwritable controlled directory"
    fi
    chmod 700 "$unwritable_state"
fi

# Source the report core so a test override can simulate a failure after a
# partial write without adding a production-only failure switch.
VPS_PLATFORM_ROOT="$PROJECT_ROOT"
source "$PROJECT_ROOT/core/platform.sh"
source "$PROJECT_ROOT/core/modules.sh"
source "$PROJECT_ROOT/core/runtime.sh"
source "$PROJECT_ROOT/core/ssh.sh"
source "$PROJECT_ROOT/core/report.sh"
race_state="$test_root/race-state"
mkdir -m 700 "$race_state" "$race_state/reports"
printf 'original-directory\n' > "$race_state/reports/sentinel.txt"
VPS_STATE_DIR="$race_state"
export VPS_STATE_DIR
mktemp() {
    local template=$1 report_dir=${1%/*}
    mv "$report_dir" "$report_dir.original"
    mkdir -m 700 "$report_dir"
    command mktemp "$template"
}
if vps_report_create raced.txt >/dev/null 2>&1; then
    fail "report rejects a reports-directory replacement during creation"
else
    pass "report rejects a reports-directory replacement during creation"
fi
unset -f mktemp
assert_eq 'original-directory' "$(<"$race_state/reports.original/sentinel.txt")" \
    "directory-replacement refusal preserves original content"
if [[ -e "$race_state/reports/raced.txt" ]] || \
   find "$race_state/reports" -type f -name '.vps-report.*' -print -quit | grep -q .; then
    fail "directory-replacement refusal must not leave output in the replacement"
else
    pass "directory-replacement refusal leaves no replacement output"
fi

VPS_STATE_DIR="$test_root/partial-state"
export VPS_STATE_DIR VPS_PLATFORM_ROOT
vps_report_write_content() {
    printf 'partial sensitive material\n'
    return 1
}
if vps_report_create partial.txt >/dev/null 2>&1; then
    fail "report surfaces a mid-generation failure"
else
    pass "report surfaces a mid-generation failure"
fi
if [[ -e "$VPS_STATE_DIR/reports/partial.txt" ]] || \
   find "$VPS_STATE_DIR/reports" -type f -name '.vps-report.*' -print -quit | grep -q .; then
    fail "mid-generation failure must not leave a report or temporary file"
else
    pass "mid-generation failure removes all partial output"
fi

finish_tests
