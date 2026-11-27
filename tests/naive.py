#!/usr/bin/env python3
"""Test NaiveProxy node creation, cert policy, HAProxy SNI routing, lifecycle, and live sing-box traffic."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

REPO = Path(__file__).resolve().parents[1]
TEST_SINGBOX = os.environ.get('TEST_SINGBOX')
TEST_SUBSTORE = os.environ.get('TEST_SUBSTORE')
ANSI_RE = re.compile(r'\x1b\[[0-9;]*m')

HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR=$WORK
CONFIG_FILE=$WORK/config.json
METADATA_FILE=$WORK/metadata.json
CLASH_YAML_FILE=$WORK/clash.yaml
XRAY_CONFIG_FILE=$WORK/xray.json
ARGO_METADATA_FILE=$WORK/argo.json
NODE_RELAY_FILE=$WORK/relay.json
NODE_RELAY_LINKS_FILE=$WORK/relay_links.json
RELAY_AUX_DIR=$WORK
SINGBOX_BIN="${HARNESS_SINGBOX_BIN:-$WORK/sing-box}"
XRAY_BIN=$WORK/xray
SNI_ROUTER_STATE_DIR=$WORK/router
SNI_ROUTER_STATE_FILE=$WORK/router/state.json
SNI_ROUTER_LOCK_FILE=$WORK/router.lock
SNI_ROUTER_HAPROXY_CONF=$WORK/haproxy.cfg
SNI_ROUTER_HAPROXY_BACKUP_DIR=$WORK/haproxy-backup
NGINX_CONF_DIR=$WORK/nginx
NGINX_CERT_DIR=$WORK/certs
NGINX_BACKUP_DIR=$WORK/backup
PROXYALL_WRITE_LOCK_FILE=$WORK/lock
NODE_UI="${HARNESS_NODE_UI:-true}"
INIT_SYSTEM=direct
YQ_BINARY=fixture_yq
server_ip=127.0.0.1

mkdir -p "$SNI_ROUTER_STATE_DIR" "$SNI_ROUTER_HAPROXY_BACKUP_DIR" "$NGINX_CONF_DIR" "$NGINX_CERT_DIR" "$NGINX_BACKUP_DIR"

fixture_yq() {
    local expr="${@: -2:1}"
    expr=${expr//strenv\(PROXY_NAME\)/env.PROXY_NAME}
    expr=${expr//strenv\(OLD_NAME\)/env.OLD_NAME}
    expr=${expr//strenv\(NEW_NAME\)/env.NEW_NAME}
    expr=${expr//env\(NEW_PORT_VAL\)/env.NEW_PORT_VAL}
    expr=${expr//.proxy-groups/.[\"proxy-groups\"]}
    jq "$expr" "${@: -1}"
}

_xray_running() { return 1; }
_is_pid_file_running_cmd() { return 1; }
_xray_validate() { return 0; }
_xray_service() { printf 'xray:%s\n' "$*" >> "$WORK/effects"; return 0; }
_get_public_ip() { echo 127.0.0.1; }
_get_ip() { echo 127.0.0.1; }
_check_root() { :; }

_check_port_occupied() {
    local port="$1" proto="${2:-tcp}" list=""
    if [ "$proto" = "udp" ]; then
        list="${OCCUPIED_UDP_PORTS:-}"
    else
        list="${OCCUPIED_TCP_PORTS:-}"
    fi
    case ",${list}," in
        *",${port},"*) return 0 ;;
    esac
    return 1
}

_manage_service() {
    printf '%s\n' "$*" >> "$WORK/restarts"
    printf 'service:%s\n' "$*" >> "$WORK/effects"
    [ "${FAIL_RESTART:-0}" != 1 ]
}

_sni_router_require_systemd() { return 0; }
haproxy() {
    [[ $# == 3 && $1 == -c && $2 == -f && -s $3 ]]
}
systemctl() {
    printf '%s\n' "$*" >> "$WORK/systemctl.calls"
    case "$1" in
        is-active) [[ -f "$WORK/loaded.cfg" ]] ;;
        is-enabled) [[ -f "$WORK/enabled" ]] ;;
        enable) touch "$WORK/enabled" ;;
        reload|start|restart) cp "$SNI_ROUTER_HAPROXY_CONF" "$WORK/loaded.cfg" ;;
        disable)
            rm -f "$WORK/enabled"
            [[ ${2:-} != --now ]] || rm -f "$WORK/loaded.cfg"
            ;;
        stop) rm -f "$WORK/loaded.cfg" ;;
        *) return 1 ;;
    esac
}
export -f _sni_router_require_systemd haproxy systemctl

if [ "${RECORD_SIDE_EFFECTS:-0}" = 1 ]; then
    side_effect() { printf '%s\n' "$*" >> "$WORK/effects"; return 1; }
    _sni_router_prepare() { side_effect sni-router-prepare; }
    _naive_prepare_certificate() { side_effect naive-prepare-cert; }
    _install_sb_acme() { side_effect install-acme; }
    _issue_local_origin_certificate() { side_effect issue-acme; }
    _validate_local_origin_dns() { side_effect validate-dns; }
fi

case "$ACTION" in
    add-naive) _add_naive ;;
    create-naive)
        _create_naive_node "$N_DOMAIN" "$N_PORT" "$N_USER" "$N_PASS" "$N_NAME" \
            "${N_NET:-tcp}" "${N_CERT_MODE:-manual}" "${N_CERT:-}" "${N_KEY:-}" \
            "${N_LISTEN:-::}" "${N_BACKEND:-$N_PORT}" "${N_ROUTER:-false}"
        ;;
    view) _view_nodes ;;
    port) _node_operation _modify_port_impl ;;
    delete) _node_operation _delete_node_impl ;;
    add-menu-dispatch)
        _add_naive() { printf 'naive\n' >> "$WORK/dispatch"; }
        _show_add_node_menu
        ;;
    add-menu-missing-sb)
        SINGBOX_BIN="$WORK/no-such-sing-box"
        _show_add_node_menu
        ;;
    prepare-acme)
        _validate_local_origin_dns() { return 0; }
        _ensure_local_origin_dependencies() { return 0; }
        _xhttp_snapshot_nginx() { return 0; }
        _install_managed_nginx_config() { cp "$1" "$2"; }
        _install_sb_acme() { return 0; }
        _ensure_acme_renewal() { return 0; }
        _issue_local_origin_certificate() {
            printf '%s\n%s\n' "$1" "${2:-}" > "$WORK/acme-issue.args"
            mkdir -p "$NGINX_CERT_DIR/$1"
            cp "$N_CERT" "$NGINX_CERT_DIR/$1/cert"
            cp "$N_KEY" "$NGINX_CERT_DIR/$1/key"
        }
        _naive_prepare_certificate "$N_DOMAIN"
        ;;
    *) exit 3 ;;
esac
'''


def build_cert_bundle(root: Path) -> dict[str, Path]:
    """Generate a temporary root CA, an untrusted CA, and leaf certs for policy & live tests."""
    cert_dir = root / 'pki'
    cert_dir.mkdir(exist_ok=True)

    def init_ca(prefix: str, cn: str) -> tuple[Path, Path, Path]:
        ca_dir = cert_dir / prefix
        (ca_dir / 'newcerts').mkdir(parents=True)
        (ca_dir / 'index.txt').write_text('')
        (ca_dir / 'serial').write_text('1000\n')
        cnf = ca_dir / 'ca.cnf'
        cnf.write_text(f'''
[ca]
default_ca = CA_default

[CA_default]
dir = {ca_dir}
database = $dir/index.txt
new_certs_dir = $dir/newcerts
serial = $dir/serial
private_key = $dir/ca.key
certificate = $dir/ca.pem
default_md = sha256
policy = policy_any
unique_subject = no
copy_extensions = copy

[policy_any]
commonName = supplied

[req]
distinguished_name = dn

[dn]

[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash

[v3_leaf]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
''')
        ca_key = ca_dir / 'ca.key'
        ca_pem = ca_dir / 'ca.pem'
        subprocess.run(
            ['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
             '-nodes', '-keyout', str(ca_key), '-out', str(ca_pem),
             '-subj', f'/CN={cn}', '-days', '30',
             '-config', str(cnf), '-extensions', 'v3_ca'],
            check=True, capture_output=True,
        )
        return ca_pem, ca_key, cnf

    def issue_leaf(ca_cnf: Path, name: str, domain: str, expired: bool = False) -> tuple[Path, Path]:
        key = cert_dir / f'{name}.key'
        csr = cert_dir / f'{name}.csr'
        pem = cert_dir / f'{name}.pem'
        subprocess.run(
            ['openssl', 'req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
             '-nodes', '-keyout', str(key), '-out', str(csr),
             '-subj', f'/CN={domain}',
             '-addext', f'subjectAltName=DNS:{domain}'],
            check=True, capture_output=True,
        )
        args = ['openssl', 'ca', '-batch', '-config', str(ca_cnf), '-extensions', 'v3_leaf',
                '-in', str(csr), '-out', str(pem)]
        if expired:
            args += ['-startdate', '20200101000000Z', '-enddate', '20200102000000Z']
        else:
            args += ['-days', '30']
        subprocess.run(args, check=True, capture_output=True)
        return pem, key

    trusted_ca, _, trusted_cnf = init_ca('trusted', 'Proxyall Test Root CA')
    _, _, untrusted_cnf = init_ca('untrusted', 'Proxyall Untrusted CA')

    valid_pem, valid_key = issue_leaf(trusted_cnf, 'valid', 'naive.example.test')
    second_pem, second_key = issue_leaf(trusted_cnf, 'second', 'second.example.test')
    mismatch_pem, mismatch_key = issue_leaf(trusted_cnf, 'mismatch', 'other.example.test')
    expired_pem, expired_key = issue_leaf(trusted_cnf, 'expired', 'naive.example.test', expired=True)
    untrusted_pem, untrusted_key = issue_leaf(untrusted_cnf, 'untrusted', 'naive.example.test')

    self_key = cert_dir / 'self.key'
    self_pem = cert_dir / 'self.pem'
    subprocess.run(
        ['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
         '-nodes', '-keyout', str(self_key), '-out', str(self_pem),
         '-subj', '/CN=naive.example.test',
         '-addext', 'subjectAltName=DNS:naive.example.test', '-days', '7'],
        check=True, capture_output=True,
    )

    return {
        'ca': trusted_ca,
        'valid_cert': valid_pem,
        'valid_key': valid_key,
        'second_cert': second_pem,
        'second_key': second_key,
        'mismatch_cert': mismatch_pem,
        'mismatch_key': mismatch_key,
        'expired_cert': expired_pem,
        'expired_key': expired_key,
        'untrusted_cert': untrusted_pem,
        'untrusted_key': untrusted_key,
        'self_cert': self_pem,
        'self_key': self_key,
    }


def free_tcp_udp_port() -> int:
    """Find a loopback port currently free on both TCP and UDP."""
    for _ in range(50):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as ts:
            ts.bind(('127.0.0.1', 0))
            port = ts.getsockname()[1]
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as us:
                try:
                    us.bind(('127.0.0.1', port))
                    return port
                except OSError:
                    continue
    raise RuntimeError('unable to allocate a free TCP+UDP port')


class NaiveFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._pki_tmp = tempfile.TemporaryDirectory(prefix='proxyall-naive-pki-')
        cls.certs = build_cert_bundle(Path(cls._pki_tmp.name))

    @classmethod
    def tearDownClass(cls):
        cls._pki_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-naive-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        sb = self.root / 'sing-box'
        sb.write_text('''#!/usr/bin/env bash
case "$1" in
    check) exit 0 ;;
    version) echo 'sing-box version 1.13.0' ;;
    *) exit 1 ;;
esac
''')
        sb.chmod(0o700)
        xray = self.root / 'xray'
        xray.write_text('#!/usr/bin/env bash\necho "Xray 25.10.15"\n')
        xray.chmod(0o700)
        self.tracked = ('config.json', 'metadata.json', 'clash.yaml', 'router/state.json', 'haproxy.cfg')
        self.reset_state()

    def reset_state(self):
        (self.root / 'router').mkdir(exist_ok=True)
        self.store('config.json', {'inbounds': [], 'outbounds': [{'type': 'direct', 'tag': 'direct'}]})
        self.store('metadata.json', {})
        self.store('clash.yaml', {
            'proxies': [{'name': 'ExistingNode', 'type': 'socks5', 'server': '127.0.0.1', 'port': 1080}],
            'proxy-groups': [{'name': '节点选择', 'type': 'select', 'proxies': ['DIRECT', 'ExistingNode']}],
        })
        for f in ('lock', 'restarts', 'effects', 'systemctl.calls', 'loaded.cfg', 'enabled', 'dispatch', 'relay_pf.json'):
            (self.root / f).unlink(missing_ok=True)
        for f in ('router/state.json', 'haproxy.cfg'):
            (self.root / f).unlink(missing_ok=True)

    def store(self, name: str, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False))

    def load(self, name: str):
        return json.loads((self.root / name).read_text())

    def snapshot(self) -> dict[str, tuple[bytes, int, int]]:
        snap = {}
        for name in self.tracked:
            p = self.root / name
            if p.exists():
                st = p.stat()
                snap[name] = (p.read_bytes(), st.st_ino, st.st_mtime_ns)
        return snap

    def run_shell(self, action: str, data: str = '', status: int = 0, use_trusted_ca: bool = True, **extra):
        env = dict(os.environ, REPO=str(REPO), WORK=str(self.root), ACTION=action)
        if use_trusted_ca:
            env['SSL_CERT_FILE'] = str(self.certs['ca'])
        env.update({k: str(v) for k, v in extra.items()})
        result = subprocess.run(
            ['bash', '-c', HARNESS],
            input=data,
            text=True,
            capture_output=True,
            timeout=15,
            env=env,
        )
        self.assertEqual(result.returncode, status, f'rc={result.returncode}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}')
        self.assertFalse(list(self.root.glob('.node-op.*')), result.stderr)
        return result

    def add_naive_interactive(self, domain='naive.example.test', port='18443', shared=None,
                              transport='1', cert_mode='2', cert=None, key=None,
                              user='alice', password='secretpassword', name='MyNaive',
                              status=0, **extra):
        lines = [domain, str(port)]
        if str(port) == '443':
            lines.append('y' if shared is None else shared)
        if not (str(port) == '443' and (shared is None or shared.lower() != 'n')):
            lines.append(str(transport))
        lines.append(str(cert_mode))
        if str(cert_mode) == '2':
            lines.append(str(cert if cert is not None else self.certs['valid_cert']))
            lines.append(str(key if key is not None else self.certs['valid_key']))
        lines += [user, password, name]
        return self.run_shell('add-naive', '\n'.join(lines) + '\n', status=status, **extra)

    def assert_naive_link(self, link: str, scheme: str, user: str, password: str, domain: str, port: int, name: str):
        parsed = urlsplit(link)
        self.assertEqual(parsed.scheme, scheme)
        self.assertEqual(unquote(parsed.username or ''), user)
        self.assertEqual(unquote(parsed.password or ''), password)
        self.assertEqual(parsed.hostname, domain)
        self.assertEqual(parsed.port, port)
        self.assertEqual(parse_qs(parsed.query), {'padding': ['1']})
        self.assertEqual(unquote(parsed.fragment), name)

    @staticmethod
    def strip_ansi(text: str) -> str:
        return ANSI_RE.sub('', text)

    def extract_all_labeled_json_lines(self, text: str, label: str) -> list[tuple[str, dict]]:
        lines = self.strip_ansi(text).splitlines()
        results = []
        for idx, line in enumerate(lines):
            if line.strip() == label:
                self.assertLess(idx + 1, len(lines), f'missing JSON line after {label!r}')
                raw = lines[idx + 1].strip()
                self.assertTrue(raw.startswith('{') and raw.endswith('}'),
                                f'expected single-line JSON after {label!r}, got {raw!r}')
                parsed = json.loads(raw)
                self.assertIsInstance(parsed, dict)
                results.append((raw, parsed))
        return results

    def extract_labeled_json(self, text: str, label: str) -> tuple[str, dict]:
        matches = self.extract_all_labeled_json_lines(text, label)
        self.assertEqual(len(matches), 1, f'expected exactly 1 occurrence of {label!r}, found {len(matches)}')
        return matches[0]

    @staticmethod
    def expected_singbox_outbound(name: str, domain: str, port: int, user: str, password: str, quic: bool = False) -> dict:
        if quic:
            return {
                'type': 'naive',
                'tag': f'{name}-QUIC',
                'server': domain,
                'server_port': port,
                'username': user,
                'password': password,
                'udp_over_tcp': True,
                'quic': True,
                'quic_congestion_control': 'bbr',
                'tls': {'enabled': True, 'server_name': domain},
            }
        return {
            'type': 'naive',
            'tag': name,
            'server': domain,
            'server_port': port,
            'username': user,
            'password': password,
            'udp_over_tcp': True,
            'quic': False,
            'tls': {'enabled': True, 'server_name': domain},
        }

    @staticmethod
    def expected_substore_json(name: str, domain: str, port: int, user: str, password: str, quic: bool = False) -> dict:
        if quic:
            return {
                'name': f'{name}-QUIC',
                'type': 'naive',
                'server': domain,
                'port': port,
                'username': user,
                'password': password,
                'sni': domain,
                'udp-over-tcp': True,
                'quic': True,
                'quic-congestion-control': 'bbr',
            }
        return {
            'name': name,
            'type': 'naive',
            'server': domain,
            'port': port,
            'username': user,
            'password': password,
            'sni': domain,
            'udp-over-tcp': True,
            'quic': False,
        }

    def assert_exact_naive_json_pair(self, text: str, sb_label: str, sub_label: str,
                                     name: str, domain: str, port: int, user: str, password: str,
                                     quic: bool = False):
        _, sb_obj = self.extract_labeled_json(text, sb_label)
        _, sub_obj = self.extract_labeled_json(text, sub_label)
        self.assertEqual(sb_obj, self.expected_singbox_outbound(name, domain, port, user, password, quic=quic))
        self.assertIs(type(sb_obj['server_port']), int)
        self.assertNotIn('insecure', sb_obj['tls'])
        self.assertEqual(sub_obj, self.expected_substore_json(name, domain, port, user, password, quic=quic))
        self.assertIs(type(sub_obj['port']), int)

    def extract_view_base64_lines(self, result: subprocess.CompletedProcess) -> list[str]:
        self.assertIn('=== 聚合 Base64 订阅 ===', result.stdout + result.stderr)
        lines = self.strip_ansi(result.stdout).splitlines()
        sep_indices = [idx for idx, line in enumerate(lines) if line.strip() == '-------------------------------------']
        self.assertTrue(sep_indices, 'node list closing separator not found')
        tail = [line.strip() for line in lines[sep_indices[-1] + 1:] if line.strip()]
        self.assertEqual(len(tail), 1, f'expected single Base64 aggregate line after separator, got {tail!r}')
        decoded = base64.b64decode(tail[0], validate=True).decode()
        return [ln for ln in decoded.splitlines() if ln]


class NaiveNodeTests(NaiveFixture):
    def test_standalone_h2_only_creation_and_defaults(self):
        clash_before = (self.root / 'clash.yaml').read_bytes()
        res = self.add_naive_interactive(
            domain='NAIVE.example.test',
            port='18443',
            transport='1',
            cert_mode='2',
            user='alice123',
            password='passWord456',
            name='Naive-H2',
        )
        config = self.load('config.json')
        self.assertEqual(len(config['inbounds']), 1)
        ib = config['inbounds'][0]
        self.assertEqual(ib['type'], 'naive')
        self.assertTrue(ib['tag'].startswith('naive-in-'))
        self.assertEqual(ib['listen'], '::')
        self.assertEqual(ib['listen_port'], 18443)
        self.assertEqual(ib['network'], 'tcp')
        self.assertNotIn('quic_congestion_control', ib)
        self.assertEqual(ib['users'], [{'username': 'alice123', 'password': 'passWord456'}])
        self.assertEqual(ib['tls'], {
            'enabled': True,
            'server_name': 'naive.example.test',
            'certificate_path': str(self.certs['valid_cert']),
            'key_path': str(self.certs['valid_key']),
        })

        meta = self.load('metadata.json')[ib['tag']]
        self.assertIs(meta['yaml'], False)
        self.assertEqual(meta['naiveNetwork'], 'tcp')
        self.assertEqual(meta['domain'], 'naive.example.test')
        self.assertEqual(meta['server_name'], 'naive.example.test')
        self.assertEqual(meta['publicPort'], 18443)
        self.assertEqual(meta['backendPort'], 18443)
        self.assertEqual(meta['certificatePath'], str(self.certs['valid_cert']))
        self.assertEqual(meta['keyPath'], str(self.certs['valid_key']))
        self.assertNotIn('share_link_quic', meta)
        self.assertNotIn('frontedBy', meta)
        self.assertNotIn('routerRole', meta)
        self.assert_naive_link(meta['share_link'], 'naive+https', 'alice123', 'passWord456',
                               'naive.example.test', 18443, 'Naive-H2')

        # clash.yaml must remain untouched
        self.assertEqual((self.root / 'clash.yaml').read_bytes(), clash_before)
        # Output format checks
        self.assertIn('[HTTP/2 (TCP)]', res.stdout)
        self.assertIn(meta['share_link'], res.stdout)
        self.assertNotIn('[HTTP/3 (QUIC/UDP)]', res.stdout)
        self.assert_exact_naive_json_pair(
            res.stdout, '[sing-box HTTP/2 (TCP)]', '[Sub-Store HTTP/2 (TCP)]',
            'Naive-H2', 'naive.example.test', 18443, 'alice123', 'passWord456', quic=False,
        )
        self.assertNotIn('[sing-box HTTP/3 (QUIC/UDP)]', res.stdout)
        self.assertNotIn('[Sub-Store HTTP/3 (QUIC/UDP)]', res.stdout)
        self.assertIn('clash.yaml', res.stdout)
        self.assertNotIn('CF优选专用链接', res.stdout)

        # Second node using auto-reused CA cert in NGINX_CERT_DIR + Enter defaults for user/pass/name
        reuse_dir = self.root / 'certs' / 'second.example.test'
        reuse_dir.mkdir(parents=True)
        (reuse_dir / 'cert').write_bytes(self.certs['second_cert'].read_bytes())
        (reuse_dir / 'key').write_bytes(self.certs['second_key'].read_bytes())
        self.add_naive_interactive(
            domain='second.example.test',
            port='18444',
            transport='',
            cert_mode='1',
            user='',
            password='',
            name='',
        )
        ib2 = self.load('config.json')['inbounds'][1]
        self.assertEqual(ib2['network'], 'tcp')
        self.assertEqual(ib2['tls']['certificate_path'], str(reuse_dir / 'cert'))
        self.assertEqual(ib2['tls']['key_path'], str(reuse_dir / 'key'))
        self.assertRegex(ib2['users'][0]['username'], r'^[A-Za-z0-9]{16}$')
        self.assertRegex(ib2['users'][0]['password'], r'^[A-Za-z0-9]{24}$')
        meta2 = self.load('metadata.json')[ib2['tag']]
        self.assertEqual(meta2['name'], 'Naive-18444')
        self.assertIs(meta2['yaml'], False)
        self.assertEqual((self.root / 'clash.yaml').read_bytes(), clash_before)

    def test_standalone_h2_h3_creation_and_url_encoding(self):
        clash_before = (self.root / 'clash.yaml').read_bytes()
        special_user = 'u_ser/@+%#?='
        special_pass = 'p@ss:w/ord?=#&%中文'
        special_name = 'Naive 节点 #1 / A&B?C=D'

        res = self.add_naive_interactive(
            domain='naive.example.test',
            port='18445',
            transport='2',
            cert_mode='2',
            user=special_user,
            password=special_pass,
            name=special_name,
        )
        ib = self.load('config.json')['inbounds'][0]
        self.assertEqual(ib['type'], 'naive')
        self.assertEqual(ib['listen'], '::')
        self.assertEqual(ib['listen_port'], 18445)
        self.assertNotIn('network', ib)
        self.assertNotIn('quic_congestion_control', ib)
        self.assertEqual(ib['users'], [{'username': special_user, 'password': special_pass}])

        meta = self.load('metadata.json')[ib['tag']]
        self.assertIs(meta['yaml'], False)
        self.assertEqual(meta['naiveNetwork'], 'both')
        self.assertIn('share_link', meta)
        self.assertIn('share_link_quic', meta)
        self.assert_naive_link(meta['share_link'], 'naive+https', special_user, special_pass,
                               'naive.example.test', 18445, special_name)
        self.assert_naive_link(meta['share_link_quic'], 'naive+quic', special_user, special_pass,
                               'naive.example.test', 18445, special_name)
        # Verify raw links properly percent-encode special characters (no raw spaces or unescaped @/:/?/#)
        self.assertNotIn(' ', meta['share_link'])
        self.assertNotIn(' ', meta['share_link_quic'])
        self.assertEqual(meta['share_link'].count('@'), 1)
        self.assertEqual(meta['share_link_quic'].count('@'), 1)
        self.assertIn('[HTTP/2 (TCP)]', res.stdout)
        self.assertIn('[HTTP/3 (QUIC/UDP)]', res.stdout)
        self.assertIn(meta['share_link'], res.stdout)
        self.assertIn(meta['share_link_quic'], res.stdout)
        self.assert_exact_naive_json_pair(
            res.stdout, '[sing-box HTTP/2 (TCP)]', '[Sub-Store HTTP/2 (TCP)]',
            special_name, 'naive.example.test', 18445, special_user, special_pass, quic=False,
        )
        self.assert_exact_naive_json_pair(
            res.stdout, '[sing-box HTTP/3 (QUIC/UDP)]', '[Sub-Store HTTP/3 (QUIC/UDP)]',
            special_name, 'naive.example.test', 18445, special_user, special_pass, quic=True,
        )
        self.assertEqual((self.root / 'clash.yaml').read_bytes(), clash_before)

    def test_standalone_udp_and_tcp_port_conflict_rejection(self):
        # Seed an existing HY2 node with UDP portHopping 20000-20020 and PF UDP entries in relay_pf.json
        self.store('config.json', {
            'inbounds': [{'type': 'hysteria2', 'tag': 'hy2-existing', 'listen': '::', 'listen_port': 19999}],
            'outbounds': [{'type': 'direct', 'tag': 'direct'}],
        })
        self.store('metadata.json', {
            'hy2-existing': {'name': 'HY2Hop', 'yaml': False, 'publicPort': 19999,
                             'backendPort': 19999, 'portHopping': '20000-20020', 'portHoppingMode': 'nftables'},
        })
        self.store('relay_pf.json', {
            '21001': {'name': 'GameUDP', 'network': 'udp', 'network_display': 'UDP',
                      'target_addr': '1.2.3.4', 'target_port': 21001},
            '21002': {'name': 'DualPF', 'network': 'tcp+udp', 'network_display': 'TCP+UDP',
                      'target_addr': '1.2.3.4', 'target_port': 21002},
        })
        before = self.snapshot()

        # 1. Interactive H2+H3 rejected on HY2 UDP hop port, PF UDP port, PF TCP+UDP port, and system-occupied UDP port
        for label, port, expected_msg, extra in (
            ('hy2-hop', '20010', 'HY2', {}),
            ('pf-udp', '21001', '端口转发', {}),
            ('pf-tcp-udp', '21002', '端口转发', {}),
            ('udp-occupied', '22000', '已被系统其他程序占用', {'OCCUPIED_UDP_PORTS': '22000'}),
        ):
            with self.subTest(case=label):
                # Interactive exits immediately after transport=2 detects UDP conflict
                res = self.run_shell('add-naive', f'naive.example.test\n{port}\n2\n', status=1, **extra)
                self.assertIn(expected_msg, res.stdout + res.stderr)
                self.assertEqual(self.snapshot(), before)

        # 2. Direct _create_naive_node (batch path) also enforces UDP conflicts + TCP config conflict
        for label, port, net, expected_msg, extra in (
            ('batch-hy2-hop', '20015', 'both', 'HY2', {}),
            ('batch-pf-udp', '21001', 'both', '端口转发', {}),
            ('batch-udp-occupied', '22000', 'both', '已被系统其他程序占用', {'OCCUPIED_UDP_PORTS': '22000'}),
            ('batch-tcp-config-conflict', '19999', 'tcp', '已被现有节点配置占用', {}),
        ):
            with self.subTest(case=label):
                res = self.run_shell(
                    'create-naive', status=1,
                    N_DOMAIN='naive.example.test', N_PORT=port, N_USER='u', N_PASS='p',
                    N_NAME='ConflictNode', N_NET=net, N_CERT_MODE='manual',
                    N_CERT=self.certs['valid_cert'], N_KEY=self.certs['valid_key'],
                    **extra,
                )
                self.assertIn(expected_msg, res.stdout + res.stderr)
                self.assertEqual(self.snapshot(), before)

        # 3. H2-only (TCP) on HY2 UDP hop port succeeds because UDP is not bound
        self.add_naive_interactive(domain='naive.example.test', port='20010', transport='1', name='TCP-On-Hop')
        ib = next(i for i in self.load('config.json')['inbounds'] if i['type'] == 'naive')
        self.assertEqual((ib['listen_port'], ib['network']), (20010, 'tcp'))

    def test_shared_443_haproxy_registration_rendering_and_duplicate_sni(self):
        clash_before = (self.root / 'clash.yaml').read_bytes()
        # 1. Interactive shared-443 creation (port 443 -> default Y -> skips transport prompt -> forced tcp)
        res = self.add_naive_interactive(
            domain='naive.example.test',
            port='443',
            shared='y',
            cert_mode='2',
            user='shareduser',
            password='sharedpassword',
            name='Shared-Naive-1',
        )
        self.assertIn('纯 TCP 透传', res.stdout + res.stderr)
        ib = self.load('config.json')['inbounds'][0]
        self.assertEqual(ib['type'], 'naive')
        self.assertEqual(ib['listen'], '127.0.0.1')
        self.assertEqual(ib['listen_port'], 2443)
        self.assertEqual(ib['network'], 'tcp')
        self.assertNotIn('quic_congestion_control', ib)

        meta = self.load('metadata.json')[ib['tag']]
        self.assertEqual(meta['routerRole'], 'tls-sni')
        self.assertEqual(meta['frontedBy'], 'haproxy')
        self.assertEqual(meta['publicPort'], 443)
        self.assertEqual(meta['backendPort'], 2443)
        self.assertEqual(meta['naiveNetwork'], 'tcp')
        self.assertIs(meta['yaml'], False)
        self.assertNotIn('share_link_quic', meta)
        self.assert_naive_link(meta['share_link'], 'naive+https', 'shareduser', 'sharedpassword',
                               'naive.example.test', 443, 'Shared-Naive-1')
        self.assert_exact_naive_json_pair(
            res.stdout, '[sing-box HTTP/2 (TCP)]', '[Sub-Store HTTP/2 (TCP)]',
            'Shared-Naive-1', 'naive.example.test', 443, 'shareduser', 'sharedpassword', quic=False,
        )
        self.assertNotIn('[sing-box HTTP/3 (QUIC/UDP)]', res.stdout)
        self.assertNotIn('[Sub-Store HTTP/3 (QUIC/UDP)]', res.stdout)
        self.assertEqual((self.root / 'clash.yaml').read_bytes(), clash_before)

        # Verify sni_router state and rendered HAProxy config
        state = self.load('router/state.json')
        self.assertEqual(state['tls_routes']['naive.example.test'], {
            'owner': 'sb',
            'tag': ib['tag'],
            'backend_host': '127.0.0.1',
            'backend_port': 2443,
        })
        cfg = (self.root / 'haproxy.cfg').read_text()
        self.assertIn('acl sb_tls_route_0 req.ssl_sni -i naive.example.test', cfg)
        self.assertIn('use_backend sb_tls_backend_0 if sb_tls_route_0', cfg)
        self.assertIn('server tls_0 127.0.0.1:2443', cfg)
        self.assertEqual((self.root / 'loaded.cfg').read_text(), cfg)

        # 2. Duplicate SNI (exact & uppercase) must be rejected without mutating state/config
        before_dup = self.snapshot()
        for dup_domain in ('naive.example.test', 'NAIVE.EXAMPLE.TEST'):
            with self.subTest(dup_domain=dup_domain):
                dup = self.add_naive_interactive(
                    domain=dup_domain,
                    port='443',
                    shared='y',
                    cert_mode='2',
                    user='u2',
                    password='p2',
                    name='Dup-Naive',
                    status=1,
                )
                self.assertIn('已被共享 443 路由占用', dup.stdout + dup.stderr)
                self.assertEqual(self.snapshot(), before_dup)

        # 3. Even if _create_naive_node is called with naive_network=both and router_mode=true, it forces network=tcp
        self.run_shell(
            'create-naive',
            N_DOMAIN='second.example.test', N_PORT='443', N_USER='u2', N_PASS='p2',
            N_NAME='Shared-Naive-2', N_NET='both', N_CERT_MODE='manual',
            N_CERT=self.certs['second_cert'], N_KEY=self.certs['second_key'],
            N_LISTEN='127.0.0.1', N_BACKEND='443', N_ROUTER='true',
        )
        ib2 = self.load('config.json')['inbounds'][1]
        self.assertEqual((ib2['listen'], ib2['listen_port'], ib2['network']), ('127.0.0.1', 2444, 'tcp'))
        meta2 = self.load('metadata.json')[ib2['tag']]
        self.assertEqual(meta2['naiveNetwork'], 'tcp')
        self.assertNotIn('share_link_quic', meta2)
        state2 = self.load('router/state.json')
        self.assertIn('second.example.test', state2['tls_routes'])
        self.assertEqual(state2['tls_routes']['second.example.test']['backend_port'], 2444)
        cfg2 = (self.root / 'haproxy.cfg').read_text()
        self.assertIn('req.ssl_sni -i second.example.test', cfg2)
        self.assertIn('127.0.0.1:2444', cfg2)

    def test_certificate_policy_rejects_invalid_before_tx_and_accepts_ca(self):
        before = self.snapshot()
        rejected_cases = [
            ('self-signed', self.certs['self_cert'], self.certs['self_key'], '信任链'),
            ('untrusted-ca', self.certs['untrusted_cert'], self.certs['untrusted_key'], '信任链'),
            ('mismatched-host', self.certs['mismatch_cert'], self.certs['mismatch_key'], '未覆盖节点 SNI'),
            ('expired', self.certs['expired_cert'], self.certs['expired_key'], '已过期'),
            ('mismatched-key', self.certs['valid_cert'], self.certs['self_key'], '私钥与证书不匹配'),
            ('missing-files', self.root / 'nope.pem', self.root / 'nope.key', '不可读'),
        ]
        for label, cert, key, expected_msg in rejected_cases:
            with self.subTest(case=label):
                res = self.add_naive_interactive(
                    domain='naive.example.test',
                    port='18443',
                    transport='1',
                    cert_mode='2',
                    cert=cert,
                    key=key,
                    user='u',
                    password='p',
                    name=f'Bad-{label}',
                    status=1,
                )
                self.assertIn(expected_msg, res.stdout + res.stderr)
                # Zero file mutations and _node_tx_begin was never entered (no lock, no restarts)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse((self.root / 'lock').exists(), f'{label} entered transaction unexpectedly')
                self.assertFalse((self.root / 'restarts').exists(), f'{label} restarted service unexpectedly')

        # CA-trusted certificate is accepted
        self.add_naive_interactive(
            domain='naive.example.test',
            port='18443',
            transport='1',
            cert_mode='2',
            cert=self.certs['valid_cert'],
            key=self.certs['valid_key'],
            user='gooduser',
            password='goodpassword',
            name='Trusted-Naive',
        )
        self.assertEqual(len(self.load('config.json')['inbounds']), 1)
        self.assertTrue((self.root / 'restarts').exists())

    def test_username_rejects_colon_whitespace_and_control_chars(self):
        before = self.snapshot()
        # 1. Pre-transaction rejection in _create_naive_node_impl (zero mutations, no lock, no restart)
        for label, bad_user in (
            ('colon', 'bad:user'),
            ('space', 'bad user'),
            ('tab', 'bad\tuser'),
            ('control', 'bad\x07user'),
        ):
            with self.subTest(path='create-naive', case=label):
                res = self.run_shell(
                    'create-naive', status=1,
                    N_DOMAIN='naive.example.test', N_PORT='18450', N_USER=bad_user,
                    N_PASS='valid:pass', N_NAME='BadUserNode', N_NET='tcp',
                    N_CERT_MODE='manual', N_CERT=self.certs['valid_cert'], N_KEY=self.certs['valid_key'],
                )
                self.assertIn('用户名不能包含冒号', res.stdout + res.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse((self.root / 'lock').exists())
                self.assertFalse((self.root / 'restarts').exists())

        # 2. Interactive rejection in _add_naive_impl immediately after username prompt
        for label, bad_user in (('colon', 'bad:user'), ('space', 'bad user'), ('tab', 'bad\tuser')):
            with self.subTest(path='interactive', case=label):
                payload = '\n'.join([
                    'naive.example.test', '18450', '1', '2',
                    str(self.certs['valid_cert']), str(self.certs['valid_key']),
                    bad_user,
                ]) + '\n'
                res = self.run_shell('add-naive', payload, status=1)
                self.assertIn('用户名不能包含冒号', res.stdout + res.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse((self.root / 'lock').exists())
                self.assertFalse((self.root / 'restarts').exists())

    def test_naive_acme_prepare_passes_singbox_reload_cmd(self):
        res = self.run_shell(
            'prepare-acme',
            N_DOMAIN='naive.example.test',
            N_CERT=self.certs['valid_cert'],
            N_KEY=self.certs['valid_key'],
        )
        args = (self.root / 'acme-issue.args').read_text().splitlines()
        self.assertEqual(len(args), 2, args)
        domain, reload_cmd = args
        self.assertEqual(domain, 'naive.example.test')
        self.assertIn('systemctl restart sing-box 8>&- 9>&-', reload_cmd)
        self.assertIn('rc-service sing-box restart 8>&- 9>&-', reload_cmd)
        self.assertIn('nginx', reload_cmd)
        self.assertTrue((self.root / 'nginx/00-sb-naive-acme-naive.example.test.conf').is_file())
        self.assertEqual(res.returncode, 0)

    def test_view_nodes_stored_and_fallback_reconstruction(self):
        # Create 3 NaiveProxy nodes: standalone H2, standalone H2+H3 (special chars), shared-443 HAProxy
        self.add_naive_interactive(
            domain='naive.example.test', port='18501', transport='1',
            user='h2user', password='h2pass', name='View-H2',
        )
        self.add_naive_interactive(
            domain='naive.example.test', port='18502', transport='2',
            user='u_special/1', password='p@ss:w#2', name='View H2+H3 中文',
        )
        self.add_naive_interactive(
            domain='second.example.test', port='443', shared='y',
            cert=self.certs['second_cert'], key=self.certs['second_key'],
            user='h443', password='p443', name='View-Shared443',
        )
        meta = self.load('metadata.json')
        tags = [ib['tag'] for ib in self.load('config.json')['inbounds']]
        stored_links = [
            meta[tags[0]]['share_link'],
            meta[tags[1]]['share_link'],
            meta[tags[1]]['share_link_quic'],
            meta[tags[2]]['share_link'],
        ]

        expected_sb_h2 = [
            self.expected_singbox_outbound('View-H2', 'naive.example.test', 18501, 'h2user', 'h2pass', quic=False),
            self.expected_singbox_outbound('View H2+H3 中文', 'naive.example.test', 18502, 'u_special/1', 'p@ss:w#2', quic=False),
            self.expected_singbox_outbound('View-Shared443', 'second.example.test', 443, 'h443', 'p443', quic=False),
        ]
        expected_sb_h3 = [
            self.expected_singbox_outbound('View H2+H3 中文', 'naive.example.test', 18502, 'u_special/1', 'p@ss:w#2', quic=True),
        ]
        expected_sub_h2 = [
            self.expected_substore_json('View-H2', 'naive.example.test', 18501, 'h2user', 'h2pass', quic=False),
            self.expected_substore_json('View H2+H3 中文', 'naive.example.test', 18502, 'u_special/1', 'p@ss:w#2', quic=False),
            self.expected_substore_json('View-Shared443', 'second.example.test', 443, 'h443', 'p443', quic=False),
        ]
        expected_sub_h3 = [
            self.expected_substore_json('View H2+H3 中文', 'naive.example.test', 18502, 'u_special/1', 'p@ss:w#2', quic=True),
        ]

        # 1. Stored share_link / share_link_quic + dynamic sing-box/Sub-Store JSON + URI-only Base64 aggregate
        viewed = self.run_shell('view', 'y\n')
        self.assertIn('NaiveProxy (H2)', viewed.stdout + viewed.stderr)
        self.assertIn('NaiveProxy (H2+H3)', viewed.stdout + viewed.stderr)
        self.assertIn('公网 443 -> HAProxy -> 127.0.0.1:2443', viewed.stdout + viewed.stderr)
        for link in stored_links:
            self.assertIn(link, viewed.stdout)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(viewed.stdout, 'sing-box JSON (H2):')], expected_sb_h2)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(viewed.stdout, 'sing-box JSON (H3/QUIC):')], expected_sb_h3)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(viewed.stdout, 'Sub-Store JSON (H2):')], expected_sub_h2)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(viewed.stdout, 'Sub-Store JSON (H3/QUIC):')], expected_sub_h3)
        for obj in expected_sb_h2 + expected_sb_h3:
            self.assertIs(type(obj['server_port']), int)
            self.assertNotIn('insecure', obj['tls'])
        expected_b64 = base64.b64encode(('\n'.join(stored_links) + '\n').encode()).decode()
        self.assertIn(expected_b64, viewed.stdout)
        decoded_lines = self.extract_view_base64_lines(viewed)
        self.assertEqual(decoded_lines, stored_links)
        for ln in decoded_lines:
            self.assertTrue(ln.startswith(('naive+https://', 'naive+quic://')), ln)
            self.assertFalse(ln.lstrip().startswith('{'), ln)

        # 2. Fallback reconstruction when share_link, share_link_quic, and naiveNetwork are removed from metadata
        for tag in tags:
            meta[tag].pop('share_link', None)
            meta[tag].pop('share_link_quic', None)
            meta[tag].pop('naiveNetwork', None)
        self.store('metadata.json', meta)

        reconstructed = self.run_shell('view', 'y\n')
        self.assertIn('NaiveProxy (H2)', reconstructed.stdout + reconstructed.stderr)
        self.assertIn('NaiveProxy (H2+H3)', reconstructed.stdout + reconstructed.stderr)
        for link in stored_links:
            self.assertIn(link, reconstructed.stdout)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(reconstructed.stdout, 'sing-box JSON (H2):')], expected_sb_h2)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(reconstructed.stdout, 'sing-box JSON (H3/QUIC):')], expected_sb_h3)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(reconstructed.stdout, 'Sub-Store JSON (H2):')], expected_sub_h2)
        self.assertEqual([obj for _, obj in self.extract_all_labeled_json_lines(reconstructed.stdout, 'Sub-Store JSON (H3/QUIC):')], expected_sub_h3)
        self.assertIn(expected_b64, reconstructed.stdout)
        self.assertEqual(self.extract_view_base64_lines(reconstructed), stored_links)

    def test_modify_port_standalone_tcp_both_conflicts_and_tls_sni_refusal(self):
        # Create 3 nodes: [1] standalone TCP (18601), [2] standalone H2+H3 (18602), [3] shared-443 tls-sni
        self.add_naive_interactive(
            domain='naive.example.test', port='18601', transport='1',
            user='tcpuser', password='tcppass', name='Port-TCP',
        )
        self.add_naive_interactive(
            domain='naive.example.test', port='18602', transport='2',
            user='both+u/1', password='both:p/1?x', name='Port Both #1',
        )
        self.add_naive_interactive(
            domain='second.example.test', port='443', shared='y',
            cert=self.certs['second_cert'], key=self.certs['second_key'],
            user='s443', password='p443', name='Port-Shared',
        )
        clash_before = (self.root / 'clash.yaml').read_bytes()
        tags = [ib['tag'] for ib in self.load('config.json')['inbounds']]

        # 1. Modify standalone TCP node 18601 -> 19601
        res_p1 = self.run_shell('port', '1\n19601\n')
        ib1 = next(i for i in self.load('config.json')['inbounds'] if i['tag'] == tags[0])
        m1 = self.load('metadata.json')[tags[0]]
        self.assertEqual(ib1['listen_port'], 19601)
        self.assertEqual((m1['publicPort'], m1['backendPort']), (19601, 19601))
        self.assert_naive_link(m1['share_link'], 'naive+https', 'tcpuser', 'tcppass',
                               'naive.example.test', 19601, 'Port-TCP')
        self.assertNotIn('share_link_quic', m1)
        self.assert_exact_naive_json_pair(
            res_p1.stdout, '[sing-box HTTP/2 (TCP)]', '[Sub-Store HTTP/2 (TCP)]',
            'Port-TCP', 'naive.example.test', 19601, 'tcpuser', 'tcppass', quic=False,
        )
        self.assertNotIn('[sing-box HTTP/3 (QUIC/UDP)]', res_p1.stdout)
        self.assertNotIn('[Sub-Store HTTP/3 (QUIC/UDP)]', res_p1.stdout)
        self.assertEqual((self.root / 'clash.yaml').read_bytes(), clash_before)

        # 2. Seed HY2 hop range + PF UDP + relay.json + xray.json conflicts and verify port edit rejects all of them
        cfg = self.load('config.json')
        cfg['inbounds'].append({'type': 'hysteria2', 'tag': 'hy2-hop', 'listen': '::', 'listen_port': 23000})
        self.store('config.json', cfg)
        meta = self.load('metadata.json')
        meta['hy2-hop'] = {'name': 'HY2Hop', 'yaml': False, 'publicPort': 23000,
                           'backendPort': 23000, 'portHopping': '23001-23020', 'portHoppingMode': 'nftables'}
        self.store('metadata.json', meta)
        self.store('relay_pf.json', {
            '23100': {'name': 'PF-UDP', 'network': 'udp', 'network_display': 'UDP',
                      'target_addr': '5.6.7.8', 'target_port': 23100},
        })
        self.store('relay.json', {
            'inbounds': [{'type': 'socks', 'tag': 'relay-in-1', 'listen': '::', 'listen_port': 23300}],
            'outbounds': [],
            'route': {'rules': []},
        })
        self.store('xray.json', {
            'inbounds': [{'tag': 'xray-in-1', 'port': 23400, 'protocol': 'vless'}],
            'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}],
        })
        before_conflicts = self.snapshot()

        for label, node_idx, target_port, expected_msg, extra in (
            ('tcp-occupied', '1', '23250', 'TCP 端口 23250 已被系统其他程序占用', {'OCCUPIED_TCP_PORTS': '23250'}),
            ('relay-config', '1', '23300', '已被现有节点配置占用', {}),
            ('xray-config', '2', '23400', '已被现有节点配置占用', {}),
            ('udp-occupied', '2', '23200', 'UDP 端口 23200 已被系统其他程序占用', {'OCCUPIED_UDP_PORTS': '23200'}),
            ('hy2-hop', '2', '23010', 'HY2 端口跳跃范围', {}),
            ('pf-udp', '2', '23100', '端口转发入口 23100 冲突', {}),
        ):
            with self.subTest(case=label):
                res = self.run_shell('port', f'{node_idx}\n{target_port}\n', status=1, **extra)
                self.assertIn(expected_msg, res.stdout + res.stderr)
                self.assertEqual(self.snapshot(), before_conflicts)

        # 3. Modify standalone H2+H3 node 18602 -> 19602 (updates BOTH share_link and share_link_quic + JSON)
        res_p2 = self.run_shell('port', '2\n19602\n')
        ib2 = next(i for i in self.load('config.json')['inbounds'] if i['tag'] == tags[1])
        m2 = self.load('metadata.json')[tags[1]]
        self.assertEqual(ib2['listen_port'], 19602)
        self.assertEqual((m2['publicPort'], m2['backendPort']), (19602, 19602))
        self.assert_naive_link(m2['share_link'], 'naive+https', 'both+u/1', 'both:p/1?x',
                               'naive.example.test', 19602, 'Port Both #1')
        self.assert_naive_link(m2['share_link_quic'], 'naive+quic', 'both+u/1', 'both:p/1?x',
                               'naive.example.test', 19602, 'Port Both #1')
        self.assert_exact_naive_json_pair(
            res_p2.stdout, '[sing-box HTTP/2 (TCP)]', '[Sub-Store HTTP/2 (TCP)]',
            'Port Both #1', 'naive.example.test', 19602, 'both+u/1', 'both:p/1?x', quic=False,
        )
        self.assert_exact_naive_json_pair(
            res_p2.stdout, '[sing-box HTTP/3 (QUIC/UDP)]', '[Sub-Store HTTP/3 (QUIC/UDP)]',
            'Port Both #1', 'naive.example.test', 19602, 'both+u/1', 'both:p/1?x', quic=True,
        )
        self.assertEqual((self.root / 'clash.yaml').read_bytes(), clash_before)

        # 3b. Tightened sed regex updates only host port even when :old_port appears in query & fragment
        meta = self.load('metadata.json')
        meta[tags[1]]['share_link'] = 'naive+https://both%2Bu%2F1:both%3Ap%2F1%3Fx@naive.example.test:19602?padding=1&x=:19602#node:19602/v2'
        meta[tags[1]]['share_link_quic'] = 'naive+quic://both%2Bu%2F1:both%3Ap%2F1%3Fx@naive.example.test:19602?padding=1&x=:19602#node:19602/v2'
        self.store('metadata.json', meta)
        self.run_shell('port', '2\n19612\n')
        m2_after = self.load('metadata.json')[tags[1]]
        self.assertEqual(
            m2_after['share_link'],
            'naive+https://both%2Bu%2F1:both%3Ap%2F1%3Fx@naive.example.test:19612?padding=1&x=:19602#node:19602/v2',
        )
        self.assertEqual(
            m2_after['share_link_quic'],
            'naive+quic://both%2Bu%2F1:both%3Ap%2F1%3Fx@naive.example.test:19612?padding=1&x=:19602#node:19602/v2',
        )

        # 4. Shared-443 tls-sni NaiveProxy refuses port modification with generalized message
        before_sni = self.snapshot()
        refused = self.run_shell('port', '3\n19603\n', status=1)
        out = refused.stdout + refused.stderr
        self.assertIn('TLS SNI 节点暂不支持直接修改端口', out)
        self.assertNotIn('普通 AnyTLS', out)
        self.assertEqual(self.snapshot(), before_sni)

    def test_delete_node_single_and_all_including_haproxy_cleanup(self):
        # Create standalone + 2 shared-443 NaiveProxy nodes
        self.add_naive_interactive(
            domain='naive.example.test', port='18701', transport='2',
            user='u1', password='p1', name='Del-Standalone',
        )
        self.add_naive_interactive(
            domain='naive.example.test', port='443', shared='y',
            user='u2', password='p2', name='Del-Shared-1',
        )
        self.add_naive_interactive(
            domain='second.example.test', port='443', shared='y',
            cert=self.certs['second_cert'], key=self.certs['second_key'],
            user='u3', password='p3', name='Del-Shared-2',
        )
        clash_before = (self.root / 'clash.yaml').read_bytes()
        tags = [ib['tag'] for ib in self.load('config.json')['inbounds']]

        # 1. Single delete standalone node (#1)
        self.run_shell('delete', '1\ny\n')
        self.assertEqual([ib['tag'] for ib in self.load('config.json')['inbounds']], tags[1:])
        self.assertNotIn(tags[0], self.load('metadata.json'))
        self.assertEqual((self.root / 'clash.yaml').read_bytes(), clash_before)
        self.assertEqual(set(self.load('router/state.json')['tls_routes'].keys()),
                         {'naive.example.test', 'second.example.test'})

        # 2. Single delete first shared-443 node (#1 now = tags[1]); HAProxy remains active for second route
        self.run_shell('delete', '1\ny\n')
        self.assertEqual([ib['tag'] for ib in self.load('config.json')['inbounds']], [tags[2]])
        self.assertNotIn(tags[1], self.load('metadata.json'))
        self.assertEqual(list(self.load('router/state.json')['tls_routes'].keys()), ['second.example.test'])
        self.assertTrue((self.root / 'loaded.cfg').exists())
        self.assertNotIn('naive.example.test', (self.root / 'haproxy.cfg').read_text())
        self.assertIn('second.example.test', (self.root / 'haproxy.cfg').read_text())

        # 3. Single delete last shared-443 node (#1 now = tags[2]); HAProxy disabled and tls_routes empty
        self.run_shell('delete', '1\ny\n')
        self.assertEqual(self.load('config.json')['inbounds'], [])
        self.assertEqual(self.load('metadata.json'), {})
        self.assertEqual(self.load('router/state.json')['tls_routes'], {})
        self.assertFalse((self.root / 'loaded.cfg').exists())

        # 4. Delete-all (99 + yes) cleans up both standalone and shared-443 HAProxy NaiveProxy nodes
        self.add_naive_interactive(
            domain='naive.example.test', port='18702', transport='1',
            user='ua', password='pa', name='All-Standalone',
        )
        self.add_naive_interactive(
            domain='naive.example.test', port='443', shared='y',
            user='ub', password='pb', name='All-Shared',
        )
        self.assertTrue((self.root / 'loaded.cfg').exists())
        self.run_shell('delete', '99\nyes\n')
        self.assertEqual(self.load('config.json')['inbounds'], [])
        self.assertEqual(self.load('metadata.json'), {})
        self.assertEqual(self.load('router/state.json')['tls_routes'], {})
        self.assertFalse((self.root / 'loaded.cfg').exists())

    def test_menu_14_and_interactive_cancellation(self):
        # 1. Menu [14] rendering and dispatch
        menu = self.run_shell('add-menu-dispatch', '14\n\n0\n')
        self.assertIn('[14]', menu.stdout)
        self.assertIn('NaiveProxy (HTTP/2 / QUIC)', menu.stdout)
        self.assertIn('输入 0 可取消', menu.stdout + menu.stderr)
        self.assertEqual((self.root / 'dispatch').read_text().splitlines(), ['naive'])

        # 2. Menu [14] refuses cleanly when sing-box binary is absent
        missing = self.run_shell('add-menu-missing-sb', '14\n0\n')
        self.assertIn('需要先安装 Sing-box 核心', missing.stdout + missing.stderr)

        # 3. NODE_UI=true cancellation (0 / EOF) at EVERY interactive prompt step leaves zero mutations & side effects
        prompt_paths = [
            # Standalone H2+H3 with manual cert
            ('standalone-manual', [
                'naive.example.test', '18801', '2', '2',
                str(self.certs['valid_cert']), str(self.certs['valid_key']),
                'alice', 'secret', 'CancelNode',
            ]),
            # Shared 443 via HAProxy with ACME cert
            ('shared-443-acme', [
                'naive.example.test', '443', 'y', '1',
                'alice', 'secret', 'CancelShared',
            ]),
            # Standalone 443 (shared=n) H2-only with ACME cert
            ('standalone-443-n', [
                'naive.example.test', '443', 'n', '1', '1',
                'alice', 'secret', 'CancelStandalone443',
            ]),
        ]
        for label, answers in prompt_paths:
            for step in range(len(answers)):
                for last in ('0\n', ''):
                    with self.subTest(path=label, step=step, last=repr(last)):
                        before = self.snapshot()
                        payload = ''.join(a + '\n' for a in answers[:step]) + last
                        self.run_shell('add-naive', payload, status=2, RECORD_SIDE_EFFECTS='1')
                        self.assertEqual(self.snapshot(), before)
                        self.assertFalse((self.root / 'lock').exists())
                        self.assertFalse((self.root / 'effects').exists())
                        self.assertFalse((self.root / 'restarts').exists())

    def test_json_export_special_chars_creation_view_and_port_edit(self):
        special_user = 'alice_spec"\\u'
        special_pass = 'p@ss"\\:中文/word'
        special_name = 'Naive "节点" \\ : 中文 #1'

        # 1. Creation (_show_node_link): exact H2 + H3 sing-box & Sub-Store JSON with escaped ", \, :, UTF-8
        created = self.add_naive_interactive(
            domain='naive.example.test',
            port='18901',
            transport='2',
            cert_mode='2',
            user=special_user,
            password=special_pass,
            name=special_name,
        )
        self.assert_exact_naive_json_pair(
            created.stdout, '[sing-box HTTP/2 (TCP)]', '[Sub-Store HTTP/2 (TCP)]',
            special_name, 'naive.example.test', 18901, special_user, special_pass, quic=False,
        )
        self.assert_exact_naive_json_pair(
            created.stdout, '[sing-box HTTP/3 (QUIC/UDP)]', '[Sub-Store HTTP/3 (QUIC/UDP)]',
            special_name, 'naive.example.test', 18901, special_user, special_pass, quic=True,
        )

        # 2. Viewing (_view_nodes): exact dynamic JSON + Base64 aggregate strictly URI-only
        viewed = self.run_shell('view', 'y\n')
        self.assert_exact_naive_json_pair(
            viewed.stdout, 'sing-box JSON (H2):', 'Sub-Store JSON (H2):',
            special_name, 'naive.example.test', 18901, special_user, special_pass, quic=False,
        )
        self.assert_exact_naive_json_pair(
            viewed.stdout, 'sing-box JSON (H3/QUIC):', 'Sub-Store JSON (H3/QUIC):',
            special_name, 'naive.example.test', 18901, special_user, special_pass, quic=True,
        )
        b64_lines = self.extract_view_base64_lines(viewed)
        self.assertEqual(len(b64_lines), 2, b64_lines)
        self.assert_naive_link(b64_lines[0], 'naive+https', special_user, special_pass,
                               'naive.example.test', 18901, special_name)
        self.assert_naive_link(b64_lines[1], 'naive+quic', special_user, special_pass,
                               'naive.example.test', 18901, special_name)
        for ln in b64_lines:
            self.assertFalse(ln.lstrip().startswith('{'), ln)

        # 3. Port edit (_modify_port_impl): refreshed H2 + H3 JSON with new integer port 19901
        edited = self.run_shell('port', '1\n19901\n')
        self.assert_exact_naive_json_pair(
            edited.stdout, '[sing-box HTTP/2 (TCP)]', '[Sub-Store HTTP/2 (TCP)]',
            special_name, 'naive.example.test', 19901, special_user, special_pass, quic=False,
        )
        self.assert_exact_naive_json_pair(
            edited.stdout, '[sing-box HTTP/3 (QUIC/UDP)]', '[Sub-Store HTTP/3 (QUIC/UDP)]',
            special_name, 'naive.example.test', 19901, special_user, special_pass, quic=True,
        )

        # 4. Subsequent _view_nodes dynamically reflects port 19901 in both JSON formats and URI-only Base64
        viewed_after = self.run_shell('view', 'y\n')
        self.assert_exact_naive_json_pair(
            viewed_after.stdout, 'sing-box JSON (H2):', 'Sub-Store JSON (H2):',
            special_name, 'naive.example.test', 19901, special_user, special_pass, quic=False,
        )
        self.assert_exact_naive_json_pair(
            viewed_after.stdout, 'sing-box JSON (H3/QUIC):', 'Sub-Store JSON (H3/QUIC):',
            special_name, 'naive.example.test', 19901, special_user, special_pass, quic=True,
        )
        b64_after = self.extract_view_base64_lines(viewed_after)
        self.assertEqual(len(b64_after), 2, b64_after)
        self.assert_naive_link(b64_after[0], 'naive+https', special_user, special_pass,
                               'naive.example.test', 19901, special_name)
        self.assert_naive_link(b64_after[1], 'naive+quic', special_user, special_pass,
                               'naive.example.test', 19901, special_name)


class EchoTarget(http.server.BaseHTTPRequestHandler):
    payload = b'NAIVE-LOOPBACK-OK-' + bytes(range(64, 127)) * 32

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(self.payload)))
        self.end_headers()
        self.wfile.write(self.payload)

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        digest = hashlib.sha256(body).hexdigest().encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(digest)))
        self.end_headers()
        self.wfile.write(digest)

    def log_message(self, *args):
        pass


@unittest.skipUnless(TEST_SINGBOX, 'set TEST_SINGBOX for live sing-box check and loopback H2/H3 traffic tests')
class NaiveLiveSingboxTests(NaiveFixture):
    def start_singbox(self, config_path: Path, tcp_port: int, label: str, env=None):
        log_path = self.root / f'{label}.log'
        with log_path.open('w') as log:
            proc = subprocess.Popen([TEST_SINGBOX, 'run', '-c', str(config_path)],
                                    stdout=log, stderr=log, env=env)

        def stop():
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

        self.addCleanup(stop)
        for _ in range(100):
            if proc.poll() is not None:
                self.fail(f'{label} exited early:\n' + log_path.read_text()[-2000:])
            try:
                with socket.create_connection(('127.0.0.1', tcp_port), timeout=0.1):
                    time.sleep(0.15)
                    return proc
            except OSError:
                time.sleep(0.05)
        self.fail(f'{label} did not listen on {tcp_port}:\n' + log_path.read_text()[-2000:])

    @staticmethod
    def read_exact(sock: socket.socket, size: int) -> bytes:
        buf = bytearray()
        while len(buf) < size:
            chunk = sock.recv(size - len(buf))
            if not chunk:
                raise RuntimeError('connection closed early')
            buf.extend(chunk)
        return bytes(buf)

    def socks5_http(self, socks_port: int, target_port: int, upload: bool = False):
        with socket.create_connection(('127.0.0.1', socks_port), timeout=8) as sock:
            sock.settimeout(8)
            sock.sendall(b'\x05\x01\x00')
            self.assertEqual(self.read_exact(sock, 2), b'\x05\x00')
            sock.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01' + target_port.to_bytes(2, 'big'))
            self.assertEqual(self.read_exact(sock, 4), b'\x05\x00\x00\x01')
            self.read_exact(sock, 6)
            body_out = EchoTarget.payload if upload else b''
            method = 'POST' if upload else 'GET'
            req = (f'{method} / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
                   f'Content-Length: {len(body_out)}\r\n\r\n').encode() + body_out
            sock.sendall(req)
            with sock.makefile('rb') as resp:
                status_line = resp.readline()
                self.assertIn(b'200', status_line, f'unexpected HTTP status: {status_line!r}')
                length = None
                while True:
                    line = resp.readline()
                    if line == b'\r\n':
                        break
                    if not line:
                        raise RuntimeError('incomplete HTTP response headers')
                    if line.lower().startswith(b'content-length:'):
                        length = int(line.split(b':', 1)[1])
                body = resp.read(length)
            expected = hashlib.sha256(body_out).hexdigest().encode() if upload else EchoTarget.payload
            self.assertEqual(body, expected)

    def test_singbox_check_h2_and_h2_h3_configs(self):
        for label, transport in (('h2-only', '1'), ('h2-h3', '2')):
            with self.subTest(mode=label):
                self.reset_state()
                self.add_naive_interactive(
                    domain='naive.example.test',
                    port=str(free_tcp_udp_port()),
                    transport=transport,
                    cert_mode='2',
                    user='checkuser',
                    password='checkpassword',
                    name=f'Check-{label}',
                    HARNESS_SINGBOX_BIN=TEST_SINGBOX,
                )
                chk = subprocess.run(
                    [TEST_SINGBOX, 'check', '-c', str(self.root / 'config.json')],
                    text=True, capture_output=True, timeout=10,
                )
                self.assertEqual(chk.returncode, 0, chk.stdout + chk.stderr)

    def test_live_loopback_h2_and_h3_traffic(self):
        inbound_port = free_tcp_udp_port()
        # Generate real H2+H3 NaiveProxy inbound via _add_naive (validated by real sing-box check)
        created = self.add_naive_interactive(
            domain='naive.example.test',
            port=str(inbound_port),
            transport='2',
            cert_mode='2',
            user='liveuser',
            password='live"\\:password123',
            name='Live-Naive',
            HARNESS_SINGBOX_BIN=TEST_SINGBOX,
        )
        viewed = self.run_shell('view', 'n\n', HARNESS_SINGBOX_BIN=TEST_SINGBOX)

        # Parse actual emitted sing-box H2 & H3 outbound JSON directly from _show_node_link & _view_nodes
        _, created_h2 = self.extract_labeled_json(created.stdout, '[sing-box HTTP/2 (TCP)]')
        _, created_h3 = self.extract_labeled_json(created.stdout, '[sing-box HTTP/3 (QUIC/UDP)]')
        _, viewed_h2 = self.extract_labeled_json(viewed.stdout, 'sing-box JSON (H2):')
        _, viewed_h3 = self.extract_labeled_json(viewed.stdout, 'sing-box JSON (H3/QUIC):')
        self.assertEqual(created_h2, viewed_h2)
        self.assertEqual(created_h3, viewed_h3)
        self.assertNotIn('insecure', created_h2['tls'])
        self.assertNotIn('insecure', created_h3['tls'])

        # Verify unmodified emitted sing-box outbounds pass sing-box check as-is
        raw_out_cfg = self.root / 'client-emitted-check.json'
        raw_out_cfg.write_text(json.dumps({'outbounds': [created_h2, created_h3]}))
        chk_raw = subprocess.run([TEST_SINGBOX, 'check', '-c', str(raw_out_cfg)],
                                 text=True, capture_output=True, timeout=10)
        self.assertEqual(chk_raw.returncode, 0, chk_raw.stdout + chk_raw.stderr)

        cfg = self.load('config.json')
        self.assertNotIn('network', cfg['inbounds'][0])
        self.assertNotIn('quic_congestion_control', cfg['inbounds'][0])
        # Bind loopback explicitly in the test runner while preserving generated protocol/tls fields
        cfg['inbounds'][0]['listen'] = '127.0.0.1'
        server_cfg = self.root / 'live-server.json'
        server_cfg.write_text(json.dumps(cfg))

        chk = subprocess.run([TEST_SINGBOX, 'check', '-c', str(server_cfg)],
                             text=True, capture_output=True, timeout=10)
        self.assertEqual(chk.returncode, 0, chk.stdout + chk.stderr)

        target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), EchoTarget)
        self.addCleanup(target.server_close)
        self.addCleanup(target.shutdown)
        threading.Thread(target=target.serve_forever, daemon=True).start()

        self.start_singbox(server_cfg, inbound_port, 'naive-server')

        client_env = dict(os.environ, SSL_CERT_FILE=str(self.certs['ca']))
        for label, emitted_outbound in (('h2', created_h2), ('h3', created_h3)):
            with self.subTest(transport=label):
                socks_port = free_tcp_udp_port()
                outbound = json.loads(json.dumps(emitted_outbound))
                outbound['server'] = '127.0.0.1'
                outbound['tls']['certificate_path'] = str(self.certs['ca'])
                client_cfg = self.root / f'client-{label}.json'
                client_cfg.write_text(json.dumps({
                    'log': {'level': 'warning'},
                    'inbounds': [{
                        'type': 'socks',
                        'tag': 'socks-in',
                        'listen': '127.0.0.1',
                        'listen_port': socks_port,
                    }],
                    'outbounds': [outbound],
                }))
                chk_c = subprocess.run([TEST_SINGBOX, 'check', '-c', str(client_cfg)],
                                       text=True, capture_output=True, timeout=10)
                self.assertEqual(chk_c.returncode, 0, chk_c.stdout + chk_c.stderr)
                self.start_singbox(client_cfg, socks_port, f'naive-client-{label}', env=client_env)
                self.socks5_http(socks_port, target.server_port, upload=False)
                self.socks5_http(socks_port, target.server_port, upload=True)


@unittest.skipUnless(TEST_SUBSTORE, 'set TEST_SUBSTORE to path of proxy-utils.esm.mjs for Sub-Store parse/produce tests')
class NaiveSubStoreTests(NaiveFixture):
    def run_substore_produce(self, raw_text: str) -> dict:
        module_path = Path(TEST_SUBSTORE).resolve()
        self.assertTrue(module_path.is_file(), f'TEST_SUBSTORE not found: {module_path}')
        in_file = self.root / 'substore-in.txt'
        out_file = self.root / 'substore-out.json'
        in_file.write_text(raw_text, encoding='utf-8')
        # Resolve cwd to the package dir containing node_modules if present (e.g. sub-store/backend)
        cwd = module_path.parent
        if not (cwd / 'node_modules').is_dir() and (cwd.parent / 'node_modules').is_dir():
            cwd = cwd.parent
        script = r'''
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');
(async () => {
  const [modPath, inPath, outPath] = process.argv.slice(1);
  const mod = await import(pathToFileURL(modPath).href);
  const api = mod.parse ? mod : (mod.default || mod.ProxyUtils);
  const text = fs.readFileSync(inPath, 'utf8');
  const proxies = api.parse(text);
  const produced = api.produce(proxies, 'sing-box');
  fs.writeFileSync(outPath, JSON.stringify({ proxies, produced: JSON.parse(produced) }), 'utf8');
})().catch((err) => { console.error(err); process.exit(1); });
'''
        res = subprocess.run(
            ['node', '-e', script, '--', str(module_path), str(in_file), str(out_file)],
            cwd=str(cwd),
            text=True,
            capture_output=True,
            timeout=20,
        )
        self.assertEqual(res.returncode, 0, f'node failed:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}')
        return json.loads(out_file.read_text(encoding='utf-8'))

    def test_emitted_substore_json_parse_produce_and_singbox_check(self):
        special_user = 'sub_user/1'
        special_pass = 'p@ss"\\:中文'
        special_name = 'SubStore "Naive" \\ : 中文'

        created_dual = self.add_naive_interactive(
            domain='naive.example.test',
            port='18950',
            transport='2',
            cert_mode='2',
            user=special_user,
            password=special_pass,
            name=special_name,
        )
        created_shared = self.add_naive_interactive(
            domain='second.example.test',
            port='443',
            shared='y',
            cert=self.certs['second_cert'],
            key=self.certs['second_key'],
            user='shared_sub',
            password='shared_pass:443',
            name='SubStore-Shared443',
        )

        raw_h2, _ = self.extract_labeled_json(created_dual.stdout, '[Sub-Store HTTP/2 (TCP)]')
        raw_h3, _ = self.extract_labeled_json(created_dual.stdout, '[Sub-Store HTTP/3 (QUIC/UDP)]')
        raw_shared, _ = self.extract_labeled_json(created_shared.stdout, '[Sub-Store HTTP/2 (TCP)]')

        # Verify _view_nodes emits byte-for-byte identical Sub-Store JSON lines
        viewed = self.run_shell('view', 'n\n')
        view_sub_h2 = [raw for raw, _ in self.extract_all_labeled_json_lines(viewed.stdout, 'Sub-Store JSON (H2):')]
        view_sub_h3 = [raw for raw, _ in self.extract_all_labeled_json_lines(viewed.stdout, 'Sub-Store JSON (H3/QUIC):')]
        self.assertEqual(view_sub_h2, [raw_h2, raw_shared])
        self.assertEqual(view_sub_h3, [raw_h3])

        result = self.run_substore_produce('\n'.join([raw_h2, raw_h3, raw_shared]))
        self.assertEqual(len(result['proxies']), 3)
        outbounds = result['produced']['outbounds']
        self.assertEqual(len(outbounds), 3)

        self.assertEqual(outbounds[0], {
            'tag': special_name,
            'type': 'naive',
            'server': 'naive.example.test',
            'server_port': 18950,
            'tls': {
                'enabled': True,
                'server_name': 'naive.example.test',
                'insecure': False,
            },
            'username': special_user,
            'password': special_pass,
            'udp_over_tcp': {'enabled': True, 'version': 1},
        })
        self.assertEqual(outbounds[1], {
            'tag': f'{special_name}-QUIC',
            'type': 'naive',
            'server': 'naive.example.test',
            'server_port': 18950,
            'tls': {
                'enabled': True,
                'server_name': 'naive.example.test',
                'insecure': False,
            },
            'username': special_user,
            'password': special_pass,
            'udp_over_tcp': {'enabled': True, 'version': 1},
            'quic': True,
            'quic_congestion_control': 'bbr',
        })
        self.assertEqual(outbounds[2], {
            'tag': 'SubStore-Shared443',
            'type': 'naive',
            'server': 'second.example.test',
            'server_port': 443,
            'tls': {
                'enabled': True,
                'server_name': 'second.example.test',
                'insecure': False,
            },
            'username': 'shared_sub',
            'password': 'shared_pass:443',
            'udp_over_tcp': {'enabled': True, 'version': 1},
        })

        if TEST_SINGBOX:
            sb_cfg = self.root / 'substore-produced-singbox.json'
            sb_cfg.write_text(json.dumps({'outbounds': outbounds}), encoding='utf-8')
            chk = subprocess.run([TEST_SINGBOX, 'check', '-c', str(sb_cfg)],
                                 text=True, capture_output=True, timeout=10)
            self.assertEqual(chk.returncode, 0, chk.stdout + chk.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
