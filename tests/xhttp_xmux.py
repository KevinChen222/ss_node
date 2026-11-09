#!/usr/bin/env python3
"""Check XHTTP concurrency input, client export and port changes in isolation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
source "$REPO/sb.sh"
METADATA_FILE="$WORK/metadata.json"
XRAY_CONFIG_FILE="$WORK/xray.json"
CLASH_YAML_FILE="$WORK/client.json"
NGINX_CONF_DIR="$WORK/conf.d"
NODE_TX_DIR="$WORK/transaction"
server_ip=203.0.113.1
_node_tx_begin() { mkdir -p "$NODE_TX_DIR"; }
_assert_node_name_free() { return 0; }
_ensure_local_origin_dependencies() { return 0; }
_xhttp_prepare_domain() { return 0; }
_xhttp_prepare_certificate() { return 0; }
_install_xray() { return 0; }
_check_port_occupied() { return 1; }
_check_port_conflict() { return 1; }
_sni_router_allocate_backend_port() { echo 10080; }
_new_node_tag() { echo xhttp-in-test; }
_xhttp_snapshot_nginx() { return 0; }
_install_managed_nginx_config() { cp -- "$1" "$2"; }
_atomic_modify_json() {
    jq "$2" "$1" > "$1.tmp" && mv -- "$1.tmp" "$1"
}
_add_node_to_yaml() {
    jq -n --argjson proxy "$1" '{proxies:[$proxy]}' > "$CLASH_YAML_FILE" || return 1
    _atomic_modify_json "$METADATA_FILE" '.["xhttp-in-test"].clientName="XHTTP test"'
}
_get_proxy_field() {
    jq -r --arg name "$1" '.proxies[] | select(.name == $name) | '"$2" "$CLASH_YAML_FILE"
}
_atomic_modify_yaml() {
    _atomic_modify_json "$1" "${2//env\(PROXY_NAME\)/env.PROXY_NAME}"
}
case "$ACTION" in
    add) _add_vless_xhttp_tls_impl ;;
    modify) _modify_xhttp_port xhttp-in-test 9443 ;;
esac
'''


class XMUXTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-xmux-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'conf.d').mkdir()
        (self.root / 'metadata.json').write_text('{}')
        (self.root / 'xray.json').write_text('{"inbounds":[]}')
        (self.root / 'harness.sh').write_text(HARNESS)

    def run_shell(self, action, answers='', check=True):
        result = subprocess.run(['bash', str(self.root / 'harness.sh')], input=answers,
                                env=dict(os.environ, REPO=str(REPO), WORK=str(self.root), ACTION=action),
                                text=True, capture_output=True, timeout=10)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def add(self, concurrency=''):
        return self.run_shell('add', '\nxhttp.test\n8443\n/test/\nXHTTP test\n' + concurrency + '\n')

    def read_json(self, name):
        return json.loads((self.root / name).read_text())

    def link_query(self):
        metadata = self.read_json('metadata.json')['xhttp-in-test']
        return parse_qs(urlsplit(metadata['share_link']).query)

    def assert_concurrency(self, expected):
        proxy = self.read_json('client.json')['proxies'][0]
        reuse = proxy['xhttp-opts']['reuse-settings']
        self.assertEqual(reuse, {'max-concurrency': expected, 'h-max-reusable-secs': '1800'})
        query = self.link_query()
        self.assertEqual(json.loads(query['extra'][0]),
                         {'xmux': {'maxConcurrency': expected, 'hMaxReusableSecs': 1800}})
        self.assertEqual(query['mode'], ['stream-up'])
        self.assertEqual(query['alpn'], ['h2'])
        self.assertEqual(query['path'], ['/test/'])
        self.assertNotIn('smux', proxy)

    def test_default_is_one(self):
        self.add()
        self.assert_concurrency('1')

    def test_custom_concurrency_is_exported(self):
        self.add('8')
        self.assert_concurrency('8')
        settings = self.read_json('xray.json')['inbounds'][0]['streamSettings']
        self.assertEqual(settings['xhttpSettings'],
                         {'path': '/test/', 'host': 'xhttp.test', 'mode': 'stream-up'})

    def test_leading_zeros_are_decimal(self):
        self.add('00008')
        self.assert_concurrency('8')

    def test_invalid_input_reprompts(self):
        result = self.add('0\n-1\n1.5\nabc\n1-4\n2147483648\n999999999999999999999\n4')
        self.assertEqual(result.stderr.count('XMUX 并发数必须'), 7)
        self.assert_concurrency('4')

    def test_eof_before_selection_writes_no_node(self):
        result = self.run_shell('add', '\nxhttp.test\n8443\n/test/\nXHTTP test\n', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read_json('metadata.json'), {})
        self.assertEqual(self.read_json('xray.json'), {'inbounds': []})
        self.assertFalse((self.root / 'transaction').exists())

    def test_port_change_preserves_selected_concurrency(self):
        self.add('4')
        self.run_shell('modify')
        self.assert_concurrency('4')
        self.assertEqual(self.read_json('client.json')['proxies'][0]['port'], 9443)
        metadata = self.read_json('metadata.json')['xhttp-in-test']
        self.assertEqual(urlsplit(metadata['share_link']).port, 9443)

    def test_port_change_of_node_without_xmux_keeps_it_absent(self):
        self.add()
        client = self.read_json('client.json')
        del client['proxies'][0]['xhttp-opts']['reuse-settings']
        (self.root / 'client.json').write_text(json.dumps(client))
        self.run_shell('modify')
        self.assertNotIn('extra', self.link_query())
        self.assertNotIn('reuse-settings', self.read_json('client.json')['proxies'][0]['xhttp-opts'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
