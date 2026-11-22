#!/usr/bin/env python3
"""Run the 52431e5 updater and the current menu in an isolated installation root."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from installer import BUNDLE_FILES, REPO, copy_files

LEGACY = '52431e518f6b1941f4f6aab577d0c9331afa1543'
STAGE_ONE = '1' * 40
STAGE_TWO = '2' * 40
TARGETS = ('bin/sb', 'bin/nginxproxy', 'bin/proxyall',
           'lib/proxyall/common.sh', 'lib/proxyall/sni_router.sh')
KEYS = ('SB_SHA256', 'DEPLOY_SHA256', None, 'COMMON_SHA256', 'SNI_ROUTER_SHA256')

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

    def git_file(self, path):
        return subprocess.check_output(['git', 'show', f'{LEGACY}:{path}'], cwd=REPO)

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
        return (self.root / 'downloads').read_text().splitlines()

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
        self.assertEqual(self.downloaded()[3:], ['sb.sh', 'deploy.sh', *BUNDLE_FILES[3:], 'proxyall'])
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
        self.command('--install', script=standalone, status=1, FAIL_DOWNLOAD=last)
        self.assertFalse(self.local.exists())
        library = self.remote / last
        original = library.read_bytes()
        library.write_bytes(original.replace(b'# PROXYALL_LIB=', b'# WRONG_MARKER='))
        self.refresh_pins()
        self.command('--install', script=standalone, status=1)
        self.assertFalse(self.local.exists())
        library.write_bytes(original)
        self.refresh_pins()
        self.command('--install', script=standalone, answer='0\n')
        self.assert_bundle()
        self.assertEqual((self.root / 'components').read_text(), 'maintenance with libraries\n')

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


if __name__ == '__main__':
    unittest.main()
