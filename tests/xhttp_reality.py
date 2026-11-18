#!/usr/bin/env python3
"""Check XHTTP Reality exports, routing and node lifecycle in isolation."""
import json
import os
import subprocess
import unittest
import xhttp_xmux

HARNESS = xhttp_xmux.HARNESS

REALITY_HARNESS = HARNESS.replace(
    'case "$ACTION" in', r'''
SNI_ROUTER_PUBLIC_PORT=443
SNI_ROUTER_STATE_FILE="$WORK/router.json"
XRAY_BIN="${TEST_REALITY_KEYGEN:-$WORK/xray-fixture}"
_select_reality_sni() {
    SELECTED_REALITY_SNI=own.example.com
    SELECTED_REALITY_HANDSHAKE_SERVER="${TARGET_HOST:-127.0.0.1}"
    SELECTED_REALITY_HANDSHAKE_PORT=8443
}
_sni_router_prepare() { return 0; }
_sni_router_assert_sni_available() { return 0; }
_sni_router_register_reality() {
    jq -n --arg tag "$2" --arg sni "$3" --argjson port "$4" '{reality:{tag:$tag,sni:$sni,backend_port:$port}}' > "$SNI_ROUTER_STATE_FILE"
}
_sni_router_remove_reality() { echo '{"reality":null}' > "$SNI_ROUTER_STATE_FILE"; }
_remove_node_from_yaml() { echo '{"proxies":[]}' > "$CLASH_YAML_FILE"; }
case "$ACTION" in''').replace(
    'add) _add_vless_xhttp_tls_impl', 'add) _add_vless_xhttp_reality_impl').replace(
    'modify) _modify_xhttp_port xhttp-in-test 9443', 'modify) _modify_xhttp_port xhttp-in-test "${NEW_PORT:-9443}"').replace(
    'esac\n', '    delete) _delete_xhttp_node xhttp-in-test ;;\nesac\n')


class RealityTests(xhttp_xmux.XMUXTests):
    def setUp(self):
        super().setUp()
        (self.root / 'harness.sh').write_text(REALITY_HARNESS)
        (self.root / 'router.json').write_text('{"reality":null}')
        binary = self.root / 'xray-fixture'
        binary.write_text('''#!/bin/bash
case "$1" in
 uuid) echo 80c7a55c-8951-423f-a420-2af7d59d19e6 ;;
 x25519) printf 'PrivateKey: test-private-key\\nPassword (PublicKey): test-public-key\\n' ;;
esac
''')
        binary.chmod(0o700)

    def add(self, concurrency='', port=8444, extra=''):
        return self.run_shell('add', f'\n{port}\n{extra}/test/\nXHTTP test\n{concurrency}\n3\n')

    def link_query(self):
        query = super().link_query()
        self.assertEqual(query['support-x25519mlkem768'], ['true'])
        return query

    def test_custom_concurrency_is_exported(self):
        self.add('8')
        self.assert_concurrency('8')
        proxy = self.read_json('client.json')['proxies'][0]
        self.assertTrue(proxy['reality-opts']['support-x25519mlkem768'])
        self.assertNotIn('flow', proxy)
        self.assertEqual(proxy['servername'], 'own.example.com')
        stream = self.read_json('xray.json')['inbounds'][0]['streamSettings']
        self.assertEqual(stream['security'], 'reality')
        self.assertEqual(stream['realitySettings']['target'], '127.0.0.1:8443')
        self.assertEqual(stream['realitySettings']['minClientVer'], '1.8.2')
        self.assertEqual(stream['realitySettings']['serverNames'], ['own.example.com'])
        self.assertEqual(self.link_query()['security'], ['reality'])
        self.assertEqual(self.link_query()['pbk'], ['test-public-key'])
        self.assertNotIn('flow', self.link_query())

    def test_target_port_cannot_loop_into_listener(self):
        result = self.run_shell('add', '\n8443\n/test/\nXHTTP test\n1\n3\n', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read_json('xray.json')['inbounds'], [])

    def test_ipv6_target_is_bracketed(self):
        harness = self.root / 'harness.sh'
        harness.write_text(harness.read_text().replace('${TARGET_HOST:-127.0.0.1}', '2001:db8::1'))
        self.add()
        settings = self.read_json('xray.json')['inbounds'][0]['streamSettings']
        self.assertEqual(settings['realitySettings']['target'], '[2001:db8::1]:8443')

    def test_switch_direct_to_shared(self):
        self.add()
        harness = self.root / 'harness.sh'
        harness.write_text(harness.read_text().replace('${NEW_PORT:-9443}', '443'))
        self.run_shell('modify', 'y\n')
        self.assertEqual(self.read_json('xray.json')['inbounds'][0]['listen'], '127.0.0.1')
        self.assertEqual(self.read_json('metadata.json')['xhttp-in-test']['publicPort'], 443)
        self.assertEqual(self.read_json('client.json')['proxies'][0]['port'], 443)
        self.assertTrue(self.read_json('client.json')['proxies'][0]['reality-opts']['support-x25519mlkem768'])

    def test_delete_direct_node(self):
        self.add()
        self.run_shell('delete')
        self.assertEqual(self.read_json('xray.json')['inbounds'], [])
        self.assertEqual(self.read_json('metadata.json'), {})
        self.assertEqual(self.read_json('client.json')['proxies'], [])

    def test_shared_entry_and_switch_to_direct(self):
        self.add(port=443, extra='y\n')
        self.assertEqual(self.read_json('xray.json')['inbounds'][0]['listen'], '127.0.0.1')
        self.assertEqual(self.read_json('router.json')['reality']['tag'], 'xhttp-in-test')
        self.run_shell('modify')
        self.assertIsNone(self.read_json('router.json')['reality'])
        self.assertEqual(self.read_json('xray.json')['inbounds'][0]['port'], 9443)
        self.assertEqual(self.read_json('xray.json')['inbounds'][0]['listen'], '::')
        self.assertEqual(self.link_query()['security'], ['reality'])
        self.assertTrue(self.read_json('client.json')['proxies'][0]['reality-opts']['support-x25519mlkem768'])

    def test_shared_delete(self):
        self.add(port=443, extra='y\n')
        self.run_shell('delete')
        self.assertIsNone(self.read_json('router.json')['reality'])
        self.assertEqual(self.read_json('xray.json')['inbounds'], [])

    def test_shared_entry_conflict(self):
        (self.root / 'router.json').write_text('{"reality":{"tag":"other"}}')
        result = self.run_shell('add', '\n443\ny\n/test/\nXHTTP test\n1\n3\n', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read_json('xray.json')['inbounds'], [])

    def test_port_change_preserves_selected_concurrency(self):
        self.add('16')
        self.run_shell('modify')
        self.assert_concurrency('16')
        self.assertEqual(self.read_json('xray.json')['inbounds'][0]['port'], 9443)
        self.assertTrue(self.read_json('client.json')['proxies'][0]['reality-opts']['support-x25519mlkem768'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
