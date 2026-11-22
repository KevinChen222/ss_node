#!/usr/bin/env bash
# PROXYALL_LIB=common.sh

# 所有组件固定先取配置写锁，再取 SNI/端口转发资源锁。
_config_write_lock() {
    local lock_file="${PROXYALL_WRITE_LOCK_FILE:-/run/lock/proxyall-config.lock}"
    if [ "${PROXYALL_WRITE_LOCK_HELD:-}" = "$lock_file" ] && [ /dev/fd/8 -ef "$lock_file" ]; then
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        if declare -F _pkg_install >/dev/null; then _pkg_install util-linux || return 1
        elif command -v apk >/dev/null 2>&1; then apk add --no-cache util-linux || return 1
        elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y util-linux || return 1
        else echo '请先安装 util-linux（flock）；拒绝无锁修改配置。' >&2; return 1; fi
        command -v flock >/dev/null 2>&1 || return 1
    fi
    mkdir -p "$(dirname "$lock_file")" || return 1
    exec 8>"$lock_file" || return 1
    flock -x -w 30 8 || { echo '配置正被其他管理进程修改，请稍后重试。' >&2; return 1; }
    export PROXYALL_WRITE_LOCK_HELD="$lock_file"
}

_proxyall_valid_ipv4() {
    local address=$1 octet
    local -a octets=()
    [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

_proxyall_require_bundle_install() {
    printf '%s\n' '管理脚本与配套库必须一起安装或更新。请运行 proxyall --install 或 proxyall --update，或在 proxyall 主菜单检查脚本更新。' >&2
    return 1
}
