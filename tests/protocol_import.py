#!/usr/bin/env python3
"""Validate imports and Reality; TEST_XRAY_REALITY_EXPECT is success or reject."""
import http.server
import base64
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
CORE = os.environ.get('TEST_SINGBOX')
XRAY_EXPECT = os.environ.get('TEST_XRAY_REALITY_EXPECT', 'success')
BASE = ('vless://bf000d23-0752-40b4-affe-68f7707a9661@example.com:443?'
        'security=reality&sni=example.com&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=0123456789abcdef&flow=xtls-rprx-vision&type=tcp')

class ImportTests(unittest.TestCase):
    def parse(self, extra='', base=BASE):
        p = subprocess.run(['bash', str(REPO/'parser.sh'), base+extra], capture_output=True, text=True)
        return p.returncode, json.loads(p.stdout)

    def test_plain_vless(self):
        for extra in ('', '&encryption=none', '&encryption=%6eone'):
            with self.subTest(extra=extra):
                rc, obj = self.parse(extra)
                self.assertEqual(rc, 0)
                self.assertEqual(obj['flow'], 'xtls-rprx-vision')
                self.assertTrue(obj['tls']['reality']['enabled'])

    def test_encryption_rejected(self):
        for value in ('mlkem768x25519plus.native.1rtt.test', '%6dlkem768x25519plus.native.1rtt.test', 'unknown', 'none&encryption=unknown'):
            with self.subTest(value=value):
                rc, obj = self.parse('&encryption='+value)
                self.assertNotEqual(rc, 0)
                self.assertIn('VLESS Encryption', obj['error'])

    def test_pqv_rejected(self):
        rc, obj = self.parse('&pqv=test')
        self.assertNotEqual(rc, 0)
        self.assertIn('pqv', obj['error'])

    def test_xhttp_rejected(self):
        rc, obj = self.parse(base=BASE.replace('type=tcp', 'type=xhttp'))
        self.assertNotEqual(rc, 0)
        self.assertIn('传输类型', obj['error'])

    def test_anytls_reality_preserved(self):
        rc, obj = self.parse(base=BASE.replace('vless://bf000d23-0752-40b4-affe-68f7707a9661', 'anytls://secret'))
        self.assertEqual(rc, 0)
        self.assertEqual(obj['type'], 'anytls')
        self.assertTrue(obj['tls']['reality']['enabled'])

    def vmess(self, **fields):
        node = dict(add='example.com', port='443',
                    id='bf000d23-0752-40b4-affe-68f7707a9661', net='tcp')
        node.update(fields)
        link = 'vmess://' + base64.urlsafe_b64encode(json.dumps(node).encode()).decode()
        return self.parse(base=link)

    def test_empty_credentials_rejected(self):
        for link in ('ss://@1.2.3.4:8388', 'ss://:secret@example.com:8388',
                     'ss://aes-128-gcm:@example.com:8388',
                     'ss://' + base64.b64encode(b'aes-128-gcm').decode() + '@example.com:8388',
                     'vless://@example.com:443', 'trojan://@example.com:443',
                     'trojan://%00@example.com:443'):
            with self.subTest(link=link):
                rc, obj = self.parse(base=link)
                self.assertNotEqual(rc, 0)
                self.assertIn('error', obj)
        for value in ('', None, 123):
            with self.subTest(uuid=value):
                rc, obj = self.vmess(id=value)
                self.assertNotEqual(rc, 0)
                self.assertIn('error', obj)

    def test_valid_credentials_preserved(self):
        for link, expected in (
                ('ss://aes-128-gcm:secret%3Arest@example.com:8388', {'method': 'aes-128-gcm', 'password': 'secret:rest'}),
                ('trojan://secret@example.com:443', {'password': 'secret'})):
            rc, obj = self.parse(base=link)
            self.assertEqual(rc, 0)
            for key, value in expected.items():
                self.assertEqual(obj[key], value)

    def test_vmess_aid_and_security(self):
        for aid in (64, '64', 0):
            with self.subTest(aid=aid):
                rc, obj = self.vmess(aid=aid, scy='aes-128-gcm')
                self.assertEqual(rc, 0, obj)
                self.assertEqual(obj['alter_id'], int(aid))
                self.assertEqual(obj['security'], 'aes-128-gcm')
        rc, obj = self.vmess()
        self.assertEqual(rc, 0, obj)
        self.assertEqual(obj['alter_id'], 0)
        self.assertEqual(obj['security'], 'auto')
        for fields in ({'aid': -1}, {'aid': 1.5}, {'aid': 'bad'}, {'aid': 65536}, {'scy': 'bad'}):
            with self.subTest(fields=fields):
                rc, obj = self.vmess(**fields)
                self.assertNotEqual(rc, 0)
                self.assertIn('error', obj)

    def test_tcp_headers_rejected(self):
        rc, obj = self.vmess(type='http', host='example.com', path='/')
        self.assertNotEqual(rc, 0)
        self.assertIn('TCP 伪装头', obj['error'])
        for link in (BASE + '&headerType=http', 'trojan://secret@example.com:443?headerType=http'):
            rc, obj = self.parse(base=link)
            self.assertNotEqual(rc, 0)
            self.assertIn('TCP 伪装头', obj['error'])
        for header in ('', 'none'):
            rc, obj = self.vmess(type=header)
            self.assertEqual(rc, 0, obj)
        rc, obj = self.vmess(net='ws', type='none', host='example.com', path='/ws')
        self.assertEqual(rc, 0, obj)
        self.assertEqual(obj['transport']['type'], 'ws')


class QuietHTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args):
        pass

@unittest.skipUnless(CORE, 'set TEST_SINGBOX for real-core tests')
class RealityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-reality-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.processes = []
        self.addCleanup(self.stop)
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(self.root/'key'),'-out',str(self.root/'cert'),'-subj','/CN=localhost','-days','1'], check=True, capture_output=True)
        self.origin = self.port()
        self.start(['openssl','s_server','-accept',f'127.0.0.1:{self.origin}','-cert',str(self.root/'cert'),'-key',str(self.root/'key'),'-tls1_3','-alpn','h2,http/1.1','-www'], self.origin)
        self.http = http.server.ThreadingHTTPServer(('127.0.0.1',0), QuietHTTP)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        keys = subprocess.check_output([CORE,'generate','reality-keypair'],text=True)
        self.keys = dict(line.split(': ',1) for line in keys.strip().splitlines())

    def stop(self):
        for p in self.processes:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill(); p.wait()

    @staticmethod
    def port():
        with socket.socket() as s:
            s.bind(('127.0.0.1',0))
            return s.getsockname()[1]

    def start(self, args, port):
        log = open(self.root/f'process-{len(self.processes)}.log','w')
        self.addCleanup(log.close)
        p = subprocess.Popen(args, stdout=log, stderr=log)
        self.processes.append(p)
        for _ in range(50):
            if p.poll() is not None: self.fail('test server exited: '+Path(log.name).read_text()[-1500:])
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1): return
            except OSError: time.sleep(.1)
        self.fail('test server did not listen')

    def outbound(self):
        port = self.port()
        config = {'inbounds':[{'type':'vless','listen':'127.0.0.1','listen_port':port,'users':[{'uuid':'bf000d23-0752-40b4-affe-68f7707a9661','flow':'xtls-rprx-vision'}],'tls':{'enabled':True,'server_name':'localhost','reality':{'enabled':True,'private_key':self.keys['PrivateKey'],'short_id':['0123456789abcdef'],'handshake':{'server':'127.0.0.1','server_port':self.origin}}}}], 'outbounds':[{'type':'direct'}]}
        path=self.root/'server.json'; path.write_text(json.dumps(config))
        self.start([CORE,'run','-c',str(path)],port)
        return {'type':'vless','tag':'test','server':'127.0.0.1','server_port':port,'uuid':'bf000d23-0752-40b4-affe-68f7707a9661','flow':'xtls-rprx-vision','tls':{'enabled':True,'server_name':'localhost','utls':{'enabled':True,'fingerprint':'firefox'},'reality':{'enabled':True,'public_key':self.keys['PublicKey'],'short_id':'0123456789abcdef'}}}

    def probe(self, outbound):
        before=set(Path("/tmp").glob("sb-reality-probe.*"))
        result=subprocess.run(['bash','-c','source "$1"; SINGBOX_BIN="$2"; _probe_reality_outbound "$3" "$4"','test',str(REPO/'advanced_relay.sh'),CORE,json.dumps(outbound),f'http://127.0.0.1:{self.http.server_port}/'],capture_output=True,text=True,timeout=25)
        self.assertEqual(set(Path("/tmp").glob("sb-reality-probe.*")),before)
        return result

    def test_valid_reality(self):
        p=self.probe(self.outbound())
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('验证通过',p.stderr)

    def test_generated_reality_nodes(self):
        for kind in ('vless', 'anytls'):
            with self.subTest(kind=kind):
                port = self.port()
                env = dict(os.environ, REPO=str(REPO), WORK=str(self.root),
                           CORE=CORE, NODE_KIND=kind, NODE_PORT=str(port),
                           ORIGIN_PORT=str(self.origin))
                generated = subprocess.run(['bash', '-c', r'''
source "$REPO/sb.sh"
SINGBOX_DIR="$WORK"
CONFIG_FILE="$WORK/generated.json"
METADATA_FILE="$WORK/metadata.json"
SINGBOX_BIN="$CORE"
server_ip=127.0.0.1
BATCH_MODE=true
BATCH_PORT="$NODE_PORT"
BATCH_SNI=localhost
BATCH_REALITY_HANDSHAKE_SERVER=127.0.0.1
BATCH_REALITY_HANDSHAKE_PORT="$ORIGIN_PORT"
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$CONFIG_FILE"
printf '%s\n' '{}' > "$METADATA_FILE"
_new_node_tag() { echo generated-reality; }
_assert_node_name_free() { return 0; }
_add_node_to_yaml() { printf '%s\n' "$1" > "$WORK/proxy.json"; }
if [ "$NODE_KIND" = vless ]; then
    _add_vless_reality_impl
else
    _create_anyreality_node_impl 127.0.0.1 "$NODE_PORT" localhost secret \
        generated-anytls 127.0.0.1 "$ORIGIN_PORT" 127.0.0.1 "$NODE_PORT" false
fi
'''], env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(generated.returncode, 0, generated.stderr)
                metadata = json.loads((self.root/'metadata.json').read_text())['generated-reality']
                parsed = subprocess.run(['bash', str(REPO/'parser.sh'), metadata['share_link']],
                                        capture_output=True, text=True)
                self.assertEqual(parsed.returncode, 0, parsed.stderr)
                outbound = json.loads(parsed.stdout)
                self.assertEqual(outbound['tls']['utls']['fingerprint'], 'firefox')
                self.assertEqual(outbound['tls']['reality']['public_key'], metadata['publicKey'])
                if kind == 'vless':
                    proxy = json.loads((self.root/'proxy.json').read_text())
                    self.assertEqual(proxy['client-fingerprint'], outbound['tls']['utls']['fingerprint'])
                    self.assertEqual(proxy['reality-opts']['public-key'], metadata['publicKey'])
                    self.assertEqual(proxy['reality-opts']['short-id'], metadata['shortId'])
                self.start([CORE, 'run', '-c', str(self.root/'generated.json')], port)
                result = self.probe(outbound)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrong_short_id(self):
        outbound=self.outbound()
        outbound['tls']['reality']['short_id']='ffffffffffffffff'
        p=self.probe(outbound)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('身份验证失败',p.stderr)
        self.assertIn('X25519MLKEM768',p.stderr)
        self.assertNotIn(self.keys['PublicKey'],p.stderr)

    @unittest.skipUnless(os.environ.get('TEST_XRAY'), 'set TEST_XRAY for Xray compatibility test')
    def test_xray_reality(self):
        self.check_xray_reality()

    @unittest.skipUnless(os.environ.get('TEST_XRAY'), 'set TEST_XRAY for Xray compatibility test')
    def test_xray_reality_min_client_version(self):
        self.check_xray_reality('1.8.2')

    def check_xray_reality(self, min_version=None):
        self.assertIn(XRAY_EXPECT, ('success', 'reject'))
        port=self.port()
        config={'inbounds':[{'listen':'127.0.0.1','port':port,'protocol':'vless',
            'settings':{'clients':[{'id':'bf000d23-0752-40b4-affe-68f7707a9661','flow':'xtls-rprx-vision'}],'decryption':'none'},
            'streamSettings':{'network':'raw','security':'reality','realitySettings':{
                'target':f'127.0.0.1:{self.origin}','serverNames':['localhost'],
                'privateKey':self.keys['PrivateKey'],'shortIds':['0123456789abcdef']}}}],
            'outbounds':[{'protocol':'freedom','settings':{'finalRules':[{'action':'allow','network':'tcp','ip':['127.0.0.1/32'],'port':str(self.http.server_port)}]}}]}
        if min_version:
            config['inbounds'][0]['streamSettings']['realitySettings']['minClientVer'] = min_version
        path=self.root/'xray.json';path.write_text(json.dumps(config))
        self.start([os.environ['TEST_XRAY'],'run','-c',str(path)],port)
        client_port=self.port()
        client={'inbounds':[{'listen':'127.0.0.1','port':client_port,'protocol':'socks','settings':{'auth':'noauth'}}],
            'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':'127.0.0.1','port':port,
                'users':[{'id':'bf000d23-0752-40b4-affe-68f7707a9661','flow':'xtls-rprx-vision','encryption':'none'}]}]},
                'streamSettings':{'network':'raw','security':'reality','realitySettings':{
                    'serverName':'localhost','password':self.keys['PublicKey'],'fingerprint':'chrome','shortId':'0123456789abcdef'}}}]}
        client_path=self.root/'client.json';client_path.write_text(json.dumps(client))
        self.start([os.environ['TEST_XRAY'],'run','-c',str(client_path)],client_port)
        control=subprocess.run(['curl','--silent','--show-error','--noproxy','','--proxy',f'socks5h://127.0.0.1:{client_port}',
            '--max-time','20',f'http://127.0.0.1:{self.http.server_port}/'],capture_output=True,text=True)
        self.assertEqual(control.returncode,0,control.stderr+'\n'+'\n'.join(p.read_text()[-3500:] for p in self.root.glob('process-*.log')))
        outbound = {'type':'vless','server':'127.0.0.1','server_port':port,
                    'uuid':'bf000d23-0752-40b4-affe-68f7707a9661','flow':'xtls-rprx-vision',
                    'tls':{'enabled':True,'server_name':'localhost',
                           'utls':{'enabled':True},
                           'reality':{'enabled':True,'public_key':self.keys['PublicKey'],
                                      'short_id':'0123456789abcdef'}}}
        for fingerprint in ('firefox', 'chrome'):
            with self.subTest(fingerprint=fingerprint, min_version=min_version):
                outbound['tls']['utls']['fingerprint'] = fingerprint
                p = self.probe(outbound)
                if XRAY_EXPECT == 'success':
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertIn('验证通过', p.stderr)
                else:
                    self.assertNotEqual(p.returncode, 0)
                    self.assertIn('身份验证失败', p.stderr)
                    self.assertIn('X25519MLKEM768', p.stderr)
                self.assertNotIn(self.keys['PublicKey'], p.stderr)

    def test_non_reality_no_probe(self):
        p=self.probe({'type':'direct','tag':'direct'})
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(p.stderr,'')

if __name__ == '__main__': unittest.main()
