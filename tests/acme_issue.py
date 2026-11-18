#!/usr/bin/env python3
"""Check ACME issuance decisions without network or service changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
DOMAIN = 'acme.example.com'
HARNESS = r'''
source "$REPO/deploy.sh"
trap - ERR INT TERM
ACME_SH="$WORK/acme.sh"
ACME_WEBROOT="$WORK/webroot"
frontend_mode="$TEST_FRONTEND"
dns_provider="$TEST_DNS"
no_tls="$TEST_NO_TLS"
you_domain=acme.example.com
format_cert_domain="$you_domain"
install_acme() { :; }
nginx_is_running() { return 0; }
start_nginx() { return 1; }
mock_sudo() { [[ $# == 3 && $1 == mkdir && $2 == -p && $3 == "/etc/nginx/certs/$you_domain" ]]; }
SUDO=mock_sudo
issue_certificate
'''
ACME_STUB = r'''#!/usr/bin/env bash
printf '%s\t' "$@" >> "$WORK/calls"
printf '\n' >> "$WORK/calls"
if [[ $1 == --info ]]; then
    cat "$WORK/info"
    exit "$TEST_INFO_STATUS"
fi
'''


class AcmeIssueTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='proxyall-acme-issue-')
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name)
        self.cert = self.work / 'full chain.cer'
        self.cert.write_text('existing certificate')
        stub = self.work / 'acme.sh'
        stub.write_text(ACME_STUB)
        stub.chmod(0o700)
        self.install = ['--install-cert', '-d', DOMAIN, '--ecc', '--fullchain-file',
                        f'/etc/nginx/certs/{DOMAIN}/cert', '--key-file',
                        f'/etc/nginx/certs/{DOMAIN}/key', '--reloadcmd']

    def run_issue(self, *fields, frontend='haproxy', dns='', no_tls='no', info_status=0):
        (self.work / 'info').write_text('\n'.join(fields))
        calls = self.work / 'calls'
        calls.unlink(missing_ok=True)
        result = subprocess.run(
            ['bash', '-c', HARNESS], capture_output=True, text=True, timeout=10,
            env=dict(os.environ, REPO=str(REPO), WORK=str(self.work), TEST_FRONTEND=frontend,
                     TEST_DNS=dns, TEST_NO_TLS=no_tls, TEST_INFO_STATUS=str(info_status)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        if not calls.exists():
            return []
        return [line.rstrip('\t').split('\t') for line in calls.read_text().splitlines()]

    def assert_issuance(self, calls, *operations):
        self.assertEqual(calls[0], ['--info', '-d', DOMAIN, '--ecc'])
        self.assertEqual([call[0] for call in calls], ['--info', *operations, '--install-cert'])
        self.assertEqual(calls[-1][:-1], self.install)

    def test_reuses_webroot_certificate_from_first_fields(self):
        calls = self.run_issue(f"Le_RealFullChainPath='{self.cert}'",
                               f"Le_Webroot='{self.work}/webroot'",
                               'Le_RealFullChainPath=/missing', 'Le_Webroot=no')
        self.assert_issuance(calls)

    def test_migrates_existing_certificate_to_webroot(self):
        calls = self.run_issue(f'Le_RealFullChainPath={self.cert}', 'Le_Webroot=no')
        self.assert_issuance(calls, '--issue')
        self.assertEqual(calls[1], ['--issue', '--webroot', str(self.work / 'webroot'),
                                    '-d', DOMAIN, '--keylength', 'ec-256', '--force'])

    def test_reuses_standalone_certificate_with_both_hooks(self):
        calls = self.run_issue(f"Le_RealFullChainPath='{self.cert}'", 'Le_PreHook=stop',
                               'Le_PostHook=start', frontend='direct')
        self.assert_issuance(calls)

    def test_migrates_standalone_certificate_with_incomplete_hooks(self):
        for hook in ('Le_PreHook=stop', 'Le_PostHook=start'):
            with self.subTest(hook=hook):
                calls = self.run_issue(f"Le_RealFullChainPath='{self.cert}'", hook, frontend='direct')
                self.assert_issuance(calls, '--issue')
                issue = calls[1]
                self.assertEqual(issue[:6], ['--issue', '--standalone', '-d', DOMAIN, '--keylength', 'ec-256'])
                self.assertEqual(issue[6:-1:2], ['--pre-hook', '--post-hook'])
                self.assertTrue(issue[7] and issue[9])
                self.assertEqual(issue[-1], '--force')

    def test_reuses_dns_certificate_without_http_renewal_settings(self):
        calls = self.run_issue(f"Le_RealFullChainPath='{self.cert}'", dns='test')
        self.assert_issuance(calls)

    def test_recovers_from_missing_certificate_or_failed_query(self):
        for fields, status in ((('Le_RealFullChainPath=/missing',), 0), ((), 1)):
            with self.subTest(info_status=status):
                calls = self.run_issue(*fields, dns='test', info_status=status)
                self.assert_issuance(calls, '--remove', '--remove', '--issue')
                self.assertEqual(calls[1:4], [
                    ['--remove', '-d', DOMAIN, '--ecc'], ['--remove', '-d', DOMAIN],
                    ['--issue', '--dns', 'dns_test', '-d', DOMAIN, '--keylength', 'ec-256', '--force'],
                ])

    def test_skips_acme_without_tls(self):
        self.assertEqual(self.run_issue(no_tls='yes'), [])


if __name__ == '__main__':
    unittest.main()
