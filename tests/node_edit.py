#!/usr/bin/env python3
"""Node edits using real Xray, yq and Nginx; ACME issuance uses local test certificates."""
import base64
import json
import os
import subprocess
import unittest
from urllib.parse import parse_qs, urlsplit

import xhttp

EXTRA = r'''
NODE_UI=true
REALITY_LOCAL_ORIGIN_PORT="$ORIGIN_PORT"
SB_ACME_SH="$WORK/acme.sh"
# Keep website and certificate preparation inside the test directory.
eval "$(declare -f _prepare_local_reality_origin | sed "s#/var/www/singbox-reality/#$WORK/www/#g; s/:80;/:$HTTP_PORT;/g")"
eval "$(declare -f _xhttp_prepare_certificate | sed "s/listen 80;/listen $HTTP_PORT;/g")"
_validate_local_origin_dns() { echo "dns $1" >> "$WORK/prepare.calls"; [ "${FAIL_DNS:-0}" != 1 ]; }
_probe_reality_target() { return 0; }
_install_sb_acme() { return 0; }
_ensure_acme_renewal() { return 0; }
_issue_local_origin_certificate() {
    echo "issue $1" >> "$WORK/prepare.calls"
    [ "${FAIL_CERT:-0}" != 1 ] || return 1
    mkdir -p "$NGINX_CERT_DIR/$1"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$NGINX_CERT_DIR/$1/key" \
        -out "$NGINX_CERT_DIR/$1/cert" -subj "/CN=$1" -addext "subjectAltName=DNS:$1" -days 30 >/dev/null 2>&1
}
_sni_router_apply() {
    [ -z "${NODE_TX_DIR:-}" ] || touch "$NODE_TX_DIR/router-touched"
    [ "${FAIL_ROUTER:-0}" != 1 ]
}
'''


@unittest.skipUnless(all(xhttp.TOOLS.values()) and os.environ.get('TEST_SUBSTORE'),
                     'set TEST_XRAY, TEST_MIHOMO, TEST_NGINX, TEST_YQ, TEST_SUBSTORE')
class NodeEdit(unittest.TestCase):
    def setUp(self):
        self.fixture = xhttp.XHTTPTests(methodName='runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.fixture.env['ORIGIN_PORT'] = str(xhttp.port())
        self.fixture.env['HTTP_PORT'] = str(xhttp.port())
        harness = xhttp.HARNESS.replace('case "$ACTION" in', EXTRA + '''
case "$ACTION" in
    edit-menu) _xray_manage_node edit ;;
    edit)
        tag=$(jq -r 'keys[0]' "$METADATA_FILE")
        meta=$(jq -c --arg t "$tag" '.[$t]' "$METADATA_FILE")
        _node_operation _xray_edit_field "$tag" "$FIELD" "$meta" ;;
    reality) _node_operation _add_vless_xhttp_reality_impl ;;
    subscribe) _xray_list_links subscription ;;
''')
        (self.root/'harness.sh').write_text(harness)

    def edit(self, field, answers, check=True, **env):
        return self.fixture.run_shell('edit', answers, check=check, FIELD=field, **env)

    def reality(self):
        self.fixture.run_shell('reality', f'\ny\n1\nxhttp.test\n{self.fixture.public}\n/test/\nReality test\n1\n3\n')

    def data(self):
        meta = next(iter(self.fixture.json('metadata.json').values()))
        inbound = self.fixture.json('xray.json')['inbounds'][0]
        client = json.loads(subprocess.check_output([xhttp.TOOLS['yq'], '-o=json', str(self.root/'clash.yaml')]))['proxies'][0]
        return meta, inbound, client

    def assert_export(self):
        meta, _, client = self.data()
        if os.environ.get('TEST_SUBSTORE'):
            exported = self.fixture.exported(meta['share_link'])
            for key, value in client.items():
                if client['type'] == 'trojan' and key == 'tls':
                    self.assertTrue(value)  # Trojan's TLS is implicit in Sub-Store's export.
                    continue
                self.assertEqual(exported.get(key), value, key)
        lines = self.fixture.run_shell('subscribe').stdout.strip().splitlines()
        self.assertIn(meta['share_link'], lines)
        self.assertIn(meta['share_link'], base64.b64decode(lines[-1]).decode())
        return client

    def traffic(self):
        self.assert_export()
        proxy = self.fixture.exported(self.data()[0]['share_link'])
        mixed = xhttp.port()
        cfg = self.root/f'client-{mixed}.json'
        cfg.write_text(json.dumps({'mixed-port':mixed,'proxies':[proxy],'rules':['MATCH,'+proxy['name']]}))
        env = dict(os.environ, SSL_CERT_FILE=str(self.root/'certs'/proxy['servername']/'cert'))
        self.fixture.start([xhttp.TOOLS['mihomo'], '-d', str(self.root/f'client-{mixed}'), '-f', str(cfg)], mixed, env)
        response = subprocess.run(['curl','-fsS','--max-time','6','--noproxy','','-x',f'http://127.0.0.1:{mixed}',f'http://127.0.0.1:{self.fixture.webport}/'],capture_output=True)
        self.assertEqual(response.stdout, b'website', (response.stderr, (self.root/'xray.log').read_text()[-1200:]))

    def snapshot(self):
        paths = [self.root/name for name in ('metadata.json','xray.json','clash.yaml','xray.pid')]
        paths += list((self.root/'conf.d').glob('*.conf'))
        return {str(p): (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns, p.stat().st_mode) for p in paths}

    def test_reality_fields_and_exported_traffic(self):
        self.reality()
        meta, original, client = self.data()
        self.edit('name', 'Renamed 中文\ny\n')
        self.edit('server', '::1\ny\n')
        self.edit('enc', '1\ny\n')
        self.edit('path', '/changed/\ny\n')
        self.edit('concurrency', '5\ny\n')
        newport = xhttp.port()
        self.edit('port', f'{newport}\ny\n')
        self.edit('sni', 'y\ny\n1\nnew.test\ny\n')
        meta, current, client = self.data()
        self.assertEqual(current['settings']['clients'], original['settings']['clients'])
        self.assertEqual(current['streamSettings']['realitySettings']['privateKey'], original['streamSettings']['realitySettings']['privateKey'])
        self.assertEqual(current['streamSettings']['realitySettings']['serverNames'], ['new.test'])
        self.assertEqual(client['name'], 'Renamed 中文')
        self.assertEqual(client['port'], newport)
        self.assertEqual(client['xhttp-opts']['path'], '/changed/')
        self.assertEqual(client['xhttp-opts']['reuse-settings']['max-concurrency'], '5')
        self.assertIn('issue new.test', (self.root/'prepare.calls').read_text())
        self.assertTrue(client['encryption'].startswith('mlkem768x25519plus.'))
        self.traffic()
        self.edit('enc', '2\ny\n')
        self.traffic()
        self.edit('enc', '3\ny\n')
        self.assertEqual(self.data()[1]['settings']['decryption'], 'none')
        self.traffic()

    def test_tls_domain_path_and_existing_certificate(self):
        self.fixture.add()
        self.edit('sni', 'new.test\ny\n')
        self.edit('path', '/new/\ny\n')
        self.traffic()
        calls = (self.root/'prepare.calls').read_text()
        self.edit('sni', '\ny\n')
        self.assertEqual((self.root/'prepare.calls').read_text(), calls)
        self.assert_export()

    def test_cancel_noop_and_invalid_inputs_preserve_files_and_pid(self):
        self.reality()
        before = self.snapshot()
        cases = {
            'name': ['0\n', '', 'Other\n0\n', 'Other\nn\n', '\n'],
            'server': ['0\n', 'bad/address\n', '\n', 'localhost\n'],
            'port': ['0\n', '65536\n', '\n', '443\n0\n', '443\ny\n0\n'],
            'enc': ['0\n', '\n', '3\n', '1\nn\n', '1\n0\n', '1\n'],
            'sni': ['0\n', '\n', 'y\n0\n', 'y\ny\n0\n', 'y\ny\n1\n0\n', 'y\ny\n1\nnew.test\nn\n', 'y\ny\n1\nnew.test\n'],
            'path': ['0\n', '/bad;path/\n', '\n', '/new/\n0\n'],
            'concurrency': ['0\n', 'invalid\n', '\n', '1\n', '5\nn\n'],
        }
        for field, answers in cases.items():
            for answer in answers:
                with self.subTest(field=field, answer=answer):
                    self.edit(field, answer, check=False)
                    self.assertEqual(self.snapshot(), before)
                    self.assertFalse(list(self.root.glob('.node-op.*')))
        self.assertNotIn('issue ', (self.root/'prepare.calls').read_text())
        result = self.fixture.run_shell('edit-menu', '1\n5\n0\n0\n0\n', check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.snapshot(), before)

    def test_certificate_and_restart_failures_restore_configuration(self):
        self.reality()
        before = {key: value[0] for key, value in self.snapshot().items() if not key.endswith('xray.pid')}
        for env in ({'FAIL_CERT':'1'}, {'FAIL_RESTART':'1'}):
            result = self.edit('sni', 'y\ny\n1\nfailed.test\ny\n', check=False, **env)
            self.assertNotEqual(result.returncode, 0)
            current = {key: value[0] for key, value in self.snapshot().items() if not key.endswith('xray.pid')}
            self.assertEqual(current, before)
            self.assertFalse((self.root/'certs/failed.test/cert').exists())
        self.traffic()

    def test_shared_reality_router_and_relay_survive_edit(self):
        self.reality()
        # Isolated HAProxy state; the existing listener stays on its loopback test port.
        tag = next(iter(self.fixture.json('metadata.json')))
        meta, ib, _ = self.data()
        metadata = self.fixture.json('metadata.json')
        metadata[tag].update(frontedBy='haproxy', routerRole='reality-default')
        (self.root/'metadata.json').write_text(json.dumps(metadata))
        state = {'version':1,'reality':{'owner':'sb-xhttp','tag':tag,'sni':'xhttp.test','backend_host':'127.0.0.1','backend_port':ib['port']},'https_routes':{'emby.test':{'owner':'emby'}},'https_backend':{'host':'127.0.0.1','port':8444},'tls_routes':{}}
        (self.root/'router').mkdir(exist_ok=True)
        (self.root/'router/state.json').write_text(json.dumps(state))
        (self.root/'relay.json').write_text(json.dumps({'protocol':'freedom','settings':{'finalRules':[{'action':'allow','ip':['127.0.0.1/32']}]}}))
        self.fixture.run_shell('relay', f'1\n{self.root}/relay.json\n')
        routing = self.fixture.json('xray.json')['routing']
        outbounds = self.fixture.json('xray.json')['outbounds']
        self.edit('sni', 'y\ny\n1\nnew.test\ny\n')
        self.assertEqual(self.fixture.json('xray.json')['routing'], routing)
        self.assertEqual(self.fixture.json('xray.json')['outbounds'], outbounds)
        changed = self.fixture.json('router/state.json')
        self.assertEqual(changed['reality']['sni'], 'new.test')
        self.assertEqual(changed['https_routes'], state['https_routes'])
        before = self.fixture.json('metadata.json')
        result = self.edit('sni', 'y\ny\n1\nemby.test\ny\n', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.json('metadata.json'), before)
        self.traffic()

    def test_reality_repairs_missing_certificate_for_same_domain(self):
        self.reality()
        (self.root/'certs/xhttp.test/cert').unlink()
        (self.root/'certs/xhttp.test/key').unlink()
        self.edit('sni', 'y\ny\n1\nxhttp.test\ny\n')
        self.assertIn('issue xhttp.test', (self.root/'prepare.calls').read_text())
        self.traffic()
        calls = (self.root/'prepare.calls').read_text().count('issue ')
        self.edit('sni', 'y\ny\n1\nxhttp.test\ny\n')
        self.assertEqual((self.root/'prepare.calls').read_text().count('issue '), calls)

    def test_tls_repairs_missing_certificate_for_same_domain(self):
        self.fixture.add()
        (self.root/'certs/xhttp.test/cert').unlink()
        self.edit('sni', '\ny\n')
        self.assertIn('issue xhttp.test', (self.root/'prepare.calls').read_text())
        self.traffic()

    def test_native_name_address_and_tls_fields(self):
        for variant in (1, 2, 3, 4, 5, 6):
            with self.subTest(variant=variant):
                self.fixture.run_shell('native', f'{variant}\n127.0.0.1\n{xhttp.port()}\nNative\n'+('xhttp.test\n' if variant>=4 else '\n' if variant == 1 else ''))
                self.edit('name', 'Renamed\ny\n')
                self.edit('server', '::1\ny\n')
                self.assert_export()
                if variant>=4:
                    self.edit('sni', 'native.test\ny\n')
                    self.edit('path', ('myservice' if variant==6 else '/new/')+'\ny\n')
                    self.assert_export()
                self.fixture.run_shell('delete', '1\ny\n')

    def test_vision_enc_and_sni(self):
        # Prepare a local Reality origin through the same creation flow.
        self.reality()
        self.fixture.run_shell('delete', '1\ny\n')
        self.fixture.run_shell('vision', PORT=str(self.fixture.public), ORIGIN=self.fixture.env['ORIGIN_PORT'], PROFILE='none')
        self.edit('enc', '1\ny\n')
        self.edit('sni', 'y\ny\n1\nvision.test\ny\n')
        self.traffic()


if __name__ == '__main__':
    unittest.main()
