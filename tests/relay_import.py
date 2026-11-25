#!/usr/bin/env python3
"""Exercise relay link import offline without running finalization."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
LINK = 'socks5://example.test:1080'
OUTBOUND = {'type': 'socks', 'server': 'example.test', 'server_port': 1080,
            'version': '5', 'tag': 'proxy'}


class RelayImportTests(unittest.TestCase):
    def run_import(self, link=LINK, *, output=None, status=0, answer=''):
        with tempfile.TemporaryDirectory(prefix='proxyall-relay-import-') as work:
            root = Path(work)
            parser = REPO / 'lib/parser.sh'
            env = os.environ.copy()
            if output is not None:
                parser = root / 'parser.sh'
                parser.write_text('printf "%s" "$TEST_PARSER_OUTPUT"\nexit "$TEST_PARSER_STATUS"\n')
                env.update(TEST_PARSER_OUTPUT=output, TEST_PARSER_STATUS=str(status))
            marker = root / 'finalize.args'
            result = subprocess.run(['bash', '-c', r'''
source "${1%/lib/relay.sh}/sb.sh" && source "$1" || exit 99
test_parser="$2"
finalize_marker="$3"
_check_parser() { _PARSER_PATH="$test_parser"; }
_finalize_relay_setup() { printf '%s\0' "$@" >> "$finalize_marker"; }
_import_link_config_locked
''', 'test', str(REPO / 'lib/relay.sh'), str(parser), str(marker)],
                cwd=root, env=env, input=f'{link}\n{answer}', text=True,
                capture_output=True, timeout=10)
            finalized = marker.read_bytes().decode().split('\0')[:-1] if marker.exists() else None
            return result, finalized

    def assert_rejected(self, result, finalized, message='链接解析失败'):
        self.assertIsNone(finalized)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)

    def test_nonzero_exit_with_valid_output_is_rejected(self):
        self.assert_rejected(*self.run_import(output=json.dumps(OUTBOUND), status=1))

    def test_real_parser_error_is_reported(self):
        self.assert_rejected(*self.run_import('invalid-link'), '节点链接格式错误或协议不支持')

    def test_invalid_output_with_zero_exit_is_rejected(self):
        valid = json.dumps(OUTBOUND)
        for output in ('', '  ', '{broken', 'null', '[]', 'false', '{}',
                       '{"error":"parser diagnostic"}',
                       json.dumps(dict(OUTBOUND, error=False)),
                       json.dumps(dict(OUTBOUND, type='')),
                       json.dumps(dict(OUTBOUND, server=None)),
                       json.dumps(dict(OUTBOUND, server_port='1080')),
                       json.dumps(dict(OUTBOUND, server_port=0)),
                       json.dumps(dict(OUTBOUND, server_port=65536)),
                       json.dumps(dict(OUTBOUND, server_port=1080.5)),
                       valid + '\n{}', valid + '\ntrailing text'):
            with self.subTest(output=output):
                self.assert_rejected(*self.run_import(output=output))

    def test_valid_output_reaches_finalize(self):
        result, finalized = self.run_import()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(finalized)
        self.assertEqual(len(finalized), 4)
        self.assertEqual(finalized[:3], ['socks', 'example.test', '1080'])
        self.assertEqual(json.loads(finalized[3]), dict(OUTBOUND, tag='TEMP_TAG'))

    def test_ss2022_still_requires_confirmation(self):
        link = 'ss://2022-blake3-aes-128-gcm:secret@example.test:8388'
        for answer in ('n\n', 'y\n'):
            with self.subTest(answer=answer):
                result, finalized = self.run_import(link, answer=answer)
                self.assertIn('Shadowsocks-2022', result.stderr)
                if answer == 'y\n':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIsNotNone(finalized)
                else:
                    self.assertIsNone(finalized)


if __name__ == '__main__':
    unittest.main()
