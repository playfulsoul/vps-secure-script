#!/usr/bin/env python3
"""Offline checks for manual hidden-input agent enrollment."""

import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.manual_join_client import ManualJoinError, install_agent, main, validate_inputs


class ManualJoinTests(unittest.TestCase):
    def test_valid_single_node_inputs(self):
        actual = validate_inputs(
            "https://monitor.example.com",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey monitor",
            "synthetic-node-token",
        )
        self.assertEqual(actual["hub_url"], "https://monitor.example.com")
        self.assertEqual(actual["agent_token"], "synthetic-node-token")

    def test_unsafe_hub_addresses_rejected(self):
        for url in (
            "http://monitor.example.com",
            "https://127.0.0.1",
            "https://monitor.example.com:8443",
            "https://user@monitor.example.com",
            "https://monitor.example.com/path",
            "https://monitor.example.com?key=x",
        ):
            with self.subTest(url=url), self.assertRaises(ManualJoinError):
                validate_inputs(url, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey", "token")

    def test_credentials_are_validated_before_install(self):
        for key, token in (("invalid-key", "token"), ("ssh-ed25519 AAAA", " bad token")):
            with self.subTest(key=key, token=token), self.assertRaises(ManualJoinError):
                validate_inputs("https://monitor.example.com", key, token)

    def test_install_uses_protected_temporary_files_and_no_secret_arguments(self):
        observed = {}

        def fake_run(arguments, *, check):
            self.assertFalse(check)
            self.assertEqual(arguments[:3], ["/isolated/bin/vps", "monitor", "join"])
            self.assertNotIn("synthetic-node-token", arguments)
            self.assertNotIn("synthetic-public-key", arguments)
            key_path = Path(arguments[arguments.index("--key-file") + 1])
            token_path = Path(arguments[arguments.index("--token-file") + 1])
            self.assertEqual(key_path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(key_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(token_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(key_path.read_text(), "synthetic-public-key\n")
            self.assertEqual(token_path.read_text(), "synthetic-node-token\n")
            observed["directory"] = key_path.parent
            return type("Result", (), {"returncode": 0})()

        with patch("scripts.manual_join_client.subprocess.run", side_effect=fake_run):
            result = install_agent(
                {"hub_url": "https://monitor.example.com", "hub_key": "synthetic-public-key",
                 "agent_token": "synthetic-node-token"}, command="/isolated/bin/vps"
            )
        self.assertEqual(result, 0)
        self.assertFalse(observed["directory"].exists())

    def test_noninteractive_session_is_rejected_before_credential_input(self):
        with patch("scripts.manual_join_client.os.geteuid", return_value=0), \
             patch("scripts.manual_join_client.sys.stdin.isatty", return_value=False), \
             patch("scripts.manual_join_client.getpass.getpass") as prompt:
            self.assertEqual(main(), 64)
            prompt.assert_not_called()

    def test_main_uses_own_absolute_entry_not_path(self):
        expected = str(Path(__file__).resolve().parents[2] / "bin" / "vps")
        with patch("scripts.manual_join_client.os.geteuid", return_value=0), \
             patch("scripts.manual_join_client.sys.stdin.isatty", return_value=True), \
             patch("builtins.input", return_value="https://monitor.example.com"), \
             patch("scripts.manual_join_client.getpass.getpass", side_effect=["ssh-ed25519 AAAA", "synthetic-token"]), \
             patch.dict("os.environ", {"PATH": "/incorrect-version/bin"}), \
             patch("scripts.manual_join_client.install_agent", return_value=0) as install:
            self.assertEqual(main(), 0)
            self.assertEqual(install.call_args.kwargs["command"], expected)


if __name__ == "__main__":
    unittest.main()
