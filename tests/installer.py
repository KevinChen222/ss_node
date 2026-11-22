#!/usr/bin/env python3
"""Exercise installer checks and component downloads in temporary directories."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BUNDLE_FILES = ('sb.sh', 'deploy.sh', 'proxyall', 'lib/common.sh', 'lib/sni_router.sh')


def copy_files(source, target, names):
    for name in names:
        path = target / name
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(source / name, path)
        path.chmod(0o644)


HARNESS = r'''
source "$REPO/proxyall"
# Model trusted system ancestors around the temporary fixture.
stat() {
    if [ "$1" = -Lc ] && { [ "$4" = / ] || [ "$4" = /tmp ]; }; then
        printf '0 755\n'
    else
        command stat "$@"
    fi
}
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-installer-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def shell(self, body, ok=True):
        result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c',
                                 HARNESS + body],
                                env=dict(os.environ, REPO=str(REPO), WORK=str(self.root)),
                                capture_output=True, text=True, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_extra_arguments_report_usage(self):
        for action in ('--install', '--help', '--version'):
            p = subprocess.run(['bash', str(REPO / 'proxyall'), action, 'extra'],
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 2)
            self.assertIn('参数过多', p.stderr)
            self.assertIn('proxyall --install', p.stderr)

    def test_source_and_process_substitution(self):
        result = self.shell('source "$REPO/proxyall"')
        self.assertEqual(result.stdout + result.stderr, '')
        result = self.shell('bash <(cat "$REPO/proxyall") --help')
        self.assertIn('proxyall --install', result.stdout)

    def test_bundle_hashes(self):
        copy_files(REPO, self.root, BUNDLE_FILES)
        self.shell('pa_validate_bundle "$WORK"')
        subprocess.run([sys.executable, REPO / 'tools/component_pins.py'], check=True)

    def test_bundle_rejects_untrusted_library_sources(self):
        copy_files(REPO, self.root, BUNDLE_FILES)
        lib = self.root / 'lib'
        for name in ('common.sh', 'sni_router.sh'):
            with self.subTest(name=name):
                path = lib / name
                original = path.read_bytes()
                path.write_bytes(original + b'\n# changed\n')
                self.shell('pa_validate_bundle "$WORK"', ok=False)
                path.write_bytes(original)
                path.chmod(0o666)
                self.shell('pa_validate_bundle "$WORK"', ok=False)
                path.unlink()
                path.symlink_to(REPO / 'lib' / name)
                self.shell('pa_validate_bundle "$WORK"', ok=False)
                path.unlink()
                path.write_bytes(original)
        lib.rename(self.root / 'saved-lib')
        lib.symlink_to(self.root / 'saved-lib')
        self.shell('pa_validate_bundle "$WORK"', ok=False)

    def test_refresh_transitive_component_pins(self):
        tool = self.root / 'tools/component_pins.py'
        tool.parent.mkdir()
        shutil.copyfile(REPO / 'tools/component_pins.py', tool)
        copy_files(REPO, self.root, (*BUNDLE_FILES, 'advanced_relay.sh', 'parser.sh'))
        with (self.root / 'parser.sh').open('a') as parser:
            parser.write('\n# fixture\n')
        cmd = [sys.executable, tool]
        check = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(check.returncode, 1)
        self.assertEqual(check.stdout.splitlines(), ['advanced_relay.sh', 'sb.sh', 'proxyall'])
        subprocess.run(cmd + ['--write'], check=True, capture_output=True)
        subprocess.run(cmd, check=True)
        self.shell('pa_validate_bundle "$WORK"')
        for name in ('lib/common.sh', 'lib/sni_router.sh'):
            with (self.root / name).open('a') as library:
                library.write('\n# fixture\n')
            check = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(check.returncode, 1)
            self.assertEqual(check.stdout.splitlines(), ['proxyall'])
            subprocess.run(cmd + ['--write'], check=True, capture_output=True)
            self.shell('pa_validate_bundle "$WORK"')

    def test_unmarked_scripts_recognized_without_execution(self):
        for name, marker in (('sb.sh', '# SB_MANAGER_MANAGED_COMMAND=1'),
                             ('deploy.sh', '# NGINXPROXY_MANAGED_COMMAND=1')):
            text = subprocess.check_output(['git', 'show', f'52431e5:{name}'], cwd=REPO, text=True)
            text = text.replace(marker + '\n', '')
            target = self.root / name
            target.write_text('touch "$WORK/executed"\n' + text)
            target.chmod(0o644)
            self.shell(f'pa_known_target "$WORK/{name}" {name}')
            self.assertFalse((self.root / 'executed').exists())
            target.write_text(text.replace('_main_menu()', '_other_menu()') if name == 'sb.sh'
                              else text.replace('generate_nginx_config()', 'other_config()'))
            self.shell(f'pa_known_target "$WORK/{name}" {name}', ok=False)
            target.write_text('not a shell script (')
            self.shell(f'pa_known_target "$WORK/{name}" {name}', ok=False)

    def test_unknown_files_and_target_symlinks_rejected(self):
        target = self.root / 'custom'
        target.write_text('#!/bin/bash\necho custom\n')
        (self.root / 'link').symlink_to(target)
        for name in ('sb.sh', 'deploy.sh', 'parser.sh', 'advanced_relay.sh', *BUNDLE_FILES[-2:]):
            self.shell(f'pa_known_target "$WORK/custom" {name}', ok=False)
            self.shell(f'pa_known_target "$WORK/link" {name}', ok=False)

    def test_safe_symlink_ancestor_and_atomic_install(self):
        self.shell(r'''
mkdir -p "$WORK/physical/local/bin" "$WORK/logical"
ln -s "$WORK/physical/local" "$WORK/logical/local"
pa_safe_directory "$WORK/logical/local/bin"
pa_safe_directory "$WORK/logical/local/etc/missing"
printf original > "$WORK/physical/local/bin/sb"
printf replacement > "$WORK/source"
pa_atomic_install "$WORK/source" "$WORK/logical/local/bin/sb"
test "$(cat "$WORK/physical/local/bin/sb")" = replacement
''')

    def test_unsafe_directory_links_rejected(self):
        physical = self.root / 'physical'
        physical.mkdir()
        (self.root / 'local').symlink_to(physical)
        self.shell('pa_safe_directory "$WORK/local"', ok=False)
        physical.chmod(0o777)
        self.shell('pa_safe_directory "$WORK/local/bin"', ok=False)
        physical.chmod(0o700)
        physical.rmdir()
        self.shell('pa_safe_directory "$WORK/local/bin"', ok=False)
        physical.write_text('file')
        self.shell('pa_safe_directory "$WORK/local/bin"', ok=False)

    def test_untrusted_plain_parent_and_state_slots_rejected(self):
        state = self.root / 'state'
        state.mkdir(mode=0o700)
        (state / '.managed').write_text('# PROXYALL_MANAGED_COMMAND=1\n')
        (state / '.managed').chmod(0o600)
        user_file = self.root / 'user-data'
        user_file.write_text('user data')
        for name in ('manager.lock', 'commit', '.managed'):
            slot = state / name
            slot.unlink(missing_ok=True)
            slot.symlink_to(user_file)
            self.shell('PA_STATE="$WORK/state"; pa_prepare_state', ok=False)
            self.assertEqual(user_file.read_text(), 'user data')
            slot.unlink()
        state.chmod(0o777)
        self.shell('pa_safe_directory "$WORK/state/ordinary/missing"', ok=False)

    def test_indirect_symlink_checks_each_target_directory(self):
        self.shell(r'''
mkdir -p "$WORK/safe/bin" "$WORK/writable"
ln -s "$WORK/safe" "$WORK/writable/hop"
ln -s "$WORK/writable/hop" "$WORK/local"
pa_safe_directory "$WORK/local/bin"
chmod 777 "$WORK/writable"
if pa_safe_directory "$WORK/local/bin"; then exit 1; fi
''')

    def test_curl_component_download_and_integrity(self):
        for mode in ('success', 'download-failure', 'bad-hash'):
            with self.subTest(mode=mode):
                self.shell(f'MODE={mode}\n' + r'''
source "$REPO/sb.sh"
SINGBOX_DIR="$WORK/components"
mkdir -p "$SINGBOX_DIR"
printf existing > "$SINGBOX_DIR/parser.sh"
_info() { :; }
_error() { :; }
wget() { echo unexpected-wget >&2; return 99; }
curl() {
    printf '%s\n' "$*" > "$WORK/curl.args"
    [ "$MODE" != download-failure ] || return 1
    local output
    while [ "$#" -gt 0 ]; do output="$1"; shift; done
    if [ "$MODE" = bad-hash ]; then printf corrupted > "$output"
    else cp "$REPO/parser.sh" "$output"; fi
}
if [ "$MODE" = success ]; then
    _ensure_component_script parser.sh
    cmp "$SINGBOX_DIR/parser.sh" "$REPO/parser.sh"
    curl() { return 99; }
    _ensure_component_script parser.sh
else
    if _ensure_component_script parser.sh; then exit 1; fi
    test "$(cat "$SINGBOX_DIR/parser.sh")" = existing
    test ! -e "$SINGBOX_DIR/parser.sh.tmp.$$"
fi
''')


if __name__ == '__main__':
    unittest.main()
