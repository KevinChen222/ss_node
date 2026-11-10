#!/usr/bin/env python3
"""Exercise node transactions with legacy DNS using TEST_SINGBOX and TEST_YQ."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR="$WORK"
CONFIG_FILE="$WORK/config.json"
NODE_RELAY_FILE="$WORK/relay.json"
NODE_RELAY_LINKS_FILE="$WORK/relay_links.json"
CLASH_YAML_FILE="$WORK/clash.yaml"
METADATA_FILE="$WORK/metadata.json"
XRAY_CONFIG_FILE="$WORK/xray.json"
XRAY_BIN="$WORK/xray"
XRAY_PID_FILE="$WORK/xray.pid"
SNI_ROUTER_STATE_FILE="$WORK/router.json"
SNI_ROUTER_HAPROXY_CONF="$WORK/haproxy.cfg"
NFT_PERSIST_FILE="$WORK/nft.rules"
NODE_NFT_CONFIG_FILE="$WORK/nftables.conf"
PROXYALL_WRITE_LOCK_FILE="$WORK/config.lock"
PID_FILE="$WORK/sing-box.pid"
INIT_SYSTEM=direct
SINGBOX_BIN="$TEST_SINGBOX"
YQ_BINARY="$TEST_YQ"
server_ip=127.0.0.1
BATCH_MODE=true
BATCH_IP=127.0.0.1
BATCH_PORT=16721
BATCH_SS_VARIANT=4
for deprecated_var in ${!ENABLE_DEPRECATED_@}; do unset "$deprecated_var"; done
_manage_service() {
    printf '%s\n' "$1" >> "$WORK/service-calls"
    [ "${FAIL_RESTART:-0}" != 1 ]
}
edit_and_check() {
    _atomic_modify_json "$CONFIG_FILE" '.log.level="error"' || return 1
    [ "${FAIL_OPERATION:-0}" != 1 ] || return 1
    _check_config
}
case "$ACTION" in
    check) _check_config ;;
    add) _add_shadowsocks_menu ;;
    edit) _node_operation edit_and_check ;;
esac
'''


@unittest.skipUnless(os.environ.get('TEST_SINGBOX') and os.environ.get('TEST_YQ'),
                     'set TEST_SINGBOX and TEST_YQ for real-core DNS transaction tests')
class NodeDNSMigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-node-dns-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.main = {'log': {'level': 'warn'}, 'inbounds': [],
                     'outbounds': [{'type': 'direct', 'tag': 'direct'}],
                     'dns': {'servers': [{'tag': 'dns-local', 'address': 'local', 'detour': 'direct'}],
                             'rules': [{'outbound': 'any', 'server': 'dns-local'}],
                             'strategy': 'prefer_ipv4'},
                     'route': {'rules': [], 'final': 'direct'}}
        self.relay = {'inbounds': [], 'outbounds': [], 'route': {'rules': []}}
        self.client = {'proxies': [], 'proxy-groups': [{'name': '节点选择', 'type': 'select',
                                                      'proxies': ['DIRECT']}]}
        self.metadata = {}
        (self.root / 'harness.sh').write_text(HARNESS)

    def write(self):
        for name, value in [('config.json', self.main), ('relay.json', self.relay),
                            ('clash.yaml', self.client), ('metadata.json', self.metadata),
                            ('relay_links.json', {})]:
            (self.root / name).write_text(json.dumps(value))

    def snapshot(self):
        return {name: (self.root / name).read_bytes() for name in
                ['config.json', 'relay.json', 'clash.yaml', 'metadata.json', 'relay_links.json']}

    def run_shell(self, action, success=True, **extra):
        result = subprocess.run(['bash', str(self.root / 'harness.sh')], text=True,
                                capture_output=True, timeout=20,
                                env=dict(os.environ, REPO=str(REPO), WORK=str(self.root),
                                         ACTION=action, **extra))
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(list(self.root.glob('.node-op.*')), result.stderr)
        return result

    def read(self, name):
        if name == 'clash.yaml':
            result = subprocess.run([os.environ['TEST_YQ'], '-o=json', '.', str(self.root / name)],
                                    capture_output=True, text=True, check=True)
            return json.loads(result.stdout)
        return json.loads((self.root / name).read_text())

    def assert_migrated(self):
        merged = [self.read('config.json'), self.read('relay.json')]
        dns = next(doc['dns'] for doc in merged if 'dns' in doc)
        self.assertEqual(dns['servers'][0]['type'], 'local')
        self.assertEqual(dns['servers'][0]['tag'], 'dns-local')
        self.assertEqual(dns['servers'][0]['detour'], 'direct')
        self.assertEqual(dns['strategy'], 'prefer_ipv4')
        self.assertNotIn('address', dns['servers'][0])
        self.assertFalse(any('outbound' in rule for rule in dns['rules']))
        self.assertEqual(merged[0]['route']['default_domain_resolver'], {'server': 'dns-local'})
        self.run_shell('check')

    def assert_rolled_back(self, before):
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.root / 'xray.json').exists())

    def test_padding_node_migrates_legacy_dns_without_service_environment(self):
        self.write()
        failed = self.run_shell('check', success=False)
        self.assertIn('legacy DNS', failed.stdout + failed.stderr)
        self.run_shell('add')
        self.assert_migrated()
        inbound = self.read('config.json')['inbounds'][0]
        self.assertEqual(inbound['multiplex'], {'enabled': True, 'padding': True})
        proxy = self.read('clash.yaml')['proxies'][0]
        self.assertTrue(proxy['smux']['enabled'])
        self.assertTrue(proxy['smux']['padding'])
        self.assertEqual(proxy['smux']['protocol'], 'h2mux')
        self.assertEqual(proxy['password'], inbound['password'])
        self.assertEqual((self.root / 'service-calls').read_text(), 'restart\n')

    def test_legacy_dns_in_relay_is_migrated_with_main(self):
        self.relay['dns'] = self.main.pop('dns')
        self.write()
        self.run_shell('add')
        self.assert_migrated()

    def test_old_outbound_rule_with_typed_dns_is_migrated(self):
        self.main['dns']['servers'][0].update(type='local')
        del self.main['dns']['servers'][0]['address']
        self.write()
        self.run_shell('edit')
        self.assert_migrated()

    def test_intermediate_config_check_uses_migrated_candidates(self):
        self.write()
        self.run_shell('edit')
        self.assert_migrated()
        self.assertEqual(self.read('config.json')['log']['level'], 'error')

    def test_modern_dns_and_routes_keep_their_values(self):
        self.main['dns'] = {'servers': [{'tag': 'dns-local', 'type': 'local'}], 'strategy': 'prefer_ipv4'}
        self.main['route']['default_domain_resolver'] = 'dns-local'
        self.write()
        self.run_shell('add')
        self.assertEqual(self.read('config.json')['dns'], self.main['dns'])
        self.assertEqual(self.read('config.json')['route'], self.main['route'])
        self.assertEqual(self.read('relay.json'), self.relay)

    def test_unsupported_custom_dns_preserves_all_files(self):
        self.main['dns']['servers'][0]['custom_dns_option'] = True
        self.write()
        before = self.snapshot()
        self.run_shell('add', success=False)
        self.assert_rolled_back(before)
        self.assertFalse((self.root / 'service-calls').exists())

    def test_core_rejection_after_conversion_preserves_all_files(self):
        self.main['unknown_config_field'] = True
        self.write()
        before = self.snapshot()
        self.run_shell('add', success=False)
        self.assert_rolled_back(before)
        self.assertFalse((self.root / 'service-calls').exists())

    def test_restart_failure_restores_dns_and_node_files(self):
        self.write()
        before = self.snapshot()
        self.run_shell('add', success=False, FAIL_RESTART='1')
        self.assert_rolled_back(before)
        self.assertEqual((self.root / 'service-calls').read_text(), 'restart\n')

    def test_operation_failure_discards_dns_migration(self):
        self.write()
        before = self.snapshot()
        self.run_shell('edit', success=False, FAIL_OPERATION='1')
        self.assert_rolled_back(before)
        self.assertFalse((self.root / 'service-calls').exists())

    def test_existing_node_and_client_fields_are_preserved(self):
        node = {'type': 'vless', 'tag': 'existing', 'listen': '127.0.0.1', 'listen_port': 10002,
                'users': [{'uuid': '8086a8fa-62fd-44be-9177-1b2f35333a27', 'flow': ''}],
                'tls': {'enabled': False}}
        proxy = {'name': 'existing', 'type': 'vless', 'server': '127.0.0.1', 'port': 10002,
                 'uuid': node['users'][0]['uuid'], 'tls': False, 'network': 'tcp'}
        self.main['inbounds'].append(node)
        self.client['proxies'].append(proxy)
        self.metadata['existing'] = {'name': 'existing', 'clientName': 'existing', 'yaml': True}
        self.write()
        self.run_shell('add')
        self.assert_migrated()
        self.assertEqual(self.read('config.json')['inbounds'][0], node)
        self.assertEqual(self.read('clash.yaml')['proxies'][0], proxy)
        self.assertEqual(self.read('metadata.json')['existing'], self.metadata['existing'])


if __name__ == '__main__':
    unittest.main()
