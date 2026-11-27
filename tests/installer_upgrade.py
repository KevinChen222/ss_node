#!/usr/bin/env python3
"""Run the 52431e5 updater and the current menu in an isolated installation root."""
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

from installer import BUNDLE_FILES, BUNDLE_VERSION, REPO, copy_files

LEGACY = '52431e518f6b1941f4f6aab577d0c9331afa1543'
STAGE_ONE = '1' * 40
STAGE_TWO = '2' * 40
RELEASE_221 = 'f0df4826a1229fa1628d0e5dc8a4e177e4b4e98e'
FILES_221 = ('sb.sh', 'deploy.sh', 'lib/common.sh', 'lib/sni_router.sh', 'proxyall')
TARGETS = ('bin/sb', 'bin/nginxproxy', 'bin/proxyall',
           *(f'lib/proxyall/{name[4:]}' for name in BUNDLE_FILES[3:]))
KEYS = ('SB_SHA256', 'DEPLOY_SHA256', None,
        *(name[4:-3].upper() + '_SHA256' for name in BUNDLE_FILES[3:]))
TARGET_OF = dict(zip(BUNDLE_FILES, TARGETS))

MOCK_ENV = r'''
stat() {
    if [ "$1" = -Lc ] && [ "$4" = "$TEMP_PARENT" ]; then
        printf '0 755\n'
    else
        command stat "$@"
    fi
}
curl() {
    local url output
    while [ "$#" -gt 0 ]; do
        case "$1" in
            https://*) url="$1" ;;
            -o) shift; output="$1" ;;
        esac
        shift
    done
    case "$url" in
        https://api.github.com/repos/KevinChen222/ss_node/git/ref/heads/main)
            printf '{"object":{"sha":"%s"}}\n' "$REMOTE_REF" > "$output" ;;
        "https://codeload.github.com/KevinChen222/ss_node/tar.gz/$REMOTE_REF")
            printf 'tar.gz:%s\n' "$REMOTE_REF" >> "$WORK/downloads"
            [ "${FAIL_TARBALL:-}" != 1 ] || return 1
            if [ -n "${TAMPER_TARBALL:-}" ]; then
                cp -- "$TAMPER_TARBALL" "$output"
            else
                local tmp rc
                tmp=$(mktemp -d) || return 1
                cp -a -- "$WORK/remote" "$tmp/ss_node-$REMOTE_REF" &&
                    tar -czf "$output" -C "$tmp" "ss_node-$REMOTE_REF"
                rc=$?
                rm -rf -- "$tmp"
                return "$rc"
            fi ;;
        "https://raw.githubusercontent.com/KevinChen222/ss_node/$REMOTE_REF/"*)
            local name="${url#*"$REMOTE_REF/"}"
            printf '%s\n' "$name" >> "$WORK/downloads"
            [ "${FAIL_DOWNLOAD:-}" != "$name" ] || return 1
            cp -- "$WORK/remote/$name" "$output" ;;
        *) return 1 ;;
    esac
}
mv() {
    local target="${!#}"
    if [ "${INTERRUPT:-}" = "$target" ] && [ ! -e "$WORK/interrupted" ]; then
        [ -s "$WORK/usr/local/lib/proxyall/common.sh" ] || return 1
        cp "$WORK/usr/local/lib/proxyall/common.sh" "$WORK/interrupted"
        kill -TERM "$$"
        return 1
    fi
    command mv "$@"
}
'''

SB_FIXTURE = r'''#!/bin/bash
# SB_MANAGER_MANAGED_COMMAND=1
[ "${PROXYALL_MANAGED:-}" = 1 ] || exit 56
if [ /dev/fd/8 -ef "$WORK/state/manager.lock" ]; then exit 57; fi
if [ "$1" = setup-maintenance ]; then
    if [ -s "$WORK/usr/local/lib/proxyall/common.sh" ] && [ -s "$WORK/usr/local/lib/proxyall/sni_router.sh" ]; then
        printf 'maintenance with libraries\n' >> "$WORK/components"
        [ "${FAIL_MAINTENANCE:-}" != 1 ]
    else
        printf 'maintenance deferred\n' >> "$WORK/components"
    fi
else
    printf 'sb menu\n' >> "$WORK/components"
fi
'''

DEPLOY_FIXTURE = r'''#!/bin/bash
# NGINXPROXY_MANAGED_COMMAND=1
[ "${PROXYALL_MANAGED:-}" = 1 ] || exit 56
if [ /dev/fd/8 -ef "$WORK/state/manager.lock" ]; then exit 57; fi
printf 'nginxproxy %s\n' "$*" >> "$WORK/components"
'''


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='proxyall-upgrade-test-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.local = self.root / 'usr/local'
        self.state = self.root / 'state'
        self.installer = self.local / TARGETS[2]
        self.remote = self.root / 'remote'
        self.env = self.root / 'mock-env'
        self.env.write_text(MOCK_ENV)
        copy_files(REPO, self.remote, BUNDLE_FILES)
        (self.remote / 'sb.sh').write_text(SB_FIXTURE)
        (self.remote / 'deploy.sh').write_text(DEPLOY_FIXTURE)
        (self.remote / 'proxyall').write_text(self.sandbox((REPO / 'proxyall').read_text()))
        self.refresh_pins()

    def sandbox(self, content):
        # Relocate system paths and bypass only the root check so the identical
        # updater flow, including both exec calls, runs as the test user.
        self.assertEqual(content.count('[ "$EUID" = 0 ]'), 1)
        return (content.replace('[ "$EUID" = 0 ]', 'true')
                .replace('/var/lib/proxyall', str(self.state))
                .replace('/usr/local/', str(self.local) + '/'))

    def refresh_pins(self):
        installer = self.remote / 'proxyall'
        content = installer.read_text()
        for key, name in zip(KEYS, BUNDLE_FILES):
            if key:
                digest = hashlib.sha256((self.remote / name).read_bytes()).hexdigest()
                content, count = re.subn(rf'^{key}="[a-f0-9]{{64}}"$', f'{key}="{digest}"',
                                         content, flags=re.M)
                self.assertEqual(count, 1, key)
        installer.write_text(content)

    def git_file(self, path, revision=LEGACY):
        return subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=REPO)

    def install_legacy_files(self):
        self.installer.parent.mkdir(parents=True)
        for directory in (self.root / 'usr', self.local, self.installer.parent):
            directory.chmod(0o755)
        self.state.mkdir(mode=0o700)
        (self.state / '.managed').write_text('# PROXYALL_MANAGED_COMMAND=1\n')
        (self.state / 'commit').write_text(LEGACY + '\n')
        for name in ('.managed', 'commit'):
            (self.state / name).chmod(0o600)
        for name, target in zip(BUNDLE_FILES[:3], TARGETS[:3]):
            path = self.local / target
            data = self.git_file(name)
            if name == 'proxyall':
                data = self.sandbox(data.decode()).encode()
            path.write_bytes(data)
            path.chmod(0o700)

    def command(self, *args, answer='', ref=STAGE_TWO, status=0, script=None, **overrides):
        p = subprocess.run(['bash', str(script or self.installer), *args], input=answer,
                           env=dict(os.environ, WORK=str(self.root), BASH_ENV=str(self.env),
                                    TEMP_PARENT=str(self.root.parent), REMOTE_REF=ref, **overrides),
                           capture_output=True, text=True, timeout=20)
        self.assertEqual(p.returncode, status, p.stdout + p.stderr)
        self.assertFalse(list(self.state.glob('stage.*')))
        if (self.state / 'manager.lock').exists():
            subprocess.run(['flock', '-n', self.state / 'manager.lock', 'true'], check=True)
        return p

    def downloaded(self):
        path = self.root / 'downloads'
        return path.read_text().splitlines() if path.exists() else []

    def clear_downloads(self):
        (self.root / 'downloads').unlink(missing_ok=True)

    def install_current_bundle(self, ref=STAGE_TWO):
        standalone = self.root / 'standalone-init'
        standalone.write_bytes((self.remote / 'proxyall').read_bytes())
        self.command('--install', script=standalone, answer='0\n', ref=ref)
        self.assert_bundle(ref=ref)
        self.clear_downloads()

    def assert_bundle(self, ref=STAGE_TWO):
        for name, target in zip(BUNDLE_FILES, TARGETS):
            self.assertEqual((self.local / target).read_bytes(), (self.remote / name).read_bytes())
        self.assertEqual((self.state / 'commit').read_text(), ref + '\n')

    def stage_one(self):
        self.install_legacy_files()
        original = {name: (self.local / target).read_bytes()
                    for name, target in zip(BUNDLE_FILES[:3], TARGETS[:3])}
        p = self.command('--update', answer='y\n1\n0\n', ref=STAGE_ONE)
        self.assertIn('3) 检查脚本更新', p.stdout)
        self.assertNotIn('1) Emby', p.stdout)
        self.assertIn('配套库缺失或版本不匹配', p.stderr)
        self.assertEqual(self.downloaded(), list(BUNDLE_FILES[:3]))
        self.assertEqual((self.root / 'components').read_text(), 'maintenance deferred\n')
        self.assertEqual((self.state / 'commit').read_text(), STAGE_ONE + '\n')
        self.assertFalse((self.local / 'lib').exists())
        self.assertEqual(self.installer.read_bytes(), (self.remote / 'proxyall').read_bytes())
        backup, = self.state.glob('backup.*')
        for name, data in original.items():
            self.assertEqual((backup / name).read_bytes(), data)
        return backup, original

    def test_legacy_update_then_menu_update_with_empty_libraries(self):
        backup, _ = self.stage_one()
        p = self.command(answer='3\ny\n1\n2\n0\n', ref=STAGE_ONE)
        self.assertIn('1) Emby', p.stdout)
        self.assertEqual(self.downloaded()[3:], [f'tar.gz:{STAGE_ONE}'])
        self.assert_bundle(ref=STAGE_ONE)
        self.assertEqual(list(self.state.glob('backup.*')), [backup])
        self.assertEqual((self.root / 'components').read_text().splitlines(),
                         ['maintenance deferred', 'maintenance with libraries', 'nginxproxy ', 'sb menu'])

    def test_interrupted_second_stage_preserves_legacy_backup_and_retries(self):
        backup, original = self.stage_one()
        paths = [self.local / target for target in TARGETS[:3]]
        installed = [path.read_bytes() for path in paths]
        p = self.command(answer='3\ny\n', status=143, INTERRUPT=str(self.local / TARGETS[4]))
        self.assertIn('正在恢复', p.stderr)
        self.assertEqual((self.root / 'interrupted').read_bytes(), (self.remote / BUNDLE_FILES[3]).read_bytes())
        self.assertEqual([path.read_bytes() for path in paths], installed)
        self.assertEqual((self.state / 'commit').read_text(), STAGE_ONE + '\n')
        self.assertFalse((self.local / 'lib').exists())
        self.assertFalse(list(self.local.rglob('*.proxyall.*')))
        self.assertEqual(list(self.state.glob('backup.*')), [backup])
        for name, data in original.items():
            self.assertEqual((backup / name).read_bytes(), data)
        self.command(answer='3\ny\n0\n')
        self.assert_bundle()

    def test_mismatched_libraries_gate_menus_and_failed_maintenance_restores_nested_files(self):
        backup, _ = self.stage_one()
        originals = {}
        (self.local / 'lib').mkdir(mode=0o755)
        (self.local / 'lib/proxyall').mkdir(mode=0o755)
        for name, target in zip(BUNDLE_FILES[3:], TARGETS[3:]):
            path = self.local / target
            originals[name] = (self.remote / name).read_bytes() + b'\n# incompatible\n'
            path.write_bytes(originals[name])
            path.chmod(0o640)
        self.command('--certificates', status=1)
        self.command('--fix-http2', status=1)
        p = self.command('--update', answer='y\n', FAIL_MAINTENANCE='1', status=1)
        self.assertIn('正在恢复', p.stderr)
        for name, target in zip(BUNDLE_FILES[3:], TARGETS[3:]):
            path = self.local / target
            self.assertEqual(path.read_bytes(), originals[name])
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            snapshots = list(self.state.glob('rollback.*/' + name))
            self.assertEqual([snap.read_bytes() for snap in snapshots], [originals[name]])
        self.assertEqual((self.state / 'commit').read_text(), STAGE_ONE + '\n')
        self.assertTrue(backup.is_dir())
        self.command('--update', answer='y\n0\n')
        self.assert_bundle()
        self.command('--certificates')
        self.command('--uninstall', answer='UNINSTALL\n')
        self.assertFalse(self.installer.exists())
        for target in (TARGETS[0], TARGETS[1], *TARGETS[3:]):
            self.assertTrue((self.local / target).is_file())
        self.assertTrue(backup.is_dir())

    def test_standalone_install_and_library_preflight(self):
        standalone = self.root / 'standalone'
        standalone.write_bytes((self.remote / 'proxyall').read_bytes())
        last = BUNDLE_FILES[-1]
        self.command('--install', script=standalone, status=1, FAIL_TARBALL='1', FAIL_DOWNLOAD=last)
        self.assertFalse(self.local.exists())
        library = self.remote / last
        original = library.read_bytes()
        library.write_bytes(original.replace(b'# PROXYALL_LIB=', b'# WRONG_MARKER='))
        self.refresh_pins()
        self.clear_downloads()
        self.command('--install', script=standalone, status=1)
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}'])
        self.assertFalse(self.local.exists())
        library.write_bytes(original)
        self.refresh_pins()
        self.clear_downloads()
        p = self.command('--install', script=standalone, answer='0\n')
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}'])
        self.assertIn(f'准备安装 v{BUNDLE_VERSION}', p.stderr)
        self.assert_bundle()
        self.assertEqual((self.root / 'components').read_text(), 'maintenance with libraries\n')

    def install_221_files(self):
        for directory in (self.root / 'usr', self.local, self.local / 'bin',
                          self.local / 'lib', self.local / 'lib/proxyall'):
            directory.mkdir(mode=0o755, exist_ok=True)
            directory.chmod(0o755)
        self.state.mkdir(mode=0o700)
        (self.state / '.managed').write_text('# PROXYALL_MANAGED_COMMAND=1\n')
        (self.state / 'commit').write_text(RELEASE_221 + '\n')
        for name in ('.managed', 'commit'):
            (self.state / name).chmod(0o600)
        for name in FILES_221:
            path = self.local / TARGET_OF[name]
            data = self.git_file(name, RELEASE_221)
            if name == 'proxyall':
                data = self.sandbox(data.decode()).encode()
            path.write_bytes(data)
            path.chmod(0o644 if name.startswith('lib/') else 0o700)

    def test_221_update_then_menu_update_installs_all_modules(self):
        self.install_221_files()
        # Stage one: the 2.2.1 installer replaces its own five files from the new commit.
        p = self.command('--update', answer='y\n0\n', ref=STAGE_ONE)
        self.assertEqual(self.downloaded(), list(FILES_221))
        self.assertEqual((self.root / 'components').read_text(), 'maintenance with libraries\n')
        for name in FILES_221:
            self.assertEqual((self.local / TARGET_OF[name]).read_bytes(), (self.remote / name).read_bytes())
        for name in BUNDLE_FILES[3:]:
            if name not in FILES_221:
                self.assertFalse((self.local / TARGET_OF[name]).exists(), name)
        # The new entry gates node menus until the remaining modules are installed.
        p = self.command(answer='0\n', ref=STAGE_ONE)
        self.assertIn('配套库缺失或版本不匹配', p.stderr)
        self.assertNotIn('1) Emby', p.stdout)
        # Stage two: one more update against the same commit downloads and installs every module.
        p = self.command(answer='3\ny\n2\n0\n', ref=STAGE_ONE)
        self.assertEqual(self.downloaded()[len(FILES_221):], [f'tar.gz:{STAGE_ONE}'])
        self.assertIn('1) Emby', p.stdout)
        self.assert_bundle(ref=STAGE_ONE)
        self.assertEqual((self.root / 'components').read_text().splitlines(),
                         ['maintenance with libraries', 'maintenance with libraries', 'sb menu'])

    def test_unrecognized_library_target_prevents_update(self):
        backup, _ = self.stage_one()
        path = self.local / TARGETS[-1]
        (self.local / 'lib').mkdir(mode=0o755)
        path.parent.mkdir(mode=0o755)
        path.write_text('local file\n')
        path.chmod(0o644)
        self.command('--update', answer='y\n', status=1)
        self.assertEqual(path.read_text(), 'local file\n')
        self.assertEqual(self.downloaded(), list(BUNDLE_FILES[:3]))
        self.assertTrue(backup.is_dir())

    def test_up_to_date_commit_fast_path(self):
        self.install_current_bundle(ref=STAGE_TWO)
        p = self.command('--update', ref=STAGE_TWO)
        self.assertEqual(self.downloaded(), [])
        self.assertEqual(p.stdout, '')
        non_empty = [line for line in p.stderr.splitlines() if line.strip()]
        self.assertEqual(len(non_empty), 1, p.stderr)
        self.assertIn(f'已是最新版本 v{BUNDLE_VERSION}', non_empty[0])
        self.assertIn(STAGE_TWO[:7], non_empty[0])

        # Verbose mode on fast-path prints the full 20-file single-spaced list without downloading.
        pv = self.command('--update', '--verbose', ref=STAGE_TWO)
        self.assertEqual(self.downloaded(), [])
        rows = [line for line in pv.stdout.splitlines() if '已是仓库版本' in line]
        self.assertEqual(len(rows), len(BUNDLE_FILES), pv.stdout)
        self.assertNotIn('已是仓库版本\n\n', pv.stdout)

        # Losing executable bit on an entry disables fast-path and triggers a tarball download.
        (self.local / TARGETS[0]).chmod(0o600)
        pm = self.command('--update', answer='n\n', ref=STAGE_TWO)
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}'])
        self.assertIn('  - sb.sh', pm.stdout)
        (self.local / TARGETS[0]).chmod(0o700)

        # Running a different standalone proxyall against an installed proxyall bypasses fast-path.
        self.clear_downloads()
        standalone_alt = self.root / 'standalone-alt'
        standalone_alt.write_text(self.installer.read_text() + '\n# standalone diff\n')
        pa = self.command('--update', script=standalone_alt, ref=STAGE_TWO)
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}'])
        self.assertIn('无变化', pa.stderr)

    def test_docs_only_commit_syncs_without_prompt(self):
        self.install_current_bundle(ref=STAGE_ONE)
        p = self.command('--update', ref=STAGE_TWO)
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}'])
        self.assertEqual((self.state / 'commit').read_text(), STAGE_TWO + '\n')
        self.assertIn('无变化', p.stderr)
        self.assertIn('已同步提交记录', p.stderr)

    def test_compact_update_output_and_verbose_mode(self):
        self.install_current_bundle(ref=STAGE_ONE)
        # <= 8 changed files: lists each changed file individually.
        (self.remote / 'sb.sh').write_text((self.remote / 'sb.sh').read_text() + '# change 1\n')
        (self.remote / 'lib/common.sh').write_text((self.remote / 'lib/common.sh').read_text() + '# change 1\n')
        self.refresh_pins()
        p_small = self.command('--update', answer='n\n', ref=STAGE_TWO)
        self.assertIn(f'发现更新: v{BUNDLE_VERSION} ({STAGE_ONE[:7]}) -> v{BUNDLE_VERSION} ({STAGE_TWO[:7]})，共 3/{len(BUNDLE_FILES)} 个文件有变化', p_small.stderr)
        self.assertIn('  - sb.sh\n', p_small.stdout)
        self.assertIn('  - lib/common.sh\n', p_small.stdout)
        self.assertIn('  - proxyall\n', p_small.stdout)
        self.assertNotIn('deploy.sh', p_small.stdout)
        self.assertNotIn('包含入口脚本', p_small.stdout)

        # > 8 changed files: prints categorized summary instead of long list.
        for lib in BUNDLE_FILES[3:13]:
            (self.remote / lib).write_text((self.remote / lib).read_text() + '# bulk change\n')
        self.refresh_pins()
        p_large = self.command('--update', answer='n\n', ref=STAGE_TWO)
        self.assertIn(f'共 12/{len(BUNDLE_FILES)} 个文件有变化', p_large.stderr)
        self.assertIn('包含入口脚本 2 个、配套库 10 个（运行 proxyall --update --verbose 查看完整清单）', p_large.stdout)
        self.assertNotIn('  - lib/', p_large.stdout)

        # --verbose and -v show clean single-spaced table for all 20 files.
        for flag in ('--verbose', '-v'):
            with self.subTest(flag=flag):
                pv = self.command('--update', flag, answer='n\n', ref=STAGE_TWO)
                table_lines = [line for line in pv.stdout.splitlines() if '已是仓库版本' in line or '待安装 / 有变化' in line]
                self.assertEqual(len(table_lines), len(BUNDLE_FILES), pv.stdout)
                self.assertNotIn('\n\n  sb.sh', pv.stdout)
                self.assertNotIn('已是仓库版本\n\n', pv.stdout)
                self.assertNotIn('待安装 / 有变化\n\n', pv.stdout)

    def test_codeload_http_failure_falls_back_to_raw(self):
        standalone = self.root / 'standalone-fallback'
        standalone.write_bytes((self.remote / 'proxyall').read_bytes())
        p = self.command('--install', script=standalone, answer='0\n', FAIL_TARBALL='1')
        self.assertIn('回退至逐文件下载', p.stderr)
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}', 'sb.sh', 'deploy.sh', *BUNDLE_FILES[3:], 'proxyall'])
        self.assert_bundle(ref=STAGE_TWO)

    def test_tampered_or_symlink_tarball_fails_without_raw_fallback(self):
        self.install_current_bundle(ref=STAGE_ONE)
        installed_before = {name: (self.local / target).read_bytes() for name, target in zip(BUNDLE_FILES, TARGETS)}

        # Case 1: tarball contains a symlink for lib/common.sh -> fails immediately, no raw fallback.
        symlink_tar = self.root / 'symlink.tar.gz'
        with tarfile.open(symlink_tar, 'w:gz') as tf:
            for d in (f'ss_node-{STAGE_TWO}/', f'ss_node-{STAGE_TWO}/lib/'):
                info = tarfile.TarInfo(d)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tf.addfile(info)
            for name in BUNDLE_FILES:
                member = f'ss_node-{STAGE_TWO}/{name}'
                if name == 'lib/common.sh':
                    info = tarfile.TarInfo(member)
                    info.type = tarfile.SYMTYPE
                    info.linkname = '/etc/passwd'
                    tf.addfile(info)
                else:
                    data = (self.remote / name).read_bytes()
                    info = tarfile.TarInfo(member)
                    info.type = tarfile.REGTYPE
                    info.mode = 0o755
                    info.size = len(data)
                    tf.addfile(info, io.BytesIO(data))

        self.clear_downloads()
        p1 = self.command('--update', ref=STAGE_TWO, status=1, TAMPER_TARBALL=str(symlink_tar))
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}'])
        self.assertIn('源码归档校验或解压失败', p1.stderr)
        self.assertNotIn('回退至逐文件下载', p1.stderr)

        # Case 2: tarball has valid structure but tampered sb.sh (SHA-256 mismatch) -> fails without raw fallback.
        tampered_tar = self.root / 'tampered.tar.gz'
        with tarfile.open(tampered_tar, 'w:gz') as tf:
            for d in (f'ss_node-{STAGE_TWO}/', f'ss_node-{STAGE_TWO}/lib/'):
                info = tarfile.TarInfo(d)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tf.addfile(info)
            for name in BUNDLE_FILES:
                data = (self.remote / name).read_bytes()
                if name == 'sb.sh':
                    data += b'\n# tampered\n'
                info = tarfile.TarInfo(f'ss_node-{STAGE_TWO}/{name}')
                info.type = tarfile.REGTYPE
                info.mode = 0o755
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))

        self.clear_downloads()
        p2 = self.command('--update', ref=STAGE_TWO, status=1, TAMPER_TARBALL=str(tampered_tar))
        self.assertEqual(self.downloaded(), [f'tar.gz:{STAGE_TWO}'])
        self.assertIn('SHA-256 不匹配', p2.stderr)
        self.assertNotIn('回退至逐文件下载', p2.stderr)

        # Verify local files and commit were untouched.
        for name, target in zip(BUNDLE_FILES, TARGETS):
            self.assertEqual((self.local / target).read_bytes(), installed_before[name])
        self.assertEqual((self.state / 'commit').read_text(), STAGE_ONE + '\n')


if __name__ == '__main__':
    unittest.main()
