#!/usr/bin/env python3
"""Validate link imports and Reality probes; set TEST_SINGBOX for socket tests."""
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
CORE = os.environ.get('TEST_SINGBOX')
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

    def test_wrong_short_id(self):
        outbound=self.outbound()
        outbound['tls']['reality']['short_id']='ffffffffffffffff'
        p=self.probe(outbound)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('身份验证失败',p.stderr)
        self.assertIn('X25519MLKEM768',p.stderr)
        self.assertNotIn(self.keys['PublicKey'],p.stderr)

    @unittest.skipUnless(os.environ.get('TEST_XRAY'), 'set TEST_XRAY for Xray compatibility test')
    def test_xray_reality_rejected(self):
        port=self.port()
        config={'inbounds':[{'listen':'127.0.0.1','port':port,'protocol':'vless',
            'settings':{'clients':[{'id':'bf000d23-0752-40b4-affe-68f7707a9661','flow':'xtls-rprx-vision'}],'decryption':'none'},
            'streamSettings':{'network':'raw','security':'reality','realitySettings':{
                'target':f'127.0.0.1:{self.origin}','serverNames':['localhost'],
                'privateKey':self.keys['PrivateKey'],'shortIds':['0123456789abcdef']}}}],
            'outbounds':[{'protocol':'freedom','settings':{'finalRules':[{'action':'allow','network':'tcp','ip':['127.0.0.1/32'],'port':str(self.http.server_port)}]}}]}
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
        outbound=self.outbound();outbound['server_port']=port
        p=self.probe(outbound)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('身份验证失败',p.stderr)
        self.assertIn('X25519MLKEM768',p.stderr)

    def test_non_reality_no_probe(self):
        p=self.probe({'type':'direct','tag':'direct'})
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(p.stderr,'')

if __name__ == '__main__': unittest.main()
