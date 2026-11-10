#!/usr/bin/env python3
"""Check SS multiplex exports and plain VLESS; set TEST_YQ, TEST_SINGBOX and TEST_MIHOMO for core tests."""
import concurrent.futures
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

REPO = Path(__file__).resolve().parents[1]
TOOLS = {key: os.environ.get('TEST_' + key.upper()) for key in ['yq', 'singbox', 'mihomo']}
HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR="$WORK"
CONFIG_FILE="$WORK/config.json"
METADATA_FILE="$WORK/metadata.json"
CLASH_YAML_FILE="$WORK/client.yaml"
XRAY_CONFIG_FILE="$WORK/xray.json"
ARGO_METADATA_FILE="$WORK/argo.json"
SINGBOX_BIN="${TEST_SINGBOX:-$WORK/core}"
YQ_BINARY="${TEST_YQ:-}"
server_ip="${TEST_ADDRESS:-127.0.0.1}"
BATCH_MODE=true
BATCH_PORT="${TEST_PORT:-10001}"
BATCH_SS_VARIANT="${VARIANT:-3}"
_assert_node_name_free() { return 0; }
_new_node_tag() { echo tcp-node-test; }
_atomic_modify_json() {
    jq "$2" "$1" > "$1.tmp" && mv -- "$1.tmp" "$1"
}
_add_node_to_yaml() {
    jq --argjson proxy "$1" '.proxies += [$proxy]' "$CLASH_YAML_FILE" > "$CLASH_YAML_FILE.tmp" &&
        mv -- "$CLASH_YAML_FILE.tmp" "$CLASH_YAML_FILE" || return 1
    local mapping
    mapping=$(jq -nc --arg t "$tag" --arg n "$(jq -r .name <<< "$1")" '.[$t]={name:$n,clientName:$n,yaml:true}') || return 1
    _atomic_modify_json "$METADATA_FILE" ". * $mapping"
}
if [ -z "$YQ_BINARY" ]; then
    _ss_share_link() { echo ss://fixture; }
fi
case "$ACTION" in
    ss) _add_shadowsocks_menu_impl ;;
    vless) _add_vless_tcp_impl ;;
    view) _view_nodes ;;
    link) _ss_share_link "$TEST_NAME" ;;
esac
'''


class NodeFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-tcp-node-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.reset()
        (self.root / 'harness.sh').write_text(HARNESS)
        core = self.root / 'core'
        core.write_text('''#!/usr/bin/env python3
import base64, secrets, sys, uuid
if sys.argv[1:] == ['generate', 'uuid']:
    print(uuid.uuid4())
elif sys.argv[1:3] == ['generate', 'rand']:
    data = secrets.token_bytes(int(sys.argv[-1]))
    print(base64.b64encode(data).decode() if '--base64' in sys.argv else data.hex())
else:
    raise SystemExit(1)
''')
        core.chmod(0o700)

    def reset(self):
        for name, value in [('config.json', {'inbounds': [], 'outbounds': [{'type': 'direct'}]}),
                            ('metadata.json', {}), ('client.yaml', {'proxies': []})]:
            (self.root / name).write_text(json.dumps(value))

    def run_shell(self, action, answers='', **extra):
        env = dict(os.environ, REPO=str(REPO), WORK=str(self.root), ACTION=action, **extra)
        result = subprocess.run(['bash', str(self.root / 'harness.sh')], env=env,
                                input=answers, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def read(self, name):
        return json.loads((self.root / name).read_text())

    def generate(self, kind='ss', variant=3, **extra):
        self.reset()
        return self.run_shell(kind, 'localhost\n' if variant == 5 else '', VARIANT=str(variant), **extra)


class GenerationTests(NodeFixture):
    def test_ss_variants_align_client_and_server_multiplex(self):
        for variant in range(1, 6):
            with self.subTest(variant=variant):
                self.generate(variant=variant)
                config = self.read('config.json')
                inbound = next(i for i in config['inbounds'] if i['type'] == 'shadowsocks')
                proxy = self.read('client.yaml')['proxies'][0]
                self.assertEqual(inbound['multiplex'], {'enabled': True, 'padding': variant == 4})
                self.assertEqual(proxy['smux'], {'enabled': True, 'protocol': 'h2mux',
                                                'max-connections': 4, 'min-streams': 4,
                                                'only-tcp': True, 'padding': variant == 4})
                self.assertEqual(proxy['cipher'], inbound['method'])
                self.assertEqual(proxy['password'], inbound['password'])
                if variant == 5:
                    self.assertEqual(proxy['plugin'], 'shadow-tls')
                    self.assertEqual(config['inbounds'][0]['detour'], inbound['tag'])

    def test_plain_vless_has_no_tls_or_reality(self):
        self.generate(kind='vless')
        inbound = self.read('config.json')['inbounds'][0]
        proxy = self.read('client.yaml')['proxies'][0]
        self.assertEqual(inbound['type'], 'vless')
        self.assertEqual(inbound['tls'], {'enabled': False})
        self.assertEqual(inbound['users'][0]['flow'], '')
        self.assertEqual(proxy['uuid'], inbound['users'][0]['uuid'])
        self.assertFalse(proxy['tls'])
        self.assertEqual(proxy['network'], 'tcp')
        self.assertNotIn('flow', proxy)
        self.assertNotIn('reality-opts', proxy)
        url = self.read('metadata.json')['tcp-node-test']['share_link']
        self.assertEqual(parse_qs(urlsplit(url).query),
                         {'security': ['none'], 'encryption': ['none'], 'type': ['tcp']})


@unittest.skipUnless(TOOLS['yq'], 'set TEST_YQ for YAML and view tests')
class ExportTests(NodeFixture):
    def assert_link(self, link, proxy):
        uri = urlsplit(link)
        userinfo = base64.urlsafe_b64decode(uri.username + '=' * (-len(uri.username) % 4)).decode()
        self.assertEqual(userinfo, proxy['cipher'] + ':' + proxy['password'])
        self.assertEqual(uri.hostname, proxy['server'])
        self.assertEqual(uri.port, proxy['port'])
        self.assertEqual(unquote(uri.fragment), proxy['name'])
        params = parse_qs(uri.query)
        self.assertEqual(json.loads(params['smux'][0]), proxy['smux'])
        self.assertEqual(params['udp'], ['0'])
        if proxy.get('plugin'):
            plugin, *options = params['plugin'][0].split(';')
            self.assertEqual(plugin, proxy['plugin'])
            opts = dict(item.split('=', 1) for item in options)
            opts['version'] = int(opts['version'])
            self.assertEqual(opts, proxy['plugin-opts'])

    def test_links_and_view_preserve_ss_smux(self):
        for variant in range(1, 6):
            with self.subTest(variant=variant):
                created = self.generate(variant=variant)
                proxy = self.read('client.yaml')['proxies'][0]
                link = self.read('metadata.json')['tcp-node-test']['share_link']
                self.assert_link(link, proxy)
                self.assertIn(link, created.stdout)
                self.assertNotIn('smux:', created.stdout)
                viewed = self.run_shell('view', 'n\n')
                self.assertIn(link, viewed.stdout)
                self.assertEqual(viewed.stdout.count('ss://'), 1)
                aggregate = self.run_shell('view', 'y\n')
                self.assertIn(base64.b64encode((link + '\n').encode()).decode(), aggregate.stdout)

    def test_link_preserves_ipv6_and_special_credentials(self):
        self.generate(variant=1)
        client = self.read('client.yaml')
        proxy = client['proxies'][0]
        proxy.update(name='落地 "A" #&?/\\', server='2001:db8::1', password='密码:+/#&?=%')
        (self.root / 'client.yaml').write_text(json.dumps(client))
        link = self.run_shell('link', TEST_NAME=proxy['name']).stdout.strip()
        self.assert_link(link, proxy)

    def test_ss_link_import_preserves_padding_and_multiplex(self):
        for variant in [1, 3, 4]:
            with self.subTest(variant=variant):
                self.generate(variant=variant)
                link = self.read('metadata.json')['tcp-node-test']['share_link']
                result = subprocess.run(['bash', str(REPO / 'parser.sh'), link],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)['multiplex'],
                                 {'enabled': True, 'protocol': 'h2mux', 'padding': variant == 4,
                                  'max_connections': 4, 'min_streams': 4})

    def test_view_reconstructs_plain_vless_link(self):
        self.generate(kind='vless')
        (self.root / 'metadata.json').write_text('{}')
        viewed = self.run_shell('view', 'n\n')
        self.assertIn('security=none&encryption=none&type=tcp', viewed.stdout)
        self.assertNotIn('security=tls', viewed.stdout)
        self.assertNotIn('security=reality', viewed.stdout)
        self.assertNotIn('mihomo 节点 YAML', viewed.stdout)

    @unittest.skipUnless(os.environ.get('TEST_SUBSTORE_SOURCE'), 'set TEST_SUBSTORE_SOURCE for official parser tests')
    def test_substore_preserves_all_ss_fields(self):
        nodes = []
        for variant in range(1, 6):
            self.generate(variant=variant)
            nodes.append({'link': self.read('metadata.json')['tcp-node-test']['share_link'],
                          'proxy': self.read('client.yaml')['proxies'][0]})
        result = subprocess.run(['node', str(REPO / 'tests/substore_smux.cjs')],
                                input=json.dumps(nodes), text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class Target(http.server.BaseHTTPRequestHandler):
    payload = bytes(range(256)) * 1024

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(self.payload)))
        self.end_headers()
        self.wfile.write(self.payload)

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        digest = hashlib.sha256(body).hexdigest().encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(digest)))
        self.end_headers()
        self.wfile.write(digest)

    def log_message(self, *args):
        pass


@unittest.skipUnless(all(TOOLS.values()), 'set TEST_YQ, TEST_SINGBOX and TEST_MIHOMO for real-core tests')
class TrafficTests(NodeFixture):
    @staticmethod
    def port():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            return sock.getsockname()[1]

    def start(self, args, port, label, env=None):
        logpath = self.root / (label + '.log')
        with logpath.open('w') as log:
            proc = subprocess.Popen(args, stdout=log, stderr=log, env=env)
        def stop():
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        self.addCleanup(stop)
        for _ in range(100):
            if proc.poll() is not None:
                self.fail(logpath.read_text()[-2000:])
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    time.sleep(.15)
                    return proc
            except OSError:
                time.sleep(.03)
        self.fail(label + ' did not listen: ' + logpath.read_text()[-2000:])

    @staticmethod
    def readexact(sock, size):
        body = bytearray()
        while len(body) < size:
            part = sock.recv(size - len(body))
            if not part:
                raise RuntimeError('connection closed early')
            body.extend(part)
        return bytes(body)

    def transfer(self, proxy_port, target_port, upload=False):
        with socket.create_connection(('127.0.0.1', proxy_port), timeout=5) as sock:
            sock.sendall(b'\x05\x01\x00')
            self.assertEqual(self.readexact(sock, 2), b'\x05\x00')
            sock.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01' + target_port.to_bytes(2, 'big'))
            self.assertEqual(self.readexact(sock, 4), b'\x05\x00\x00\x01')
            self.readexact(sock, 6)
            payload = Target.payload if upload else b''
            method = 'POST' if upload else 'GET'
            sock.sendall((method + ' / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: '
                          + str(len(payload)) + '\r\n\r\n').encode() + payload)
            with sock.makefile('rb') as response:
                self.assertIn(b'200', response.readline())
                length = None
                while True:
                    line = response.readline()
                    if line == b'\r\n':
                        break
                    if not line:
                        raise RuntimeError('incomplete HTTP headers')
                    if line.lower().startswith(b'content-length:'):
                        length = int(line.split(b':', 1)[1])
                body = response.read(length)
            self.assertEqual(body, hashlib.sha256(payload).hexdigest().encode() if upload else Target.payload)

    def exercise(self, kind, variant=3):
        inbound_port, client_port = self.port(), self.port()
        self.generate(kind=kind, variant=variant, TEST_PORT=str(inbound_port))
        client_env = None
        if kind == 'ss' and variant == 5:
            cert, key = self.root / 'cert.pem', self.root / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(key), '-out', str(cert), '-subj', '/CN=localhost',
                            '-addext', 'subjectAltName=DNS:localhost', '-days', '1'],
                           check=True, capture_output=True)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_3
            context.load_cert_chain(str(cert), str(key))
            fallback = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Target)
            fallback.socket = context.wrap_socket(fallback.socket, server_side=True)
            self.addCleanup(fallback.server_close)
            self.addCleanup(fallback.shutdown)
            threading.Thread(target=fallback.serve_forever, daemon=True).start()
            config = self.read('config.json')
            config['inbounds'][0]['handshake']['server_port'] = fallback.server_port
            (self.root / 'config.json').write_text(json.dumps(config))
            client_env = dict(os.environ, SSL_CERT_FILE=str(cert))
        proxy = self.read('client.yaml')['proxies'][0]
        if kind == 'ss':
            proxy['name'] = 'SS 测试 "quoted" \\ node'
            clients = self.read('client.yaml')
            clients['proxies'][0] = proxy
            (self.root / 'client.yaml').write_text(json.dumps(clients))
        proxy = self.export_proxy(proxy['name'])
        target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Target)
        self.addCleanup(target.server_close)
        self.addCleanup(target.shutdown)
        threading.Thread(target=target.serve_forever, daemon=True).start()
        self.start([TOOLS['singbox'], 'run', '-c', str(self.root / 'config.json')], inbound_port, 'server')
        client = {'socks-port': client_port, 'bind-address': '127.0.0.1', 'mode': 'rule',
                  'log-level': 'warning', 'dns': {'enable': False}, 'proxies': [proxy],
                  'rules': ['MATCH,' + proxy['name']]}
        path = self.root / 'mihomo.json'
        path.write_text(json.dumps(client))
        self.start([TOOLS['mihomo'], '-d', str(self.root), '-f', str(path)], client_port, 'client', env=client_env)
        self.transfer(client_port, target.server_port)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            jobs = [pool.submit(self.transfer, client_port, target.server_port, bool(i % 2)) for i in range(16)]
            for job in jobs:
                job.result()
        if kind == 'ss':
            connections = 0
            for path in [Path('/proc/net/tcp'), Path('/proc/net/tcp6')]:
                for line in path.read_text().splitlines()[1:]:
                    fields = line.split()
                    if fields[3] == '01' and int(fields[2].rsplit(':', 1)[1], 16) == inbound_port:
                        connections += 1
            self.assertGreater(connections, 0, 'multiplex transport should remain open after application requests')
            self.assertLessEqual(connections, proxy['smux']['max-connections'])

    def export_proxy(self, name):
        return next(proxy for proxy in self.read('client.yaml')['proxies'] if proxy['name'] == name)

    def test_ss_aes256(self):
        self.exercise('ss', 1)

    def test_ss_chacha(self):
        self.exercise('ss', 2)

    def test_ss2022(self):
        self.exercise('ss', 3)

    def test_ss2022_padding(self):
        self.exercise('ss', 4)

    def test_ss2022_shadowtls(self):
        self.exercise('ss', 5)

    def test_plain_vless(self):
        self.exercise('vless')

    def test_ss2022_multiplex_hop_to_plain_vless(self):
        hop_port, exit_port, client_port = self.port(), self.port(), self.port()
        self.generate(variant=3, TEST_PORT=str(hop_port))
        hop_proxy = self.read('client.yaml')['proxies'][0]
        hop_config = self.root / 'hop.json'
        hop_config.write_text(json.dumps(self.read('config.json')))
        self.generate(kind='vless', TEST_PORT=str(exit_port))
        exit_proxy = self.read('client.yaml')['proxies'][0]
        exit_proxy['dialer-proxy'] = hop_proxy['name']
        target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Target)
        self.addCleanup(target.server_close)
        self.addCleanup(target.shutdown)
        threading.Thread(target=target.serve_forever, daemon=True).start()
        self.start([TOOLS['singbox'], 'run', '-c', str(hop_config)], hop_port, 'hop')
        self.start([TOOLS['singbox'], 'run', '-c', str(self.root / 'config.json')], exit_port, 'exit')
        client = {'socks-port': client_port, 'bind-address': '127.0.0.1', 'mode': 'rule',
                  'log-level': 'warning', 'dns': {'enable': False},
                  'proxies': [hop_proxy, exit_proxy], 'rules': ['MATCH,' + exit_proxy['name']]}
        path = self.root / 'chain.json'
        path.write_text(json.dumps(client))
        self.start([TOOLS['mihomo'], '-d', str(self.root), '-f', str(path)], client_port, 'chain')
        self.transfer(client_port, target.server_port)
        self.transfer(client_port, target.server_port, upload=True)

    def test_shadowtls_config(self):
        self.generate(variant=5)
        result = subprocess.run([TOOLS['singbox'], 'check', '-c', str(self.root / 'config.json')],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
