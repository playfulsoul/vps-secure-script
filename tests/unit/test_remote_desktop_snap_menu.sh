#!/usr/bin/env bash
set -u
# shellcheck disable=SC2034,SC2329
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
export VPS_PLATFORM_ROOT=$PROJECT_ROOT
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
temporary_root=$(mktemp -d)
trap 'rm -rf -- "$temporary_root"' EXIT
export VPS_REMOTE_DESKTOP_TEST_MODE=yes
export VPS_REMOTE_DESKTOP_LIB_DIR="$temporary_root/lib"
export VPS_REMOTE_DESKTOP_CONFIG_DIR="$temporary_root/config"
# shellcheck source=../../modules/builtin/applications-remote-desktop/module.sh
source "$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"
mkdir -p "$RD_LIB_DIR" "$RD_CONFIG_DIR" "$temporary_root/bin" "$temporary_root/home"
cat > "$temporary_root/bin/dbus-run-session" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$XDG_DATA_DIRS"
MOCK
chmod +x "$temporary_root/bin/dbus-run-session"
export PATH="$temporary_root/bin:$PATH"

for profile in lxqt xfce mate; do
    RD_PROFILE=$profile
    rd_write_session_script "$RD_LIB_DIR/startwm.sh"
    actual=$(unset XDG_DATA_DIRS; "$RD_LIB_DIR/startwm.sh")
    assert_eq '/usr/local/share:/usr/share:/var/lib/snapd/desktop' "$actual" "$profile uses standard lookup paths when unset"
    actual=$(XDG_DATA_DIRS='' "$RD_LIB_DIR/startwm.sh")
    assert_eq '/usr/local/share:/usr/share:/var/lib/snapd/desktop' "$actual" "$profile uses standard lookup paths when empty"
    actual=$(XDG_DATA_DIRS='/custom/data:/usr/share' "$RD_LIB_DIR/startwm.sh")
    assert_eq '/custom/data:/usr/share:/var/lib/snapd/desktop' "$actual" "$profile preserves custom lookup precedence"
    actual=$(XDG_DATA_DIRS='/var/lib/snapd/desktop:/custom/data' "$RD_LIB_DIR/startwm.sh")
    assert_eq '/var/lib/snapd/desktop:/custom/data' "$actual" "$profile does not duplicate an existing Snap path"
    actual=$(XDG_DATA_DIRS='/var/lib/snapd/desktop-backup:/custom/data' "$RD_LIB_DIR/startwm.sh")
    assert_eq '/var/lib/snapd/desktop-backup:/custom/data:/var/lib/snapd/desktop' "$actual" "$profile checks complete path entries rather than prefixes"
done

rd_is_managed() { return 0; }
rd_managed_transaction() { return "${transaction_result:-0}"; }
# Both component stages report an idempotent no-op: launcher repair must still run.
rd_repair_fonts() { return 10; }
rd_repair_lxqt() { return 10; }
for profile in lxqt xfce mate; do
    printf 'profile=%s\n' "$profile" > "$RD_STATE_FILE"
    RD_PROFILE=$profile
    rd_write_session_script "$RD_LIB_DIR/startwm.sh"
    sed '/# vps-secure-snap-desktop:/,/^esac$/d' "$RD_LIB_DIR/startwm.sh" > "$temporary_root/legacy-startwm"
    cp "$temporary_root/legacy-startwm" "$RD_LIB_DIR/startwm.sh"
    chmod +x "$RD_LIB_DIR/startwm.sh"
    actual=$(HOME="$temporary_root/home" rd_repair)
    assert_contains "$actual" '应用菜单路径已更新' "$profile refreshes the installed launcher even when fonts and WM are ready"
    assert_contains "$actual" '注销图形桌面后重新登录' "$profile explains when the menu change takes effect"
    actual=$(XDG_DATA_DIRS='/custom/data' "$RD_LIB_DIR/startwm.sh")
    assert_eq '/custom/data:/var/lib/snapd/desktop' "$actual" "$profile repaired launcher exports the required path"
    before=$(cksum "$RD_LIB_DIR/startwm.sh")
    result=0
    rd_repair >/dev/null || result=$?
    assert_eq 10 "$result" "$profile repeated repair returns no-op"
    assert_eq "$before" "$(cksum "$RD_LIB_DIR/startwm.sh")" "$profile repeated repair leaves script unchanged"
done
assert_eq '' "$(ls -A "$temporary_root/home")" 'launcher repair writes no user home files'
# Refuse links rather than overwriting a target outside the module directory.
mv "$RD_LIB_DIR/startwm.sh" "$temporary_root/protected-script"
ln -s "$temporary_root/protected-script" "$RD_LIB_DIR/startwm.sh"
before=$(cksum "$temporary_root/protected-script")
result=0
rd_repair_session_launcher >/dev/null || result=$?
assert_eq 60 "$result" 'launcher repair rejects a symlinked destination'
assert_eq "$before" "$(cksum "$temporary_root/protected-script")" 'symlink refusal preserves its target'
rm "$RD_LIB_DIR/startwm.sh"
cp "$temporary_root/legacy-startwm" "$RD_LIB_DIR/startwm.sh"
chmod +x "$RD_LIB_DIR/startwm.sh"
transaction_result=60
before=$(cksum "$RD_LIB_DIR/startwm.sh")
result=0
rd_repair_session_launcher >/dev/null || result=$?
assert_eq 60 "$result" 'launcher refresh requires the original valid transaction'
assert_eq "$before" "$(cksum "$RD_LIB_DIR/startwm.sh")" 'invalid transaction leaves launcher unchanged'
finish_tests
