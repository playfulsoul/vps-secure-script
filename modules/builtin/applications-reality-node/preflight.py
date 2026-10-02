#!/usr/bin/env python3
"""Read-only node prerequisites. Does not install or mutate any services."""
import argparse
import ipaddress
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys

# -I ignores caller Python paths; import only files beside the module entry.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from target_check import TargetError, check_target, validate_target

SERVICE = "vps-secure-reality-node.service"
PLATFORM_ENTRY = Path(__file__).resolve().parents[3] / "bin/vps"
COMMAND_ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "LANG": "C"}


class PreflightError(Exception):
    def __init__(self, reason, code=30):
        super().__init__(reason)
        self.code = code


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default errors can echo sensitive arguments supplied by mistake.
        raise PreflightError("invalid_arguments", 64)


def run(arguments):
    try:
        return subprocess.run(arguments, capture_output=True, text=True,
                              timeout=20, env=COMMAND_ENV, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise PreflightError("dependency_execution_failed") from None


def platform_check():
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "amd64"):
        raise PreflightError("unsupported_platform", 20)
    info = platform.freedesktop_os_release()
    if info.get("ID") != "debian" or info.get("VERSION_ID") != "13":
        raise PreflightError("unsupported_platform", 20)
    if any(shutil.which(name, path=COMMAND_ENV["PATH"]) is None for name in ("systemctl", "ufw", "openssl")):
        raise PreflightError("dependencies_missing", 20)


def assert_port_available(port):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("0.0.0.0", port))
    except OSError:
        raise PreflightError("node_port_in_use_or_unavailable") from None


def validate_endpoint(value):
    try:
        address = ipaddress.ip_address(value)
        # First validated node listener is IPv4. IPv6 is not silently advertised.
        if address.version != 4 or not address.is_global:
            raise ValueError()
    except ValueError:
        raise PreflightError("public_ipv4_required") from None


def prerequisites(args):
    validate_target(args.target_host, args.target_port, args.server_name, args.node_port)
    validate_endpoint(args.public_address)
    platform_check()
    if os.geteuid() != 0:
        raise PreflightError("root_required_for_firewall_inspection")
    # Existing installers keep ownership. Never take over their files or units.
    for service in ("xray.service", "x-ui.service", SERVICE):
        result = run(["systemctl", "show", service, "--property=LoadState", "--value"])
        if result.returncode or result.stdout.strip() != "not-found":
            raise PreflightError("existing_node_service_requires_review")
    for path in ("/usr/local/x-ui", "/etc/xray", "/usr/local/etc/xray", "/etc/vps-secure-reality-node"):
        if os.path.lexists(path):
            raise PreflightError("existing_node_configuration_requires_review")
    assert_port_available(args.node_port)
    firewall = run(["ufw", "status"])
    if firewall.returncode or "Status: active" not in firewall.stdout.splitlines():
        raise PreflightError("active_firewall_required")
    # Delegate ownership/runtime-chain checks to the installed platform contract.
    checked = run([str(PLATFORM_ENTRY), "module", "run", "security.firewall", "preflight"])
    if checked.returncode:
        raise PreflightError("firewall_preflight_failed")
    check_target(args.target_host, args.target_port, args.server_name, args.node_port)
    return "PREFLIGHT=pass; TARGET_TLS=pass; FIREWALL=pass; NODE_CLIENT=not_tested"


def main(argv=None):
    try:
        parser = SafeParser(description=__doc__)
        parser.add_argument("action", choices=("check", "plan", "preflight", "status", "doctor"))
        parser.add_argument("--target-host", default="127.0.0.1")
        parser.add_argument("--target-port", type=int)
        parser.add_argument("--server-name")
        parser.add_argument("--node-port", type=int, default=443)
        parser.add_argument("--public-address")
        args = parser.parse_args(argv)
        if args.action == "plan":
            print("只读检查：节点入口冲突、防火墙所有权与运行状态、本机 HTTPS 目标。")
            print("不会申请证书、修改防火墙、安装节点或接管既有面板。")
            return 0
        if args.action == "check":
            platform_check()
            print("PLATFORM=eligible; NODE_CLIENT=not_tested")
            return 0
        if args.action == "status":
            platform_check()
            result = run(["systemctl", "is-active", SERVICE])
            print("NODE_SERVICE=" + ("active" if result.returncode == 0 else "not_active") + "; NODE_CLIENT=not_tested")
            return 0 if result.returncode == 0 else 10
        if None in (args.target_port, args.server_name, args.public_address):
            raise PreflightError("required_target_and_endpoint_arguments_missing", 64)
        print(prerequisites(args))
        return 0
    except TargetError as error:
        print("PREFLIGHT=" + str(error), file=sys.stderr)
        return 30
    except PreflightError as error:
        print("PREFLIGHT=" + str(error), file=sys.stderr)
        return error.code
    except Exception:
        print("PREFLIGHT=unexpected_failure_redacted", file=sys.stderr)
        return 30


if __name__ == "__main__":
    sys.exit(main())
