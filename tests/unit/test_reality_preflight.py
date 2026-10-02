import argparse
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'modules/builtin/applications-reality-node'))
import preflight


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.args = argparse.Namespace(target_host='127.0.0.1', target_port=8443,
                                       server_name='target.example', node_port=443,
                                       public_address='8.8.8.8')
        self.calls = []

    def command(self, args):
        self.calls.append(args)
        if args[0] == 'systemctl':
            return subprocess.CompletedProcess(args, 0, 'not-found\n', '')
        if args[0] == 'ufw':
            return subprocess.CompletedProcess(args, 0, 'Status: active\n', '')
        return subprocess.CompletedProcess(args, 0, '', '')

    def checks(self, callback):
        with patch.object(preflight, 'platform_check'), patch.object(preflight.os, 'geteuid', return_value=0), \
             patch.object(preflight.os.path, 'lexists', return_value=False), \
             patch.object(preflight, 'assert_port_available'), patch.object(preflight, 'check_target'), \
             patch.object(preflight, 'run', side_effect=callback):
            return preflight.prerequisites(self.args)

    def test_prerequisites_never_claim_client_acceptance(self):
        result = self.checks(self.command)
        self.assertIn('NODE_CLIENT=not_tested', result)
        self.assertFalse(any('apply' in call or 'restart' in call or 'allow' in call for call in self.calls))

    def test_ownership_failure_blocks(self):
        def command(args):
            if 'preflight' in args:
                return subprocess.CompletedProcess(args, 30, 'private raw output', '')
            return self.command(args)
        with self.assertRaisesRegex(preflight.PreflightError, '^firewall_preflight_failed$'):
            self.checks(command)

    def test_existing_service_never_taken_over(self):
        def command(args):
            return subprocess.CompletedProcess(args, 0, 'loaded\n', '')
        with self.assertRaisesRegex(preflight.PreflightError, 'existing_node_service'):
            self.checks(command)

    def test_bad_public_endpoint(self):
        for address in ('127.0.0.1', '0.0.0.0', '10.0.0.1', '::1', 'name.example'):
            with self.assertRaises(preflight.PreflightError):
                preflight.validate_endpoint(address)

    def test_invalid_arguments_do_not_echo(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            result = preflight.main(['preflight', '--node-port', 'sensitive-value'])
        self.assertEqual(result, 64)
        self.assertNotIn('sensitive-value', output.getvalue())

    def test_occupied_port_has_redacted_error(self):
        with patch.object(preflight.socket, 'socket', side_effect=OSError('private raw error')):
            with self.assertRaisesRegex(preflight.PreflightError, '^node_port_in_use_or_unavailable$'):
                preflight.assert_port_available(443)
