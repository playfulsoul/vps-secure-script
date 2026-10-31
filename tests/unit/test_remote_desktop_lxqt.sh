#!/usr/bin/env bash
set -u
# shellcheck disable=SC2034,SC2329
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VPS_PLATFORM_ROOT=$PROJECT_ROOT
export VPS_PLATFORM_ROOT
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
temporary_root=$(mktemp -d)
trap 'rm -rf -- "$temporary_root"' EXIT
export VPS_REMOTE_DESKTOP_TEST_MODE=yes
export VPS_REMOTE_DESKTOP_LIB_DIR="$temporary_root/lib"
export VPS_REMOTE_DESKTOP_CONFIG_DIR="$temporary_root/config"
export VPS_STATE_DIR="$temporary_root/state"
# shellcheck source=../../modules/builtin/applications-remote-desktop/module.sh
source "$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"
test_transaction="$(vps_module_state_dir "$MODULE_ID")/transactions/original"
mkdir -p "$test_transaction" "$RD_LIB_DIR" "$RD_CONFIG_DIR" "$temporary_root/bin" "$temporary_root/home/.config/lxqt"
printf 'profile=lxqt\nowned_packages=xrdp\n' > "$RD_STATE_FILE"
printf 'xrdp\n' > "$test_transaction/packages.new"
printf 'external\nxrdp\n' > "$temporary_root/packages"
cat > "$temporary_root/bin/openbox" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$temporary_root/bin/openbox"
cat > "$temporary_root/bin/dbus-send" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$temporary_root/bin/dbus-send"
export PATH="$temporary_root/bin:$PATH"

rd_managed_transaction() { printf '%s\n' "$test_transaction"; }
rd_apt_unlocked() { return 0; }
rd_verify_core() { return 0; }
rd_cjk_font_ready() { return 0; }
rd_package_installed() { grep -Fxq "$1" "$temporary_root/packages"; }
rd_package_present() { rd_package_installed "$1"; }
rd_present_packages() {
    [[ ${inventory_fail:-no} != yes ]] || return 40
    cat "$temporary_root/packages"
}
vps_apt_update() { printf 'update\n' >> "$temporary_root/apt.log"; }
vps_apt_install() {
    printf '%s\n' "$*" >> "$temporary_root/apt.log"
    printf 'external\nlibobrender32v5\nopenbox\nxrdp\n' > "$temporary_root/packages"
    return "${install_result_mock:-0}"
}

actual=$(rd_profile_packages lxqt)
assert_contains "$actual" 'openbox' 'fresh LXQt profile explicitly includes its window manager'
for profile in xfce mate; do
    if [[ $(rd_profile_packages "$profile") == *openbox* ]]; then
        fail "$profile must not acquire the LXQt window manager"
    else
        pass "$profile package selection remains unchanged"
    fi
done
if rd_lxqt_components_ready; then fail 'missing Openbox must be detected'; else pass 'missing Openbox is detected'; fi
if rd_verify >/dev/null 2>&1; then fail 'verify must reject missing LXQt components'; else pass 'verify rejects missing LXQt components'; fi

# Preferences, including a symlinked user config, are never privileged write targets.
printf '[General]\nwindow_manager=custom-wm\n' > "$temporary_root/user-preference"
ln -s "$temporary_root/user-preference" "$temporary_root/home/.config/lxqt/session.conf"
preference_before=$(cksum "$temporary_root/user-preference")
actual=$(HOME="$temporary_root/home" rd_repair_lxqt)
assert_contains "$actual" '注销图形桌面后重新登录' 'repair explains that a new graphical session is needed'
assert_eq "$preference_before" "$(cksum "$temporary_root/user-preference")" 'repair preserves a symlinked user preference without writing home'
assert_eq $'libobrender32v5\nopenbox\nxrdp' "$(cat "$test_transaction/packages.new")" 'repair owns only new packages including dependencies'
assert_contains "$(cat "$temporary_root/apt.log")" '--no-install-recommends openbox' 'repair installs only the missing LXQt top-level component'
if rd_lxqt_components_ready; then pass 'default window manager becomes ready'; else fail 'default window manager must become ready'; fi

# Execute the generated launcher with a mocked session, observing the real environment.
cat > "$temporary_root/bin/dbus-run-session" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$XDG_CONFIG_DIRS"
MOCK
chmod +x "$temporary_root/bin/dbus-run-session"
actual=$(XDG_CONFIG_DIRS=/existing/config "$RD_LIB_DIR/startwm.sh")
assert_eq "/existing/config:$RD_LIB_DIR/xdg" "$actual" 'launcher appends fallback after existing system configuration'
actual=$(unset XDG_CONFIG_DIRS; "$RD_LIB_DIR/startwm.sh")
assert_eq "/etc/xdg:$RD_LIB_DIR/xdg" "$actual" 'launcher preserves the standard XDG search path when unset'
: > "$temporary_root/apt.log"
result=0
rd_repair_lxqt >/dev/null || result=$?
assert_eq 10 "$result" 'repeated LXQt repair is a no-op'
assert_eq '' "$(cat "$temporary_root/apt.log")" 'repeated repair does not call APT'

# A pre-existing Openbox is not claimed; only module-owned defaults are repaired.
printf 'xrdp\n' > "$test_transaction/packages.new"
rm "$RD_LIB_DIR/xdg/lxqt/session.conf"
rd_repair_lxqt >/dev/null
assert_eq xrdp "$(cat "$test_transaction/packages.new")" 'pre-existing Openbox remains externally owned'
printf '[General]\nwindow_manager=\n' > "$temporary_root/user-preference"
rm "$RD_LIB_DIR/xdg/lxqt/session.conf"
rd_repair_lxqt >/dev/null
assert_eq $'[General]\nwindow_manager=' "$(cat "$temporary_root/user-preference")" 'an explicitly empty user value is not silently rewritten'

rm "$RD_LIB_DIR/xdg/lxqt/session.conf"
ln -s "$temporary_root/user-preference" "$RD_LIB_DIR/xdg/lxqt/session.conf"
result=0
rd_repair_lxqt >/dev/null || result=$?
assert_eq 60 "$result" 'repair refuses symlinked privileged fallback destinations'
rm "$RD_LIB_DIR/xdg/lxqt/session.conf"

# An unavailable inventory aborts before APT. Partial installs remain owned.
printf 'external\nxrdp\n' > "$temporary_root/packages"
inventory_fail=yes
result=0
rd_repair_lxqt >/dev/null || result=$?
assert_eq 40 "$result" 'failed pre-install package inventory stops repair'
assert_eq '' "$(cat "$temporary_root/apt.log")" 'failed inventory does not call APT'
inventory_fail=no
install_result_mock=40
result=0
rd_repair_lxqt >/dev/null || result=$?
assert_eq 40 "$result" 'partial package installation reports failure'
assert_contains "$(cat "$test_transaction/packages.new")" 'openbox' 'partial install retains package ownership evidence'

printf 'profile=xfce\n' > "$RD_STATE_FILE"
result=0
rd_repair_lxqt >/dev/null || result=$?
assert_eq 10 "$result" 'non-LXQt repair never adds window-manager configuration'
RD_PROFILE=xfce
rd_write_session_script "$temporary_root/xfce-startwm"
if grep -q 'XDG_CONFIG_DIRS\|openbox' "$temporary_root/xfce-startwm"; then
    fail 'XFCE launcher must not receive LXQt defaults'
else
    pass 'XFCE launcher remains independent of LXQt defaults'
fi
finish_tests
