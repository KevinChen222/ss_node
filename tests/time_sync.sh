#!/usr/bin/env bash
set -eo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/sb.sh"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

command() {
    if [ "${1:-}" = -v ]; then
        case "$2" in
            timedatectl|ntpdate|chronyd) [ "$2" = "$test_backend" ]; return ;;
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
        -s) printf 'date %s\n' "$2" >> "$test_calls"; return "$test_sync_status" ;;
        *) printf '2026-10-17 08:07:00\n' ;;
    esac
}

timedatectl() { printf 'timedatectl %s\n' "$*" >> "$test_calls"; return "$test_sync_status"; }
ntpdate() { printf 'ntpdate %s\n' "$*" >> "$test_calls"; return "$test_sync_status"; }
chronyd() { printf 'chronyd %s\n' "$*" >> "$test_calls"; return "$test_sync_status"; }
curl() { printf 'date: Sat, 17 Oct 2026 08:07:00 GMT\r\n'; }
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
    assert_contains "$test_calls" 'ntpdate -u pool.ntp.org'
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
    assert_empty "$test_calls"
    assert_empty "$test_cron"
}

test_cli() {
    (
        _check_root() { printf 'root-check\n' >> "$test_calls"; }
        main() { return 99; }
        set -- sync-time
        eval "$(sed -n '/^if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]; then/,$p' "$repo_dir/sb.sh")"
    ) < /dev/null
    assert_contains "$test_calls" 'root-check'
    assert_contains "$test_calls" 'ntpdate -u pool.ntp.org'
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

for test_name in accept decline replace_and_preserve sync_failure missing_cron cron_failure remove backends automatic_sync cli script_path; do
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
