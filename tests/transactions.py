#!/usr/bin/env python3
"""Exercise dual-core (Sing-box primary + Xray XHTTP) node transactions with real flock."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlsplit

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR=$WORK CONFIG_FILE=$WORK/config.json METADATA_FILE=$WORK/metadata.json
CLASH_YAML_FILE=$WORK/clash.yaml XRAY_CONFIG_FILE=$WORK/xray.json
NODE_RELAY_FILE=$WORK/relay.json NODE_RELAY_LINKS_FILE=$WORK/relay_links.json
SINGBOX_BIN=$WORK/sing-box XRAY_BIN=$WORK/xray
SNI_ROUTER_STATE_DIR=$WORK SNI_ROUTER_STATE_FILE=$WORK/state.json
SNI_ROUTER_LOCK_FILE=$WORK/router.lock SNI_ROUTER_HAPROXY_CONF=$WORK/haproxy.cfg
NGINX_CONF_DIR=$WORK NGINX_CERT_DIR=$WORK/certs NGINX_BACKUP_DIR=$WORK/backup
PROXYALL_WRITE_LOCK_FILE=$WORK/lock NODE_UI=true INIT_SYSTEM=direct
YQ_BINARY=fixture_yq server_ip=127.0.0.1
mkdir -p "$NGINX_BACKUP_DIR" "$NGINX_CERT_DIR"
fixture_yq() {
    local expr="${@: -2:1}"
    expr=${expr//strenv\(PROXY_NAME\)/env.PROXY_NAME}
    expr=${expr//strenv\(OLD_NAME\)/env.OLD_NAME}
    expr=${expr//strenv\(NEW_NAME\)/env.NEW_NAME}
    expr=${expr//env\(NEW_PORT_VAL\)/env.NEW_PORT_VAL}
    expr=${expr//.proxy-groups/.[\"proxy-groups\"]}
    jq "$expr" "${@: -1}"
}
_get_proxy_field() {
    jq -r --arg name "$1" '.proxies[] | select(.name == $name) | '"$2" "$CLASH_YAML_FILE" 2>/dev/null | head -n 1
}
assert_locked() {
    [ "${NODE_TX_STARTED:-0}" = 1 ] && [ /dev/fd/8 -ef "$WORK/lock" ] &&
        ! flock -n "$WORK/lock" true
}
_install_xray() { assert_locked; }
_xray_running() { return 1; }
_is_pid_file_running_cmd() { return 1; }
_manage_service() {
    assert_locked || return 1
    printf '%s\n' "$*" >> "$WORK/restarts"
    [ "${FAIL_RESTART:-0}" != 1 ]
}
_manage_singbox_service_impl() { printf 'sb:%s\n' "$*" >> "$WORK/rollback-services"; return 0; }
_xray_service() { printf 'xray:%s\n' "$*" >> "$WORK/rollback-services"; return 0; }
_check_port_occupied() { return 1; }
_probe_reality_target() { return 0; }
_ensure_local_origin_dependencies() { assert_locked; }
_xhttp_prepare_domain() { assert_locked; }
_xhttp_prepare_certificate() { assert_locked; }
_prepare_local_reality_origin() {
    assert_locked || return 1
    printf '%s\n' "$1" >> "$WORK/origins"
}
_install_managed_nginx_config() { assert_locked && cp "$1" "$2"; }
_sni_router_require_systemd() { assert_locked; }
_sni_router_apply() { [ /dev/fd/8 -ef "$WORK/lock" ]; }
_sb_reload_or_start_nginx() { return 0; }
systemctl() { return 0; }
nginx() {
    if [ "$1" = -T ]; then return 0; fi
    echo 'nginx version: nginx/1.26.0' >&2
}
if [ -n "$WAIT_PROMPT" ]; then
    definition=$(declare -f _node_read)
    eval "${definition/_node_read /fixture_read }"
    _node_read() {
        if [[ "$*" == *"$WAIT_PROMPT"* ]]; then touch "$WORK/prompt"; fi
        fixture_read "$@"
    }
fi
case "$ACTION" in
    vision) _node_operation _add_vless_reality_impl ;;
    anytls) _node_operation _add_anytls_impl ;;
    xhttp-reality) _node_operation _add_vless_xhttp_reality_impl ;;
    xhttp-tls) _node_operation _add_vless_xhttp_tls_impl ;;
    edit) _node_operation _xray_edit_field "$TAG" "$VARIANT" "$(jq -c --arg t "$TAG" '.[$t]' "$METADATA_FILE")" ;;
    edit-menu) _edit_node_menu ;;
    delete) _node_operation _delete_node_impl ;;
    port) _node_operation _modify_port_impl ;;
    view) _view_nodes ;;
    enc-editable) _xray_enc_editable "$VARIANT" ;;
    cert-match) _cert_matches_hostname "$CERT_FILE" "$VARIANT" ;;
    anytls-link) _anytls_share_link "$VARIANT" "$CERT_FILE" ;;
    batch-cmd) _batch_create_nodes "$VARIANT" ;;
    uninstall)
        SELF_SCRIPT_PATH="$WORK/sb"
        SERVICE_FILE="$WORK/systemd/sing-box.service"
        SYSTEMD_UNIT_DIR="$WORK/systemd"
        LOGROTATE_DIR="$WORK/logrotate.d"
        LOG_FILE="$WORK/sb.log"
        XRAY_LOG_FILE="$WORK/xray.log"
        ARGO_LOG_FILE="$WORK/argo.log"
        REALITL_SCANNER_DIR="$WORK/scanner"
        REALITL_SCANNER_BIN="$WORK/scanner/RealiTLScanner"
        REALITL_SCANNER_MARKER="$WORK/scanner/.managed"
        GO_TOOLCHAIN_DIR="$WORK/go-toolchain"
        GO_TOOLCHAIN_MARKER="$WORK/go-toolchain/.managed"
        mkdir -p "$SYSTEMD_UNIT_DIR" "$LOGROTATE_DIR"
        _remove_time_sync() { :; }
        _remove_nftables_rules() { :; }
        _disable_argo_watchdog() { :; }
        _stop_all_argo_tunnels() { :; }
        crontab() { return 0; }
        rm() {
            local -a filtered=()
            local arg
            for arg in "$@"; do
                case "$arg" in
                    /usr/local/bin/sb) continue ;;
                    -*) filtered+=("$arg") ;;
                    "$WORK"/*|"$WORK") filtered+=("$arg") ;;
                    *) echo "refusing rm outside WORK: $arg" >&2; return 1 ;;
                esac
            done
            local has_path=0
            for arg in "${filtered[@]}"; do [[ "$arg" == -* ]] || has_path=1; done
            [ "$has_path" = 0 ] || command rm "${filtered[@]}"
        }
        _uninstall_locked ;;
    batch)
        batch() {
            local BATCH_MODE=true BATCH_PORT port BATCH_SNI=example.test BATCH_IP=127.0.0.1
            local BATCH_REALITY_HANDSHAKE_SERVER=127.0.0.1 BATCH_REALITY_HANDSHAKE_PORT=9444
            for port in $VARIANT; do
                BATCH_PORT=$port _add_vless_reality || return 1
            done
        }
        _node_operation batch ;;
    writer)
        update() { _atomic_modify_json "$METADATA_FILE" '.test.writer=1'; }
        _node_operation update ;;
    *) exit 3 ;;
esac
'''


class Transactions(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix='proxyall-tx-test-')
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        sb = self.root / 'sing-box'
        sb.write_text('''#!/usr/bin/env bash
case "$1" in
    generate)
        case "$2" in
            uuid) echo 80c7a55c-8951-423f-a420-2af7d59d19e6 ;;
            reality-keypair)
                printf 'PrivateKey: SB_PRIV_KEY_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n'
                printf 'PublicKey: SB_PUB_KEY_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\\n' ;;
            rand) echo 0123456789abcdef ;;
            *) exit 1 ;;
        esac ;;
    check) exit 0 ;;
    version) echo 'sing-box version 1.12.0' ;;
    *) exit 1 ;;
esac
''')
        sb.chmod(0o700)
        xray = self.root / 'xray'
        mlkem_dec = 'mlkem768x25519plus.native.600s.' + 'A' * 64
        mlkem_enc = 'mlkem768x25519plus.native.0rtt.' + 'B' * 1580
        x25519_dec = 'mlkem768x25519plus.native.600s.' + 'C' * 43
        x25519_enc = 'mlkem768x25519plus.native.0rtt.' + 'D' * 43
        xray.write_text(f'''#!/usr/bin/env bash
case "$1" in
    uuid) echo 90c7a55c-8951-423f-a420-2af7d59d19e6 ;;
    x25519)
        printf 'PrivateKey: XRAY_PRIV_KEY_AAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n'
        printf 'Password (PublicKey): XRAY_PUB_KEY_BBBBBBBBBBBBBBBBBBBBBBBBBB\\n' ;;
    vlessenc)
        cat <<'EOF'
Authentication: ML-KEM-768, Post-Quantum
"decryption": "{mlkem_dec}"
"encryption": "{mlkem_enc}"
Authentication: X25519, not Post-Quantum
"decryption": "{x25519_dec}"
"encryption": "{x25519_enc}"
EOF
        ;;
    run) exit 0 ;;
    version) echo 'Xray 25.10.15' ;;
    *) exit 1 ;;
esac
''')
        xray.chmod(0o700)
        self.mlkem_dec = mlkem_dec
        self.mlkem_enc = mlkem_enc
        self.x25519_dec = x25519_dec
        self.x25519_enc = x25519_enc
        self.files = ('config.json', 'metadata.json', 'xray.json', 'clash.yaml', 'state.json')

    def seed_xhttp(self):
        link = 'vless://90c7a55c-8951-423f-a420-2af7d59d19e6@original.test:443?encryption=none&security=reality&type=xhttp&mode=stream-up&path=%2Ftest%2F&host=old.test&sni=old.test&alpn=h2&fp=chrome&pbk=XRAY_PUB&sid=aabbccdd&support-x25519mlkem768=true&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%221%22%2C%22hMaxReusableSecs%22%3A1800%7D%7D#Test'
        self.store('config.json', {'inbounds': [], 'outbounds': [{'type': 'direct', 'tag': 'direct'}]})
        self.store('metadata.json', {'test': {
            'core': 'xray', 'name': 'Test', 'clientName': 'Test',
            'type': 'vless-xhttp-reality', 'publicPort': 443, 'backendPort': 10443,
            'server_name': 'old.test', 'path': '/test/', 'publicKey': 'XRAY_PUB',
            'shortId': 'aabbccdd', 'handshakeServer': '127.0.0.1', 'handshakePort': 9444,
            'share_link': link,
        }})
        self.store('xray.json', {
            'inbounds': [{'tag': 'test', 'port': 10443, 'listen': '127.0.0.1', 'protocol': 'vless',
                          'settings': {'clients': [{'id': '90c7a55c-8951-423f-a420-2af7d59d19e6'}],
                                       'decryption': 'none'},
                          'streamSettings': {'security': 'reality', 'network': 'xhttp',
                                             'realitySettings': {'target': '127.0.0.1:9444',
                                                                 'serverNames': ['old.test'],
                                                                 'privateKey': 'XRAY_PRIV',
                                                                 'shortIds': ['aabbccdd']},
                                             'xhttpSettings': {'path': '/test/', 'host': 'old.test',
                                                               'mode': 'stream-up'}}}],
            'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}],
        })
        self.store('clash.yaml', {
            'proxies': [{'name': 'Test', 'type': 'vless', 'port': 443, 'server': 'original.test',
                         'uuid': '90c7a55c-8951-423f-a420-2af7d59d19e6', 'encryption': 'none',
                         'servername': 'old.test',
                         'xhttp-opts': {'path': '/test/', 'host': 'old.test', 'mode': 'stream-up',
                                        'reuse-settings': {'max-concurrency': '1',
                                                           'h-max-reusable-secs': '1800'}}}],
            'proxy-groups': [{'name': '节点选择', 'proxies': ['DIRECT', 'Test']}],
        })

    def store(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def load(self, name):
        return json.loads((self.root / name).read_text())

    def snapshot(self):
        return {name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns)
                for name in self.files for p in [self.root / name] if p.exists()}

    def env(self, action, variant='', prompt='', tag='test', **extra):
        return dict(os.environ, REPO=str(REPO), WORK=str(self.root), ACTION=action,
                    VARIANT=str(variant), WAIT_PROMPT=prompt, TAG=tag, **extra)

    def shell(self, action, data='', variant='', status=0, **extra):
        result = subprocess.run(['bash', '-c', HARNESS], input=data, text=True, capture_output=True,
                                timeout=15, env=self.env(action, variant, **extra))
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return result

    def assert_restarts(self, count):
        path = self.root / 'restarts'
        self.assertEqual(path.read_text().splitlines() if path.exists() else [], ['restart'] * count)
        self.assertFalse(list(self.root.glob('.node-op.*')))

    def test_singbox_vless_vision_reality_direct_and_shared(self):
        # Direct port creation from empty install: no xray.json created, clean sing-box link.
        res = self.shell('vision', '127.0.0.1\ny\n2\nvision.test\n8443\nVisionDirect\n')
        self.assertFalse((self.root / 'xray.json').exists())
        (tag, meta), = self.load('metadata.json').items()
        inbound, = self.load('config.json')['inbounds']
        client, = self.load('clash.yaml')['proxies']
        self.assertEqual(inbound['type'], 'vless')
        self.assertEqual(inbound['tag'], tag)
        self.assertEqual(inbound['listen_port'], 8443)
        self.assertEqual(inbound['users'][0]['flow'], 'xtls-rprx-vision')
        self.assertEqual(inbound['tls']['server_name'], 'vision.test')
        self.assertTrue(inbound['tls']['reality']['enabled'])
        self.assertEqual(meta['server_name'], 'vision.test')
        self.assertEqual((meta['publicPort'], meta['backendPort']), (8443, 8443))
        self.assertTrue(client['udp'])
        self.assertEqual(client['flow'], 'xtls-rprx-vision')
        self.assertEqual(client['client-fingerprint'], 'firefox')
        self.assertNotIn('support-x25519mlkem768', client['reality-opts'])
        self.assertNotIn('encryption', client)
        q = parse_qs(urlsplit(meta['share_link']).query)
        self.assertEqual(q['security'], ['reality'])
        self.assertEqual(q['encryption'], ['none'])
        self.assertEqual(q['flow'], ['xtls-rprx-vision'])
        self.assertEqual(q['sni'], ['vision.test'])
        self.assertNotIn('support-x25519mlkem768', q)
        self.assertIn(meta['share_link'], res.stdout)
        self.assert_restarts(1)

        # Port edit on sing-box node updates config, metadata, clash.yaml, and share_link.
        self.shell('port', '1\n9443\n')
        self.assertEqual(self.load('config.json')['inbounds'][0]['listen_port'], 9443)
        self.assertEqual(self.load('clash.yaml')['proxies'][0]['port'], 9443)
        self.assertEqual(urlsplit(self.load('metadata.json')[tag]['share_link']).port, 9443)
        self.assert_restarts(2)

        # Shared 443 creation with local origin defers origin prep until locked transaction.
        res2 = self.shell('vision', '127.0.0.1\ny\n1\nown.vision.test\n443\ny\nVisionShared\n')
        self.assertEqual((self.root / 'origins').read_text().splitlines(), ['own.vision.test'])
        shared_tag, shared_meta = next((t, m) for t, m in self.load('metadata.json').items() if t != tag)
        self.assertEqual(shared_meta['frontedBy'], 'haproxy')
        self.assertEqual(shared_meta['routerRole'], 'reality-default')
        self.assertEqual(shared_meta['publicPort'], 443)
        self.assertNotEqual(shared_meta['backendPort'], 443)
        state = self.load('state.json')
        self.assertEqual(state['reality']['owner'], 'sb')
        self.assertEqual(state['reality']['tag'], shared_tag)
        self.assertEqual(state['reality']['sni'], 'own.vision.test')
        self.assertIn(shared_meta['share_link'], res2.stdout)
        self.assert_restarts(3)

        # Deleting the shared node unregisters HAProxy Reality route cleanly.
        self.shell('delete', '2\ny\n')
        self.assertIsNone(self.load('state.json')['reality'])
        self.assertEqual(list(self.load('metadata.json').keys()), [tag])
        self.assert_restarts(4)

    def test_singbox_anytls_and_anyreality_lifecycle_and_cert_checks(self):
        # Mode 1: AnyTLS TLS self-signed (cert choice 2) emits pcs fingerprint & locks before cert gen.
        res = self.shell('anytls', '1\n127.0.0.1\n8443\nany.test\nmy-secret\nAnyTLSNode\n2\n')
        (tag, meta), = self.load('metadata.json').items()
        inbound, = self.load('config.json')['inbounds']
        client, = self.load('clash.yaml')['proxies']
        self.assertEqual(inbound['type'], 'anytls')
        self.assertEqual(inbound['users'][0]['password'], 'my-secret')
        self.assertTrue(Path(meta['certificatePath']).is_file())
        self.assertTrue(Path(meta['keyPath']).is_file())
        self.assertTrue(client['skip-cert-verify'])
        self.assertTrue(client['udp'])
        self.assertEqual(client['sni'], 'any.test')
        q = parse_qs(urlsplit(meta['share_link']).query)
        self.assertEqual(q['sni'], ['any.test'])
        self.assertEqual(q['insecure'], ['1'])
        self.assertRegex(q['pcs'][0], r'^[0-9a-f]{64}$')
        self.assertEqual(client['fingerprint'], q['pcs'][0])
        self.assertIn(meta['share_link'], res.stdout)
        self.assert_restarts(1)

        # Verify 20-kevin.44 fixes: _cert_matches_hostname rejects mismatch & _anytls_share_link refuses missing cert.
        self.shell('cert-match', variant='any.test', CERT_FILE=meta['certificatePath'])
        self.shell('cert-match', variant='wrong.test', status=1, CERT_FILE=meta['certificatePath'])
        self.shell('anytls-link', variant='AnyTLSNode', status=1, CERT_FILE=str(self.root / 'missing.pem'))

        # Mode 2: Any-Reality on shared 443 with local origin deferred after lock.
        res2 = self.shell('anytls', '2\n127.0.0.1\n443\ny\ny\n1\nown.any.test\nreality-pw\nAnyRealityNode\n')
        self.assertEqual((self.root / 'origins').read_text().splitlines(), ['own.any.test'])
        r_tag, r_meta = next((t, m) for t, m in self.load('metadata.json').items() if t != tag)
        r_in = next(i for i in self.load('config.json')['inbounds'] if i['tag'] == r_tag)
        self.assertEqual(r_in['type'], 'anytls')
        self.assertTrue(r_in['tls']['reality']['enabled'])
        self.assertEqual(r_in['listen'], '127.0.0.1')
        self.assertEqual(r_meta['type'], 'any-reality')
        self.assertIs(r_meta['yaml'], False)
        self.assertEqual(r_meta['frontedBy'], 'haproxy')
        self.assertEqual(self.load('state.json')['reality']['owner'], 'sb')
        self.assertEqual(self.load('state.json')['reality']['tag'], r_tag)
        rq = parse_qs(urlsplit(r_meta['share_link']).query)
        self.assertEqual(rq['security'], ['reality'])
        self.assertEqual(rq['sni'], ['own.any.test'])
        self.assertEqual(rq['fp'], ['firefox'])
        self.assertIn(r_meta['share_link'], res2.stdout)
        self.assert_restarts(2)

        # Delete-all removes both nodes and clears HAProxy reality route.
        self.shell('delete', '99\nyes\n')
        self.assertEqual(self.load('config.json')['inbounds'], [])
        self.assertEqual(self.load('metadata.json'), {})
        self.assertEqual(self.load('clash.yaml')['proxies'], [])
        self.assertIsNone(self.load('state.json')['reality'])
        self.assert_restarts(3)

    def test_xray_xhttp_tls_and_reality_with_enc_and_edits(self):
        # XHTTP creation works even without sing-box installed.
        (self.root / 'sing-box').unlink()
        for action, answers, kind, enc_choice, exp_enc, exp_dec in (
            ('xhttp-tls', '127.0.0.1\nxhttp.test\n8443\n/tls/\nXhttpTLS\n2\n1\n',
             'vless-xhttp', '1', self.mlkem_enc, self.mlkem_dec),
            ('xhttp-reality', '127.0.0.1\ny\n2\nreality.test\n8444\n/real/\nXhttpReal\n4\n2\n',
             'vless-xhttp-reality', '2', self.x25519_enc, self.x25519_dec),
        ):
            with self.subTest(kind=kind):
                for name in (*self.files, 'lock', 'restarts'):
                    (self.root / name).unlink(missing_ok=True)
                res = self.shell(action, answers)
                self.assertFalse((self.root / 'config.json').exists())
                (tag, meta), = self.load('metadata.json').items()
                inbound, = self.load('xray.json')['inbounds']
                client, = self.load('clash.yaml')['proxies']
                self.assertEqual((meta['core'], meta['type']), ('xray', kind))
                self.assertEqual(inbound['settings']['decryption'], exp_dec)
                self.assertEqual(client['encryption'], exp_enc)
                self.assertIn(meta['share_link'], res.stdout)
                self.assertNotIn(exp_dec.rsplit('.', 1)[-1], meta['share_link'])
                q = parse_qs(urlsplit(meta['share_link']).query)
                self.assertEqual(q['encryption'], [exp_enc])
                self.assertEqual('support-x25519mlkem768' in q, kind == 'vless-xhttp-reality')
                self.assert_restarts(1)

        # Verify _xray_enc_editable is strictly scoped to XHTTP node types.
        self.shell('enc-editable', variant='vless-xhttp', status=0)
        self.shell('enc-editable', variant='vless-xhttp-reality', status=0)
        for forbidden in ('vless-vision-reality', 'native-vless', 'anytls', 'any-reality'):
            self.shell('enc-editable', variant=forbidden, status=1)

    def test_confirmed_sni_and_enc_edits_update_all_records(self):
        self.seed_xhttp()
        res = self.shell('edit', 'y\ny\n1\nnew.test\ny\n', 'sni')
        meta = self.load('metadata.json')['test']
        stream = self.load('xray.json')['inbounds'][0]['streamSettings']
        self.assertEqual(meta['server_name'], 'new.test')
        self.assertEqual(stream['realitySettings']['serverNames'], ['new.test'])
        self.assertEqual(self.load('clash.yaml')['proxies'][0]['servername'], 'new.test')
        self.assertIn(meta['share_link'], res.stdout)
        self.assertEqual((self.root / 'origins').read_text().splitlines(), ['new.test'])
        self.assert_restarts(1)

        # Edit ENC from none -> ML-KEM-768, then name & concurrency.
        self.shell('edit', '1\ny\n', 'enc')
        self.assertEqual(self.load('xray.json')['inbounds'][0]['settings']['decryption'], self.mlkem_dec)
        self.assertEqual(self.load('clash.yaml')['proxies'][0]['encryption'], self.mlkem_enc)
        self.shell('edit', 'Renamed\ny\n', 'name')
        self.assertEqual(self.load('metadata.json')['test']['clientName'], 'Renamed')
        self.assertEqual(self.load('clash.yaml')['proxies'][0]['name'], 'Renamed')
        self.shell('edit', '6\ny\n', 'concurrency')
        self.assertEqual(
            self.load('clash.yaml')['proxies'][0]['xhttp-opts']['reuse-settings']['max-concurrency'], '6')
        self.assert_restarts(4)

    def test_dual_core_coexistence_view_and_port_conflict_and_rollback(self):
        # Create one sing-box Vision Reality node + one Xray XHTTP TLS node.
        self.shell('vision', '127.0.0.1\ny\n2\nvision.test\n8443\nSBNode\n')
        self.shell('xhttp-tls', '127.0.0.1\nxhttp.test\n8444\n/h2/\nXrayNode\n1\n3\n')
        self.assertEqual(len(self.load('config.json')['inbounds']), 1)
        self.assertEqual(len(self.load('xray.json')['inbounds']), 1)
        self.assertEqual(len(self.load('metadata.json')), 2)
        self.assertEqual(len(self.load('clash.yaml')['proxies']), 2)
        self.assert_restarts(2)

        # Dual-core _view_nodes lists both links and builds valid base64 subscription.
        viewed = self.shell('view', 'y\n')
        links = [m['share_link'] for m in self.load('metadata.json').values()]
        for link in links:
            self.assertIn(link, viewed.stdout)
        b64 = base64.b64encode(('\n'.join(links) + '\n').encode()).decode()
        self.assertIn(b64, viewed.stdout)

        # Sing-box node cannot collide with existing Xray inbound port (backendPort in xray.json).
        xray_backend = next(m['backendPort'] for m in self.load('metadata.json').values() if m.get('core') == 'xray')
        before = self.snapshot()
        conflict = self.shell('vision', f'127.0.0.1\ny\n2\nother.test\n{xray_backend}\n0\n', status=2)
        self.assertIn(f'端口 {xray_backend} 已被现有节点配置占用', conflict.stderr)
        self.assertEqual(self.snapshot(), before)

        # Restart failure rolls back both files and does NOT print share links.
        failed = self.shell('xhttp-reality', '127.0.0.1\ny\n2\nfail.test\n9443\n/f/\nFailNode\n1\n3\n',
                            status=1, FAIL_RESTART='1')
        self.assertNotIn('FailNode', failed.stdout)
        self.assertEqual(len(self.load('metadata.json')), 2)
        self.assertEqual(len(self.load('xray.json')['inbounds']), 1)

        # Delete-all cleans both sing-box and xray cleanly.
        self.shell('delete', '99\nyes\n')
        self.assertEqual(self.load('config.json')['inbounds'], [])
        self.assertEqual(self.load('xray.json')['inbounds'], [])
        self.assertEqual(self.load('metadata.json'), {})
        self.assertEqual(self.load('clash.yaml')['proxies'], [])

    def test_batch_singbox_vision_publishes_once_and_rolls_back_on_conflict(self):
        result = self.shell('batch', variant='443 8443')
        self.assertEqual(len(self.load('config.json')['inbounds']), 2)
        self.assertEqual(self.load('state.json')['reality']['owner'], 'sb')
        self.assertEqual(self.load('state.json')['reality']['sni'], 'example.test')
        self.assertEqual(result.stdout.count('vless://'), 2)
        self.assert_restarts(1)

        # Conflicting batch rolls back without restarting or printing links.
        before = self.snapshot()
        failed = self.shell('batch', variant='8445 8443', status=1)
        self.assertNotIn('vless://', failed.stdout)
        self.assertEqual(self.snapshot(), before)
        self.assert_restarts(1)

    def test_waiting_add_and_edit_allow_another_writer_then_reject_stale_input(self):
        for action, variant, prefix, suffix, prompt in (
            ('vision', '', '127.0.0.1\ny\n2\nexample.test\n8443\n', 'New\n', '请输入节点名称'),
            ('edit', 'name', 'New\n', 'y\n', '保存修改并重启'),
        ):
            with self.subTest(action=action):
                self.seed_xhttp()
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

    def test_reality_bidirectional_direct_and_shared_443_switch(self):
        # 1. VLESS Vision + Reality: direct 14443 -> shared 443 -> direct 15443.
        self.shell('vision', '127.0.0.1\ny\n2\nvision.switch.test\n14443\nVisionSwitch\n')
        (v_tag, v_meta), = self.load('metadata.json').items()
        self.assertEqual(v_meta['publicPort'], 14443)
        self.assertNotIn('frontedBy', v_meta)

        self.shell('port', '1\n443\n')
        v_meta = self.load('metadata.json')[v_tag]
        v_in = self.load('config.json')['inbounds'][0]
        v_client = self.load('clash.yaml')['proxies'][0]
        state = self.load('state.json')
        self.assertEqual(v_in['tag'], v_tag)
        self.assertEqual(v_in['listen'], '127.0.0.1')
        self.assertEqual(v_in['listen_port'], v_meta['backendPort'])
        self.assertNotEqual(v_meta['backendPort'], 443)
        self.assertEqual(v_meta['publicPort'], 443)
        self.assertEqual(v_meta['frontedBy'], 'haproxy')
        self.assertEqual(v_meta['routerRole'], 'reality-default')
        self.assertEqual(urlsplit(v_meta['share_link']).port, 443)
        self.assertEqual(v_client['port'], 443)
        self.assertEqual(state['reality']['owner'], 'sb')
        self.assertEqual(state['reality']['tag'], v_tag)
        self.assertEqual(state['reality']['backend_port'], v_meta['backendPort'])

        self.shell('port', '1\n15443\n')
        v_meta = self.load('metadata.json')[v_tag]
        v_in = self.load('config.json')['inbounds'][0]
        v_client = self.load('clash.yaml')['proxies'][0]
        self.assertEqual(v_in['tag'], v_tag)
        self.assertEqual(v_in['listen'], '::')
        self.assertEqual(v_in['listen_port'], 15443)
        self.assertEqual((v_meta['publicPort'], v_meta['backendPort']), (15443, 15443))
        self.assertNotIn('frontedBy', v_meta)
        self.assertNotIn('routerRole', v_meta)
        self.assertEqual(urlsplit(v_meta['share_link']).port, 15443)
        self.assertEqual(v_client['port'], 15443)
        self.assertIsNone(self.load('state.json')['reality'])

        # 2. Any-Reality (yaml: false): direct 17443 -> shared 443 -> direct 18443.
        self.shell('anytls', '2\n127.0.0.1\n17443\ny\n2\nanyr.switch.test\nsecret-pw\nAnyRSwitch\n')
        r_tag, r_meta = next((t, m) for t, m in self.load('metadata.json').items() if t != v_tag)
        self.assertEqual(r_meta['publicPort'], 17443)
        self.assertIs(r_meta['yaml'], False)

        self.shell('port', '2\n443\n')
        r_meta = self.load('metadata.json')[r_tag]
        r_in = next(i for i in self.load('config.json')['inbounds'] if i['tag'] == r_tag)
        state = self.load('state.json')
        self.assertEqual(r_in['listen'], '127.0.0.1')
        self.assertEqual(r_in['listen_port'], r_meta['backendPort'])
        self.assertNotEqual(r_meta['backendPort'], 443)
        self.assertEqual(r_meta['publicPort'], 443)
        self.assertEqual(r_meta['frontedBy'], 'haproxy')
        self.assertEqual(r_meta['routerRole'], 'reality-default')
        self.assertEqual(urlsplit(r_meta['share_link']).port, 443)
        self.assertEqual(state['reality']['owner'], 'sb')
        self.assertEqual(state['reality']['tag'], r_tag)

        self.shell('port', '2\n18443\n')
        r_meta = self.load('metadata.json')[r_tag]
        r_in = next(i for i in self.load('config.json')['inbounds'] if i['tag'] == r_tag)
        self.assertEqual(r_in['listen'], '::')
        self.assertEqual(r_in['listen_port'], 18443)
        self.assertEqual((r_meta['publicPort'], r_meta['backendPort']), (18443, 18443))
        self.assertNotIn('frontedBy', r_meta)
        self.assertNotIn('routerRole', r_meta)
        self.assertEqual(urlsplit(r_meta['share_link']).port, 18443)
        self.assertIsNone(self.load('state.json')['reality'])

    def test_batch_create_nodes_single_transaction_and_mid_batch_rollback(self):
        # 7-node batch (Hy2 + TUIC + 3 SS variants + VLESS TCP + SOCKS5) publishes with ONE restart.
        res = self.shell('batch-cmd', '\nbatch.test\nn\nn\n1,3,4\n18101-18107\n', variant='6,7,8,9,10')
        self.assertEqual(len(self.load('config.json')['inbounds']), 7)
        self.assertEqual(len(self.load('metadata.json')), 7)
        self.assertEqual(len(self.load('clash.yaml')['proxies']), 7)
        self.assert_restarts(1)
        self.assertIn('批量创建任务已全部完成', res.stdout + res.stderr)

        # Invalid SS variant 99 is rejected upfront with zero writes and zero extra restarts.
        before = self.snapshot()
        bad_variant = self.shell('batch-cmd', '\n99\n18201 18202\n', variant='9,8', status=1)
        self.assertEqual(self.snapshot(), before)
        self.assert_restarts(1)
        self.assertNotIn('vless://', bad_variant.stdout)

        # Mid-batch failure: node 1 (9: VLESS TCP) stages into candidates, node 2 (5: AnyTLS without
        # BATCH_ANYTLS_INSECURE) fails -> earlier node in the batch is completely rolled back!
        failed = self.shell('batch-cmd', '\nfail.test\n18211 18212\n', variant='9,5', status=1)
        self.assertEqual(self.snapshot(), before)
        self.assert_restarts(1)
        self.assertNotIn('vless://', failed.stdout)

    def test_legacy_xray_native_node_view_port_edit_delete_and_uninstall(self):
        ss_pw = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        ss_link = 'ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQT0@127.0.0.1:18201/?udp=0#LegacyXraySS'
        vless_link = 'vless://11111111-2222-3333-4444-555555555555@127.0.0.1:18202?encryption=none&security=none&type=tcp#LegacyXrayVLESS'
        self.store('config.json', {
            'inbounds': [{'type': 'socks', 'tag': 'sb-socks', 'listen': '::', 'listen_port': 18203,
                          'users': [{'username': 'u1', 'password': 'p1'}]}],
            'outbounds': [{'type': 'direct', 'tag': 'direct'}],
        })
        self.store('xray.json', {
            'inbounds': [
                {'tag': 'xray-ss-legacy', 'listen': '::', 'port': 18201, 'protocol': 'shadowsocks',
                 'settings': {'method': '2022-blake3-aes-256-gcm', 'password': ss_pw}},
                {'tag': 'xray-vless-legacy', 'listen': '::', 'port': 18202, 'protocol': 'vless',
                 'settings': {'clients': [{'id': '11111111-2222-3333-4444-555555555555'}], 'decryption': 'none'},
                 'streamSettings': {'network': 'tcp', 'security': 'none'}},
            ],
            'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}],
        })
        self.store('metadata.json', {
            'sb-socks': {'name': 'SBSocks', 'clientName': 'SBSocks', 'publicPort': 18203, 'backendPort': 18203},
            'xray-ss-legacy': {'core': 'xray', 'type': 'native-shadowsocks', 'name': 'LegacyXraySS',
                               'clientName': 'LegacyXraySS', 'publicPort': 18201, 'backendPort': 18201,
                               'share_link': ss_link},
            'xray-vless-legacy': {'core': 'xray', 'type': 'native-vless', 'name': 'LegacyXrayVLESS',
                                  'clientName': 'LegacyXrayVLESS', 'publicPort': 18202, 'backendPort': 18202,
                                  'share_link': vless_link},
        })
        self.store('clash.yaml', {
            'proxies': [
                {'name': 'SBSocks', 'type': 'socks5', 'server': '127.0.0.1', 'port': 18203,
                 'username': 'u1', 'password': 'p1'},
                {'name': 'LegacyXraySS', 'type': 'ss', 'server': '127.0.0.1', 'port': 18201,
                 'cipher': '2022-blake3-aes-256-gcm', 'password': ss_pw, 'udp': False},
                {'name': 'LegacyXrayVLESS', 'type': 'vless', 'server': '127.0.0.1', 'port': 18202,
                 'uuid': '11111111-2222-3333-4444-555555555555', 'network': 'tcp', 'tls': False},
            ],
            'proxy-groups': [{'name': '节点选择', 'proxies': ['DIRECT', 'SBSocks', 'LegacyXraySS', 'LegacyXrayVLESS']}],
        })

        # 1. _view_nodes matches legacy Xray SS & VLESS nodes and prints their links without errors.
        viewed = self.shell('view', 'y\n')
        self.assertNotIn('客户端关联不唯一', viewed.stderr)
        self.assertNotIn('找不到 mihomo 节点配置', viewed.stderr)
        self.assertIn('ss://', viewed.stdout)
        self.assertIn('LegacyXraySS', viewed.stdout)
        self.assertIn(vless_link, viewed.stdout)

        # 2. Port edit via _edit_node_menu works cleanly on legacy Xray SS node (item 2: sb-socks is 1, xray-ss-legacy is 2).
        edited = self.shell('edit-menu', '2\n18299\n0\n')
        self.assertIn('Xray 历史节点 · 修改端口', edited.stdout)
        ss_in = next(i for i in self.load('xray.json')['inbounds'] if i['tag'] == 'xray-ss-legacy')
        self.assertEqual(ss_in['port'], 18299)
        ss_meta = self.load('metadata.json')['xray-ss-legacy']
        self.assertEqual((ss_meta['publicPort'], ss_meta['backendPort']), (18299, 18299))
        self.assertEqual(urlsplit(ss_meta['share_link']).port, 18299)
        ss_client = next(p for p in self.load('clash.yaml')['proxies'] if p['name'] == 'LegacyXraySS')
        self.assertEqual(ss_client['port'], 18299)

        # 3. Single delete removes legacy Xray VLESS node cleanly despite having no nginxConfig.
        self.shell('delete', '3\ny\n')
        self.assertEqual([i['tag'] for i in self.load('xray.json')['inbounds']], ['xray-ss-legacy'])
        self.assertNotIn('xray-vless-legacy', self.load('metadata.json'))
        self.assertNotIn('LegacyXrayVLESS', [p['name'] for p in self.load('clash.yaml')['proxies']])

        # 4. _uninstall_locked completes cleanly even while legacy Xray SS node still exists in metadata/xray.json.
        (self.root / 'sb').write_text('#!/usr/bin/env bash\n')
        self.shell('uninstall', 'y\n')
        self.assertFalse((self.root / 'config.json').exists())
        self.assertFalse((self.root / 'xray.json').exists())


if __name__ == '__main__':
    unittest.main()
