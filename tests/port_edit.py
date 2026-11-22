#!/usr/bin/env python3
"""Xray port preflight and XHTTP public-port edits against local services."""
import json
import os
import socket
import subprocess
import time
import unittest
from urllib.parse import urlsplit

import xhttp


@unittest.skipUnless(all(xhttp.TOOLS.values()), 'set TEST_XRAY, TEST_MIHOMO, TEST_NGINX, TEST_YQ')
class PortEdit(unittest.TestCase):
    def setUp(self):
        self.fixture = xhttp.XHTTPTests(methodName='runTest')
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        self.root = self.fixture.root
        (self.root / 'config.json').unlink()
        self.fixture.env['HTTPS_BACKEND'] = str(xhttp.port())
        self.fixture.env['ROUTER_PUBLIC'] = str(xhttp.port())
        (self.root / 'harness.sh').write_text(xhttp.HARNESS.replace('case "$ACTION" in', r'''
case "$ACTION" in
    conflict) _check_port_conflict "$PORT" "${PROTO:-tcp}" "${SILENT:-false}" ;;
    candidate-conflict)
        NODE_TX_FILES=([9]="$XRAY_CONFIG_FILE")
        NODE_TX_DIR="$WORK"
        NODE_TX_STARTED=1
        _check_port_conflict "$PORT" tcp ;;
    edit)
        tag=$(jq -r 'keys[0]' "$METADATA_FILE")
        meta=$(jq -c --arg t "$tag" '.[$t]' "$METADATA_FILE")
        _node_operation _xray_edit_field "$tag" port "$meta" ;;
    reload) _sb_reload_or_start_nginx ;;
'''))

    def edit(self, port, shared=None, check=True):
        answers = f'{port}\n' + (f'{shared}\n' if shared is not None else '') + 'y\n'
        return self.fixture.run_shell('edit', answers, check=check)

    def snapshot(self):
        paths = list((self.root / 'conf.d').glob('*.conf'))
        paths += [self.root / f for f in ('xray.json', 'clash.yaml', 'metadata.json', 'router/state.json')]
        return {str(path): path.read_bytes() for path in paths if path.exists()}

    def assert_rejected(self, port, diagnostic, shared=None):
        before = self.snapshot()
        result = self.edit(port, shared, check=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.root / 'config.json').exists())

    def add_vhost(self, listen, domain, proxy_protocol=False):
        cert = self.root / 'certs/xhttp.test'
        options = ' proxy_protocol' if proxy_protocol else ''
        (self.root / 'conf.d/00-other.conf').write_text(f'''
server {{ listen {listen} ssl http2{options};
    server_name "{domain}";
    ssl_certificate {cert}/cert;
    ssl_certificate_key {cert}/key;
    location / {{ return 200 'other'; }}
}}
''')
        self.fixture.run_shell('reload')
        host, port = listen.split(':')
        address = ('127.0.0.1' if host == '0.0.0.0' else host, int(port))
        for _ in range(40):
            try:
                with socket.create_connection(address, timeout=.1):
                    return
            except OSError:
                time.sleep(.05)
        self.fail(f'Nginx did not open {listen}')

    def assert_traffic(self, public):
        meta = next(iter(self.fixture.json('metadata.json').values()))
        clients = subprocess.check_output([xhttp.TOOLS['yq'], '-o=json', str(self.root / 'clash.yaml')])
        client = json.loads(clients)['proxies'][0]
        self.assertEqual((meta['publicPort'], client['port'], urlsplit(meta['share_link']).port), (public,) * 3)
        if os.environ.get('TEST_SUBSTORE'):
            exported = self.fixture.exported(meta['share_link'])
            for key, value in client.items():
                self.assertEqual(exported.get(key), value, key)
            client = exported
        mixed = xhttp.port()
        config = self.root / f'mihomo-{mixed}.json'
        config.write_text(json.dumps({'mixed-port': mixed, 'proxies': [client], 'rules': ['MATCH,' + client['name']]}))
        env = dict(os.environ, SSL_CERT_FILE=str(self.root / 'certs/xhttp.test/cert'))
        self.fixture.start([xhttp.TOOLS['mihomo'], '-d', str(self.root / f'client-{mixed}'), '-f', str(config)], mixed, env)
        response = subprocess.run(['curl', '-fsS', '--max-time', '6', '--noproxy', '', '-x', f'http://127.0.0.1:{mixed}',
                                   f'http://127.0.0.1:{self.fixture.webport}/'], capture_output=True)
        self.assertEqual(response.stdout, b'website', response.stderr)

    def test_configured_ports_without_running_xray_or_singbox(self):
        public, candidate, free, legacy, relay, udp = [xhttp.port() for _ in range(6)]
        (self.root / 'xray.json').write_text(json.dumps({'inbounds': [{'port': public}]}))
        (self.root / 'candidate.9').write_text(json.dumps({'inbounds': [{'port': str(candidate)}]}))
        run = self.fixture.run_shell
        found = run('conflict', PORT=str(public))
        self.assertIn('配置占用', found.stdout + found.stderr)
        silent = run('conflict', PORT=str(public), SILENT='true')
        self.assertEqual(silent.stdout + silent.stderr, '')
        run('candidate-conflict', PORT=str(candidate))
        self.assertEqual(run('candidate-conflict', PORT=str(public), check=False).returncode, 1)
        self.assertEqual(run('conflict', PORT=str(free), check=False).returncode, 1)
        (self.root / 'config.json').write_text(json.dumps({'inbounds': [{'listen_port': legacy}]}))
        (self.root / 'relay.json').write_text(json.dumps({'inbounds': [{'listen_port': relay}]}))
        (self.root / 'metadata.json').write_text(json.dumps({'hy2': {'portHopping': f'{udp}-{udp}'}}))
        run('conflict', PORT=str(legacy))
        run('conflict', PORT=str(relay))
        hop = run('conflict', PORT=str(udp), PROTO='udp')
        self.assertIn('HY2', hop.stdout + hop.stderr)

    def test_direct_edit_reuses_nginx_port_for_different_domain(self):
        self.fixture.add()
        outbound_port = xhttp.port()
        self.add_vhost(f'0.0.0.0:{outbound_port}', 'other.test')
        before = self.fixture.json('xray.json')['inbounds']
        self.edit(outbound_port)
        self.assertEqual(self.fixture.json('xray.json')['inbounds'], before)
        self.assert_traffic(outbound_port)
        self.assertEqual(subprocess.check_output(['curl', '-kfsS', '--noproxy', '*', '--resolve',
                                                 f'other.test:{outbound_port}:127.0.0.1',
                                                 f'https://other.test:{outbound_port}/']), b'other')
        self.assertFalse((self.root / 'config.json').exists())

    def test_direct_edit_rejects_duplicate_vhost(self):
        self.fixture.add()
        port = xhttp.port()
        self.add_vhost(f'0.0.0.0:{port}', 'XHTTP.TEST')
        self.assert_rejected(port, '已有同名站点')
        self.assert_traffic(self.fixture.public)

    def test_direct_edit_rejects_address_specific_vhost(self):
        self.fixture.add()
        port = xhttp.port()
        self.add_vhost(f'127.0.0.1:{port}', 'XHTTP.TEST')
        self.assert_rejected(port, '现有监听地址或 PROXY protocol 设置与 XHTTP 不兼容')

    def test_direct_edit_rejects_proxy_protocol_listener(self):
        self.fixture.add()
        port = xhttp.port()
        self.add_vhost(f'0.0.0.0:{port}', 'other.test', proxy_protocol=True)
        self.assert_rejected(port, '现有监听地址或 PROXY protocol 设置与 XHTTP 不兼容')

    def test_direct_edit_rejects_mixed_tcp_listeners(self):
        self.fixture.add()
        port = xhttp.port()
        with socket.socket() as other:
            other.bind(('127.0.0.2', port))
            other.listen()
            self.add_vhost(f'127.0.0.1:{port}', 'other.test')
            self.assert_rejected(port, '已被其他服务使用')

    def test_shared_edit_rejects_busy_or_reserved_backend(self):
        self.fixture.add()
        backend = int(self.fixture.env['HTTPS_BACKEND'])
        public = int(self.fixture.env['ROUTER_PUBLIC'])
        self.assert_rejected(backend, '保留给共享 SNI')
        with socket.socket() as other:
            other.bind(('127.0.0.1', backend))
            other.listen()
            self.assert_rejected(public, '已被其他服务使用', 'y')
        # A stopped Xray still owns the port in its configuration.
        data = self.fixture.json('xray.json')
        data['inbounds'].append({'tag': 'offline', 'port': backend})
        (self.root / 'xray.json').write_text(json.dumps(data))
        self.assert_rejected(public, '已被现有节点配置占用', 'y')

    def test_shared_edit_rejects_nginx_backend_without_proxy_protocol(self):
        self.fixture.add()
        backend = int(self.fixture.env['HTTPS_BACKEND'])
        public = int(self.fixture.env['ROUTER_PUBLIC'])
        self.add_vhost(f'127.0.0.1:{backend}', 'other.test')
        self.assert_rejected(public, '现有监听地址或 PROXY protocol 设置与 XHTTP 不兼容', 'y')

    def router_state(self, routes):
        (self.root / 'router').mkdir()
        state = {'version': 1, 'public_port': int(self.fixture.env['ROUTER_PUBLIC']), 'reality': None,
                 'https_backend': {'host': '127.0.0.1', 'port': int(self.fixture.env['HTTPS_BACKEND'])},
                 'https_routes': routes, 'tls_routes': {}}
        (self.root / 'router/state.json').write_text(json.dumps(state))

    def test_shared_edit_rejects_existing_sni(self):
        self.fixture.add()
        self.router_state({'xhttp.test': {'owner': 'sb-xhttp'}})
        self.assert_rejected(int(self.fixture.env['ROUTER_PUBLIC']), '已被共享 443 路由占用', 'y')

    @unittest.skipUnless(os.environ.get('TEST_HAPROXY'), 'set TEST_HAPROXY for shared TLS edit traffic')
    def test_shared_edit_round_trip_with_live_proxy(self):
        self.fixture.add()
        backend = int(self.fixture.env['HTTPS_BACKEND'])
        public = int(self.fixture.env['ROUTER_PUBLIC'])
        self.add_vhost(f'127.0.0.1:{backend}', 'other.test', proxy_protocol=True)
        routes = {'other.test': {'owner': 'nginx-proxy'}}
        self.router_state(routes)
        inbound = self.fixture.json('xray.json')['inbounds']
        self.edit(public, 'y')
        self.assertEqual(self.fixture.json('router/state.json')['https_routes']['xhttp.test']['owner'], 'sb-xhttp')
        self.fixture.run_shell('haproxy')
        config = self.root / 'haproxy.test'
        raw = (self.root / 'haproxy.raw').read_text()
        config.write_text('\n'.join(line for line in raw.splitlines()
                                    if not line.strip().startswith(('user ', 'group ', 'stats socket '))) + '\n')
        self.fixture.start([os.environ['TEST_HAPROXY'], '-db', '-f', str(config)], public)
        self.assert_traffic(public)
        self.edit(self.fixture.public)
        self.assertEqual(self.fixture.json('router/state.json')['https_routes'], routes)
        self.assertEqual(self.fixture.json('xray.json')['inbounds'], inbound)
        self.assert_traffic(self.fixture.public)


if __name__ == '__main__':
    unittest.main()
