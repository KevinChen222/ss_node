#!/usr/bin/env python3
"""VLESS ENC generation, export and port-change checks with real Xray keys."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

from xhttp_xmux import HARNESS
from xhttp_reality import REALITY_HARNESS

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('TEST_XRAY'), 'set TEST_XRAY for real ENC key generation')
class EncryptionTests(unittest.TestCase):
    def shell(self, root, action, answers='', check=True):
        env = dict(os.environ, WORK=str(root), REPO=str(REPO), ACTION=action,
                   TEST_REALITY_KEYGEN=os.environ['TEST_XRAY'])
        result = subprocess.run(['bash', str(root/'harness')], input=answers, text=True,
                                capture_output=True, env=env, timeout=15)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def prepare(self, root, reality):
        (root/'conf.d').mkdir()
        (root/'metadata.json').write_text('{}')
        (root/'xray.json').write_text('{"inbounds":[]}')
        (root/'router.json').write_text('{"reality":null}')
        harness = REALITY_HARNESS if reality else HARNESS
        harness = harness.replace(
            'server_ip=203.0.113.1',
            'server_ip=203.0.113.1\nCONFIG_FILE="$WORK/config.json"\nARGO_METADATA_FILE="$WORK/argo.json"\nXRAY_BIN="$TEST_XRAY"\n_find_proxy_name() { echo "XHTTP test"; }',
        )
        harness = harness.replace('case "$ACTION" in', 'case "$ACTION" in\n    view) _view_nodes <<< y ;;')
        (root/'harness').write_text(harness)

    def test_profiles_survive_exports_and_port_changes(self):
        for reality in (False, True):
            for choice in ('', '2', '3'):
                with self.subTest(reality=reality, choice=choice), tempfile.TemporaryDirectory() as work:
                    root = Path(work)
                    self.prepare(root, reality)
                    prefix = '\n8444\n' if reality else '\nxhttp.test\n8443\n'
                    self.shell(root, 'add', prefix+'/test/\nXHTTP test\n4\n'+choice+'\n')
                    server = json.loads((root/'xray.json').read_text())['inbounds'][0]
                    client = json.loads((root/'client.json').read_text())['proxies'][0]
                    enc = client['encryption']
                    self.assertEqual(enc == 'none', choice == '3')
                    self.assertEqual(server['settings']['decryption'] == 'none', choice == '3')
                    if choice != '3':
                        self.assertTrue(enc.startswith('mlkem768x25519plus.native.0rtt.'))
                        self.assertTrue(server['settings']['decryption'].startswith('mlkem768x25519plus.native.600s.'))
                        key = enc.rsplit('.', 1)[1]
                        self.assertEqual(len(base64.urlsafe_b64decode(key+'===')), 32 if choice == '2' else 1184)
                    subprocess.run([os.environ['TEST_XRAY'], 'run', '-test', '-config', str(root/'xray.json')],
                                   capture_output=True, check=True)
                    for change in (False, True):
                        if change:
                            self.shell(root, 'modify')
                        link = json.loads((root/'metadata.json').read_text())['xhttp-in-test']['share_link']
                        q = parse_qs(urlsplit(link).query)
                        self.assertEqual(q['encryption'], [enc])
                        if reality:
                            self.assertEqual(q['support-x25519mlkem768'], ['true'])
                        else:
                            self.assertNotIn('support-x25519mlkem768', q)
                        if choice != '3':
                            self.assertNotIn(server['settings']['decryption'].rsplit('.', 1)[1], link)
                        viewed = self.shell(root, 'view').stdout
                        self.assertIn(link, viewed)
                        self.assertIn(base64.b64encode((link + '\n').encode()).decode(), viewed)
                        if os.environ.get('TEST_SUBSTORE'):
                            exported = json.loads(subprocess.check_output(['node', str(REPO/'tests/substore_link.mjs')], input=link, text=True))
                            saved = json.loads((root/'client.json').read_text())['proxies'][0]
                            for key, value in saved.items():
                                self.assertEqual(exported.get(key), value, key)
                            if reality:
                                self.assertIs(exported['reality-opts']['support-x25519mlkem768'], True)
                    self.assertEqual(urlsplit(link).port, 9443)

    def test_invalid_choice_retries_and_eof_does_not_create_node(self):
        for answer in ('bad\n0\n', ''):
            with self.subTest(answer=answer), tempfile.TemporaryDirectory() as work:
                root = Path(work)
                self.prepare(root, False)
                result = self.shell(root, 'add', '\nxhttp.test\n8443\n/test/\nXHTTP test\n1\n'+answer, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads((root/'xray.json').read_text()), {'inbounds': []})
                self.assertEqual(json.loads((root/'metadata.json').read_text()), {})

    def test_existing_node_without_enc_remains_none(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.prepare(root, True)
            self.shell(root, 'add', '\n8444\n/test/\nXHTTP test\n1\n3\n')
            client = json.loads((root/'client.json').read_text())
            del client['proxies'][0]['encryption']
            (root/'client.json').write_text(json.dumps(client))
            self.shell(root, 'modify')
            link = json.loads((root/'metadata.json').read_text())['xhttp-in-test']['share_link']
            self.assertEqual(parse_qs(urlsplit(link).query)['encryption'], ['none'])
            self.assertEqual(json.loads((root/'xray.json').read_text())['inbounds'][0]['settings']['decryption'], 'none')


if __name__ == '__main__':
    unittest.main()
