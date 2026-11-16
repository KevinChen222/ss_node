#!/usr/bin/env python3
"""Check HTTP-01 directory access with restrictive installation permissions."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
source "$REPO/deploy.sh"
trap - ERR INT TERM
umask 077
ACME_WEBROOT="$WORK/www/acme-challenge"
frontend_mode=haproxy
dns_provider=''
you_domain=acme.example.com
format_cert_domain="$you_domain"
ensure_http_include() { :; }
ipv6_stack_available() { return 1; }
backup_file() { :; }
stage_file_install() { cp "$1" "$WORK/acme.conf"; }
test_and_reload_nginx() { :; }
check_acme_webroot() { :; }
log_success() { :; }
if [ "${FAIL_CHMOD:-0}" = 1 ]; then
    chmod() {
        [ "$1" != a+x ] || return 1
        command chmod "$@"
    }
fi
prepare_acme_webroot
'''


class AcmeWebrootTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-acme-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def prepare(self, fail=False):
        result = subprocess.run(
            ['bash', '-eu', '-o', 'pipefail', '-c', HARNESS],
            env=dict(os.environ, REPO=str(REPO), WORK=str(self.root),
                     FAIL_CHMOD='1' if fail else '0'),
            capture_output=True, text=True, timeout=10)
        if fail:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_accessible(self):
        directory = self.root / 'www'
        for part in ('', 'acme-challenge', 'acme-challenge/.well-known',
                     'acme-challenge/.well-known/acme-challenge'):
            self.assertEqual((directory / part).stat().st_mode & 0o111, 0o111)
        config = (self.root / 'acme.conf').read_text()
        self.assertIn(f'root {directory}/acme-challenge;', config)
        self.assertIn('server_name acme.example.com;', config)

    def test_new_parent_with_private_umask(self):
        self.prepare()
        self.assert_accessible()

    def test_existing_private_parent_and_repeat(self):
        parent = self.root / 'www'
        parent.mkdir(mode=0o700)
        for _ in range(2):
            self.prepare()
            self.assert_accessible()
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o711)

    def test_existing_parent_retains_read_write_permissions(self):
        parent = self.root / 'www'
        parent.mkdir()
        parent.chmod(0o750)
        self.prepare()
        self.assert_accessible()
        self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o751)

    def test_parent_permission_failure_stops_before_configuration(self):
        self.prepare(fail=True)
        self.assertFalse((self.root / 'acme.conf').exists())


if __name__ == '__main__':
    unittest.main()
