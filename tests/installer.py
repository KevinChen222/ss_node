#!/usr/bin/env python3
"""Exercise installer checks, bundle hashes and target recognition in temporary directories."""
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
def bundle_libraries():
    text = (REPO / 'proxyall').read_text()
    match = re.search(r'^PA_LIBS=\((.*?)\)', text, re.M | re.S)
    return tuple(f'lib/{name}' for name in match.group(1).split())


def bundle_version():
    text = (REPO / 'proxyall').read_text()
    match = re.search(r'^PROXYALL_VERSION="([^"]+)"', text, re.M)
    return match.group(1)


# Entries first (the three-file legacy bundle), then every library in installer order.
BUNDLE_FILES = ('sb.sh', 'deploy.sh', 'proxyall', *bundle_libraries())
BUNDLE_VERSION = bundle_version()


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
        invalid_cases = (
            ('--install', 'extra'),
            ('--help', 'extra'),
            ('--version', 'extra'),
            ('--update', 'extra'),
            ('--update', '--verbose', 'extra'),
            ('--update', '-v', 'extra'),
        )
        for args in invalid_cases:
            with self.subTest(args=args):
                p = subprocess.run(['bash', str(REPO / 'proxyall'), *args],
                                   capture_output=True, text=True)
                self.assertEqual(p.returncode, 2)
                self.assertIn('参数过多', p.stderr)
                self.assertIn('proxyall --install', p.stderr)

    def test_update_verbose_argument_parsing(self):
        for args, expected in (
            ('--update', 'ask 0'),
            ('--update --verbose', 'ask 1'),
            ('--update -v', 'ask 1'),
        ):
            with self.subTest(args=args):
                res = self.shell(rf'''
pa_dependencies() {{ return 0; }}
pa_prepare_state() {{ return 0; }}
pa_update() {{ printf '%s %s\n' "$1" "${{2:-0}}"; }}
eval "$(declare -f main | sed 's/\[ "\$EUID" = 0 \]/true/')"
main {args}
''')
                self.assertEqual(res.stdout.strip(), expected)

    def _build_tarball(self, archive_path, entries):
        with tarfile.open(archive_path, 'w:gz') as tf:
            for spec in entries:
                kind = spec[0]
                if kind == 'dir':
                    info = tarfile.TarInfo(spec[1])
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    tf.addfile(info)
                elif kind == 'file':
                    data = spec[2]
                    info = tarfile.TarInfo(spec[1])
                    info.type = tarfile.REGTYPE
                    info.mode = spec[3] if len(spec) > 3 else 0o755
                    info.size = len(data)
                    tf.addfile(info, io.BytesIO(data))
                elif kind == 'symlink':
                    info = tarfile.TarInfo(spec[1])
                    info.type = tarfile.SYMTYPE
                    info.linkname = spec[2]
                    tf.addfile(info)
                elif kind == 'hardlink':
                    info = tarfile.TarInfo(spec[1])
                    info.type = tarfile.LNKTYPE
                    info.linkname = spec[2]
                    tf.addfile(info)
                elif kind == 'fifo':
                    info = tarfile.TarInfo(spec[1])
                    info.type = tarfile.FIFOTYPE
                    info.mode = 0o644
                    tf.addfile(info)
                elif kind == 'chr':
                    info = tarfile.TarInfo(spec[1])
                    info.type = tarfile.CHRTYPE
                    info.mode = 0o644
                    info.devmajor = 1
                    info.devminor = 3
                    tf.addfile(info)

    def _valid_tar_entries(self, prefix='ss_node-test'):
        entries = [('dir', f'{prefix}/'), ('dir', f'{prefix}/lib/')]
        for name in BUNDLE_FILES:
            entries.append(('file', f'{prefix}/{name}', (REPO / name).read_bytes()))
        return entries

    def test_extract_tarball_valid_and_busybox_portable(self):
        entries = self._valid_tar_entries() + [('file', 'ss_node-test/README.md', b'extra\n', 0o644)]
        tar_variants = [('gnu', '')]
        if shutil.which('busybox'):
            tar_variants.append(('busybox', 'tar() { busybox tar "$@"; }\n'))
        for label, wrapper in tar_variants:
            with self.subTest(tar=label):
                stage = self.root / f'stage-{label}'
                stage.mkdir(mode=0o700)
                archive = stage / 'bundle.tar.gz'
                self._build_tarball(archive, entries)
                self.shell(wrapper + f'pa_extract_tarball "{archive}" "{stage}" && pa_validate_bundle "{stage}"')
                self.assertFalse((stage / 'extract').exists())
                self.assertFalse(archive.exists())
                self.assertFalse((stage / 'README.md').exists())
                for name in BUNDLE_FILES:
                    extracted = stage / name
                    self.assertEqual(extracted.read_bytes(), (REPO / name).read_bytes())
                    self.assertEqual(extracted.stat().st_mode & 0o777, 0o600)

    def test_extract_tarball_rejects_malicious_archives(self):
        base = self._valid_tar_entries()
        host_secret = self.root / 'secret ss_node-test'
        host_secret.mkdir(mode=0o700)
        secret_file = host_secret / 'sb.sh'
        secret_file.write_text('# host secret\n')

        def replace_entry(entries, target, replacement):
            return [replacement if e[1].rstrip('/') == target.rstrip('/') else e for e in entries]

        cases = {
            'symlink_member': replace_entry(base, 'ss_node-test/sb.sh', ('symlink', 'ss_node-test/sb.sh', '/etc/passwd')),
            'symlink_lib_dir': replace_entry(base, 'ss_node-test/lib', ('symlink', 'ss_node-test/lib', '/tmp')),
            'symlink_root_dir': replace_entry(base, 'ss_node-test', ('symlink', 'ss_node-test', '/tmp')),
            'hardlink_member': replace_entry(base, 'ss_node-test/sb.sh', ('hardlink', 'ss_node-test/sb.sh', 'ss_node-test/deploy.sh')),
            'hardlink_spoofed_suffix': replace_entry(base, 'ss_node-test/sb.sh', ('hardlink', 'ss_node-test/sb.sh', str(secret_file))),
            'hardlink_fake_timestamp': replace_entry(base, 'ss_node-test/sb.sh', ('hardlink', 'ss_node-test/sb.sh', '2026-01-01 00:00 ss_node-test/sb.sh')),
            'fifo_member': replace_entry(base, 'ss_node-test/sb.sh', ('fifo', 'ss_node-test/sb.sh')),
            'chr_member': replace_entry(base, 'ss_node-test/sb.sh', ('chr', 'ss_node-test/sb.sh')),
            'hyphen_root': self._valid_tar_entries(prefix='-C'),
            'dot_root': self._valid_tar_entries(prefix='.hidden'),
            'dotdot_traversal_nested': base + [('file', 'ss_node-test/../evil.sh', b'evil\n')],
            'dotdot_traversal_top': base + [('file', '../evil.sh', b'evil\n')],
            'absolute_path': base + [('file', '/tmp/evil.sh', b'evil\n')],
            'missing_member': [e for e in base if e[1] != 'ss_node-test/lib/parser.sh'],
            'duplicate_entry': base + [('file', 'ss_node-test/sb.sh', (REPO / 'sb.sh').read_bytes())],
            'multiple_roots': base + [('file', 'other-root/extra.sh', b'x\n')],
        }
        tar_variants = [('gnu', '')]
        if shutil.which('busybox'):
            tar_variants.append(('busybox', 'tar() { busybox tar "$@"; }\n'))
        for label, entries in cases.items():
            archive = self.root / f'bad-{label}.tar.gz'
            self._build_tarball(archive, entries)
            for tar_label, wrapper in tar_variants:
                with self.subTest(case=label, tar=tar_label):
                    stage = self.root / f'bad-{label}-{tar_label}'
                    stage.mkdir(mode=0o700)
                    self.shell(wrapper + f'pa_extract_tarball "{archive}" "{stage}"', ok=False)
                    self.assertFalse((stage / 'extract').exists())
                    self.assertFalse((stage / 'sb.sh').exists())

        with self.subTest(case='corrupt_archive'):
            stage = self.root / 'bad-corrupt'
            stage.mkdir(mode=0o700)
            archive = stage / 'bundle.tar.gz'
            archive.write_text('<html>502 Bad Gateway</html>\n')
            self.shell(f'pa_extract_tarball "{archive}" "{stage}"', ok=False)
            self.assertFalse((stage / 'extract').exists())

    def test_version_of_helper(self):
        res = self.shell('pa_version_of "$REPO/proxyall"')
        self.assertEqual(res.stdout.strip(), BUNDLE_VERSION)
        bad = self.root / 'bad-ver'
        bad.write_text('PROXYALL_VERSION="1.0.0"\nPROXYALL_VERSION="2.0.0"\n')
        self.shell('pa_version_of "$WORK/bad-ver"', ok=False)

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
        for name in ('common.sh', 'sni_router.sh', 'sb_core.sh', 'relay.sh', 'parser.sh'):
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

    def test_refresh_component_pins(self):
        tool = self.root / 'tools/component_pins.py'
        tool.parent.mkdir()
        shutil.copyfile(REPO / 'tools/component_pins.py', tool)
        copy_files(REPO, self.root, BUNDLE_FILES)
        cmd = [sys.executable, tool]
        subprocess.run(cmd, check=True)
        for name in ('sb.sh', 'lib/common.sh', 'lib/sb_proto_quic.sh', 'lib/parser.sh'):
            with self.subTest(name=name):
                with (self.root / name).open('a') as changed:
                    changed.write('\n# fixture\n')
                self.shell('pa_validate_bundle "$WORK"', ok=False)
                check = subprocess.run(cmd, capture_output=True, text=True)
                self.assertEqual(check.returncode, 1)
                self.assertEqual(check.stdout.splitlines(), ['proxyall'])
                subprocess.run(cmd + ['--write'], check=True, capture_output=True)
                subprocess.run(cmd, check=True)
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
        for name in ('sb.sh', 'deploy.sh', *BUNDLE_FILES[2:]):
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


if __name__ == '__main__':
    unittest.main()
