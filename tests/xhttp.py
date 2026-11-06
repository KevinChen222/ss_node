#!/usr/bin/env python3
"""Isolated XHTTP lifecycle and real mihomo -> Nginx -> Xray traffic tests.

Set TEST_XRAY, TEST_MIHOMO, TEST_NGINX, TEST_YQ and TEST_SINGBOX to local binaries.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
TOOLS = {name: os.environ.get('TEST_' + name.upper()) for name in ('xray', 'mihomo', 'nginx', 'yq', 'singbox')}


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR="$WORK"
CONFIG_FILE="$WORK/config.json"
METADATA_FILE="$WORK/metadata.json"
CLASH_YAML_FILE="$WORK/clash.yaml"
XRAY_CONFIG_FILE="$WORK/xray.json"
XRAY_PID_FILE="$WORK/xray.pid"
XRAY_LOG_FILE="$WORK/xray.log"
XRAY_BIN="$TEST_XRAY"
SINGBOX_BIN="$TEST_SINGBOX"
YQ_BINARY="$TEST_YQ"
PID_FILE="$WORK/singbox.pid"
INIT_SYSTEM=direct
NGINX_CONF_DIR="$WORK/conf.d"
NGINX_CERT_DIR="$WORK/certs"
NGINX_BACKUP_DIR="$WORK/backup"
SNI_ROUTER_HTTPS_BACKEND_PORT="${HTTPS_BACKEND:-8444}"
SNI_ROUTER_PUBLIC_PORT="${ROUTER_PUBLIC:-443}"
SNI_ROUTER_STATE_DIR="$WORK/router"
SNI_ROUTER_STATE_FILE="$WORK/router/state.json"
SNI_ROUTER_LOCK_FILE="$WORK/router.lock"
SNI_ROUTER_HAPROXY_CONF="$WORK/haproxy.cfg"
SNI_ROUTER_HAPROXY_BACKUP_DIR="$WORK/router-backup"
NFT_PERSIST_FILE="$WORK/nft.rules"
NODE_NFT_CONFIG_FILE="$WORK/nft.conf"
PROXYALL_WRITE_LOCK_FILE="$WORK/write.lock"
server_ip=127.0.0.1
nginx() { "$TEST_NGINX" -p "$WORK/" -c "$WORK/nginx.conf" "$@"; }
_sb_reload_or_start_nginx() { nginx -t && nginx -s reload; }
_ensure_local_origin_dependencies() { return 0; }
_install_xray() { _atomic_modify_json "$XRAY_CONFIG_FILE" '.outbounds[0].settings.finalRules=[{action:"allow",ip:["127.0.0.1/32"]}]'; }
_manage_singbox_service_impl() {
    if [ "$1" = restart ] && [ "${NODE_TX_STARTED:-0}" = 1 ]; then
        _node_tx_publish || return 1
        touch "$NODE_TX_DIR/service-touched"
    fi
    [ "${FAIL_RESTART:-0}" != 1 ]
}
_sni_router_require_systemd() { return 0; }
_sni_router_prepare() { _node_tx_begin && _sni_router_init_state; }
_sni_router_apply() { return 0; }
case "$ACTION" in
    add) _add_vless_xhttp_tls ;;
    view) _view_nodes ;;
    delete) _delete_node ;;
    modify) _modify_port ;;
    stop) _xray_service stop ;;
    haproxy) _sni_router_generate_haproxy_config "$WORK/haproxy.raw" ;;
    render) _xhttp_nginx_config xhttp.test /test/ 10080 443 true ;;
    *) exit 2 ;;
esac
'''


class Echo(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(self.server.payload)))
        self.end_headers()
        self.wfile.write(self.server.payload)

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        result = hashlib.sha256(body).hexdigest().encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(result)))
        self.end_headers()
        self.wfile.write(result)

    def log_message(self, *args):
        pass


@unittest.skipUnless(all(TOOLS.values()), 'set TEST_XRAY, TEST_MIHOMO, TEST_NGINX, TEST_YQ, TEST_SINGBOX')
class XHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-xhttp-test-')
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.procs = []
        self.addCleanup(self.stop)
        for name in ('conf.d', 'certs/xhttp.test', 'backup', 'logs'):
            (self.root / name).mkdir(parents=True)
        certdir = self.root / 'certs/xhttp.test'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(certdir / 'key'), '-out', str(certdir / 'cert'),
                        '-subj', '/CN=xhttp.test', '-addext', 'subjectAltName=DNS:xhttp.test',
                        '-days', '30'], check=True, capture_output=True)
        self.webport, self.public = port(), port()
        (self.root / 'nginx.conf').write_text(f'''
error_log {self.root}/nginx.log;
pid {self.root}/nginx.pid;
worker_processes 1;
events {{ worker_connections 1024; }}
http {{
    access_log off;
    client_body_temp_path {self.root}/body;
    proxy_temp_path {self.root}/proxy;
    fastcgi_temp_path {self.root}/fastcgi;
    uwsgi_temp_path {self.root}/uwsgi;
    scgi_temp_path {self.root}/scgi;
    include {self.root}/conf.d/*.conf;
    server {{ listen 127.0.0.1:{self.webport}; location / {{ return 200 'website'; }} }}
}}
''')
        self.nginx = self.start([TOOLS['nginx'], '-p', str(self.root) + '/', '-c', str(self.root / 'nginx.conf'), '-g', 'daemon off;'], self.webport)
        (self.root / 'config.json').write_text(json.dumps({'inbounds': [], 'outbounds': [{'type': 'direct', 'tag': 'direct'}]}))
        (self.root / 'metadata.json').write_text('{}')
        (self.root / 'clash.yaml').write_text('proxies: []\nproxy-groups:\n  - name: 节点选择\n    type: select\n    proxies: [DIRECT]\n')
        (self.root / 'harness.sh').write_text(HARNESS)
        self.env = dict(os.environ, WORK=str(self.root), REPO=str(REPO), **{'TEST_' + k.upper(): v for k, v in TOOLS.items()})

    def stop(self):
        if hasattr(self, 'env'):
            self.run_shell('stop', check=False)
        for proc in reversed(self.procs):
            proc.terminate()
            try:
                proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def start(self, args, listen, env=None):
        log = open(self.root / f'proc-{len(self.procs)}.log', 'w')
        self.addCleanup(log.close)
        proc = subprocess.Popen(args, stdout=log, stderr=log, env=env)
        self.procs.append(proc)
        for _ in range(80):
            if proc.poll() is not None:
                self.fail(Path(log.name).read_text())
            try:
                with socket.create_connection(('127.0.0.1', listen), timeout=.1):
                    return proc
            except OSError:
                time.sleep(.05)
        self.fail('listener did not start: ' + str(args))

    def run_shell(self, action, answers='', check=True, **extra):
        result = subprocess.run(['bash', str(self.root / 'harness.sh')], input=answers, text=True,
                                env=dict(self.env, ACTION=action, **extra), capture_output=True, timeout=40)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-4000:])
        return result

    def add(self, domain='xhttp.test', name='XHTTP test', **extra):
        return self.run_shell('add', f'\n{domain}\n{self.public}\n/test/\n{name}\n', **extra)

    def json(self, name):
        return json.loads((self.root / name).read_text())

    def snapshot(self):
        return {p.name: p.read_bytes() for p in self.root.iterdir() if p.name in
                ('config.json', 'metadata.json', 'clash.yaml', 'xray.json')}

    def test_real_mihomo_h2_upload_download_and_lifecycle(self):
        self.add()
        cfg = self.json('xray.json')
        self.assertEqual(cfg['inbounds'][0]['listen'], '127.0.0.1')
        self.assertEqual(cfg['inbounds'][0]['streamSettings']['xhttpSettings']['mode'], 'stream-up')
        yaml = subprocess.check_output([TOOLS['yq'], '-o=json', str(self.root / 'clash.yaml')], text=True)
        proxy = json.loads(yaml)['proxies'][0]
        self.assertEqual(proxy['alpn'], ['h2'])
        self.assertFalse(proxy['skip-cert-verify'])
        self.assertNotIn('flow', proxy)
        self.assertNotIn('smux', proxy)
        mixed = port()
        client = {'mixed-port': mixed, 'mode': 'rule', 'log-level': 'info', 'proxies': [proxy], 'rules': ['MATCH,' + proxy['name']]}
        (self.root / 'mihomo.json').write_text(json.dumps(client))
        env = dict(os.environ, SSL_CERT_FILE=str(self.root / 'certs/xhttp.test/cert'))
        subprocess.run([TOOLS['mihomo'], '-t', '-d', str(self.root), '-f', str(self.root / 'mihomo.json')], env=env, check=True, capture_output=True)
        self.start([TOOLS['mihomo'], '-d', str(self.root), '-f', str(self.root / 'mihomo.json')], mixed, env)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Echo)
        server.payload = os.urandom(1024 * 1024)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f'http://127.0.0.1:{server.server_port}/'
        curl = ['curl', '-fsS', '--noproxy', '', '--max-time', '15', '-x', f'http://127.0.0.1:{mixed}']
        result = subprocess.run(curl + [url], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode() + '\n'.join(p.read_text()[-6000:] for p in self.root.glob('*.log')))
        self.assertEqual(result.stdout, server.payload)
        uploaded = subprocess.check_output(curl + ['--data-binary', '@-', url], input=server.payload)
        self.assertEqual(uploaded.decode(), hashlib.sha256(server.payload).hexdigest())
        view = self.run_shell('view').stdout
        self.assertIn('type=xhttp', view)
        self.assertIn('alpn=h2', view)
        self.assertIn(str(self.public), view)
        self.assertEqual(subprocess.check_output(['curl', '-fsS', f'http://127.0.0.1:{self.webport}/']), b'website')
        newport = port()
        self.run_shell('modify', f'1\n{newport}\n')
        self.assertEqual(next(iter(self.json('metadata.json').values()))['publicPort'], newport)
        self.assertIn(f':{newport}?', next(iter(self.json('metadata.json').values()))['share_link'])
        self.run_shell('delete', '1\ny\n')
        self.assertEqual(self.json('xray.json')['inbounds'], [])
        self.assertEqual(self.json('metadata.json'), {})
        self.assertTrue((self.root / 'certs/xhttp.test/cert').exists())
        self.assertEqual(subprocess.check_output(['curl', '-fsS', f'http://127.0.0.1:{self.webport}/']), b'website')

    def test_restart_failure_rolls_back(self):
        self.add()
        before = self.snapshot()
        result = self.run_shell('modify', f'1\n{port()}\n', check=False, FAIL_RESTART='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(len(list((self.root / 'conf.d').glob('*.xhttp.conf'))), 1)

    def test_failed_creation_leaves_no_node(self):
        before = self.snapshot()
        self.add(check=False, FAIL_RESTART='1')
        self.assertEqual(before, self.snapshot())
        self.assertEqual(list((self.root / 'conf.d').glob('*.xhttp.conf')), [])

    def test_duplicate_domain_rejected(self):
        self.add()
        before = self.snapshot()
        result = self.add(name='other', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.snapshot())

    def test_unsafe_path_rejected_before_writes(self):
        before = self.snapshot()
        result = self.run_shell('add', f'\nxhttp.test\n{self.public}\n/x;return 200;/\n', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.snapshot())

    @unittest.skipUnless(os.environ.get('TEST_HAPROXY'), 'set TEST_HAPROXY for shared TLS entry test')
    def test_haproxy_shared_tls_entry(self):
        backend, frontend = port(), port()
        self.env['HTTPS_BACKEND'] = str(backend)
        self.env['ROUTER_PUBLIC'] = str(frontend)
        (self.root / 'conf.d/emby.conf').write_text(f"""
server {{
    listen 127.0.0.1:{backend} ssl proxy_protocol http2;
    server_name emby.test;
    ssl_certificate {self.root}/certs/xhttp.test/cert;
    ssl_certificate_key {self.root}/certs/xhttp.test/key;
    location / {{ return 200 'emby'; }}
}}
""")
        (self.root / 'router').mkdir()
        state = {'version': 1, 'public_port': frontend, 'reality': None,
                 'https_backend': {'host': '127.0.0.1', 'port': backend},
                 'https_routes': {'emby.test': {'owner': 'nginx-proxy'}}, 'tls_routes': {}}
        (self.root / 'router/state.json').write_text(json.dumps(state))
        self.run_shell('add', '\nxhttp.test\n443\ny\n/test/\nShared XHTTP\n')
        state = self.json('router/state.json')
        self.assertEqual(state['https_routes']['emby.test']['owner'], 'nginx-proxy')
        self.assertEqual(state['https_routes']['xhttp.test']['owner'], 'sb-xhttp')
        self.run_shell('haproxy')
        raw = (self.root / 'haproxy.raw').read_text()
        config = '\n'.join(line for line in raw.splitlines() if not line.strip().startswith(('user ', 'group ', 'stats socket ')))
        (self.root / 'haproxy.test').write_text(config + '\n')
        self.start([os.environ['TEST_HAPROXY'], '-db', '-f', str(self.root / 'haproxy.test')], frontend)
        result = subprocess.check_output(['curl', '-kfsS', '--noproxy', '*', '--resolve',
                                          f'emby.test:{frontend}:127.0.0.1', f'https://emby.test:{frontend}/'])
        self.assertEqual(result, b'emby')
        # TLS and H2 reach the XHTTP virtual host through PROXY protocol.
        tls = subprocess.run(['openssl', 's_client', '-connect', f'127.0.0.1:{frontend}',
                              '-servername', 'xhttp.test', '-alpn', 'h2'], input='', text=True,
                             capture_output=True, timeout=5)
        self.assertIn('ALPN protocol: h2', tls.stdout)
        self.assertIn('CN = xhttp.test', tls.stdout)
        self.run_shell('delete', '1\ny\n')
        remaining = self.json('router/state.json')
        self.assertEqual(remaining['https_routes'], {'emby.test': {'owner': 'nginx-proxy'}})
        self.assertEqual(remaining['https_backend']['port'], backend)
        self.assertTrue((self.root / 'conf.d/emby.conf').exists())

    def test_shared_listener_render(self):
        rendered = self.run_shell('render').stdout
        self.assertIn('listen 127.0.0.1:8444 ssl proxy_protocol http2;', rendered)
        self.assertIn('grpc_pass grpc://127.0.0.1:10080;', rendered)


if __name__ == '__main__':
    unittest.main(verbosity=2)
