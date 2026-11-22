#!/usr/bin/env python3
"""Exercise SNI routing in isolation. TEST_HAPROXY enables real loopback traffic checks."""
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
HAPROXY = os.environ.get('TEST_HAPROXY') or shutil.which('haproxy')
HARNESS = r'''
set -Eeuo pipefail
source "$1"
shift
export PROXYALL_WRITE_LOCK_FILE="$WORK/write.lock"
export SNI_ROUTER_STATE_DIR="$WORK/router"
export SNI_ROUTER_STATE_FILE="$SNI_ROUTER_STATE_DIR/state.json"
export SNI_ROUTER_LOCK_FILE="$WORK/router.lock"
export SNI_ROUTER_HAPROXY_CONF="$WORK/haproxy.cfg"
export SNI_ROUTER_HAPROXY_BACKUP_DIR="$WORK/haproxy-backup"
CONFIG_FILE="$WORK/no-singbox-config"
SNI_ROUTER_BIN="$WORK/${SB_COMMAND:-no-sb}"
_sni_router_require_systemd() { return 0; }
has_systemd() { return 0; }
haproxy() {
    [[ $# == 3 && $1 == -c && $2 == -f && -s $3 && ${FAIL_CHECK:-0} != 1 ]]
}
systemctl() {
    printf '%s\n' "$1" >> "$WORK/systemctl.calls"
    case "$1" in
        is-active) [[ -f $WORK/loaded.cfg ]] ;;
        is-enabled) [[ -f $WORK/enabled ]] ;;
        enable) touch "$WORK/enabled" ;;
        reload|start|restart)
            # Model a load failure that leaves the service down.
            if [[ $1 == "${FAIL_ACTION:-}" || ($1 == restart && ${FAIL_RESTART:-0} == 1) ]]; then
                rm -f "$WORK/loaded.cfg"
                return 1
            fi
            cp "$SNI_ROUTER_HAPROXY_CONF" "$WORK/loaded.cfg"
            ;;
        disable)
            [[ ${FAIL_ACTION:-} != disable ]] || return 1
            rm -f "$WORK/enabled"
            [[ ${2:-} != --now ]] || rm -f "$WORK/loaded.cfg"
            ;;
        stop) rm -f "$WORK/loaded.cfg" ;;
        *) return 1 ;;
    esac
}
export -f _sni_router_require_systemd haproxy systemctl
'''


class SniRouterTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='proxyall-sni-test-')
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        (self.work / 'tmp').mkdir()
        (self.work / 'router').mkdir()
        self.state = self.work / 'router/state.json'
        self.conf = self.work / 'haproxy.cfg'
        self.loaded = self.work / 'loaded.cfg'
        self.calls = self.work / 'systemctl.calls'

    def run_router(self, body, entry='sb.sh', ok=True, **env):
        result = subprocess.run(['bash', '-c', HARNESS + '\n' + body, 'test', str(REPO / entry)],
                                env=dict(os.environ, REPO=str(REPO), WORK=str(self.work),
                                         TMPDIR=str(self.work / 'tmp'), **env),
                                capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return [f.read_bytes() if f.exists() else None for f in (self.state, self.conf, self.loaded)]

    def test_fallback_refuses_tls_routes_then_delegates_to_sb(self):
        self.run_router('''
_sni_router_cli register-reality sb-xray vision reality.example.com 2443
_sni_router_cli register-tls sb-xray ws ws.example.com 10443
''')
        before = self.snapshot()
        for action in ('status', 'check', 'prepare', 'register-https nginx-proxy emby.example.com 8444',
                       'remove-https nginx-proxy emby.example.com'):
            with self.subTest(action=action):
                result = self.run_router('sni_router_call ' + action, 'deploy.sh', ok=False)
                self.assertIn('TLS SNI', result.stderr)
                self.assertEqual(self.snapshot(), before)
        wrapper = self.work / 'sb'
        wrapper.write_text('#!/usr/bin/env bash\nset -Eeuo pipefail\nsource "$REPO/sb.sh"\n'
                           '[[ $1 == sni-router ]] || exit 2\nshift\n_sni_router_cli "$@"\n')
        wrapper.chmod(0o700)
        self.run_router('sni_router_call register-https nginx-proxy WS.example.com 8444',
                        'deploy.sh', ok=False, SB_COMMAND='sb')
        self.assertEqual(self.snapshot(), before)
        result = self.run_router('''
sni_router_call register-https nginx-proxy Emby.example.com 8444
sni_router_call check
sni_router_call status
''', 'deploy.sh', SB_COMMAND='sb')
        self.assertIn('reality=reality.example.com -> 127.0.0.1:2443', result.stdout)
        self.assertIn('https=emby.example.com -> 127.0.0.1:8444 (nginx-proxy)', result.stdout)
        self.assertIn('tls=ws.example.com -> 127.0.0.1:10443 (ws)', result.stdout)
        cfg = self.conf.read_text()
        self.assertIn('server nginx 127.0.0.1:8444 send-proxy-v2', cfg)
        self.assertIn('server tls_0 127.0.0.1:10443', cfg)
        self.assertIn('default_backend sb_reality_backend', cfg)
        self.run_router('sni_router_call remove-https nginx-proxy emby.example.com',
                        'deploy.sh', SB_COMMAND='sb')
        self.run_router('_sni_router_cli remove-reality vision')
        self.assertTrue(self.loaded.exists())
        self.assertIn('reject if sb_tls_client_hello !sb_tls_route_0', self.conf.read_text())
        self.run_router('_sni_router_cli remove-tls ws')
        self.assertFalse(self.loaded.exists())

    def test_fallback_accepts_legacy_state_and_preserves_reality(self):
        for tls in ({}, {'tls_routes': None}, {'tls_routes': {}}):
            with self.subTest(tls=tls):
                self.state.write_text(json.dumps(dict(version=1, public_port=443, https_backend=None,
                    https_routes={}, reality=dict(owner='sb-xray', tag='vision', sni='Reality.Example.com',
                    backend_host='127.0.0.1', backend_port=2443), **tls)))
                self.run_router('sni_router_call register-https nginx-proxy reality.example.com 8444',
                                'deploy.sh', ok=False)
                self.run_router('sni_router_call register-https nginx-proxy emby.example.com 8444',
                                'deploy.sh')
                self.assertIn('default_backend sb_reality_backend', self.conf.read_text())
                self.run_router('sni_router_call remove-https nginx-proxy EMBY.example.com', 'deploy.sh')
                self.assertTrue(self.loaded.exists())
                self.assertEqual(json.loads(self.state.read_text())['https_routes'], {})
                self.assertEqual(json.loads(self.state.read_text())['reality']['tag'], 'vision')
                result = self.run_router('_sni_router_cli check\n_sni_router_cli status')
                self.assertIn('public=:443', result.stdout)
                self.assertIn('reality=Reality.Example.com -> 127.0.0.1:2443', result.stdout)
                self.assertIn('tls=未登记', result.stdout)

    def test_invalid_or_missing_state_never_replaces_managed_config(self):
        self.run_router('_sni_router_cli register-tls sb-xray ws ws.example.com 10443')
        saved = json.loads(self.state.read_text())
        saved['tls_routes'] = {}
        for changes in ({'tls_routes': False}, {'tls_routes': []}, {'tls_routes': ''},
                        {'public_port': '08'}, {'reality': {'backend_port': 2443}},
                        {'https_routes': {'emby.example.com': {'owner': 'nginx-proxy'}}},
                        {'tls_routes': {'ws.example.com': {}}}, None):
            for entry, command in (('deploy.sh', 'sni_router_call'), ('sb.sh', '_sni_router_cli')):
                with self.subTest(changes=changes, entry=entry):
                    if changes is None:
                        self.state.unlink(missing_ok=True)
                    else:
                        self.state.write_text(json.dumps({**saved, **changes}))
                    before = self.snapshot()
                    calls = self.calls.read_bytes()
                    self.run_router(command + ' register-https nginx-proxy emby.example.com 8444',
                                    entry, ok=False)
                    self.assertEqual(self.snapshot(), before)
                    self.assertEqual(self.calls.read_bytes(), calls)

    def test_apply_failure_restores_state_disk_and_live_config(self):
        for entry, command in (('deploy.sh', 'sni_router_call'), ('sb.sh', '_sni_router_cli')):
            self.run_router(command + ' register-https nginx-proxy a.example.com 8444', entry)
            before = self.snapshot()
            for fault in ({'FAIL_CHECK': '1'}, {'FAIL_ACTION': 'reload'}):
                for action in ('register-https nginx-proxy b.example.com 8444',
                               'remove-https nginx-proxy a.example.com'):
                    if action.startswith('remove'):
                        self.run_router(command + ' register-https nginx-proxy c.example.com 8444', entry)
                    with self.subTest(entry=entry, fault=fault, action=action):
                        snapshot = self.snapshot()
                        self.calls.unlink(missing_ok=True)
                        self.run_router(f'{command} {action}', entry, ok=False, **fault)
                        self.assertEqual(self.snapshot(), snapshot)
                        if 'FAIL_ACTION' in fault:
                            self.assertEqual(self.calls.read_text().splitlines()[-2:], ['reload', 'restart'])
                        else:
                            self.assertFalse(self.calls.exists())
                    if action.startswith('remove'):
                        self.run_router(command + ' remove-https nginx-proxy c.example.com', entry)
            self.assertEqual(self.snapshot(), before)

    def test_direct_prepare_failure_restores_config_under_errexit(self):
        self.run_router('_sni_router_cli register-https nginx-proxy a.example.com 8444')
        before_state, before_conf, before_loaded = self.snapshot()
        state = json.loads(before_state)
        state['https_routes']['b.example.com'] = {'owner': 'nginx-proxy'}
        self.state.write_text(json.dumps(state))
        pending_state = self.state.read_bytes()
        for entry, command in (('deploy.sh', 'sni_router_call'), ('sb.sh', '_sni_router_cli')):
            with self.subTest(entry=entry):
                result = self.run_router(command + ' prepare', entry, ok=False, FAIL_ACTION='reload')
                self.assertIn('正在恢复上一份配置', result.stderr)
                self.assertEqual(self.snapshot(), [pending_state, before_conf, before_loaded])
                self.assertEqual(list((self.work / 'tmp').iterdir()), [])

    def test_first_start_failure_keeps_service_inactive(self):
        self.conf.write_text('# Initial HAProxy package configuration\n')
        original = self.conf.read_bytes()
        for entry, command in (('deploy.sh', 'sni_router_call'), ('sb.sh', '_sni_router_cli')):
            with self.subTest(entry=entry):
                self.calls.unlink(missing_ok=True)
                self.run_router(command + ' register-https nginx-proxy a.example.com 8444', entry,
                                ok=False, FAIL_ACTION='start')
                self.assertEqual(json.loads(self.state.read_bytes())['https_routes'], {})
                self.assertEqual(self.conf.read_bytes(), original)
                self.assertFalse(self.loaded.exists())
                self.assertFalse((self.work / 'enabled').exists())
                self.assertNotIn('restart', self.calls.read_text().splitlines())

    def test_restart_failure_after_failed_reload_stops_haproxy(self):
        for entry, command in (('deploy.sh', 'sni_router_call'), ('sb.sh', '_sni_router_cli')):
            with self.subTest(entry=entry):
                self.run_router(command + ' register-https nginx-proxy a.example.com 8444', entry)
                state, conf, _ = self.snapshot()
                result = self.run_router(command + ' register-https nginx-proxy b.example.com 8444',
                                         entry, ok=False, FAIL_ACTION='reload', FAIL_RESTART='1')
                self.assertIn('重启失败', result.stderr)
                self.assertEqual(self.snapshot(), [state, conf, None])
                self.assertEqual(self.calls.read_text().splitlines()[-3:], ['reload', 'restart', 'stop'])

    def test_foreign_frontend_is_preserved(self):
        self.conf.write_text('# Example marker: # Managed by singbox-lite SNI router\n'
                             'frontend foreign\n    bind 127.0.0.1:12345\n')
        self.loaded.write_bytes(self.conf.read_bytes())
        for entry, command in (('deploy.sh', 'sni_router_call'), ('sb.sh', '_sni_router_cli')):
            with self.subTest(entry=entry):
                self.run_router(command + ' status', entry)
                before = self.snapshot()
                result = self.run_router(command + ' register-https nginx-proxy a.example.com 8444',
                                         entry, ok=False)
                self.assertIn('拒绝覆盖', result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_last_route_disable_failure_rolls_back(self):
        for entry, command in (('deploy.sh', 'sni_router_call'), ('sb.sh', '_sni_router_cli')):
            with self.subTest(entry=entry):
                self.run_router(command + ' register-https nginx-proxy a.example.com 8444', entry)
                before = self.snapshot()
                self.run_router(command + ' remove-https nginx-proxy a.example.com', entry, ok=False,
                                FAIL_ACTION='disable')
                self.assertEqual(self.snapshot(), before)
                self.run_router(command + ' remove-https nginx-proxy a.example.com', entry)
                self.assertFalse(self.loaded.exists())

    @unittest.skipUnless(HAPROXY, 'set TEST_HAPROXY for live loopback routing')
    def test_live_matched_routes_and_unmatched_sni(self):
        frontend, https, tls, reality = (self.listen() for _ in range(4))
        state = dict(version=1, public_port=frontend.getsockname()[1], reality=None,
                     https_backend={'host': '127.0.0.1', 'port': https.getsockname()[1]},
                     https_routes={'emby.example.com': {'owner': 'nginx-proxy'}},
                     tls_routes={'ws.example.com': {'owner': 'sb-xray', 'tag': 'ws',
                         'backend_host': '127.0.0.1', 'backend_port': tls.getsockname()[1]}})
        addr = frontend.getsockname()
        frontend.close()
        for with_reality in (False, True):
            with self.subTest(with_reality=with_reality):
                if with_reality:
                    state['reality'] = dict(owner='sb-xray', tag='vision', sni='vision.example.com',
                                            backend_host='127.0.0.1', backend_port=reality.getsockname()[1])
                self.state.write_text(json.dumps(state))
                self.run_router('_sni_router_generate_haproxy_config "$WORK/raw.cfg"')
                # Strip package-account requirements and bind only to loopback.
                config = self.work / 'loopback.cfg'
                config.write_text('\n'.join(line.replace('bind 0.0.0.0:', 'bind 127.0.0.1:')
                    for line in (self.work / 'raw.cfg').read_text().splitlines()
                    if not line.strip().startswith(('user ', 'group ', 'stats socket ', 'bind [::]'))) + '\n')
                with subprocess.Popen([HAPROXY, '-db', '-f', str(config)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as proc:
                    try:
                        self.assert_forwarded(addr, 'EMBY.example.com', https, b'\r\n\r\n\0\r\nQUIT\n', proc=proc)
                        self.assert_forwarded(addr, 'ws.example.com', tls, b'\x16\x03')
                        for sni in ('unknown.example.com', None):
                            if with_reality:
                                self.assert_forwarded(addr, sni, reality, b'\x16\x03')
                            else:
                                with socket.create_connection(addr, timeout=2) as client:
                                    client.sendall(self.hello(sni))
                                    try:
                                        self.assertEqual(client.recv(1), b'')
                                    except ConnectionResetError:
                                        pass
                        for backend in (https, tls, reality):
                            backend.settimeout(.1)
                            with self.assertRaises(TimeoutError):
                                backend.accept()
                    finally:
                        proc.terminate()
                        proc.wait(timeout=5)

    def listen(self):
        sock = socket.socket()
        self.addCleanup(sock.close)
        sock.bind(('127.0.0.1', 0))
        sock.listen()
        return sock

    def connect_frontend(self, addr, proc):
        for _ in range(100):
            if proc.poll() is not None:
                self.fail(proc.stderr.read().decode())
            try:
                return socket.create_connection(addr, timeout=2)
            except ConnectionRefusedError:
                time.sleep(.02)
        self.fail('HAProxy did not listen')

    @staticmethod
    def hello(sni):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        wire = ssl.MemoryBIO()
        connection = context.wrap_bio(ssl.MemoryBIO(), wire, server_hostname=sni)
        try:
            connection.do_handshake()
        except ssl.SSLWantReadError:
            return wire.read()
        raise AssertionError('expected a TLS ClientHello')

    def assert_forwarded(self, addr, sni, backend, prefix, proc=None):
        client = self.connect_frontend(addr, proc) if proc else socket.create_connection(addr, timeout=2)
        with client:
            client.sendall(self.hello(sni))
            backend.settimeout(2)
            conn, _ = backend.accept()
            with conn:
                conn.settimeout(2)
                with conn.makefile('rb') as wire:
                    self.assertEqual(wire.read(len(prefix)), prefix)


if __name__ == '__main__':
    unittest.main(verbosity=2)
