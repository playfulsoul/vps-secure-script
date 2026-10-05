"""Synthetic PTY fixture only; never reads a server's node or modifies host services."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/unit'))
from test_reality_lifecycle import FakeNode
sys.path.insert(0, str(ROOT / 'modules/builtin/applications-reality-node'))
import client_view as view
from client_data import share_uri
import lifecycle as life


def snapshot(root):
    return {str(p.relative_to(root)): (p.stat().st_mode, p.stat().st_mtime_ns,
                                     p.read_bytes() if p.is_file() else None)
            for p in root.rglob('*')}


def main():
    if sys.argv[-1] == 'menu':
        environment = dict(os.environ, FIXTURE_PYTHON=sys.executable, FIXTURE_HELPER=str(Path(__file__).resolve()),
                           FIXTURE_ROOT=str(ROOT))
        script = '''
source "$FIXTURE_ROOT/bin/vps" --version >/dev/null
vps_ui_status_dashboard() { :; }
vps_update_notice() { :; }
vps_module_run() { printf 'UNEXPECTED_MODULE_EXECUTION\n'; return 1; }
python3() { "$FIXTURE_PYTHON" "$FIXTURE_HELPER" "$@"; }
vps_ui_main_menu
'''
        return subprocess.call(['bash', '-c', script], env=environment)
    with tempfile.TemporaryDirectory() as temporary:
        parent = Path(temporary).resolve()
        node = FakeNode(parent)
        args = argparse.Namespace(core_version='26.2.6', public_address='8.8.8.8', node_port=24443,
                                  target_host='127.0.0.1', target_port=8443, server_name='synthetic.example')
        with patch.object(life, 'check_target', return_value='synthetic'), patch.object(life.time, 'sleep'), node.locked():
            node.install(args)
        expected = share_uri(node.settings())
        before = snapshot(parent)
        node.calls.clear()
        encoder = os.environ.get('REALITY_TEST_QRENCODER')
        def local_encoder():
            if encoder:
                return encoder
            raise view.ViewError('二维码工具未安装，仍可查看并复制链接。本次不会自动安装软件。')
        # This bypass is in the synthetic fixture, never in the shipped viewer.
        with patch.object(view, 'require_admin'), patch.object(view, 'Node', return_value=node), \
             patch.object(view, 'find_encoder', side_effect=local_encoder), \
             patch.object(node, 'read_client_uri', wraps=node.read_client_uri) as reader:
            result = view.main([sys.argv[-1]])
        unchanged = before == snapshot(parent) and all(call[:2] == ['systemctl', 'show'] for call in node.calls)
        if not unchanged:
            print('FIXTURE_STATE_CHANGED')
            return 1
        print('FIXTURE_UNCHANGED=yes; READS=' + str(reader.call_count))
        print('FIXTURE_LINK_SHA256=' + hashlib.sha256(expected.encode()).hexdigest())
        return result


if __name__ == '__main__':
    sys.exit(main())
