#!/usr/bin/env python3
"""Isolated XHTTP lifecycle and real mihomo -> Nginx -> Xray traffic tests.

Set TEST_XRAY, TEST_MIHOMO, TEST_NGINX and TEST_YQ to local binaries.
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
TOOLS = {name: os.environ.get('TEST_' + name.upper()) for name in ('xray', 'mihomo', 'nginx', 'yq')}


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
XRAY_ONLY=true
SINGBOX_BIN="$WORK/no-sing-box"
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
_manage_service() { [ "${FAIL_RESTART:-0}" != 1 ] && _xray_service "$@"; }
_sni_router_require_systemd() { return 0; }
_sni_router_prepare() { _node_tx_begin && _sni_router_init_state; }
_sni_router_apply() { return 0; }
case "$ACTION" in
    retire)
        INIT_SYSTEM=systemd
        SERVICE_FILE="$WORK/legacy.service"
        systemctl() { if [ "$1" = show ]; then echo "$SERVICE_FILE"; else echo "$*" >> "$WORK/service.calls"; fi; }
        _sni_router_apply() { [ "${FAIL_APPLY:-0}" != 1 ]; }
        _retire_legacy_service ;;
    vision) BATCH_MODE=true BATCH_PORT="$PORT" BATCH_SNI=xhttp.test BATCH_IP=127.0.0.1 BATCH_REALITY_HANDSHAKE_SERVER=127.0.0.1 BATCH_REALITY_HANDSHAKE_PORT="$ORIGIN" BATCH_VISION_PROFILE="$PROFILE" _node_operation _add_vless_reality_impl ;;
    native) _node_operation _xray_native_add ;;
    relay) _node_operation _xray_manage_node relay ;;
    add) _add_vless_xhttp_tls ;;
    view) _xray_list_links ;;
    delete) _node_operation _xray_manage_node delete ;;
    modify) _node_operation _xray_manage_node port ;;
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


@unittest.skipUnless(all(TOOLS.values()), 'set TEST_XRAY, TEST_MIHOMO, TEST_NGINX, TEST_YQ')
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

    def add(self, domain='xhttp.test', name='XHTTP test', concurrency='', enc='', **extra):
        return self.run_shell('add', f'\n{domain}\n{self.public}\n/test/\n{name}\n{concurrency}\n{enc}\n', **extra)

    def json(self, name):
        return json.loads((self.root / name).read_text())

    def snapshot(self):
        return {p.name: p.read_bytes() for p in self.root.iterdir() if p.name in
                ('config.json', 'metadata.json', 'clash.yaml', 'xray.json')}

    def exported(self, link):
        return json.loads(subprocess.check_output(['node', str(REPO / 'tests/substore_link.mjs')], input=link, text=True))

    def test_retire_preserves_https_and_xray(self):
        router=self.root/'router'; router.mkdir()
        state={'version':1,'public_port':443,'reality':{'owner':'advanced-relay','tag':'old'},
               'https_routes':{'emby.test':{'owner':'nginx-proxy'}},
               'tls_routes':{'xray.test':{'owner':'sb-xray'},'old.test':{'owner':'sb'}}}
        (router/'state.json').write_text(json.dumps(state))
        (self.root/'.managed_sing_box').touch()
        (self.root/'legacy.service').write_text(f'ExecStart={self.root}/no-sing-box run -c {self.root}/config.json -c {self.root}/relay.json\n')
        (self.root/'relay.json').write_text('{"inbounds":[]}')
        before=self.snapshot()
        self.assertNotEqual(self.run_shell('retire','RETIRE\n',FAIL_APPLY='1',check=False).returncode,0)
        self.assertEqual(before,self.snapshot())
        self.assertEqual(self.json('router/state.json'),state)
        self.run_shell('retire','RETIRE\n')
        self.assertFalse((self.root/'config.json').exists())
        self.assertFalse((self.root/'relay.json').exists())
        self.assertTrue(any(self.root.glob('retired.*/config.json')))
        self.assertEqual(self.json('router/state.json'),dict(state,reality=None,tls_routes={'xray.test':{'owner':'sb-xray'}}))
        self.assertNotIn('proxyall-xray',(self.root/'service.calls').read_text())

    def check_udp(self, mixed):
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as origin, socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as client, socket.create_connection(('127.0.0.1',mixed),timeout=4) as tcp:
            origin.settimeout(5); client.settimeout(5)
            origin.bind(('127.0.0.1',0))
            tcp.sendall(b'\x05\x01\x00')
            self.assertEqual(tcp.recv(2,socket.MSG_WAITALL),b'\x05\x00')
            tcp.sendall(bytes.fromhex('05030001000000000000'))
            reply=tcp.recv(10,socket.MSG_WAITALL)
            self.assertEqual(reply[:4],bytes.fromhex('05000001'))
            header=bytes.fromhex('000000017f000001')+origin.getsockname()[1].to_bytes(2,'big')
            client.sendto(header+b'udp-test',('127.0.0.1',int.from_bytes(reply[-2:],'big')))
            payload, address=origin.recvfrom(256)
            self.assertEqual(payload,b'udp-test')
            origin.sendto(b'udp-ok',address)
            self.assertEqual(client.recv(256),header+b'udp-ok')

    @unittest.skipUnless(os.environ.get('TEST_SUBSTORE'), 'set TEST_SUBSTORE for exported Vision traffic')
    def test_vision_profiles_from_empty_install(self):
        for filename in ('config.json', 'metadata.json', 'clash.yaml'):
            (self.root/filename).unlink()
        origin = port()
        self.start(['openssl','s_server','-accept',f'127.0.0.1:{origin}','-tls1_3','-alpn','h2','-www',
                    '-cert',str(self.root/'certs/xhttp.test/cert'),'-key',str(self.root/'certs/xhttp.test/key')], origin)
        for profile in ('none','x25519','mlkem768'):
            with self.subTest(profile=profile):
                public = port()
                self.run_shell('vision', PORT=str(public), ORIGIN=str(origin), PROFILE=profile)
                meta = next(m for m in self.json('metadata.json').values() if m['publicPort']==public)
                client = self.exported(meta['share_link'])
                expected = json.loads(subprocess.check_output([TOOLS['yq'],'-o=json',str(self.root/'clash.yaml')]))['proxies']
                for key, value in next(p for p in expected if p['port']==public).items():
                    self.assertEqual(client.get(key), value, key)
                mixed=port()
                cfg=self.root/f'{profile}.json'
                cfg.write_text(json.dumps({'mixed-port':mixed,'proxies':[client],'rules':['MATCH,'+client['name']]}))
                home=self.root/profile; home.mkdir()
                self.start([TOOLS['mihomo'],'-d',str(home),'-f',str(cfg)],mixed)
                res=subprocess.run(['curl','-fsS','--noproxy','','-x',f'http://127.0.0.1:{mixed}','--max-time','5',f'http://127.0.0.1:{self.webport}'],capture_output=True)
                self.assertEqual(res.stdout,b'website',(res.stderr,(self.root/f'proc-{len(self.procs)-1}.log').read_text()[-1600:],(self.root/'xray.log').read_text()[-800:]))
                self.check_udp(mixed)
        self.assertFalse((self.root/'config.json').exists())
        self.assertFalse((self.root/'relay.json').exists())
        nodes = self.json('metadata.json')
        inlet = next(tag for tag, node in nodes.items() if node['publicPort'] == public)
        selection = list(nodes).index(inlet) + 1
        for variant, protocol in ((2, 'shadowsocks'), (1, 'vless')):
            with self.subTest(landing=protocol):
                landing_port = port()
                self.run_shell('native', f'{variant}\n127.0.0.1\n{landing_port}\nlanding-{protocol}\n' + ('\n' if variant == 1 else ''))
                landing, meta = next((tag, node) for tag, node in self.json('metadata.json').items()
                                     if node['publicPort'] == landing_port)
                self.run_shell('relay', f"{selection}\n{meta['share_link']}\n")
                # Start a fresh client after the server restart for each landing handshake.
                mixed = port()
                cfg = self.root/f'relay-{protocol}.json'
                cfg.write_text(json.dumps({'mixed-port': mixed, 'proxies': [client],
                                           'rules': ['MATCH,' + client['name']]}))
                self.start([TOOLS['mihomo'], '-d', str(self.root/f'client-{protocol}'), '-f', str(cfg)], mixed)
                response = subprocess.run(['curl', '-fsS', '--max-time', '5', '--noproxy', '',
                                           '-x', f'http://127.0.0.1:{mixed}',
                                           f'http://127.0.0.1:{self.webport}/'], capture_output=True)
                self.assertEqual(response.stdout, b'website', (response.stderr, (self.root/'xray.log').read_text()[-2500:],
                                                               (self.root/f'proc-{len(self.procs)-1}.log').read_text()[-1000:]))
                self.check_udp(mixed)
                log = (self.root/'xray.log').read_text()
                for transport in ('tcp', 'udp'):
                    self.assertRegex(log, rf'accepted {transport}:.*\[{landing} >> direct\]')

    @unittest.skipUnless(os.environ.get('TEST_SUBSTORE'), 'set TEST_SUBSTORE for native exports')
    def test_native_exports_and_relay(self):
        for variant in range(1,7):
            with self.subTest(variant=variant):
                public=port()
                self.run_shell('native',f'{variant}\n127.0.0.1\n{public}\nnode{variant}\n' + ('xhttp.test\n' if variant>=4 else '\n' if variant == 1 else ''))
                meta=next(m for m in self.json('metadata.json').values() if m['publicPort']==public)
                proxy=self.exported(meta['share_link'])
                saved=json.loads(subprocess.check_output([TOOLS['yq'],'-o=json',str(self.root/'clash.yaml')]))
                for key,value in next(p for p in saved['proxies'] if p['port']==public).items():
                    if key=='tls' and variant==5: continue  # Trojan implies TLS in mihomo.
                    self.assertEqual(proxy.get(key),value,key)
                mixed=port()
                cfg=self.root/f'native{variant}.json'
                cfg.write_text(json.dumps({'mixed-port':mixed,'proxies':[proxy],'rules':['MATCH,'+proxy['name']]}))
                home=self.root/f'home{variant}'; home.mkdir()
                self.start([TOOLS['mihomo'],'-d',str(home),'-f',str(cfg)],mixed,dict(os.environ,SSL_CERT_FILE=str(self.root/'certs/xhttp.test/cert')))
                cmd=['curl','-fsS','--max-time','5','--noproxy','','-x',f'http://127.0.0.1:{mixed}',f'http://127.0.0.1:{self.webport}/']
                res=subprocess.run(cmd,capture_output=True)
                self.assertEqual(res.stdout,b'website',(res.stderr,(self.root/f'proc-{len(self.procs)-1}.log').read_text()[-1600:],(self.root/'xray.log').read_text()[-800:]))
                if variant in (1,2):  # VLESS TCP without TLS, Shadowsocks
                    self.check_udp(mixed)
                if variant==1:
                    ob=self.root/'out.json'
                    ob.write_text('{"protocol":"blackhole"}')
                    self.run_shell('relay',f'1\n{ob}\n')
                    self.assertNotEqual(subprocess.run(cmd,capture_output=True).returncode,0)
                    self.run_shell('relay','1\ndirect\n')
                    self.assertEqual(subprocess.run(cmd,capture_output=True).stdout,b'website')

    def test_real_mihomo_h2_upload_download_and_lifecycle(self):
        self.add()
        cfg = self.json('xray.json')
        self.assertEqual(cfg['inbounds'][0]['listen'], '127.0.0.1')
        self.assertEqual(cfg['inbounds'][0]['streamSettings']['xhttpSettings']['mode'], 'stream-up')
        yaml = subprocess.check_output([TOOLS['yq'], '-o=json', str(self.root / 'clash.yaml')], text=True)
        proxy = json.loads(yaml)['proxies'][0]
        self.assertEqual(proxy['alpn'], ['h2'])
        self.assertFalse(proxy['skip-cert-verify'])
        self.assertEqual(proxy['xhttp-opts']['reuse-settings']['max-concurrency'], '1')
        self.assertNotIn('flow', proxy)
        self.assertNotIn('smux', proxy)
        if os.environ.get('TEST_SUBSTORE'):
            exported=self.exported(next(iter(self.json('metadata.json').values()))['share_link'])
            for key,value in proxy.items(): self.assertEqual(exported.get(key),value,key)
            proxy=exported
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
        # The extra encryption must be enforced beyond the outer TLS connection.
        badport = port()
        bad = dict(proxy, encryption='none')
        (self.root / 'wrong-enc.json').write_text(json.dumps({'mixed-port': badport, 'proxies': [bad], 'rules': ['MATCH,' + bad['name']]}))
        self.start([TOOLS['mihomo'], '-d', str(self.root/'wrong-client'), '-f', str(self.root/'wrong-enc.json')], badport, env)
        rejected = subprocess.run(['curl', '-fsS', '--max-time', '4', '--noproxy', '', '-x', f'http://127.0.0.1:{badport}', url], capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
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

    @unittest.skipUnless(os.environ.get('TEST_SUBSTORE'), 'set TEST_SUBSTORE for exported XHTTP traffic')
    def test_xhttp_tls_other_enc_profiles(self):
        for choice in ('2', '3'):
            with self.subTest(choice=choice):
                self.add(enc=choice)
                meta = next(iter(self.json('metadata.json').values()))
                proxy = self.exported(meta['share_link'])
                expected = json.loads(subprocess.check_output([TOOLS['yq'], '-o=json', str(self.root/'clash.yaml')]))['proxies'][0]
                self.assertEqual(proxy['encryption'], expected['encryption'])
                self.assertEqual(proxy['encryption'] == 'none', choice == '3')
                mixed = port()
                cfg = self.root/f'enc-{choice}.json'
                cfg.write_text(json.dumps({'mixed-port':mixed,'proxies':[proxy],'rules':['MATCH,'+proxy['name']]}))
                self.start([TOOLS['mihomo'], '-d', str(self.root/f'client-{choice}'), '-f', str(cfg)], mixed,
                           dict(os.environ, SSL_CERT_FILE=str(self.root/'certs/xhttp.test/cert')))
                response = subprocess.run(['curl','-fsS','--max-time','5','--noproxy','','-x',f'http://127.0.0.1:{mixed}',f'http://127.0.0.1:{self.webport}/'],capture_output=True)
                self.assertEqual(response.stdout, b'website', response.stderr)
                self.run_shell('delete', '1\ny\n')

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
        self.run_shell('add', '\nxhttp.test\n443\ny\n/test/\nShared XHTTP\n\n\n')
        state = self.json('router/state.json')
        self.assertEqual(state['https_routes']['emby.test']['owner'], 'nginx-proxy')
        self.assertEqual(state['https_routes']['xhttp.test']['owner'], 'sb-xhttp')
        origin=port()
        self.start(['openssl','s_server','-accept',f'127.0.0.1:{origin}','-tls1_3','-alpn','h2','-www',
                    '-cert',str(self.root/'certs/xhttp.test/cert'),'-key',str(self.root/'certs/xhttp.test/key')],origin)
        # The same HAProxy has an HTTPS vhost and a default Reality backend.
        harness=self.root/'harness.sh'
        harness.write_text(HARNESS.replace('BATCH_SNI=xhttp.test','BATCH_SNI=vision.test'))
        self.run_shell('vision',PORT=str(frontend),ORIGIN=str(origin),PROFILE='x25519')
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
        def get_vision():
            m=next(m for m in self.json('metadata.json').values() if m['type']=='vless-vision-reality')
            if os.environ.get('TEST_SUBSTORE'): p=self.exported(m['share_link'])
            else: p=next(p for p in json.loads(subprocess.check_output([TOOLS['yq'],'-o=json',str(self.root/'clash.yaml')]))['proxies'] if p['name']==m['name'])
            mixed=port(); home=self.root/str(mixed); home.mkdir()
            cfg=home/'client.json'; cfg.write_text(json.dumps({'mixed-port':mixed,'proxies':[p],'rules':['MATCH,'+p['name']]}))
            self.start([TOOLS['mihomo'],'-d',str(home),'-f',str(cfg)],mixed)
            self.assertEqual(subprocess.check_output(['curl','-fsS','--max-time','5','--noproxy','','-x',f'http://127.0.0.1:{mixed}',f'http://127.0.0.1:{self.webport}/']),b'website')
        get_vision()
        before=self.json('metadata.json')
        self.run_shell('modify',f'2\n{port()}\n')
        get_vision()
        first=next(iter(before))
        self.assertEqual(before[first],self.json('metadata.json')[first])
        self.run_shell('delete','2\ny\n')
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
