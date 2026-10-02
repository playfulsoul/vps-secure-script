import importlib.util
from pathlib import Path
import sys
import unittest

MODULE_DIR = Path(__file__).resolve().parents[2] / 'modules/builtin/applications-reality-node'
sys.path.insert(0, str(MODULE_DIR))
import node_config
from target_check import TargetError


class ConfigTests(unittest.TestCase):
    def config(self, **changes):
        values = dict(port=443, target_host='127.0.0.1', target_port=8443,
                      server_name='target.example', client_id='00000000-0000-4000-8000-000000000001',
                      private_key='A' * 43, short_id='0123456789abcdef')
        values.update(changes)
        return node_config.server_config(**values)

    def test_single_node_no_panel_or_api(self):
        config = self.config()
        self.assertEqual(len(config['inbounds']), 1)
        self.assertNotIn('api', config)
        inbound = config['inbounds'][0]
        self.assertEqual(inbound['settings']['clients'][0]['flow'], 'xtls-rprx-vision')
        self.assertEqual(inbound['streamSettings']['realitySettings']['target'], '127.0.0.1:8443')
        self.assertEqual(config['log']['loglevel'], 'none')

    def test_ipv6_target_bracketed(self):
        config = self.config(target_host='::1')
        self.assertEqual(config['inbounds'][0]['streamSettings']['realitySettings']['target'], '[::1]:8443')

    def test_external_target_or_recursion_rejected(self):
        for changes in ({'target_host': 'example.com'}, {'target_port': 443}):
            with self.assertRaises(TargetError):
                self.config(**changes)

    def test_bad_credentials_rejected_without_echo(self):
        for name, value in (('client_id', 'sensitive'), ('private_key', 'sensitive'), ('short_id', 'sensitive')):
            with self.assertRaisesRegex(node_config.ConfigError, '^invalid_credentials$'):
                self.config(**{name: value})

    def test_private_destinations_blocked(self):
        rule = self.config()['routing']['rules'][0]
        self.assertEqual(rule['outboundTag'], 'blocked')
        for network in ('127.0.0.0/8', '169.254.0.0/16', 'fc00::/7'):
            self.assertIn(network, rule['ip'])
