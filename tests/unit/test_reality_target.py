"""Synthetic target checks: no real domains, accounts or remote connections."""
import importlib.util
from pathlib import Path
import ssl
import unittest
from unittest.mock import MagicMock, patch


MODULE = Path(__file__).resolve().parents[2] / "modules/builtin/applications-reality-node/target_check.py"
spec = importlib.util.spec_from_file_location("target_check", MODULE)
target = importlib.util.module_from_spec(spec)
spec.loader.exec_module(target)


class TargetTests(unittest.TestCase):
    def test_imported_check_rejects_trust_override_before_dial(self):
        for key in ("SSL_CERT_FILE", "SSL_CERT_DIR"):
            with patch.dict(target.os.environ, {key: "/synthetic/ca"}), patch.object(target.socket, "create_connection") as dial:
                with self.assertRaisesRegex(target.TargetError, "trust_environment_override_rejected"):
                    target.check_target("127.0.0.1", 8443, "target.example", 443)
                dial.assert_not_called()

    def test_loopback_literals(self):
        for host in ("127.0.0.1", "::1"):
            target.validate_target(host, 8443, "target.example", 443)

    def test_external_or_ambiguous_target_rejected_before_dial(self):
        with patch.object(target.socket, "create_connection") as dial:
            for host in ("example.com", "localhost", "0.0.0.0", "127.0.0.2", "::", "[::1]", "::ffff:127.0.0.1"):
                with self.subTest(host=host), self.assertRaises(target.TargetError):
                    target.check_target(host, 8443, "target.example", 443)
            dial.assert_not_called()

    def test_recursion_and_bad_ports(self):
        for port, node_port in ((443, 443), (0, 443), (65536, 443), (8443, -1), (True, 443)):
            with self.subTest(port=port), self.assertRaises(target.TargetError):
                target.validate_target("127.0.0.1", port, "target.example", node_port)

    def test_hostname_rejection(self):
        for name in ("", "localhost", "127.0.0.1", "*.example.com", "-a.example", "a..example", "a.example\n", "a.example/", "é.example", "x" * 64 + ".example"):
            with self.subTest(name=name), self.assertRaises(target.TargetError):
                target.validate_target("127.0.0.1", 8443, name, 443)

    def test_valid_tls_reports_only_prerequisites(self):
        context = MagicMock()
        tls = context.wrap_socket.return_value.__enter__.return_value
        tls.version.return_value = "TLSv1.3"
        tls.selected_alpn_protocol.return_value = "h2"
        tls.getpeercert.return_value = {"synthetic": True}
        with patch.object(target.ssl, "create_default_context", return_value=context), patch.object(target.socket, "create_connection"):
            result = target.check_target("127.0.0.1", 8443, "target.example", 443)
        self.assertEqual(context.minimum_version, ssl.TLSVersion.TLSv1_3)
        self.assertIn("REALITY_CLIENT=not_tested", result)
        self.assertNotIn("target.example", result)

    def test_certificate_failure_is_redacted(self):
        with patch.object(target.socket, "create_connection", side_effect=ssl.SSLCertVerificationError("synthetic-sensitive-detail")):
            with self.assertRaises(target.TargetError) as caught:
                target.check_target("127.0.0.1", 8443, "target.example", 443)
        self.assertNotIn("synthetic-sensitive-detail", str(caught.exception))

    def test_no_http2_rejected(self):
        context = MagicMock()
        tls = context.wrap_socket.return_value.__enter__.return_value
        tls.version.return_value = "TLSv1.3"
        tls.selected_alpn_protocol.return_value = None
        with patch.object(target.ssl, "create_default_context", return_value=context), patch.object(target.socket, "create_connection"):
            with self.assertRaisesRegex(target.TargetError, "target_h2_required"):
                target.check_target("127.0.0.1", 8443, "target.example", 443)


if __name__ == "__main__":
    unittest.main()
