#!/usr/bin/env python3
"""Validate an operator-owned loopback HTTPS target without logging its address."""

import argparse
import ipaddress
import os
import re
import socket
import ssl
import sys


class TargetError(Exception):
    """A safe, non-sensitive validation failure."""


def validate_target(host, port, server_name, node_port):
    # Literal loopback only: never resolve a hostname into an outbound target.
    if host not in ("127.0.0.1", "::1"):
        raise TargetError("target_not_loopback")
    if type(port) is not int or not 1 <= port <= 65535:
        raise TargetError("invalid_target_port")
    if type(node_port) is not int or not 1 <= node_port <= 65535:
        raise TargetError("invalid_node_port")
    if port == node_port:
        raise TargetError("recursive_target")
    if not isinstance(server_name, str) or not 1 <= len(server_name) <= 253:
        raise TargetError("invalid_server_name")
    labels = server_name.split(".")
    if len(labels) < 2 or any(
        not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", label)
        for label in labels
    ):
        raise TargetError("invalid_server_name")
    try:
        ipaddress.ip_address(server_name)
    except ValueError:
        pass
    else:
        raise TargetError("server_name_is_ip")


def check_target(host, port, server_name, node_port):
    validate_target(host, port, server_name, node_port)
    if "SSL_CERT_FILE" in os.environ or "SSL_CERT_DIR" in os.environ:
        raise TargetError("trust_environment_override_rejected")
    # Use platform trust, require hostname verification, and do not accept an
    # operator-supplied CA argument as a substitute for public certificate trust.
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2"])
    try:
        with socket.create_connection((host, port), timeout=5) as connection:
            with context.wrap_socket(connection, server_hostname=server_name) as tls:
                if tls.version() != "TLSv1.3":
                    raise TargetError("target_tls13_required")
                if tls.selected_alpn_protocol() != "h2":
                    raise TargetError("target_h2_required")
                if not tls.getpeercert():
                    raise TargetError("target_certificate_missing")
    except ssl.SSLCertVerificationError:
        raise TargetError("target_certificate_untrusted_expired_or_mismatched") from None
    except (OSError, ssl.SSLError):
        raise TargetError("target_tls_connection_failed") from None
    # This is a TLS prerequisite, not proof of REALITY/client compatibility.
    return "TARGET_TLS_PREREQUISITES=pass; REALITY_CLIENT=not_tested"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--node-port", type=int, required=True)
    args = parser.parse_args()
    # Environment trust overrides must not silently relax production checks.
    try:
        print(check_target(args.host, args.port, args.server_name, args.node_port))
        return 0
    except TargetError as error:
        print("TARGET_CHECK=" + str(error), file=sys.stderr)
        return 30


if __name__ == "__main__":
    sys.exit(main())
