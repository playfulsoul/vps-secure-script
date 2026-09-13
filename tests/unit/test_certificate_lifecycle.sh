#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
CERTIFICATE_MODULE="$PROJECT_ROOT/modules/builtin/security-certificate/module.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root=$(mktemp -d)
test_root=$(readlink -f "$test_root")
tls_server_pid=''
cleanup() {
    [[ -z "$tls_server_pid" ]] || kill "$tls_server_pid" >/dev/null 2>&1 || true
    rm -rf -- "$test_root"
}
trap cleanup EXIT
bin_dir="$test_root/bin"
fixture_dir="$test_root/fixtures"
deploy_base="$test_root/managed-certificates"
deploy_root="$deploy_base/node"
runtime_state="$test_root/runtime-state"
fake_state="$test_root/fake-state"
mkdir -p "$bin_dir" "$fixture_dir" "$deploy_root/generations/old" "$runtime_state" "$fake_state"
printf 'ID=debian\nVERSION_ID=12\n' > "$test_root/os-release"

make_certificate() {
    local name=$1 days=$2
    openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
        -subj '/CN=node.example.invalid' \
        -addext 'subjectAltName=DNS:node.example.invalid' \
        -keyout "$fixture_dir/$name.key" -out "$fixture_dir/$name.pem" \
        >/dev/null 2>&1
    chmod 600 "$fixture_dir/$name.key"
}

make_certificate old 1
make_certificate renewed 365
make_certificate unrelated 365
cp "$fixture_dir/old.pem" "$fixture_dir/source.pem"
cp "$fixture_dir/old.key" "$fixture_dir/source.key"
printf '%s\n' \
    "Le_Domain='node.example.invalid'" \
    "Le_RealCertPath=''" \
    "Le_RealKeyPath=''" \
    "Le_RealFullChainPath=''" \
    "Le_ReloadCmd=''" \
    "Le_RenewHook=''" \
    "Le_DeployHook=''" > "$fixture_dir/domain.conf"
cp "$fixture_dir/old.pem" "$deploy_root/generations/old/fullchain.pem"
cp "$fixture_dir/old.key" "$deploy_root/generations/old/key.pem"
chmod 600 "$fixture_dir/source.key" "$deploy_root/generations/old/key.pem"
ln -s generations/old "$deploy_root/current"

cat > "$bin_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
case ${1:-} in
    is-active) exit 0 ;;
    reload|restart)
        count=0
        [[ ! -r "$VPS_TEST_CERT_STATE/service-count" ]] || count=$(<"$VPS_TEST_CERT_STATE/service-count")
        count=$((count + 1))
        printf '%s\n' "$count" > "$VPS_TEST_CERT_STATE/service-count"
        if [[ -e "$VPS_TEST_CERT_STATE/fail-service-once" && "$count" == 1 ]]; then
            rm -f "$VPS_TEST_CERT_STATE/fail-service-once"
            exit 1
        fi
        if [[ -e "$VPS_TEST_CERT_STATE/fail-service-restore" && "$count" == 2 ]]; then
            exit 1
        fi
        ;;
    *) exit 64 ;;
esac
EOF

cat > "$bin_dir/crontab" <<'EOF'
#!/usr/bin/env bash
set -u
case ${1:-} in
    -l)
        [[ -r "$VPS_TEST_CERT_STATE/crontab" ]] || exit 1
        cat "$VPS_TEST_CERT_STATE/crontab"
        ;;
    '') exit 64 ;;
    *) cp "$1" "$VPS_TEST_CERT_STATE/crontab" ;;
esac
EOF

cat > "$bin_dir/vps-fixture" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$VPS_TEST_CERT_STATE/vps-calls"
EOF

cat > "$bin_dir/acme-fixture" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$VPS_TEST_CERT_STATE/acme-calls"
case ${VPS_TEST_ACME_MODE:-skip} in
    skip) exit 2 ;;
    renew)
        cp "$VPS_TEST_CERT_FIXTURES/renewed.pem" "$VPS_TEST_CERT_FIXTURES/source.pem"
        cp "$VPS_TEST_CERT_FIXTURES/renewed.key" "$VPS_TEST_CERT_FIXTURES/source.key"
        chmod 600 "$VPS_TEST_CERT_FIXTURES/source.key"
        ;;
    invalid)
        cp "$VPS_TEST_CERT_FIXTURES/renewed.pem" "$VPS_TEST_CERT_FIXTURES/source.pem"
        cp "$VPS_TEST_CERT_FIXTURES/unrelated.key" "$VPS_TEST_CERT_FIXTURES/source.key"
        chmod 600 "$VPS_TEST_CERT_FIXTURES/source.key"
        ;;
    fail)
        printf 'SECRET_MARKER private material must stay hidden\n' >&2
        exit 1
        ;;
    *) exit 64 ;;
esac
EOF

cat > "$bin_dir/check-ok" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$bin_dir/flock" <<'EOF'
#!/usr/bin/env bash
[[ ${VPS_TEST_FLOCK_FAIL:-no} == yes ]] && exit 1
exit 0
EOF

cat > "$bin_dir/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "$VPS_TEST_LISTEN_PORT"
EOF

chmod +x "$bin_dir"/*

config_file="$test_root/certificate-lifecycle.conf"
cat > "$config_file" <<EOF
domain=node.example.invalid
acme_client=$bin_dir/acme-fixture
acme_domain_conf=$fixture_dir/domain.conf
acme_cert_file=$fixture_dir/source.pem
acme_key_file=$fixture_dir/source.key
acme_ecc=yes
deploy_root=$deploy_root
service_unit=x-ui.service
service_action=reload
cron_kind=user
cron_user=root
vps_command=$bin_dir/vps-fixture
min_validity_seconds=0
panel_healthcheck=$bin_dir/check-ok
reality_healthcheck=$bin_dir/check-ok
vless_healthcheck=$bin_dir/check-ok
EOF
chmod 600 "$config_file"

run_certificate() {
    local function_name=$1
    shift
    PATH="$bin_dir:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_OS_RELEASE_FILE="$test_root/os-release" \
    VPS_STATE_DIR="$runtime_state" \
    VPS_CERT_CONFIG_FILE="$config_file" \
    VPS_CERT_DEPLOY_BASE="$deploy_base" \
    VPS_CERT_ALLOW_UNSAFE_TEST_HOOKS=yes \
    VPS_CERT_COMMAND_TRUST_ROOT="$test_root" \
    VPS_CERT_DEPLOY_TRUST_ROOT="$test_root" \
    VPS_CERT_SYSTEM_CRON_ROOT="$test_root/etc" \
    VPS_TEST_CERT_STATE="$fake_state" \
    VPS_TEST_CERT_FIXTURES="$fixture_dir" \
        bash -c '
            source "$1" check >/dev/null
            vps_require_root() { return 0; }
            if [[ ${VPS_TEST_CERT_RECORD_FAIL:-no} == yes ]]; then
                vps_set_last_transaction() { return 1; }
            fi
            shift 2
            "$@"
        ' _ "$CERTIFICATE_MODULE" "$function_name" "$function_name" "$@"
}

current_target() {
    readlink "$deploy_root/current"
}

current_fingerprint() {
    openssl x509 -in "$deploy_root/current/fullchain.pem" -noout -fingerprint -sha256 |
        sed 's/^[^=]*=//; s/://g'
}

assert_recovery_evidence() {
    local transaction_dir=$1 label=$2
    if [[ -f "$transaction_dir/previous_target" &&
          -f "$transaction_dir/new_target" &&
          -f "$transaction_dir/restore-context" &&
          -f "$transaction_dir/compensation-status" ]]; then
        pass "$label retains complete recovery evidence"
    else
        fail "$label must retain complete recovery evidence"
    fi
}

old_fingerprint=$(openssl x509 -in "$fixture_dir/old.pem" -noout -fingerprint -sha256 |
    sed 's/^[^=]*=//; s/://g')
renewed_fingerprint=$(openssl x509 -in "$fixture_dir/renewed.pem" -noout -fingerprint -sha256 |
    sed 's/^[^=]*=//; s/://g')

# Deployment roots are resolved and bounded before any mutation.
actual=$(VPS_CERT_DEPLOY_ROOT="$deploy_base/.." run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "deployment root rejects a parent-directory leaf"
actual=$(VPS_CERT_DEPLOY_ROOT="$deploy_base/." run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "deployment root rejects a current-directory leaf"

mv "$deploy_base" "$deploy_base.real"
ln -s "$deploy_base.real" "$deploy_base"
actual=$(run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "deployment base rejects a symbolic link"
rm "$deploy_base"
mv "$deploy_base.real" "$deploy_base"

mv "$deploy_root" "$deploy_base/node.real"
ln -s "$deploy_base/node.real" "$deploy_root"
actual=$(run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "deployment node directory rejects a symbolic link"
rm "$deploy_root"
mv "$deploy_base/node.real" "$deploy_root"

mv "$deploy_root/generations" "$deploy_root/generations.real"
ln -s "$deploy_root/generations.real" "$deploy_root/generations"
actual=$(run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "generation directory rejects a symbolic link"
rm "$deploy_root/generations"
mv "$deploy_root/generations.real" "$deploy_root/generations"

# Root-scheduled executables must resolve inside a trusted, non-writable chain.
cp "$bin_dir/vps-fixture" "$bin_dir/vps-world-writable"
chmod 777 "$bin_dir/vps-world-writable"
actual=$(VPS_CERT_VPS_COMMAND="$bin_dir/vps-world-writable" \
    run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "world-writable vps command target is rejected"

cp "$bin_dir/acme-fixture" "$bin_dir/acme-world-writable"
chmod 777 "$bin_dir/acme-world-writable"
actual=$(VPS_CERT_ACME_CLIENT="$bin_dir/acme-world-writable" \
    run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "world-writable ACME client target is rejected"

actual=$(VPS_CERT_VPS_COMMAND="$bin_dir/vps-fixture;unexpected" \
    run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "cron command path rejects shell metacharacters"

ln -s /bin/true "$bin_dir/vps-outside-trust"
actual=$(VPS_CERT_VPS_COMMAND="$bin_dir/vps-outside-trust" \
    run_certificate certificate_check 2>&1)
result=$?
assert_eq '30' "$result" "command symlink target outside the trusted root is rejected"

mkdir -p "$test_root/controlled-install/bin"
cp "$bin_dir/vps-fixture" "$test_root/controlled-install/bin/vps"
chmod 755 "$test_root/controlled-install/bin/vps"
ln -s "$test_root/controlled-install/bin/vps" "$bin_dir/vps-safe-link"
actual=$(VPS_CERT_VPS_COMMAND="$bin_dir/vps-safe-link" \
    run_certificate certificate_check 2>&1)
result=$?
assert_eq '0' "$result" "safe command symlink to a controlled install target is accepted"

# No renewal: install the owned personal-crontab entry without reloading service.
actual=$(VPS_TEST_ACME_MODE=skip run_certificate certificate_apply 2>&1)
result=$?
assert_eq '0' "$result" "first no-renew run installs the missing scheduled entry"
assert_contains "$actual" '尚无需部署' "no-renew path reports a safe skip"
assert_eq 'generations/old' "$(current_target)" "no-renew path leaves the active generation unchanged"
if [[ -e "$fake_state/service-count" ]]; then
    fail "no-renew path must not reload the service"
else
    pass "no-renew path does not reload the service"
fi
personal_line=$(grep 'vps-secure:security.certificate' "$fake_state/crontab")
assert_contains "$personal_line" '17 3 * * *' "personal cron entry contains five schedule fields"
if [[ "$personal_line" == '17 3 * * * root '* ]]; then
    fail "personal cron entry must not contain a username field"
else
    pass "personal cron entry omits the system-cron username field"
fi

# Exercise the rendered personal-cron command through /bin/sh's parsing path.
personal_command=$(printf '%s\n' "$personal_line" | awk '{for (i=6; i<=NF; i++) printf "%s%s", $i, (i<NF ? OFS : ORS)}')
VPS_TEST_CERT_STATE="$fake_state" /bin/sh -c "$personal_command"
assert_contains "$(<"$fake_state/vps-calls")" \
    'module run security.certificate apply --yes --cron' \
    "personal cron shell path invokes the certificate module rather than a username command"

: > "$fake_state/acme-calls"
actual=$(VPS_TEST_ACME_MODE=skip run_certificate certificate_apply 2>&1)
result=$?
assert_eq '10' "$result" "repeat no-renew run is idempotently skipped"
transaction_count=$(find "$runtime_state/modules/security-certificate/transactions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq '1' "$transaction_count" "repeat no-renew run discards its temporary transaction"
assert_contains "$(<"$fake_state/acme-calls")" '--renew -d node.example.invalid --ecc' \
    "scheduled renewal uses a per-domain ACME due check"
if grep -q -- '--force' "$fake_state/acme-calls"; then
    fail "normal renewal must not pass a force flag"
else
    pass "normal renewal never passes a force flag"
fi

# A successful renewal creates a new generation, reloads, and verifies layers.
# The pre-renewal source is valid for only one day. A seven-day deployment
# floor must not prevent acme.sh from replacing that near-expiry source.
: > "$fake_state/acme-calls"
rm -f "$fake_state/service-count"
actual=$(VPS_CERT_MIN_VALIDITY_SECONDS=604800 VPS_TEST_ACME_MODE=renew \
    run_certificate certificate_apply 2>&1)
result=$?
assert_eq '0' "$result" "near-expiry source can renew before the deployment validity gate"
assert_eq "$renewed_fingerprint" "$(current_fingerprint)" \
    "successful deployment switches current to the renewed certificate"
assert_contains "$actual" '管理服务进程: 通过' "verification reports the service layer separately"
assert_contains "$actual" '受控面板访问路径: 通过' "verification reports the panel layer separately"
assert_contains "$actual" '直连 TLS、SNI 与实际证书: 未配置，未验证' \
    "verification does not imply an unconfigured direct TLS check passed"
assert_contains "$actual" '转发 TLS 与实际证书: 未配置，未验证' \
    "verification does not imply an unconfigured forwarded TLS check passed"
assert_contains "$actual" 'REALITY 协议专项健康: 通过' \
    "verification reports REALITY independently"
assert_contains "$actual" 'VLESS+TLS 协议专项健康: 通过' \
    "verification reports VLESS+TLS independently"
assert_eq '1' "$(<"$fake_state/service-count")" "successful deployment reloads the service once"
transaction=$(VPS_PLATFORM_ROOT="$PROJECT_ROOT" VPS_STATE_DIR="$runtime_state" \
    bash -c 'source "$1"; vps_last_transaction security.certificate' _ \
    "$PROJECT_ROOT/core/runtime.sh")
if find "$transaction" -type f -name '*key*' -print | grep -q .; then
    fail "transaction backup must not copy private key material"
else
    pass "transaction backup contains no private key copy"
fi

# Real loopback TLS handshakes distinguish the deployed certificate from TCP reachability.
tls_port=$((30000 + ($$ % 10000)))
openssl s_server -accept "127.0.0.1:$tls_port" \
    -cert "$deploy_root/current/fullchain.pem" -key "$deploy_root/current/key.pem" \
    -quiet >/dev/null 2>&1 &
tls_server_pid=$!
sleep 0.2
actual=$(VPS_TEST_LISTEN_PORT="$tls_port" \
    VPS_CERT_LOCAL_PORT="$tls_port" \
    VPS_CERT_DIRECT_HOST=127.0.0.1 VPS_CERT_DIRECT_PORT="$tls_port" \
    VPS_CERT_FORWARD_HOST=127.0.0.1 VPS_CERT_FORWARD_PORT="$tls_port" \
    run_certificate certificate_verify 2>&1)
result=$?
assert_eq '0' "$result" "loopback TLS fixture serves the active certificate"
assert_contains "$actual" '本机监听: 通过' "listener state is reported separately from TLS"
assert_contains "$actual" '直连 TLS、SNI 与实际证书: 通过' \
    "direct TLS verifies SNI and the served certificate fingerprint"
assert_contains "$actual" '转发 TLS 与实际证书: 通过' \
    "forwarded TLS is verified as a separate path"
kill "$tls_server_pid" >/dev/null 2>&1 || true
wait "$tls_server_pid" 2>/dev/null || true
tls_server_pid=''

wrong_tls_port=$((tls_port + 1))
openssl s_server -accept "127.0.0.1:$wrong_tls_port" \
    -cert "$fixture_dir/old.pem" -key "$fixture_dir/old.key" \
    -quiet >/dev/null 2>&1 &
tls_server_pid=$!
sleep 0.2
actual=$(VPS_CERT_DIRECT_HOST=127.0.0.1 VPS_CERT_DIRECT_PORT="$wrong_tls_port" \
    run_certificate certificate_verify 2>&1)
result=$?
assert_eq '50' "$result" "reachable TLS endpoint with the wrong certificate fails verification"
assert_contains "$actual" '直连 TLS、SNI 与实际证书: 失败' \
    "TCP reachability is not accepted as direct TLS certificate health"
kill "$tls_server_pid" >/dev/null 2>&1 || true
wait "$tls_server_pid" 2>/dev/null || true
tls_server_pid=''

# Manual rollback restores the previous valid generation and owned cron state.
actual=$(run_certificate certificate_rollback 2>&1)
result=$?
assert_eq '0' "$result" "rollback restores a still-valid previous generation"
assert_eq "$old_fingerprint" "$(current_fingerprint)" "rollback switches current back to the old generation"

# A completed switch is not committed unless its rollback pointer is durable.
before_target=$(current_target)
rm -f "$fake_state/service-count"
actual=$(VPS_TEST_ACME_MODE=renew VPS_TEST_CERT_RECORD_FAIL=yes \
    run_certificate certificate_apply 2>&1)
result=$?
assert_eq '40' "$result" "rollback-point registration failure rejects the transaction"
assert_eq "$before_target" "$(current_target)" \
    "rollback-point registration failure restores the previous deployment"
assert_eq '2' "$(<"$fake_state/service-count")" \
    "rollback-point registration failure reloads the new and restored generations"
assert_contains "$actual" '已核对恢复旧部署链接、旧定时入口与旧服务状态' \
    "rollback-point registration failure reports restoration"

# Issuance failure leaves the deployed generation unchanged and hides client output.
before_failure_transaction_count=$(find "$runtime_state/modules/security-certificate/transactions" \
    -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
actual=$(VPS_TEST_ACME_MODE=fail run_certificate certificate_apply 2>&1)
result=$?
assert_eq '40' "$result" "ACME failure is reported as apply failure"
assert_eq "$before_target" "$(current_target)" "ACME failure leaves current unchanged"
failed_transaction_count=$(find "$runtime_state/modules/security-certificate/transactions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "$before_failure_transaction_count" "$failed_transaction_count" \
    "ACME failure discards an uncommitted transaction"
if [[ "$actual" == *SECRET_MARKER* || "$actual" == *node.example.invalid* ]]; then
    fail "ACME failure output must hide secrets and configured addresses"
else
    pass "ACME failure output is redacted"
fi

# Saved acme.sh deployment paths or hooks would escape this transaction.
: > "$fake_state/acme-calls"
printf "%s\n" "Le_RealKeyPath='/etc/example/active.key'" > "$fixture_dir/domain.conf"
actual=$(VPS_TEST_ACME_MODE=renew run_certificate certificate_apply 2>&1)
result=$?
assert_eq '30' "$result" "preflight rejects an acme.sh saved deployment side effect"
assert_eq "$before_target" "$(current_target)" "ACME side-effect refusal leaves current unchanged"
if [[ -s "$fake_state/acme-calls" ]]; then
    fail "unsafe acme.sh configuration must be rejected before the client runs"
else
    pass "unsafe acme.sh configuration is rejected before the client runs"
fi
if [[ "$actual" == *'/etc/example/active.key'* ]]; then
    fail "ACME side-effect diagnostics must not print deployment paths"
else
    pass "ACME side-effect diagnostics redact deployment paths"
fi
printf '%s\n' \
    "Le_Domain='node.example.invalid'" \
    "Le_RealCertPath=''" \
    "Le_RealKeyPath=''" \
    "Le_RealFullChainPath=''" \
    "Le_ReloadCmd=''" \
    "Le_RenewHook=''" \
    "Le_DeployHook=''" > "$fixture_dir/domain.conf"

# The inspected acme.sh state must belong to the exact renewal domain.
: > "$fake_state/acme-calls"
printf "%s\n" "Le_Domain='other.example.invalid'" > "$fixture_dir/domain.conf"
actual=$(VPS_TEST_ACME_MODE=renew run_certificate certificate_apply 2>&1)
result=$?
assert_eq '30' "$result" "preflight rejects an acme.sh state file for another domain"
if [[ -s "$fake_state/acme-calls" ]]; then
    fail "mismatched acme.sh domain state must be rejected before the client runs"
else
    pass "mismatched acme.sh domain state is rejected before the client runs"
fi
printf '%s\n' \
    "Le_Domain='node.example.invalid'" \
    "Le_RealCertPath=''" \
    "Le_RealKeyPath=''" \
    "Le_RealFullChainPath=''" \
    "Le_ReloadCmd=''" \
    "Le_RenewHook=''" \
    "Le_DeployHook=''" > "$fixture_dir/domain.conf"

# A second ACME scheduler is a conflicting lifecycle owner.
printf '17 2 * * * /root/.acme.sh/acme.sh --cron\n%s\n' "$personal_line" > "$fake_state/crontab"
: > "$fake_state/acme-calls"
actual=$(VPS_TEST_ACME_MODE=renew run_certificate certificate_apply 2>&1)
result=$?
assert_eq '30' "$result" "preflight rejects a competing ACME scheduled task"
if [[ -s "$fake_state/acme-calls" ]]; then
    fail "competing ACME scheduler must be rejected before the client runs"
else
    pass "competing ACME scheduler is rejected before the client runs"
fi
printf '%s\n' "$personal_line" > "$fake_state/crontab"

# A mismatched renewed key fails before the deployment link is switched.
actual=$(VPS_TEST_ACME_MODE=invalid run_certificate certificate_apply 2>&1)
result=$?
assert_eq '40' "$result" "mismatched renewal artifacts fail deployment validation"
assert_eq "$before_target" "$(current_target)" "invalid deployment artifacts leave current unchanged"

# A service reload failure automatically switches back to the old generation.
cp "$fixture_dir/old.pem" "$fixture_dir/source.pem"
cp "$fixture_dir/old.key" "$fixture_dir/source.key"
chmod 600 "$fixture_dir/source.key"
rm -f "$fake_state/service-count"
: > "$fake_state/fail-service-once"
actual=$(VPS_TEST_ACME_MODE=renew run_certificate certificate_apply 2>&1)
result=$?
assert_eq '40' "$result" "service reload failure fails the transaction"
assert_eq "$before_target" "$(current_target)" "service reload failure restores the old generation"
assert_eq '2' "$(<"$fake_state/service-count")" \
    "service failure path retries only after restoring the old generation"

# A post-deployment TLS mismatch also uses the verified compensation path.
verify_fail_port=$((tls_port + 2))
openssl s_server -accept "127.0.0.1:$verify_fail_port" \
    -cert "$fixture_dir/old.pem" -key "$fixture_dir/old.key" \
    -quiet >/dev/null 2>&1 &
tls_server_pid=$!
sleep 0.2
rm -f "$fake_state/service-count"
actual=$(VPS_TEST_ACME_MODE=renew \
    VPS_CERT_DIRECT_HOST=127.0.0.1 VPS_CERT_DIRECT_PORT="$verify_fail_port" \
    run_certificate certificate_apply 2>&1)
result=$?
kill "$tls_server_pid" >/dev/null 2>&1 || true
wait "$tls_server_pid" 2>/dev/null || true
tls_server_pid=''
assert_eq '50' "$result" "post-deployment TLS mismatch fails the transaction"
assert_eq "$before_target" "$(current_target)" \
    "post-deployment verify failure restores the previous deployment"
assert_eq '2' "$(<"$fake_state/service-count")" \
    "post-deployment verify failure reloads new and restored generations"
assert_contains "$actual" '已核对恢复旧部署链接、旧定时入口与旧服务状态' \
    "post-deployment verify failure reports only verified restoration"

# System cron has a username field and its command survives /bin/sh parsing.
system_cron="$test_root/etc/cron.d/vps-secure-certificate"
mkdir -p "$(dirname -- "$system_cron")"
system_line=$(VPS_CERT_CRON_KIND=system VPS_CERT_CRON_FILE="$system_cron" \
    run_certificate certificate_cron_line)
assert_contains "$system_line" '17 3 * * * root ' "system cron entry contains the root username field"
printf '5 4 * * * root /usr/local/bin/unrelated-job\n' > "$system_cron"
actual=$(VPS_CERT_CRON_KIND=system VPS_CERT_CRON_FILE="$system_cron" \
    run_certificate certificate_cron_install 2>&1)
result=$?
assert_eq '30' "$result" "system cron refuses a file owned by another task"
assert_eq '5 4 * * * root /usr/local/bin/unrelated-job' "$(<"$system_cron")" \
    "system cron refusal preserves unrelated content"
rm -f "$system_cron"
system_command=$(printf '%s\n' "$system_line" | awk '{for (i=7; i<=NF; i++) printf "%s%s", $i, (i<NF ? OFS : ORS)}')
VPS_TEST_CERT_STATE="$fake_state" /bin/sh -c "$system_command"
assert_contains "$(<"$fake_state/vps-calls")" \
    'module run security.certificate apply --yes --cron' \
    "system cron shell path invokes the same bounded certificate transaction"

# Refuse rollback when the previous generation would violate the validity floor.
cp "$fixture_dir/old.pem" "$fixture_dir/source.pem"
cp "$fixture_dir/old.key" "$fixture_dir/source.key"
chmod 600 "$fixture_dir/source.key"
rm -f "$fake_state/service-count"
VPS_TEST_ACME_MODE=renew run_certificate certificate_apply >/dev/null
renewed_target=$(current_target)
actual=$(VPS_CERT_SERVICE_UNIT=other.service run_certificate certificate_rollback 2>&1)
result=$?
assert_eq '60' "$result" "rollback refuses a changed deployment or service boundary"
assert_eq "$renewed_target" "$(current_target)" "configuration-drift refusal leaves current unchanged"
assert_contains "$actual" '恢复边界不同' "configuration drift stops at an explicit confirmation boundary"

actual=$(VPS_TEST_FLOCK_FAIL=yes run_certificate certificate_apply 2>&1)
result=$?
assert_eq '30' "$result" "a concurrent certificate transaction is safely refused"
assert_eq "$renewed_target" "$(current_target)" "concurrency refusal leaves current unchanged"

actual=$(VPS_CERT_MIN_VALIDITY_SECONDS=172800 run_certificate certificate_rollback 2>&1)
result=$?
assert_eq '60' "$result" "rollback refuses a previous certificate below the configured validity floor"
assert_eq "$renewed_target" "$(current_target)" "refused rollback leaves the working generation active"
assert_contains "$actual" '需要人工确认' "unsafe rollback stops at an explicit confirmation boundary"

# Failed compensation retains the transaction context and both usable generations.
ln -sfn generations/old "$deploy_root/current"
rm -f "$fake_state/service-count"
actual=$(VPS_TEST_ACME_MODE=renew VPS_TEST_CERT_RECORD_FAIL=yes \
    VPS_TEST_CERT_FAIL_SWITCH_TARGET=generations/old \
    run_certificate certificate_apply 2>&1)
result=$?
assert_eq '40' "$result" "failed switch-back keeps the transaction failed"
switch_status=$(find "$runtime_state/modules/security-certificate/transactions" \
    -name compensation-status -type f -print | sort | tail -n 1)
assert_recovery_evidence "${switch_status%/*}" "switch-back failure"
assert_contains "$(<"$switch_status")" 'link_restored=no' \
    "switch-back failure is recorded in compensation evidence"
assert_contains "$actual" '已保留事务上下文及可用证书代' \
    "switch-back failure requires manual recovery without claiming restoration"
switch_new_target=$(<"${switch_status%/*}/new_target")
if [[ -d "$deploy_root/generations/old" && -d "$deploy_root/$switch_new_target" ]]; then
    pass "switch-back failure preserves old and new generations"
else
    fail "switch-back failure must preserve old and new generations"
fi

ln -sfn generations/old "$deploy_root/current"
rm -f "$fake_state/service-count"
actual=$(VPS_TEST_ACME_MODE=renew VPS_TEST_CERT_RECORD_FAIL=yes \
    VPS_TEST_CERT_FAIL_CRON_RESTORE=yes run_certificate certificate_apply 2>&1)
result=$?
assert_eq '40' "$result" "failed cron restoration keeps the transaction failed"
cron_status=$(find "$runtime_state/modules/security-certificate/transactions" \
    -name compensation-status -type f -print | sort | tail -n 1)
assert_recovery_evidence "${cron_status%/*}" "cron restoration failure"
assert_contains "$(<"$cron_status")" 'cron_restored=no' \
    "cron restoration failure is recorded in compensation evidence"
cron_new_target=$(<"${cron_status%/*}/new_target")
if [[ -d "$deploy_root/generations/old" && -d "$deploy_root/$cron_new_target" ]]; then
    pass "cron restoration failure preserves old and new generations"
else
    fail "cron restoration failure must preserve old and new generations"
fi

ln -sfn generations/old "$deploy_root/current"
rm -f "$fake_state/service-count"
: > "$fake_state/fail-service-restore"
actual=$(VPS_TEST_ACME_MODE=renew VPS_TEST_CERT_RECORD_FAIL=yes \
    run_certificate certificate_apply 2>&1)
result=$?
rm -f "$fake_state/fail-service-restore"
assert_eq '40' "$result" "failed old-service reload keeps the transaction failed"
service_status=$(find "$runtime_state/modules/security-certificate/transactions" \
    -name compensation-status -type f -print | sort | tail -n 1)
assert_recovery_evidence "${service_status%/*}" "old-service reload failure"
assert_contains "$(<"$service_status")" 'service_restored=no' \
    "old-service reload failure is recorded in compensation evidence"
service_new_target=$(<"${service_status%/*}/new_target")
if [[ -d "$deploy_root/generations/old" && -d "$deploy_root/$service_new_target" ]]; then
    pass "old-service reload failure preserves old and new generations"
else
    fail "old-service reload failure must preserve old and new generations"
fi

trap - EXIT
cleanup
finish_tests
