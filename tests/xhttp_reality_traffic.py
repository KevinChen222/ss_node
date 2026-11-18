#!/usr/bin/env python3
"""Exercise generated XHTTP Reality nodes with TEST_XRAY and TEST_MIHOMO binaries."""
import sys,os,json,subprocess,socket,tempfile,time,threading,http.server,hashlib
from pathlib import Path
from xhttp_reality import REALITY_HARNESS

def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def run_traffic():
    root=Path(tempfile.mkdtemp(prefix='proxyall-reality-e2e-'))
    xray = os.environ['TEST_XRAY']
    mihomo = os.environ['TEST_MIHOMO']
    origin,public,mixed,web=[port() for _ in range(4)]
    (root/'conf.d').mkdir()
    (root/'metadata.json').write_text('{}')
    (root/'xray.json').write_text('{"log":{"loglevel":"debug"},"inbounds":[],"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}]}')
    (root/'router.json').write_text('{"reality":null}')
    (root/'harness.sh').write_text(REALITY_HARNESS.replace('SELECTED_REALITY_HANDSHAKE_PORT=8443',f'SELECTED_REALITY_HANDSHAKE_PORT={origin}'))
    env=dict(os.environ,WORK=str(root),REPO=str(Path(__file__).resolve().parents[1]),ACTION='add',TEST_REALITY_KEYGEN=xray)
    r=subprocess.run(['bash',str(root/'harness.sh')],input=f'\n{public}\n/test/\nXHTTP test\n1\n',text=True,env=env,capture_output=True)
    assert r.returncode==0,r.stderr
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(root/'key'),'-out',str(root/'cert'),'-subj','/CN=own.example.com','-days','1'],capture_output=True,check=True)
    proxy=json.loads((root/'client.json').read_text())['proxies'][0]
    if os.environ.get('TEST_SUBSTORE'):
     link=json.loads((root/'metadata.json').read_text())['xhttp-in-test']['share_link']
     exported=json.loads(subprocess.check_output(['node',str(Path(__file__).with_name('substore_link.mjs'))],input=link,text=True))
     for key in ('uuid','network','alpn','client-fingerprint','servername','reality-opts','xhttp-opts'):
      assert exported[key]==proxy[key],(key,exported.get(key),proxy[key])
     proxy=exported
    proxy['server']='127.0.0.1'
    client={'mixed-port':mixed,'mode':'rule','log-level':'debug','proxies':[proxy],'rules':['MATCH,XHTTP test']}
    (root/'mihomo.json').write_text(json.dumps(client))
    procs=[]
    def start(cmd,name):
     f=open(root/name,'w');p=subprocess.Popen(cmd,stdout=f,stderr=f);procs.append((p,f));return p
    class Echo(http.server.BaseHTTPRequestHandler):
     def do_GET(self):
      body=b'proxyall-reality-ok';self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
     def do_POST(self):
      body=hashlib.sha256(self.rfile.read(int(self.headers['Content-Length']))).hexdigest().encode();self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
     def log_message(self,*args):pass
    srv=http.server.ThreadingHTTPServer(('127.0.0.1',web),Echo);threading.Thread(target=srv.serve_forever,daemon=True).start()
    try:
     start(['openssl','s_server','-accept',f'127.0.0.1:{origin}','-cert',str(root/'cert'),'-key',str(root/'key'),'-tls1_3','-alpn','h2','-www'],'origin.log')
     subprocess.run([xray,'run','-test','-config',str(root/'xray.json')],check=True,capture_output=True)
     start([xray,'run','-config',str(root/'xray.json')],'xray.log')
     start([mihomo,'-d',str(root),'-f',str(root/'mihomo.json')],'mihomo.log')
     time.sleep(2)
     cmd=['curl','-fsS','--max-time','12','--noproxy','','--proxy',f'http://127.0.0.1:{mixed}',f'http://127.0.0.1:{web}/']
     r=subprocess.run(cmd,text=True,capture_output=True);assert r.returncode==0,(r.stderr,(root/'mihomo.log').read_text()[-3500:],(root/'xray.log').read_text()[-3500:]);assert r.stdout=='proxyall-reality-ok',r.stdout
     payload=b'upload-data'*100000
     r=subprocess.run(cmd[:-1]+['--data-binary','@-',cmd[-1]],input=payload,capture_output=True);assert r.returncode==0,r.stderr;assert r.stdout.decode()==hashlib.sha256(payload).hexdigest()
     print('PASS: generated mihomo node -> Xray -> HTTP GET and 1.1 MB POST')
    finally:
     for p,f in reversed(procs):p.terminate();p.wait(timeout=5);f.close()
     srv.shutdown()
     import shutil
     shutil.rmtree(root)

if __name__ == '__main__':
    if not all(os.environ.get(name) for name in ('TEST_XRAY', 'TEST_MIHOMO')):
        print('SKIP: set TEST_XRAY and TEST_MIHOMO to run the traffic test')
    else:
        run_traffic()
