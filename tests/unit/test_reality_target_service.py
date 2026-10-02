"""No CA/network use. Exercise prerequisite failure domains with safe fakes."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'modules/builtin/applications-reality-node'))
import target_service as service


class FakeTarget(service.Target):
    def __init__(self,base):
        super().__init__()
        self.root=base/'state'
        self.config=base/'config'
        self.runtime=base/'runtime'
        self.units=base/'units'
        self.units.mkdir()
        self.webroot=base/'webroot'
        self.files={'settings':self.config/'settings.json','nginx':self.config/'nginx.conf',
                    'unit':self.units/service.SERVICE,'renew':self.units/service.RENEW,'timer':self.units/service.TIMER}
        self.pending=self.root/'pending.json'
        self.fw_pending=self.root/'firewall-pending.json'
        self.transactions=self.root/'transactions'
        self.states={name:{'active':False,'enabled':False} for name in (service.SERVICE,service.TIMER)}
        self.rule_list=['ufw allow 2222/tcp']
        self.calls=[]
        self.fail_reload=0
        self.fail_issue=False
        self.fail_deploy=False
        self.fail_install=False
        self.cert='a'*64
        self.source_dir=base/'lineage'
        self.source_dir.mkdir()

    def command(self,args,check=True,timeout=60,input=None):
        self.calls.append(args)
        data=b''
        rc=0
        if args[0]=='systemctl':
            op=args[1]
            name=args[2] if op=='show' else args[-1]
            state=self.states.get(name,{'active':False,'enabled':False})
            if op=='show':
                if '--property=LoadState' in args:
                    data=b'loaded' if (self.units/name).exists() else b'not-found'
            elif op=='is-enabled':
                data=b'enabled' if state['enabled'] else b'disabled'
            elif op=='is-active':
                rc=0 if state['active'] else 3
            elif op in ('start','restart','reload'):
                if name==service.SERVICE and self.fail_reload:
                    self.fail_reload-=1
                    raise service.Error('injected_service_failure',40)
                state['active']=True
            elif op=='stop':
                state['active']=False
            elif op in ('enable','disable'):
                state['enabled']=op=='enable'
                if '--now' in args:
                    state['active']=op=='enable'
        elif args[0]=='ufw':
            if args[1:3]==['show','added']:
                data='\n'.join(self.rule_list).encode()
            elif args[1]=='allow':
                self.rule_list.append(self.http_rule())
            else:
                self.rule_list.remove(self.http_rule())
        elif args[0]=='certbot':
            if self.fail_issue:
                raise service.Error('injected_issuance_failure',40)
        elif args[0]=='pgrep':
            rc=1
        elif args[:2]==['apt-get','install']:
            for name in ('nginx.service','certbot.timer'):
                (self.units/name).touch()
            if self.fail_install:
                raise KeyboardInterrupt()
        return subprocess.CompletedProcess(args,rc,data,b'')

    def entry(self,settings=None):
        return Path('/example/platform/bin/vps')

    def platform_gate(self):
        pass

    def firewall_preflight(self,settings=None):
        pass

    def runtime_install(self):
        pass

    def certificate(self,lineage,name):
        if self.fail_deploy:
            raise service.Error('injected_deployment_failure',40)
        return {k:b'fake '+k.encode() for k in ('cert.pem','chain.pem','fullchain.pem','privkey.pem')},self.cert

    def verify(self,ownership=True):
        if ownership:
            self.ownership()
        if self.capture()!=self.desired(self.settings()):
            raise service.Error('fake_state_mismatch',50)
        return 'TARGET=verified'


class TargetServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.base=Path(self.temp.name)
        # Unit tests run unprivileged, with no checks relaxed in production code.
        self.secure=patch.object(service,'secure',lambda *a,**k:None)
        self.secure.start()
        self.sockets=patch.object(service.socket,'socket')
        self.sockets.start()
        self.target=FakeTarget(self.base)
        self.target.initialize()
        self.args=argparse.Namespace(server_name='node.example.com',target_port=12345,
                                    existing_lineage=str(self.target.source_dir),external_renewal=True)

    def tearDown(self):
        self.secure.stop()
        self.sockets.stop()
        self.temp.cleanup()

    def apply(self):
        return self.target.apply(self.args)

    def test_external_apply_keeps_firewall_and_enables_sync_timer(self):
        self.apply()
        self.assertEqual(self.target.rule_list,['ufw allow 2222/tcp'])
        self.assertTrue(self.target.states[service.TIMER]['active'])
        self.assertNotIn('listen 0.0.0.0:80',self.target.files['nginx'].read_text())

    def test_repeat_apply_no_change(self):
        self.apply()
        self.assertEqual(self.apply(),10)

    def test_external_renew_never_calls_acme_and_is_idempotent(self):
        self.apply()
        self.target.calls=[]
        self.assertEqual(self.target.renew(),10)
        self.assertFalse(any(c[0]=='certbot' for c in self.target.calls))
        self.assertFalse(any(c[:2]==['systemctl','reload'] for c in self.target.calls))

    def test_changed_certificate_deploys_using_reload(self):
        self.apply()
        self.target.calls=[]
        self.target.cert='b'*64
        self.target.renew()
        self.assertEqual(self.target.settings()['generation'],'b'*64)
        self.assertIn(['systemctl','reload',service.SERVICE],self.target.calls)

    def test_deployment_failure_preserves_old(self):
        self.apply()
        before=self.target.capture()
        self.target.fail_deploy=True
        with self.assertRaises(service.Error):
            self.target.renew()
        self.assertEqual(self.target.capture(),before)

    def test_reload_failure_compensates(self):
        self.apply()
        before=self.target.capture()
        self.target.cert='b'*64
        self.target.fail_reload=1
        with self.assertRaisesRegex(service.Error,'restored'):
            self.target.renew()
        self.assertEqual(self.target.capture(),before)
        self.assertFalse(self.target.pending.exists())

    def test_failed_compensation_keeps_evidence_and_retry(self):
        self.apply()
        before=self.target.capture()
        self.target.cert='b'*64
        self.target.fail_reload=2
        with self.assertRaisesRegex(service.Error,'incomplete'):
            self.target.renew()
        self.assertTrue(self.target.pending.exists())
        with self.assertRaisesRegex(service.Error,'pending'):
            self.target.renew()
        self.target.rollback()
        self.assertEqual(self.target.capture(),before)

    def test_backup_restore_and_default_undo_are_different(self):
        self.apply()
        identifier=self.target.backup()
        self.target.cert='b'*64
        self.target.renew()
        self.target.rollback(identifier)
        self.assertEqual(self.target.settings()['generation'],'a'*64)
        self.target.rollback()
        self.assertEqual(self.target.settings()['generation'],'b'*64)

    def test_unrelated_rule_change_blocks_backup_restore(self):
        self.apply()
        identifier=self.target.backup()
        self.target.rule_list.append('ufw allow 9090/tcp')
        with self.assertRaisesRegex(service.Error,'firewall_changes'):
            self.target.rollback(identifier)

    def test_uninstall_preserves_source_generations_and_other_rules(self):
        self.apply()
        self.target.uninstall()
        self.assertTrue(self.target.source_dir.exists())
        self.assertTrue((self.target.root/'generations'/('a'*64)).exists())
        self.assertEqual(self.target.rule_list,['ufw allow 2222/tcp'])
        self.assertFalse(self.target.files['settings'].exists())
        self.target.rollback()
        self.assertTrue(self.target.states[service.SERVICE]['active'])

    def managed_apply(self):
        self.args.existing_lineage=None
        self.args.external_renewal=False
        self.apply()

    def test_managed_apply_challenge_only(self):
        self.managed_apply()
        self.assertIn(self.target.http_rule(),self.target.rule_list)
        self.assertIsNone(self.target.settings()['generation'])
        self.assertFalse(self.target.states[service.TIMER]['active'])

    def test_managed_issuance_failure_retains_challenge_state(self):
        self.managed_apply()
        before=self.target.capture()
        self.target.fail_issue=True
        with self.assertRaisesRegex(service.Error,'challenge_service_and_owned_http_rule_retained'):
            self.target.issue(True)
        self.assertEqual(self.target.capture(),before)
        self.assertIn(self.target.http_rule(),self.target.rule_list)

    def test_issue_requires_terms(self):
        self.managed_apply()
        with self.assertRaisesRegex(service.Error,'ca_terms'):
            self.target.issue(False)

    def test_issue_staging_then_production_without_force(self):
        self.managed_apply()
        self.target.issue(True)
        calls=[c for c in self.target.calls if c[0]=='certbot']
        self.assertEqual(len(calls),2)
        self.assertIn('--staging',calls[0])
        self.assertNotIn('--staging',calls[1])
        self.assertNotIn('--force-renewal',repr(calls))

    def test_normal_renew_no_force_and_deploy(self):
        self.managed_apply()
        source=self.target.source(self.target.settings())
        source.mkdir(parents=True)
        self.target.renew()
        calls=[c for c in self.target.calls if c[0]=='certbot']
        self.assertEqual(len(calls),1)
        self.assertIn('renew',calls[0])
        self.assertNotIn('--force-renewal',calls[0])

    def test_managed_uninstall_and_rollback_restore_owned_rule(self):
        self.managed_apply()
        self.target.uninstall()
        self.assertNotIn(self.target.http_rule(),self.target.rule_list)
        self.target.rollback()
        self.assertIn(self.target.http_rule(),self.target.rule_list)

    def test_rollback_apply_removes_only_owned_rule(self):
        self.managed_apply()
        self.target.rollback()
        self.assertEqual(self.target.rule_list,['ufw allow 2222/tcp'])
        self.assertFalse(self.target.files['settings'].exists())

    def test_existing_occupied_port_is_refused(self):
        with patch.object(service.socket,'socket') as sock:
            sock.return_value.__enter__.return_value.bind.side_effect=OSError()
            with self.assertRaisesRegex(service.Error,'occupied'):
                self.target.preflight(self.args)

    def test_generated_config_and_units_are_self_contained(self):
        self.managed_apply()
        config=self.target.files['nginx'].read_text()
        self.assertNotIn('proxy_pass',config)
        self.assertNotIn('include ',config)
        self.assertIn('user www-data;',config)
        unit=self.target.files['renew'].read_text()
        self.assertIn('target_service.py renew --yes',unit)
        self.assertIn('SuccessExitStatus=10',unit)
        self.assertNotIn('certbot renew',unit)

    def test_no_secret_in_parser_error(self):
        self.assertEqual(service.main(['deploy','--password','SECRET-VALUE']),64)

    def dependency_paths(self):
        policy=self.base/'policy-rc.d'
        original=Path
        return policy,patch.object(service,'Path',side_effect=lambda value: policy if str(value)=='/usr/sbin/policy-rc.d' else original(value))

    def test_dependencies_restore_guard_and_disable_only_new_defaults(self):
        policy,paths=self.dependency_paths()
        (self.target.units/'nginx.service').touch()
        with paths,patch.object(service.shutil,'which',return_value=None):
            service.install_dependencies(self.target)
        self.assertFalse(policy.exists())
        self.assertNotIn(['systemctl','disable','--now','nginx.service'],self.target.calls)
        self.assertIn(['systemctl','disable','--now','certbot.timer'],self.target.calls)

    def test_dependencies_interrupt_recovers_policy(self):
        policy,paths=self.dependency_paths()
        self.target.fail_install=True
        with paths,patch.object(service.shutil,'which',return_value=None):
            with self.assertRaises(KeyboardInterrupt):
                service.install_dependencies(self.target)
        self.assertFalse(policy.exists())
        self.assertFalse((self.target.root/'dependencies-pending.json').exists())

    def test_existing_package_policy_is_never_overwritten(self):
        policy,paths=self.dependency_paths()
        policy.write_bytes(b'existing operator policy')
        with paths,patch.object(service.shutil,'which',return_value=None):
            with self.assertRaisesRegex(service.Error,'existing_package_service_policy'):
                service.install_dependencies(self.target)
        self.assertEqual(policy.read_bytes(),b'existing operator policy')
        self.assertFalse(any(c[0]=='apt-get' for c in self.target.calls))

    def test_changed_policy_blocks_recovery_without_overwrite(self):
        policy,paths=self.dependency_paths()
        policy.write_bytes(b'other writer')
        self.target.write(self.target.root/'dependencies-pending.json',{'policy_sha256':'0'*64,'units_existed':{}})
        with paths:
            with self.assertRaisesRegex(service.Error,'package_policy_changed'):
                service.recover_dependencies(self.target)
        self.assertEqual(policy.read_bytes(),b'other writer')
        self.assertTrue((self.target.root/'dependencies-pending.json').exists())

    def test_abrupt_dependency_guard_can_be_explicitly_recovered(self):
        policy,paths=self.dependency_paths()
        content=b'owned guard'
        policy.write_bytes(content)
        self.target.write(self.target.root/'dependencies-pending.json',{'policy_sha256':service.sha(content),'units_existed':{}})
        with paths:
            service.recover_dependencies(self.target)
        self.assertFalse(policy.exists())

    def test_issue_existing_lineage_checks_before_skip(self):
        self.managed_apply()
        self.target.source(self.target.settings()).mkdir(parents=True)
        self.target.fail_deploy=True
        with self.assertRaises(service.Error):
            self.target.issue(False)
        self.assertFalse(any(c[0]=='certbot' for c in self.target.calls))

    def test_pending_dependencies_block_normal_apply(self):
        self.target.write(self.target.root/'dependencies-pending.json',{'pending':True})
        with self.assertRaisesRegex(service.Error,'pending_recovery'):
            self.apply()

    def test_runtime_copy_failure_recovers_and_allows_retry(self):
        original=service.atomic
        failures=[1]
        def failing(path,data,mode=0o600):
            if path==self.target.runtime/'target_check.py' and failures[0]:
                failures[0]-=1
                raise OSError('injected_runtime_copy')
            return original(path,data,mode)
        with patch.object(service,'atomic',side_effect=failing):
            with self.assertRaisesRegex(service.Error,'runtime_install_failed_restored'):
                service.Target.runtime_install(self.target)
        self.assertFalse((self.target.runtime/'target_service.py').exists())
        self.assertFalse((self.target.root/'runtime-pending.json').exists())
        service.Target.runtime_install(self.target)
        self.assertTrue((self.target.runtime/'target_service.py').exists())


if __name__=='__main__':
    unittest.main()
