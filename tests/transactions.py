#!/usr/bin/env python3
"""Exercise Xray node transactions with real flock and isolated service fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR=$WORK CONFIG_FILE=$WORK/config.json METADATA_FILE=$WORK/metadata.json
CLASH_YAML_FILE=$WORK/clash.yaml XRAY_CONFIG_FILE=$WORK/xray.json XRAY_BIN=$WORK/xray
SNI_ROUTER_STATE_DIR=$WORK SNI_ROUTER_STATE_FILE=$WORK/state.json
SNI_ROUTER_LOCK_FILE=$WORK/router.lock SNI_ROUTER_HAPROXY_CONF=$WORK/haproxy.cfg
NGINX_CONF_DIR=$WORK NGINX_CERT_DIR=$WORK/certs PROXYALL_WRITE_LOCK_FILE=$WORK/lock
XRAY_ONLY=true NODE_UI=true INIT_SYSTEM=direct YQ_BINARY=fixture_yq server_ip=127.0.0.1
fixture_yq() {
    local expr="${@: -2:1}"
    expr=${expr//strenv\(PROXY_NAME\)/env.PROXY_NAME}
    expr=${expr//.proxy-groups/.[\"proxy-groups\"]}
    jq "$expr" "${@: -1}"
}
assert_locked() {
    [ "${NODE_TX_STARTED:-0}" = 1 ] && [ /dev/fd/8 -ef "$WORK/lock" ] &&
        ! flock -n "$WORK/lock" true
}
_install_xray() { assert_locked; }
_xray_running() { return 1; }
_xray_service() { assert_locked && printf '%s\n' "$*" >> "$WORK/restarts"; }
_check_port_occupied() { return 1; }
_probe_reality_target() { return 0; }
_ensure_local_origin_dependencies() { assert_locked; }
_xhttp_prepare_domain() { assert_locked; }
_xhttp_prepare_certificate() { assert_locked; }
_prepare_local_reality_origin() { assert_locked; }
_install_managed_nginx_config() { assert_locked && cp "$1" "$2"; }
_sni_router_require_systemd() { assert_locked; }
_sni_router_apply() { [ /dev/fd/8 -ef "$WORK/lock" ]; }
_sb_reload_or_start_nginx() { return 0; }
systemctl() { return 0; }
nginx() { echo 'nginx version: nginx/1.26.0' >&2; }
if [ -n "$WAIT_PROMPT" ]; then
    definition=$(declare -f _node_read)
    eval "${definition/_node_read /fixture_read }"
    _node_read() {
        if [[ "$*" == *"$WAIT_PROMPT"* ]]; then touch "$WORK/prompt"; fi
        fixture_read "$@"
    }
fi
case "$ACTION" in
    native) _node_operation _xray_native_add "$VARIANT" ;;
    vision) _node_operation _add_vless_reality_impl ;;
    xhttp-reality) _node_operation _add_vless_xhttp_reality_impl ;;
    xhttp-tls) _node_operation _add_vless_xhttp_tls_impl ;;
    edit) _node_operation _xray_edit_field test "$VARIANT" "$(jq -c .test "$METADATA_FILE")" ;;
    relay) _xray_manage_node relay ;;
    delete|port) _xray_manage_node "$ACTION" ;;
    candidate)
        apply() {
            local original_metadata="$METADATA_FILE" original_clients="$CLASH_YAML_FILE"
            _atomic_modify_json "$original_metadata" '.fixture={}' || return 1
            _atomic_modify_yaml "$original_clients" '.fixture=true' || return 1
            _node_operation _xray_route_node test "$WORK/outbound.json" || return 1
            jq -e 'has("fixture") | not' "$original_metadata" "$original_clients" >/dev/null &&
                jq -e 'has("routing") | not' "$XRAY_CONFIG_FILE" >/dev/null &&
                jq -e '.routing.rules[0].inboundTag == ["test"]' "$(_node_candidate_path "$XRAY_CONFIG_FILE")" >/dev/null
        }
        _node_operation apply ;;
    batch)
        batch() {
            local BATCH_MODE=true BATCH_PORT port BATCH_SNI=example.test BATCH_IP=127.0.0.1
            local BATCH_VISION_PROFILE=none BATCH_REALITY_HANDSHAKE_SERVER=127.0.0.1
            local BATCH_REALITY_HANDSHAKE_PORT=9444
            for port in $VARIANT; do
                BATCH_PORT=$port _add_vless_reality || return 1
            done
        }
        _node_operation batch ;;
    writer)
        update() { _atomic_modify_json "$METADATA_FILE" '.test.writer=1'; }
        _node_operation update ;;
esac
'''


class Transactions(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        core = self.root / 'xray'
        core.write_text('''#!/usr/bin/env bash
case "$1" in
    uuid) echo 80c7a55c-8951-423f-a420-2af7d59d19e6 ;;
    x25519) printf '%s\\n' 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 'PublicKey: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' ;;
    run) exit 0 ;;
    *) exit 1 ;;
esac
''')
        core.chmod(0o700)
        self.files = ('metadata.json', 'xray.json', 'clash.yaml', 'state.json')

    def seed(self, native=False):
        link = 'vless://uuid@original.test:443?security=reality&type=xhttp#Test'
        tag, name, public, backend = 'test', 'Test', 443, 10443
        kind, security, network = 'vless-xhttp-reality', 'reality', 'xhttp'
        if native:
            kind, security, network = 'native-vless', 'none', 'raw'
            public = backend
            link = 'vless://uuid@original.test:10443?security=none&type=tcp#Test'
        self.store('metadata.json', {tag: {'core': 'xray', 'name': name, 'clientName': name,
                                          'type': kind, 'publicPort': public, 'backendPort': backend,
                                          'server_name': 'old.test' if not native else '', 'share_link': link}})
        self.store('xray.json', {'inbounds': [{'tag': tag, 'port': backend, 'protocol': 'vless',
                                             'streamSettings': {'security': security, 'network': network}}],
                                 'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}]})
        self.store('clash.yaml', {'proxies': [{'name': name, 'port': public, 'server': 'original.test'}],
                                 'proxy-groups': [{'name': '节点选择', 'proxies': ['DIRECT', name]}]})

    def store(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def load(self, name):
        return json.loads((self.root / name).read_text())

    def snapshot(self):
        return {name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns)
                for name in self.files for p in [self.root / name] if p.exists()}

    def env(self, action, variant='', prompt=''):
        return dict(os.environ, REPO=str(REPO), WORK=str(self.root), ACTION=action, VARIANT=str(variant), WAIT_PROMPT=prompt)

    def shell(self, action, data='', variant='', status=0):
        result = subprocess.run(['bash', '-c', HARNESS], input=data, text=True, capture_output=True,
                                timeout=10, env=self.env(action, variant))
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return result

    def assert_restarts(self, count):
        path = self.root / 'restarts'
        self.assertEqual(path.read_text().splitlines() if path.exists() else [], ['restart'] * count)
        self.assertFalse(list(self.root.glob('.node-op.*')))

    def test_first_create_for_all_current_protocols(self):
        for action, variant, answers, kind in (
            ('native', '1', '127.0.0.1\n8443\nNew\n3\n', 'native-vless'),
            ('native', '2', '127.0.0.1\n8443\nNew\n', 'native-shadowsocks'),
            ('vision', '', '127.0.0.1\ny\n2\nexample.test\n8443\nNew\n3\n', 'vless-vision-reality'),
            ('xhttp-reality', '', '127.0.0.1\ny\n2\nexample.test\n8443\n/test/\nNew\n1\n3\n', 'vless-xhttp-reality'),
            ('xhttp-tls', '', '127.0.0.1\nexample.test\n8443\n/test/\nNew\n1\n3\n', 'vless-xhttp'),
        ):
            with self.subTest(kind=kind):
                for name in (*self.files, 'lock', 'restarts'):
                    (self.root / name).unlink(missing_ok=True)
                result = self.shell(action, answers, variant)
                self.assertFalse((self.root / 'config.json').exists())
                self.assertFalse((self.root / 'relay.json').exists())
                (tag, meta), = self.load('metadata.json').items()
                inbound, = self.load('xray.json')['inbounds']
                client, = self.load('clash.yaml')['proxies']
                self.assertEqual((inbound['tag'], inbound['port']), (tag, meta['backendPort']))
                self.assertEqual((meta['type'], client['name'], client['port']), (kind, 'New', 8443))
                self.assertIn(meta['share_link'], result.stdout)
                self.assert_restarts(1)

    def test_confirmed_sni_edit_locks_before_origin_and_updates_all_records(self):
        self.seed()
        result = self.shell('edit', 'y\ny\n1\nnew.test\ny\n', 'sni')
        meta = self.load('metadata.json')['test']
        stream = self.load('xray.json')['inbounds'][0]['streamSettings']
        self.assertEqual(meta['server_name'], 'new.test')
        self.assertEqual(stream['realitySettings']['serverNames'], ['new.test'])
        self.assertEqual(self.load('clash.yaml')['proxies'][0]['servername'], 'new.test')
        self.assertIn(meta['share_link'], result.stdout)
        self.assert_restarts(1)

    def test_native_port_and_delete_on_xray_only_host(self):
        self.seed(native=True)
        self.store('config.json', {'inbounds': [{'listen_port': 9443}]})
        self.shell('port', '1\n9443\n', status=1)
        self.assert_restarts(0)
        (self.root / 'config.json').unlink()
        self.shell('port', '1\n9443\n')
        self.assertEqual(self.load('xray.json')['inbounds'][0]['port'], 9443)
        self.assertEqual(self.load('clash.yaml')['proxies'][0]['port'], 9443)
        self.shell('delete', '1\ny\n')
        self.assertEqual(self.load('xray.json')['inbounds'], [])
        self.assertEqual(self.load('metadata.json'), {})
        self.assertEqual(self.load('clash.yaml')['proxies'], [])
        self.assert_restarts(2)

    def test_first_write_resolves_original_paths_and_nested_relay_joins_transaction(self):
        self.seed()
        self.store('outbound.json', {'protocol': 'freedom'})
        self.shell('candidate')
        self.assertEqual(self.load('metadata.json')['fixture'], {})
        self.assertTrue(self.load('clash.yaml')['fixture'])
        self.assertEqual(self.load('xray.json')['routing']['rules'][0]['outboundTag'], 'pa-relay-test')
        self.assert_restarts(1)

    def test_batch_success_publishes_once(self):
        result = self.shell('batch', variant='443 8443')
        self.assertEqual(len(self.load('xray.json')['inbounds']), 2)
        self.assertEqual(self.load('state.json')['reality']['sni'], 'example.test')
        self.assertEqual(result.stdout.count('vless://'), 2)
        self.assert_restarts(1)

    def test_batch_conflict_discards_candidates_and_router_state(self):
        self.seed()
        before = self.snapshot()
        result = self.shell('batch', variant='443 10443', status=1)
        self.assertIn('端口 10443 已被现有节点配置占用', result.stderr)
        self.assertNotIn('vless://', result.stdout)
        self.assertEqual(self.snapshot(), before)
        self.assert_restarts(0)

    def test_waiting_add_and_edit_allow_another_writer_then_reject_stale_input(self):
        for action, variant, prefix, suffix, prompt in (
            ('native', '1', '127.0.0.1\n8443\nNew\n', '3\n', '请选择 [0-3]'),
            ('edit', 'name', 'New\n', 'y\n', '保存修改并重启'),
        ):
            with self.subTest(action=action):
                self.seed()
                for name in ('prompt', 'lock', 'restarts'):
                    (self.root / name).unlink(missing_ok=True)
                marker = self.root / 'prompt'
                with subprocess.Popen(['bash', '-c', HARNESS], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, env=self.env(action, variant, prompt)) as waiting:
                    try:
                        waiting.stdin.write(prefix)
                        waiting.stdin.flush()
                        deadline = time.monotonic() + 5
                        while not marker.exists() and waiting.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(marker.exists(), 'did not reach the final input prompt')
                        self.assertFalse((self.root / 'lock').exists())
                        self.shell('writer')
                        before = self.snapshot()
                        out, err = waiting.communicate(suffix, timeout=5)
                        self.assertEqual(waiting.returncode, 1, out + err)
                        self.assertIn('输入期间配置已变化', err)
                        self.assertEqual(self.snapshot(), before)
                        self.assertEqual(self.load('metadata.json')['test']['writer'], 1)
                        self.assert_restarts(1)
                    finally:
                        if waiting.poll() is None:
                            waiting.kill()


if __name__ == '__main__':
    unittest.main()
