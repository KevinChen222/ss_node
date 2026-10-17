#!/usr/bin/env python3
"""Exercise forwarding in a private user/network namespace with a supplied core."""

import argparse
import base64
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--core", required=True)
options, unittest_args = parser.parse_known_args()
CORE = str(Path(options.core).resolve())
REPO = Path(__file__).resolve().parents[1]
parent_netns = os.environ.get("PROXYALL_TEST_PARENT_NETNS")
if not parent_netns or os.readlink("/proc/self/ns/net") == parent_netns:
    raise SystemExit('Run with PROXYALL_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)" unshare -Urn.')
subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
for address in ("192.0.2.1/32", "192.0.2.2/32"):
    subprocess.run(["ip", "addr", "add", address, "dev", "lo"], check=True)


class TCPEcho(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(b"echo:" + data)


class UDPEcho(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(b"echo:" + data, self.client_address)


class ForwardingTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="proxyall-forwarding-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.processes = []
        self.addCleanup(self.stop_processes)
        self.table = "pa_test_" + self.root.name.rsplit("-", 1)[-1]
        self.addCleanup(lambda: subprocess.run(
            ["nft", "delete", "table", "inet", self.table], capture_output=True))
        self.main = self.root / "config.json"
        self.relay = self.root / "relay.json"
        self.links = self.root / "relay_links.json"
        self.meta = self.root / "relay_pf.json"
        (self.root / "parser.sh").write_bytes((REPO / "parser.sh").read_bytes())
        self.write(self.main, {
            "log": {"level": "debug", "timestamp": False},
            "dns": {"servers": [{"type": "local", "tag": "dns-main"}]},
            "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}],
            "route": {"rules": [], "final": "direct", "default_domain_resolver": "dns-main"},
        })
        self.write(self.relay, {"inbounds": [], "outbounds": [], "route": {"rules": []}})
        self.write(self.links, {})
        self.write(self.meta, {})
        self.write(self.root / "metadata.json", {})

    def stop_processes(self):
        for process in reversed(self.processes):
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    @staticmethod
    def read(path):
        return json.loads(path.read_text())

    @staticmethod
    def port():
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]

    def bash(self, body, stdin="", engine="singbox", extra=None, check=True):
        setup = r'''
source "$REPO/advanced_relay.sh"
SCRIPT_DIR="$WORK"
SINGBOX_DIR="$WORK"
RELAY_AUX_DIR="$WORK"
MAIN_CONFIG_FILE="$WORK/config.json"
MAIN_METADATA_FILE="$WORK/metadata.json"
RELAY_CONFIG_FILE="$WORK/relay.json"
RELAY_CLASH_YAML="$WORK/clash.yaml"
PF_METADATA_FILE="$WORK/relay_pf.json"
PF_LOCK_FILE="$WORK/relay_pf.lock"
PF_SYSCTL_FILE="$WORK/sysctl.conf"
PROXYALL_WRITE_LOCK_FILE="$WORK/config.lock"
NFT_TABLE="$TEST_TABLE"
NFT_PERSIST_FILE="$WORK/persist.nft"
SINGBOX_BIN="$TEST_CORE"
YQ_BINARY="$WORK/yq"
INIT_SYSTEM=direct
_pf_detect_engine() { PF_ENGINE="$TEST_ENGINE"; PF_ENV_KIND=host; PF_ACCESS_HINT=""; PF_PUBLISH_HINT=false; }
_pf_service_is_active() { return 0; }
_manage_service() {
    printf '%s\n' "$1" >> "$WORK/services.log"
    [ "${FAIL_RESTART:-0}" != 1 ]
}
_save_nftables_rules() {
    if nft list table inet "$NFT_TABLE" > "$NFT_PERSIST_FILE.tmp" 2>/dev/null; then
        mv "$NFT_PERSIST_FILE.tmp" "$NFT_PERSIST_FILE"
    else
        rm -f "$NFT_PERSIST_FILE.tmp"
    fi
    [ "${FAIL_PERSIST:-0}" != 1 ]
}
_pf_enable_forwarding() {
    printf 'net.ipv4.ip_forward=1\n' > "$PF_SYSCTL_FILE"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}
_pf_setup_dns_cron() { printf 'enable\n' >> "$WORK/cron.log"; }
_pf_remove_dns_cron() { printf 'disable\n' >> "$WORK/cron.log"; }
_get_public_ip() { printf '127.0.0.1\n'; }
_select_reality_sni() {
    SELECTED_REALITY_SNI=localhost
    SELECTED_REALITY_HANDSHAKE_SERVER=127.0.0.2
    SELECTED_REALITY_HANDSHAKE_PORT=38443
}
_pf_warn_firewall_coexistence() { return 0; }
logger() { printf '%s\n' "$*" >> "$WORK/logger.log"; }
'''
        env = dict(os.environ, REPO=str(REPO), WORK=str(self.root),
                   TEST_CORE=CORE, TEST_ENGINE=engine, TEST_TABLE=self.table)
        env.update(extra or {})
        result = subprocess.run(["bash", "-c", setup + "\n" + body], input=stdin,
                                text=True, capture_output=True, env=env, timeout=30)
        (self.root / "last-shell.log").write_text(result.stdout + result.stderr)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def check_core(self):
        result = subprocess.run([CORE, "check", "-c", str(self.main), "-c", str(self.relay)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def start_core(self, *configs):
        log = self.root / f"core-{len(self.processes)}.log"
        with log.open("w") as output:
            process = subprocess.Popen([CORE, "run", *sum((["-c", str(p)] for p in configs), [])],
                                       stdout=output, stderr=subprocess.STDOUT)
        self.processes.append(process)
        time.sleep(0.25)
        self.assertIsNone(process.poll(), log.read_text())
        return process, log

    def echo(self, udp=False, ipv6=False, address=None):
        family = socket.AF_INET6 if ipv6 else socket.AF_INET
        parent = socketserver.ThreadingUDPServer if udp else socketserver.ThreadingTCPServer
        cls = type("EchoServer", (parent,), {"address_family": family, "allow_reuse_address": True,
                                           "daemon_threads": True})
        server = cls((address or ("::1" if ipv6 else "127.0.0.2"), 0), UDPEcho if udp else TCPEcho)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server.server_address[1]

    def traffic(self, port, udp=False, ipv6=False, address=None):
        family = socket.AF_INET6 if ipv6 else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as sock:
            sock.settimeout(2)
            sock.connect((address or ("::1" if ipv6 else "127.0.0.1"), port))
            sock.sendall(b"forward-test")
            self.assertEqual(sock.recv(65536), b"echo:forward-test")

    def add_pf(self, listen, target, protocol="tcp+udp", engine="singbox", addr="127.0.0.2", extra=None):
        choice = {"tcp": 1, "udp": 2, "tcp+udp": 3}[protocol]
        return self.bash("_pf_add", f"{listen}\n{addr}\n{target}\n{choice}\nforward\n\n",
                         engine=engine, extra=extra, check=not extra)

    def make_relay(self, choice=4, out=None):
        out = out or {"type": "shadowsocks", "server": "127.0.0.1", "server_port": 39001,
                      "method": "aes-128-gcm", "password": "relay-secret"}
        port = self.port()
        answers = f"{choice}\n{port}\n"
        if choice != 1:
            answers += "localhost\n"
        answers += "relay-test\n"
        if choice == 2:
            answers += "n\n"
        answers += "\n"
        self.bash('_finalize_relay_setup "$DEST_TYPE" 127.0.0.1 39001 "$OUTBOUND"', answers,
                  extra={"DEST_TYPE": out["type"], "OUTBOUND": json.dumps(out)})
        self.check_core()
        return port

    def test_pf_singbox_core_matrix(self):
        for protocol in ("tcp", "udp", "tcp+udp"):
            for addr in ("127.0.0.2", "::1", "localhost"):
                with self.subTest(protocol=protocol, addr=addr):
                    port = self.port()
                    self.add_pf(port, 39001, protocol, addr=addr)
                    self.check_core()
                    self.bash('_pf_apply_singbox_rules delete "$PORT"', extra={"PORT": str(port)})

    def test_pf_singbox_tcp_traffic(self):
        target, listen = self.echo(), self.port()
        self.add_pf(listen, target, "tcp")
        self.start_core(self.main, self.relay)
        self.traffic(listen)

    def test_pf_singbox_udp_traffic(self):
        target, listen = self.echo(udp=True), self.port()
        self.add_pf(listen, target, "udp")
        self.start_core(self.main, self.relay)
        self.traffic(listen, udp=True)

    def test_pf_singbox_ipv6_traffic(self):
        target, listen = self.echo(ipv6=True), self.port()
        self.add_pf(listen, target, "tcp", addr="::1")
        self.start_core(self.main, self.relay)
        self.traffic(listen, ipv6=True)

    def test_pf_nft_tcp_traffic(self):
        target, listen = self.echo(address="192.0.2.2"), self.port()
        self.add_pf(listen, target, "tcp", "nftables", addr="192.0.2.2")
        self.traffic(listen, address="192.0.2.1")

    def test_pf_nft_udp_traffic(self):
        target, listen = self.echo(udp=True, address="192.0.2.2"), self.port()
        self.add_pf(listen, target, "udp", "nftables", addr="192.0.2.2")
        self.traffic(listen, udp=True, address="192.0.2.1")

    def test_pf_nft_ipv6_traffic(self):
        target, listen = self.echo(ipv6=True), self.port()
        self.add_pf(listen, target, "tcp", "nftables", addr="::1")
        self.traffic(listen, ipv6=True)

    def test_pf_modify_delete(self):
        for engine in ("singbox", "nftables"):
            with self.subTest(engine=engine):
                port = self.port()
                self.add_pf(port, 39001, "tcp", engine)
                self.bash("_pf_modify", "1\nchanged\n127.0.0.2\n39002\n3\n\n", engine)
                self.assertEqual(self.read(self.meta)[str(port)]["target_port"], 39002)
                self.assertEqual(self.read(self.meta)[str(port)]["network"], "tcp+udp")
                self.check_core()
                self.bash("_pf_delete", "1\n\n", engine)
                self.assertEqual(self.read(self.meta), {})
                self.assertEqual(self.read(self.relay)["inbounds"], [])

    def test_pf_engine_switch(self):
        port = self.port()
        self.add_pf(port, 39001, "tcp+udp")
        self.bash("_pf_switch_engine", "1\ny\n\n", "nftables")
        self.assertEqual(self.read(self.meta)[str(port)]["engine"], "nftables")
        self.assertEqual(self.read(self.relay)["inbounds"], [])
        self.bash("_pf_switch_engine", "1\ny\n\n", "nftables")
        self.assertEqual(self.read(self.meta)[str(port)]["engine"], "singbox")
        self.check_core()

    def test_pf_restart_failure_rolls_back(self):
        before = self.relay.read_bytes(), self.meta.read_bytes()
        result = self.add_pf(self.port(), 39001, extra={"FAIL_RESTART": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.relay.read_bytes(), self.meta.read_bytes()), before)

    def test_pf_persist_failure_rolls_back(self):
        before = self.relay.read_bytes(), self.meta.read_bytes()
        result = self.add_pf(self.port(), 39001, engine="nftables", extra={"FAIL_PERSIST": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.relay.read_bytes(), self.meta.read_bytes()), before)
        rules = subprocess.run(["nft", "list", "table", "inet", self.table], capture_output=True, text=True)
        self.assertNotIn("dnat", rules.stdout)

    def test_pf_clear_preserves_relay(self):
        self.make_relay()
        relay_before = self.read(self.relay)
        self.add_pf(self.port(), 39001)
        self.bash("_pf_clear", "y\n\n")
        self.assertEqual(self.read(self.relay), relay_before)
        self.assertEqual(self.read(self.meta), {})
        self.check_core()

    def test_relay_inbound_core_matrix(self):
        for choice in (1, 2, 3, 4):
            with self.subTest(choice=choice):
                self.make_relay(choice)

    def test_relay_clear_preserves_port_forward(self):
        port = self.port()
        self.add_pf(port, 39001)
        self.make_relay()
        self.bash("_clear_all_relays")
        self.assertTrue(any(i["tag"] == f"pf-in-{port}" for i in self.read(self.relay)["inbounds"]),
                        "Clearing relay chains also removed an unrelated sing-box port forward")
        self.check_core()

    def test_reuse_existing_inbound(self):
        main = self.read(self.main)
        main["inbounds"] = [{"type": "socks", "tag": "existing-node", "listen": "::", "listen_port": self.port()}]
        self.write(self.main, main)
        before = self.main.read_bytes()
        self.bash('_offer_existing_inbound_relay shadowsocks 127.0.0.1 39001 \'{"type":"shadowsocks","server":"127.0.0.1","server_port":39001,"method":"aes-128-gcm","password":"secret"}\'',
                  "y\n1\n\n")
        self.check_core()
        self.assertEqual(self.main.read_bytes(), before)
        self.bash("_delete_relay", "1\n")
        self.assertEqual(self.main.read_bytes(), before)
        self.assertEqual(self.read(self.relay)["outbounds"], [])

    def test_reuse_failure_rolls_back(self):
        main = self.read(self.main)
        main["inbounds"] = [{"type": "socks", "tag": "existing-node", "listen": "::", "listen_port": self.port()}]
        self.write(self.main, main)
        before = self.relay.read_bytes(), self.links.read_bytes()
        result = self.bash('_offer_existing_inbound_relay shadowsocks 127.0.0.1 39001 \'{"type":"shadowsocks","server":"127.0.0.1","server_port":39001,"method":"aes-128-gcm","password":"secret"}\'',
                           "y\n1\n\n", extra={"FAIL_RESTART": "1"}, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual((self.relay.read_bytes(), self.links.read_bytes()), before)

    def test_token_import(self):
        outbound = {"type": "shadowsocks", "server": "127.0.0.1", "server_port": 39001,
                    "method": "aes-128-gcm", "password": "relay-secret"}
        encoded = base64.b64encode(json.dumps(outbound).encode()).decode()
        encrypted = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-a", "-A", "-pass", "pass:test-key"],
                                   input=json.dumps(outbound), text=True, capture_output=True, check=True).stdout
        for token in (encoded, "ENC:test-key:" + encrypted):
            with self.subTest(token_type="encrypted" if token.startswith("ENC:") else "base64"):
                self.bash("_relay_config", f"{token}\n4\n{self.port()}\nlocalhost\nimported\n\n")
                self.check_core()
                self.assertEqual(self.read(self.relay)["outbounds"][0]["password"], "relay-secret")

    def test_share_link_import(self):
        auth = base64.b64encode(b"aes-128-gcm:relay-secret").decode()
        link = f"ss://{auth}@127.0.0.1:39001#landing"
        self.bash("_import_link_config", f"{link}\n4\n{self.port()}\nlocalhost\nimported\n\n")
        self.check_core()
        self.assertEqual(self.read(self.relay)["outbounds"][0]["password"], "relay-secret")

    def test_relay_modify_updates_public_port(self):
        old_port = self.make_relay()
        new_port = self.port()
        self.bash("_modify_relay_port", f"1\n{new_port}\n\n")
        self.assertEqual(self.read(self.relay)["inbounds"][0]["listen_port"], new_port)
        meta = next(iter(self.read(self.links).values()))
        self.assertEqual(meta["public_port"], new_port,
                         f"Metadata still advertises the old port {old_port}")
        self.assertEqual(meta["backend_port"], new_port)

    def test_relay_modify_restart_failure_rolls_back(self):
        self.make_relay()
        before = self.relay.read_bytes(), self.links.read_bytes()
        result = self.bash("_modify_relay_port", f"1\n{self.port()}\n\n",
                           extra={"FAIL_RESTART": "1"}, check=False)
        self.assertNotEqual(result.returncode, 0, "Port change reported success after restart failed")
        self.assertEqual((self.relay.read_bytes(), self.links.read_bytes()), before)

    def test_relay_clear_restart_failure_rolls_back(self):
        self.add_pf(self.port(), 39001)
        self.make_relay()
        before = tuple(path.read_bytes() for path in (self.main, self.relay, self.links, self.meta))
        result = self.bash("_clear_all_relays", extra={"FAIL_RESTART": "1"}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(tuple(path.read_bytes() for path in (self.main, self.relay, self.links, self.meta)), before)

    def test_relay_modify_yaml_failure_rolls_back(self):
        self.make_relay()
        yaml = self.root / "clash.yaml"
        yaml.write_text("proxies: []\nproxy-groups: []\n")
        (self.root / "yq").write_text("#!/bin/sh\nexit 1\n")
        before = tuple(path.read_bytes() for path in (self.relay, self.links, yaml))
        result = self.bash('_atomic_modify_yaml() { echo invalid > "$RELAY_CLASH_YAML"; return 1; }; _modify_relay_port',
                           f"1\n{self.port()}\n\n", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(tuple(path.read_bytes() for path in (self.relay, self.links, yaml)), before)

    def test_relay_modify_metadata_failure_rolls_back(self):
        self.make_relay()
        before = self.relay.read_bytes(), self.links.read_bytes()
        result = self.bash('mv() { if [ "${@: -1}" = "$WORK/relay_links.json" ]; then return 1; fi; command mv "$@"; }; _modify_relay_port',
                           f"1\n{self.port()}\n\n", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.relay.read_bytes(), self.links.read_bytes()), before)

    def test_relay_modify_quoted_name(self):
        old_port = self.make_relay()
        links = self.read(self.links)
        tag = next(iter(links))
        links[tag]["node_name"] = f'node "quoted" \\ route-{old_port}'
        self.write(self.links, links)
        new_port = self.port()
        self.bash("_modify_relay_port", f"1\n{new_port}\n\n")
        self.assertEqual(self.read(self.links)[tag]["node_name"], f'node "quoted" \\ route-{new_port}')
        self.check_core()

    def test_relay_clear_with_ruleset_preserves_forward(self):
        port = self.port()
        self.add_pf(port, 39001)
        self.make_relay()
        self.bash('''
policy='{"id":"test","inbound":"","url":"https://example.com/test.srs","dns_ip":"","outbound":{"type":"direct","tag":"ruleset-out-test"}}'
_ruleset_render "$RELAY_CONFIG_FILE" "$WORK/relay_links.json" add "$policy" "$WORK/rendered.json" "$WORK/render-links.json" true || exit 1
mv "$WORK/render-links.json.main" "$MAIN_CONFIG_FILE"
mv "$WORK/render-links.json.config" "$RELAY_CONFIG_FILE"
mv "$WORK/render-links.json" "$WORK/relay_links.json"
_clear_all_relays
''')
        relay = self.read(self.relay)
        self.assertTrue(any(i["tag"] == f"pf-in-{port}" for i in relay["inbounds"]))
        self.assertEqual([o["tag"] for o in relay["outbounds"]], [f"pf-out-{port}"])
        self.assertEqual(self.read(self.main)["route"]["rules"], [])
        self.assertEqual(self.read(self.links), {})
        self.check_core()

    def test_relay_delete_nft_restart_failure_rolls_back(self):
        self.make_relay(2)
        links = self.read(self.links)
        tag = next(iter(links))
        port = links[tag]["backend_port"]
        links[tag]["port_hopping"] = "20000-20010"
        self.write(self.links, links)
        self.bash('_nft_apply_redirect_rule add 20000 20010 "$PORT" "$COMMENT" && _save_nftables_rules',
                  extra={"PORT": str(port), "COMMENT": f"singboxlite-relay-hop-{tag}"})
        before = tuple(path.read_bytes() for path in (self.relay, self.links, self.root / "persist.nft"))
        result = self.bash("_delete_relay", "1\n", extra={"FAIL_RESTART": "1"}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(tuple(path.read_bytes() for path in (self.relay, self.links, self.root / "persist.nft")), before)
        rules = subprocess.run(["nft", "list", "table", "inet", self.table], capture_output=True, text=True, check=True)
        self.assertIn(f"redirect to :{port}", rules.stdout)

    def test_relay_router_restart_failure_restores_registration(self):
        port = self.make_relay(1)
        links = self.read(self.links)
        tag = next(iter(links))
        links[tag].update(fronted_by="haproxy", router_role="reality-default", public_port=443)
        self.write(self.links, links)
        before = self.relay.read_bytes(), self.links.read_bytes()
        result = self.bash('''
_sni_router_call() { printf '%s\n' "$*" >> "$WORK/router-calls.log"; }
_delete_relay
''', "1\n", extra={"FAIL_RESTART": "1"}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.relay.read_bytes(), self.links.read_bytes()), before)
        calls = (self.root / "router-calls.log").read_text().splitlines()
        self.assertEqual(calls, [f"remove-reality {tag}", f"register-reality advanced-relay {tag} localhost {port}"])

    def test_relay_delete_restart_failure_rolls_back(self):
        self.make_relay()
        before = self.relay.read_bytes(), self.links.read_bytes()
        result = self.bash("_delete_relay", "1\n", extra={"FAIL_RESTART": "1"}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.relay.read_bytes(), self.links.read_bytes()), before,
                         "Deleting a relay did not restore its configuration after restart failed")

    def test_relay_delete_reuse_preserves_same_port_outbound(self):
        port = self.make_relay()
        main = self.read(self.main)
        tls = self.read(self.relay)["inbounds"][0]["tls"]
        tls["alpn"] = ["h3"]
        main["inbounds"] = [{"type": "hysteria2", "tag": f"hysteria2-{port}", "listen": "::", "listen_port": port,
                             "users": [{"password": "reuse-secret"}], "tls": tls}]
        self.write(self.main, main)
        self.bash('_offer_existing_inbound_relay shadowsocks 127.0.0.1 39001 \'{"type":"shadowsocks","server":"127.0.0.1","server_port":39001,"method":"aes-128-gcm","password":"secret"}\'',
                  "y\n1\n\n")
        self.bash("_delete_relay", "2\n")
        self.check_core()
        self.assertTrue(any(o["tag"] == f"relay-out-{port}" for o in self.read(self.relay)["outbounds"]))

    def test_relay_modify_rejects_occupied_udp(self):
        old_port = self.make_relay(2)
        occupied = self.echo(udp=True)
        self.bash("_modify_relay_port", f"1\n{occupied}\n\n", check=False)
        self.assertEqual(self.read(self.relay)["inbounds"][0]["listen_port"], old_port,
                         "A Hysteria2 port change accepted a port already occupied by another UDP service")

    def nft_loopback(self, route_localnet):
        setting = "net.ipv4.conf.all.route_localnet"
        old_value = subprocess.run(["sysctl", "-n", setting], capture_output=True, text=True, check=True).stdout.strip()
        subprocess.run(["sysctl", "-w", f"{setting}={route_localnet}"], capture_output=True, check=True)
        self.addCleanup(lambda: subprocess.run(["sysctl", "-w", f"{setting}={old_value}"], capture_output=True))
        target, listen = self.echo(), self.port()
        self.add_pf(listen, target, "tcp", "nftables")
        self.traffic(listen)

    def test_pf_nft_loopback_target(self):
        self.nft_loopback(0)

    def test_pf_nft_loopback_route_localnet_control(self):
        self.nft_loopback(1)

    def test_pf_engine_switch_traffic(self):
        target, listen = self.echo(address="192.0.2.2"), self.port()
        self.add_pf(listen, target, "tcp", addr="192.0.2.2")
        self.bash("_pf_switch_engine", "1\ny\n\n", "nftables")
        self.traffic(listen, address="192.0.2.1")
        self.bash("_pf_switch_engine", "1\ny\n\n", "nftables")
        self.start_core(self.main, self.relay)
        self.traffic(listen)

    def test_pf_dns_refresh(self):
        port = self.port()
        self.add_pf(port, 39001, engine="nftables", addr="localhost")
        old_ip = self.read(self.meta)[str(port)]["resolved_ip"]
        self.bash('_pf_resolve_domain_family() { echo 192.0.2.2; }; _pf_dns_refresh')
        self.assertNotEqual(old_ip, "192.0.2.2")
        self.assertEqual(self.read(self.meta)[str(port)]["resolved_ip"], "192.0.2.2")
        rules = subprocess.run(["nft", "list", "table", "inet", self.table], capture_output=True, text=True, check=True)
        self.assertIn("192.0.2.2:39001", rules.stdout)

    def test_pf_reject_occupied_udp(self):
        occupied = self.echo(udp=True)
        result = self.add_pf(occupied, 39001, "udp", extra={"TEST_CASE": "occupied"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read(self.meta), {})

    def test_pf_preserves_state_when_metadata_write_fails(self):
        before = self.relay.read_bytes(), self.meta.read_bytes()
        result = self.bash('_pf_store_metadata() { return 1; }; _pf_add',
                           f"{self.port()}\n127.0.0.2\n39001\n1\nforward\n\n", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.relay.read_bytes(), self.meta.read_bytes()), before)

    def certificate(self, name):
        cert, key = self.root / f"{name}.pem", self.root / f"{name}.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                        "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], capture_output=True, check=True)
        return cert, key

    def relay_traffic(self, choice, udp, destination="shadowsocks", insecure_control=False):
        target = self.echo(udp=udp)
        downstream_port = self.port()
        uuid = "99a16b48-7a04-477d-9a9f-2409af9cf3c0"
        credentials = {
            "shadowsocks": {"method": "aes-128-gcm", "password": "relay-secret"},
            "shadowsocks2022": {"method": "2022-blake3-aes-128-gcm", "password": base64.b64encode(b"0123456789abcdef").decode()},
            "vless": {"uuid": uuid},
            "vmess": {"uuid": uuid},
            "trojan": {"password": "relay-secret"},
            "hysteria2": {"password": "relay-secret"},
            "tuic": {"uuid": uuid, "password": "relay-secret"},
            "anytls": {"password": "relay-secret"},
        }[destination]
        kind = "shadowsocks" if destination == "shadowsocks2022" else destination
        landing_inbound = {"type": kind, "tag": "landing", "listen": "127.0.0.1", "listen_port": downstream_port}
        if kind == "shadowsocks":
            landing_inbound.update(credentials)
        else:
            landing_inbound["users"] = [credentials]
        outbound = {"type": kind, "server": "127.0.0.1", "server_port": downstream_port, **credentials}
        if kind == "vmess":
            outbound["security"] = "auto"
        if kind in ("trojan", "hysteria2", "tuic", "anytls"):
            cert, key = self.certificate("landing")
            landing_inbound["tls"] = {"enabled": True, "server_name": "localhost", "certificate_path": str(cert), "key_path": str(key)}
            outbound["tls"] = {"enabled": True, "server_name": "localhost", "insecure": True}
            if kind in ("hysteria2", "tuic"):
                landing_inbound["tls"]["alpn"] = ["h3"]
                outbound["tls"]["alpn"] = ["h3"]
            if kind == "hysteria2":
                outbound["disable_chrome_parrot"] = True
        downstream = self.root / "downstream.json"
        self.write(downstream, {
            "log": {"level": "debug"},
            "inbounds": [landing_inbound],
            "outbounds": [{"type": "direct", "tag": "landing-direct"}],
            "route": {"final": "landing-direct"},
        })
        self.start_core(downstream)
        if choice == 1:
            cert, key = self.certificate("handshake")
            server = subprocess.Popen(["openssl", "s_server", "-quiet", "-www", "-tls1_3", "-accept", "127.0.0.2:38443",
                                       "-cert", str(cert), "-key", str(key)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.processes.append(server)
            time.sleep(0.1)
        if choice == 0:
            reused_port = self.port()
            main = self.read(self.main)
            main["inbounds"] = [{"type": "vless", "tag": "existing-node", "listen": "::", "listen_port": reused_port,
                                 "users": [{"uuid": uuid}]}]
            self.write(self.main, main)
            self.bash('_offer_existing_inbound_relay "$DEST_TYPE" 127.0.0.1 39001 "$OUTBOUND"',
                      "y\n1\n\n", extra={"DEST_TYPE": kind, "OUTBOUND": json.dumps(outbound)})
            node = {"type": "vless", "server": "127.0.0.1", "server_port": reused_port, "uuid": uuid}
        else:
            self.make_relay(choice, outbound)
            link = next(iter(self.read(self.links).values()))["link"]
            result = subprocess.run(["bash", str(REPO / "parser.sh"), link], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            node = json.loads(result.stdout)
        _, relay_log = self.start_core(self.main, self.relay)
        node["tag"] = "node"
        if insecure_control:
            node["tls"]["insecure"] = True
        client_port = self.port()
        client = self.root / "client.json"
        self.write(client, {
            "log": {"level": "debug"},
            "inbounds": [{"type": "direct", "tag": "probe", "listen": "127.0.0.1",
                          "listen_port": client_port, "network": "udp" if udp else "tcp"}],
            "outbounds": [node],
            "route": {"rules": [{"inbound": "probe", "action": "route", "outbound": "node",
                                  "override_address": "127.0.0.2", "override_port": target, "udp_connect": True}]},
        })
        _, client_log = self.start_core(client)
        try:
            self.traffic(client_port, udp=udp)
        except (OSError, AssertionError) as error:
            self.fail(f"{error}\nCLIENT:\n{client_log.read_text()[-6000:]}\nRELAY:\n{relay_log.read_text()[-6000:]}")
        self.assertIn(f"outbound/{kind}[relay-out-", relay_log.read_text())

    def test_tuic_traffic_with_explicit_insecure(self):
        self.relay_traffic(3, False, insecure_control=True)

    def test_generated_tuic_link_preserves_insecure(self):
        self.make_relay(3)
        link = next(iter(self.read(self.links).values()))["link"]
        result = subprocess.run(["bash", str(REPO / "parser.sh"), link], capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(result.stdout)["tls"]["insecure"],
                        "Generated allow_insecure=1 is discarded by the node link parser")

    def test_pf_nft_ingress_tcp_udp(self):
        peers = []
        for suffix, subnet in (("c", "10.77.0"), ("b", "10.78.0")):
            peer = subprocess.Popen(["unshare", "-n", "sleep", "120"])
            self.processes.append(peer)
            for _ in range(100):
                if os.readlink(f"/proc/{peer.pid}/ns/net") != os.readlink("/proc/self/ns/net"):
                    break
                time.sleep(0.01)
            local, remote = f"pa-{suffix}", f"pa-{suffix}-peer"
            subprocess.run(["ip", "link", "add", local, "type", "veth", "peer", "name", remote], check=True)
            self.addCleanup(lambda name=local: subprocess.run(["ip", "link", "del", name], capture_output=True))
            subprocess.run(["ip", "link", "set", remote, "netns", str(peer.pid)], check=True)
            subprocess.run(["ip", "addr", "add", f"{subnet}.1/24", "dev", local], check=True)
            subprocess.run(["ip", "link", "set", local, "up"], check=True)
            prefix = ["nsenter", "-t", str(peer.pid), "-n"]
            for args in (["ip", "link", "set", "lo", "up"],
                         ["ip", "addr", "add", f"{subnet}.2/24", "dev", remote],
                         ["ip", "link", "set", remote, "up"],
                         ["ip", "route", "add", "default", "via", f"{subnet}.1"]):
                subprocess.run(prefix + args, check=True)
            peers.append(prefix)
        server_code = '''
import socketserver,threading,time
class TCP(socketserver.BaseRequestHandler):
 def handle(self): self.request.sendall(b"echo:"+self.request.recv(65536))
class UDP(socketserver.BaseRequestHandler):
 def handle(self): self.request[1].sendto(b"echo:"+self.request[0],self.client_address)
for cls,handler in ((socketserver.ThreadingTCPServer,TCP),(socketserver.ThreadingUDPServer,UDP)):
 server=cls(("10.78.0.2",39001),handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
time.sleep(60)
'''
        server = subprocess.Popen(peers[1] + [sys.executable, "-c", server_code],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.processes.append(server)
        time.sleep(0.2)
        listen = self.port()
        self.add_pf(listen, 39001, engine="nftables", addr="10.78.0.2")
        client_code = f'''
import socket
for kind in (socket.SOCK_STREAM,socket.SOCK_DGRAM):
 with socket.socket(socket.AF_INET,kind) as sock:
  sock.settimeout(3)
  sock.connect(("10.77.0.1",{listen}))
  sock.sendall(b"forward-test")
  assert sock.recv(65536)==b"echo:forward-test"
'''
        subprocess.run(peers[0] + [sys.executable, "-c", client_code], check=True, capture_output=True, timeout=10)


for entrance in range(0, 5):
    for use_udp in (False, True):
        def run_traffic(self, choice=entrance, udp=use_udp):
            self.relay_traffic(choice, udp)
        setattr(ForwardingTests, f"test_relay_traffic_{entrance}_{'udp' if use_udp else 'tcp'}", run_traffic)

for landing in ("shadowsocks2022", "vless", "vmess", "trojan", "hysteria2", "tuic", "anytls"):
    for use_udp in (False, True):
        def run_landing(self, destination=landing, udp=use_udp):
            self.relay_traffic(4, udp, destination)
        setattr(ForwardingTests, f"test_outbound_{landing}_{'udp' if use_udp else 'tcp'}", run_landing)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
