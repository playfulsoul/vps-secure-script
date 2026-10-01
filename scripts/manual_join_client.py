#!/usr/bin/env python3
"""Interactive manual Beszel enrollment without credentials in shell history."""

from __future__ import annotations

import getpass
import ipaddress
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit


class ManualJoinError(ValueError):
    pass


def install_agent(credentials: dict[str, str], *, command: str) -> int:
    """Pass credential paths, never their contents, across the process boundary."""
    with tempfile.TemporaryDirectory(prefix="vps-monitor-join-") as directory:
        root = Path(directory)
        os.chmod(root, 0o700)
        for key, name in (("hub_key", "hub-key"), ("agent_token", "hub-token")):
            target = root / name
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(credentials[key] + "\n")
        result = subprocess.run(
            [command, "monitor", "join", "--hub-url", credentials["hub_url"],
             "--key-file", str(root / "hub-key"), "--token-file", str(root / "hub-token"), "--yes"],
            check=False,
        )
        return result.returncode


def validate_inputs(hub_url: str, hub_key: str, agent_token: str) -> dict[str, str]:
    hub_url = hub_url.strip()
    hub_key = hub_key.strip()
    try:
        parsed = urlsplit(hub_url)
        port = parsed.port
    except ValueError as exc:
        raise ManualJoinError("Hub 地址格式无效。") from exc
    host = parsed.hostname or ""
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ManualJoinError("Hub 地址必须使用域名。")
    if (
        parsed.scheme != "https" or port not in (None, 443) or parsed.username
        or parsed.password or parsed.path not in ("", "/") or parsed.query or parsed.fragment
        or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", host)
        or "." not in host
    ):
        raise ManualJoinError("Hub 地址必须是标准 HTTPS 域名根地址。")
    if not re.fullmatch(
        r"(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/=]+(?: [^\r\n]*)?",
        hub_key,
    ):
        raise ManualJoinError("Hub 公钥格式无效。")
    if not agent_token or len(agent_token) > 4096 or re.search(r"\s", agent_token):
        raise ManualJoinError("单节点令牌格式无效。")
    return {"hub_url": hub_url, "hub_key": hub_key, "agent_token": agent_token}


def main() -> int:
    if os.geteuid() != 0:
        print("请在目标 VPS 的 SSH 会话中以 root 权限运行。", file=sys.stderr)
        return 64
    if not sys.stdin.isatty():
        print("请使用目标 VPS 的交互式 SSH 会话；禁止经管道传入凭据。", file=sys.stderr)
        return 64
    command = str(Path(__file__).resolve().parent.parent / "bin" / "vps")
    if not os.path.isfile(command) or not os.access(command, os.X_OK):
        print("目标 VPS 尚未安装 VPS Secure。", file=sys.stderr)
        return 20
    try:
        hub_url = input("Hub HTTPS 地址: ")
        hub_key = getpass.getpass("Hub 公钥（不回显）: ")
        agent_token = getpass.getpass("该节点令牌（不回显）: ")
        credentials = validate_inputs(hub_url, hub_key, agent_token)
        result = install_agent(credentials, command=command)
        if result == 0:
            print("Agent 已安装；请在 Hub 页面核对本节点的最新采样。")
        return result
    except (ManualJoinError, EOFError, KeyboardInterrupt) as exc:
        print(str(exc) or "已取消接入。", file=sys.stderr)
        return 30


if __name__ == "__main__":
    raise SystemExit(main())
