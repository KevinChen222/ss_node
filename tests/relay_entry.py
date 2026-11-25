#!/usr/bin/env python3
"""Enter the sing-box relay module through sb: menu entry, cron command and component migration."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]

HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR=$WORK CONFIG_FILE=$WORK/config.json METADATA_FILE=$WORK/metadata.json
CLASH_YAML_FILE=$WORK/clash.yaml PROXYALL_WRITE_LOCK_FILE=$WORK/lock INIT_SYSTEM=direct
PID_FILE=$WORK/sing-box.pid
printf '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}\n' > "$CONFIG_FILE"
printf '{}\n' > "$METADATA_FILE"
curl() { touch "$WORK/network"; return 1; }
wget() { touch "$WORK/network"; return 1; }
'''


class RelayEntryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='proxyall-relay-entry-')
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        # Stub crontab with a plain file so cron edits stay inside the test directory.
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        crontab = self.bin / 'crontab'
        crontab.write_text('#!/bin/bash\nif [ "$1" = -l ]; then cat "$WORK/crontab" 2>/dev/null; exit 0; fi\n'
                           'cat > "$WORK/crontab"\n')
        crontab.chmod(crontab.stat().st_mode | stat.S_IXUSR)

    def shell(self, body, stdin='', ok=True):
        result = subprocess.run(['bash', '-c', HARNESS + body], input=stdin,
                                env=dict(os.environ, REPO=str(REPO), WORK=str(self.work),
                                         PATH=f'{self.bin}:{os.environ["PATH"]}'),
                                capture_output=True, text=True, timeout=60)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.work / 'network').exists(), 'relay entry must not download components')
        return result

    def test_main_menu_17_opens_relay_menu_and_returns(self):
        result = self.shell(r'''
_require_singbox() { return 0; }
_install_yq() { :; }
_main_menu
''', stdin='17\n0\n\n')
        self.assertIn('sing-box 中转与端口转发', result.stdout)
        self.assertIn('落地机：生成全协议 Token', result.stdout)
        self.assertIn('端口转发管理', result.stdout)
        self.assertTrue((self.work / 'relay.json').is_file())
        self.assertTrue((self.work / 'relay_links.json').is_file())
        # Relay functions stay inside the subshell; the main menu keeps its own definitions.
        self.assertNotIn('中转已整合到 Xray', result.stdout + result.stderr)

    def test_relay_menu_ends_on_eof(self):
        self.shell(r'''
_install_yq() { :; }
_advanced_features
if declare -F _relay_menu >/dev/null; then exit 1; fi
''')

    def test_relay_module_uses_bundled_parser_and_singbox_service(self):
        result = self.shell(r'''
_relay_command bash -c 'exit 0'
_relay_command eval '_check_parser && printf "%s\n" "$_PARSER_PATH"'
_relay_command eval 'declare -f _relay_service' | grep -Fq _manage_singbox_service_impl
''')
        self.assertEqual(result.stdout.strip().splitlines()[-1], str(REPO / 'lib/parser.sh'))

    def test_executing_relay_module_directly_points_to_sb(self):
        result = subprocess.run(['bash', str(REPO / 'lib/relay.sh')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('sb', result.stderr)

    def test_dns_refresh_cron_runs_through_sb(self):
        self.shell(r'''
_relay_command _pf_setup_dns_cron
grep -Fx "* * * * * /bin/bash \"$SELF_SCRIPT_PATH\" pf-dns-refresh >/dev/null 2>&1 # pf-dns-auto-refresh" "$WORK/crontab"
''')

    def test_legacy_component_copies_and_cron_are_migrated(self):
        (self.work / 'crontab').write_text(
            '*/15 * * * * bash /usr/local/bin/sb cleanup-logs >/dev/null 2>&1 # sing-box-log-cleanup\n'
            f'* * * * * /bin/bash "{self.work}/advanced_relay.sh" pf-dns-refresh >/dev/null 2>&1 # pf-dns-auto-refresh\n')
        for name in ('advanced_relay.sh', 'parser.sh'):
            (self.work / name).write_text('old component\n')
        self.shell('_migrate_legacy_relay_component')
        lines = (self.work / 'crontab').read_text().splitlines()
        self.assertIn('*/15 * * * * bash /usr/local/bin/sb cleanup-logs >/dev/null 2>&1 # sing-box-log-cleanup', lines)
        self.assertIn(f'* * * * * /bin/bash "{REPO / "sb.sh"}" pf-dns-refresh >/dev/null 2>&1 # pf-dns-auto-refresh', lines)
        self.assertEqual(len(lines), 2)
        self.assertFalse((self.work / 'advanced_relay.sh').exists())
        self.assertFalse((self.work / 'parser.sh').exists())


if __name__ == '__main__':
    unittest.main()
