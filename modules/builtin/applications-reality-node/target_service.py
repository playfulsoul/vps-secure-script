#!/usr/bin/env python3
"""Owned loopback HTTPS prerequisite. No panel takeover or secret output."""
import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from target_check import check_target, validate_target

SERVICE = 'vps-secure-reality-target.service'
RENEW = 'vps-secure-reality-renew.service'
TIMER = 'vps-secure-reality-renew.timer'
TAG = 'vps-secure-reality-acme'
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C', 'LC_ALL': 'C'}
MAGIC = b'vps-secure-reality-target-v1\n'


class Error(Exception):
    def __init__(self, reason, code=30):
        super().__init__(reason)
        self.code = code


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sync_parent(path):
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, data, mode=0o600):
    fd, name = tempfile.mkstemp(prefix='.target-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            os.fchmod(out.fileno(), mode)
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
        sync_parent(path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def unlink(path):
    path.unlink(missing_ok=True)
    sync_parent(path)


def secure(path, directory=False, private=False):
    for item in [path] + list(path.parents):
        if item.is_symlink():
            raise Error('symlink_owned_path_rejected')
        st = item.stat()
        if st.st_uid != os.geteuid() or st.st_mode & 0o022:
            # /tmp-like roots are allowed only for offline test subclasses.
            raise Error('untrusted_owned_path')
    st = path.stat()
    if not (stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode)):
        raise Error('unexpected_owned_path_type')
    if private and st.st_mode & 0o077:
        raise Error('private_permissions_required')


def pack(data, mode=0o600):
    return {'data': base64.b64encode(data).decode(), 'mode': mode}


class Target:
    def __init__(self):
        self.root = Path('/var/lib/vps-secure-reality-target')
        self.config = Path('/etc/vps-secure-reality-target')
        self.runtime = Path('/usr/local/lib/vps-secure-reality-target')
        self.units = Path('/etc/systemd/system')
        self.webroot = Path('/var/www/vps-secure-reality-target')
        self.files = {'settings': self.config/'settings.json', 'nginx': self.config/'nginx.conf',
                      'unit': self.units/SERVICE, 'renew': self.units/RENEW, 'timer': self.units/TIMER}
        self.pending = self.root/'pending.json'
        self.fw_pending = self.root/'firewall-pending.json'
        self.transactions = self.root/'transactions'

    def command(self, args, check=True, timeout=60, input=None):
        try:
            result = subprocess.run(args, input=input, capture_output=True, timeout=timeout, env=ENV)
        except (OSError, subprocess.TimeoutExpired):
            raise Error('command_execution_failed', 40) from None
        if check and result.returncode:
            raise Error('command_failed_redacted', 40)
        return result

    def write(self, path, value):
        atomic(path, json.dumps(value, sort_keys=True).encode())

    def read(self, path):
        secure(path, private=True)
        if path.stat().st_size > 4*1024*1024:
            raise Error('state_too_large')
        return json.loads(path.read_bytes())

    def initialize(self):
        for path in (self.root, self.config, self.runtime):
            if not path.exists():
                secure(path.parent, directory=True)
                path.mkdir(mode=0o700)
            secure(path, directory=True, private=True)
        marker = self.root/'owner'
        if not marker.exists():
            if any(self.files[k].exists() for k in self.files):
                raise Error('unowned_target_files')
            atomic(marker, MAGIC)
        secure(marker, private=True)
        if marker.read_bytes() != MAGIC:
            raise Error('target_ownership_conflict')
        for name in ('transactions', 'generations', 'acme', 'acme-work', 'acme-logs', 'staging', 'staging-work', 'staging-logs'):
            path = self.root/name
            path.mkdir(mode=0o700, exist_ok=True)
            secure(path, directory=True, private=True)

    @contextlib.contextmanager
    def locked(self):
        self.initialize()
        fd = os.open(self.root/'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(fd).st_uid != os.geteuid() or os.fstat(fd).st_mode & 0o077:
                raise Error('unsafe_lock')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Error('another_target_operation_running') from None
            yield
        finally:
            os.close(fd)

    def platform_gate(self):
        if os.geteuid() != 0:
            raise Error('root_required')
        info = platform.freedesktop_os_release()
        if info.get('ID') != 'debian' or info.get('VERSION_ID') != '13' or platform.machine() not in ('x86_64', 'amd64'):
            raise Error('unsupported_platform', 20)
        for program in ('nginx', 'certbot', 'openssl', 'systemctl', 'ufw'):
            if not shutil.which(program, path=ENV['PATH']):
                raise Error('run_dependencies_first', 20)

    def entry(self, settings=None):
        if settings is not None:
            path = Path(settings['platform_entry'])
        else:
            path = Path(__file__).resolve().parents[3]/'bin/vps'
        secure(path)
        return path

    def firewall_preflight(self, settings=None):
        self.command([str(self.entry(settings)), 'module', 'run', 'security.firewall', 'preflight'])
        status = self.command(['ufw', 'status', 'verbose']).stdout
        if b'Status: active' not in status or b'Default: deny (incoming)' not in status:
            raise Error('active_default_deny_firewall_required')
        if re.search(rb'(DOCKER|CNI-|KUBE-|LIBVIRT)', self.command(['iptables-save']).stdout):
            raise Error('complex_firewall_requires_review')
        for rule in self.rules():
            if not re.fullmatch(r"ufw (allow|limit|deny|reject) [0-9]+/(tcp|udp)( comment '[A-Za-z0-9 _.:-]+')?", rule):
                raise Error('complex_firewall_requires_review')

    def rules(self):
        return [s.strip() for s in self.command(['ufw', 'show', 'added']).stdout.decode().splitlines() if s.startswith('ufw ')]

    @staticmethod
    def http_rule():
        return "ufw allow 80/tcp comment '"+TAG+"'"

    def firewall_change(self, desired, settings):
        self.firewall_preflight(settings)
        if self.fw_pending.exists():
            raise Error('pending_firewall_recovery', 60)
        before = self.rules()
        after = [r for r in before if r != self.http_rule()]
        if desired:
            after.append(self.http_rule())
        if before == after:
            return
        record = {'before': before, 'after': after, 'settings': settings}
        self.write(self.root/'firewall-backup.json', record)
        self.write(self.fw_pending, record)
        try:
            self.firewall_reconcile(record, after)
        except BaseException:
            try:
                self.firewall_reconcile(record, before)
                unlink(self.fw_pending)
            except BaseException:
                raise Error('firewall_recovery_incomplete', 60) from None
            raise Error('firewall_apply_failed_restored', 40) from None
        unlink(self.fw_pending)

    def firewall_reconcile(self, record, desired):
        current = self.rules()
        if current not in (record['before'], record['after']):
            raise Error('unrelated_firewall_change_blocks_recovery', 60)
        if current != desired:
            if (set(current) ^ set(desired)) != {self.http_rule()}:
                raise Error('unowned_firewall_delta', 60)
            args = ['ufw', 'allow'] if self.http_rule() in desired else ['ufw', '--force', 'delete', 'allow']
            self.command(args+['80/tcp', 'comment', TAG])
        if self.rules() != desired:
            raise Error('firewall_verify_failed', 60)
        self.firewall_preflight(record['settings'])

    def service_state(self):
        result = {}
        for name in (SERVICE, TIMER):
            enabled = self.command(['systemctl', 'is-enabled', name], check=False).stdout.strip()
            if enabled not in (b'enabled', b'disabled', b'not-found', b''):
                raise Error('unexpected_enablement')
            result[name] = {'active': self.command(['systemctl','is-active',name],check=False).returncode == 0,
                            'enabled': enabled == b'enabled'}
        return result

    def capture(self):
        files = {}
        for key, path in self.files.items():
            if not path.exists() and not path.is_symlink():
                files[key] = None
            else:
                secure(path, private=key in ('settings', 'nginx'))
                files[key] = pack(path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
        return {'files': files, 'services': self.service_state()}

    def ownership(self):
        current = self.capture()
        marker = self.root/'managed.json'
        if marker.exists():
            expected = self.read(marker)
            if current['files'] != expected['files']:
                raise Error('managed_target_changed_by_another_writer')
        elif any(current['files'].values()):
            raise Error('unowned_target_files')
        for name in (SERVICE, RENEW, TIMER):
            result = self.command(['systemctl','show',name,'--property=DropInPaths','--value']).stdout.strip()
            fragment = self.command(['systemctl','show',name,'--property=FragmentPath','--value']).stdout.strip()
            if result or (fragment and fragment.decode() != str(self.units/name)):
                raise Error('service_override_requires_review')

    def settings(self):
        return self.read(self.files['settings'])

    def clean(self):
        if any(path.exists() for path in (self.pending,self.fw_pending,self.root/'operation.json',self.root/'dependencies-pending.json',self.root/'runtime-pending.json')):
            raise Error('pending_recovery_requires_rollback', 60)
        self.ownership()

    def validate_settings(self, args):
        validate_target('127.0.0.1', args.target_port, args.server_name, 80)
        if args.existing_lineage is None and args.external_renewal:
            raise Error('existing_lineage_required')
        if args.existing_lineage is not None and not args.external_renewal:
            raise Error('external_renewal_acknowledgement_required')
        source = None
        if args.existing_lineage:
            source = str(Path(args.existing_lineage))
            if not Path(source).is_absolute():
                raise Error('absolute_lineage_required')
            self.certificate(Path(source), args.server_name)
        return {'schema': 1, 'server_name': args.server_name, 'target_port': args.target_port,
                'external_lineage': source, 'generation': None, 'platform_entry': str(self.entry()),
                'renewal_enabled': False}

    def preflight(self, args):
        self.platform_gate()
        settings = self.validate_settings(args)
        self.firewall_preflight(settings)
        if self.files['settings'].exists():
            self.clean()
            current = self.settings()
            if any(current[k] != settings[k] for k in ('server_name','target_port','external_lineage','platform_entry')):
                raise Error('existing_settings_differ')
            return current
        for path in self.files.values():
            if path.exists() or path.is_symlink():
                raise Error('existing_target_requires_review')
        for name in (SERVICE, RENEW, TIMER):
            if self.command(['systemctl','show',name,'--property=LoadState','--value']).stdout.strip() != b'not-found':
                raise Error('existing_target_unit_requires_review')
        ports = [settings['target_port']] + ([] if settings['external_lineage'] else [80])
        for port in ports:
            try:
                with socket.socket() as listener:
                    listener.bind(('0.0.0.0', port))
            except OSError:
                raise Error('required_port_occupied') from None
        if not settings['external_lineage'] and any(re.search(r'\b80/(tcp|udp)\b', r) or TAG in r for r in self.rules()):
            raise Error('http_firewall_rule_requires_review')
        return settings

    def certificate(self, lineage, name):
        secure(lineage, directory=True)
        data = {}
        for item in ('cert.pem','chain.pem','fullchain.pem','privkey.pem'):
            resolved = (lineage/item).resolve(strict=True)
            secure(resolved, private=item == 'privkey.pem')
            if resolved.stat().st_size > 1024*1024:
                raise Error('certificate_file_too_large')
            data[item] = resolved.read_bytes()
        # Validate the exact bytes to be deployed, never reopen a changing lineage.
        with tempfile.TemporaryDirectory(prefix='certcheck-', dir=self.root if self.root.exists() else None) as temp:
            folder = Path(temp)
            for item, content in data.items():
                atomic(folder/item, content)
            self.command(['openssl','x509','-in',str(folder/'cert.pem'),'-noout','-checkend','86400'])
            self.command(['openssl','verify','-CAfile','/etc/ssl/certs/ca-certificates.crt','-verify_hostname',name,
                          '-untrusted',str(folder/'chain.pem'),str(folder/'cert.pem')])
            pub = self.command(['openssl','x509','-in',str(folder/'cert.pem'),'-pubkey','-noout']).stdout
            key = self.command(['openssl','pkey','-in',str(folder/'privkey.pem'),'-pubout']).stdout
            if pub != key:
                raise Error('certificate_key_mismatch')
            leaf = self.command(['openssl','x509','-in',str(folder/'cert.pem'),'-outform','DER']).stdout
            fullleaf = self.command(['openssl','x509','-in',str(folder/'fullchain.pem'),'-outform','DER']).stdout
            if leaf != fullleaf or data['fullchain.pem'].strip() != (data['cert.pem'].rstrip()+b'\n'+data['chain.pem'].lstrip()).strip():
                raise Error('fullchain_mismatch')
        return data, sha(leaf)

    def generation(self, source, name):
        data, fingerprint = self.certificate(source, name)
        folder = self.root/'generations'/fingerprint
        if not folder.exists():
            with tempfile.TemporaryDirectory(prefix='generation-', dir=self.root) as temp:
                for item, content in data.items():
                    atomic(Path(temp)/item, content)
                os.rename(temp, folder)
                sync_parent(folder)
        for item, content in data.items():
            secure(folder/item, private=True)
            if (folder/item).read_bytes() != content:
                raise Error('generation_content_conflict')
        return fingerprint

    def desired(self, settings):
        generation = settings['generation']
        tls = ''
        if generation:
            certdir = self.root/'generations'/generation
            tls = f'''server {{
 listen 127.0.0.1:{settings['target_port']} ssl;
 http2 on;
 server_name {settings['server_name']};
 ssl_protocols TLSv1.3;
 ssl_certificate {certdir}/fullchain.pem;
 ssl_certificate_key {certdir}/privkey.pem;
 location / {{ default_type text/plain; return 200 "ready\\n"; }}
}}
'''
        http = '' if settings['external_lineage'] else f'''server {{
 listen 0.0.0.0:80;
 server_name {settings['server_name']};
 location ^~ /.well-known/acme-challenge/ {{ root {self.webroot}; }}
 location / {{ return 404; }}
}}
'''
        # The root master reads keys; unprivileged workers serve static challenges.
        # No proxy, dynamic module, external include, or user-controlled URI mapping.
        nginx = f'''user www-data;
daemon off;
worker_processes 1;
pid /run/vps-secure-reality-target/nginx.pid;
error_log stderr crit;
events {{ worker_connections 128; }}
http {{ access_log off;
 client_body_temp_path /run/vps-secure-reality-target/body;
 proxy_temp_path /run/vps-secure-reality-target/proxy;
 fastcgi_temp_path /run/vps-secure-reality-target/fastcgi;
 uwsgi_temp_path /run/vps-secure-reality-target/uwsgi;
 scgi_temp_path /run/vps-secure-reality-target/scgi;
 {http}{tls} }}
'''
        unit = f'''[Unit]
Description=VPS Secure owned loopback TLS target
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
UMask=0077
ExecStart=/usr/sbin/nginx -c {self.files['nginx']}
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RuntimeDirectory=vps-secure-reality-target
RuntimeDirectoryMode=0755
ReadWritePaths=/run/vps-secure-reality-target
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_CHOWN
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
'''
        renew = f'''[Unit]
Description=VPS Secure owned certificate renewal and deployment
After=network-online.target {SERVICE}
[Service]
Type=oneshot
UMask=0077
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/python3 -I {self.runtime}/target_service.py renew --yes
SuccessExitStatus=10
StandardOutput=journal
StandardError=journal
'''
        timer = '''[Unit]
Description=VPS Secure certificate renewal schedule
[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
'''
        files = {'settings': pack(json.dumps(settings,sort_keys=True).encode()), 'nginx': pack(nginx.encode()),
                 'unit': pack(unit.encode(),0o644), 'renew': pack(renew.encode(),0o644), 'timer': pack(timer.encode(),0o644)}
        return {'files':files, 'services': {SERVICE:{'active':True,'enabled':True},
                  TIMER:{'active':settings['renewal_enabled'],'enabled':settings['renewal_enabled']}}}

    def configure_state(self, state, reload_target=False):
        self.command(['systemctl','daemon-reload'])
        for name in (SERVICE, TIMER):
            target = state['services'][name]
            if (self.units/name).exists():
                self.command(['systemctl','enable' if target['enabled'] else 'disable',name])
                action = 'reload' if name == SERVICE and reload_target else 'start'
                self.command(['systemctl',action if target['active'] else 'stop',name])
            elif target['active'] or target['enabled']:
                raise Error('restore_unit_missing',60)
        if self.service_state() != state['services']:
            raise Error('service_state_mismatch',50)

    def restore(self, record, desired):
        current = self.capture()
        for key in self.files:
            if current['files'][key] not in (record['before']['files'][key],record['after']['files'][key]):
                raise Error('external_change_blocks_recovery',60)
        # Units are exclusively owned; never restart system nginx or old panels.
        reload_target = (current['services'][SERVICE]['active'] and desired['services'][SERVICE]['active']
                         and current['files']['unit'] == desired['files']['unit'])
        for name in (TIMER, SERVICE):
            if (self.units/name).exists() and not desired['services'][name]['active']:
                self.command(['systemctl','disable','--now',name])
        for key,path in self.files.items():
            value = desired['files'][key]
            if value is None:
                unlink(path)
            else:
                expected_mode = 0o600 if key in ('settings','nginx') else 0o644
                if value['mode'] != expected_mode:
                    raise Error('invalid_restore_mode',60)
                atomic(path,base64.b64decode(value['data'],validate=True),expected_mode)
        if desired['files']['nginx']:
            # nginx -t needs its runtime directory before the first unit start.
            self.command(['install','-d','-m','755','/run/vps-secure-reality-target'])
            self.command(['nginx','-t','-c',str(self.files['nginx'])])
        self.configure_state(desired,reload_target=reload_target)
        if desired['files']['settings']:
            for attempt in range(20):
                try:
                    self.verify(ownership=False)
                    break
                except Exception:
                    if attempt == 19:
                        raise
                    time.sleep(.1)
        self.write(self.root/'managed.json',{'files':desired['files']})

    def transaction(self, kind, after, firewall_before=None, firewall_after=None):
        if self.pending.exists():
            raise Error('pending_certificate_recovery',60)
        self.ownership()
        before = self.capture()
        if before == after:
            self.verify()
            return 10
        identifier = time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+secrets.token_hex(4)
        record = {'id':identifier,'kind':kind,'status':'pending','before':before,'after':after,
                  'firewall_before':self.rules() if firewall_before is None else firewall_before,
                  'firewall_after':self.rules() if firewall_after is None else firewall_after}
        path = self.transactions/(identifier+'.json')
        self.write(path,record)
        self.write(self.pending,{'id':identifier})
        try:
            self.restore(record,after)
        except BaseException:
            try:
                self.restore(record,before)
                record['status']='compensated'
                self.write(path,record)
                unlink(self.pending)
            except BaseException:
                raise Error('certificate_recovery_incomplete',60) from None
            raise Error('certificate_operation_failed_restored',40) from None
        record['status']='committed'
        self.write(path,record)
        self.write(self.root/'last.json',{'id':identifier})
        unlink(self.pending)
        return 0

    def runtime_install(self):
        marker=self.root/'runtime.json'
        previous=self.read(marker) if marker.exists() else {}
        record={'before':{},'after':{},'previous_manifest':previous}
        for name in ('target_service.py','target_check.py'):
            source = Path(__file__).resolve().with_name(name)
            secure(source)
            destination = self.runtime/name
            if destination.exists():
                secure(destination,private=True)
                if sha(destination.read_bytes())!=previous.get(name):
                    raise Error('runtime_changed_requires_review')
            record['before'][name]=pack(destination.read_bytes()) if destination.exists() else None
            record['after'][name]=pack(source.read_bytes())
        journal=self.root/'runtime-pending.json'
        self.write(journal,record)
        try:
            for name,value in record['after'].items():
                atomic(self.runtime/name,base64.b64decode(value['data']))
            self.write(marker,{name:sha(base64.b64decode(value['data'])) for name,value in record['after'].items()})
            unlink(journal)
        except BaseException:
            try:
                self.recover_runtime()
            except BaseException:
                raise Error('runtime_recovery_incomplete',60) from None
            raise Error('runtime_install_failed_restored',40) from None

    def recover_runtime(self):
        journal=self.root/'runtime-pending.json'
        record=self.read(journal)
        names={'target_service.py','target_check.py'}
        if set(record['before'])!=names or set(record['after'])!=names:
            raise Error('invalid_runtime_recovery_record',60)
        for name in sorted(names):
            path=self.runtime/name
            if path.exists():
                secure(path,private=True)
                current=pack(path.read_bytes())
            else:
                current=None
            if current not in (record['before'][name],record['after'][name]):
                raise Error('external_runtime_change_blocks_recovery',60)
            before=record['before'][name]
            if before is None:
                unlink(path)
            else:
                atomic(path,base64.b64decode(before['data'],validate=True))
        if record['previous_manifest']:
            self.write(self.root/'runtime.json',record['previous_manifest'])
        else:
            unlink(self.root/'runtime.json')
        unlink(journal)

    def apply(self,args):
        self.clean()
        settings = self.preflight(args)
        if self.files['settings'].exists():
            self.verify()
            return 10
        self.runtime_install()
        if not settings['external_lineage']:
            web_marker=self.root/'webroot.json'
            if self.webroot.exists() and (not web_marker.exists() or self.read(web_marker).get('path')!=str(self.webroot)):
                raise Error('unowned_challenge_directory')
            secure(self.webroot.parent,directory=True)
            self.write(web_marker,{'path':str(self.webroot)})
            if not self.webroot.exists():
                self.webroot.mkdir(mode=0o755)
                self.webroot.chmod(0o755)
            secure(self.webroot,directory=True)
        if settings['external_lineage']:
            settings['generation'] = self.generation(Path(settings['external_lineage']),settings['server_name'])
            settings['renewal_enabled'] = True
        # Durable coordination marker links independent firewall and certificate domains.
        self.write(self.root/'operation.json',{'kind':'apply','settings':settings,'before':self.capture(), 'rules':self.rules()})
        try:
            if not settings['external_lineage']:
                self.firewall_change(True,settings)
            self.transaction('apply',self.desired(settings),firewall_before=self.read(self.root/'operation.json')['rules'])
        except BaseException:
            try:
                self.recover_operation()
            except BaseException:
                raise Error('apply_recovery_incomplete',60) from None
            raise Error('apply_failed_restored',40) from None
        unlink(self.root/'operation.json')
        return 0

    def verify(self,ownership=True):
        if ownership:
            self.ownership()
        settings = self.settings()
        self.firewall_preflight(settings)
        if not settings['external_lineage'] and self.http_rule() not in self.rules():
            raise Error('challenge_firewall_rule_missing',50)
        desired = self.desired(settings)
        if self.capture() != desired:
            raise Error('target_configuration_or_service_mismatch',50)
        if settings['generation']:
            folder = self.root/'generations'/settings['generation']
            _, fingerprint = self.certificate(folder,settings['server_name'])
            if fingerprint != settings['generation']:
                raise Error('deployed_generation_mismatch',50)
            check_target('127.0.0.1',settings['target_port'],settings['server_name'],80)
            context = ssl.create_default_context()
            with socket.create_connection(('127.0.0.1',settings['target_port']),timeout=5) as connection:
                with context.wrap_socket(connection,server_hostname=settings['server_name']) as tls:
                    if sha(tls.getpeercert(binary_form=True)) != fingerprint:
                        raise Error('served_certificate_mismatch',50)
            rows = self.command(['ss','-H','-ltn']).stdout.decode().splitlines()
            listeners = [r.split()[3] for r in rows if r.split()[3].endswith(':'+str(settings['target_port']))]
            if listeners != ['127.0.0.1:'+str(settings['target_port'])]:
                raise Error('target_not_loopback_only',50)
        return 'TARGET=verified; TLS='+('ready' if settings['generation'] else 'awaiting_certificate')+'; NATURAL_RENEWAL=not_accepted'

    def acme(self, settings, staging=False):
        prefix = 'staging' if staging else 'acme'
        return ['certbot','--config-dir',str(self.root/prefix),'--work-dir',str(self.root/(prefix+'-work')),
                '--logs-dir',str(self.root/(prefix+'-logs'))]

    def source(self,settings):
        return Path(settings['external_lineage']) if settings['external_lineage'] else self.root/'acme/live/target'

    def deploy(self):
        self.clean()
        settings = self.settings()
        settings['generation'] = self.generation(self.source(settings),settings['server_name'])
        settings['renewal_enabled'] = True
        return self.transaction('deploy',self.desired(settings))

    def issue(self,accept):
        self.clean()
        settings = self.settings()
        if settings['external_lineage']:
            raise Error('external_issuer_not_owned')
        if self.source(settings).exists():
            return self.deploy()
        if not accept:
            raise Error('explicit_ca_terms_required',64)
        self.verify()
        self.backup()
        extra = ['certonly','--non-interactive','--agree-tos','--register-unsafely-without-email',
                 '--webroot','-w',str(self.webroot),'--cert-name','target','-d',settings['server_name']]
        try:
            self.command(self.acme(settings,True)+extra+['--staging'],timeout=240)
            self.command(self.acme(settings)+extra,timeout=240)
        except Error:
            # Issuance is external and cannot be undone by deleting a local file.
            # Keep the already verified challenge-only apply state for retry.
            raise Error('issuance_failed_challenge_service_and_owned_http_rule_retained',40) from None
        return self.deploy()

    def renew(self):
        self.clean()
        settings = self.settings()
        if not settings['external_lineage']:
            if not self.source(settings).exists():
                raise Error('issue_certificate_first')
            # Deployment is a distinct transaction and runs even after a no-op renewal.
            self.command(self.acme(settings)+['renew','--non-interactive','--cert-name','target'],timeout=240)
        return self.deploy()

    def backup(self):
        self.clean()
        self.verify()
        identifier = time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+secrets.token_hex(4)
        state = self.capture()
        self.write(self.transactions/(identifier+'.json'),{'id':identifier,'kind':'backup','status':'committed',
                   'before':state,'after':state,'rules':self.rules()})
        self.write(self.root/'last-backup.json',{'id':identifier})
        return identifier

    def recover_certificate(self,identifier=None):
        pointer = self.pending if self.pending.exists() else self.root/'last.json'
        if identifier is None:
            if not pointer.exists():
                return 10
            identifier = self.read(pointer)['id']
        if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}',identifier):
            raise Error('invalid_transaction_id',64)
        if self.pending.exists() and self.read(self.pending)['id'] != identifier:
            raise Error('recover_pending_first',60)
        path = self.transactions/(identifier+'.json')
        record = self.read(path)
        if record['id'] != identifier:
            raise Error('transaction_id_mismatch')
        if record['kind']=='backup':
            self.clean()
            if self.rules()!=record['rules']:
                raise Error('firewall_changes_block_backup_restore')
            return self.transaction('restore-backup',record['before'])
        if record['status'] in ('rolled_back','compensated'):
            if self.pending.exists():
                if self.capture()!=record['before']:
                    raise Error('terminal_record_mismatch',60)
                unlink(self.pending)
            return 10
        self.write(self.pending,{'id':identifier})
        fw={'before':record['firewall_before'],'after':record['firewall_after'],
            'settings':json.loads(base64.b64decode((record['before']['files']['settings'] or record['after']['files']['settings'])['data']))}
        # A distinct durable firewall journal precedes certificate restoration.
        self.write(self.fw_pending,fw)
        self.firewall_reconcile(fw,fw['before'])
        unlink(self.fw_pending)
        self.restore(record,record['before'])
        record['status']='rolled_back'
        self.write(path,record)
        unlink(self.pending)
        return 0

    def recover_operation(self):
        operation = self.read(self.root/'operation.json')
        record={'before':operation['rules'],'after':self.rules(),'settings':operation['settings']}
        if self.fw_pending.exists():
            record=self.read(self.fw_pending)
        self.firewall_reconcile(record,operation['rules'])
        if self.fw_pending.exists():
            unlink(self.fw_pending)
        if self.pending.exists():
            self.recover_certificate()
        if self.capture()!=operation['before']:
            self.transaction('recover-operation',operation['before'])
        unlink(self.root/'operation.json')

    def rollback(self,identifier=None):
        if (self.root/'runtime-pending.json').exists():
            if identifier:
                raise Error('recover_runtime_without_id_first',60)
            self.recover_runtime()
            return 0
        if (self.root/'operation.json').exists():
            if identifier:
                raise Error('recover_operation_without_id_first',60)
            self.recover_operation()
            return 0
        if self.pending.exists():
            return self.recover_certificate(identifier)
        if self.fw_pending.exists():
            if identifier:
                raise Error('recover_firewall_without_id_first',60)
            record=self.read(self.fw_pending)
            self.firewall_reconcile(record,record['before'])
            unlink(self.fw_pending)
            return 0
        return self.recover_certificate(identifier)

    def uninstall(self):
        self.clean()
        settings=self.settings()
        # Refuse to remove a target still referenced by the managed node.
        node=Path('/var/lib/vps-secure-reality-node/settings.json')
        if node.exists() and self.read(node).get('target_port')==settings['target_port']:
            raise Error('uninstall_node_before_target')
        before=self.capture()
        self.write(self.root/'operation.json',{'kind':'uninstall','settings':settings,'before':before,'rules':self.rules()})
        try:
            empty={'files':{key:None for key in self.files},'services':{name:{'active':False,'enabled':False} for name in (SERVICE,TIMER)}}
            final_rules=[r for r in self.rules() if r!=self.http_rule()] if not settings['external_lineage'] else self.rules()
            self.transaction('uninstall',empty,firewall_after=final_rules)
            if not settings['external_lineage']:
                self.firewall_change(False,settings)
        except BaseException:
            try:
                self.recover_operation()
            except BaseException:
                raise Error('uninstall_recovery_incomplete',60) from None
            raise Error('uninstall_failed_restored',40) from None
        unlink(self.root/'operation.json')
        return 0


def recover_dependencies(t):
    for process in ('apt-get','dpkg'):
        if t.command(['pgrep','-x',process],check=False).returncode==0:
            raise Error('package_manager_running_wait_before_recovery',60)
    marker=t.root/'dependencies-pending.json'
    record=t.read(marker)
    policy=Path('/usr/sbin/policy-rc.d')
    if policy.exists() or policy.is_symlink():
        secure(policy)
        if sha(policy.read_bytes())!=record['policy_sha256']:
            raise Error('package_policy_changed_recovery_requires_review',60)
        unlink(policy)
    # Only disable newly introduced default units, never pre-existing services.
    for name, existed in record['units_existed'].items():
        if not existed:
            loaded=t.command(['systemctl','show',name,'--property=LoadState','--value']).stdout.strip()
            if loaded!=b'not-found':
                t.command(['systemctl','disable','--now',name])
    unlink(marker)


def dependencies(confirmed):
    if not confirmed:
        raise Error('confirmation_required',64)
    info=platform.freedesktop_os_release()
    if os.geteuid()!=0 or info.get('ID')!='debian' or info.get('VERSION_ID')!='13' or platform.machine() not in ('x86_64','amd64'):
        raise Error('unsupported_platform_or_user',20)
    t=Target()
    with t.locked():
        return install_dependencies(t)


def install_dependencies(t):
    packages=['nginx','certbot','ca-certificates','openssl','python3']
    if (t.root/'dependencies-pending.json').exists():
        raise Error('dependency_recovery_required',60)
    if all(shutil.which(p,path=ENV['PATH']) for p in ('nginx','certbot','openssl','python3')):
        return 10
    policy=Path('/usr/sbin/policy-rc.d')
    # Never overwrite an existing package service policy, or stop a site's nginx.
    if policy.exists() or policy.is_symlink():
        raise Error('existing_package_service_policy_requires_review')
    marker=t.root/'dependencies-pending.json'
    if marker.exists():
        raise Error('dependency_recovery_required',60)
    content=b'#!/bin/sh\n# vps-secure-reality-target temporary package-start guard\nexit 101\n'
    existed={name:t.command(['systemctl','show',name,'--property=LoadState','--value']).stdout.strip()!=b'not-found'
             for name in ('nginx.service','certbot.timer')}
    t.write(marker,{'policy_sha256':sha(content),'units_existed':existed})
    try:
        fd=os.open(policy,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o755)
        with os.fdopen(fd,'wb') as stream:
            os.fchmod(stream.fileno(),0o755)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        sync_parent(policy)
        t.command(['apt-get','update'],timeout=300)
        t.command(['apt-get','install','-y','--no-install-recommends']+packages,timeout=600)
    finally:
        recover_dependencies(t)
    return 0


class Parser(argparse.ArgumentParser):
    def error(self,message):
        raise Error('invalid_arguments',64)


def main(argv=None):
    os.umask(0o077)
    try:
        parser=Parser(description=__doc__)
        parser.add_argument('action',choices=('dependencies','preflight','apply','issue','deploy','renew','verify','status','backup','rollback','uninstall'))
        parser.add_argument('--yes',action='store_true')
        parser.add_argument('--server-name')
        parser.add_argument('--target-port',type=int)
        parser.add_argument('--existing-lineage')
        parser.add_argument('--external-renewal',action='store_true')
        parser.add_argument('--accept-ca-terms',action='store_true')
        parser.add_argument('--transaction')
        args=parser.parse_args(argv)
        if args.action not in ('preflight','verify','status') and not args.yes:
            raise Error('confirmation_required',64)
        if args.action=='dependencies':
            result=dependencies(args.yes)
        else:
            target=Target()
            if args.action=='rollback' and (target.root/'dependencies-pending.json').exists():
                if args.transaction:
                    raise Error('recover_dependencies_without_id_first',60)
                with target.locked():
                    recover_dependencies(target)
                print('DEPENDENCIES_RECOVERY=completed; INSTALLED_PACKAGES=retained')
                return 0
            target.platform_gate()
            if args.action=='preflight':
                target.preflight(args)
                print('TARGET_PREFLIGHT=pass; PURE_INSTALL=not_accepted')
                return 0
            if args.action in ('status','verify'):
                if any(path.exists() for path in (target.pending,target.fw_pending,target.root/'operation.json',target.root/'dependencies-pending.json',target.root/'runtime-pending.json')):
                    raise Error('pending_recovery_requires_rollback',60)
                if not target.files['settings'].exists():
                    print('TARGET=not_installed')
                    return 10
                target.clean()
                print(target.verify())
                return 0
            def interrupt(signum,frame):
                raise Error('operation_interrupted',40)
            for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):
                signal.signal(sig,interrupt)
            with target.locked():
                if args.action=='apply':
                    result=target.apply(args)
                elif args.action=='issue':
                    result=target.issue(args.accept_ca_terms)
                elif args.action=='backup':
                    print('TARGET_BACKUP='+target.backup()+'; CONTENTS=private')
                    return 0
                elif args.action=='rollback':
                    result=target.rollback(args.transaction)
                else:
                    result=getattr(target,args.action)()
        print('TARGET_OPERATION='+('unchanged' if result==10 else 'completed')+'; NATURAL_RENEWAL=not_accepted')
        return result or 0
    except Error as error:
        print('TARGET_OPERATION='+str(error),file=sys.stderr)
        return error.code
    except Exception:
        print('TARGET_OPERATION=failed_redacted; CHECK_PENDING_RECOVERY=required',file=sys.stderr)
        return 40


if __name__=='__main__':
    sys.exit(main())
