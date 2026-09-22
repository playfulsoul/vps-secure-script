#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
STATE_ROOT="$TEST_ROOT/state"
HOME_ROOT="$TEST_ROOT/home/admin"
CONFIG_DIR="$TEST_ROOT/sshd_config.d"
CONFIG_FILE="$CONFIG_DIR/00-vps-secure-login-hardening.conf"
PASSWD_FILE="$TEST_ROOT/passwd"
GROUP_FILE="$TEST_ROOT/group"
AUTH_LOG="$TEST_ROOT/auth.log"
FAKE_BIN="$TEST_ROOT/bin"
KEY_MODULE="$TEST_ROOT/key-module"
SSHD_BIN="$TEST_ROOT/sshd"
SYSTEMCTL_BIN="$TEST_ROOT/systemctl"
MODULE="$PROJECT_ROOT/modules/builtin/security-login/module.sh"
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

mkdir -p "$STATE_ROOT" "$HOME_ROOT/.ssh" "$CONFIG_DIR" "$FAKE_BIN"
chmod 700 "$HOME_ROOT/.ssh"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForVpsSecure admin@test' \
    > "$HOME_ROOT/.ssh/authorized_keys"
chmod 600 "$HOME_ROOT/.ssh/authorized_keys"
printf 'admin:x:%s:%s::%s:/bin/bash\n' "$CURRENT_UID" "$CURRENT_GID" "$HOME_ROOT" > "$PASSWD_FILE"
printf '%s\n' 'sudo:x:27:admin' > "$GROUP_FILE"

for command_name in useradd usermod passwd gpasswd userdel; do
    command_path="$FAKE_BIN/$command_name"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$command_path"
    chmod +x "$command_path"
done

cat > "$KEY_MODULE" <<'EOF'
#!/usr/bin/env bash
set -u
state="$VPS_STATE_DIR/modules/security-ssh"
case ${1:-} in
    configure)
        transaction="$state/transactions/test-key"
        mkdir -p "$transaction"
        chmod 700 "$state" "$state/transactions" "$transaction"
        printf '%s\n' "$transaction" > "$state/last_transaction"
        printf 'committed\n' > "$transaction/phase"
        printf '公钥测试事务已提交。\n'
        ;;
    rollback)
        printf 'rolled-back\n' > "$(cat "$state/last_transaction")/phase"
        ;;
    *) exit 64 ;;
esac
EOF
chmod +x "$KEY_MODULE"

cat > "$SSHD_BIN" <<'EOF'
#!/usr/bin/env bash
set -u
case ${1:-} in
    -t)
        [[ ! -e ${VPS_TEST_SSHD_FAIL_FILE:-/nonexistent} ]]
        ;;
    -T)
        password=yes
        keyboard=yes
        root_mode=yes
        if [[ ! -e ${VPS_TEST_SSHD_IGNORE_CONFIG_FILE:-/nonexistent} && -r ${VPS_LOGIN_CONFIG_FILE:-} ]]; then
            while read -r key value; do
                lower_key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
                case $lower_key in
                    passwordauthentication) password=$value ;;
                    kbdinteractiveauthentication) keyboard=$value ;;
                    permitrootlogin) root_mode=$value ;;
                esac
            done < "$VPS_LOGIN_CONFIG_FILE"
        fi
        if [[ ${VPS_TEST_SSHD_ROOT_ALIAS:-no} == yes && "$root_mode" == prohibit-password ]]; then
            root_mode=without-password
        fi
        printf 'port 32876\npasswordauthentication %s\nkbdinteractiveauthentication %s\npermitrootlogin %s\npubkeyauthentication yes\n' \
            "$password" "$keyboard" "$root_mode"
        ;;
    *) exit 64 ;;
esac
EOF
chmod +x "$SSHD_BIN"

cat > "$SYSTEMCTL_BIN" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$VPS_TEST_SYSTEMCTL_LOG"
[[ ! -e ${VPS_TEST_SYSTEMCTL_FAIL_FILE:-/nonexistent} ]]
EOF
chmod +x "$SYSTEMCTL_BIN"

run_module() {
    env PATH="$FAKE_BIN:$PATH" \
        VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
        VPS_MODULE_ID=security.login-hardening \
        VPS_STATE_DIR="$STATE_ROOT" \
        VPS_LOGIN_ALLOW_NON_ROOT=yes \
        VPS_LOGIN_PASSWD_FILE="$PASSWD_FILE" \
        VPS_LOGIN_GROUP_FILE="$GROUP_FILE" \
        VPS_LOGIN_SSHD_CONFIG_DIR="$CONFIG_DIR" \
        VPS_LOGIN_CONFIG_FILE="$CONFIG_FILE" \
        VPS_LOGIN_AUTH_LOG_FILE="$AUTH_LOG" \
        VPS_LOGIN_KEY_MODULE_COMMAND="$KEY_MODULE" \
        VPS_SSHD_BIN="$SSHD_BIN" \
        VPS_LOGIN_SSHD_COMMAND="$SSHD_BIN" \
        VPS_LOGIN_SYSTEMCTL_COMMAND="$SYSTEMCTL_BIN" \
        VPS_TEST_SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log" \
        VPS_LOGIN_VERIFY_TTL=1800 \
        "$MODULE" "$@"
}

assert_path_absent() {
    if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2 (unexpected path: $1)"; fi
}

actual=$(run_module plan --user admin --github octocat)
assert_contains "$actual" '新的公钥 SSH 会话' "login plan requires a separate public-key session"
assert_contains "$actual" '不会修改 sshd 配置' "login preparation leaves current login methods unchanged"

printf '%s\n' 'Aug 22 sshd[99]: Accepted publickey for admin from 203.0.113.10 port 54321 ssh2: ED25519 SHA256:stale' \
    > "$AUTH_LOG"
actual=$(run_module apply --user admin --github octocat)
token=$(printf '%s\n' "$actual" | sed -n 's/.*--token \([a-f0-9][a-f0-9]*\)$/\1/p')
if [[ "$token" =~ ^[a-f0-9]{32}$ ]]; then
    pass "login preparation issues a one-time verification token"
else
    fail "login preparation must issue a one-time verification token"
fi
assert_path_absent "$CONFIG_FILE" "preparation does not change sshd policy"

actual=$(run_module configure password-disable --user admin 2>&1 || true)
assert_contains "$actual" '尚未完成有效的新窗口' "password hardening is locked before verification"
assert_path_absent "$CONFIG_FILE" "unverified hardening cannot create an sshd drop-in"

printf '%s\n' 'Aug 22 sshd[100]: Accepted password for admin from 203.0.113.10 port 54321 ssh2' >> "$AUTH_LOG"
actual=$(SUDO_USER=admin VPS_LOGIN_SESSION='203.0.113.10 54321 192.0.2.20 32876' \
    run_module verify --token "$token" 2>&1 || true)
assert_contains "$actual" '未找到与当前连接匹配的公钥登录记录' \
    "password session and a stale public-key log cannot unlock hardening"

printf '%s\n' 'Aug 22 sshd[101]: Accepted publickey for admin from 203.0.113.10 port 54321 ssh2: ED25519 SHA256:test' \
    >> "$AUTH_LOG"
actual=$(SUDO_USER=admin VPS_LOGIN_SESSION='203.0.113.10 54321 192.0.2.20 32876' \
    run_module verify --token "$token")
assert_contains "$actual" '公钥登录与 sudo 已验证' "matching public-key session unlocks the first hardening stage"

actual=$(run_module preflight admin)
assert_contains "$actual" '登录安全预检通过' "verified user passes login-hardening preflight"

actual=$(run_module configure password-disable --user admin)
second_token=$(printf '%s\n' "$actual" | sed -n 's/.*--token \([a-f0-9][a-f0-9]*\)$/\1/p')
assert_contains "$(<"$CONFIG_FILE")" 'PasswordAuthentication no' "password authentication is disabled in the owned drop-in"
assert_contains "$(<"$CONFIG_FILE")" 'KbdInteractiveAuthentication no' "keyboard-interactive password fallback is disabled"
assert_contains "$actual" '必须再次从新窗口验证' "root restriction remains locked after password hardening"
if [[ "$second_token" =~ ^[a-f0-9]{32}$ && "$second_token" != "$token" ]]; then
    pass "password hardening rotates the verification token"
else
    fail "password hardening must require a fresh verification token"
fi

actual=$(run_module configure root-restrict --user admin --mode key-only 2>&1 || true)
assert_contains "$actual" '尚未完成有效的新窗口' "root restriction is locked until post-password verification"

printf '%s\n' 'Aug 22 sshd[102]: Accepted publickey for admin from 203.0.113.10 port 54322 ssh2: ED25519 SHA256:test' \
    >> "$AUTH_LOG"
actual=$(SUDO_USER=admin VPS_LOGIN_SESSION='203.0.113.10 54322 192.0.2.20 32876' \
    run_module verify --token "$second_token")
assert_contains "$actual" '公钥登录与 sudo 已验证' "fresh public-key session unlocks root restriction"

actual=$(VPS_TEST_SSHD_ROOT_ALIAS=yes run_module configure root-restrict --user admin --mode key-only)
assert_contains "$(<"$CONFIG_FILE")" 'PermitRootLogin prohibit-password' \
    "recommended root policy keeps root keys while rejecting root passwords"
assert_contains "$actual" 'prohibit-password' "root key-only result is explicit"

actual=$(run_module configure root-restrict --user admin --mode disable)
assert_contains "$(<"$CONFIG_FILE")" 'PermitRootLogin no' \
    "optional strict root policy disables direct root login"

actual=$(run_module rollback)
assert_contains "$actual" '已恢复上一次 SSH 登录策略' "first rollback restores the root key-only policy"
assert_contains "$(<"$CONFIG_FILE")" 'PermitRootLogin prohibit-password' \
    "strict-root rollback restores root key-only access"

actual=$(run_module rollback)
assert_contains "$actual" '已恢复上一次 SSH 登录策略' "second rollback restores the pre-root policy"
if grep -q '^PermitRootLogin' "$CONFIG_FILE"; then
    fail "root rollback must remove the module-owned root restriction"
else
    pass "root rollback preserves password hardening without a root directive"
fi

actual=$(run_module rollback)
assert_contains "$actual" '已恢复上一次 SSH 登录策略' "third rollback restores the pre-hardening policy"
assert_path_absent "$CONFIG_FILE" "password rollback removes a newly created module drop-in"

third_token=$(printf '%s\n' "$actual" | sed -n 's/.*--token \([a-f0-9][a-f0-9]*\)$/\1/p')
printf '%s\n' 'Aug 22 sshd[103]: Accepted publickey for admin from 203.0.113.10 port 54323 ssh2: ED25519 SHA256:test' \
    >> "$AUTH_LOG"
actual=$(SUDO_USER=admin VPS_LOGIN_SESSION='203.0.113.10 54323 192.0.2.20 32876' \
    run_module verify --token "$third_token")
assert_contains "$actual" '公钥登录与 sudo 已验证' "rollback requires and accepts a new verification"

: > "$TEST_ROOT/empty-random"
actual=$(VPS_LOGIN_RANDOM_FILE="$TEST_ROOT/empty-random" \
    run_module configure password-disable --user admin 2>&1 || true)
assert_contains "$actual" '已恢复关闭密码前的配置' \
    "second-stage token failure compensates password hardening"
assert_path_absent "$CONFIG_FILE" "token failure does not leave password authentication disabled"

printf '%s\n' original > "$CONFIG_FILE"
actual=$(run_module configure password-disable --user admin 2>&1 || true)
assert_contains "$actual" '不是本模块所有' "module refuses an unowned sshd drop-in after verification"
assert_contains "$(<"$CONFIG_FILE")" original "module never overwrites an unowned sshd drop-in"
rm -f -- "$CONFIG_FILE"

touch "$TEST_ROOT/ignore-config"
actual=$(VPS_TEST_SSHD_IGNORE_CONFIG_FILE="$TEST_ROOT/ignore-config" \
    run_module configure password-disable --user admin 2>&1 || true)
assert_contains "$actual" '已恢复原配置' "effective-policy mismatch triggers automatic compensation"
assert_path_absent "$CONFIG_FILE" "failed effective verification restores the absent drop-in"
assert_path_absent "$STATE_ROOT/modules/security-login-hardening/last_transaction" \
    "compensated hardening does not become a rollback point"
rm -f -- "$TEST_ROOT/ignore-config"

NEW_STATE_ROOT="$TEST_ROOT/new-state"
NEW_PASSWD_FILE="$TEST_ROOT/new-passwd"
NEW_GROUP_FILE="$TEST_ROOT/new-group"
NEW_HOME="$TEST_ROOT/home/deploy"
: > "$NEW_PASSWD_FILE"
printf '%s\n' 'sudo:x:27:' > "$NEW_GROUP_FILE"
cat > "$FAKE_BIN/useradd" <<'EOF'
#!/usr/bin/env bash
set -u
username=${!#}
mkdir -p "$VPS_TEST_NEW_HOME/.ssh"
chmod 700 "$VPS_TEST_NEW_HOME/.ssh"
printf 'deploy:x:%s:%s::%s:/bin/bash\n' "$(id -u)" "$(id -g)" "$VPS_TEST_NEW_HOME" >> "$VPS_LOGIN_PASSWD_FILE"
printf 'useradd %s\n' "$username" > "$VPS_TEST_USERADD_LOG"
EOF
cat > "$FAKE_BIN/passwd" <<'EOF'
#!/usr/bin/env bash
printf 'passwd %s\n' "$1" > "$VPS_TEST_PASSWD_LOG"
EOF
cat > "$FAKE_BIN/usermod" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'usermod %s\n' "$*" > "$VPS_TEST_USERMOD_LOG"
printf '%s\n' 'sudo:x:27:deploy' > "$VPS_LOGIN_GROUP_FILE"
EOF
chmod +x "$FAKE_BIN/useradd" "$FAKE_BIN/passwd" "$FAKE_BIN/usermod"

actual=$(env PATH="$FAKE_BIN:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" VPS_MODULE_ID=security.login-hardening \
    VPS_STATE_DIR="$NEW_STATE_ROOT" VPS_LOGIN_ALLOW_NON_ROOT=yes \
    VPS_LOGIN_PASSWD_FILE="$NEW_PASSWD_FILE" VPS_LOGIN_GROUP_FILE="$NEW_GROUP_FILE" \
    VPS_LOGIN_SSHD_CONFIG_DIR="$CONFIG_DIR" VPS_LOGIN_CONFIG_FILE="$CONFIG_FILE" \
    VPS_LOGIN_AUTH_LOG_FILE="$AUTH_LOG" VPS_LOGIN_KEY_MODULE_COMMAND="$KEY_MODULE" \
    VPS_SSHD_BIN="$SSHD_BIN" VPS_LOGIN_SSHD_COMMAND="$SSHD_BIN" \
    VPS_LOGIN_SYSTEMCTL_COMMAND="$SYSTEMCTL_BIN" VPS_TEST_SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log" \
    VPS_TEST_NEW_HOME="$NEW_HOME" VPS_TEST_USERADD_LOG="$TEST_ROOT/useradd.log" \
    VPS_TEST_PASSWD_LOG="$TEST_ROOT/passwd.log" VPS_TEST_USERMOD_LOG="$TEST_ROOT/usermod.log" \
    "$MODULE" apply --user deploy --github octocat)
assert_contains "$(<"$TEST_ROOT/useradd.log")" 'useradd deploy' "preparation creates a missing ordinary user"
assert_contains "$(<"$TEST_ROOT/passwd.log")" 'passwd deploy' "new ordinary user receives an interactive password step"
assert_contains "$(<"$TEST_ROOT/usermod.log")" 'usermod -aG sudo deploy' "new ordinary user is added to the sudo group"
assert_contains "$actual" '验证完成前' "new-user preparation still preserves current login methods"

finish_tests
