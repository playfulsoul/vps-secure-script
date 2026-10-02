"""Strict single-node configuration generation, with no logs or exported secrets."""
import base64
import ipaddress
import re
import uuid

from target_check import validate_target


class ConfigError(Exception):
    """Redacted configuration rejection."""


def validate_credentials(client_id, private_key, short_id):
    try:
        parsed = uuid.UUID(client_id)
        if str(parsed) != client_id or parsed.version != 4:
            raise ValueError()
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", private_key):
            raise ValueError()
        raw = base64.urlsafe_b64decode(private_key + "=")
        if len(raw) != 32 or base64.urlsafe_b64encode(raw).decode().rstrip("=") != private_key:
            raise ValueError()
        if not re.fullmatch(r"[0-9a-f]{16}", short_id):
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise ConfigError("invalid_credentials") from None


def server_config(*, port, target_host, target_port, server_name, client_id, private_key, short_id,
                  listen="0.0.0.0"):
    validate_target(target_host, target_port, server_name, port)
    validate_credentials(client_id, private_key, short_id)
    if listen not in ("0.0.0.0", "::", "127.0.0.1", "::1"):
        raise ConfigError("invalid_listen")
    address = ipaddress.ip_address(target_host)
    target = f"[{address}]:{target_port}" if address.version == 6 else f"{address}:{target_port}"
    return {
        "log": {"access": "none", "error": "none", "loglevel": "none"},
        "inbounds": [{
            "tag": "managed-reality", "listen": listen, "port": port, "protocol": "vless",
            "settings": {"clients": [{"id": client_id, "flow": "xtls-rprx-vision"}], "decryption": "none"},
            "streamSettings": {
                "network": "raw", "security": "reality",
                "realitySettings": {"show": False, "target": target, "xver": 0,
                                    "serverNames": [server_name], "privateKey": private_key,
                                    "shortIds": [short_id]},
            },
            "sniffing": {"enabled": False},
        }],
        "outbounds": [{"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIP"}},
                      {"tag": "blocked", "protocol": "blackhole"}],
        # Defense in depth, not a substitute for host-level egress isolation.
        "routing": {"domainStrategy": "IPOnDemand", "rules": [{
            "type": "field", "ip": ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
                                      "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
                                      "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
                                      "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"],
            "outboundTag": "blocked",
        }]},
    }
