#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VPS_PLATFORM_ROOT=$PROJECT_ROOT
VPS_MODULE_ID=applications.remote-desktop
export VPS_PLATFORM_ROOT VPS_MODULE_ID

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

temporary_root=$(mktemp -d)
trap 'rm -rf -- "$temporary_root"' EXIT
test_transaction="$temporary_root/state/modules/applications-remote-desktop/transactions/original"
config_dir="$temporary_root/config"
mkdir -p "$temporary_root/bin" "$test_transaction" "$config_dir"

cat > "$temporary_root/bin/fc-list" <<'EOF'
#!/usr/bin/env bash
[[ -e "$VPS_TEST_FONT_READY" ]] && printf 'Noto Sans CJK SC\n'
EOF
cat > "$temporary_root/bin/fc-cache" <<'EOF'
#!/usr/bin/env bash
touch "$VPS_TEST_FONT_READY"
EOF
chmod +x "$temporary_root/bin/fc-list" "$temporary_root/bin/fc-cache"

export PATH="$temporary_root/bin:$PATH"
export VPS_STATE_DIR="$temporary_root/state"
export VPS_REMOTE_DESKTOP_CONFIG_DIR="$config_dir"
export VPS_REMOTE_DESKTOP_TEST_MODE=yes
export VPS_REMOTE_DESKTOP_LISTENER_STATE=loopback
export VPS_TEST_FONT_PRESENT="$temporary_root/font-present"
export VPS_TEST_FONT_INSTALLED="$temporary_root/font-installed"
export VPS_TEST_FONT_READY="$temporary_root/font-ready"
export VPS_TEST_APT_LOG="$temporary_root/apt.log"

# shellcheck source=../../modules/builtin/applications-remote-desktop/module.sh
source "$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"

printf '%s\n' applications.remote-desktop > "$RD_MARKER"
cat > "$RD_STATE_FILE" <<EOF
profile=xfce
user=desktop
browser=firefox
group=vpsrdp
transaction=$test_transaction
owned_packages=xrdp
EOF
chmod 600 "$RD_STATE_FILE"
printf 'xrdp\n' > "$test_transaction/packages.new"

vps_require_root() {
    return 0
}

vps_last_transaction() {
    printf '%s\n' "$test_transaction"
}

rd_apt_unlocked() {
    return 0
}

rd_verify_core() {
    [[ ${VPS_TEST_CORE_HEALTH:-yes} == yes ]]
}

rd_package_present() {
    [[ $1 == "$RD_CJK_FONT_PACKAGE" && -e "$VPS_TEST_FONT_PRESENT" ]]
}

rd_package_installed() {
    [[ $1 == "$RD_CJK_FONT_PACKAGE" && -e "$VPS_TEST_FONT_INSTALLED" ]]
}

vps_apt_update() {
    printf 'update\n' >> "$VPS_TEST_APT_LOG"
}

vps_apt_install() {
    printf 'install:%s\n' "$*" >> "$VPS_TEST_APT_LOG"
    touch "$VPS_TEST_FONT_PRESENT"
    if [[ ${VPS_TEST_APT_RESULT:-success} == success ]]; then
        touch "$VPS_TEST_FONT_INSTALLED" "$VPS_TEST_FONT_READY"
        return 0
    fi
    return 40
}

if rd_cjk_font_ready; then
    fail "Chinese font readiness must reject an absent package"
else
    pass "Chinese font readiness rejects an absent package"
fi
touch "$VPS_TEST_FONT_PRESENT" "$VPS_TEST_FONT_INSTALLED" "$VPS_TEST_FONT_READY"
if rd_cjk_font_ready; then
    pass "Chinese font readiness confirms the installed Noto CJK family"
else
    fail "Chinese font readiness must confirm the installed Noto CJK family"
fi
rm -f -- "$VPS_TEST_FONT_PRESENT" "$VPS_TEST_FONT_INSTALLED" "$VPS_TEST_FONT_READY"

actual=$(rd_repair)
assert_contains "$actual" '没有重装桌面、重启 xrdp 或修改系统语言' \
    "managed beta7 desktops can add Chinese fonts in place"
actual=$(<"$test_transaction/packages.new")
assert_eq $'fonts-noto-cjk\nxrdp' "$actual" \
    "in-place font repair adds the package to the original rollback inventory"
actual=$(rd_state_value owned_packages)
assert_eq 'fonts-noto-cjk,xrdp' "$actual" \
    "in-place font repair refreshes the readable ownership summary"
actual=$(<"$VPS_TEST_APT_LOG")
assert_contains "$actual" 'install:--no-install-recommends fonts-noto-cjk' \
    "font repair installs only the required top-level font package"

: > "$VPS_TEST_APT_LOG"
if actual=$(rd_repair); then
    fail "a repeated font repair should report that no change is required"
else
    result=$?
    assert_eq 10 "$result" "repeated font repair is an idempotent no-op"
fi
assert_contains "$actual" '已经就绪' "repeated font repair explains the no-op"
if [[ -s "$VPS_TEST_APT_LOG" ]]; then
    fail "repeated font repair must not run APT"
else
    pass "repeated font repair does not run APT"
fi

printf 'xrdp\n' > "$test_transaction/packages.new"
awk '!/^owned_packages=/' "$RD_STATE_FILE" > "$RD_STATE_FILE.tmp"
printf 'owned_packages=xrdp\n' >> "$RD_STATE_FILE.tmp"
mv -f "$RD_STATE_FILE.tmp" "$RD_STATE_FILE"
chmod 600 "$RD_STATE_FILE"
touch "$VPS_TEST_FONT_PRESENT" "$VPS_TEST_FONT_INSTALLED" "$VPS_TEST_FONT_READY"
if actual=$(rd_repair); then
    fail "a pre-existing font package should report that no change is required"
else
    result=$?
    assert_eq 10 "$result" "pre-existing Chinese fonts remain externally owned"
fi
actual=$(<"$test_transaction/packages.new")
assert_eq xrdp "$actual" \
    "repair does not take rollback ownership of a pre-existing font package"

rm -f -- "$VPS_TEST_FONT_PRESENT" "$VPS_TEST_FONT_INSTALLED" "$VPS_TEST_FONT_READY"
: > "$VPS_TEST_APT_LOG"
VPS_TEST_CORE_HEALTH=no
export VPS_TEST_CORE_HEALTH
if rd_repair >/dev/null 2>&1; then
    fail "font repair must stop when the managed RDP core is unhealthy"
else
    result=$?
    assert_eq 50 "$result" "font repair fails closed before APT on an unhealthy RDP core"
fi
if [[ -s "$VPS_TEST_APT_LOG" ]]; then
    fail "an unhealthy RDP core must stop before APT"
else
    pass "an unhealthy RDP core stops before APT"
fi
VPS_TEST_CORE_HEALTH=yes

printf 'xrdp\n' > "$test_transaction/packages.new"
VPS_TEST_APT_RESULT=failure
export VPS_TEST_APT_RESULT
if rd_repair >/dev/null 2>&1; then
    fail "a partial font package installation must report failure"
else
    result=$?
    assert_eq 40 "$result" "a partial font package installation remains retryable"
fi
actual=$(<"$test_transaction/packages.new")
assert_eq $'fonts-noto-cjk\nxrdp' "$actual" \
    "a partial install still records the repair package for safe rollback"

finish_tests
