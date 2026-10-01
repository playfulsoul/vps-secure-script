#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VERSION=$(<"$PROJECT_ROOT/VERSION")

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

temporary_root=$(mktemp -d)
VPS_INSTALL_ROOT="$temporary_root/lib/vps-secure" \
VPS_BIN_DIR="$temporary_root/bin" \
    "$PROJECT_ROOT/install.sh" >/dev/null

assert_file_exists "$temporary_root/lib/vps-secure/bin/vps" "installer copies the CLI"
assert_file_exists "$temporary_root/lib/vps-secure/modules/builtin/security-firewall/module.conf" \
    "installer copies built-in modules"
assert_file_exists "$temporary_root/lib/vps-secure/modules/builtin/monitoring-beszel-agent/module.conf" \
    "installer includes the central monitoring agent module"
assert_file_exists "$temporary_root/lib/vps-secure/modules/builtin/applications-beszel-hub/module.conf" \
    "installer includes the Hub migration module"
if [[ -e "$temporary_root/lib/vps-secure/scripts/pairing_client.py" ]]; then
    fail "installer must exclude unreleased pairing client"
else
    pass "installer excludes unreleased pairing client"
fi
assert_file_exists "$temporary_root/lib/vps-secure/scripts/manual_join_client.py" \
    "installer includes hidden-input manual enrollment"
if PYTHONDONTWRITEBYTECODE=1 python3 - "$temporary_root/lib/vps-secure" <<'PY'
import importlib.util
import sys
from pathlib import Path
from unittest.mock import patch
root = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("installed_manual", root / "scripts/manual_join_client.py")
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
with patch.object(client.os, "geteuid", return_value=0), \
     patch.object(client.sys.stdin, "isatty", return_value=True), \
     patch("builtins.input", return_value="https://monitor.example.com"), \
     patch.object(client.getpass, "getpass", side_effect=["ssh-ed25519 AAAA", "synthetic-token"]), \
     patch.dict("os.environ", {"PATH": "/incorrect-version/bin"}), \
     patch.object(client, "install_agent", return_value=0) as install:
    assert client.main() == 0
    assert install.call_args.kwargs["command"] == str(root / "bin/vps")
PY
then
    pass "installed enrollment calls its own absolute platform entry regardless of PATH"
else
    fail "installed enrollment selected the wrong platform entry"
fi
assert_file_exists "$temporary_root/lib/vps-secure/scripts/beszel-backup-watchdog.sh" \
    "installer includes the backup health watchdog"
assert_file_exists "$temporary_root/lib/vps-secure/scripts/vps-secure-beszel-backup-watchdog.service" \
    "installer includes the watchdog service unit"
actual=$("$temporary_root/bin/vps" monitor join-prompt 2>&1 || true)
assert_contains "$actual" '目标 VPS' \
    "installed manual enrollment loads and requires the target VPS session"
actual=$("$temporary_root/bin/vps" --version)
assert_contains "$actual" "vps-secure $VERSION (build sha256-" \
    "installed command reports its preserved build identity"
assert_file_exists "$temporary_root/lib/vps-secure/BUILD_ID" \
    "installer preserves the build identity"
assert_file_exists "$temporary_root/lib/vps-secure/BUILD_MANIFEST.sha256" \
    "installer preserves the source manifest behind the build identity"
installed_build=$(<"$temporary_root/lib/vps-secure/BUILD_ID")
assert_contains "$actual" "$installed_build" \
    "installed status matches the identity recorded during installation"

temporary_root=$(cd "$temporary_root" && pwd -P)
VPS_STATE_DIR="$temporary_root/report-state" "$temporary_root/bin/vps" report --output installed.txt >/dev/null
assert_file_exists "$temporary_root/report-state/reports/installed.txt" \
    "installed CLI generates a diagnostic report"
report=$(<"$temporary_root/report-state/reports/installed.txt")
assert_contains "$report" "完整构建身份: $installed_build" \
    "installed report uses the preserved content build identity"

rm -rf "$temporary_root"
finish_tests
