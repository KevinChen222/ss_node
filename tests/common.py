#!/usr/bin/env python3
"""Cover the shared entry bootstrap, module loading and the staged maintenance calls."""
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
BWRAP = shutil.which('bwrap')
LEGACY = '52431e518f6b1941f4f6aab577d0c9331afa1543'


class CommonTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix='proxyall-common-test-')
        self.addCleanup(work.cleanup)
        self.work = Path(work.name)

    def shell(self, body, *args):
        result = subprocess.run(
            ['bash', '-eu', '-o', 'pipefail', '-c', body, 'test', *args],
            cwd=self.work, env=dict(os.environ, REPO=str(REPO)),
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_both_checkout_entries_source_the_libraries_and_keep_validator_behavior(self):
        for entry, validator in (('sb.sh', '_is_valid_ipv4'), ('deploy.sh', 'is_valid_ipv4')):
            with self.subTest(entry=entry):
                self.shell(r'''
source "$REPO/$1"
declare -F _config_write_lock _sni_router_cli >/dev/null
"$2" 001.02.255.0
for bad in 256.1.2.3 0.0.0 0001.2.3.4 1.2.3.4.5; do
    if "$2" "$bad"; then exit 1; fi
done
''', entry, validator)

    def test_bootstrap_block_is_identical_in_both_entries(self):
        pattern = re.compile(r'^# >>> proxyall bootstrap\n.*?^# <<< proxyall bootstrap\n', re.M | re.S)
        blocks = [pattern.search((REPO / name).read_text()) for name in ('sb.sh', 'deploy.sh')]
        self.assertTrue(all(blocks))
        self.assertEqual(blocks[0].group(0), blocks[1].group(0))

    def test_function_ownership_and_bundle_lists(self):
        result = subprocess.run(['python3', REPO / 'tools/check_functions.py'],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_modules_keep_maintenance_and_gate_features(self):
        lib = self.work / 'lib'
        lib.mkdir()
        for name in ('common.sh', 'sni_router.sh'):
            shutil.copyfile(REPO / 'lib' / name, lib / name)
        shutil.copyfile(REPO / 'sb.sh', self.work / 'sb.sh')
        result = self.shell(r'''
source ./sb.sh
[[ $SB_MODULES_READY == false ]]
declare -F _setup_log_cleanup _cleanup_runtime_logs _cleanup_config_backups _pkg_install >/dev/null
if declare -F _node_operation >/dev/null; then exit 1; fi
if _sb_require_modules; then exit 1; fi
if _advanced_features; then exit 1; fi
''')
        self.assertIn('proxyall --update', result.stderr)

    def test_incomplete_checkout_returns_before_loading_either_library(self):
        (self.work / 'lib').mkdir()
        (self.work / 'lib/common.sh').write_text('# PROXYALL_LIB=common.sh\ntouch loaded\n')
        for entry in ('sb.sh', 'deploy.sh'):
            with self.subTest(entry=entry):
                shutil.copyfile(REPO / entry, self.work / entry)
                result = self.shell(r'''
if source "./$1"; then exit 1; fi
[[ ! -e loaded ]]
''', entry)
                self.assertIn('proxyall --install', result.stderr)

    def test_standalone_updates_require_the_bundle(self):
        for entry, command in (('sb.sh', '_update_script'), ('deploy.sh', 'update_script')):
            with self.subTest(entry=entry):
                result = self.shell(r'''
source "$REPO/$1"
curl() { touch attempted_download; return 1; }
wget() { touch attempted_download; return 1; }
if "$2"; then exit 1; fi
[[ ! -e attempted_download ]]
''', entry, command)
                self.assertIn('proxyall --update', result.stderr)

    @unittest.skipUnless(BWRAP and all(shutil.which(cmd) for cmd in (
        'cron', 'crontab', 'logrotate', 'pgrep', 'flock',
    )), 'bubblewrap, cron, logrotate, pgrep and flock are required')
    def test_legacy_installer_runs_real_maintenance_without_libraries(self):
        namespace = [BWRAP, '--die-with-parent', '--unshare-user', '--uid', '0', '--gid', '0',
                     '--unshare-pid', '--unshare-net', '--dev', '/dev', '--proc', '/proc',
                     '--dir', '/usr', '--ro-bind', '/usr/bin', '/usr/bin',
                     '--ro-bind', '/usr/sbin', '/usr/sbin', '--ro-bind', '/usr/lib', '/usr/lib',
                     '--ro-bind-try', '/usr/lib64', '/usr/lib64', '--ro-bind', '/etc', '/etc',
                     '--symlink', 'usr/bin', '/bin', '--symlink', 'usr/sbin', '/sbin',
                     '--symlink', 'usr/lib', '/lib', '--symlink', 'usr/lib64', '/lib64', '--chdir', '/']
        probe = subprocess.run(namespace + ['true'], capture_output=True, text=True, timeout=10)
        if probe.returncode:
            self.skipTest(probe.stderr.strip())
        legacy = self.work / 'legacy-proxyall'
        legacy.write_bytes(subprocess.check_output(['git', 'show', f'{LEGACY}:proxyall'], cwd=REPO))
        result = subprocess.run(namespace + [
            '--tmpfs', '/run', '--tmpfs', '/var', '--tmpfs', '/tmp',
            '--tmpfs', '/etc/cron.d', '--ro-bind', '/dev/null', '/etc/crontab',
            '--ro-bind', str(legacy), '/tmp/legacy-proxyall', '--ro-bind', str(REPO), '/tmp/repo',
            '--chdir', '/tmp', 'bash', '-euc', r'''
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PROXYALL_MAINTENANCE_DIR=/var/lib/proxyall-maintenance
export PROXYALL_LOGROTATE_DIR=/tmp/logrotate.d
export PROXYALL_WRITE_LOCK_FILE=/run/lock/proxyall-config.lock
umask 022
mkdir -p /usr/local/bin /usr/local/lib /var/spool/cron/crontabs
chmod 1730 /var/spool/cron/crontabs
ln -s /run /var/run

# Use the original install transaction with the two current production scripts.
source /tmp/legacy-proxyall
pa_prepare_state
PA_STAGE=$(mktemp -d "$PA_STATE/stage.XXXXXXXX")
cp /tmp/repo/sb.sh /tmp/repo/deploy.sh "$PA_STAGE/"
cp /tmp/legacy-proxyall "$PA_STAGE/proxyall"
printf '%s\n' "$1" > "$PA_STAGE/commit"
test ! -e /usr/local/lib/proxyall/common.sh
test ! -e /usr/local/lib/proxyall/sni_router.sh
test ! -d /run/systemd/system
pa_install_bundle 2>/tmp/install.err
cmp /tmp/repo/sb.sh /usr/local/bin/sb
grep -Fq '日志维护将在下一次 proxyall 更新补齐配套库后设置' /tmp/install.err
test ! -e "$PROXYALL_LOGROTATE_DIR/proxyall"
if crontab -l 2>/dev/null | grep -Fq sing-box-log-cleanup; then exit 1; fi

# The second update installs every library; maintenance then runs for real.
install -d -m 755 /usr/local/lib/proxyall
install -m 644 /tmp/repo/lib/*.sh /usr/local/lib/proxyall/
PROXYALL_MANAGED=1 bash /usr/local/bin/sb setup-maintenance
test -f "$PROXYALL_WRITE_LOCK_FILE"
grep -Fx '# Managed by proxyall log maintenance' "$PROXYALL_LOGROTATE_DIR/proxyall"
crontab -l | grep -Fx '*/15 * * * * bash /usr/local/bin/sb cleanup-logs >/dev/null 2>&1 # sing-box-log-cleanup'
pgrep -a -x cron
rm -rf /usr/local/lib/proxyall

# Installed commands ignore a marked library tree in cwd or the environment.
mkdir lib /usr/local/bin/lib
for name in common.sh sni_router.sh; do
    printf '# PROXYALL_LIB=%s\ntouch /tmp/loaded\n' "$name" > "lib/$name"
    cp "lib/$name" "/usr/local/bin/lib/$name"
done
export PROXYALL_LIB_DIR=/tmp/lib _proxyall_lib_dir=/tmp/lib
export PROXYALL_WRITE_LOCK_FILE=/run/lock/blocked.lock
export PROXYALL_MAINTENANCE_DIR=/tmp/blocked
must_refuse() {
    if "$@" >/tmp/stdout 2>/tmp/stderr; then return 1; fi
    grep -Fq 'proxyall --install' /tmp/stderr
}
must_refuse bash /usr/local/bin/sb cleanup-logs
must_refuse bash /usr/local/bin/nginxproxy --install-command
[[ ! -e /tmp/loaded && ! -e /tmp/blocked && ! -e $PROXYALL_WRITE_LOCK_FILE ]]

mkdir /usr/local/lib/proxyall
cp /tmp/repo/lib/common.sh /usr/local/lib/proxyall/
must_refuse env PROXYALL_MANAGED=1 bash /usr/local/bin/sb setup-maintenance
[[ ! -e /tmp/blocked && ! -e $PROXYALL_WRITE_LOCK_FILE ]]
cp /tmp/repo/lib/sni_router.sh /usr/local/lib/proxyall/
# Entry and shared libraries only: maintenance works, node features ask for the second update.
PROXYALL_MANAGED=1 bash /usr/local/bin/sb setup-maintenance
must_refuse_update() {
    if "$@" >/tmp/stdout 2>/tmp/stderr; then return 1; fi
    grep -Fq 'proxyall --update' /tmp/stderr
}
must_refuse_update bash /usr/local/bin/sb sni-router api-version
cp /tmp/repo/lib/*.sh /usr/local/lib/proxyall/
chmod g+w /usr/local/lib/proxyall/common.sh
must_refuse bash /usr/local/bin/sb sni-router api-version
must_refuse bash /usr/local/bin/nginxproxy --version
chmod g-w /usr/local/lib/proxyall/common.sh
[[ $(bash /usr/local/bin/sb sni-router api-version) == 1 ]]
bash /usr/local/bin/nginxproxy --version
must_refuse bash /usr/local/bin/nginxproxy --install-command
cmp /tmp/repo/deploy.sh /usr/local/bin/nginxproxy
''', 'test', LEGACY], capture_output=True, text=True, timeout=20,
            env={'PATH': '/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('# Managed by proxyall log maintenance', result.stdout)
        self.assertIn('bash /usr/local/bin/sb cleanup-logs', result.stdout)

    def test_daemon_start_under_write_lock_does_not_inherit_lock_fds(self):
        cases = [
            ('sb-direct-nginx', r'''
source "$REPO/sb.sh"
command() {
    if [ "${1:-}" = -v ] && [[ "${2:-}" == systemctl || "${2:-}" == rc-service ]]; then return 1; fi
    builtin command "$@"
}
_sb_nginx_running() { return 1; }
nginx() {
    if [ "${1:-}" = -t ]; then return 0; fi
    sleep 30 >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$WORK/daemon.pid"
}
_sb_reload_or_start_nginx
'''),
            ('deploy-direct-nginx', r'''
source "$REPO/deploy.sh"
trap - ERR INT TERM
has_systemd() { return 1; }
command() {
    if [ "${1:-}" = -v ] && [[ "${2:-}" == systemctl || "${2:-}" == rc-service || "${2:-}" == service ]]; then return 1; fi
    builtin command "$@"
}
nginx_is_running() { return 1; }
nginx() {
    if [ "${1:-}" = -t ]; then return 0; fi
    sleep 30 >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$WORK/daemon.pid"
}
reload_or_start_nginx
'''),
            ('sni-router-apply', r'''
source "$REPO/sb.sh"
SNI_ROUTER_STATE_DIR="$WORK/router"
SNI_ROUTER_STATE_FILE="$WORK/router/state.json"
SNI_ROUTER_LOCK_FILE="$WORK/router.lock"
SNI_ROUTER_HAPROXY_CONF="$WORK/haproxy.cfg"
SNI_ROUTER_HAPROXY_BACKUP_DIR="$WORK/router-backup"
mkdir -p "$SNI_ROUTER_STATE_DIR" "$SNI_ROUTER_HAPROXY_BACKUP_DIR"
printf '{"version":1,"public_port":443,"reality":null,"https_backend":{"host":"127.0.0.1","port":8444},"https_routes":{"emby.test":{"owner":"nginx-proxy"}},"tls_routes":{}}\n' > "$SNI_ROUTER_STATE_FILE"
_sni_router_require_systemd() { return 0; }
haproxy() { return 0; }
systemctl() {
    case "$1" in
        is-active) return 1 ;;
        enable|reload|restart)
            sleep 30 >/dev/null 2>&1 &
            printf '%s\n' "$!" > "$WORK/daemon.pid"
            return 0 ;;
        *) return 0 ;;
    esac
}
_sni_router_apply
'''),
        ]
        for label, snippet in cases:
            with self.subTest(case=label):
                case_dir = self.work / label
                case_dir.mkdir()
                pid_file = case_dir / 'daemon.pid'
                write_lock = case_dir / 'write.lock'
                router_lock = case_dir / 'router.lock'
                script = (
                    'export PROXYALL_WRITE_LOCK_FILE="$WORK/write.lock"\n'
                    'source "$REPO/lib/common.sh"\n'
                    '_config_write_lock\n'
                    'exec 9>"$WORK/router.lock"\n'
                    'flock -x 9\n'
                    + snippet
                )
                result = subprocess.run(
                    ['bash', '-eu', '-o', 'pipefail', '-c', script],
                    cwd=case_dir, env=dict(os.environ, REPO=str(REPO), WORK=str(case_dir)),
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                pid = int(pid_file.read_text().strip())

                def cleanup_pid(target=pid):
                    try:
                        os.kill(target, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

                self.addCleanup(cleanup_pid)
                os.kill(pid, 0)
                self.assertFalse(Path(f'/proc/{pid}/fd/8').exists(), f'{label} daemon inherited FD 8')
                self.assertFalse(Path(f'/proc/{pid}/fd/9').exists(), f'{label} daemon inherited FD 9')

                # Subsequent lock acquisitions must succeed immediately without hitting the 30s timeout.
                start = time.monotonic()
                relock = subprocess.run(
                    ['bash', '-eu', '-o', 'pipefail', '-c', r'''
export PROXYALL_WRITE_LOCK_FILE="$WORK/write.lock"
source "$REPO/lib/common.sh"
flock -n "$WORK/write.lock" true
flock -n "$WORK/router.lock" true
_config_write_lock
'''],
                    cwd=case_dir, env=dict(os.environ, REPO=str(REPO), WORK=str(case_dir)),
                    capture_output=True, text=True, timeout=5,
                )
                elapsed = time.monotonic() - start
                self.assertEqual(relock.returncode, 0, relock.stdout + relock.stderr)
                self.assertLess(elapsed, 3.0)
                cleanup_pid()


if __name__ == '__main__':
    unittest.main(verbosity=2)
