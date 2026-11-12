#!/usr/bin/env python3
"""Check swap provisioning using temporary files and simulated kernel commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
source "$REPO/proxyall"
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 2000000 0 %s 0%% /\n' "${AVAILABLE:-2000000}"; }
dd() {
    printf '%s\n' "$*" >> "$WORK/dd.args"
    [ "${FAIL:-}" != dd ] || return 1
    printf allocated > "$WORK/swap"
}
mkswap() { [ "${FAIL:-}" != mkswap ]; }
swapon() {
    printf 'on\n' >> "$WORK/kernel"
    [ "${FAIL:-}" != swapon ] || return 1
    if [ "${FAIL:-}" = concurrent ]; then printf '# external edit\n' >> "$WORK/fstab"; fi
}
swapoff() {
    printf 'off\n' >> "$WORK/kernel"
    [ "${FAIL:-}" != swapoff ]
}
mv() {
    [ "${FAIL:-}" != mv ] && [ "${FAIL:-}" != swapoff ] || return 1
    command mv "$@"
}
pa_setup_swap "$WORK/swap" "$WORK/fstab" "$WORK/swaps"
'''


class SwapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-swap-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.original = '# system mounts\n/dev/root / ext4 defaults 0 1\n'
        (self.root / 'fstab').write_text(self.original)
        (self.root / 'fstab').chmod(0o644)
        (self.root / 'swaps').write_text('Filename Type Size Used Priority\n')

    def run_swap(self, ok=True, **extra):
        result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', HARNESS],
                                env=dict(os.environ, REPO=str(REPO), WORK=str(self.root), **extra),
                                text=True, capture_output=True, timeout=10)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assert_unmodified(self):
        self.assertEqual((self.root / 'fstab').read_text(), self.original)
        self.assertFalse((self.root / 'swap').exists())

    def test_create_and_repeat(self):
        self.run_swap()
        swap = self.root / 'swap'
        self.assertEqual(swap.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'fstab').stat().st_mode & 0o777, 0o644)
        self.assertEqual((self.root / 'fstab').read_text(),
                         self.original + f'\n{swap} none swap sw 0 0\n')
        backups = list(self.root.glob('fstab.proxyall-backup.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), self.original)
        self.assertIn('bs=1M count=1024', (self.root / 'dd.args').read_text())
        (self.root / 'swaps').write_text(f'Filename Type Size Used Priority\n{swap} file 1048572 0 -2\n')
        self.run_swap()
        self.assertEqual((self.root / 'kernel').read_text(), 'on\n')
        self.assertEqual(len(list(self.root.glob('fstab.proxyall-backup.*'))), 1)

    def test_existing_swap_preserved(self):
        (self.root / 'swaps').write_text('Filename Type Size Used Priority\n/other file 524284 0 -2\n')
        self.run_swap()
        self.assert_unmodified()
        self.assertFalse((self.root / 'kernel').exists())

    def test_existing_file_and_symlink_preserved(self):
        swap = self.root / 'swap'
        swap.write_text('user data')
        self.run_swap(ok=False)
        self.assertEqual(swap.read_text(), 'user data')
        swap.unlink()
        swap.symlink_to(self.root / 'absent')
        self.run_swap(ok=False)
        self.assertTrue(swap.is_symlink())

    def test_inactive_fstab_entry_preserved(self):
        original = self.original + f'{self.root}/swap none swap sw 0 0\n'
        (self.root / 'fstab').write_text(original)
        self.run_swap(ok=False)
        self.assertEqual((self.root / 'fstab').read_text(), original)
        self.assertFalse((self.root / 'swap').exists())

    def test_symlink_fstab_preserved(self):
        fstab = self.root / 'fstab'
        fstab.rename(self.root / 'real-fstab')
        fstab.symlink_to(self.root / 'real-fstab')
        self.run_swap(ok=False)
        self.assertTrue(fstab.is_symlink())
        self.assert_unmodified()

    def test_menu_entry(self):
        result = subprocess.run(['bash', '-eu', '-c',
                                 'source "$REPO/proxyall"; '
                                 'pa_setup_swap() { echo swap-selected; }; pa_menu'],
                                env=dict(os.environ, REPO=str(REPO)),
                                input='7\n0\n', text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('7) 配置 1 GiB swap', result.stdout)
        self.assertEqual(result.stdout.count('swap-selected'), 1)

    def test_insufficient_disk(self):
        self.run_swap(ok=False, AVAILABLE='1048576')
        self.assert_unmodified()
        self.assertFalse((self.root / 'dd.args').exists())

    def test_allocation_format_and_activation_failure(self):
        for failure in ('dd', 'mkswap', 'swapon'):
            with self.subTest(failure=failure):
                self.run_swap(ok=False, FAIL=failure)
                self.assert_unmodified()

    def test_persistence_failure_rolls_back_active_swap(self):
        self.run_swap(ok=False, FAIL='mv')
        self.assert_unmodified()
        self.assertEqual((self.root / 'kernel').read_text(), 'on\noff\n')

    def test_failed_swapoff_keeps_active_file(self):
        result = self.run_swap(ok=False, FAIL='swapoff')
        self.assertTrue((self.root / 'swap').exists())
        self.assertIn('文件已保留', result.stderr)
        self.assertEqual((self.root / 'fstab').read_text(), self.original)

    def test_concurrent_fstab_edit_preserved(self):
        self.run_swap(ok=False, FAIL='concurrent')
        self.assertEqual((self.root / 'fstab').read_text(), self.original + '# external edit\n')
        self.assertFalse((self.root / 'swap').exists())
        self.assertEqual((self.root / 'kernel').read_text(), 'on\noff\n')


if __name__ == '__main__':
    unittest.main()
