"""Owned single-node transactions. No firewall table replacement or panel takeover."""
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import ssl
import socket
import stat
import subprocess
import tempfile
import time
import uuid

import artifacts
from client_data import share_uri
from node_config import server_config
import preflight
from target_check import check_target

SERVICE = "vps-secure-reality-node.service"
RULE_TAG = "vps-secure-reality-node"
MAGIC = b"vps-secure-reality-node-v1\n"


class NodeError(Exception):
    def __init__(self, reason, code=30):
        super().__init__(reason)
        self.code = code


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic(path, data, mode=0o600):
    fd, name = tempfile.mkstemp(prefix=".node-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def encoded(data, mode=0o600):
    return {"data": base64.b64encode(data).decode(), "mode": mode}


def durable_unlink(path):
    path.unlink(missing_ok=True)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def parse_core_keys(generated):
    fields = dict(line.split(': ', 1) for line in generated.splitlines() if ': ' in line)
    private = fields.get('PrivateKey')
    public = fields.get('Password (PublicKey)', fields.get('Password'))
    for value in (private, public):
        if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', value):
            raise NodeError('unsupported_core_key_output')
        raw = base64.urlsafe_b64decode(value + '=')
        if len(raw) != 32 or base64.urlsafe_b64encode(raw).decode().rstrip('=') != value:
            raise NodeError('unsupported_core_key_output')
    return private, public


class Node:
    def __init__(self, root=Path('/var/lib/vps-secure-reality-node'),
                 unit=Path('/etc/systemd/system') / SERVICE,
                 binaries=Path('/usr/local/lib/vps-secure-reality-node')):
        self.root, self.unit, self.binaries = Path(root), Path(unit), Path(binaries)
        self.files = {"config": self.root / 'config.json', "settings": self.root / 'settings.json',
                      "unit": self.unit, "managed": self.root / 'managed.json',
                      "export": self.root / 'client-export.json', "share": self.root / 'client-link.txt'}
        self.pending = self.root / 'pending.json'
        self.transactions = self.root / 'transactions'

    def command(self, args, *, allow_failure=False, timeout=30):
        try:
            result = subprocess.run(args, capture_output=True, timeout=timeout, env=preflight.COMMAND_ENV)
        except (OSError, subprocess.TimeoutExpired):
            raise NodeError('command_failed', 40) from None
        if result.returncode and not allow_failure:
            raise NodeError('command_failed', 40)
        return result

    def secure_path(self, path, *, directory=False):
        # Parent path substitution is not allowed, even for a read-only backup.
        for parent in path.parents:
            if parent.is_symlink():
                raise NodeError('symlink_parent_rejected')
        st = path.lstat()
        wanted = stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode)
        if not wanted or st.st_uid != os.geteuid() or st.st_mode & 0o022:
            raise NodeError('untrusted_owned_path')
        return st

    def initialize(self):
        if not self.root.exists() and not self.root.is_symlink():
            self.secure_path(self.root.parent, directory=True)
            self.root.mkdir(mode=0o700)
            atomic(self.root / 'owner', MAGIC)
        self.secure_path(self.root, directory=True)
        if self.root.stat().st_mode & 0o077:
            raise NodeError('state_permissions_too_broad')
        self.secure_path(self.root / 'owner')
        if (self.root / 'owner').read_bytes() != MAGIC:
            raise NodeError('state_ownership_conflict')
        if not self.transactions.exists():
            self.transactions.mkdir(mode=0o700)
        self.secure_path(self.transactions, directory=True)

    @contextlib.contextmanager
    def locked(self):
        self.initialize()
        lock = self.root / 'lock'
        fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(fd).st_uid != os.geteuid() or os.fstat(fd).st_mode & 0o077:
                raise NodeError('unsafe_lock')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise NodeError('another_node_operation_is_running') from None
            yield
        finally:
            os.close(fd)

    def json_read(self, path):
        st = self.secure_path(path)
        if st.st_mode & 0o077 or st.st_size > 2 * 1024 * 1024:
            raise NodeError('unsafe_state_file')
        return json.loads(path.read_bytes())

    def write_json(self, path, value):
        atomic(path, json.dumps(value, sort_keys=True).encode())

    def inventory(self):
        result = {}
        for key, path in self.files.items():
            if not path.exists() and not path.is_symlink():
                result[key] = None
                continue
            st = self.secure_path(path)
            if st.st_size > 1024 * 1024:
                raise NodeError('managed_file_too_large')
            if key != 'unit' and st.st_mode & 0o077:
                raise NodeError('credential_permissions_too_broad')
            result[key] = encoded(path.read_bytes(), stat.S_IMODE(st.st_mode))
        return result

    def installed(self):
        return self.files['managed'].exists()

    def settings(self):
        return self.json_read(self.files['settings'])

    def ownership(self):
        files = self.inventory()
        if files['managed'] is None:
            if any(files.values()):
                raise NodeError('unowned_node_files')
            return
        manifest = self.json_read(self.files['managed'])
        if manifest.get('schema') != 1:
            raise NodeError('unknown_ownership_schema')
        expected = manifest.get('files', {})
        for key in ('config', 'settings', 'unit'):
            if files[key] is None or digest(base64.b64decode(files[key]['data'])) != expected.get(key):
                raise NodeError('managed_file_changed_by_another_writer')
        for key in ('export', 'share'):
            if files[key] is not None:
                if digest(base64.b64decode(files[key]['data'])) != expected.get(key):
                    raise NodeError('client_export_changed_by_another_writer')
            elif key in expected:
                raise NodeError('client_export_removed_by_another_writer')
        dropins = self.command(['systemctl', 'show', SERVICE, '--property=DropInPaths', '--value']).stdout.strip()
        fragment = self.command(['systemctl', 'show', SERVICE, '--property=FragmentPath', '--value']).stdout.strip()
        if dropins or (fragment and fragment.decode() != str(self.unit)):
            raise NodeError('systemd_override_requires_review')

    def rules(self):
        result = self.command(['ufw', 'show', 'added'])
        return [line.strip() for line in result.stdout.decode().splitlines() if line.startswith('ufw ')]

    @staticmethod
    def rule(port):
        return f"ufw allow {port}/tcp comment '{RULE_TAG}'"

    def firewall_gate(self):
        result = self.command([str(preflight.PLATFORM_ENTRY), 'module', 'run', 'security.firewall', 'preflight'], allow_failure=True)
        if result.returncode:
            raise NodeError('firewall_ownership_or_runtime_preflight_failed')
        status = self.command(['ufw', 'status', 'verbose']).stdout.decode()
        if 'Status: active' not in status or 'Default: deny (incoming)' not in status:
            raise NodeError('active_default_deny_firewall_required')
        raw = self.command(['iptables-save']).stdout
        if re.search(rb'(DOCKER|CNI-|KUBE-|LIBVIRT)', raw):
            raise NodeError('complex_container_firewall_requires_review')
        for rule in self.rules():
            if not re.fullmatch(r"ufw (allow|limit|deny|reject) [0-9]+/(tcp|udp)( comment '[A-Za-z0-9 _.:-]+')?", rule):
                raise NodeError('complex_firewall_rule_requires_review')

    def service_state(self):
        active = self.command(['systemctl', 'is-active', SERVICE], allow_failure=True).returncode == 0
        enabled_result = self.command(['systemctl', 'is-enabled', SERVICE], allow_failure=True)
        text = enabled_result.stdout.decode().strip()
        if text not in ('enabled', 'disabled', 'not-found', ''):
            raise NodeError('unexpected_service_enablement')
        return {"active": active, "enabled": text == 'enabled'}

    def capture(self):
        return {"files": self.inventory(), "rules": self.rules(), "service": self.service_state()}

    def binary(self, version):
        if version not in artifacts.RELEASES:
            raise NodeError('core_version_not_pinned')
        return self.binaries / version / 'xray'

    def ensure_binary(self, version):
        binary = self.binary(version)
        if binary.exists() or binary.is_symlink():
            self.secure_path(binary)
            checksum = binary.with_name('binary.sha256')
            self.secure_path(checksum)
            if digest(binary.read_bytes()) != checksum.read_text().strip():
                raise NodeError('installed_core_digest_mismatch')
            return binary
        for directory in (self.binaries, binary.parent):
            if not directory.exists():
                self.secure_path(directory.parent, directory=True)
                directory.mkdir(mode=0o755)
                directory.chmod(0o755)
            self.secure_path(directory, directory=True)
        with tempfile.TemporaryDirectory(prefix='download-', dir=self.root) as temp:
            archive = Path(temp) / 'xray.zip'
            url = f'https://github.com/XTLS/Xray-core/releases/download/v{version}/Xray-linux-64.zip'
            self.command(['curl', '--proto', '=https', '--tlsv1.2', '--fail', '--silent', '--show-error',
                          '--location', '--max-time', '180', '--max-filesize', str(artifacts.MAX_ARCHIVE),
                          '--output', str(archive), url], timeout=190)
            candidate = Path(temp) / 'xray'
            binary_hash = artifacts.unpack_verified(archive, candidate, version)
            # Publish the verified, root-owned executable atomically.
            atomic(binary, candidate.read_bytes(), 0o755)
            atomic(binary.with_name('binary.sha256'), (binary_hash + '\n').encode())
        result = self.command([str(binary), 'version'])
        if version.encode() not in result.stdout:
            raise NodeError('core_version_mismatch')
        return binary

    def checked_binary(self, version):
        binary = self.binary(version)
        if not binary.exists():
            raise NodeError('installed_core_missing', 50)
        self.secure_path(binary)
        checksum = binary.with_name('binary.sha256')
        self.secure_path(checksum)
        if digest(binary.read_bytes()) != checksum.read_text().strip():
            raise NodeError('installed_core_digest_mismatch', 50)
        return binary

    def host_gate(self, settings, fresh=False):
        preflight.platform_check()
        preflight.validate_endpoint(settings['public_address'])
        check_target(settings['target_host'], settings['target_port'], settings['server_name'], settings['node_port'])
        self.firewall_gate()
        if fresh:
            for name in ('xray.service', 'x-ui.service', SERVICE):
                result = self.command(['systemctl', 'show', name, '--property=LoadState', '--value'])
                if result.stdout.strip() != b'not-found':
                    raise NodeError('existing_node_service_requires_review')
            for path in ('/usr/local/x-ui', '/etc/xray', '/usr/local/etc/xray'):
                if os.path.lexists(path):
                    raise NodeError('existing_node_configuration_requires_review')
            preflight.assert_port_available(settings['node_port'])
            for rule in self.rules():
                if RULE_TAG in rule or re.search(r'\b' + str(settings['node_port']) + r'/(tcp|udp)\b', rule):
                    raise NodeError('node_firewall_rule_conflict')

    def unit_bytes(self, version):
        return f'''[Unit]
Description=VPS Secure single REALITY node
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
DynamicUser=yes
User=vps-reality-node
LoadCredential=node.json:{self.files['config']}
ExecStart={self.binary(version)} run -c ${{CREDENTIALS_DIRECTORY}}/node.json
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
KillMode=control-group
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
UMask=0077
LimitNOFILE=65536
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
'''.encode()

    def candidate_files(self, settings, config):
        raw = {'settings': json.dumps(settings, sort_keys=True).encode(),
               'config': json.dumps(config, sort_keys=True).encode(), 'unit': self.unit_bytes(settings['version'])}
        for key in ('export', 'share'):
            if self.installed() and self.files[key].exists():
                raw[key] = self.files[key].read_bytes()
        raw['managed'] = json.dumps({'schema': 1, 'files': {k: digest(v) for k, v in raw.items()}}, sort_keys=True).encode()
        result = {key: None for key in self.files}
        result.update({k: encoded(v, 0o644 if k == 'unit' else 0o600) for k, v in raw.items()})
        return result

    def config_check(self, config, version):
        with tempfile.TemporaryDirectory(prefix='check-', dir=self.root) as temp:
            path = Path(temp) / 'config.json'
            atomic(path, config)
            self.command([str(self.binary(version)), 'run', '-test', '-c', str(path)])

    def verify(self, expected_active=None):
        self.ownership()
        state = self.service_state()
        if not self.installed():
            if state['active'] or state['enabled'] or any(RULE_TAG in line for line in self.rules()):
                raise NodeError('uninstall_verification_failed', 50)
            return 'NODE=not_installed; BACKUPS=retained'
        settings = self.settings()
        if self.rule(settings['node_port']) not in self.rules():
            raise NodeError('managed_firewall_rule_missing', 50)
        if expected_active is not None and state['active'] != expected_active:
            raise NodeError('service_state_verification_failed', 50)
        if not state['active']:
            return 'NODE=stopped; OWNERSHIP=verified; PUBLIC_CLIENT=not_tested'
        self.checked_binary(settings['version'])
        self.config_check(self.files['config'].read_bytes(), settings['version'])
        check_target(settings['target_host'], settings['target_port'], settings['server_name'], settings['node_port'])
        dynamic = self.command(['systemctl', 'show', SERVICE, '--property=DynamicUser', '--value']).stdout.strip()
        pid = self.command(['systemctl', 'show', SERVICE, '--property=MainPID', '--value']).stdout.strip()
        if dynamic != b'yes' or not pid.isdigit() or pid == b'0':
            raise NodeError('unprivileged_service_verification_failed', 50)
        uid_line = next(line for line in Path('/proc/' + pid.decode() + '/status').read_text().splitlines() if line.startswith('Uid:'))
        if int(uid_line.split()[1]) == 0:
            raise NodeError('root_service_rejected', 50)
        # Fixed-target fallback is a separate layer from authenticated client use.
        context = ssl.create_default_context()
        def leaf(port):
            with socket.create_connection(('127.0.0.1', port), timeout=5) as conn:
                with context.wrap_socket(conn, server_hostname=settings['server_name']) as tls:
                    return digest(tls.getpeercert(binary_form=True))
        if settings['target_host'] != '127.0.0.1':
            raise NodeError('ipv4_target_required_for_current_lifecycle')
        if leaf(settings['node_port']) != leaf(settings['target_port']):
            raise NodeError('live_fallback_certificate_mismatch', 50)
        return 'NODE=active; CONFIG=verified; LOCAL_FALLBACK=verified; AUTHENTICATED_PUBLIC_CLIENT=not_tested'

    def write_files(self, desired):
        if set(desired) != set(self.files):
            raise NodeError('transaction_file_set_invalid')
        for key in ('config', 'settings', 'unit', 'export', 'share', 'managed'):
            entry, path = desired[key], self.files[key]
            if entry is None:
                durable_unlink(path)
            else:
                mode = 0o644 if key == 'unit' else 0o600
                if entry['mode'] != mode:
                    raise NodeError('transaction_file_mode_invalid')
                atomic(path, base64.b64decode(entry['data'], validate=True), mode)

    def transition_rules(self, source, destination):
        current = self.rules()
        if current == destination:
            return
        if current != source:
            raise NodeError('firewall_changed_by_another_writer', 60)
        removed = [r for r in source if r not in destination]
        added = [r for r in destination if r not in source]
        if len(removed) > 1 or len(added) > 1:
            raise NodeError('firewall_delta_too_broad', 60)
        for rule, deleting in [(r, True) for r in removed] + [(r, False) for r in added]:
            match = re.fullmatch(r"ufw allow ([0-9]+)/tcp comment '" + RULE_TAG + "'", rule)
            if not match or not 1 <= int(match[1]) <= 65535:
                raise NodeError('unowned_firewall_delta', 60)
            args = ['ufw', '--force', 'delete', 'allow'] if deleting else ['ufw', 'allow']
            self.command(args + [match[1] + '/tcp', 'comment', RULE_TAG])
        if self.rules() != destination:
            raise NodeError('firewall_delta_verification_failed', 60)

    def set_service(self, desired):
        self.command(['systemctl', 'daemon-reload'])
        if self.unit.exists():
            self.command(['systemctl', 'enable' if desired['enabled'] else 'disable', SERVICE])
            self.command(['systemctl', 'start' if desired['active'] else 'stop', SERVICE])
        elif desired['active'] or desired['enabled']:
            raise NodeError('missing_unit_for_service_restore', 60)
        if self.service_state() != desired:
            raise NodeError('service_restore_verification_failed', 60)

    def reconcile(self, record, rollback=False):
        source = record['after'] if rollback else record['before']
        destination = record['before'] if rollback else record['after']
        current_files = self.inventory()
        for key in self.files:
            if current_files[key] not in (record['before']['files'][key], record['after']['files'][key]):
                raise NodeError('managed_files_changed_during_transaction', 60)
        if self.rules() not in (record['before']['rules'], record['after']['rules']):
            raise NodeError('firewall_changed_during_transaction', 60)
        if destination['service']['active']:
            target_settings = json.loads(base64.b64decode(destination['files']['settings']['data']))
            self.checked_binary(target_settings['version'])
            self.config_check(base64.b64decode(destination['files']['config']['data']), target_settings['version'])
            check_target(target_settings['target_host'], target_settings['target_port'],
                         target_settings['server_name'], target_settings['node_port'])
        restart_required = any(source['files'][key] != destination['files'][key] for key in ('config', 'unit')) or source['service'] != destination['service']
        # Stop only our owned unit, before removing its exact firewall rule/files.
        if restart_required and self.unit.exists():
            self.command(['systemctl', 'stop', SERVICE])
            if destination['files']['unit'] is None:
                self.command(['systemctl', 'disable', SERVICE])
        self.transition_rules(source['rules'], destination['rules'])
        self.write_files(destination['files'])
        if restart_required:
            self.set_service(destination['service'])
        self.firewall_gate()
        for attempt in range(20):
            try:
                self.verify(expected_active=destination['service']['active'])
                break
            except (NodeError, OSError, ssl.SSLError):
                if attempt == 19:
                    raise
                time.sleep(.2)

    def execute(self, kind, after):
        if self.pending.exists():
            raise NodeError('pending_recovery_blocks_apply')
        self.ownership()
        identifier = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + secrets.token_hex(4)
        record = {'schema': 1, 'id': identifier, 'kind': kind, 'status': 'pending', 'before': self.capture(), 'after': after}
        record_path = self.transactions / (identifier + '.json')
        self.write_json(record_path, record)
        self.write_json(self.pending, {'id': identifier})
        try:
            self.reconcile(record)
        except BaseException as original_error:
            try:
                self.reconcile(record, rollback=True)
            except BaseException:
                raise NodeError('operation_failed_recovery_incomplete_evidence_retained', 60) from None
            record['status'] = 'compensated'
            self.write_json(record_path, record)
            durable_unlink(self.pending)
            code = 50 if isinstance(original_error, NodeError) and original_error.code == 50 else 40
            raise NodeError('operation_failed_previous_state_restored', code) from None
        record['status'] = 'committed'
        self.write_json(record_path, record)
        self.write_json(self.root / 'last.json', {'id': identifier})
        durable_unlink(self.pending)
        return identifier

    def fresh_settings(self, args):
        return {'schema': 1, 'version': args.core_version, 'public_address': args.public_address,
                'node_port': args.node_port, 'target_host': args.target_host,
                'target_port': args.target_port, 'server_name': args.server_name}

    def install(self, args):
        self.ownership()
        if self.pending.exists():
            raise NodeError('pending_recovery_blocks_apply')
        settings = self.fresh_settings(args)
        if settings['target_host'] != '127.0.0.1':
            raise NodeError('ipv4_loopback_required_for_current_lifecycle')
        if self.installed():
            previous = self.settings()
            public = {key: previous[key] for key in settings}
            if public != settings:
                raise NodeError('existing_node_configuration_differs_use_reviewed_operation')
            self.host_gate(settings)
            self.verify(expected_active=True)
            return 10
        self.host_gate(settings, fresh=True)
        binary = self.ensure_binary(settings['version'])
        generated = self.command([str(binary), 'x25519']).stdout.decode()
        private_key, public_key = parse_core_keys(generated)
        settings.update({'client_id': str(uuid.uuid4()), 'short_id': secrets.token_hex(8), 'public_key': public_key})
        config = server_config(port=settings['node_port'], target_host=settings['target_host'], target_port=settings['target_port'],
                               server_name=settings['server_name'], client_id=settings['client_id'], private_key=private_key, short_id=settings['short_id'])
        files = self.candidate_files(settings, config)
        self.config_check(base64.b64decode(files['config']['data']), settings['version'])
        after = {'files': files, 'rules': self.rules() + [self.rule(settings['node_port'])], 'service': {'active': True, 'enabled': True}}
        self.execute('install', after)
        return 0

    def backup(self):
        self.ownership()
        if self.pending.exists():
            raise NodeError('pending_recovery_blocks_backup')
        if not self.installed():
            raise NodeError('node_not_installed')
        identifier = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + secrets.token_hex(4)
        state = self.capture()
        self.write_json(self.transactions / (identifier + '.json'),
                        {'schema': 1, 'id': identifier, 'kind': 'backup', 'status': 'committed', 'before': state, 'after': state})
        self.write_json(self.root / 'last-backup.json', {'id': identifier})
        return identifier

    def upgrade(self, version):
        self.ownership()
        if self.pending.exists():
            raise NodeError('pending_recovery_blocks_upgrade')
        settings = self.settings()
        self.host_gate(settings)
        if version == settings['version']:
            self.verify()
            return 10
        if version not in artifacts.RELEASES or tuple(map(int, version.split('.'))) < tuple(map(int, settings['version'].split('.'))):
            raise NodeError('upgrade_version_not_pinned_or_is_downgrade')
        self.ensure_binary(version)
        settings['version'] = version
        config = self.json_read(self.files['config'])
        self.config_check(json.dumps(config).encode(), version)
        after = self.capture()
        after['files'] = self.candidate_files(settings, config)
        self.execute('upgrade', after)
        return 0

    def change_state(self, action):
        self.ownership()
        if self.pending.exists():
            raise NodeError('pending_recovery_blocks_change')
        if not self.installed():
            if action == 'uninstall':
                self.verify(expected_active=False)
                return 10
            raise NodeError('node_not_installed')
        settings = self.settings()
        # Uninstall/stop must still work when the external certificate has expired.
        self.firewall_gate()
        if action == 'start':
            self.host_gate(settings)
        after = self.capture()
        if action == 'uninstall':
            own_rule = self.rule(settings['node_port'])
            if after['rules'].count(own_rule) != 1:
                raise NodeError('owned_firewall_rule_missing_or_duplicate')
            after['rules'].remove(own_rule)
            after['files'] = {key: None for key in self.files}
            after['service'] = {'active': False, 'enabled': False}
        else:
            after['service'] = {'active': action == 'start', 'enabled': action == 'start'}
        if after == self.capture():
            return 10
        self.execute(action, after)
        return 0

    def rollback(self, identifier=None):
        pointer = self.pending if self.pending.exists() else self.root / 'last.json'
        if identifier is None:
            if not pointer.exists():
                return 10
            identifier = self.json_read(pointer)['id']
        elif self.pending.exists() and self.json_read(self.pending)['id'] != identifier:
            raise NodeError('pending_transaction_must_be_recovered_first')
        if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}', identifier):
            raise NodeError('invalid_transaction_id', 64)
        path = self.transactions / (identifier + '.json')
        record = self.json_read(path)
        if record.get('schema') != 1 or record.get('id') != identifier:
            raise NodeError('invalid_transaction_record')
        if record['status'] in ('rolled_back', 'compensated'):
            if self.pending.exists():
                if self.capture() != record['before']:
                    raise NodeError('terminal_recovery_record_state_mismatch', 60)
                self.firewall_gate()
                self.verify(expected_active=record['before']['service']['active'])
                durable_unlink(self.pending)
            return 10
        self.firewall_gate()
        if record['kind'] == 'backup':
            self.ownership()
            current = self.capture()
            other_now = [r for r in current['rules'] if RULE_TAG not in r]
            other_then = [r for r in record['before']['rules'] if RULE_TAG not in r]
            if other_now != other_then:
                raise NodeError('unrelated_firewall_changes_block_backup_restore')
            self.execute('restore-backup', record['before'])
            return 0
        if self.capture() == record['before'] and record['status'] == 'committed':
            return 10
        self.write_json(self.pending, {'id': identifier})
        try:
            self.reconcile(record, rollback=True)
        except BaseException:
            raise NodeError('rollback_incomplete_evidence_retained', 60) from None
        record['status'] = 'rolled_back'
        self.write_json(path, record)
        durable_unlink(self.pending)
        return 0

    def read_client_uri(self):
        """Read existing owned settings without initializing state or changing transactions."""
        if not self.root.exists() and not self.root.is_symlink():
            raise NodeError('node_not_installed')
        st = self.secure_path(self.root, directory=True)
        if st.st_mode & 0o077:
            raise NodeError('state_permissions_too_broad')
        self.secure_path(self.root / 'owner')
        if (self.root / 'owner').read_bytes() != MAGIC:
            raise NodeError('state_ownership_conflict')
        lock = self.root / 'lock'
        expected = self.secure_path(lock)
        fd = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            current = os.fstat(fd)
            if ((current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino)
                    or current.st_uid != os.geteuid() or current.st_mode & 0o077):
                raise NodeError('unsafe_lock')
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                raise NodeError('another_node_operation_is_running') from None
            if self.pending.exists():
                raise NodeError('pending_recovery_blocks_export')
            self.ownership()
            if not self.installed():
                raise NodeError('node_not_installed')
            return share_uri(self.settings())
        finally:
            os.close(fd)

    def export_client(self):
        self.ownership()
        if self.pending.exists():
            raise NodeError('pending_recovery_blocks_export')
        settings = self.settings()
        preflight.validate_endpoint(settings['public_address'])
        config = {
            'log': {'loglevel': 'none', 'access': 'none', 'error': 'none'},
            'inbounds': [{'listen': '127.0.0.1', 'port': 10808, 'protocol': 'socks',
                          'settings': {'auth': 'noauth', 'udp': False}}],
            'outbounds': [{'protocol': 'vless', 'settings': {'vnext': [{
                'address': settings['public_address'], 'port': settings['node_port'],
                'users': [{'id': settings['client_id'], 'encryption': 'none', 'flow': 'xtls-rprx-vision'}]}]},
                'streamSettings': {'network': 'raw', 'security': 'reality', 'realitySettings': {
                    'serverName': settings['server_name'], 'fingerprint': 'chrome',
                    'password': settings['public_key'], 'shortId': settings['short_id'], 'spiderX': '/'}}}],
        }
        after = self.capture()
        after['files']['export'] = encoded(json.dumps(config, sort_keys=True).encode())
        uri = share_uri(settings)
        after['files']['share'] = encoded((uri + '\n').encode())
        manifest = {'schema': 1, 'files': {k: digest(base64.b64decode(v['data']))
                    for k, v in after['files'].items() if k != 'managed' and v is not None}}
        after['files']['managed'] = encoded(json.dumps(manifest, sort_keys=True).encode())
        if after != self.capture():
            self.execute('export-client', after)
        return self.files['export']


def interrupted(signum, frame):
    raise NodeError('operation_interrupted', 40)


def install_signal_handlers():
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, interrupted)
