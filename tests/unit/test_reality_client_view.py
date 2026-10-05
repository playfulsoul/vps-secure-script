import argparse
import contextlib
import fcntl
import hashlib
import io
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import patch
from unittest.mock import Mock
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'modules/builtin/applications-reality-node'))
sys.path.insert(0, str(ROOT / 'tests/unit'))
import client_view as view
import lifecycle as life
from client_data import share_uri
from test_reality_lifecycle import FakeNode


def snapshot(root):
    return {str(p.relative_to(root)): (p.stat().st_mode, p.stat().st_mtime_ns,
                                     p.read_bytes() if p.is_file() else None) for p in root.rglob('*')}


def terminal_run(mode, data, columns=140, rows=90, redirect=None, nested=False, encoder=None):
    """Real local controlling PTY; root permission is mocked only by the synthetic helper."""
    helper = ROOT / 'tests/fixtures/reality_view_session.py'
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        os.environ['TERM'] = 'xterm-256color'
        if encoder:
            os.environ['REALITY_TEST_QRENCODER'] = encoder
        else:
            os.environ.pop('REALITY_TEST_QRENCODER', None)
        if redirect is not None:
            fd = os.open(os.devnull, os.O_RDWR)
            os.dup2(fd, redirect)
            os.close(fd)
        args = [sys.executable, str(helper), mode]
        if nested:
            code = 'import os,pty,sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))'
            args = [sys.executable, '-c', code, *args]
        os.execv(sys.executable, args)
    output = bytearray()
    deadline = time.monotonic() + 35
    sent = False
    status = None
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    part = os.read(master, 65536)
                except OSError:
                    break
                if not part:
                    break
                output.extend(part)
                marker = '请选择: ' if mode == 'menu' else '确认在当前终端显示导入信息？'
                if not sent and marker.encode() in output:
                    os.write(master, data)
                    sent = True
            ended, status_value = os.waitpid(pid, os.WNOHANG)
            if ended:
                status = os.waitstatus_to_exitcode(status_value)
                # Continue draining the PTY until EOF, without waiting for the child again.
                while select.select([master], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                break
        if status is None:
            ended, status_value = os.waitpid(pid, os.WNOHANG)
            while not ended and time.monotonic() < deadline:
                time.sleep(0.01)
                ended, status_value = os.waitpid(pid, os.WNOHANG)
            if not ended:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                raise AssertionError('synthetic terminal did not exit within its bound')
            status = os.waitstatus_to_exitcode(status_value)
    finally:
        os.close(master)
    return status, output.decode('utf-8', errors='replace').replace('\r', '')


class ClientReadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name).resolve()
        self.node = FakeNode(self.parent)
        for patcher in (patch.object(life, 'check_target', return_value='synthetic'), patch.object(life.time, 'sleep')):
            patcher.start()
            self.addCleanup(patcher.stop)
        args = argparse.Namespace(core_version='26.2.6', public_address='8.8.8.8', node_port=24443,
                                  target_host='127.0.0.1', target_port=8443, server_name='synthetic.example')
        with self.node.locked():
            self.node.install(args)

    def test_view_without_export_is_read_only(self):
        before = snapshot(self.parent)
        self.node.calls.clear()
        first = self.node.read_client_uri()
        self.assertTrue(first == self.node.read_client_uri())
        self.assertTrue(before == snapshot(self.parent))
        self.assertFalse(self.node.files['share'].exists())
        self.assertTrue(all(call[:2] == ['systemctl', 'show'] for call in self.node.calls))

    def test_matches_protected_export_and_never_rotates(self):
        self.node.export_client()
        before = snapshot(self.parent)
        self.assertTrue(self.node.read_client_uri() == self.node.files['share'].read_text().strip())
        self.assertTrue(before == snapshot(self.parent))
        self.assertNotIn('privateKey', self.node.read_client_uri())

    def test_formatter_matches_frozen_beta4_export_expression(self):
        settings = self.node.settings()
        # Independent expression from frozen beta.4 (3fe2013), synthetic data only.
        # Do not replace this reference with the shared formatter under test.
        query = urlencode({'encryption': 'none', 'security': 'reality', 'sni': settings['server_name'],
                           'fp': 'chrome', 'pbk': settings['public_key'], 'sid': settings['short_id'],
                           'type': 'tcp', 'flow': 'xtls-rprx-vision'})
        expected = 'vless://' + settings['client_id'] + '@' + settings['public_address'] + ':' + str(settings['node_port']) + '?' + query + '#VPS-Secure'
        self.assertTrue(share_uri(settings) == expected)

    def test_missing_node_does_not_create_state(self):
        with tempfile.TemporaryDirectory() as folder:
            absent = life.Node(Path(folder).resolve() / 'absent')
            with self.assertRaises(life.NodeError):
                absent.read_client_uri()
            self.assertFalse(absent.root.exists())

    def test_pending_and_exclusive_lock_fail_closed(self):
        with self.node.locked():
            with self.assertRaises(life.NodeError):
                self.node.read_client_uri()
        life.atomic(self.node.pending, b'{}')
        before = snapshot(self.parent)
        with self.assertRaises(life.NodeError):
            self.node.read_client_uri()
        self.assertTrue(before == snapshot(self.parent))

    def test_missing_lock_is_not_recreated(self):
        (self.node.root / 'lock').unlink()
        before = snapshot(self.parent)
        with self.assertRaises(FileNotFoundError):
            self.node.read_client_uri()
        self.assertTrue(before == snapshot(self.parent))

    def test_bad_permissions_and_changed_settings_rejected(self):
        settings = self.node.files['settings']
        settings.chmod(0o644)
        with self.assertRaises(life.NodeError):
            self.node.read_client_uri()
        settings.chmod(0o600)
        settings.write_bytes(b'{}')
        with self.assertRaises(life.NodeError):
            self.node.read_client_uri()

    def test_symlink_lock_refused_without_touching_target(self):
        lock = self.node.root / 'lock'
        lock.unlink()
        target = self.parent / 'unrelated'
        target.write_bytes(b'unrelated')
        lock.symlink_to(target)
        with self.assertRaises(life.NodeError):
            self.node.read_client_uri()
        self.assertEqual(target.read_bytes(), b'unrelated')

    def test_formatter_rejects_terminal_control_input(self):
        settings = self.node.settings()
        for key in ('server_name', 'public_address', 'public_key', 'short_id', 'client_id'):
            with self.assertRaises(Exception):
                share_uri(dict(settings, **{key: '\x1b[2J'}))


class ViewerTests(unittest.TestCase):
    def test_real_foreground_pty_link_and_read_only(self):
        result, text = terminal_run('link', b'y\n\n')
        self.assertEqual(result, 0)
        self.assertTrue('vless://' in text)
        self.assertTrue(text.index('等同密码') < text.index('vless://'))
        self.assertIn('未自动复制到剪贴板', text)
        self.assertIn('FIXTURE_UNCHANGED=yes; READS=1', text)

    def test_nested_pty_like_sudo_use_pty(self):
        result, text = terminal_run('link', b'y\n\n', nested=True)
        self.assertEqual(result, 0)
        self.assertTrue('vless://' in text)
        self.assertIn('FIXTURE_UNCHANGED=yes; READS=1', text)

    def test_real_menu_discovery_to_copy(self):
        result, text = terminal_run('menu', b'4\n4\n1\ny\n\n0\n0\n0\n')
        self.assertEqual(result, 0)
        self.assertGreaterEqual(text.count('REALITY 节点 · Docker'), 2)
        self.assertIn('1. 显示可复制导入链接', text)
        self.assertTrue('vless://' in text)
        self.assertNotIn('UNEXPECTED_MODULE_EXECUTION', text)
        self.assertIn('FIXTURE_UNCHANGED=yes; READS=1', text)

    def test_cancel_blank_eof_do_not_read(self):
        for answer in (b'n\n', b'\n', b'\x04', b'y\x04\x04'):
            with self.subTest(answer=repr(answer)):
                result, text = terminal_run('link', answer)
                self.assertEqual(result, 90)
                self.assertFalse('vless://' in text)
                self.assertIn('READS=0', text)

    def test_each_redirect_rejected(self):
        for redirected in (0, 1, 2):
            with self.subTest(fd=redirected):
                result, text = terminal_run('link', b'y\n', redirect=redirected)
                self.assertEqual(result, 30)
                self.assertFalse('vless://' in text)
                if redirected != 1:
                    self.assertIn('READS=0', text)

    def test_non_tty_and_non_root(self):
        with patch.object(view, 'require_admin'), patch.object(view.os, 'isatty', return_value=False), \
             patch.object(view, 'Node') as node, contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(view.main(['link']), 30)
            node.assert_not_called()
            self.assertIn('不要使用管道或重定向', errors.getvalue())
        with patch.object(view.os, 'geteuid', return_value=1000), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(view.main(['link']), 30)

    def test_missing_encoder_offers_choice_not_auto_display(self):
        result, text = terminal_run('qr', b'y\n\n')
        self.assertEqual(result, 90)
        self.assertIn('二维码工具未安装，仍可查看并复制链接', text)
        self.assertFalse('vless://' in text)
        result, text = terminal_run('qr', b'y\nl\n\n')
        self.assertEqual(result, 0)
        self.assertTrue('vless://' in text)

    def test_safe_encoder_input_and_failures(self):
        sentinel = 'synthetic-input-not-a-node'
        result = subprocess.CompletedProcess([], 1, b'', b'')
        with patch.object(view, 'find_encoder', return_value='/test/qrencode'), \
             patch.object(view.subprocess, 'run', return_value=result) as run:
            with self.assertRaises(view.ViewError):
                view.qr_matrix(sentinel)
            self.assertNotIn(sentinel, run.call_args.args[0])
            self.assertEqual(run.call_args.kwargs['input'], sentinel.encode())
            self.assertEqual(run.call_args.kwargs['stderr'], subprocess.DEVNULL)
        with patch.object(view, 'find_encoder', side_effect=AssertionError('should not spawn')):
            with self.assertRaises(view.ViewError):
                view.qr_matrix('x' * 2049)

    def test_bad_render_size_and_human_errors(self):
        matrix = [[False] * 29 for _ in range(29)]
        with self.assertRaisesRegex(view.ViewError, '窗口不足'):
            view.qr_frame(matrix, os.terminal_size((10, 10)))
        for reason in ('node_not_installed', 'another_node_operation_is_running',
                       'pending_recovery_blocks_export', 'unknown-sensitive-value'):
            message = view.friendly_node_error(life.NodeError(reason))
            self.assertFalse(reason in message)
            self.assertTrue(len(message) > 10)

    def test_encoding_and_render_failure_allow_return_or_copy(self):
        for replies, expected in ((['y', ''], False), (['y', 'l', ''], True)):
            terminal = Mock()
            terminal.line.side_effect = replies
            node = Mock()
            node.read_client_uri.return_value = 'synthetic-sensitive-value'
            with patch.object(view, 'Node', return_value=node), \
                 patch.object(view, 'qr_matrix', side_effect=view.ViewError('二维码生成失败，请改用链接。')):
                self.assertEqual(view.show(terminal, 'qr'), 0 if expected else 90)
            output = ''.join(call.args[0] for call in terminal.write.call_args_list)
            self.assertEqual('synthetic-sensitive-value' in output, expected)
            self.assertIn('直接回车返回', output)

    def test_missing_node_data_is_human_readable_and_redacted(self):
        for failure in (life.NodeError('node_not_installed'), FileNotFoundError('synthetic-secret'),
                        life.NodeError('synthetic-secret')):
            terminal = Mock()
            terminal.line.return_value = 'y'
            node = Mock()
            node.read_client_uri.side_effect = failure
            with patch.object(view, 'require_admin'), patch.object(view, 'Terminal') as kind, \
                 patch.object(view, 'Node', return_value=node), contextlib.redirect_stderr(io.StringIO()) as errors:
                kind.return_value.__enter__.return_value = terminal
                self.assertNotEqual(view.main(['link']), 0)
            self.assertNotIn('synthetic-secret', errors.getvalue())
            self.assertIn('节点', errors.getvalue())

    def test_displayed_qr_allows_explicit_copy_fallback(self):
        for replies, expected in ((['y', ''], False), (['y', 'l', ''], True)):
            terminal = Mock()
            terminal.line.side_effect = replies
            node = Mock()
            node.read_client_uri.return_value = 'synthetic-sensitive-value'
            with patch.object(view, 'Node', return_value=node), \
                 patch.object(view, 'qr_matrix', return_value=[]), \
                 patch.object(view, 'qr_frame', return_value='synthetic-qr-frame'):
                self.assertEqual(view.show(terminal, 'qr'), 0)
            output = ''.join(call.args[0] for call in terminal.write.call_args_list)
            self.assertEqual('synthetic-sensitive-value' in output, expected)
            self.assertIn('字体或行距可能影响扫码', output)

    def test_default_cli_export_remains_redacted(self):
        import module
        node = Mock()
        node.locked.side_effect = contextlib.nullcontext
        with patch.object(module.preflight, 'platform_check'), patch.object(module.os, 'geteuid', return_value=0), \
             patch.object(module, 'Node', return_value=node), patch.object(module, 'install_signal_handlers'), \
             patch.object(module.os, 'umask'), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(module.main(['configure', '--export-client']), 0)
        node.export_client.assert_called_once()
        node.read_client_uri.assert_not_called()
        self.assertNotIn('vless://', output.getvalue())
        self.assertIn('SECRET_VALUES=not_printed', output.getvalue())

    @unittest.skipUnless(os.environ.get('REALITY_TEST_QRENCODER'), 'optional real encoder/decoder integration')
    def test_real_encoder_terminal_frame_independent_decode(self):
        import zxingcpp
        from PIL import Image
        tool = os.environ['REALITY_TEST_QRENCODER']
        result, text = terminal_run('menu', b'4\n4\n2\ny\n\n0\n0\n0\n', encoder=tool)
        self.assertEqual(result, 0)
        self.assertFalse('vless://' in text)
        self.assertNotIn('UNEXPECTED_MODULE_EXECUTION', text)
        self.assertIn('FIXTURE_UNCHANGED=yes; READS=1', text)
        frame = text.split('\x1b[30;47m', 1)[1].split('\x1b[0m', 1)[0].splitlines()
        # Rasterize the actual emitted terminal half-block cells, not the encoder's source matrix.
        pixels = []
        for line in frame:
            pixels.extend([[0 if cell in ('▀', '█') else 255 for cell in line],
                           [0 if cell in ('▄', '█') else 255 for cell in line]])
        image = Image.new('L', (len(frame[0]), len(pixels)), 255)
        image.putdata([pixel for row in pixels for pixel in row])
        for scale in (3, 5, 8):
            decoded = zxingcpp.read_barcode(image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST))
            self.assertIsNotNone(decoded)
            expected = re.search(r'FIXTURE_LINK_SHA256=([a-f0-9]{64})', text).group(1)
            self.assertEqual(hashlib.sha256(decoded.bytes).hexdigest(), expected)
        result, text = terminal_run('qr', b'y\nl\n\n', columns=40, rows=20, encoder=tool)
        self.assertEqual(result, 0)
        self.assertIn('窗口不足', text)
        self.assertNotIn('\x1b[30;47m', text)
        self.assertTrue('vless://' in text)
        # A maximal-length valid domain must remain byte-exact without truncation.
        settings = dict(public_address='8.8.8.8', node_port=24443, target_host='127.0.0.1',
                        target_port=8443, server_name='.'.join(['a' * 63] * 3 + ['b' * 61]),
                        client_id='00000000-0000-4000-8000-000000000001', public_key='A' * 43,
                        short_id='0011223344556677')
        uri = share_uri(settings)
        with patch.object(view, 'find_encoder', return_value=tool):
            matrix = view.qr_matrix(uri)
        image = Image.new('L', (len(matrix), len(matrix)), 255)
        image.putdata([0 if cell else 255 for row in matrix for cell in row])
        decoded = zxingcpp.read_barcode(image.resize((image.width * 5, image.height * 5), Image.Resampling.NEAREST))
        self.assertIsNotNone(decoded)
        self.assertTrue(decoded.bytes == uri.encode())
        with self.assertRaises(view.ViewError):
            view.qr_frame(matrix, os.terminal_size((len(matrix) + 1, 100)))


if __name__ == '__main__':
    unittest.main()
