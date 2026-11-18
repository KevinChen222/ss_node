"""Exercise migration with isolated config files and simulated systemd services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR=$WORK CONFIG_FILE=$WORK/config.json METADATA_FILE=$WORK/metadata.json
CLASH_YAML_FILE=$WORK/clash.yaml XRAY_CONFIG_FILE=$WORK/xray.json XRAY_BIN=/bin/true
SINGBOX_BIN=$WORK/sing-box SERVICE_FILE=$WORK/sing-box.service SNI_ROUTER_STATE_FILE=$WORK/state
PROXYALL_WRITE_LOCK_FILE=$WORK/lock INIT_SYSTEM=systemd XRAY_ONLY=true YQ_BINARY=local_yq
local_yq() { jq .proxies "${@: -1}"; }
_install_yq() { :; }; _install_xray() { :; }; _xray_running() { test -e "$WORK/started"; }
_manage_service() { [ "$FAIL" = 0 ] && touch "$WORK/started"; }
ss() { echo 'LISTEN 0 128 [::]:2346 [::]:* users:(("xray",pid=42,fd=4))'; }
systemctl() { case "$1" in show) if [ "$3" = MainPID ]; then echo 42; else echo "$SERVICE_FILE"; fi;; is-active|is-enabled) [ "${@: -1}" = sing-box ];; *) echo "$*" >> "$WORK/calls";; esac; }
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
            for name, obj in files.items():
                (root / name).write_text(json.dumps(obj))
            (root / 'sing-box.service').write_text(f'ExecStart={root}/sing-box run -c {root}/config.json -c {root}/relay.json\n')
            (root / 'sing-box').touch()
            (root / '.managed_sing_box').touch()
            r = subprocess.run(['bash', '-c', HARNESS], input=('no' if mode == 'cancel' else 'MIGRATE')+'\n',
                               env=dict(os.environ, WORK=work, REPO=str(REPO), FAIL=str(int(mode == 'fail'))),
                               text=True, capture_output=True)
            self.assertIn('old-tuic', r.stderr)
            if mode == 'success':
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertFalse((root / 'sing-box').exists())
                self.assertFalse((root / 'sing-box.service').exists())
                self.assertTrue(next(root.glob('retired.*/sing-box')).is_file())
                ib, = json.loads((root / 'xray.json').read_text())['inbounds']
                self.assertEqual(ib['settings']['accounts'], [{'user':'user','pass':'abc#/'}])
                self.assertIn('socks5://user:abc%23%2F@[::1]:2346', r.stdout)
            else:
                self.assertTrue((root / 'sing-box').is_file())
                self.assertTrue((root / 'sing-box.service').is_file())
                for name, obj in files.items():
                    self.assertEqual(json.loads((root / name).read_text()), obj)
                if mode == 'fail':
                    self.assertNotEqual(r.returncode, 0)
                    self.assertIn('start sing-box', (root / 'calls').read_text())
                else:
                    self.assertFalse((root / 'calls').exists())

    def test_cutover(self):
        for mode in ['skip', 'cancel', 'fail', 'success']:
            with self.subTest(mode=mode):
                self.run_case(mode)


if __name__ == '__main__':
    unittest.main()
