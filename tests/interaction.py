#!/usr/bin/env python3
"""Check interactive exits and cancel safety without touching host services."""
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
SINGBOX_BIN=$WORK/sing-box XRAY_BIN=$WORK/xray
SNI_ROUTER_STATE_FILE=$WORK/state.json SNI_ROUTER_HAPROXY_CONF=$WORK/haproxy.cfg
NFT_PERSIST_FILE=$WORK/nft NODE_NFT_CONFIG_FILE=$WORK/nft.conf
PROXYALL_WRITE_LOCK_FILE=$WORK/lock NODE_UI=true
YQ_BINARY=local_yq INIT_SYSTEM=direct server_ip=127.0.0.1
local_yq() {
    local expr="${@: -2:1}"
    expr=${expr//strenv\(PROXY_NAME\)/env.PROXY_NAME}
    jq "$expr" "${@: -1}"
}
_xray_running() { return 1; }
_is_pid_file_running_cmd() { return 1; }
_get_public_ip() { echo 127.0.0.1; }
_get_ip() { echo 127.0.0.1; }
_check_root() { :; }
_check_port_conflict() { return 1; }
_probe_reality_target() { return 0; }
side_effect() { echo "$*" >> "$WORK/effects"; return 1; }
_install_xray() { side_effect install-xray; }
_install_or_update_singbox() { side_effect install-singbox; }
_install_realitlscanner() { side_effect scanner; }
_prepare_local_reality_origin() { side_effect origin; }
_generate_self_signed_cert() { side_effect self-signed-cert; }
_sni_router_prepare() { side_effect router; }
_manage_service() { side_effect service; }
_xray_service() { side_effect xray-service; }
_xray_validate() { return 0; }
_node_tx_validate() { return 0; }
case "$ACTION" in
    vision) _node_operation _add_vless_reality_impl ;;
    anytls) _node_operation _add_anytls_impl ;;
    xhttp-reality) _node_operation _add_vless_xhttp_reality_impl ;;
    xhttp-tls) _node_operation _add_vless_xhttp_tls_impl ;;
    delete) _node_operation _delete_node_impl ;;
    port) _node_operation _modify_port_impl ;;
    edit-menu) _edit_node_menu ;;
    xray-edit) _xray_edit_node_menu "$VARIANT" ;;
    add-menu) _show_add_node_menu ;;
    add-dispatch)
        _add_vless_reality() { printf 'vision\n' >> "$WORK/dispatch"; }
        _add_anytls() { printf 'anytls\n' >> "$WORK/dispatch"; }
        _add_vless_xhttp_tls() { printf 'xhttp-tls\n' >> "$WORK/dispatch"; }
        _add_vless_xhttp_reality() { printf 'xhttp-reality\n' >> "$WORK/dispatch"; }
        _show_add_node_menu ;;
    main-menu) _main_menu ;;
    failed)
        change() { _atomic_modify_json "$METADATA_FILE" '.foo={}' && return 1; }
        _node_operation change ;;
    noop) _node_operation true ;;
    interrupt)
        change() { kill -INT "$BASHPID"; }
        _node_operation change ;;
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
        for name, ver in (('sing-box', 'sing-box version 1.12.0'), ('xray', 'Xray 25.10.15')):
            script = self.root / name
            script.write_text(f'#!/usr/bin/env bash\necho "{ver}"\n')
            script.chmod(0o700)
        self.files = {
            'config.json': {'inbounds': [
                {'type': 'vless', 'tag': 'sb-vision', 'listen': '::', 'listen_port': 8443,
                 'users': [{'uuid': '80c7a55c-8951-423f-a420-2af7d59d19e6', 'flow': 'xtls-rprx-vision'}],
                 'tls': {'enabled': True, 'server_name': 'vision.test', 'reality': {'enabled': True}}},
            ], 'outbounds': [{'type': 'direct', 'tag': 'direct'}]},
            'metadata.json': {
                'sb-vision': {'name': 'SBVision', 'clientName': 'SBVision',
                              'publicPort': 8443, 'backendPort': 8443, 'server_name': 'vision.test'},
                'xhttp-test': {'core': 'xray', 'name': 'XhttpTest', 'clientName': 'XhttpTest',
                               'publicPort': 443, 'backendPort': 10443, 'type': 'vless-xhttp-reality',
                               'server_name': 'xhttp.test', 'path': '/test/',
                               'handshakeServer': '127.0.0.1', 'handshakePort': 9444,
                               'nginxConfig': str(self.root / 'xhttp-test.xhttp.conf')},
            },
            'xray.json': {'inbounds': [{'tag': 'xhttp-test', 'port': 10443, 'protocol': 'vless',
                                        'settings': {'clients': [{'id': 'uuid'}], 'decryption': 'none'},
                                        'streamSettings': {'security': 'reality', 'network': 'xhttp',
                                                           'xhttpSettings': {'path': '/test/', 'host': 'xhttp.test',
                                                                             'mode': 'stream-up'}}}]},
            'clash.yaml': {'proxies': [
                {'name': 'SBVision', 'type': 'vless', 'server': '127.0.0.1', 'port': 8443,
                 'uuid': '80c7a55c-8951-423f-a420-2af7d59d19e6', 'servername': 'vision.test'},
                {'name': 'XhttpTest', 'type': 'vless', 'server': '127.0.0.1', 'port': 443,
                 'uuid': 'uuid', 'servername': 'xhttp.test', 'encryption': 'none',
                 'xhttp-opts': {'path': '/test/', 'reuse-settings': {'max-concurrency': '1'}}},
            ]},
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

    def test_delete_and_port_cancel_and_invalid_choices(self):
        for action in ('delete', 'port'):
            for data in ('0\n', ''):
                with self.subTest(action=action, data=data):
                    self.assertEqual(self.run_shell(action, data).returncode, 2)
        for data in ('1\n0\n', '1\n', '2\n0\n', '99\n'):
            with self.subTest(action='delete', data=data):
                self.assertEqual(self.run_shell('delete', data).returncode, 2)
        for data in ('1\nn\n', '1\n\n', '99\nno\n', '99\n0\n'):
            with self.subTest(action='delete-decline', data=data):
                self.assertEqual(self.run_shell('delete', data).returncode, 0)
        self.assertEqual(self.run_shell('delete', 'bad\n').returncode, 1)
        for data in ('1\n0\n', '1\n', '2\n0\n'):
            with self.subTest(action='port-cancel', data=data):
                self.assertEqual(self.run_shell('port', data).returncode, 2)
        self.assertEqual(self.run_shell('port', '1\n8443\n').returncode, 0)
        self.assertEqual(self.run_shell('port', '1\n65536\n').returncode, 1)

    def test_edit_node_menu_cancel_and_noop(self):
        # Node 1 is sing-box (SBVision); node 2 is xray (XhttpTest).
        for data in ('0\n', '', 'bad\n999\n0\n',
                     '1\n0\n0\n', '1\n8443\n0\n',
                     '2\n0\n0\n',
                     '2\n1\nNew\n0\n0\n0\n',
                     '2\n2\n0\n0\n0\n',
                     '2\n3\n443\n0\n0\n',
                     '2\n3\n9443\n0\n0\n0\n',
                     '2\n4\ny\ny\n1\nnew.test\n0\n0\n0\n',
                     '2\n5\n\n0\n0\n',
                     '2\n5\n1\n0\n0\n0\n',
                     '2\n6\n/new/\n0\n0\n0\n',
                     '2\n7\n5\n0\n0\n0\n'):
            with self.subTest(data=data):
                self.assertEqual(self.run_shell('edit-menu', data).returncode, 0)

    def test_shared_port_prompt_returns_without_preparing_router(self):
        for kind in ('vless-xhttp', 'vless-xhttp-reality'):
            data = json.loads((self.root / 'metadata.json').read_text())
            data['xhttp-test']['publicPort'] = 9443
            data['xhttp-test']['type'] = kind
            (self.root / 'metadata.json').write_text(json.dumps(data))
            with self.subTest(kind=kind):
                self.assertEqual(self.run_shell('port', '2\n443\n0\n').returncode, 2)
                self.assertEqual(self.run_shell('port', '2\n443\nwrong\n0\n').returncode, 2)

    def test_empty_list(self):
        (self.root / 'config.json').write_text('{"inbounds":[]}')
        (self.root / 'xray.json').write_text('{"inbounds":[]}')
        (self.root / 'metadata.json').write_text('{}')
        self.assertEqual(self.run_shell('delete').returncode, 0)
        self.assertEqual(self.run_shell('edit-menu').returncode, 0)

    def test_every_creation_prompt_can_cancel_or_eof(self):
        cases = [
            # Sing-box VLESS Vision Reality: IP, own-domain y, self-origin 1, SNI, port 443, shared y, name
            ('vision', ['127.0.0.1', 'y', '1', 'example.test', '443', 'y', 'New']),
            # Sing-box AnyTLS TLS: mode 1, IP, port 443, shared y, SNI, password, name, cert choice 1, cert path, key path
            ('anytls', ['1', '127.0.0.1', '443', 'y', 'any.test', 'secret', 'NewAny', '1', '/tmp/a.pem', '/tmp/a.key']),
            # Sing-box Any-Reality: mode 2, IP, port 443, shared y, own-domain y, self-origin 1, SNI, password, name
            ('anytls', ['2', '127.0.0.1', '443', 'y', 'y', '1', 'any.test', 'secret', 'NewAnyR']),
            # Xray XHTTP Reality: IP, own-domain y, self-origin 1, SNI, port 443, shared y, path, name, xmux, enc
            ('xhttp-reality', ['127.0.0.1', 'y', '1', 'example.test', '443', 'y', '/test/', 'New', '1', '1']),
            # Xray XHTTP TLS: IP, domain, port 443, shared y, path, name, xmux, enc
            ('xhttp-tls', ['127.0.0.1', 'example.test', '443', 'y', '/test/', 'New', '1', '1']),
        ]
        for action, answers in cases:
            for i in range(len(answers)):
                for last in ('0\n', ''):
                    data = ''.join(a + '\n' for a in answers[:i]) + last
                    with self.subTest(action=action, step=i, last=last):
                        self.assertEqual(self.run_shell(action, data).returncode, 2)

    def test_scan_cancel(self):
        for suffix in ('0\n', '1\n0\n', '3\n0\n'):
            self.assertEqual(self.run_shell('vision', '127.0.0.1\nn\nn\ny\n' + suffix).returncode, 2)

    def test_main_menu_dual_status_back_and_xray_update_declined(self):
        for data in ('0\n', '18\n0\n0\n', '18\nn\n0\n', '18\n\n0\n', '1\n0\n0\n', '5\n0\n0\n'):
            result = self.run_shell('main-menu', data)
            self.assertEqual(result.returncode, 0)
            self.assertIn('Sing-box', result.stdout)
            self.assertIn('Xray', result.stdout)

    def test_add_menu_groups_singbox_primary_and_xray_xhttp(self):
        result = self.run_shell('add-dispatch', '1\n5\n12\n13\n0\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / 'dispatch').read_text().splitlines(),
                         ['vision', 'anytls', 'xhttp-tls', 'xhttp-reality'])
        self.assertIn('Sing-box 主核心协议', result.stdout)
        self.assertIn('VLESS (Vision + Reality)', result.stdout)
        self.assertIn('AnyTLS / Any-Reality', result.stdout)
        self.assertIn('Xray 备用核心协议 (XHTTP)', result.stdout)
        self.assertIn('VLESS (XHTTP + TLS / H2)', result.stdout)
        self.assertIn('VLESS (XHTTP + Reality)', result.stdout)

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


if __name__ == '__main__':
    unittest.main()
