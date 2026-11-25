#!/usr/bin/env python3
"""Exercise log rotation and backup retention in isolated directories."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from installer import BUNDLE_FILES, copy_files

REPO = Path(__file__).resolve().parents[1]
LIMIT = 150 * 1024 * 1024
LOGROTATE = shutil.which('logrotate')
HARNESS = r'''
source "$REPO/sb.sh"
SINGBOX_DIR="$WORK/sing-box"
CONFIG_FILE="$SINGBOX_DIR/config.json"
LOG_FILE="$WORK/logs/sing-box.log"
ARGO_LOG_FILE="$WORK/logs/argo.log"
XRAY_LOG_FILE="$SINGBOX_DIR/xray.log"
ARGO_LOG_DIR="$WORK/argo"
NGINX_LOG_DIR="$WORK/nginx-logs"
HAPROXY_LOG_FILE="$WORK/logs/haproxy.log"
MAINTENANCE_DIR="$WORK/maintenance"
LOGROTATE_DIR="$WORK/logrotate.d"
SYSTEMD_UNIT_DIR="$WORK/systemd"
NGINX_BACKUP_DIR="$WORK/nginx-backups"
SNI_ROUTER_HAPROXY_BACKUP_DIR="$WORK/haproxy-backups"
SB_ROOT_HOME="$WORK/root"
PROXYALL_STATE_DIR="$WORK/proxyall"
PROXYALL_WRITE_LOCK_FILE="$WORK/write.lock"
INIT_SYSTEM=direct
_pkg_install() { echo unexpected-package-install >&2; return 1; }
pgrep() { return 0; }
cron() { printf started > "$WORK/cron.started"; }
logrotate() { "$TEST_LOGROTATE" -s "$WORK/logrotate.status" "$@"; }
crontab() {
    case "$1" in
        -l) [ ! -f "$WORK/crontab" ] || cat "$WORK/crontab" ;;
        -) cat > "$WORK/crontab.tmp" && mv -f "$WORK/crontab.tmp" "$WORK/crontab" ;;
        *) return 1 ;;
    esac
}
systemctl() {
    printf '%s\n' "$*" >> "$WORK/systemctl.calls"
    if [ "$1" = --version ]; then echo 'systemd 252'; fi
}
'''


@unittest.skipUnless(LOGROTATE, 'logrotate is required')
class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-maintenance-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('sing-box', 'logs', 'argo', 'nginx-logs', 'maintenance',
                          'logrotate.d', 'systemd', 'nginx-backups', 'haproxy-backups',
                          'root', 'proxyall/certificates'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)

    def run_shell(self, body, ok=True):
        result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', HARNESS + '\n' + body],
                                env=dict(os.environ, REPO=str(REPO), WORK=str(self.root),
                                         TEST_LOGROTATE=LOGROTATE),
                                capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def write(self, name, content='data'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_real_150_mib_boundary_and_append_descriptor(self):
        log = self.write('sing-box/xray.log')
        with log.open('r+b') as stream:
            stream.truncate(LIMIT)
        self.run_shell('_cleanup_runtime_logs')
        self.assertEqual(log.stat().st_size, LIMIT)
        self.assertFalse(Path(str(log) + '.1').exists())
        with log.open('ab') as stream:
            stream.write(b'x')
        inode = log.stat().st_ino
        self.run_shell('exec 3>>"$XRAY_LOG_FILE"\n_cleanup_runtime_logs\nprintf after-rotation >&3')
        self.assertEqual(log.stat().st_ino, inode)
        self.assertEqual(log.read_text(), 'after-rotation')
        backup = Path(str(log) + '.1')
        self.assertEqual(backup.stat().st_size, LIMIT + 1)
        with backup.open('rb') as stream:
            stream.seek(-1, 2)
            self.assertEqual(stream.read(), b'x')

    def small_policy(self):
        return r'''
eval "$(declare -f _runtime_log_policy | sed '1s/_runtime_log_policy/_test_policy/')"
_runtime_log_policy() { _test_policy "$@" | sed 's/size 157286401/size 4k/'; }
'''

    def test_all_runtime_logs_keep_one_rotation(self):
        paths = ['logs/sing-box.log', 'logs/argo.log', 'sing-box/xray.log',
                 'sing-box/relay_operations.log', 'argo/singbox_argo_1234.log',
                 'nginx-logs/access.log', 'nginx-logs/error.log', 'logs/haproxy.log']
        for path in paths:
            self.write(path, 'first\n' * 1000)
            old = self.write(path + '.2.gz', 'old')
            os.utime(old, (1, 1))
        self.run_shell(self.small_policy() + '\n_cleanup_runtime_logs')
        for path in paths:
            self.assertEqual((self.root / path).stat().st_size, 0)
            self.assertEqual((self.root / (path + '.1')).read_text(), 'first\n' * 1000)
            self.assertFalse((self.root / (path + '.2.gz')).exists())
            self.write(path, 'second\n' * 1000)
        self.run_shell(self.small_policy() + '\n_cleanup_runtime_logs')
        for path in paths:
            self.assertEqual((self.root / (path + '.1')).read_text(), 'second\n' * 1000)
            self.assertFalse((self.root / (path + '.2')).exists())

    def test_small_and_empty_logs_are_untouched(self):
        self.write('logs/sing-box.log', 'recent')
        self.write('sing-box/xray.log', '')
        self.run_shell('_cleanup_runtime_logs')
        self.assertEqual((self.root / 'logs/sing-box.log').read_text(), 'recent')
        self.assertFalse((self.root / 'logs/sing-box.log.1').exists())

    def test_current_rotation_wins_over_legacy_archives(self):
        current = self.write('logs/sing-box.log.1', 'latest rotation')
        archive = self.write('logs/sing-box.log.2.gz', 'older rotation')
        os.utime(current, (1, 1))
        os.utime(archive, (2, 2))
        self.run_shell('_cleanup_runtime_logs')
        self.assertEqual(current.read_text(), 'latest rotation')
        self.assertFalse(archive.exists())

    def test_policies_are_idempotent_and_preserve_original(self):
        original = self.write('logrotate.d/nginx', '/var/log/nginx/*.log {\n daily\n rotate 14\n}\n')
        before = original.read_text()
        self.run_shell('_configure_runtime_log_rotation\n_configure_runtime_log_rotation')
        self.assertEqual((self.root / 'maintenance/logrotate-nginx.latest').read_text(), before)
        policy = original.read_text()
        self.assertIn('size 157286401', policy)
        self.assertIn('rotate 1', policy)
        self.assertNotIn('daily', policy)

    def test_cron_replaces_daily_job_and_preserves_other_tasks(self):
        self.write('crontab', '0 1 * * * unrelated\n17 3 * * * old # sing-box-log-cleanup\n')
        self.run_shell('_setup_log_cleanup\n_setup_log_cleanup')
        content = (self.root / 'crontab').read_text()
        self.assertIn('0 1 * * * unrelated', content)
        self.assertEqual(content.count('# sing-box-log-cleanup'), 1)
        self.assertIn('*/15 * * * * bash ', content)
        self.assertNotIn('17 3', content)

    def test_direct_mode_starts_cron(self):
        self.run_shell('pgrep() { return 1; }\ncrond() { cron; }\n_setup_log_cleanup')
        self.assertEqual((self.root / 'cron.started').read_text(), 'started')

    def test_systemd_output_is_installed_without_restarting_services(self):
        for unit in ('sing-box', 'proxyall-xray'):
            self.write('systemd/' + unit + '.service', '[Service]\nExecStart=/bin/true\n')
        self.run_shell('INIT_SYSTEM=systemd\n_setup_log_cleanup\n_setup_log_cleanup')
        for unit in ('sing-box', 'proxyall-xray'):
            content = (self.root / ('systemd/' + unit + '.service.d/90-proxyall-logging.conf')).read_text()
            self.assertIn('StandardOutput=append:', content)
            self.assertIn('StandardError=inherit', content)
        calls = (self.root / 'systemctl.calls').read_text()
        self.assertEqual(calls.count('daemon-reload'), 1)
        self.assertNotIn('restart', calls)
        self.assertIn('enable --now cron', calls)

    def test_symlinked_policy_and_log_directory_are_rejected(self):
        original = self.write('protected', 'preserve')
        (self.root / 'logrotate.d/proxyall').symlink_to(original)
        self.run_shell('_configure_runtime_log_rotation', ok=False)
        self.assertEqual(original.read_text(), 'preserve')
        (self.root / 'logrotate.d/proxyall').unlink()
        (self.root / 'nginx-logs').rmdir()
        (self.root / 'nginx-logs').symlink_to(self.root / 'logs', target_is_directory=True)
        self.run_shell('_configure_runtime_log_rotation', ok=False)

    def test_custom_systemd_dropin_is_preserved(self):
        self.write('systemd/sing-box.service', '[Service]\nExecStart=/bin/true\n')
        custom = self.write('systemd/sing-box.service.d/90-proxyall-logging.conf', '# custom\n')
        self.run_shell('INIT_SYSTEM=systemd\n_configure_runtime_log_output', ok=False)
        self.assertEqual(custom.read_text(), '# custom\n')

    def test_dated_backups_are_grouped_per_configuration(self):
        for base in ('site-a.conf', 'site-b.conf'):
            self.write('nginx-backups/' + base + '.20261101_120000', 'old')
            self.write('nginx-backups/' + base + '.20261106_120000.100', 'new')
        self.write('nginx-backups/custom.txt', 'unrelated')
        self.write('haproxy-backups/haproxy.cfg.20261101_120000.1', 'old')
        self.write('haproxy-backups/haproxy.cfg.20261106_120000.2', 'new')
        self.write('sing-box/config.json.bak_dns_20261101_120000', 'old')
        self.write('sing-box/config.json.bak_dns_20261106_120000', 'new')
        self.run_shell('_cleanup_config_backups')
        self.assertEqual(len(list((self.root / 'nginx-backups').iterdir())), 3)
        self.assertTrue((self.root / 'nginx-backups/custom.txt').exists())
        self.assertEqual(len(list((self.root / 'haproxy-backups').iterdir())), 1)
        self.assertEqual(len(list((self.root / 'sing-box').glob('*.bak_dns_*'))), 1)

    def test_latest_core_and_bundle_snapshots_and_active_bundle_lock(self):
        self.write('proxyall/.managed', '# PROXYALL_MANAGED_COMMAND=1\n')
        for i in (1, 2):
            for prefix, filename in [('root/.singbox-update.', 'sing-box'), ('proxyall/backup.', 'sb.sh')]:
                path = self.write(prefix + str(i) + '/' + filename)
                os.utime(path.parent, (i, i))
        self.run_shell('exec 9>"$PROXYALL_STATE_DIR/manager.lock"\nflock -n 9\n_cleanup_config_backups')
        self.assertFalse((self.root / 'root/.singbox-update.1').exists())
        self.assertTrue((self.root / 'proxyall/backup.1').exists())
        self.run_shell('_cleanup_config_backups')
        self.assertFalse((self.root / 'proxyall/backup.1').exists())
        self.assertTrue((self.root / 'proxyall/backup.2').exists())

    def test_certificate_backups_are_per_certificate_and_archives_are_preserved(self):
        for name, certificate, timestamp in [('a-old', 'a', 1), ('a-new', 'a', 2), ('b-only', 'b', 1)]:
            path = self.write('proxyall/certificates/operation.' + name + '/paths.txt',
                              'certificate=/etc/nginx/certs/' + certificate + '/cert\n')
            os.utime(path.parent, (timestamp, timestamp))
        archive = self.write('proxyall/certificates/operation.archive/archived/cert', 'retained certificate')
        self.run_shell('_cleanup_config_backups')
        self.assertFalse((self.root / 'proxyall/certificates/operation.a-old').exists())
        self.assertTrue((self.root / 'proxyall/certificates/operation.a-new').exists())
        self.assertTrue((self.root / 'proxyall/certificates/operation.b-only').exists())
        self.assertEqual(archive.read_text(), 'retained certificate')

    def test_failed_backup_copy_keeps_previous_snapshot(self):
        self.write('nginx-backups/site.conf.20261101_120000', 'good snapshot')
        self.write('site.conf', 'current config')
        self.run_shell('cp() { printf partial > "${@: -1}"; return 1; }\n_sb_backup_nginx_file "$WORK/site.conf"', ok=False)
        self.assertEqual((self.root / 'nginx-backups/site.conf.20261101_120000').read_text(), 'good snapshot')
        self.assertEqual(len(list((self.root / 'nginx-backups').iterdir())), 1)

    def test_successful_backup_keeps_other_sites(self):
        self.write('nginx-backups/site.conf.20261101_120000', 'old snapshot')
        self.write('nginx-backups/other.conf.20261101_120000', 'other site')
        self.write('site.conf', 'current config')
        self.run_shell('_sb_backup_nginx_file "$WORK/site.conf"')
        snapshots = list((self.root / 'nginx-backups').glob('site.conf.*'))
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(snapshots[0].read_text(), 'current config')
        self.assertEqual((self.root / 'nginx-backups/other.conf.20261101_120000').read_text(), 'other site')

    def test_deploy_backups_keep_latest_per_site(self):
        self.write('nginx-backups/site.conf.20261101_120000', 'old')
        self.write('nginx-backups/other.conf.20261101_120000', 'other site')
        self.write('site.conf', 'current config')
        self.run_shell(r'''
source "$REPO/deploy.sh"
trap - ERR INT TERM
BACKUP_DIR="$WORK/nginx-backups"
backup_file "$WORK/site.conf"
''')
        snapshots = list((self.root / 'nginx-backups').glob('site.conf.*'))
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(snapshots[0].read_text(), 'current config')
        self.assertTrue((self.root / 'nginx-backups/other.conf.20261101_120000').exists())

    def bundle_install(self, fail=False):
        self.write('proxyall/backup.old/sb.sh', 'old snapshot')
        target = self.root / 'bundle-target'
        stage = self.root / 'bundle-stage'
        copy_files(REPO, target, BUNDLE_FILES)
        copy_files(REPO, stage, BUNDLE_FILES)
        self.write('bundle-stage/sb.sh', '#!/bin/bash\n[ "$1" = setup-maintenance ]\n')
        self.write('bundle-stage/commit', 'new commit\n')
        self.write('proxyall/commit', 'previous commit\n').chmod(0o600)
        for directory in ('proxyall', 'proxyall/backup.old'):
            (self.root / directory).chmod(0o700)
        return self.run_shell(r'''
source "$REPO/proxyall"
# The test root is private, although its system temp parent permits writes.
stat() {
    if [ "$1" = -Lc ] && [ "$4" = "${WORK%/*}" ]; then
        printf '0 755\n'
    else
        command stat "$@"
    fi
}
PA_STATE="$WORK/proxyall"
PA_STAGE="$WORK/bundle-stage"
PA_TARGETS=()
for file in "${PA_FILES[@]}"; do PA_TARGETS+=("$WORK/bundle-target/$file"); done
''' + (r'''
mv() {
    if [ "${!#}" = "$PA_STATE/commit" ] && grep -Fqx 'new commit' "${@: -2:1}"; then
        return 1
    fi
    command mv "$@"
}
if pa_install_bundle; then exit 42; fi
pa_rollback
''' if fail else 'pa_install_bundle'))

    def test_bundle_prunes_only_after_successful_install(self):
        self.bundle_install()
        snapshots = list((self.root / 'proxyall').glob('backup.*'))
        self.assertEqual(len(snapshots), 1)
        for name in BUNDLE_FILES:
            self.assertEqual((snapshots[0] / name).read_bytes(), (REPO / name).read_bytes())
        self.assertEqual((snapshots[0] / 'commit').read_text(), 'previous commit\n')
        self.assertEqual((self.root / 'proxyall/commit').read_text(), 'new commit\n')

    def test_bundle_failure_preserves_existing_snapshots_and_script(self):
        self.bundle_install(fail=True)
        self.assertEqual((self.root / 'proxyall/backup.old/sb.sh').read_text(), 'old snapshot')
        for name in BUNDLE_FILES:
            self.assertEqual((self.root / 'bundle-target' / name).read_bytes(), (REPO / name).read_bytes())
        self.assertEqual((self.root / 'proxyall/commit').read_text(), 'previous commit\n')


class ServiceAndUninstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='proxyall-service-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('sing-box', 'bin', 'logs', 'systemd', 'logrotate.d', 'maintenance'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)

    def write(self, rel, content='data', mode=None):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        if mode is not None:
            path.chmod(mode)
        return path

    def run_shell(self, body, stdin_text='', expected_rc=0):
        preamble = r'''
source "$REPO/sb.sh"
SINGBOX_DIR="$WORK/sing-box"
CONFIG_FILE="$SINGBOX_DIR/config.json"
METADATA_FILE="$SINGBOX_DIR/metadata.json"
CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
XRAY_CONFIG_FILE="$SINGBOX_DIR/xray.json"
SINGBOX_BIN="$WORK/bin/sing-box"
XRAY_BIN="$WORK/bin/xray"
YQ_BINARY="$WORK/bin/yq"
CLOUDFLARED_BIN="$WORK/bin/cloudflared"
REALITL_SCANNER_DIR="$WORK/scanner"
REALITL_SCANNER_BIN="$WORK/scanner/RealiTLScanner"
REALITL_SCANNER_MARKER="$WORK/scanner/.managed"
GO_TOOLCHAIN_DIR="$WORK/go-toolchain"
GO_TOOLCHAIN_MARKER="$WORK/go-toolchain/.managed"
SELF_SCRIPT_PATH="$WORK/bin/sb"
SERVICE_FILE="$WORK/systemd/sing-box.service"
SYSTEMD_UNIT_DIR="$WORK/systemd"
LOGROTATE_DIR="$WORK/logrotate.d"
MAINTENANCE_DIR="$WORK/maintenance"
LOG_FILE="$WORK/logs/sing-box.log"
XRAY_LOG_FILE="$SINGBOX_DIR/xray.log"
ARGO_LOG_FILE="$WORK/logs/argo.log"
SNI_ROUTER_STATE_FILE="$WORK/router/state.json"
PROXYALL_WRITE_LOCK_FILE="$WORK/write.lock"
rm() {
    local -a filtered=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            /usr/local/bin/sb) continue ;;
            -*) filtered+=("$arg") ;;
            "$WORK"/*|"$WORK") filtered+=("$arg") ;;
            *) echo "refusing rm outside WORK: $arg" >&2; return 1 ;;
        esac
    done
    local has_path=0
    for arg in "${filtered[@]}"; do
        [[ "$arg" == -* ]] || has_path=1
    done
    [ "$has_path" = 0 ] || command rm "${filtered[@]}"
}
crontab() {
    case "$1" in
        -l) [ ! -f "$WORK/crontab" ] || cat "$WORK/crontab" ;;
        -) cat > "$WORK/crontab.tmp" && mv -f "$WORK/crontab.tmp" "$WORK/crontab" ;;
        *) return 1 ;;
    esac
}
systemctl() {
    printf '%s\n' "$*" >> "$WORK/systemctl.calls"
    return 0
}
_remove_time_sync() { :; }
_remove_nftables_rules() { :; }
_disable_argo_watchdog() { :; }
_stop_all_argo_tunnels() { :; }
'''
        result = subprocess.run(
            ['bash', '-c', preamble + '\n' + body],
            input=stdin_text, text=True, capture_output=True, timeout=20,
            env=dict(os.environ, REPO=str(REPO), WORK=str(self.root)),
        )
        self.assertEqual(result.returncode, expected_rc, result.stdout + result.stderr)
        return result

    def test_mixed_status_reports_active_xray_when_singbox_stopped(self):
        self.write('bin/sing-box', '#!/usr/bin/env bash\nexit 0\n', mode=0o700)
        self.write('bin/xray', '#!/usr/bin/env bash\nexit 0\n', mode=0o700)

        active = self.run_shell(r'''
_manage_singbox_service_impl() { echo "Sing-box: inactive"; return 3; }
_xray_service() { echo "Xray: active"; return 0; }
_xray_running() { return 0; }
_manage_service status
''', expected_rc=0)
        self.assertIn('Sing-box: inactive', active.stdout)
        self.assertIn('Xray: active', active.stdout)

        both_stopped = self.run_shell(r'''
_manage_singbox_service_impl() { echo "Sing-box: inactive"; return 3; }
_xray_service() { echo "Xray: inactive"; return 3; }
_xray_running() { return 1; }
_manage_service status
''', expected_rc=3)
        self.assertIn('Sing-box: inactive', both_stopped.stdout)
        self.assertIn('Xray: inactive', both_stopped.stdout)

    def test_uninstall_cleans_restart_timers_and_log_dropins_including_xray_only(self):
        # Case 1: Full dual-core install with restart timer, log drop-ins, logrotate policy, and crontab.
        self.write('bin/sing-box', '#!/usr/bin/env bash\nexit 0\n', mode=0o700)
        self.write('bin/xray', '#!/usr/bin/env bash\nexit 0\n', mode=0o700)
        self.write('bin/sb', '#!/usr/bin/env bash\nexit 0\n', mode=0o700)
        self.write('sing-box/.managed_sing_box', '')
        self.write('sing-box/.managed_xray', '')
        self.write('sing-box/config.json', '{"inbounds":[],"outbounds":[]}')
        self.write('sing-box/metadata.json', '{}')
        self.write('sing-box/xray.log', 'xray-log')
        self.write('logs/sing-box.log', 'sb-log')
        self.write('systemd/sing-box.service', '[Service]\nExecStart=/bin/true\n')
        self.write('systemd/proxyall-xray.service', '[Service]\nExecStart=/bin/true\n')
        self.write('systemd/sing-box-restart.timer', '[Timer]\nOnCalendar=daily\n')
        self.write('systemd/sing-box-restart.service', '[Service]\nExecStart=/bin/true\n')
        for unit in ('sing-box', 'proxyall-xray'):
            self.write(
                f'systemd/{unit}.service.d/90-proxyall-logging.conf',
                '# Managed by proxyall log maintenance\n[Service]\nStandardOutput=append:/tmp/x.log\n',
            )
        self.write('logrotate.d/proxyall', '# Managed by proxyall log maintenance\n')
        self.write('crontab', '0 1 * * * keep-me\n*/15 * * * * bash /usr/local/bin/sb cleanup-logs # sing-box-log-cleanup\n')

        self.run_shell(r'''
INIT_SYSTEM=systemd
_xray_service() { return 0; }
_manage_singbox_service_impl() { return 0; }
_uninstall_locked
''', stdin_text='y\n', expected_rc=0)

        for gone in (
            'sing-box', 'bin/sing-box', 'bin/xray', 'bin/sb',
            'logs/sing-box.log',
            'systemd/sing-box.service', 'systemd/proxyall-xray.service',
            'systemd/sing-box-restart.timer', 'systemd/sing-box-restart.service',
            'systemd/sing-box.service.d/90-proxyall-logging.conf',
            'systemd/sing-box.service.d',
            'systemd/proxyall-xray.service.d/90-proxyall-logging.conf',
            'systemd/proxyall-xray.service.d',
            'logrotate.d/proxyall',
        ):
            self.assertFalse((self.root / gone).exists(), f'expected {gone} to be removed')
        crontab_after = (self.root / 'crontab').read_text()
        self.assertIn('0 1 * * * keep-me', crontab_after)
        self.assertNotIn('# sing-box-log-cleanup', crontab_after)
        calls = (self.root / 'systemctl.calls').read_text()
        self.assertIn('disable proxyall-xray', calls)
        self.assertIn('daemon-reload', calls)
        if Path('/run/systemd/system').is_dir():
            self.assertIn('disable --now sing-box-restart.timer', calls)

        # Case 2: Xray-only installation (installed via [18] with no nodes / no xray.json / no sing-box).
        (self.root / 'systemctl.calls').unlink(missing_ok=True)
        (self.root / 'sing-box').mkdir(exist_ok=True)
        self.write('bin/xray', '#!/usr/bin/env bash\nexit 0\n', mode=0o700)
        self.write('sing-box/.managed_xray', '')
        self.write('systemd/proxyall-xray.service', '[Service]\nExecStart=/bin/true\n')
        self.write(
            'systemd/proxyall-xray.service.d/90-proxyall-logging.conf',
            '# Managed by proxyall log maintenance\n[Service]\nStandardOutput=append:/tmp/xray.log\n',
        )
        custom = self.write('systemd/sing-box.service.d/90-proxyall-logging.conf', '# custom user drop-in\n')

        self.run_shell(r'''
INIT_SYSTEM=systemd
_xray_service() { return 0; }
_uninstall_locked
''', stdin_text='y\n', expected_rc=0)

        for gone in (
            'bin/xray', 'sing-box',
            'systemd/proxyall-xray.service',
            'systemd/proxyall-xray.service.d/90-proxyall-logging.conf',
            'systemd/proxyall-xray.service.d',
        ):
            self.assertFalse((self.root / gone).exists(), f'expected {gone} to be removed in xray-only uninstall')
        # Unmanaged custom drop-ins must be preserved.
        self.assertEqual(custom.read_text(), '# custom user drop-in\n')
        calls2 = (self.root / 'systemctl.calls').read_text()
        self.assertIn('disable proxyall-xray', calls2)
        self.assertIn('daemon-reload', calls2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
