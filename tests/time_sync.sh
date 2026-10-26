#!/usr/bin/env bash
set -eo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/sb.sh"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

command() {
    if [ "${1:-}" = -v ]; then
        case "$2" in
            timedatectl|ntpdate|chronyd|chronyc|curl)
                [[ " ${test_available:-$test_backend curl} " == *" $2 "* ]]; return ;;
            crontab) [ "$test_has_cron" = yes ]; return ;;
        esac
    fi
    builtin command "$@"
}

date() {
    case "${1:-}" in
        +%Y) printf '2026\n' ;;
        '+%M %H') printf '07 08\n' ;;
        +%H:%M) printf '08:07\n' ;;
        +%s) printf '1793000000\n' ;;
        -u) /bin/date "$@" ;;
        -s)
            printf 'date %s\n' "$2" >> "$test_calls"
            [ "${test_date_status:-$test_sync_status}" = 0 ] || { echo 'date: Operation not permitted' >&2; return 1; }
            ;;
        *) printf '2026-10-17 08:07:00\n' ;;
    esac
}

timedatectl() {
    printf 'timedatectl %s\n' "$*" >> "$test_calls"
    if [ "$1" = show ]; then
        if [ "${test_sync_after:-0}" -gt 0 ] && [ "$(grep -c '^timedatectl show' "$test_calls")" -ge "$test_sync_after" ]; then
            echo yes
        else
            printf '%s\n' "${test_ntp_synced:-yes}"
        fi
        return 0
    fi
    [ "${test_timedatectl_status:-$test_sync_status}" = 0 ] || { echo 'Failed to set ntp: NTP not supported' >&2; return 1; }
}
ntpdate() { printf 'ntpdate %s\n' "$*" >> "$test_calls"; return "${test_ntpdate_status:-$test_sync_status}"; }
chronyd() { printf 'chronyd %s\n' "$*" >> "$test_calls"; return "${test_chronyd_status:-$test_sync_status}"; }
chronyc() { printf 'chronyc %s\n' "$*" >> "$test_calls"; return "${test_chronyc_status:-$test_sync_status}"; }
sleep() { printf 'sleep %s\n' "$*" >> "$test_calls"; }
curl() {
    printf 'curl %s\n' "$*" >> "$test_calls"
    if [ "${test_curl_status:-0}" != 0 ] || [[ "${@: -1}" == "${test_http_fail_url:-NONE}"* ]]; then
        echo 'curl: Failed to connect' >&2
        return 1
    fi
    printf '%s\r\n' "${test_http_header-date: Sat, 17 Oct 2026 08:07:00 GMT}"
}
crontab() {
    case "$1" in
        -l) [ -f "$test_cron" ] && cat "$test_cron" ;;
        -)
            if [ "$test_cron_status" != 0 ]; then cat > /dev/null; return "$test_cron_status"; fi
            cat > "$test_cron"
            ;;
        *) return 2 ;;
    esac
}

assert_contains() { grep -Fq -- "$2" "$1"; }
assert_empty() { [ ! -s "$1" ]; }

test_accept() {
    _sync_system_time_interactive <<< y
    assert_contains "$test_calls" 'ntpdate -u -t 5 pool.ntp.org'
    assert_contains "$test_cron" '07 08 * * * bash '
    assert_contains "$test_cron" ' sync-time >/dev/null 2>&1 # sing-box-time-sync'
}

test_decline() {
    local answer
    for answer in n ''; do
        _sync_system_time_interactive <<< "$answer"
        assert_empty "$test_cron"
    done
    _sync_system_time_interactive < /dev/null
    assert_empty "$test_cron"
}

test_replace_and_preserve() {
    printf '5 1 * * * backup\n0 2 * * * old sync-time # sing-box-time-sync\n' > "$test_cron"
    _sync_system_time_interactive <<< YES
    _sync_system_time_interactive <<< yes
    assert_contains "$test_cron" '5 1 * * * backup'
    [ "$(grep -Fc '# sing-box-time-sync' "$test_cron")" = 1 ]
    ! grep -Fq 'old sync-time' "$test_cron"
    local before
    before=$(cat "$test_cron")
    _sync_system_time_interactive <<< n
    [ "$before" = "$(cat "$test_cron")" ]
}

test_sync_failure() {
    test_sync_status=1
    if _sync_system_time_interactive <<< y; then return 1; fi
    assert_empty "$test_cron"
}

test_missing_cron() {
    test_has_cron=no
    if _sync_system_time_interactive <<< y; then return 1; fi
    assert_empty "$test_cron"
}

test_cron_failure() {
    test_cron_status=1
    if _sync_system_time_interactive <<< y; then return 1; fi
    assert_empty "$test_cron"
}

test_remove() {
    _setup_time_sync
    _remove_time_sync
    ! grep -Fq '# sing-box-time-sync' "$test_cron"
    printf '5 1 * * * backup\n' > "$test_cron"
    _setup_time_sync
    _remove_time_sync
    [ "$(cat "$test_cron")" = '5 1 * * * backup' ]
    _remove_time_sync
}

test_backends() {
    for test_backend in timedatectl ntpdate chronyd https; do
        : > "$test_calls"
        _sync_system_time true < /dev/null
        [ -s "$test_calls" ]
        assert_empty "$test_cron"
        test_sync_status=1
        if _sync_system_time true; then return 1; fi
        test_sync_status=0
    done
}

test_automatic_sync() {
    _sync_system_time < /dev/null
    assert_contains "$test_calls" 'ntpdate -u -t 5 pool.ntp.org'
    assert_empty "$test_cron"
}

test_automatic_synced() {
    test_available='timedatectl ntpdate curl'
    _sync_system_time
    assert_contains "$test_calls" 'timedatectl show'
    ! grep -q 'set-ntp\|^ntpdate\|^curl ' "$test_calls"
}

test_automatic_unconfirmed() {
    test_available='timedatectl ntpdate curl'
    test_ntp_synced=no
    _sync_system_time
    assert_contains "$test_calls" 'ntpdate -u -t 5 pool.ntp.org'
}

test_cli() {
    (
        _check_root() { printf 'root-check\n' >> "$test_calls"; }
        main() { return 99; }
        set -- sync-time
        eval "$(sed -n '/^if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]; then/,$p' "$repo_dir/sb.sh")"
    ) < /dev/null
    assert_contains "$test_calls" 'root-check'
    assert_contains "$test_calls" 'ntpdate -u -t 5 pool.ntp.org'
    assert_empty "$test_cron"
}

test_script_path() {
    SELF_SCRIPT_PATH="$test_dir/a b'c%script.sh"
    _setup_time_sync
    local job
    job=$(cat "$test_cron")
    assert_contains "$test_cron" '\%'
    job=${job#* * * * * }
    job=${job//\\%/%}
    bash() { [ "$1" = "$SELF_SCRIPT_PATH" ] && [ "$2" = sync-time ]; }
    eval "$job"
}

test_systemd_failure_ntpdate() {
    test_available='timedatectl ntpdate curl'
    test_timedatectl_status=1
    _sync_system_time_interactive <<< y
    assert_contains "$test_calls" 'ntpdate -u -t 5 pool.ntp.org'
    assert_contains "$test_cron" '# sing-box-time-sync'
    ! grep -q '^curl ' "$test_calls"
}

test_systemd_failure_https() {
    test_available='timedatectl curl'
    test_timedatectl_status=1
    _sync_system_time_interactive <<< y
    assert_contains "$test_calls" 'date Sat, 17 Oct 2026 08:07:00 GMT'
    assert_contains "$test_cron" '# sing-box-time-sync'
}

test_systemd_unconfirmed() {
    test_available='timedatectl curl'
    test_ntp_synced=no
    _sync_system_time true
    assert_contains "$test_calls" 'timedatectl show'
    assert_contains "$test_calls" 'date Sat, 17 Oct 2026 08:07:00 GMT'
}

test_systemd_delayed_confirmation() {
    test_backend=timedatectl
    test_ntp_synced=no
    test_sync_after=2
    _sync_system_time true
    [ "$(grep -c '^timedatectl show' "$test_calls")" = 2 ]
    ! grep -q '^curl ' "$test_calls"
}

test_ntpdate_failure_chronyd() {
    test_available='ntpdate chronyd curl'
    test_ntpdate_status=1
    _sync_system_time true
    assert_contains "$test_calls" "chronyd -q -t 10 server pool.ntp.org iburst"
    ! grep -q '^curl ' "$test_calls"
}

test_chrony_daemon() {
    test_available='chronyc chronyd curl'
    _sync_system_time true
    assert_contains "$test_calls" 'chronyc -m makestep 0.1 1 burst 1/2 waitsync 5 0.1 0 1'
    ! grep -q '^chronyd\|^curl ' "$test_calls"
}

test_chronyc_failure_chronyd() {
    test_available='chronyc chronyd curl'
    test_chronyc_status=1
    _sync_system_time true
    assert_contains "$test_calls" 'chronyd -q -t 10'
}

test_https_provider_fallback() {
    test_backend=https
    test_http_fail_url=https://www.google.com
    _sync_system_time true
    assert_contains "$test_calls" 'https://www.cloudflare.com'
    assert_contains "$test_calls" 'date Sat, 17 Oct 2026 08:07:00 GMT'
}

test_https_fresh_request() {
    test_backend=https
    _sync_system_time true
    assert_contains "$test_calls" "--noproxy *"
    assert_contains "$test_calls" "Cache-Control: no-cache, no-store"
    assert_contains "$test_calls" '/?sb_time='
}

test_https_cached_date() {
    test_backend=https
    test_http_header=$'date: Sat, 17 Oct 2026 08:07:00 GMT\r\nAge: 600'
    if _sync_system_time true; then return 1; fi
    ! grep -q '^date ' "$test_calls"
    assert_contains "$test_calls" 'https://www.cloudflare.com'
}

test_https_invalid_date() {
    test_backend=https
    test_http_header='date: invalid'
    if _sync_system_time true; then return 1; fi
    ! grep -q '^date ' "$test_calls"
}

test_https_missing_date() {
    test_backend=https
    test_http_header='HTTP/2 200'
    if _sync_system_time true; then return 1; fi
    ! grep -q '^date ' "$test_calls"
}

test_https_network_failure() {
    test_backend=https
    test_curl_status=1
    if _sync_system_time true; then return 1; fi
    ! grep -q '^date ' "$test_calls"
}

test_failure_diagnostics() {
    test_available='timedatectl curl'
    test_timedatectl_status=1
    test_date_status=1
    if _sync_system_time_interactive <<< y > "$test_dir/diagnostics" 2>&1; then return 1; fi
    assert_contains "$test_dir/diagnostics" 'NTP not supported'
    assert_contains "$test_dir/diagnostics" 'Operation not permitted'
    assert_empty "$test_cron"
}

for test_name in accept decline replace_and_preserve sync_failure missing_cron cron_failure remove backends automatic_sync automatic_synced automatic_unconfirmed cli script_path systemd_failure_ntpdate systemd_failure_https systemd_unconfirmed systemd_delayed_confirmation ntpdate_failure_chronyd chrony_daemon chronyc_failure_chronyd https_provider_fallback https_fresh_request https_cached_date https_invalid_date https_missing_date https_network_failure failure_diagnostics; do
    [ -z "${TIME_SYNC_TEST_FILTER:-}" ] || [ "$test_name" = "$TIME_SYNC_TEST_FILTER" ] || continue
    (
        test_backend=ntpdate
        test_has_cron=yes
        test_sync_status=0
        test_cron_status=0
        test_cron="$test_dir/$test_name.cron"
        test_calls="$test_dir/$test_name.calls"
        INIT_SYSTEM=systemd
        "test_$test_name"
    )
    printf 'PASS %s\n' "$test_name"
done
