import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'modules/builtin/applications-reality-node'))
import lifecycle as life
import artifacts


class FakeNode(life.Node):
    def __init__(self, parent):
        self.systemd = parent / 'systemd'
        self.systemd.mkdir()
        super().__init__(parent / 'state', self.systemd / life.SERVICE, parent / 'binaries')
        self.rule_list = ['ufw allow 2222/tcp', "ufw allow 8080/tcp comment 'existing-site'"]
        self.active = False
        self.enabled = False
        self.calls = []
        self.fail_start = 0
        self.fail_write = 0
        self.fail_verify = False
        self.extra_rule_on_start = False

    def command(self, args, **kwargs):
        self.calls.append(args)
        result = b''
        if args[0] == 'ufw':
            if args[1:3] == ['show', 'added']:
                result = ('\n'.join(self.rule_list) + '\n').encode()
            elif '--force' in args:
                self.rule_list.remove(self.rule(int(args[4].split('/')[0])))
            else:
                self.rule_list.append(self.rule(int(args[2].split('/')[0])))
        elif args[0] == 'systemctl':
            command = args[1]
            if command == 'is-active':
                return subprocess.CompletedProcess(args, 0 if self.active else 3, b'active' if self.active else b'inactive', b'')
            if command == 'is-enabled':
                result = b'enabled' if self.enabled else b'disabled'
            elif command == 'enable':
                self.enabled = True
            elif command == 'disable':
                self.enabled = False
            elif command == 'stop':
                self.active = False
            elif command == 'start':
                if self.extra_rule_on_start:
                    self.rule_list.append('ufw allow 9999/tcp')
                    self.extra_rule_on_start = False
                    raise life.NodeError('injected_external_change', 40)
                if self.fail_start:
                    self.fail_start -= 1
                    raise life.NodeError('injected_start_failure', 40)
                self.active = True
        elif args[-1] == 'x25519':
            result = ('PrivateKey: ' + 'A'*43 + '\nPassword (PublicKey): ' + 'A'*43 + '\n').encode()
        return subprocess.CompletedProcess(args, 0, result, b'')

    def firewall_gate(self):
        pass

    def host_gate(self, settings, fresh=False):
        pass

    def config_check(self, config, version):
        json.loads(config)

    def ensure_binary(self, version):
        binary = self.binary(version)
        binary.parent.mkdir(parents=True, exist_ok=True)
        life.atomic(binary, b'fixture-core-' + version.encode(), 0o755)
        life.atomic(binary.with_name('binary.sha256'), life.digest(binary.read_bytes()).encode())
        return binary

    def write_files(self, desired):
        super().write_files(desired)
        if self.fail_write:
            self.fail_write -= 1
            raise life.NodeError('injected_write_failure', 40)

    def verify(self, expected_active=None):
        if self.fail_verify:
            raise life.NodeError('injected_verify_failure', 50)
        self.ownership()
        if expected_active is not None and expected_active != self.active:
            raise life.NodeError('incorrect_active_state', 50)
        if self.installed():
            if self.rule(self.settings()['node_port']) not in self.rule_list:
                raise life.NodeError('missing_rule', 50)
        elif self.active or self.enabled or any(life.RULE_TAG in r for r in self.rule_list):
            raise life.NodeError('incomplete_uninstall', 50)
        return 'verified'


class LifecycleTests(unittest.TestCase):
    def test_pinned_versions_key_field_aliases(self):
        for label in ('Password', 'Password (PublicKey)'):
            private, public = life.parse_core_keys('PrivateKey: ' + 'A'*43 + '\n' + label + ': ' + 'A'*43)
            self.assertEqual(len(private), 43)
            self.assertEqual(len(public), 43)
        with self.assertRaisesRegex(life.NodeError, '^unsupported_core_key_output$'):
            life.parse_core_keys('unexpected: sensitive')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.node = FakeNode(Path(self.temp.name).resolve())
        self.node.initialize()
        self.args = argparse.Namespace(core_version='26.2.6', public_address='8.8.8.8', node_port=24443,
                                       target_host='127.0.0.1', target_port=8443, server_name='target.example')
        for patcher in (patch.object(life, 'check_target', return_value='ok'), patch.object(life.time, 'sleep')):
            patcher.start()
            self.addCleanup(patcher.stop)

    def install(self):
        self.assertEqual(self.node.install(self.args), 0)

    def test_install_repeat_and_permissions(self):
        before = self.node.capture()
        self.install()
        self.assertTrue(self.node.active)
        self.assertEqual(self.node.install(self.args), 10)
        self.assertEqual(self.node.rule_list[:-1], before['rules'])
        for key in ('config', 'settings', 'managed'):
            self.assertEqual(self.node.files[key].stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.node.unit.stat().st_mode & 0o777, 0o644)
        self.assertFalse(self.node.pending.exists())

    def test_install_failure_restores_all_owned_state(self):
        before = self.node.capture()
        self.node.fail_start = 1
        with self.assertRaises(life.NodeError) as caught:
            self.node.install(self.args)
        self.assertEqual(caught.exception.code, 40)
        self.assertEqual(self.node.capture(), before)
        self.assertFalse(self.node.pending.exists())

    def test_partial_file_write_compensated(self):
        before = self.node.capture()
        self.node.fail_write = 1
        with self.assertRaises(life.NodeError) as caught:
            self.node.install(self.args)
        self.assertEqual(caught.exception.code, 40)
        self.assertEqual(self.node.capture(), before)

    def test_failed_recovery_retains_pending_blocks_apply_then_retry(self):
        before = self.node.capture()
        self.node.fail_verify = True
        with self.assertRaises(life.NodeError) as caught:
            self.node.install(self.args)
        self.assertEqual(caught.exception.code, 60)
        self.assertTrue(self.node.pending.exists())
        with self.assertRaisesRegex(life.NodeError, 'pending_recovery'):
            self.node.install(self.args)
        self.node.fail_verify = False
        self.assertEqual(self.node.rollback(), 0)
        self.assertEqual(self.node.capture(), before)
        self.assertEqual(self.node.rollback(), 10)

    def test_upgrade_and_exact_rollback_preserve_credentials(self):
        self.install()
        before = self.node.capture()
        identifier = self.node.settings()['client_id']
        self.assertEqual(self.node.upgrade(artifacts.VERSION), 0)
        self.assertEqual(self.node.settings()['client_id'], identifier)
        self.assertEqual(self.node.settings()['version'], artifacts.VERSION)
        self.assertEqual(self.node.rollback(), 0)
        self.assertEqual(self.node.capture(), before)
        self.assertEqual(self.node.rollback(), 10)

    def test_stop_start_uninstall_and_restore(self):
        self.install()
        self.assertEqual(self.node.change_state('stop'), 0)
        self.assertFalse(self.node.active)
        self.assertFalse(self.node.enabled)
        self.assertEqual(self.node.change_state('start'), 0)
        before = self.node.capture()
        self.assertEqual(self.node.change_state('uninstall'), 0)
        self.assertFalse(self.node.unit.exists())
        self.assertFalse(self.node.installed())
        self.assertEqual(self.node.rule_list, before['rules'][:-1])
        self.assertEqual(self.node.rollback(), 0)
        self.assertEqual(self.node.capture(), before)

    def test_backup_restore_after_upgrade(self):
        self.install()
        before = self.node.capture()
        backup = self.node.backup()
        self.node.upgrade(artifacts.VERSION)
        self.assertEqual(self.node.rollback(backup), 0)
        self.assertEqual(self.node.capture(), before)

    def test_external_file_edits_never_overwritten(self):
        self.install()
        self.node.unit.write_text('external admin edit')
        with self.assertRaisesRegex(life.NodeError, 'another_writer'):
            self.node.change_state('uninstall')
        self.assertEqual(self.node.unit.read_text(), 'external admin edit')

    def test_external_firewall_edits_block_compensation_and_preserve_evidence(self):
        self.node.extra_rule_on_start = True
        with self.assertRaises(life.NodeError) as caught:
            self.node.install(self.args)
        self.assertEqual(caught.exception.code, 60)
        self.assertIn('ufw allow 9999/tcp', self.node.rule_list)
        self.assertTrue(self.node.pending.exists())

    def test_export_uses_public_endpoint_never_loopback_or_private_key(self):
        self.install()
        path = self.node.export_client()
        client = json.loads(path.read_text())
        self.assertEqual(client['outbounds'][0]['settings']['vnext'][0]['address'], self.args.public_address)
        self.assertNotIn('privateKey', path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        before = self.node.capture()
        self.node.change_state('uninstall')
        self.assertFalse(path.exists())
        self.node.rollback()
        self.assertEqual(self.node.capture(), before)

    def test_export_does_not_restart_node(self):
        self.install()
        self.node.calls.clear()
        self.node.export_client()
        self.assertFalse(any(cmd[:2] == ['systemctl', 'stop'] for cmd in self.node.calls))
        self.assertTrue(self.node.active)

    def test_lock_contention_and_symlink_rejected(self):
        with self.node.locked():
            with self.assertRaisesRegex(life.NodeError, 'another_node_operation'):
                with self.node.locked():
                    pass
        self.node.files['config'].symlink_to(self.node.root / 'owner')
        with self.assertRaises(life.NodeError):
            self.node.inventory()

    def test_no_broad_firewall_or_ssh_mutation(self):
        self.install()
        self.node.change_state('uninstall')
        forbidden = ('flush', 'reset', 'iptables', 'iptables-restore', 'sshd', 'ssh.service')
        self.assertFalse(any(any(word in command for word in forbidden) for command in self.node.calls))

    def test_corrupt_cached_binary_refused_before_start(self):
        self.install()
        self.node.change_state('stop')
        self.node.binary(self.args.core_version).write_bytes(b'corrupt')
        with self.assertRaises(life.NodeError):
            self.node.change_state('start')
        self.assertFalse(self.node.active)

    def test_interruption_after_write_restores_baseline(self):
        before = self.node.capture()
        original = self.node.write_files
        calls = []
        def interrupted_write(desired):
            original(desired)
            calls.append(True)
            if len(calls) == 1:
                raise KeyboardInterrupt()
        with patch.object(self.node, 'write_files', side_effect=interrupted_write):
            with self.assertRaises(life.NodeError) as caught:
                self.node.install(self.args)
        self.assertEqual(caught.exception.code, 40)
        self.assertEqual(self.node.capture(), before)

    def test_uninstall_removes_only_owned_export_and_restores_it(self):
        self.install()
        self.node.export_client()
        self.node.files['share'].write_text('external admin edit')
        with self.assertRaisesRegex(life.NodeError, 'another_writer'):
            self.node.change_state('uninstall')
        self.assertEqual(self.node.files['share'].read_text(), 'external admin edit')

    def test_read_only_verify_does_not_download_missing_core(self):
        self.install()
        binary = self.node.binary(self.args.core_version)
        binary.unlink()
        with self.assertRaisesRegex(life.NodeError, 'installed_core_missing'):
            self.node.checked_binary(self.args.core_version)
        self.assertFalse(binary.exists())

    def test_terminal_pending_marker_reconciles_after_power_loss(self):
        self.install()
        pointer = self.node.json_read(self.node.root / 'last.json')
        self.node.rollback()
        self.node.write_json(self.node.pending, pointer)
        self.assertEqual(self.node.rollback(), 10)
        self.assertFalse(self.node.pending.exists())

    def test_terminal_pending_marker_does_not_hide_external_changes(self):
        self.install()
        pointer = self.node.json_read(self.node.root / 'last.json')
        self.node.rollback()
        self.node.write_json(self.node.pending, pointer)
        self.node.rule_list.append('ufw allow 9999/tcp')
        with self.assertRaisesRegex(life.NodeError, 'terminal_recovery_record_state_mismatch'):
            self.node.rollback()
        self.assertTrue(self.node.pending.exists())

    def test_backup_rejects_unrelated_firewall_changes(self):
        self.install()
        backup = self.node.backup()
        self.node.rule_list.append('ufw allow 9999/tcp')
        with self.assertRaisesRegex(life.NodeError, 'unrelated_firewall'):
            self.node.rollback(backup)
