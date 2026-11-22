#!/usr/bin/env python3
"""Check interactive exits without touching host services or installing binaries."""
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
CLASH_YAML_FILE=$WORK/clash.yaml XRAY_CONFIG_FILE=$WORK/xray.json
SNI_ROUTER_STATE_FILE=$WORK/state.json SNI_ROUTER_HAPROXY_CONF=$WORK/haproxy.cfg
NFT_PERSIST_FILE=$WORK/nft NODE_NFT_CONFIG_FILE=$WORK/nft.conf
PROXYALL_WRITE_LOCK_FILE=$WORK/lock XRAY_ONLY=true NODE_UI=true
YQ_BINARY=local_yq INIT_SYSTEM=direct server_ip=127.0.0.1
local_yq() { jq .proxies "${@: -1}"; }
_xray_running() { return 1; }
_get_public_ip() { echo 127.0.0.1; }
_get_ip() { echo 127.0.0.1; }
_check_root() { :; }
_check_port_conflict() { return 1; }
_probe_reality_target() { return 0; }
side_effect() { echo "$*" >> "$WORK/effects"; return 1; }
_install_xray() { side_effect install; }
_install_realitlscanner() { side_effect scanner; }
_prepare_local_reality_origin() { side_effect origin; }
_sni_router_prepare() { side_effect router; }
_manage_service() { side_effect service; }
_xray_service() { side_effect xray-service; }
_xray_validate() { return 0; }
_node_tx_validate() { return 0; }
case "$ACTION" in
    delete|port|relay|edit) _xray_manage_node "$ACTION" ;;
    native) _node_operation _xray_native_add "$VARIANT" ;;
    vision) _node_operation _add_vless_reality_impl ;;
    xhttp-reality) _node_operation _add_vless_xhttp_reality_impl ;;
    xhttp-tls) _node_operation _add_vless_xhttp_tls_impl ;;
    add-menu) _xray_add_node_menu ;;
    add-dispatch)
        _node_operation() { printf '%s\n' "$*" >> "$WORK/dispatch"; }
        _xray_add_node_menu ;;
    main-menu) _xray_menu ;;
    failed)
        change() { _atomic_modify_json "$METADATA_FILE" '.foo={}' && return 1; }
        _node_operation change ;;
    noop) _node_operation true ;;
    interrupt)
        change() { kill -INT "$BASHPID"; }
        _node_operation change ;;
    dispatch)
        _xray_manage_node_apply() { printf '%s\n' "$1 $2 $3" > "$WORK/dispatch"; }
        _xray_manage_node "$VARIANT" ;;
    restart-failed)
        _manage_service() { echo restart >> "$WORK/effects"; return 1; }
        change() { _atomic_modify_json "$METADATA_FILE" '.foo={}'; }
        _node_operation change ;;
    *) exit 3 ;;
esac
'''


class Interaction(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = {
            'config.json': {'inbounds': []},
            'metadata.json': {'test': {'core': 'xray', 'name': 'Test', 'clientName': 'Test',
                                     'publicPort': 443, 'backendPort': 10443, 'type': 'vless-xhttp-reality',
                                     'nginxConfig': str(self.root / 'test.xhttp.conf')}},
            'xray.json': {'inbounds': [{'tag': 'test', 'port': 10443,
                                      'streamSettings': {'security':'reality','network':'xhttp'}}]},
            'clash.yaml': {'proxies': [{'name': 'Test', 'port': 443}]},
            'state.json': {'reality': None},
        }
        for name, data in self.files.items():
            (self.root / name).write_text(json.dumps(data))

    def snapshot(self):
        return {name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns, p.stat().st_mode)
                for name in self.files for p in [self.root / name]}

    def run_shell(self, action, data='', variant='', unchanged=True, lock=False):
        before = self.snapshot()
        result = subprocess.run(['bash', '-c', HARNESS], input=data, text=True, capture_output=True,
                                timeout=10, env=dict(os.environ, REPO=str(REPO), WORK=str(self.root),
                                                    ACTION=action, VARIANT=str(variant)))
        if unchanged:
            self.assertEqual(self.snapshot(), before, result.stdout + result.stderr)
            self.assertFalse((self.root / 'effects').exists(), result.stdout + result.stderr)
            self.assertNotIn('正在恢复', result.stdout + result.stderr)
        self.assertEqual((self.root / 'lock').exists(), lock, result.stdout + result.stderr)
        self.assertFalse(list(self.root.glob('.node-op.*')), result.stderr)
        return result

    def test_manage_returns_and_invalid_choices(self):
        for action in ('delete', 'port', 'relay', 'edit'):
            for data in ('0\n', '', 'bad\n999\n0\n', '1\n0\n0\n', '1\n'):
                with self.subTest(action=action, data=data):
                    self.assertEqual(self.run_shell(action, data).returncode, 2)
        for data in ('1\nn\n0\n', '1\n\n0\n', '1\nbad\nn\n0\n'):
            self.assertEqual(self.run_shell('delete', data).returncode, 2)
        for data in ('1\n443\n0\n', '1\nbad\n65536\n0\n0\n'):
            self.assertEqual(self.run_shell('port', data).returncode, 2)
        self.assertEqual(self.run_shell('relay', '1\n\n0\n').returncode, 2)

    def test_edit_parameter_cancel_and_noop(self):
        for data in ('1\n1\nNew\n0\n0\n0\n', '1\n2\n0\n0\n0\n',
                     '1\n3\n443\n0\n0\n', '1\n3\n8443\n0\n0\n0\n',
                     '1\n5\n\n0\n0\n', '1\n5\n1\n0\n0\n0\n',
                     '1\n4\ny\ny\n1\nnew.test\n0\n0\n0\n',
                     '1\n6\n/new/\n0\n0\n0\n', '1\n7\n5\n0\n0\n0\n'):
            with self.subTest(data=data):
                self.assertEqual(self.run_shell('edit', data).returncode, 2)

    def test_shared_port_prompt_returns_without_preparing_router(self):
        for kind in ('vless-xhttp', 'vless-xhttp-reality', 'vless-vision-reality'):
            data = self.files['metadata.json']
            data['test']['publicPort'] = 8443
            data['test']['type'] = kind
            (self.root / 'metadata.json').write_text(json.dumps(data))
            with self.subTest(kind=kind):
                self.assertEqual(self.run_shell('port', '1\n443\n0\n0\n').returncode, 2)
                self.assertEqual(self.run_shell('port', '1\n443\nwrong\n0\n0\n').returncode, 2)

    def test_empty_list(self):
        (self.root / 'metadata.json').write_text('{}')
        self.assertEqual(self.run_shell('delete').returncode, 2)

    def test_every_creation_prompt_can_cancel_or_eof(self):
        cases = [('native', n, ['127.0.0.1', '8443', 'New'] + (['1'] if n == 1 else []))
                 for n in (1, 2)]
        cases += [
            ('vision', '', ['127.0.0.1', 'y', '1', 'example.test', '443', 'y', 'New', '1']),
            ('xhttp-reality', '', ['127.0.0.1', 'y', '1', 'example.test', '443', 'y', '/test/', 'New', '1', '1']),
            ('xhttp-tls', '', ['127.0.0.1', 'example.test', '443', 'y', '/test/', 'New', '1', '1']),
        ]
        for action, variant, answers in cases:
            for i in range(len(answers)):
                for last in ('0\n', ''):
                    data = ''.join(a+'\n' for a in answers[:i]) + last
                    with self.subTest(action=action, variant=variant, step=i, last=last):
                        self.assertEqual(self.run_shell(action, data, variant).returncode, 2)

    def test_scan_cancel(self):
        # Cancel scan mode, CIDR entry, or the pasted target list.
        for suffix in ('0\n', '1\n0\n', '3\n0\n'):
            self.assertEqual(self.run_shell('vision', '127.0.0.1\nn\nn\ny\n'+suffix).returncode, 2)

    def test_menu_back_and_update_declined(self):
        for data in ('0\n', '6\n0\n0\n', '6\nn\n0\n', '6\n\n0\n', '1\n0\n0\n', '3\n0\n0\n'):
            self.assertEqual(self.run_shell('main-menu', data).returncode, 0)
        result = self.run_shell('add-menu', '5\n0\n0\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.count('Xray 添加节点'), 2)

    def test_add_menu_has_five_protocols(self):
        result = self.run_shell('add-dispatch', '1\n2\n3\n4\n5\n6\n9\n0\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root/'dispatch').read_text().splitlines(), [
            '_add_vless_reality_impl', '_add_vless_xhttp_reality_impl', '_add_vless_xhttp_tls_impl',
            '_xray_native_add 2', '_xray_native_add 1'])
        for removed in ('WebSocket', 'gRPC', 'SOCKS5', 'AES-128-GCM'):
            self.assertNotIn(removed, result.stdout)
        for variant in (3, 4, 5, 6):
            self.assertEqual(self.run_shell('native', '', variant).returncode, 1)

    def test_candidate_failure_and_noop_preserve_original_files(self):
        self.assertEqual(self.run_shell('failed', lock=True).returncode, 1)
        (self.root / 'lock').unlink()
        self.assertEqual(self.run_shell('noop').returncode, 0)
        self.assertEqual(self.run_shell('interrupt').returncode, 130)

    def test_real_publish_failure_still_rolls_back(self):
        result = self.run_shell('restart-failed', unchanged=False, lock=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('正在恢复', result.stderr + result.stdout)
        for name, data in self.files.items():
            self.assertEqual(json.loads((self.root / name).read_text()), data)

    def test_confirmed_actions_dispatch_once(self):
        for action, data, expected in [('delete', '1\ny\n', 'delete test '),
                                       ('delete', '1\nn\n1\ny\n', 'delete test '),
                                       ('delete', 'bad\n1\ny\n', 'delete test '),
                                       ('port', '1\n8443\n', 'port test 8443'),
                                       ('relay', '1\ndirect\n', 'relay test ')]:
            with self.subTest(action=action):
                result = self.run_shell('dispatch', data, action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.root / 'dispatch').read_text(), expected+'\n')


if __name__ == '__main__':
    unittest.main()
