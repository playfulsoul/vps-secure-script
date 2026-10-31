#!/usr/bin/env bash
set -u
# shellcheck disable=SC2034,SC2329
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
export VPS_PLATFORM_ROOT=$PROJECT_ROOT
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# Short socket paths also work on macOS. Production has no path override.
test_root=$(mktemp -d /tmp/vps-session.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
export VPS_REMOTE_DESKTOP_LIB_DIR="$test_root/lib"
# shellcheck source=../../modules/builtin/applications-remote-desktop/module.sh
source "$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"
mkdir -p "$test_root/bin" "$test_root/home" "$test_root/run/user/$UID" "$RD_LIB_DIR"
printf 'synthetic-cookie-fixture\n' > "$test_root/home/.Xauthority"
export VPS_SESSION_FIXTURE_ROOT="$test_root"
cat > "$test_root/bin/stat" <<'MOCK'
#!/usr/bin/env bash
path=${!#}
if [[ ${VPS_FIXTURE_BAD_OWNER:-} == "$path" ]]; then
    printf '%s\n' "$((UID + 1))"
else
    printf '%s\n' "$UID"
fi
MOCK
cat > "$test_root/bin/dbus-send" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$VPS_SESSION_FIXTURE_ROOT/probe.log"
if [[ ${VPS_FIXTURE_DELAY_MANAGER:-0} == 1 && ! -e "$VPS_SESSION_FIXTURE_ROOT/manager-first" ]]; then
    touch "$VPS_SESSION_FIXTURE_ROOT/manager-first"
    printf '   boolean false\n'
    exit "${VPS_FIXTURE_FIRST_EXIT:-0}"
fi
printf '   boolean %s\n' "${VPS_FIXTURE_BUS_REPLY:-true}"
exit "${VPS_FIXTURE_BUS_EXIT:-0}"
MOCK
cat > "$test_root/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "-k 0.2s 0.5s" ]] || exit 99
shift 3
exec "$@"
MOCK
cat > "$test_root/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
printf 'wait\n' >> "$VPS_SESSION_FIXTURE_ROOT/waits.log"
if [[ ${VPS_FIXTURE_DELAY_SOCKET:-0} == 1 && -S "$VPS_SESSION_FIXTURE_ROOT/run/user/$UID/bus.saved" ]]; then
    mv "$VPS_SESSION_FIXTURE_ROOT/run/user/$UID/bus.saved" "$VPS_SESSION_FIXTURE_ROOT/run/user/$UID/bus"
fi
MOCK
cat > "$test_root/bin/desktop" <<'MOCK'
#!/usr/bin/env bash
printf 'ENTRY=%s\nXAUTHORITY=%s\nBUS=%s\n' "${0##*/}" "${XAUTHORITY:-unset}" "${DBUS_SESSION_BUS_ADDRESS:-unset}"
MOCK
for entry in startlxqt startxfce4 mate-session dbus-run-session; do
    cp "$test_root/bin/desktop" "$test_root/bin/$entry"
done
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"
python3 - "$test_root/run/user/$UID/bus" <<'PY' || exit 1
import socket,sys
s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()
PY
runtime="$test_root/run/user/$UID"
auth="$test_root/home/.Xauthority"
run_launcher() {
    HOME="$test_root/home" DBUS_SESSION_BUS_ADDRESS='unix:abstract=old-session' \
        "$test_root/startwm-test"
}
for profile in lxqt xfce mate; do
    RD_PROFILE=$profile
    rd_write_session_script "$test_root/startwm"
    # Only the test copy points at fixtures; the emitted production file is fixed.
    sed "s|/run/user/|$test_root/run/user/|g" "$test_root/startwm" > "$test_root/startwm-test"
    chmod +x "$test_root/startwm-test"
    unset XAUTHORITY VPS_FIXTURE_BAD_OWNER VPS_FIXTURE_BUS_REPLY VPS_FIXTURE_BUS_EXIT
    actual=$(run_launcher)
    assert_contains "$actual" "XAUTHORITY=$auth" "$profile inherits the safe user authority file"
    assert_contains "$actual" "BUS=unix:path=$runtime/bus" "$profile uses the verified user manager bus"
    if [[ "$actual" == *'ENTRY=dbus-run-session'* ]]; then fail "$profile bypasses fallback for healthy user bus"; else pass "$profile starts directly on healthy user bus"; fi
    actual=$(XAUTHORITY=/explicit/authority run_launcher)
    assert_contains "$actual" 'XAUTHORITY=/explicit/authority' "$profile preserves an explicit authority setting"
    actual=$(XAUTHORITY='' run_launcher)
    assert_contains "$actual" "XAUTHORITY=$auth" "$profile fills an empty authority setting"
    actual=$(VPS_FIXTURE_BAD_OWNER="$auth" run_launcher)
    assert_contains "$actual" 'XAUTHORITY=unset' "$profile refuses an authority file owned by another user"
    for path in "$runtime" "$runtime/bus"; do
        : > "$test_root/probe.log"
        actual=$(VPS_FIXTURE_BAD_OWNER="$path" run_launcher)
        assert_eq '' "$(cat "$test_root/probe.log")" "$profile never probes a bus with unsafe ownership"
        assert_contains "$actual" 'ENTRY=dbus-run-session' "$profile rejects wrong ownership: ${path##*/}"
        assert_contains "$actual" 'BUS=unset' "$profile discards the previous abstract bus on fallback"
    done
    rm -f "$test_root/manager-first"
    actual=$(VPS_FIXTURE_DELAY_MANAGER=1 run_launcher)
    assert_contains "$actual" "BUS=unix:path=$runtime/bus" "$profile waits for the user manager to become ready"
    rm -f "$test_root/manager-first"
    actual=$(VPS_FIXTURE_DELAY_MANAGER=1 VPS_FIXTURE_FIRST_EXIT=124 run_launcher)
    assert_contains "$actual" "BUS=unix:path=$runtime/bus" "$profile retries a transient probe timeout"
    mv "$runtime/bus" "$runtime/bus.saved"
    actual=$(VPS_FIXTURE_DELAY_SOCKET=1 run_launcher)
    assert_contains "$actual" "BUS=unix:path=$runtime/bus" "$profile waits for a late user socket"
    : > "$test_root/waits.log"
    actual=$(VPS_FIXTURE_BUS_REPLY=false run_launcher)
    waits=$(wc -l < "$test_root/waits.log" | tr -d ' ')
    if (( waits <= 15 )); then pass "$profile permanently unavailable manager has bounded retries"; else fail "$profile exceeds retry bound"; fi
    assert_contains "$actual" 'ENTRY=dbus-run-session' "$profile rejects a bus without the user systemd manager"
    actual=$(VPS_FIXTURE_BUS_EXIT=124 run_launcher)
    assert_contains "$actual" 'ENTRY=dbus-run-session' "$profile rejects a failed probe even if it printed true"
    mv "$runtime/bus" "$runtime/bus.saved"
    actual=$(run_launcher)
    assert_contains "$actual" 'ENTRY=dbus-run-session' "$profile falls back when the user socket is missing"
    ln -s "$runtime/bus.saved" "$runtime/bus"
    actual=$(run_launcher)
    assert_contains "$actual" 'ENTRY=dbus-run-session' "$profile refuses a symlinked socket"
    rm "$runtime/bus"
    mv "$runtime/bus.saved" "$runtime/bus"
    mv "$runtime" "$runtime.saved"
    ln -s "$runtime.saved" "$runtime"
    actual=$(run_launcher)
    assert_contains "$actual" 'ENTRY=dbus-run-session' "$profile refuses a symlinked runtime directory"
    rm "$runtime"; mv "$runtime.saved" "$runtime"
    mv "$auth" "$auth.saved"
    actual=$(run_launcher)
    assert_contains "$actual" 'XAUTHORITY=unset' "$profile leaves missing authority unset"
    ln -s "$auth.saved" "$auth"
    actual=$(run_launcher)
    assert_contains "$actual" 'XAUTHORITY=unset' "$profile refuses a symlinked authority default"
    rm "$auth"; mv "$auth.saved" "$auth"
    before=$(cksum "$test_root/startwm")
    rd_write_session_script "$test_root/startwm"
    assert_eq "$before" "$(cksum "$test_root/startwm")" "$profile generates deterministic session configuration"
done
assert_contains "$(cat "$test_root/probe.log")" '--dest=org.freedesktop.DBus' 'probe targets the message bus explicitly'
assert_contains "$(cat "$test_root/probe.log")" 'org.freedesktop.DBus.NameHasOwner string:org.freedesktop.systemd1' 'probe checks the user service manager'
# Exercise the real wait clock once, separately from the fast ownership matrix.
mv "$test_root/bin/sleep" "$test_root/bin/sleep.mock"
SECONDS=0
actual=$(VPS_FIXTURE_BUS_REPLY=false run_launcher)
elapsed=$SECONDS
assert_contains "$actual" 'ENTRY=dbus-run-session' 'permanently unavailable manager still starts the fallback session'
if (( elapsed >= 2 && elapsed <= 5 )); then
    pass 'real retry wait stays within the bounded startup budget'
else
    fail "real retry wait is outside the startup budget: $elapsed seconds"
fi
assert_eq 'synthetic-cookie-fixture'  "$(cat "$auth")" 'session setup does not rewrite X authority cookies'
finish_tests
