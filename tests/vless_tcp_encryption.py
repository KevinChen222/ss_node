#!/usr/bin/env python3
"""VLESS TCP ENC exports, edits and mihomo dialer-proxy traffic."""
import json
import os
import subprocess
import unittest
from urllib.parse import parse_qs, urlsplit

import node_edit
import xhttp


@unittest.skipUnless(all(xhttp.TOOLS.values()) and os.environ.get('TEST_SUBSTORE'),
                     'set TEST_XRAY, TEST_MIHOMO, TEST_NGINX, TEST_YQ, TEST_SUBSTORE')
class TCPEncryption(unittest.TestCase):
    setUp = node_edit.NodeEdit.setUp
    edit = node_edit.NodeEdit.edit
    data = node_edit.NodeEdit.data
    assert_export = node_edit.NodeEdit.assert_export
    snapshot = node_edit.NodeEdit.snapshot

    def add(self, choice=''):
        public = xhttp.port()
        self.fixture.run_shell('native', f'1\n127.0.0.1\n{public}\nLanding\n{choice}\n')
        return public

    def request(self, proxy, front=None, reject=False):
        mixed = xhttp.port()
        proxy = dict(proxy)
        proxies = [proxy]
        if front:
            proxy['dialer-proxy'] = front['name']
            proxies.append(front)
        cfg = self.root/f'client-{mixed}.json'
        cfg.write_text(json.dumps({'mixed-port':mixed,'proxies':proxies,'rules':['MATCH,'+proxy['name']]}))
        self.fixture.start([xhttp.TOOLS['mihomo'], '-d', str(self.root/f'client-{mixed}'), '-f', str(cfg)], mixed,
                           dict(os.environ, SSL_CERT_FILE=str(self.root/'certs/xhttp.test/cert')))
        response = subprocess.run(['curl','-fsS','--max-time','4','--noproxy','','-x',f'http://127.0.0.1:{mixed}',
                                   f'http://127.0.0.1:{self.fixture.webport}/'],capture_output=True)
        if reject:
            self.assertNotEqual(response.returncode, 0)
        else:
            self.assertEqual(response.stdout, b'website', (response.stderr, (self.root/'xray.log').read_text()[-1000:]))
            self.fixture.check_udp(mixed)

    def check_export(self, enabled):
        self.assert_export()
        meta, inbound, client = self.data()
        q = parse_qs(urlsplit(meta['share_link']).query)
        self.assertEqual(q['security'], ['none'])
        self.assertEqual(q['type'], ['tcp'])
        self.assertEqual(q['encryption'], [client['encryption']])
        self.assertEqual(inbound['streamSettings'], {'network':'raw','security':'none'})
        self.assertEqual(client['encryption'] != 'none', enabled)
        self.assertEqual(inbound['settings']['decryption'] != 'none', enabled)
        self.assertFalse(client.get('tls', False))
        self.assertNotIn('reality-opts', client)
        self.assertNotIn('sni', q)
        self.assertNotIn('support-x25519mlkem768', q)
        if enabled:
            self.assertNotIn(inbound['settings']['decryption'].rsplit('.',1)[-1], meta['share_link'])
        outbound = json.loads(subprocess.check_output(['bash','-c','source "$REPO/sb.sh"; _xray_link_outbound "$LINK"'],
                             env=dict(self.fixture.env, LINK=meta['share_link'])))
        self.assertEqual(outbound['settings']['vnext'][0]['users'][0]['encryption'], client['encryption'])
        return self.fixture.exported(meta['share_link'])

    def test_default_and_edit_lifecycle(self):
        self.add()
        meta, inbound, client = self.data()
        uuid = client['uuid']
        self.assertGreater(len(client['encryption']), 1000)
        self.request(self.check_export(True))
        for choice in ('2','3','1'):
            with self.subTest(choice=choice):
                self.edit('enc', f'{choice}\ny\n')
                proxy = self.check_export(choice != '3')
                self.assertEqual(proxy['uuid'], uuid)
                self.request(proxy)
                if choice != '3':
                    self.request(dict(proxy,encryption='none'), reject=True)
        before = self.snapshot()
        self.edit('enc', '1\n')
        self.assertEqual(self.snapshot(), before)
        self.fixture.run_shell('edit-menu', '1\n5\n0\n0\n0\n', check=False)
        self.assertEqual(self.snapshot(), before)
        self.edit('port', f'{xhttp.port()}\ny\n')
        self.edit('name', 'Landing 中文\ny\n')
        self.edit('server', '::1\ny\n')
        self.request(self.check_export(True))
        self.fixture.run_shell('delete', '1\ny\n')
        self.assertEqual(self.fixture.json('metadata.json'), {})

    def test_creation_choices_and_existing_plain_node_upgrade(self):
        for choice in ('2','3'):
            with self.subTest(choice=choice):
                self.add(choice)
                self.request(self.check_export(choice != '3'))
                if choice == '3':
                    # Older TCP nodes had no encryption property in their client YAML.
                    subprocess.run([xhttp.TOOLS['yq'], '-i', 'del(.proxies[0].encryption)', str(self.root/'clash.yaml')], check=True)
                    self.edit('enc', '1\ny\n')
                    self.request(self.check_export(True))
                self.fixture.run_shell('delete', '1\ny\n')

    def test_mihomo_chain_through_three_fronts(self):
        landing_port = self.add()
        landing_tag = next(iter(self.fixture.json('metadata.json')))
        landing = self.fixture.exported(self.data()[0]['share_link'])
        for kind in ('tls','reality','vision'):
            with self.subTest(front=kind):
                public = xhttp.port()
                if kind == 'tls':
                    self.fixture.public = public
                    self.fixture.add(name='Front TLS')
                elif kind == 'reality':
                    self.fixture.run_shell('reality', f'\ny\n1\nxhttp.test\n{public}\n/front/\nFront Reality\n1\n\n')
                else:
                    self.fixture.run_shell('vision', PORT=str(public), ORIGIN=self.fixture.env['ORIGIN_PORT'], PROFILE='mlkem768')
                tag, meta = next((t,m) for t,m in self.fixture.json('metadata.json').items() if m['publicPort']==public)
                front = self.fixture.exported(meta['share_link'])
                offset = len((self.root/'xray.log').read_text())
                self.request(landing, front)
                log = (self.root/'xray.log').read_text()[offset:]
                self.assertIn(f'[{tag} >> direct]', log)
                self.assertIn(f'[{landing_tag} >> direct]', log)
                self.assertEqual(landing['port'], landing_port)


if __name__ == '__main__':
    unittest.main()
