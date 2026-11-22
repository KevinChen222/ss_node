"""Exercise migration with isolated config files and simulated systemd services."""
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
CLASH_YAML_FILE=$WORK/clash.yaml XRAY_CONFIG_FILE=$WORK/xray.json XRAY_BIN=/bin/true
SINGBOX_BIN=$WORK/sing-box SERVICE_FILE=$WORK/sing-box.service SNI_ROUTER_STATE_FILE=$WORK/state
SNI_ROUTER_STATE_DIR=$WORK SNI_ROUTER_LOCK_FILE=$WORK/router.lock
SNI_ROUTER_HAPROXY_CONF=$WORK/haproxy.cfg
PROXYALL_WRITE_LOCK_FILE=$WORK/lock INIT_SYSTEM=systemd XRAY_ONLY=true YQ_BINARY=local_yq
local_yq() { jq .proxies "${@: -1}"; }
_install_yq() { :; }; _install_xray() { test /dev/fd/8 -ef "$WORK/lock"; }; _xray_running() { test -e "$WORK/started"; }
_manage_service() { [ "$MODE" != fail ] && touch "$WORK/started"; }
_sni_router_apply() { _sni_router_generate_haproxy_config "$WORK/haproxy.test"; }
sleep() { :; }
ss() {
    local port=2346
    [ "$MODE" != unready ] || port=1234
    echo "LISTEN 0 128 [::]:$port [::]:* users:((\"xray\",pid=42,fd=4))"
}
systemctl() { case "$1" in show) if [ "$3" = MainPID ]; then echo 42; else echo "$SERVICE_FILE"; fi;; is-active|is-enabled) [ "${@: -1}" = sing-box ] || _xray_running;; *) echo "$*" >> "$WORK/calls";; esac; }
read() { touch "$WORK/prompt"; builtin read "$@"; }
_retire_legacy_service migrate
'''


class Migration(unittest.TestCase):
    def run_case(self, mode):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            unsupported = {'tag': 'old-tuic', 'type': 'tuic', 'listen_port': 2345}
            socks = dict(type='socks', tag='old-socks', listen='::', listen_port=2346,
                         users=[dict(username='user', password='abc#/')])
            proxy = dict(type='socks5', name='Original', server='::1', port=2346, **socks['users'][0])
            files = {'config.json': {'inbounds': [unsupported] if mode == 'skip' else [unsupported, socks]},
                     'relay.json': {'inbounds': []}, 'metadata.json': {}, 'clash.yaml': {'proxies': [proxy]}}
            preserve = mode in ('preserve', 'unready')
            if preserve:
                existing = dict(type='vless', name='Existing', server='::1', port=443,
                                uuid='80c7a55c-8951-423f-a420-2af7d59d19e6', tls=True)
                files['clash.yaml']['proxies'].append(existing)
                files['xray.json'] = {'inbounds': [{'tag': 'existing', 'port': 10443, 'listen': '127.0.0.1',
                                                   'protocol': 'vless'}],
                                      'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}]}
                files['metadata.json']['existing'] = {'core': 'xray', 'type': 'native-vless',
                                                     'clientName': 'Existing', 'name': 'Existing',
                                                     'publicPort': 443, 'backendPort': 10443,
                                                     'share_link': f"vless://{existing['uuid']}@[::1]:443#Existing"}
                files['state'] = {'version': 1, 'public_port': 443, 'reality': None,
                                  'https_backend': {'host': '127.0.0.1', 'port': 8444},
                                  'https_routes': {'emby.test': {'owner': 'nginx-proxy'}},
                                  'tls_routes': {'xray.test': {'owner': 'sb-xray', 'tag': 'existing',
                                                               'backend_host': '127.0.0.1', 'backend_port': 10443},
                                                 'legacy.test': {'owner': 'sb', 'tag': 'old-tls',
                                                                 'backend_host': '127.0.0.1', 'backend_port': 10444}}}
                (root / 'started').touch()
            for name, obj in files.items():
                (root / name).write_text(json.dumps(obj))
            (root / 'sing-box.service').write_text(f'ExecStart={root}/sing-box run -c {root}/config.json -c {root}/relay.json\n')
            (root / 'sing-box').touch()
            (root / '.managed_sing_box').touch()
            env = dict(os.environ, WORK=work, REPO=str(REPO), MODE=mode)
            clash_inode = (root / 'clash.yaml').stat().st_ino
            if mode == 'concurrent':
                with subprocess.Popen(['bash', '-c', HARNESS], env=env, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as child:
                    try:
                        deadline = time.monotonic() + 5
                        while not (root / 'prompt').exists() and child.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue((root / 'prompt').exists(), 'migration did not reach confirmation')
                        self.assertFalse((root / 'lock').exists())
                        subprocess.run(['flock', '-n', str(root / 'lock'), 'bash', '-c',
                                        'printf %s \'{"inbounds":[],"writer":true}\' > "$WORK/relay.json"'],
                                       env=env, check=True, timeout=5)
                        files['relay.json']['writer'] = True
                        out, err = child.communicate('MIGRATE\n', timeout=5)
                        r = subprocess.CompletedProcess(child.args, child.returncode, out, err)
                    finally:
                        if child.poll() is None:
                            child.kill()
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('确认期间配置已变化', r.stderr)
                self.assertFalse(list(root.glob('retired.*')))
            else:
                r = subprocess.run(['bash', '-c', HARNESS], input=('no' if mode == 'cancel' else 'MIGRATE')+'\n',
                                   env=env, text=True, capture_output=True, timeout=10)
            self.assertFalse(list(root.glob('.migration.*')))
            self.assertFalse(list(root.glob('.node-op.*')))
            self.assertEqual((root / 'clash.yaml').stat().st_ino, clash_inode)
            self.assertIn('old-tuic', r.stderr)
            if mode in ('success', 'preserve'):
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertFalse((root / 'sing-box').exists())
                self.assertFalse((root / 'sing-box.service').exists())
                self.assertTrue(next(root.glob('retired.*/sing-box')).is_file())
                inbounds = json.loads((root / 'xray.json').read_text())['inbounds']
                self.assertEqual(inbounds[-1]['settings']['accounts'], [{'user':'user','pass':'abc#/'}])
                self.assertIn('socks5://user:abc%23%2F@[::1]:2346', r.stdout)
                if preserve:
                    state = dict(files['state'], tls_routes={'xray.test': files['state']['tls_routes']['xray.test']})
                    self.assertEqual(json.loads((root / 'state').read_text()), state)
                    self.assertEqual(inbounds[:-1], files['xray.json']['inbounds'])
                    self.assertEqual(json.loads((root / 'metadata.json').read_text())['existing'],
                                     files['metadata.json']['existing'])
                    self.assertIn('emby.test', (root / 'haproxy.test').read_text())
            else:
                self.assertTrue((root / 'sing-box').is_file())
                self.assertTrue((root / 'sing-box.service').is_file())
                for name, obj in files.items():
                    self.assertEqual(json.loads((root / name).read_text()), obj)
                if mode in ('fail', 'unready'):
                    self.assertNotEqual(r.returncode, 0)
                    self.assertNotIn('socks5://', r.stdout)
                    self.assertIn('start sing-box', (root / 'calls').read_text())
                    if mode == 'unready':
                        self.assertIn('Xray 未接管全部迁移端口', r.stderr)
                        self.assertIn('start proxyall-xray', (root / 'calls').read_text())
                else:
                    self.assertFalse((root / 'calls').exists())
                    if mode in ('skip', 'cancel'):
                        self.assertFalse((root / 'lock').exists())

    def test_cutover(self):
        for mode in ('skip', 'cancel', 'concurrent', 'fail', 'unready', 'success', 'preserve'):
            with self.subTest(mode=mode):
                self.run_case(mode)


if __name__ == '__main__':
    unittest.main()
