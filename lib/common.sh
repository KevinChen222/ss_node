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

# sb 与 nginxproxy 安装的 acme.sh 固定为同一版本与归档哈希。
PROXYALL_ACME_VERSION='3.1.2'
PROXYALL_ACME_ARCHIVE_SHA256='a51511ad0e2912be45125cf189401e4ae776ca1a29d5768f020a1e35a9560186'

_proxyall_require_bundle_install() {
    printf '%s\n' '管理脚本与配套库必须一起安装或更新。请运行 proxyall --install 或 proxyall --update，或在 proxyall 主菜单检查脚本更新。' >&2
    return 1
}

# 以下为 sb 与中转模块共用的输出、系统与下载工具。deploy.sh 加载后会以自身定义覆盖颜色变量。
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
ORANGE='\033[0;33m'

# 打印消息函数
_info() { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() {
    if [ -n "${NODE_TX_DIR:-}" ] && [ "${NODE_TX_COMMITTED:-0}" != 1 ]; then return 0; fi
    echo -e "${GREEN}[成功] $1${NC}" >&2
}
_warn() { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_warning() { _warn "$1"; } # 别名兼容
_error() { echo -e "${RED}[错误] $1${NC}" >&2; }

# 检查 root 权限
_check_root() {
    if [[ $EUID -ne 0 ]]; then
        _error "此脚本必须以 root 权限运行。"
        exit 1
    fi
}

# 编解码器 (纯 Bash 稳健实现)
_url_decode() {
    local data="$1" result="" hex decoded
    while [ -n "$data" ]; do
        if [ "${data:0:1}" = "%" ] && [[ "${data:1:2}" =~ ^[0-9A-Fa-f]{2}$ ]]; then
            hex="${data:1:2}"
            printf -v decoded '%b' "\\x${hex}"
            result+="$decoded"
            data="${data:3}"
        else
            result+="${data:0:1}"
            data="${data:1}"
        fi
    done
    printf '%s' "$result"
}
_url_encode() {
    # [修复] 使用 jq 内建 @uri 过滤器，完美处理 UTF-8 多字节字符
    # jq 是必装依赖，@uri 以字节为单位执行标准 percent-encoding
    printf '%s' "$1" | jq -sRr @uri
}

_cert_sha256_hex() {
    local cert_path="$1"
    [ -f "$cert_path" ] || return 1
    openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null | \
        awk -F= 'NR==1 { gsub(":", "", $2); print tolower($2) }'
}

# 公网 IP 获取 (带全局缓存)
_get_public_ip() {
    [ -n "$server_ip" ] && [ "$server_ip" != "null" ] && { echo "$server_ip"; return; }
    local ip=$(timeout 5 curl -fsS4 --max-time 2 https://icanhazip.com 2>/dev/null || timeout 5 curl -fsS4 --max-time 2 https://ipinfo.io/ip 2>/dev/null)
    [ -z "$ip" ] && ip=$(timeout 5 curl -fsS6 --max-time 2 https://icanhazip.com 2>/dev/null || timeout 5 curl -fsS6 --max-time 2 https://ipinfo.io/ip 2>/dev/null)
    ip=$(printf '%s' "$ip" | tr -d '\r\n ')
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ ! "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
        _error "无法获取有效的公网 IP，请稍后重试或在创建节点时手动输入。"
        return 1
    fi
    server_ip="$ip"
    echo "$ip"
}

_is_valid_ipv4() { _proxyall_valid_ipv4 "$@"; }

_ipv4_to_int() {
    local a b c d
    _is_valid_ipv4 "$1" || return 1
    IFS='.' read -r a b c d <<< "$1"
    printf '%u\n' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

_ipv4_in_cidr() {
    local ip_int network_int prefix mask
    ip_int=$(_ipv4_to_int "$1") || return 1
    network_int=$(_ipv4_to_int "${2%/*}") || return 1
    prefix="${2#*/}"
    [ "$prefix" -ge 0 ] 2>/dev/null && [ "$prefix" -le 32 ] 2>/dev/null || return 1
    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    [ $((ip_int & mask)) -eq $((network_int & mask)) ]
}

_version_at_least() {
    local current="${1#go}" required="${2#go}"
    [ -n "$current" ] && [ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n 1)" = "$required" ]
}

# 系统环境检测
_detect_init_system() {
    if [ -f /sbin/openrc-run ] || command -v rc-service &>/dev/null; then
        export INIT_SYSTEM="openrc"
        export SERVICE_FILE="/etc/init.d/sing-box"
    elif command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        export INIT_SYSTEM="systemd"
        export SERVICE_FILE="/etc/systemd/system/sing-box.service"
    else
        export INIT_SYSTEM="direct"
        export SERVICE_FILE=""
    fi
}

# 端口占用检查
_check_port_occupied() {
    local port=$1
    local proto=${2:-tcp}
    if [[ "$proto" == "tcp" ]]; then
        if command -v ss &>/dev/null; then
            ss -lnpt | grep -q ":${port} " && return 0
        else
            netstat -lnpt | grep -q ":${port} " && return 0
        fi
    else
        if command -v ss &>/dev/null; then
            ss -lnpu | grep -q ":${port} " && return 0
        else
            netstat -lnpu | grep -q ":${port} " && return 0
        fi
    fi
    return 1
}

_is_pid_running_cmd() {
    local pid="$1"
    local pattern="$2"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Fq "$pattern"
    else
        ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$pattern"
    fi
}

_is_pid_file_running_cmd() {
    local pid_file="$1"
    local pattern="$2"
    local pid
    [ -s "$pid_file" ] || return 1
    pid=$(cat "$pid_file" 2>/dev/null)
    _is_pid_running_cmd "$pid" "$pattern"
}

# 智能包管理
_pkg_install() {
    local pkgs="$*" verbose="${SB_PKG_VERBOSE:-0}"
    [ -z "$pkgs" ] && return 0
    if command -v apk &>/dev/null; then
        if [ "$verbose" = 1 ]; then apk add --no-cache $pkgs; else apk add --no-cache $pkgs >/dev/null 2>&1; fi
    elif command -v apt-get &>/dev/null; then
        # 全新 LXC/容器上 apt 缓存可能为空，必须先 update
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls -A /var/lib/apt/lists/ 2>/dev/null | wc -l)" -le 1 ]; then
            if [ "$verbose" = 1 ]; then apt-get update; else apt-get update -qq >/dev/null 2>&1; fi
        fi
        if [ "$verbose" = 1 ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs || {
                apt-get update
                DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
            }
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || {
                # 兜底：如果安装失败，强制刷新索引后重试
                apt-get update -qq >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
            }
        fi
    elif command -v yum &>/dev/null; then
        if [ "$verbose" = 1 ]; then yum install -y $pkgs; else yum install -y $pkgs >/dev/null 2>&1; fi
    elif command -v dnf &>/dev/null; then
        if [ "$verbose" = 1 ]; then dnf install -y $pkgs; else dnf install -y $pkgs >/dev/null 2>&1; fi
    else
        return 1
    fi
}
_node_cancel() {
    [ -z "${NODE_TX_DIR:-}" ] || touch "$NODE_TX_DIR/cancelled"
    return 2
}

# 交互取消通过标记跨命令替换传递，不与配置失败混淆。
_node_read() {
    local result=0 variable="${@: -1}"
    builtin read "$@" || result=$?
    if [ "${NODE_UI:-false}" = true ] && { [ "$result" != 0 ] || [ "${!variable}" = 0 ]; }; then
        _node_cancel
        return 2
    fi
    return "$result"
}

_node_read_yes_no() {
    local prompt="$1" destination="$2"
    while true; do
        _node_read -r -p "$prompt" "$destination" || return $?
        case "${!destination}" in ''|y|Y|n|N) return 0 ;; esac
        _error '请输入 y、n，或按提示返回。'
    done
}

# 保留兼容入口；不主动写 drop_caches，避免影响同机其他服务的缓存与延迟。
_release_install_cache() {
    return 0
}

# 从 GitHub Release API 获取官方资产，并核对 GitHub 提供的 SHA256 digest。
_download_verified_github_asset() {
    local api_url="$1"
    local asset_name="$2"
    local destination="$3"
    local release_info asset_info download_url digest expected actual

    release_info=$(curl -fLsS --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: singbox-lite-kevin' \
        "$api_url") || {
        _error "无法读取 GitHub Release 信息: ${api_url}"
        return 1
    }

    asset_info=$(printf '%s' "$release_info" | jq -r --arg name "$asset_name" \
        '.assets[] | select(.name == $name) | [.browser_download_url, (.digest // "")] | @tsv' | head -n 1)
    IFS=$'\t' read -r download_url digest <<< "$asset_info"
    if [ -z "$download_url" ] || [[ "$digest" != sha256:* ]]; then
        _error "Release 中缺少资产或 SHA256 digest: ${asset_name}"
        return 1
    fi

    expected="${digest#sha256:}"
    if ! wget -qO "$destination" "$download_url"; then
        _error "下载失败: ${asset_name}"
        rm -f "$destination"
        return 1
    fi

    actual=$(sha256sum "$destination" 2>/dev/null | awk '{print $1}')
    if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
        _error "SHA256 校验失败，已拒绝安装: ${asset_name}"
        rm -f "$destination"
        return 1
    fi
    return 0
}

# 安装 yq
_install_yq() {
    if [ ! -x "$YQ_BINARY" ]; then
        _info "安装 yq..."
        local arch=$(uname -m)
        case $arch in x86_64|amd64) arch='amd64' ;; aarch64|arm64) arch='arm64' ;; *) arch='amd64' ;; esac
        local asset_name="yq_linux_${arch}"
        _download_verified_github_asset \
            "https://api.github.com/repos/mikefarah/yq/releases/latest" \
            "$asset_name" "$YQ_BINARY" || return 1
        chmod 700 "$YQ_BINARY"
        if ! "$YQ_BINARY" --version 2>/dev/null | grep -q 'version v4\.'; then
            _error "下载的 yq 版本不符合 v4 要求，已拒绝使用。"
            rm -f "$YQ_BINARY"
            return 1
        fi
        touch "${SINGBOX_DIR}/.managed_yq"
    fi
}
