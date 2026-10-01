#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config" "$TEST_ROOT/install" "$TEST_ROOT/data" \
    "$TEST_ROOT/systemd" "$TEST_ROOT/service-state"
printf '%s\n' 'ID=debian' 'VERSION_ID="12"' > "$TEST_ROOT/os-release"

cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$VPS_TEST_SYSTEMCTL_LOG"
case ${1:-} in
    list-unit-files|cat)
        [[ ${2:-} == beszel-agent.service ]] && exit 1
        ;;
    is-enabled)
        [[ -e "$VPS_TEST_SERVICE_STATE/enabled" ]]
        exit
        ;;
    is-active)
        if [[ -e "$VPS_TEST_SERVICE_STATE/active" ]]; then
            [[ ${2:-} == --quiet ]] || printf 'active\n'
            exit 0
        fi
        [[ ${2:-} == --quiet ]] || printf 'inactive\n'
        exit 3
        ;;
    enable)
        touch "$VPS_TEST_SERVICE_STATE/enabled"
        [[ ${2:-} == --now ]] && touch "$VPS_TEST_SERVICE_STATE/active"
        ;;
    disable)
        rm -f "$VPS_TEST_SERVICE_STATE/enabled"
        [[ ${2:-} == --now ]] && rm -f "$VPS_TEST_SERVICE_STATE/active"
        ;;
    restart|start)
        if [[ -e "$VPS_TEST_SERVICE_STATE/fail-next-start" ]]; then
            rm -f "$VPS_TEST_SERVICE_STATE/fail-next-start"
            exit 1
        fi
        touch "$VPS_TEST_SERVICE_STATE/active"
        ;;
    stop)
        rm -f "$VPS_TEST_SERVICE_STATE/active"
        ;;
    daemon-reload) ;;
esac
exit 0
EOF
cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected network call\n' >&2
exit 99
EOF
chmod +x "$TEST_ROOT/bin/systemctl" "$TEST_ROOT/bin/curl"

KEY_SOURCE="$TEST_ROOT/source-key"
TOKEN_SOURCE="$TEST_ROOT/source-token"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey monitor' > "$KEY_SOURCE"
printf '%s\n' 'SECRET_MARKER_TOKEN_123456789' > "$TOKEN_SOURCE"
chmod 600 "$KEY_SOURCE" "$TOKEN_SOURCE"

export VPS_PLATFORM_ROOT=$PROJECT_ROOT
export VPS_STATE_DIR="$TEST_ROOT/state"
export VPS_OS_RELEASE_FILE="$TEST_ROOT/os-release"
export VPS_BESZEL_AGENT_CONFIG_DIR="$TEST_ROOT/config"
export VPS_BESZEL_AGENT_INSTALL_DIR="$TEST_ROOT/install"
export VPS_BESZEL_AGENT_DATA_DIR="$TEST_ROOT/data"
export VPS_BESZEL_AGENT_SERVICE_FILE="$TEST_ROOT/systemd/vps-secure-beszel-agent.service"
export VPS_BESZEL_AGENT_USER
VPS_BESZEL_AGENT_USER=$(id -un)
export VPS_BESZEL_AGENT_GROUP
VPS_BESZEL_AGENT_GROUP=$(id -gn)
export VPS_TEST_SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
export VPS_TEST_SERVICE_STATE="$TEST_ROOT/service-state"
export PATH="$TEST_ROOT/bin:$PATH"

# shellcheck source=../../modules/builtin/monitoring-beszel-agent/module.sh
source "$PROJECT_ROOT/modules/builtin/monitoring-beszel-agent/module.sh"

vps_require_root() { return 0; }
beszel_agent_platform_asset() { printf 'beszel-agent_linux_amd64.tar.gz\n'; }
beszel_agent_probe_hub() { return 0; }
beszel_agent_fetch_release() {
    local _version=$1 destination=$2
    cat > "$destination/beszel-agent" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "$destination/beszel-agent"
}

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

default_paths=$(VPS_BESZEL_AGENT_CONFIG_DIR='' VPS_BESZEL_AGENT_DATA_DIR='' \
    bash -c 'source "$1"; printf "%s\n%s\n" "$BESZEL_AGENT_CONFIG_DIR" "$BESZEL_AGENT_DATA_DIR"' \
    _ "$PROJECT_ROOT/modules/builtin/monitoring-beszel-agent/module.sh")
assert_contains "$default_paths" '/etc/vps-secure-beszel-agent' \
    "agent credentials avoid the root-only platform config parent"
assert_contains "$default_paths" '/var/lib/vps-secure-beszel-agent' \
    "agent data avoids the root-only platform state parent"

assert_not_contains_secret() {
    local value=$1 message=$2
    if [[ "$value" == *SECRET_MARKER* ]]; then
        fail "$message (secret was exposed)"
    else
        pass "$message"
    fi
}

archive_fixture="$TEST_ROOT/archive-fixture"
mkdir -p "$archive_fixture/valid" "$archive_fixture/extra" "$archive_fixture/link"
printf 'license\n' > "$archive_fixture/valid/LICENSE"
printf 'readme\n' > "$archive_fixture/valid/readme.md"
printf '#!/usr/bin/env sh\nexit 0\n' > "$archive_fixture/valid/beszel-agent"
tar -czf "$archive_fixture/valid.tar.gz" -C "$archive_fixture/valid" \
    LICENSE readme.md beszel-agent
mkdir -p "$archive_fixture/extracted"
if beszel_agent_extract_release_archive "$archive_fixture/valid.tar.gz" \
    "$archive_fixture/extracted"; then
    pass "agent accepts the exact upstream release layout"
else
    fail "agent accepts the exact upstream release layout"
fi
assert_file_exists "$archive_fixture/extracted/beszel-agent" \
    "agent extracts only the executable from the upstream release"

cp -R "$archive_fixture/valid/." "$archive_fixture/extra/"
printf 'unexpected\n' > "$archive_fixture/extra/extra-file"
tar -czf "$archive_fixture/extra.tar.gz" -C "$archive_fixture/extra" \
    LICENSE readme.md beszel-agent extra-file
if beszel_agent_extract_release_archive "$archive_fixture/extra.tar.gz" \
    "$archive_fixture/extracted" >/dev/null 2>&1; then
    fail "agent rejects release archives with extra files"
else
    pass "agent rejects release archives with extra files"
fi

printf 'license\n' > "$archive_fixture/link/LICENSE"
printf '#!/usr/bin/env sh\nexit 0\n' > "$archive_fixture/link/beszel-agent"
ln -s LICENSE "$archive_fixture/link/readme.md"
tar -czf "$archive_fixture/link.tar.gz" -C "$archive_fixture/link" \
    LICENSE readme.md beszel-agent
if beszel_agent_extract_release_archive "$archive_fixture/link.tar.gz" \
    "$archive_fixture/extracted" >/dev/null 2>&1; then
    fail "agent rejects non-regular release members"
else
    pass "agent rejects non-regular release members"
fi

if beszel_agent_validate_hub_url 'https://203.0.113.10' >/dev/null 2>&1; then
    fail "agent rejects a raw Hub IP"
else
    pass "agent rejects a raw Hub IP"
fi
if beszel_agent_validate_hub_url 'http://monitor.example.com' >/dev/null 2>&1; then
    fail "agent rejects a plaintext Hub URL"
else
    pass "agent rejects a plaintext Hub URL"
fi
if beszel_agent_parse_join_args --hub-url https://monitor.example.com \
    --key-file "$KEY_SOURCE" --token-file >/dev/null 2>&1; then
    fail "agent rejects a missing credential-file argument"
else
    pass "agent rejects a missing credential-file argument"
fi

actual=$(beszel_agent_plan --hub-url https://monitor.example.com \
    --key-file "$KEY_SOURCE" --token-file "$TOKEN_SOURCE")
assert_contains "$actual" '主动连接 Hub' "agent plan describes outbound-only mode"
assert_contains "$actual" '不开放入站端口' "agent plan preserves the firewall boundary"
assert_not_contains_secret "$actual" "agent plan redacts token contents"

actual=$(beszel_agent_apply --hub-url https://monitor.example.com \
    --key-file "$KEY_SOURCE" --token-file "$TOKEN_SOURCE")
assert_contains "$actual" '已安装并启动' "agent apply reports local startup only"
assert_not_contains_secret "$actual" "agent apply redacts token contents"
assert_file_exists "$TEST_ROOT/install/beszel-agent" "agent apply installs the verified binary"
assert_file_exists "$TEST_ROOT/systemd/vps-secure-beszel-agent.service" \
    "agent apply installs a module-owned service"
assert_file_exists "$TEST_ROOT/config/hub-token" "agent apply stores a protected token file"
actual=$(<"$TEST_ROOT/systemd/vps-secure-beszel-agent.service")
assert_contains "$actual" "EnvironmentFile=$TEST_ROOT/config/agent.env" \
    "agent service references a protected environment file"
assert_not_contains_secret "$actual" "agent service does not inline token contents"
actual=$(<"$TEST_ROOT/config/agent.env")
assert_contains "$actual" 'DISABLE_SSH=true' "agent disables the inbound SSH listener"
assert_contains "$actual" 'DOCKER_HOST=' "agent does not inherit Docker socket access"
assert_not_contains_secret "$actual" "agent environment does not inline token contents"
mode=$(beszel_agent_file_mode "$TEST_ROOT/config/hub-token")
assert_eq '600' "$mode" "agent token is stored with mode 600"
mode=$(beszel_agent_file_mode "$TEST_ROOT/config")
assert_eq '710' "$mode" "agent config directory permits group traversal without listing"
actual=$(stat -c '%G' "$TEST_ROOT/config" 2>/dev/null || stat -f '%Sg' "$TEST_ROOT/config")
assert_eq "$VPS_BESZEL_AGENT_GROUP" "$actual" \
    "agent config directory grants traversal to the service group"

: > "$TEST_ROOT/systemctl.log"
if actual=$(beszel_agent_apply --hub-url https://monitor.example.com \
    --key-file "$KEY_SOURCE" --token-file "$TOKEN_SOURCE"); then
    result=0
else
    result=$?
fi
assert_eq '10' "$result" "identical agent apply is safely idempotent"
assert_contains "$actual" '无需修改' "idempotent apply explains that no change is needed"
if grep -Eq 'restart|enable --now' "$TEST_ROOT/systemctl.log"; then
    fail "idempotent apply does not restart the service"
else
    pass "idempotent apply does not restart the service"
fi

beszel_agent_rebind --hub-url https://monitor-new.example.com
actual=$(beszel_agent_config_hub_url)
assert_eq 'https://monitor-new.example.com' "$actual" "rebind updates only the stable Hub URL"
actual=$(<"$TEST_ROOT/config/hub-token")
assert_eq 'SECRET_MARKER_TOKEN_123456789' "$actual" "rebind preserves the token"

touch "$TEST_ROOT/service-state/fail-next-start"
if actual=$(beszel_agent_rebind --hub-url https://monitor-failed.example.com 2>&1); then
    result=0
else
    result=$?
fi
assert_eq '50' "$result" "failed rebind returns a verification failure"
assert_contains "$actual" '恢复原配置' "failed rebind reports automatic rollback"
actual=$(beszel_agent_config_hub_url)
assert_eq 'https://monitor-new.example.com' "$actual" "failed rebind restores the previous Hub URL"
mode=$(beszel_agent_file_mode "$TEST_ROOT/install/beszel-agent")
assert_eq '755' "$mode" "failed rebind restores the executable mode"
if systemctl is-active --quiet "$BESZEL_AGENT_SERVICE"; then
    pass "failed rebind restores the running service"
else
    fail "failed rebind restores the running service"
fi

actual=$(beszel_agent_status)
assert_contains "$actual" '入站监听：已关闭' "status reports the outbound-only security posture"
assert_contains "$actual" '最终以 Hub 的最新采样时间为准' \
    "status does not claim end-to-end Hub connectivity"
assert_not_contains_secret "$actual" "status redacts token contents"

actual=$(beszel_agent_doctor)
assert_not_contains_secret "$actual" "doctor redacts token contents"

beszel_agent_uninstall
if [[ -e "$TEST_ROOT/config/hub-token" ]]; then
    fail "uninstall removes the active token file"
else
    pass "uninstall removes the active token file"
fi
if [[ -d "$TEST_ROOT/data" ]]; then
    pass "uninstall preserves agent fingerprint data"
else
    fail "uninstall preserves agent fingerprint data"
fi

finish_tests
