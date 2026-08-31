#!/bin/bash

# SB_MANAGER_MANAGED_COMMAND=1

# 所有运行时配置、节点凭据和私钥默认仅允许 root 读取。
umask 077

# 基础路径定义
export SCRIPT_VERSION="20-kevin.19"
export DEFAULT_SNI="www.icloud.com"
export DEFAULT_REALITY_SNI="www.amd.com"
export WS_EARLY_DATA_SIZE="2560"
export WS_EARLY_DATA_HEADER="Sec-WebSocket-Protocol"
SELF_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF_SCRIPT_PATH")"
SB_QUICK_COMMAND_PATH="/usr/local/bin/sb"
SB_QUICK_COMMAND_MARKER="# SB_MANAGER_MANAGED_COMMAND=1"
SINGBOX_DIR="/usr/local/etc/sing-box"
# 主脚本与可选中转组件均从用户自己的同一仓库更新，并用固定哈希校验。
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/KevinChen222/ss_node/main/sb.sh"
COMPONENT_RAW_BASE="https://raw.githubusercontent.com/KevinChen222/ss_node/main"
ADVANCED_RELAY_SHA256="c729615d6ee272c2b1fb74e1c5753416d2237e2e18ebfc7fa6c3bc826992ccbc"
PARSER_SHA256="33edfbb4dc2dd2724d950b0608ae3c910db859f21701fd0e9ec8e09c2d438f31"
REALITL_SCANNER_VERSION="v0.2.3"
REALITL_SCANNER_RELEASE_BASE="https://github.com/XTLS/RealiTLScanner/releases/download/${REALITL_SCANNER_VERSION}"
REALITL_SCANNER_AMD64_SHA256="a55595446de9f1c2e6c5c3cd766a7320a11115947df48f101749bb62c8055592"
REALITL_SCANNER_ARM64_SHA256="27bdd3e53d4391c66c8df3391d3c3fb5eb2dc356125f2fb33ac58fcaaf8f88b3"
REALITL_SCANNER_DIR="/usr/local/lib/singbox-lite"
REALITL_SCANNER_BIN="${REALITL_SCANNER_DIR}/RealiTLScanner"
REALITL_SCANNER_MARKER="${REALITL_SCANNER_DIR}/RealiTLScanner.release"
REALITY_SNI_MAX_SCAN_TARGETS=512
# 基于 3x-ui 当前内置 Reality 扫描种子；www.cloudflare.com 因既有非 Cloudflare 规则省略。
REALITY_SNI_SEED_DOMAINS=(
    "www.microsoft.com"
    "www.amazon.com"
    "aws.amazon.com"
    "www.samsung.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.intel.com"
    "www.sony.com"
    "dl.google.com"
)
GREATFIRE_API_BASE="https://zh.greatfire.org"
GO_MIN_VERSION="1.21"
GO_TOOLCHAIN_DIR="${REALITL_SCANNER_DIR}/go-toolchain"
GO_TOOLCHAIN_MARKER="${GO_TOOLCHAIN_DIR}/.managed-by-singbox-lite"

# 单机自有域名模式与 nginx_proxy/deploy.sh 使用相同的 Nginx/证书目录结构。
REALITY_LOCAL_ORIGIN_HOST="127.0.0.1"
REALITY_LOCAL_ORIGIN_PORT=8443
SB_ROOT_HOME="$(awk -F: '$3 == 0 {print $6; exit}' /etc/passwd 2>/dev/null || true)"
SB_ROOT_HOME="${SB_ROOT_HOME:-/root}"
NGINX_ROOT="/etc/nginx"
NGINX_MAIN_CONF="${NGINX_ROOT}/nginx.conf"
NGINX_CONF_DIR="${NGINX_ROOT}/conf.d"
NGINX_CERT_DIR="${NGINX_ROOT}/certs"
NGINX_BACKUP_DIR="${NGINX_ROOT}/backup"
ACME_WEBROOT="/var/www/acme-challenge"
SB_ACME_HOME="${SB_ROOT_HOME}/.acme.sh"
SB_ACME_SH="${SB_ACME_HOME}/acme.sh"
SB_ACME_VERSION="3.1.2"
SB_ACME_ARCHIVE_SHA256="a51511ad0e2912be45125cf189401e4ae776ca1a29d5768f020a1e35a9560186"
SB_ACME_ARCHIVE_URL="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${SB_ACME_VERSION}.tar.gz"
SB_ACME_RELOAD_CMD='if [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s reload; elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx; elif command -v service >/dev/null 2>&1 && service nginx start; then :; else nginx; fi'

# HAProxy SNI 共享入口。HAProxy 只负责 TCP ClientHello 分流，不终止 TLS。
SNI_ROUTER_API_VERSION=1
SNI_ROUTER_PUBLIC_PORT=443
SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT=2443
SNI_ROUTER_HTTPS_BACKEND_PORT=8444
SNI_ROUTER_STATE_DIR="${SNI_ROUTER_STATE_DIR:-/var/lib/sb-sni-router}"
SNI_ROUTER_STATE_FILE="${SNI_ROUTER_STATE_FILE:-${SNI_ROUTER_STATE_DIR}/state.json}"
SNI_ROUTER_LOCK_FILE="${SNI_ROUTER_LOCK_FILE:-/run/lock/sb-sni-router.lock}"
SNI_ROUTER_HAPROXY_CONF="${SNI_ROUTER_HAPROXY_CONF:-/etc/haproxy/haproxy.cfg}"
SNI_ROUTER_HAPROXY_BACKUP_DIR="${SNI_ROUTER_HAPROXY_BACKUP_DIR:-/etc/haproxy/backup}"
SNI_ROUTER_MARKER="# Managed by singbox-lite SNI router"

# --- 核心工具函数 ---

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
ORANGE='\033[0;33m'

# 打印消息函数
_info() { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
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

_ensure_quick_command() {
    local source_path="$SELF_SCRIPT_PATH" source_real target_real install_tmp

    if [ ! -f "$source_path" ]; then
        _warn "当前脚本不是普通本地文件，已跳过自动安装 sb 快捷命令。"
        _warn "请先下载 sb.sh 并执行 bash -n sb.sh，再运行该本地文件。"
        return 0
    fi
    if ! grep -Fqx -- "$SB_QUICK_COMMAND_MARKER" "$source_path" || ! bash -n "$source_path"; then
        _warn "当前脚本缺少管理标记或语法校验失败，已跳过自动安装 sb 快捷命令。"
        return 0
    fi

    source_real=$(readlink -f -- "$source_path" 2>/dev/null || printf '%s\n' "$source_path")
    if [ -L "$SB_QUICK_COMMAND_PATH" ]; then
        _warn "sb 快捷命令路径是符号链接，已保留原目标: ${SB_QUICK_COMMAND_PATH}"
        return 0
    fi
    if [ -e "$SB_QUICK_COMMAND_PATH" ]; then
        target_real=$(readlink -f -- "$SB_QUICK_COMMAND_PATH" 2>/dev/null || printf '%s\n' "$SB_QUICK_COMMAND_PATH")
        if [ "$source_real" = "$target_real" ]; then
            chmod 700 -- "$SB_QUICK_COMMAND_PATH" 2>/dev/null || true
            return 0
        fi
        if [ ! -f "$SB_QUICK_COMMAND_PATH" ] || ! grep -Fqx -- "$SB_QUICK_COMMAND_MARKER" "$SB_QUICK_COMMAND_PATH"; then
            _warn "${SB_QUICK_COMMAND_PATH} 已被其他文件占用，拒绝覆盖；deploy.sh 将无法调用本脚本的 SNI 路由接口。"
            return 0
        fi
    fi

    install_tmp=$(mktemp "${SB_QUICK_COMMAND_PATH}.tmp.XXXXXXXXXX") || return 1
    if ! install -m 700 -- "$source_path" "$install_tmp" || ! mv -f -- "$install_tmp" "$SB_QUICK_COMMAND_PATH"; then
        rm -f -- "$install_tmp"
        _warn "安装 sb 快捷命令失败；本次管理仍可继续，但暂不能保证与 deploy.sh 自动协作。"
        return 0
    fi
    SELF_SCRIPT_PATH="$SB_QUICK_COMMAND_PATH"
    SCRIPT_DIR="$(dirname "$SELF_SCRIPT_PATH")"
    _success "sb 快捷命令已就绪: ${SB_QUICK_COMMAND_PATH}"
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

_ws_path_with_early_data() {
    local ws_path="${1:-/}"
    if [[ "$ws_path" == *"ed="* ]]; then
        printf '%s' "$ws_path"
        return
    fi
    if [[ "$ws_path" == *"?"* ]]; then
        printf '%s&ed=%s' "$ws_path" "$WS_EARLY_DATA_SIZE"
    else
        printf '%s?ed=%s' "$ws_path" "$WS_EARLY_DATA_SIZE"
    fi
}

_cert_sha256_hex() {
    local cert_path="$1"
    [ -f "$cert_path" ] || return 1
    openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null | \
        awk -F= 'NR==1 { gsub(":", "", $2); print tolower($2) }'
}

_tls_insecure_params() {
    local skip_verify="$1"
    local cert_path="$2"
    local insecure_param=""
    if [[ "$skip_verify" == "true" ]]; then
        insecure_param="&insecure=1"
        local cert_pcs=$(_cert_sha256_hex "$cert_path")
        [ -n "$cert_pcs" ] && insecure_param="${insecure_param}&pcs=${cert_pcs}"
    fi
    printf '%s' "$insecure_param"
}

_append_pcs_to_tls_link() {
    local url="$1"
    local cert_path="$2"
    [ -n "$url" ] || return 0
    [[ "$url" == *"pcs="* ]] && { printf '%s' "$url"; return 0; }

    local cert_pcs=$(_cert_sha256_hex "$cert_path")
    [ -n "$cert_pcs" ] || { printf '%s' "$url"; return 0; }

    local body="$url"
    local fragment=""
    if [[ "$url" == *"#"* ]]; then
        body="${url%%#*}"
        fragment="#${url#*#}"
    fi

    local sep="&"
    [[ "$body" != *"?"* ]] && sep="?"
    printf '%s%s%s%s' "$body" "$sep" "pcs=${cert_pcs}" "$fragment"
}

_ss_base64_encode() {
    # Shadowsocks SIP002 规范要求 Base64 编码不带填充 (No Padding)
    printf '%s' "$1" | base64 | tr -d '\n\r ' | sed 's/=//g'
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
_get_ip() { _get_public_ip; } # 别名兼容

# Reality SNI 与握手目标必须分开保存：扫描结果是“证书域名 + 邻居 IP”。
REALITY_SNI_SCAN_DONE=false
REALITY_SNI_DOMAINS=()
REALITY_SNI_LATENCIES=()
REALITY_SNI_TARGETS=()
REALITY_SNI_CHINA_STATUSES=()
SELECTED_REALITY_SNI="$DEFAULT_REALITY_SNI"
SELECTED_REALITY_HANDSHAKE_SERVER="$DEFAULT_REALITY_SNI"
SELECTED_REALITY_HANDSHAKE_PORT=443
REALITY_PROBE_ERROR=""
REALITY_PROBE_LATENCY=""
REALITY_PROBE_HTTP_STATUS=""
REALITY_CHINA_CHECK_ENABLED=false
GREATFIRE_RESULT_CODE=2
GREATFIRE_RESULT_LABEL="未验证"
GREATFIRE_RESULT_LAST_TESTED=""
GREATFIRE_CACHE_DOMAINS=()
GREATFIRE_CACHE_CODES=()
GREATFIRE_CACHE_LABELS=()
GREATFIRE_CACHE_LAST_TESTED=()

_is_valid_ipv4() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    for a in "$a" "$b" "$c" "$d"; do
        [ "$((10#$a))" -le 255 ] 2>/dev/null || return 1
    done
}

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

_is_cloudflare_ipv4() {
    local ip="$1" cidr
    local ranges=(
        "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22"
        "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20"
        "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
        "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22"
    )
    for cidr in "${ranges[@]}"; do
        _ipv4_in_cidr "$ip" "$cidr" && return 0
    done
    return 1
}

_target_uses_cloudflare() {
    local target="$1" ip
    if _is_valid_ipv4 "$target"; then
        _is_cloudflare_ipv4 "$target"
        return
    fi
    while read -r ip; do
        [ -z "$ip" ] && continue
        _is_cloudflare_ipv4 "$ip" && return 0
    done < <(getent ahostsv4 "$target" 2>/dev/null | awk '{print $1}' | sort -u)
    return 1
}

_is_valid_reality_domain() {
    local domain="${1,,}" label
    local labels=()
    [ "${#domain}" -le 253 ] || return 1
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != *..* && "$domain" != .* && "$domain" != *. && "$domain" != *"*"* ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
    return 0
}

_version_at_least() {
    local current="${1#go}" required="${2#go}"
    [ -n "$current" ] && [ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n 1)" = "$required" ]
}

_go_version_for_bin() {
    local go_bin="$1"
    "$go_bin" env GOVERSION 2>/dev/null | sed -E 's/^go//; s/(rc|beta).*//'
}

_find_compatible_go() {
    local go_bin go_version
    if [ -x "$GO_TOOLCHAIN_DIR/bin/go" ] && [ -f "$GO_TOOLCHAIN_MARKER" ]; then
        go_version=$(_go_version_for_bin "$GO_TOOLCHAIN_DIR/bin/go")
        if _version_at_least "$go_version" "$GO_MIN_VERSION"; then
            printf '%s\n' "$GO_TOOLCHAIN_DIR/bin/go"
            return 0
        fi
    fi
    if command -v go >/dev/null 2>&1; then
        go_bin=$(command -v go)
        go_version=$(_go_version_for_bin "$go_bin")
        if _version_at_least "$go_version" "$GO_MIN_VERSION"; then
            printf '%s\n' "$go_bin"
            return 0
        fi
    fi
    return 1
}

_install_managed_go_toolchain() {
    local machine go_arch metadata entry go_version filename expected_sha
    local temp_dir archive extracted_version new_dir backup_dir=""
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64) go_arch="amd64" ;;
        aarch64|arm64) go_arch="arm64" ;;
        i386|i486|i586|i686) go_arch="386" ;;
        armv6l|armv7l) go_arch="armv6l" ;;
        *) _error "官方 Go 工具链暂不支持此架构: ${machine}"; return 1 ;;
    esac

    _pkg_install curl jq tar ca-certificates coreutils git || return 1
    metadata=$(curl -fsSL --connect-timeout 10 --max-time 30 'https://go.dev/dl/?mode=json') || {
        _error "无法读取 Go 官方版本元数据。"
        return 1
    }
    entry=$(printf '%s' "$metadata" | jq -r --arg arch "$go_arch" '
        first(.[] | select(.stable == true) as $release
            | $release.files[]
            | select(.os == "linux" and .arch == $arch and .kind == "archive")
            | [$release.version, .filename, .sha256] | @tsv) // empty
    ' 2>/dev/null)
    IFS=$'\t' read -r go_version filename expected_sha <<< "$entry"
    if [[ ! "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
       [[ ! "$filename" =~ ^go[0-9.]+\.linux-(amd64|arm64|386|armv6l)\.tar\.gz$ ]] || \
       [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || \
       ! _version_at_least "$go_version" "$GO_MIN_VERSION"; then
        _error "Go 官方元数据无效或版本低于 ${GO_MIN_VERSION}。"
        return 1
    fi

    temp_dir=$(mktemp -d /tmp/sb-go-toolchain.XXXXXX) || return 1
    archive="${temp_dir}/${filename}"
    _info "正在下载 Go ${go_version#go} (${go_arch})，并校验官方 SHA-256..."
    if ! curl -fL --connect-timeout 10 --max-time 300 \
        "https://go.dev/dl/${filename}" -o "$archive"; then
        rm -rf -- "$temp_dir"
        _error "Go 官方工具链下载失败。"
        return 1
    fi
    if ! printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum -c - >/dev/null 2>&1; then
        rm -rf -- "$temp_dir"
        _error "Go 官方工具链 SHA-256 校验失败。"
        return 1
    fi
    if ! tar -xzf "$archive" -C "$temp_dir" || [ ! -x "$temp_dir/go/bin/go" ]; then
        rm -rf -- "$temp_dir"
        _error "Go 官方工具链解压失败。"
        return 1
    fi
    extracted_version=$(_go_version_for_bin "$temp_dir/go/bin/go")
    if ! _version_at_least "$extracted_version" "$GO_MIN_VERSION"; then
        rm -rf -- "$temp_dir"
        _error "下载的 Go 版本不满足 ${GO_MIN_VERSION}+ 要求。"
        return 1
    fi

    mkdir -p "$REALITL_SCANNER_DIR" || { rm -rf -- "$temp_dir"; return 1; }
    if [ -e "$GO_TOOLCHAIN_DIR" ]; then
        if [ ! -f "$GO_TOOLCHAIN_MARKER" ]; then
            rm -rf -- "$temp_dir"
            _error "${GO_TOOLCHAIN_DIR} 已存在且不属于本脚本，拒绝覆盖。"
            return 1
        fi
        backup_dir="${GO_TOOLCHAIN_DIR}.old.$$"
        mv "$GO_TOOLCHAIN_DIR" "$backup_dir" || { rm -rf -- "$temp_dir"; return 1; }
    fi
    new_dir="${temp_dir}/go"
    if ! mv "$new_dir" "$GO_TOOLCHAIN_DIR"; then
        [ -n "$backup_dir" ] && mv "$backup_dir" "$GO_TOOLCHAIN_DIR" 2>/dev/null || true
        rm -rf -- "$temp_dir"
        return 1
    fi
    touch "$GO_TOOLCHAIN_MARKER"
    [ -n "$backup_dir" ] && rm -rf -- "$backup_dir"
    rm -rf -- "$temp_dir"
    _success "已安装受本脚本隔离管理的 Go ${extracted_version}。"
}

_ensure_compatible_go() {
    local go_bin current_version install_go
    if go_bin=$(_find_compatible_go); then
        printf '%s\n' "$go_bin"
        return 0
    fi
    if command -v go >/dev/null 2>&1; then
        current_version=$(_go_version_for_bin "$(command -v go)")
        _warn "系统 Go ${current_version:-未知} 低于 RealiTLScanner 要求的 ${GO_MIN_VERSION}。"
    else
        _warn "未检测到 Go ${GO_MIN_VERSION}+。"
    fi
    read -r -p "是否从 go.dev 安装满足要求的官方 Go 工具链？[Y/n]: " install_go
    if [[ "$install_go" == "n" || "$install_go" == "N" ]]; then
        _warn "已取消 RealiTLScanner 安装。"
        return 1
    fi
    _install_managed_go_toolchain || return 1
    _find_compatible_go
}

_sb_nginx_running() {
    [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null
}

_sb_reload_or_start_nginx() {
    nginx -t || return 1
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl is-active nginx >/dev/null 2>&1; then
            systemctl reload nginx
        else
            systemctl enable --now nginx
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service nginx status >/dev/null 2>&1; then rc-service nginx reload; else rc-service nginx start; fi
    elif _sb_nginx_running; then
        nginx -s reload
    else
        nginx
    fi
}

_sb_backup_nginx_file() {
    local target="$1" stamp
    [ -f "$target" ] || return 0
    mkdir -p "$NGINX_BACKUP_DIR" || return 1
    chmod 700 "$NGINX_BACKUP_DIR" 2>/dev/null || true
    stamp=$(date +%Y%m%d_%H%M%S)
    cp -a -- "$target" "${NGINX_BACKUP_DIR}/$(basename "$target").${stamp}.$$"
}

_ensure_nginx_conf_d_include() {
    [ -f "$NGINX_MAIN_CONF" ] || { _error "未找到 ${NGINX_MAIN_CONF}。"; return 1; }
    grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' "$NGINX_MAIN_CONF" && return 0

    local tmp rollback
    tmp=$(mktemp) || return 1
    rollback=$(mktemp) || { rm -f "$tmp"; return 1; }
    cp -a -- "$NGINX_MAIN_CONF" "$rollback" || { rm -f "$tmp" "$rollback"; return 1; }
    awk '
        BEGIN {in_http=0; depth=0; inserted=0}
        {
            line=$0; opens=gsub(/\{/, "{", line); closes=gsub(/\}/, "}", line)
            if (!in_http && $0 ~ /^[[:space:]]*http[[:space:]]*\{/) {in_http=1; depth=opens-closes; print; next}
            if (in_http) {
                if (depth==1 && $0 ~ /^[[:space:]]*}[[:space:]]*$/ && !inserted) {print "    include /etc/nginx/conf.d/*.conf;"; inserted=1}
                depth += opens-closes; if (depth==0) in_http=0
            }
            print
        }
        END {if (!inserted) exit 12}
    ' "$NGINX_MAIN_CONF" > "$tmp" || {
        rm -f "$tmp" "$rollback"
        _error "无法安全地向 nginx.conf 添加 conf.d include。"
        return 1
    }
    _sb_backup_nginx_file "$NGINX_MAIN_CONF" || { rm -f "$tmp" "$rollback"; return 1; }
    if ! cp -- "$tmp" "$NGINX_MAIN_CONF"; then
        cp -a -- "$rollback" "$NGINX_MAIN_CONF" 2>/dev/null || true
        rm -f "$tmp" "$rollback"
        return 1
    fi
    rm -f "$tmp"
    if ! nginx -t >/dev/null 2>&1; then
        cp -a -- "$rollback" "$NGINX_MAIN_CONF"
        rm -f "$rollback"
        _error "添加 conf.d include 后 Nginx 测试失败，已回滚。"
        return 1
    fi
    rm -f "$rollback"
    _success "已向 nginx.conf 添加 ${NGINX_CONF_DIR}/*.conf。"
}

_install_managed_nginx_config() {
    local source="$1" target="$2" marker="$3" rollback="" existed=false
    if [ -e "$target" ]; then
        if ! grep -Fqx "$marker" "$target" 2>/dev/null; then
            _error "Nginx 配置已存在且不属于本脚本，拒绝覆盖: ${target}"
            return 1
        fi
        existed=true
        rollback=$(mktemp) || return 1
        cp -a -- "$target" "$rollback" || { rm -f "$rollback"; return 1; }
        _sb_backup_nginx_file "$target" || { rm -f "$rollback"; return 1; }
    fi
    if ! install -m 644 "$source" "$target"; then
        if [ "$existed" = true ]; then cp -a -- "$rollback" "$target"; else rm -f -- "$target"; fi
        [ -n "$rollback" ] && rm -f "$rollback"
        return 1
    fi
    if ! _sb_reload_or_start_nginx; then
        if [ "$existed" = true ]; then cp -a -- "$rollback" "$target"; else rm -f -- "$target"; fi
        rm -f "$rollback"
        _sb_reload_or_start_nginx >/dev/null 2>&1 || true
        _error "Nginx 配置加载失败，已回滚: ${target}"
        return 1
    fi
    if [ -n "$rollback" ]; then
        rm -f "$rollback"
    fi
    return 0
}

_ensure_local_origin_dependencies() {
    _info "正在安装/检查 Nginx 与证书依赖..."
    if ! command -v nginx >/dev/null 2>&1; then
        _warn "首次安装 Nginx 时包管理器可能数分钟没有输出，请勿重复运行或中断脚本。"
    fi
    if command -v apk >/dev/null 2>&1; then
        _pkg_install nginx dcron || return 1
    elif command -v apt-get >/dev/null 2>&1; then
        _pkg_install nginx cron || return 1
    else
        _pkg_install nginx cronie || return 1
    fi
    command -v nginx >/dev/null 2>&1 || { _error "Nginx 安装失败。"; return 1; }
    _success "Nginx 与证书依赖已就绪。"
    install -d -m 755 "$NGINX_CONF_DIR" "$NGINX_CERT_DIR" "$ACME_WEBROOT/.well-known/acme-challenge" || return 1
    install -d -m 700 "$NGINX_BACKUP_DIR" || return 1
    _ensure_nginx_conf_d_include
}

_validate_local_origin_dns() {
    local domain="$1" public_v4 public_v6 resolved_a resolved_aaaa ip local_v6=""
    resolved_a=$(getent ahostsv4 "$domain" 2>/dev/null | awk '$2 == "STREAM" {print $1}' | sort -u)
    resolved_aaaa=$(getent ahostsv6 "$domain" 2>/dev/null | awk '$2 == "STREAM" && $1 ~ /:/ && $1 !~ /^::ffff:/ {print tolower($1)}' | sort -u)
    [ -n "$resolved_a$resolved_aaaa" ] || { _error "公共 DNS 尚未解析出 ${domain} 的 A/AAAA 记录。"; return 1; }

    public_v4=$(timeout 8 curl -fsS4 --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '\r\n ' || true)
    public_v6=$(timeout 8 curl -fsS6 --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '\r\n ' | tr '[:upper:]' '[:lower:]' || true)
    if [ -n "$resolved_a" ]; then
        _is_valid_ipv4 "$public_v4" || { _error "无法获取本机公网 IPv4，不能核对域名 A 记录。"; return 1; }
        while read -r ip; do
            [ -z "$ip" ] && continue
            _is_cloudflare_ipv4 "$ip" && { _error "${domain} 的 A 记录 ${ip} 属于 Cloudflare；请改为 DNS only。"; return 1; }
            [ "$ip" = "$public_v4" ] || { _error "${domain} 的 A 记录 ${ip} 未指向本机公网 IPv4 ${public_v4}。"; return 1; }
        done <<< "$resolved_a"
    fi
    if [ -n "$resolved_aaaa" ]; then
        if command -v ip >/dev/null 2>&1; then
            local_v6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print tolower($4)}' | sort -u)
        fi
        while read -r ip; do
            [ -z "$ip" ] && continue
            if ! printf '%s\n%s\n' "$local_v6" "$public_v6" | grep -Fxiq "$ip"; then
                _error "${domain} 的 AAAA 记录 ${ip} 未指向本机；请修正或删除该 AAAA 记录。"
                return 1
            fi
        done <<< "$resolved_aaaa"
    fi
    _success "域名 DNS 已确认直连本机（DNS only）。"
}

_install_sb_acme() {
    local current_version archive extract_dir source_dir
    if [ -x "$SB_ACME_SH" ]; then
        current_version=$("$SB_ACME_SH" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1 || true)
        if _version_at_least "$current_version" "$SB_ACME_VERSION"; then
            "$SB_ACME_SH" --set-default-ca --server letsencrypt >/dev/null
            return 0
        fi
        _warn "现有 acme.sh ${current_version:-未知} 过旧，将升级到 ${SB_ACME_VERSION}。"
    fi

    archive=$(mktemp) || return 1
    extract_dir=$(mktemp -d /tmp/sb-acme-install.XXXXXX) || { rm -f "$archive"; return 1; }
    _info "正在安装 acme.sh ${SB_ACME_VERSION}..."
    if ! curl -fsSL --connect-timeout 10 --max-time 120 "$SB_ACME_ARCHIVE_URL" -o "$archive" || \
       ! printf '%s  %s\n' "$SB_ACME_ARCHIVE_SHA256" "$archive" | sha256sum -c - >/dev/null 2>&1 || \
       ! tar -xzf "$archive" -C "$extract_dir"; then
        rm -f "$archive"; rm -rf -- "$extract_dir"
        _error "acme.sh 下载、校验或解压失败。"
        return 1
    fi
    source_dir="${extract_dir}/acme.sh-${SB_ACME_VERSION}"
    if [ ! -f "$source_dir/acme.sh" ] || ! (cd "$source_dir" && sh ./acme.sh --install --home "$SB_ACME_HOME" --nocron); then
        rm -f "$archive"; rm -rf -- "$extract_dir"
        _error "acme.sh 安装失败。"
        return 1
    fi
    rm -f "$archive"; rm -rf -- "$extract_dir"
    [ -x "$SB_ACME_SH" ] || return 1
    "$SB_ACME_SH" --set-default-ca --server letsencrypt >/dev/null
    touch "${SINGBOX_DIR}/.managed_acme"
}

_ensure_acme_renewal() {
    local cron_file="/etc/cron.d/singbox-reality-acme" marker="# Managed by singbox-lite Reality ACME"
    if ! { command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$SB_ACME_SH"; } && \
       ! grep -RqsF "$SB_ACME_SH" /etc/cron.d 2>/dev/null; then
        if [ -e "$cron_file" ] && ! grep -Fqx "$marker" "$cron_file" 2>/dev/null; then
            _error "续期任务文件已存在且不属于本脚本: ${cron_file}"
            return 1
        fi
        local tmp
        tmp=$(mktemp) || return 1
        {
            echo "$marker"
            printf '23 3 * * * root "%s" --cron --home "%s" >/dev/null 2>&1\n' "$SB_ACME_SH" "$SB_ACME_HOME"
        } > "$tmp"
        install -m 644 "$tmp" "$cron_file" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service dcron start >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
        rc-update add dcron default >/dev/null 2>&1 || rc-update add crond default >/dev/null 2>&1 || true
    fi
}

_acme_ecc_cert_is_usable() {
    local domain="$1" info cert_path
    [ -x "$SB_ACME_SH" ] || return 1
    info=$("$SB_ACME_SH" --info -d "$domain" --ecc 2>/dev/null || true)
    cert_path=$(printf '%s\n' "$info" | sed -n 's/^Le_RealFullChainPath=//p' | head -n 1)
    cert_path=${cert_path#\'}
    cert_path=${cert_path%\'}
    [ -n "$cert_path" ] && [ -s "$cert_path" ] && openssl x509 -in "$cert_path" -checkend 604800 -noout >/dev/null 2>&1
}

_acme_record_uses_webroot() {
    local domain="$1" info webroot
    info=$("$SB_ACME_SH" --info -d "$domain" --ecc 2>/dev/null || true)
    webroot=$(printf '%s\n' "$info" | sed -n 's/^Le_Webroot=//p' | head -n 1)
    webroot=${webroot#\'}
    webroot=${webroot%\'}
    [ "$webroot" = "$ACME_WEBROOT" ]
}

_issue_local_origin_certificate() {
    local domain="$1"
    local cert_dir="${NGINX_CERT_DIR}/${domain}"
    local -a force_args=()
    if ! _acme_ecc_cert_is_usable "$domain" || ! _acme_record_uses_webroot "$domain"; then
        if "$SB_ACME_SH" --info -d "$domain" --ecc >/dev/null 2>&1; then
            force_args+=(--force)
            _warn "现有证书续期方式不是本机 HTTP-01 webroot，将迁移为无 Token 的自动续期。"
        fi
        _info "正在通过 HTTP-01 webroot 申请 Let's Encrypt 证书: ${domain}"
        "$SB_ACME_SH" --issue --server letsencrypt --webroot "$ACME_WEBROOT" \
            -d "$domain" --keylength ec-256 "${force_args[@]}" || return 1
    else
        _info "检测到仍有效的现有 ECC 证书，将直接复用。"
    fi
    install -d -m 700 "$cert_dir" || return 1
    "$SB_ACME_SH" --install-cert -d "$domain" --ecc \
        --fullchain-file "$cert_dir/cert" \
        --key-file "$cert_dir/key" \
        --reloadcmd "$SB_ACME_RELOAD_CMD" || return 1
    [ -s "$cert_dir/cert" ] && [ -s "$cert_dir/key" ] || return 1
    chmod 600 "$cert_dir/cert" "$cert_dir/key" 2>/dev/null || true
}

_prepare_local_reality_origin() {
    local domain="${1,,}" safe_domain challenge_conf origin_conf site_root tmp marker
    _is_valid_reality_domain "$domain" || { _error "自有域名格式无效: ${domain}"; return 1; }
    safe_domain="${domain//[^a-z0-9.-]/_}"
    challenge_conf="${NGINX_CONF_DIR}/00-sb-reality-acme-${safe_domain}.conf"
    origin_conf="${NGINX_CONF_DIR}/${safe_domain}.${REALITY_LOCAL_ORIGIN_PORT}.reality.conf"
    site_root="/var/www/singbox-reality/${safe_domain}"

    _validate_local_origin_dns "$domain" || return 1
    _ensure_local_origin_dependencies || return 1

    marker="# Generated by singbox-lite Reality local origin"
    tmp=$(mktemp) || return 1
    {
        echo "$marker"
        echo 'server {'
        echo '    listen 0.0.0.0:80;'
        if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "0" ]; then
            echo '    listen [::]:80;'
        fi
        echo "    server_name ${domain};"
        echo '    location ^~ /.well-known/acme-challenge/ {'
        echo "        root ${ACME_WEBROOT};"
        echo '        default_type text/plain;'
        echo '        try_files $uri =404;'
        echo '    }'
        echo '    location / { return 404; }'
        echo '}'
    } > "$tmp"
    _install_managed_nginx_config "$tmp" "$challenge_conf" "$marker" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    _install_sb_acme || return 1
    _ensure_acme_renewal || return 1
    _issue_local_origin_certificate "$domain" || return 1

    install -d -m 755 "$site_root" || return 1
    if [ ! -f "$site_root/index.html" ]; then
        tmp=$(mktemp) || return 1
        printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>Welcome</h1></body></html>' > "$tmp"
        install -m 644 "$tmp" "$site_root/index.html" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi

    tmp=$(mktemp) || return 1
    cat > "$tmp" <<EOF_REALITY_ORIGIN
$marker
server {
    listen ${REALITY_LOCAL_ORIGIN_HOST}:${REALITY_LOCAL_ORIGIN_PORT} ssl http2;
    server_name ${domain};

    ssl_certificate ${NGINX_CERT_DIR}/${domain}/cert;
    ssl_certificate_key ${NGINX_CERT_DIR}/${domain}/key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SBRealitySSL:10m;
    ssl_session_timeout 1h;
    server_tokens off;

    root ${site_root};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF_REALITY_ORIGIN
    _install_managed_nginx_config "$tmp" "$origin_conf" "$marker" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    local probe_ok=false probe_attempt
    for probe_attempt in 1 2 3 4 5; do
        if _probe_reality_target "$REALITY_LOCAL_ORIGIN_HOST" "$domain" "$REALITY_LOCAL_ORIGIN_PORT"; then
            probe_ok=true
            break
        fi
        if [ "$probe_attempt" -lt 5 ]; then
            [ "$probe_attempt" -eq 1 ] && _info "Nginx 正在切换到新的 HTTPS 配置，稍候重试本机源站探测..."
            sleep 1
        fi
    done
    if [ "$probe_ok" != true ]; then
        _error "本机 HTTPS 源站复核失败: ${REALITY_PROBE_ERROR}"
        return 1
    fi
    _success "自有证书、本机 Nginx HTTPS 源站与自动续期已配置完成。"
    _info "Reality SNI: ${domain} | 握手目标: ${REALITY_LOCAL_ORIGIN_HOST}:${REALITY_LOCAL_ORIGIN_PORT}"
}

_realitlscanner_release_spec() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf '%s\t%s\n' "RealiTLScanner-linux-amd64" "$REALITL_SCANNER_AMD64_SHA256"
            ;;
        aarch64|arm64)
            printf '%s\t%s\n' "RealiTLScanner-linux-arm64" "$REALITL_SCANNER_ARM64_SHA256"
            ;;
        *)
            return 1
            ;;
    esac
}

_install_realitlscanner() {
    local spec asset_name expected_sha expected_marker temp_dir candidate actual_sha
    spec=$(_realitlscanner_release_spec) || {
        _error "RealiTLScanner ${REALITL_SCANNER_VERSION} 未提供当前架构 $(uname -m) 的官方 Linux 二进制。"
        _warn "为避免临时安装 Go 与本地编译，已中止扫描器安装。"
        return 1
    }
    IFS=$'\t' read -r asset_name expected_sha <<< "$spec"
    expected_marker="${REALITL_SCANNER_VERSION}:${asset_name}:${expected_sha}"
    if [ -x "$REALITL_SCANNER_BIN" ] && [ -r "$REALITL_SCANNER_MARKER" ] && \
       [ "$(tr -d '\r\n ' < "$REALITL_SCANNER_MARKER")" = "$expected_marker" ]; then
        return 0
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        _pkg_install coreutils || {
            _error "无法安装 SHA-256 校验工具，RealiTLScanner 安装已中止。"
            return 1
        }
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        _pkg_install curl wget ca-certificates || {
            _error "无法安装下载工具，RealiTLScanner 安装已中止。"
            return 1
        }
    fi
    temp_dir=$(mktemp -d /tmp/sb-realitlscanner.XXXXXX) || {
        _error "无法创建 RealiTLScanner 临时目录。"
        return 1
    }
    candidate="${temp_dir}/${asset_name}"
    _info "正在下载并校验 XTLS/RealiTLScanner ${REALITL_SCANNER_VERSION} (${asset_name})..."
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fL --connect-timeout 10 --max-time 180 \
            "${REALITL_SCANNER_RELEASE_BASE}/${asset_name}" -o "$candidate"; then
            rm -f "$candidate"
        fi
    fi
    if [ ! -s "$candidate" ] && command -v wget >/dev/null 2>&1; then
        wget -qO "$candidate" "${REALITL_SCANNER_RELEASE_BASE}/${asset_name}" || true
    fi
    actual_sha=$(sha256sum "$candidate" 2>/dev/null | awk '{print $1}')
    if [ ! -s "$candidate" ] || [ "$actual_sha" != "$expected_sha" ]; then
        [[ "$temp_dir" == /tmp/sb-realitlscanner.* ]] && rm -rf -- "$temp_dir"
        _error "RealiTLScanner 下载失败或 SHA-256 校验不匹配，已拒绝安装。"
        return 1
    fi
    chmod 700 "$candidate"
    if ! mkdir -p "$REALITL_SCANNER_DIR" || ! install -m 700 "$candidate" "$REALITL_SCANNER_BIN"; then
        [[ "$temp_dir" == /tmp/sb-realitlscanner.* ]] && rm -rf -- "$temp_dir"
        _error "无法将 RealiTLScanner 安装到 ${REALITL_SCANNER_BIN}。"
        return 1
    fi
    if ! printf '%s\n' "$expected_marker" > "$REALITL_SCANNER_MARKER" || \
       ! chmod 600 "$REALITL_SCANNER_MARKER" || \
       ! mkdir -p "$SINGBOX_DIR" || ! touch "${SINGBOX_DIR}/.managed_realitlscanner"; then
        [[ "$temp_dir" == /tmp/sb-realitlscanner.* ]] && rm -rf -- "$temp_dir"
        _error "无法写入 RealiTLScanner 安装校验标记。"
        return 1
    fi
    rm -f "${REALITL_SCANNER_DIR}/RealiTLScanner.commit"
    [[ "$temp_dir" == /tmp/sb-realitlscanner.* ]] && rm -rf -- "$temp_dir"
    _success "RealiTLScanner ${REALITL_SCANNER_VERSION} 官方二进制已安装并通过固定 SHA-256 校验。"
}

_probe_reality_target() {
    local target="$1" sni="$2" target_port="${3:-443}" connect_target curl_result curl_headers curl_meta appconnect
    local tls_output
    REALITY_PROBE_ERROR=""
    REALITY_PROBE_LATENCY=""
    REALITY_PROBE_HTTP_STATUS=""

    _target_uses_cloudflare "$target" && {
        REALITY_PROBE_ERROR="目标 IP 属于 Cloudflare 公开网段"
        return 1
    }
    [[ "$target_port" =~ ^[0-9]+$ ]] && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ] || {
        REALITY_PROBE_ERROR="目标端口无效"
        return 1
    }
    connect_target="${target}:${target_port}"
    [[ "$target" == *:* ]] && connect_target="[${target}]:${target_port}"
    tls_output=$(timeout 7 openssl s_client -connect "$connect_target" -servername "$sni" \
        -verify_hostname "$sni" -verify_return_error -tls1_3 -alpn h2 </dev/null 2>&1 | \
        LC_ALL=C tr -d '\000') || true
    printf '%s' "$tls_output" | grep -q 'TLSv1.3' || {
        REALITY_PROBE_ERROR="未协商 TLS 1.3"
        return 1
    }
    printf '%s' "$tls_output" | grep -q 'ALPN protocol: h2' || {
        REALITY_PROBE_ERROR="未协商 HTTP/2 (h2)"
        return 1
    }
    printf '%s' "$tls_output" | grep -Eq 'Verify return code: 0 \(ok\)|Verification: OK' || {
        REALITY_PROBE_ERROR="证书与 SNI 不匹配或证书链无效"
        return 1
    }

    local curl_args=(-sS -I --noproxy '*' --connect-timeout 4 --max-time 8)
    _is_valid_ipv4 "$target" && curl_args+=(--resolve "${sni}:${target_port}:${target}")
    curl_result=$(curl "${curl_args[@]}" -w $'\nSB_REALITY:%{http_code}\t%{time_appconnect}' \
        "https://${sni}:${target_port}/" 2>/dev/null) || {
        REALITY_PROBE_ERROR="HTTPS 请求失败"
        return 1
    }
    curl_meta=$(printf '%s\n' "$curl_result" | awk -F: '/^SB_REALITY:/{v=$2} END{print v}')
    curl_headers=$(printf '%s\n' "$curl_result" | sed '/^SB_REALITY:/d')
    IFS=$'\t' read -r REALITY_PROBE_HTTP_STATUS appconnect <<< "$curl_meta"
    [[ "$REALITY_PROBE_HTTP_STATUS" =~ ^3[0-9][0-9]$ ]] && {
        REALITY_PROBE_ERROR="根路径返回 HTTP ${REALITY_PROBE_HTTP_STATUS} 跳转"
        return 1
    }
    [[ "$REALITY_PROBE_HTTP_STATUS" =~ ^[245][0-9][0-9]$ ]] || {
        REALITY_PROBE_ERROR="无法确认根路径 HTTP 状态"
        return 1
    }
    printf '%s\n' "$curl_headers" | grep -qi '^server:[[:space:]]*cloudflare' && {
        REALITY_PROBE_ERROR="HTTP 响应由 Cloudflare 提供"
        return 1
    }
    REALITY_PROBE_LATENCY=$(awk -v t="$appconnect" 'BEGIN { printf "%.0f", t * 1000 }')
    [[ "$REALITY_PROBE_LATENCY" =~ ^[0-9]+$ ]] || REALITY_PROBE_LATENCY=99999
    return 0
}

# GreatFire 的判定来自中国大陆探针与境外对照点；它只能提供风险证据，不能保证
# 所有省份、运营商和时刻都可达。返回值：0=未发现屏蔽，1=已知高风险，2=无结论。
_greatfire_fetch_verdict() {
    local domain="$1" response headline stale conclusions last_tested
    GREATFIRE_RESULT_CODE=2
    GREATFIRE_RESULT_LABEL="无大陆侧数据"
    GREATFIRE_RESULT_LAST_TESTED=""

    response=$(curl -fsS --connect-timeout 5 --max-time 12 --retry 1 --retry-delay 1 \
        -H 'Accept: application/json' \
        -H "User-Agent: singbox-lite/${SCRIPT_VERSION} gfw-check" \
        "${GREATFIRE_API_BASE}/api/url/https/${domain}" 2>/dev/null) || return 2
    jq -e 'type == "object" and (.headline | type == "string")' \
        >/dev/null 2>&1 <<< "$response" || return 2

    headline=$(jq -r '.headline' <<< "$response")
    stale=$(jq -r '.stale // false' <<< "$response")
    conclusions=$(jq -r '.conclusions // 0' <<< "$response")
    last_tested=$(jq -r '.last_tested // empty' <<< "$response")
    if [[ "$last_tested" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        GREATFIRE_RESULT_LAST_TESTED="${last_tested%%T*}"
    fi

    if [ "$stale" = "true" ]; then
        GREATFIRE_RESULT_LABEL="数据过期"
        return 2
    fi
    case "$headline" in
        "not blocked")
            if [[ "$conclusions" =~ ^[0-9]+$ ]] && [ "$conclusions" -gt 0 ]; then
                GREATFIRE_RESULT_CODE=0
                GREATFIRE_RESULT_LABEL="历史未屏蔽${GREATFIRE_RESULT_LAST_TESTED:+(${GREATFIRE_RESULT_LAST_TESTED})}"
                return 0
            fi
            GREATFIRE_RESULT_LABEL="数据不足"
            return 2
            ;;
        blocked)
            GREATFIRE_RESULT_CODE=1
            GREATFIRE_RESULT_LABEL="已知被屏蔽${GREATFIRE_RESULT_LAST_TESTED:+(${GREATFIRE_RESULT_LAST_TESTED})}"
            return 1
            ;;
        intermittent)
            GREATFIRE_RESULT_CODE=1
            GREATFIRE_RESULT_LABEL="存在间歇性干扰${GREATFIRE_RESULT_LAST_TESTED:+(${GREATFIRE_RESULT_LAST_TESTED})}"
            return 1
            ;;
        redirected)
            GREATFIRE_RESULT_CODE=1
            GREATFIRE_RESULT_LABEL="大陆侧重定向${GREATFIRE_RESULT_LAST_TESTED:+(${GREATFIRE_RESULT_LAST_TESTED})}"
            return 1
            ;;
        unresolvable)
            GREATFIRE_RESULT_CODE=1
            GREATFIRE_RESULT_LABEL="公共 DNS 无法解析"
            return 1
            ;;
        *)
            GREATFIRE_RESULT_LABEL="数据不足"
            return 2
            ;;
    esac
}

_greatfire_cached_verdict() {
    local domain="$1" i result
    for i in "${!GREATFIRE_CACHE_DOMAINS[@]}"; do
        if [ "${GREATFIRE_CACHE_DOMAINS[$i]}" = "$domain" ]; then
            GREATFIRE_RESULT_CODE="${GREATFIRE_CACHE_CODES[$i]}"
            GREATFIRE_RESULT_LABEL="${GREATFIRE_CACHE_LABELS[$i]}"
            GREATFIRE_RESULT_LAST_TESTED="${GREATFIRE_CACHE_LAST_TESTED[$i]}"
            return "$GREATFIRE_RESULT_CODE"
        fi
    done

    _greatfire_fetch_verdict "$domain"
    result=$?
    GREATFIRE_CACHE_DOMAINS+=("$domain")
    GREATFIRE_CACHE_CODES+=("$result")
    GREATFIRE_CACHE_LABELS+=("$GREATFIRE_RESULT_LABEL")
    GREATFIRE_CACHE_LAST_TESTED+=("$GREATFIRE_RESULT_LAST_TESTED")
    return "$result"
}

_greatfire_live_verify() {
    local domain="$1" payload response state triggered started elapsed last_state="" failures=0
    payload=$(jq -cn --arg url "https://${domain}" '{url:$url}') || return 2
    started=$(date +%s)
    _info "正在请求 GreatFire 中国大陆探针实测 ${domain}；通常需要几十秒，最长等待 150 秒..."

    while true; do
        elapsed=$(( $(date +%s) - started ))
        [ "$elapsed" -lt 150 ] || {
            GREATFIRE_RESULT_CODE=2
            GREATFIRE_RESULT_LABEL="大陆探针等待超时"
            return 2
        }
        response=$(curl -fsS --connect-timeout 5 --max-time 15 \
            -H 'Accept: application/json' -H 'Content-Type: application/json' \
            -H "User-Agent: singbox-lite/${SCRIPT_VERSION} gfw-check" \
            -X POST --data "$payload" "${GREATFIRE_API_BASE}/api/test-now" 2>/dev/null) || {
            failures=$((failures + 1))
            if [ "$failures" -ge 3 ]; then
                GREATFIRE_RESULT_CODE=2
                GREATFIRE_RESULT_LABEL="大陆探针接口不可用"
                return 2
            fi
            sleep 2
            continue
        }
        failures=0
        jq -e 'type == "object"' >/dev/null 2>&1 <<< "$response" || {
            GREATFIRE_RESULT_CODE=2
            GREATFIRE_RESULT_LABEL="大陆探针返回格式异常"
            return 2
        }
        triggered=$(jq -r '.triggered // false' <<< "$response")
        state=$(jq -r '.state // "error"' <<< "$response")
        if [ "$triggered" != "true" ] || [ "$state" = "error" ]; then
            GREATFIRE_RESULT_CODE=2
            GREATFIRE_RESULT_LABEL="大陆探针拒绝或无法执行测试"
            return 2
        fi
        if [ "$state" != "$last_state" ]; then
            case "$state" in
                waiting_backend) _info "大陆探针任务已提交，正在等待后端..." ;;
                waiting_cn) _info "境外对照已响应，正在等待中国大陆探针..." ;;
                partial) _info "已收到部分大陆探针结果，继续等待..." ;;
            esac
            last_state="$state"
        fi
        case "$state" in
            done)
                sleep 1
                _greatfire_fetch_verdict "$domain"
                return $?
                ;;
            timeout)
                GREATFIRE_RESULT_CODE=2
                GREATFIRE_RESULT_LABEL="大陆探针测试超时"
                return 2
                ;;
        esac
        sleep 2
    done
}

_confirm_reality_china_reachability() {
    local domain="$1" result force_unverified
    if [ "$REALITY_CHINA_CHECK_ENABLED" != "true" ]; then
        _warn "${domain} 尚未从中国大陆网络验证；境外 TLS/H2 成功不能证明其未被 GFW 屏蔽。"
        read -r -p "仍要使用这个未经大陆验证的 SNI？[y/N]: " force_unverified
        [[ "$force_unverified" == "y" || "$force_unverified" == "Y" ]]
        return
    fi

    _greatfire_live_verify "$domain"
    result=$?
    case "$result" in
        0)
            _success "大陆探针本次判定：未屏蔽。"
            _warn "该结果只覆盖 GreatFire 当前探针，不能保证所有省份、运营商和未来时刻。"
            return 0
            ;;
        1)
            _error "已拒绝该 SNI：GreatFire 判定为 ${GREATFIRE_RESULT_LABEL}。"
            return 1
            ;;
        *)
            _warn "无法取得明确的大陆侧结论：${GREATFIRE_RESULT_LABEL}。"
            read -r -p "仍要使用这个结果不明确的 SNI？[y/N]: " force_unverified
            [[ "$force_unverified" == "y" || "$force_unverified" == "Y" ]]
            return
            ;;
    esac
}

_is_safe_reality_scan_cidr() {
    local value="$1" ip prefix
    [[ "$value" == */* ]] || return 1
    ip="${value%/*}"; prefix="${value#*/}"
    _is_valid_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 24 ] && [ "$prefix" -le 32 ]
}

_prepare_reality_custom_scan_file() {
    local output_file="$1" raw_line token normalized prefix expanded
    local total_targets=0 valid_entries=0 invalid_entries=0
    local seen=" "
    local tokens=()
    : > "$output_file" || { _error "无法创建自定义扫描列表。"; return 1; }

    echo "请粘贴域名、IPv4 或 IPv4 CIDR；支持每行一个，也可用空格或逗号分隔。"
    echo "CIDR 仅允许 /24-/32，全部条目展开后最多 ${REALITY_SNI_MAX_SCAN_TARGETS} 个目标；输入空行结束。"
    while true; do
        IFS= read -r raw_line || break
        raw_line="${raw_line//$'\r'/}"
        [ -z "${raw_line//[[:space:]]/}" ] && break
        raw_line="${raw_line//,/ }"
        raw_line="${raw_line//;/ }"
        read -r -a tokens <<< "$raw_line"
        for token in "${tokens[@]}"; do
            normalized=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')
            [ -z "$normalized" ] && continue
            expanded=1
            if [[ "$normalized" == */* ]]; then
                if ! _is_safe_reality_scan_cidr "$normalized"; then
                    _warn "已忽略无效或过大的 CIDR: ${token}"
                    invalid_entries=$((invalid_entries + 1))
                    continue
                fi
                prefix="${normalized#*/}"
                expanded=$((1 << (32 - 10#$prefix)))
            elif _is_valid_ipv4 "$normalized"; then
                :
            elif _is_valid_reality_domain "$normalized"; then
                :
            else
                _warn "已忽略无效目标: ${token}"
                invalid_entries=$((invalid_entries + 1))
                continue
            fi
            [[ "$seen" == *" ${normalized} "* ]] && continue
            if [ $((total_targets + expanded)) -gt "$REALITY_SNI_MAX_SCAN_TARGETS" ]; then
                _error "自定义列表展开后超过 ${REALITY_SNI_MAX_SCAN_TARGETS} 个目标，请缩小 CIDR 或减少条目。"
                return 1
            fi
            printf '%s\n' "$normalized" >> "$output_file" || return 1
            seen="${seen}${normalized} "
            total_targets=$((total_targets + expanded))
            valid_entries=$((valid_entries + 1))
        done
    done
    [ "$valid_entries" -gt 0 ] || { _error "没有可扫描的有效目标。"; return 1; }
    [ "$invalid_entries" -gt 0 ] && _warn "共忽略 ${invalid_entries} 个无效目标。"
    _info "已载入 ${valid_entries} 个条目，展开后最多 ${total_targets} 个扫描目标。"
}

_first_exact_cert_domain() {
    local target="$1" cert_info domain
    cert_info=$(timeout 6 openssl s_client -connect "${target}:443" -showcerts </dev/null 2>/dev/null | \
        openssl x509 -noout -ext subjectAltName 2>/dev/null) || return 1
    while read -r domain; do
        domain="${domain#DNS:}"
        domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
        _is_valid_reality_domain "$domain" && { printf '%s\n' "$domain"; return 0; }
    done < <(printf '%s\n' "$cert_info" | grep -oE 'DNS:[^,[:space:]]+')
    return 1
}

_scan_reality_sni_once() {
    if [ "$REALITY_SNI_SCAN_DONE" = "true" ]; then
        [ "${#REALITY_SNI_DOMAINS[@]}" -gt 0 ] && return 0
    fi
    REALITY_SNI_SCAN_DONE=false
    REALITY_SNI_DOMAINS=()
    REALITY_SNI_LATENCIES=()
    REALITY_SNI_TARGETS=()
    REALITY_SNI_CHINA_STATUSES=()

    _install_realitlscanner || {
        _error "RealiTLScanner 安装或校验失败，尚未开始扫描。"
        return 1
    }
    local temp_dir csv_file scan_log scan_status input_file scan_mode scan_label entry_count
    local public_ipv4 default_cidr="" scan_cidr
    local scan_args=()
    temp_dir=$(mktemp -d /tmp/sb-reality-scan.XXXXXX) || {
        _error "无法创建 Reality 扫描临时目录。"
        return 1
    }
    csv_file="${temp_dir}/out.csv"
    scan_log="${temp_dir}/scan.log"
    input_file="${temp_dir}/targets.txt"

    public_ipv4=$(_get_public_ip 2>/dev/null || true)
    if _is_valid_ipv4 "$public_ipv4"; then
        IFS='.' read -r _scan_a _scan_b _scan_c _scan_d <<< "$public_ipv4"
        default_cidr="${_scan_a}.${_scan_b}.${_scan_c}.0/24"
    fi

    echo "请选择 Reality 候选扫描方式："
    echo "  1) 扫描 VPS 邻近 IPv4 /24"
    echo "  2) 检测内置大厂域名种子（推荐）"
    echo "  3) 粘贴自定义域名/IPv4/CIDR 列表"
    read -r -p "请选择 [1-3] (默认: 2): " scan_mode
    scan_mode="${scan_mode:-2}"
    case "$scan_mode" in
        1)
            _warn "上游建议在本地而非云 VPS 扫描；本模式限制为最多 /24、16 线程、3 秒单目标超时。"
            read -r -p "请输入扫描 IPv4 CIDR [${default_cidr:-例如 203.0.113.0/24}]: " scan_cidr
            scan_cidr="${scan_cidr:-$default_cidr}"
            if ! _is_safe_reality_scan_cidr "$scan_cidr"; then
                [[ "$temp_dir" == /tmp/sb-reality-scan.* ]] && rm -rf -- "$temp_dir"
                _error "扫描范围必须是 IPv4 CIDR，且前缀长度为 /24-/32。"
                return 1
            fi
            scan_args=(-addr "$scan_cidr")
            scan_label="VPS 邻近网段 ${scan_cidr}:443"
            ;;
        2)
            printf '%s\n' "${REALITY_SNI_SEED_DOMAINS[@]}" > "$input_file" || {
                [[ "$temp_dir" == /tmp/sb-reality-scan.* ]] && rm -rf -- "$temp_dir"
                _error "无法写入内置 Reality 域名种子。"
                return 1
            }
            scan_args=(-in "$input_file")
            scan_label="内置大厂域名种子（${#REALITY_SNI_SEED_DOMAINS[@]} 个）"
            _info "种子源自 3x-ui 当前内置列表；已按既有规则排除 www.cloudflare.com。"
            ;;
        3)
            if ! _prepare_reality_custom_scan_file "$input_file"; then
                [[ "$temp_dir" == /tmp/sb-reality-scan.* ]] && rm -rf -- "$temp_dir"
                return 1
            fi
            entry_count=$(wc -l < "$input_file" | tr -d ' ')
            scan_args=(-in "$input_file")
            scan_label="自定义列表（${entry_count} 个条目）"
            ;;
        *)
            [[ "$temp_dir" == /tmp/sb-reality-scan.* ]] && rm -rf -- "$temp_dir"
            _error "扫描方式无效。"
            return 1
            ;;
    esac

    _info "正在使用 RealiTLScanner 检测 ${scan_label}..."
    timeout 180 "$REALITL_SCANNER_BIN" "${scan_args[@]}" -port 443 -thread 16 -timeout 3 \
        -out "$csv_file" > "$scan_log" 2>&1
    scan_status=$?
    if [ "$scan_status" -eq 124 ]; then
        _warn "扫描达到 180 秒上限，将使用已获得的结果。"
    elif [ "$scan_status" -ne 0 ]; then
        if [ -s "$csv_file" ]; then
            _warn "扫描器返回状态 ${scan_status}，将尝试使用已获得的结果。"
        else
            _error "RealiTLScanner 执行失败（状态 ${scan_status}）。"
            [ -s "$scan_log" ] && tail -n 5 "$scan_log" >&2
            [[ "$temp_dir" == /tmp/sb-reality-scan.* ]] && rm -rf -- "$temp_dir"
            return 1
        fi
    fi

    local results="" target origin candidate key china_status
    local gfw_result gfw_rejected=0
    local seen=" "
    local csv_header header_name csv_line cert_domain_index=-1 i
    local csv_fields=()
    if [ -s "$csv_file" ]; then
        IFS= read -r csv_header < "$csv_file"
        IFS=',' read -r -a csv_fields <<< "$csv_header"
        for i in "${!csv_fields[@]}"; do
            header_name=$(printf '%s' "${csv_fields[$i]}" | tr -d '\r\" ' | tr '[:lower:]' '[:upper:]')
            [ "$header_name" = "CERT_DOMAIN" ] && { cert_domain_index="$i"; break; }
        done
        if [ "$cert_domain_index" -lt 0 ]; then
            _error "无法识别 RealiTLScanner CSV 格式：缺少 CERT_DOMAIN 列。"
            [[ "$temp_dir" == /tmp/sb-reality-scan.* ]] && rm -rf -- "$temp_dir"
            return 1
        fi
        while IFS= read -r csv_line; do
            IFS=',' read -r -a csv_fields <<< "$csv_line"
            [ "${#csv_fields[@]}" -gt "$cert_domain_index" ] || continue
            target="${csv_fields[0]}"
            origin="${csv_fields[1]}"
            candidate="${csv_fields[$cert_domain_index]}"
            target=$(printf '%s' "$target" | tr -d '\r ')
            origin=$(printf '%s' "$origin" | tr -d '\r\" ' | tr '[:upper:]' '[:lower:]')
            candidate=$(printf '%s' "$candidate" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
            _is_valid_ipv4 "$target" || continue
            if ! _is_valid_ipv4 "$origin" && _is_valid_reality_domain "$origin"; then
                candidate="$origin"
            elif [[ "$candidate" == \*.* ]]; then
                candidate=$(_first_exact_cert_domain "$target" 2>/dev/null || true)
            fi
            _is_valid_reality_domain "$candidate" || continue
            key="${target}|${candidate}"
            [[ "$seen" == *" ${key} "* ]] && continue
            seen+="${key} "
            _probe_reality_target "$target" "$candidate" || continue
            china_status="未验证"
            if [ "$REALITY_CHINA_CHECK_ENABLED" = "true" ]; then
                _greatfire_cached_verdict "$candidate"
                gfw_result=$?
                china_status="$GREATFIRE_RESULT_LABEL"
                if [ "$gfw_result" -eq 1 ]; then
                    gfw_rejected=$((gfw_rejected + 1))
                    _warn "已过滤大陆侧高风险候选: ${candidate} (${china_status})"
                    continue
                fi
            fi
            results+="${REALITY_PROBE_LATENCY}"$'\t'"${candidate}"$'\t'"${target}"$'\t'"${REALITY_PROBE_HTTP_STATUS}"$'\t'"${china_status}"$'\n'
        done < <(tail -n +2 "$csv_file")
    fi
    [[ "$temp_dir" == /tmp/sb-reality-scan.* ]] && rm -rf -- "$temp_dir"

    local sorted_latency sorted_domain sorted_target sorted_status sorted_china_status
    while IFS=$'\t' read -r sorted_latency sorted_domain sorted_target sorted_status sorted_china_status; do
        [ -z "$sorted_domain" ] && continue
        REALITY_SNI_LATENCIES+=("$sorted_latency")
        REALITY_SNI_DOMAINS+=("$sorted_domain")
        REALITY_SNI_TARGETS+=("$sorted_target")
        REALITY_SNI_CHINA_STATUSES+=("${sorted_china_status:-未验证}")
        [ "${#REALITY_SNI_DOMAINS[@]}" -ge 20 ] && break
    done < <(printf '%s' "$results" | sort -n -k1,1)

    if [ "${#REALITY_SNI_DOMAINS[@]}" -eq 0 ]; then
        _warning "本次未找到同时满足 TLS 1.3、H2、不跳转、证书匹配、非 Cloudflare 且未命中大陆高风险判定的候选。"
        return 1
    fi
    REALITY_SNI_SCAN_DONE=true
    _success "扫描与复核完成，共保留 ${#REALITY_SNI_DOMAINS[@]} 个候选；大陆侧高风险过滤 ${gfw_rejected} 个。"
}

_select_reality_sni() {
    REALITY_SNI_SCAN_DONE=false
    REALITY_SNI_DOMAINS=()
    REALITY_SNI_LATENCIES=()
    REALITY_SNI_TARGETS=()
    REALITY_SNI_CHINA_STATUSES=()
    SELECTED_REALITY_SNI="$DEFAULT_REALITY_SNI"
    SELECTED_REALITY_HANDSHAKE_SERVER="$DEFAULT_REALITY_SNI"
    SELECTED_REALITY_HANDSHAKE_PORT=443

    echo "Reality 目标优先使用你自己控制的、真实可访问的 HTTPS 域名。"
    read -r -p "你是否有符合条件的自有域名？[y/N]: " own_domain_choice
    if [[ "$own_domain_choice" == "y" || "$own_domain_choice" == "Y" ]]; then
        echo "  自有域名使用方式："
        echo "  1) 单机自动模式：本机安装 Nginx、申请证书并配置自动续期（默认）"
        echo "  2) 使用已经存在的独立 HTTPS 源站"
        local own_mode own_domain
        read -r -p "请选择 [1-2] (默认: 1): " own_mode
        own_mode="${own_mode:-1}"
        if [ "$own_mode" = "1" ]; then
            echo "  单机自动模式要求："
            echo "  1) 域名 A/AAAA 已指向本机，且使用 DNS only。"
            echo "  2) 公网 TCP 80 可访问，用于 Let's Encrypt HTTP-01；不需要 Cloudflare Token。"
            echo "  3) Nginx 仅在 127.0.0.1:${REALITY_LOCAL_ORIGIN_PORT} 提供 Reality HTTPS 源站。"
            echo "  4) 若 Reality 与 Emby 都使用公网 443，请启用 HAProxy SNI 分流，并确保两个域名不同。"
            read -r -p "请输入自有域名: " own_domain
            own_domain=$(printf '%s' "$own_domain" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
            _is_valid_reality_domain "$own_domain" || { _error "自有域名格式无效。"; return 1; }
            _prepare_local_reality_origin "$own_domain" || return 1
            SELECTED_REALITY_SNI="$own_domain"
            SELECTED_REALITY_HANDSHAKE_SERVER="$REALITY_LOCAL_ORIGIN_HOST"
            SELECTED_REALITY_HANDSHAKE_PORT="$REALITY_LOCAL_ORIGIN_PORT"
            return 0
        elif [ "$own_mode" != "2" ]; then
            _error "无效选择。"
            return 1
        fi

        echo "  独立 HTTPS 源站要求："
        echo "  1) A/AAAA/CNAME 指向另一个真实 HTTPS 源站。"
        echo "  2) 使用 DNS only，不要开启 Cloudflare 代理/CDN。"
        echo "  3) 证书匹配域名，支持 TLS 1.3 + H2，根路径不返回 30x。"
        echo "  4) 不要指向当前 Reality 公网监听端口，以免形成自连接回环。"
        read -r -p "请输入自有 Reality 目标域名: " own_domain
        own_domain=$(printf '%s' "$own_domain" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
        if _is_valid_reality_domain "$own_domain" && _probe_reality_target "$own_domain" "$own_domain"; then
            SELECTED_REALITY_SNI="$own_domain"
            SELECTED_REALITY_HANDSHAKE_SERVER="$own_domain"
            SELECTED_REALITY_HANDSHAKE_PORT=443
            _success "自有域名已通过 TLS/H2/跳转/Cloudflare 复核。"
            _info "Reality SNI: ${SELECTED_REALITY_SNI} | 握手目标: ${SELECTED_REALITY_HANDSHAKE_SERVER}:${SELECTED_REALITY_HANDSHAKE_PORT}"
            return 0
        fi
        _warn "自有域名未通过复核：${REALITY_PROBE_ERROR:-域名格式无效}。将转入扫描/默认选择。"
    fi

    local scan_choice scan_action greatfire_choice default_china_status="未验证"
    echo ""
    _warn "境外 VPS 无法自行证明候选域名在中国大陆可达。"
    echo "  可选的大陆侧校验会把候选 HTTPS 域名提交给 GreatFire。"
    echo "  GreatFire 使用中国大陆探针与境外对照点测试，测量结果可能公开；不会提交你的 VPS IP、UUID 或 Reality 密钥。"
    read -r -p "是否启用 GreatFire 大陆可达性筛查？[Y/n]: " greatfire_choice
    if [[ "$greatfire_choice" == "n" || "$greatfire_choice" == "N" ]]; then
        REALITY_CHINA_CHECK_ENABLED=false
        _warn "已关闭大陆侧校验；选择候选时需要再次明确确认风险。"
    else
        REALITY_CHINA_CHECK_ENABLED=true
    fi

    read -r -p "是否使用 XTLS/RealiTLScanner 查找 Reality 候选？[Y/n]: " scan_choice
    if [[ "$scan_choice" != "n" && "$scan_choice" != "N" ]]; then
        while ! _scan_reality_sni_once; do
            while true; do
                echo "  1) 重新扫描（默认）"
                echo "  2) 跳过扫描，进入默认域名选择"
                echo "  0) 取消本次 Reality 节点添加"
                read -r -p "扫描未成功，请选择 [0-2] (默认: 1): " scan_action
                scan_action="${scan_action:-1}"
                case "$scan_action" in
                    1) break ;;
                    2) break 2 ;;
                    0)
                        _info "已取消本次 Reality 节点添加。"
                        return 1
                        ;;
                    *) _warn "无效选择，请重新输入。" ;;
                esac
            done
        done
    fi

    if [ "$REALITY_CHINA_CHECK_ENABLED" = "true" ]; then
        _greatfire_cached_verdict "$DEFAULT_REALITY_SNI"
        default_china_status="$GREATFIRE_RESULT_LABEL"
    fi

    local i sni_choice force_default
    while true; do
        echo "请选择 Reality SNI（候选已按 TLS 延迟从低到高排序）:"
        echo "  回车) ${DEFAULT_REALITY_SNI} (默认，AMD 官方站点；仍需现场复核；大陆判定: ${default_china_status})"
        for i in "${!REALITY_SNI_DOMAINS[@]}"; do
            printf '  %d) %s (目标 %s:443, %s ms；大陆判定: %s)\n' "$((i + 1))" \
                "${REALITY_SNI_DOMAINS[$i]}" "${REALITY_SNI_TARGETS[$i]}" \
                "${REALITY_SNI_LATENCIES[$i]}" "${REALITY_SNI_CHINA_STATUSES[$i]:-未验证}"
        done
        echo "  0) 取消本次 Reality 节点添加"

        SELECTED_REALITY_SNI="$DEFAULT_REALITY_SNI"
        SELECTED_REALITY_HANDSHAKE_SERVER="$DEFAULT_REALITY_SNI"
        SELECTED_REALITY_HANDSHAKE_PORT=443
        read -r -p "请输入候选编号，回车使用 ${DEFAULT_REALITY_SNI}，或输入 0 取消: " sni_choice
        if [ "$sni_choice" = "0" ]; then
            _info "已取消本次 Reality 节点添加。"
            return 1
        elif [[ "$sni_choice" =~ ^[0-9]+$ ]] && [ "$sni_choice" -ge 1 ] && [ "$sni_choice" -le "${#REALITY_SNI_DOMAINS[@]}" ]; then
            SELECTED_REALITY_SNI="${REALITY_SNI_DOMAINS[$((sni_choice - 1))]}"
            SELECTED_REALITY_HANDSHAKE_SERVER="${REALITY_SNI_TARGETS[$((sni_choice - 1))]}"
        elif [ -n "$sni_choice" ]; then
            _warning "编号无效，已使用默认 ${DEFAULT_REALITY_SNI}。"
        fi

        if [ "$SELECTED_REALITY_SNI" = "$DEFAULT_REALITY_SNI" ] && \
           ! _probe_reality_target "$DEFAULT_REALITY_SNI" "$DEFAULT_REALITY_SNI"; then
            _warn "默认目标当前复核失败：${REALITY_PROBE_ERROR}；建议重新选择扫描结果。"
            read -r -p "仍要继续检查该默认目标的大陆可达性？[y/N]: " force_default
            if [[ "$force_default" != "y" && "$force_default" != "Y" ]]; then
                continue
            fi
        fi
        if _confirm_reality_china_reachability "$SELECTED_REALITY_SNI"; then
            break
        fi
        _warn "该候选未通过严格大陆可达性筛查，请重新选择。"
    done
    _info "Reality SNI: ${SELECTED_REALITY_SNI} | 握手目标: ${SELECTED_REALITY_HANDSHAKE_SERVER}:${SELECTED_REALITY_HANDSHAKE_PORT}"
}

_validate_reality_no_self_loop() {
    local listen_port="$1" target="$2" target_port="${3:-443}" public_ip target_ip
    [ "$listen_port" = "$target_port" ] || return 0
    if [[ "$target" == 127.* || "$target" == "::1" || "$target" == "localhost" ]]; then
        _error "Reality 入站与本机握手目标同时使用 ${target_port}，会发生端口冲突或自连接回环。"
        return 1
    fi
    public_ip=$(_get_public_ip 2>/dev/null || true)
    _is_valid_ipv4 "$public_ip" || return 0
    if _is_valid_ipv4 "$target"; then
        [ "$target" = "$public_ip" ] || return 0
    else
        while read -r target_ip; do
            [ "$target_ip" = "$public_ip" ] && {
                _error "Reality 握手目标 ${target}:${target_port} 解析回本机，与入站 ${listen_port} 形成自连接回环。"
                return 1
            }
        done < <(getent ahostsv4 "$target" 2>/dev/null | awk '{print $1}' | sort -u)
        return 0
    fi
    _error "Reality 握手目标 ${target}:${target_port} 就是本机公网 IP，与入站 ${listen_port} 形成自连接回环。"
    return 1
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

# 配置文件端口扫描 (预检是否已被本程序占用)
_check_port_in_config() {
    local port=$1
    [ ! -f "$CONFIG_FILE" ] && return 1
    jq -e ".inbounds[] | select(.listen_port == ($port|tonumber))" "$CONFIG_FILE" >/dev/null 2>&1
}

# 综合端口碰撞检测
_check_port_conflict() {
    local port=$1
    local proto=${2:-tcp}
    local silent=${3:-false}
    if _check_port_in_config "$port"; then
        [ "$silent" != "true" ] && _error "端口 ${port} 已在 sing-box 配置文件中被占用。"
        return 0
    fi
    if _check_port_occupied "$port" "$proto"; then
        [ "$silent" != "true" ] && _error "端口 ${port} 已被系统其他程序占用。"
        return 0
    fi
    if [[ "$proto" == "udp" ]]; then
        local hop_conflict
        hop_conflict=$(_find_udp_hop_conflict_in_range "$port" "$port")
        if [ -n "$hop_conflict" ]; then
            local c_tag c_name c_range c_mode
            IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$hop_conflict"
            [ "$silent" != "true" ] && _error "UDP 端口 ${port} 落在已有 HY2 端口跳跃范围 ${c_range} 内（${c_name}, ${c_tag}, ${c_mode}）。"
            return 0
        fi
    fi
    return 1
}

_find_pf_udp_conflict_in_range() {
    local start="$1" end="$2"
    local pf_meta="${SINGBOX_DIR}/relay_pf.json"
    [ -f "$pf_meta" ] || return 1
    jq -r --argjson start "$start" --argjson end "$end" '
        to_entries[]
        | (.key | tonumber?) as $port
        | select($port != null and $port >= $start and $port <= $end)
        | select(.value.network == "udp" or .value.network == "tcp+udp")
        | [
            .key,
            (.value.name // "端口转发"),
            (.value.network_display // .value.network // "UDP"),
            ((.value.target_addr // "") + ":" + ((.value.target_port // "") | tostring))
          ]
        | @tsv
    ' "$pf_meta" 2>/dev/null | head -n 1
}

_find_udp_hop_conflict_in_range() {
    local start="$1" end="$2" exclude_tag="${3:-}"
    local conflict=""
    if [ -f "$METADATA_FILE" ]; then
        conflict=$(jq -r --argjson start "$start" --argjson end "$end" --arg exclude "$exclude_tag" '
            to_entries[]
            | select(.key != $exclude)
            | select(.value.portHopping)
            | (.value.portHopping | capture("^(?<start>[0-9]+)-(?<end>[0-9]+)$")?) as $range
            | select($range != null)
            | ($range.start | tonumber) as $other_start
            | ($range.end | tonumber) as $other_end
            | select($start <= $other_end and $end >= $other_start)
            | [
                .key,
                (.value.name // .key),
                .value.portHopping,
                ("主HY2/" + (.value.portHoppingMode // "unknown"))
              ]
            | @tsv
        ' "$METADATA_FILE" 2>/dev/null | head -n 1)
        [ -n "$conflict" ] && { echo "$conflict"; return 0; }
    fi

    local relay_links="${SINGBOX_DIR}/relay_links.json"
    if [ -f "$relay_links" ]; then
        conflict=$(jq -r --argjson start "$start" --argjson end "$end" --arg exclude "$exclude_tag" '
            to_entries[]
            | select(.key != $exclude)
            | select(.value.port_hopping)
            | (.value.port_hopping | capture("^(?<start>[0-9]+)-(?<end>[0-9]+)$")?) as $range
            | select($range != null)
            | ($range.start | tonumber) as $other_start
            | ($range.end | tonumber) as $other_end
            | select($start <= $other_end and $end >= $other_start)
            | [
                .key,
                (.value.node_name // .key),
                .value.port_hopping,
                "中转HY2/nftables"
              ]
            | @tsv
        ' "$relay_links" 2>/dev/null | head -n 1)
        [ -n "$conflict" ] && { echo "$conflict"; return 0; }
    fi

    return 1
}

# nftables 规则管理 (独立表，避免污染系统其他防火墙规则)
export NFT_TABLE="singboxlite"
export NFT_PERSIST_FILE="/etc/nftables.d/singboxlite.nft"

_nft_ensure_base() {
    command -v nft &>/dev/null || return 1
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || nft add table inet "$NFT_TABLE" >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" prerouting >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" prerouting '{ type nat hook prerouting priority -100; policy accept; }' >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" output >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" output '{ type nat hook output priority -100; policy accept; }' >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" postrouting >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" postrouting '{ type nat hook postrouting priority 100; policy accept; }' >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" forward >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" forward '{ type filter hook forward priority 0; policy accept; }' >/dev/null 2>&1 || return 1
}

_nft_delete_rules_by_comment() {
    local comment="$1"
    local entries chain handle
    command -v nft &>/dev/null || return 0
    entries=$(nft -a list table inet "$NFT_TABLE" 2>/dev/null | awk -v c="comment \"$comment\"" '
        /^[[:space:]]*chain / { chain=$2 }
        index($0, c) && /# handle / { print chain, $NF }
    ')
    [ -z "$entries" ] && return 0
    while read -r chain handle; do
        [ -n "$chain" ] && [ -n "$handle" ] && nft delete rule inet "$NFT_TABLE" "$chain" handle "$handle" >/dev/null 2>&1
    done <<< "$entries"
}

_nft_port_expr() {
    local start="$1" end="$2"
    if [ "$start" = "$end" ]; then
        echo "$start"
    else
        echo "${start}-${end}"
    fi
}

_nft_apply_redirect_rule() {
    local action="$1" start_port="$2" end_port="$3" target_port="$4" comment="$5"
    if [ "$action" = "delete" ]; then
        _nft_delete_rules_by_comment "$comment"
        return 0
    fi
    _nft_ensure_base || return 1
    _nft_delete_rules_by_comment "$comment"
    nft add rule inet "$NFT_TABLE" prerouting udp dport "$(_nft_port_expr "$start_port" "$end_port")" redirect to ":${target_port}" comment "$comment" >/dev/null 2>&1
}

_nft_can_redirect() {
    local test_port="${1:-65530}" target_port="${2:-65531}" comment="singboxlite-test-redirect-$$"
    _nft_apply_redirect_rule add "$test_port" "$test_port" "$target_port" "$comment" || return 1
    _nft_apply_redirect_rule delete "$test_port" "$test_port" "$target_port" "$comment"
    return 0
}

_save_nftables_rules() {
    command -v nft &>/dev/null || return 0
    mkdir -p /etc/nftables.d
    if nft list table inet "$NFT_TABLE" > "$NFT_PERSIST_FILE" 2>/dev/null; then
        if [ ! -f /etc/nftables.conf ]; then
            {
                echo '#!/usr/sbin/nft -f'
                echo 'include "/etc/nftables.d/*.nft"'
            } > /etc/nftables.conf
        elif ! grep -q 'singboxlite\.nft\|/etc/nftables\.d/\*\.nft' /etc/nftables.conf 2>/dev/null; then
            echo 'include "/etc/nftables.d/singboxlite.nft"' >> /etc/nftables.conf
        fi
        if command -v systemctl &>/dev/null; then
            systemctl enable nftables >/dev/null 2>&1 || true
        fi
        if command -v rc-update &>/dev/null; then
            rc-update add nftables default >/dev/null 2>&1 || true
        fi
    fi
}

_remove_nftables_rules() {
    if command -v nft &>/dev/null; then
        nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    fi
    rm -f "$NFT_PERSIST_FILE"
    if [ -f /etc/nftables.conf ]; then
        sed -i '\|/etc/nftables.d/singboxlite.nft|d' /etc/nftables.conf 2>/dev/null || true
    fi
}

# 公网 IP 初始化
_init_server_ip() {
    _info "正在获取服务器公网 IP..."
    server_ip=$(_get_public_ip)
    if [ -z "$server_ip" ] || [ "$server_ip" == "null" ]; then
        _warn "自动获取 IP 失败，将回退到 127.0.0.1"
        server_ip="127.0.0.1"
    else
        _success "当前服务器公网 IP: ${server_ip}"
    fi
}

# 统一服务管理
_manage_service() {
    local action="$1"

    # [关键核心修复] 动态注入内置 NTP 时间同步模块
    # 解决部分廉价 LXC/Docker 容器无法修改母机系统时间，导致 SS-2022 触发 30s 重放保护直接爆 bad timestamp 拒连的断流问题
    if [[ "$action" == "restart" || "$action" == "start" ]]; then
        if [ -s "$CONFIG_FILE" ] && ! jq -e '.ntp' "$CONFIG_FILE" >/dev/null 2>&1; then
            _info "检测到内核配置缺失内置时间同步(NTP)模块，正在自动注入防重放保护补丁..."
            _atomic_modify_json "$CONFIG_FILE" '.ntp = {"enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "30m"}' 2>/dev/null
        fi
    fi

    [ -z "$INIT_SYSTEM" ] && _detect_init_system
    [ "$action" == "status" ] || _info "正在使用 ${INIT_SYSTEM} 执行: $action..."
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" == "status" ]; then systemctl status sing-box --no-pager -l; return; fi
            systemctl "$action" sing-box ;;
        openrc)
            if [ "$action" == "status" ]; then rc-service sing-box status; return; fi
            rc-service sing-box "$action" ;;
        direct)
            case "$action" in
                start)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box 已在 direct 模式运行。"
                        return 0
                    fi
                    rm -f "$PID_FILE"
                    [ -s "${SINGBOX_DIR}/relay.json" ] || echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "${SINGBOX_DIR}/relay.json"
                    nohup env GOMEMLIMIT="$(_get_mem_limit)MiB" \
                        "$SINGBOX_BIN" run -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" \
                        >> "$LOG_FILE" 2>&1 &
                    echo $! > "$PID_FILE"
                    _success "sing-box 已以 direct 后台模式启动。"
                    ;;
                stop)
                    if [ -s "$PID_FILE" ]; then
                        local pid
                        pid=$(cat "$PID_FILE" 2>/dev/null)
                        if _is_pid_running_cmd "$pid" "$SINGBOX_BIN"; then
                            kill "$pid" 2>/dev/null
                        fi
                    fi
                    rm -f "$PID_FILE"
                    _success "sing-box direct 后台进程已停止。"
                    ;;
                restart)
                    _manage_service stop
                    sleep 1
                    _manage_service start
                    ;;
                status)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box direct 后台模式运行中 (PID: $(cat "$PID_FILE"))"
                    else
                        rm -f "$PID_FILE"
                        _warn "sing-box direct 后台模式未运行。"
                        return 1
                    fi
                    ;;
                *) _error "direct 模式不支持的服务操作: $action"; return 1 ;;
            esac
            ;;
        *) _error "不支持的服务管理系统" ;;
    esac
}

# 智能包管理
_pkg_install() {
    local pkgs="$*"
    [ -z "$pkgs" ] && return 0
    if command -v apk &>/dev/null; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get &>/dev/null; then
        # 全新 LXC/容器上 apt 缓存可能为空，必须先 update
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls -A /var/lib/apt/lists/ 2>/dev/null | wc -l)" -le 1 ]; then
            apt-get update -qq >/dev/null 2>&1
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || {
            # 兜底：如果安装失败，强制刷新索引后重试
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
        }
    elif command -v yum &>/dev/null; then yum install -y $pkgs >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then dnf install -y $pkgs >/dev/null 2>&1
    else
        return 1
    fi
}

# --- HAProxy TCP/443 SNI 共享入口 ---

_sni_router_require_systemd() {
    _detect_init_system
    if [ "$INIT_SYSTEM" != "systemd" ]; then
        _error "HAProxy SNI 共享入口当前仅支持 systemd。"
        return 1
    fi
}

_sni_router_lock() {
    command -v flock >/dev/null 2>&1 || _pkg_install util-linux || return 1
    mkdir -p "$(dirname "$SNI_ROUTER_LOCK_FILE")" || return 1
    exec 9>"$SNI_ROUTER_LOCK_FILE"
    flock -x 9
}

_sni_router_init_state() {
    mkdir -p "$SNI_ROUTER_STATE_DIR" || return 1
    chmod 700 "$SNI_ROUTER_STATE_DIR" 2>/dev/null || true
    if [ ! -s "$SNI_ROUTER_STATE_FILE" ]; then
        local tmp
        tmp=$(mktemp "${SNI_ROUTER_STATE_DIR}/state.XXXXXX") || return 1
        jq -n --argjson version "$SNI_ROUTER_API_VERSION" --argjson port "$SNI_ROUTER_PUBLIC_PORT" \
            '{version:$version,public_port:$port,reality:null,https_backend:null,https_routes:{},tls_routes:{}}' > "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        chmod 600 "$tmp"
        mv "$tmp" "$SNI_ROUTER_STATE_FILE"
    fi
    if ! jq -e --argjson version "$SNI_ROUTER_API_VERSION" \
        '.version == $version and (.https_routes | type == "object")' \
        "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
        _error "SNI 路由状态版本不兼容: ${SNI_ROUTER_STATE_FILE}"
        return 1
    fi
    if ! jq -e '.tls_routes | type == "object"' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
        local migrate_tmp
        migrate_tmp=$(mktemp "${SNI_ROUTER_STATE_DIR}/state.XXXXXX") || return 1
        jq '.tls_routes={}' "$SNI_ROUTER_STATE_FILE" > "$migrate_tmp" || {
            rm -f "$migrate_tmp"
            return 1
        }
        chmod 600 "$migrate_tmp"
        mv "$migrate_tmp" "$SNI_ROUTER_STATE_FILE"
    fi
}

_sni_router_state_has_routes() {
    jq -e '(.reality != null) or ((.https_routes | length) > 0) or ((.tls_routes | length) > 0)' \
        "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1
}

_sni_router_validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_sni_router_allocate_backend_port() {
    local preferred="${1:-$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT}" port
    _sni_router_validate_port "$preferred" || return 1
    for ((port=preferred; port<=preferred+99 && port<=65535; port++)); do
        [ "$port" -eq "$REALITY_LOCAL_ORIGIN_PORT" ] && continue
        [ "$port" -eq "$SNI_ROUTER_HTTPS_BACKEND_PORT" ] && continue
        if [ -f "$CONFIG_FILE" ] && jq -e --argjson p "$port" \
            '.inbounds[]? | select(.listen_port == $p)' "$CONFIG_FILE" >/dev/null 2>&1; then
            continue
        fi
        if [ -f "${SINGBOX_DIR}/relay.json" ] && jq -e --argjson p "$port" \
            '.inbounds[]? | select(.listen_port == $p)' "${SINGBOX_DIR}/relay.json" >/dev/null 2>&1; then
            continue
        fi
        _check_port_occupied "$port" tcp && continue
        printf '%s\n' "$port"
        return 0
    done
    _error "未找到可用的 TLS 回环后端端口。"
    return 1
}

_sni_router_prepare_haproxy() {
    _sni_router_require_systemd || return 1
    if ! command -v haproxy >/dev/null 2>&1; then
        _info "正在安装 HAProxy（仅用于 TCP/443 SNI 分流）..."
        _pkg_install haproxy util-linux || {
            _error "HAProxy 安装失败。"
            return 1
        }
    fi

    mkdir -p "$(dirname "$SNI_ROUTER_HAPROXY_CONF")" "$SNI_ROUTER_HAPROXY_BACKUP_DIR" || return 1
    chmod 700 "$SNI_ROUTER_HAPROXY_BACKUP_DIR" 2>/dev/null || true
    if [ -f "$SNI_ROUTER_HAPROXY_CONF" ] && ! grep -Fq "$SNI_ROUTER_MARKER" "$SNI_ROUTER_HAPROXY_CONF"; then
        if grep -Eq '^[[:space:]]*(frontend|listen)[[:space:]]' "$SNI_ROUTER_HAPROXY_CONF"; then
            _error "检测到非 sb.sh 管理的 HAProxy 前端，拒绝覆盖: ${SNI_ROUTER_HAPROXY_CONF}"
            _error "请先手动整合现有 HAProxy 配置。"
            return 1
        fi
        cp -a -- "$SNI_ROUTER_HAPROXY_CONF" \
            "${SNI_ROUTER_HAPROXY_BACKUP_DIR}/haproxy.cfg.$(date +%Y%m%d_%H%M%S).$$" || return 1
        systemctl stop haproxy >/dev/null 2>&1 || true
    fi
}

_sni_router_generate_haproxy_config() {
    local output="$1" public_port reality_host reality_port https_host https_port
    public_port=$(jq -r '.public_port' "$SNI_ROUTER_STATE_FILE")
    reality_host=$(jq -r '.reality.backend_host // empty' "$SNI_ROUTER_STATE_FILE")
    reality_port=$(jq -r '.reality.backend_port // empty' "$SNI_ROUTER_STATE_FILE")
    https_host=$(jq -r '.https_backend.host // empty' "$SNI_ROUTER_STATE_FILE")
    https_port=$(jq -r '.https_backend.port // empty' "$SNI_ROUTER_STATE_FILE")

    {
        echo "$SNI_ROUTER_MARKER"
        echo '# TLS remains end-to-end; HAProxy only inspects ClientHello SNI.'
        cat <<'EOF_HAPROXY_GLOBAL'
global
    log /dev/log local0
    log /dev/log local1 notice
    user haproxy
    group haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend sb_sni_443
EOF_HAPROXY_GLOBAL
        echo "    bind 0.0.0.0:${public_port}"
        if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && \
           [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "0" ]; then
            echo "    bind [::]:${public_port} v6only"
        fi
        cat <<'EOF_HAPROXY_INSPECT'
    tcp-request inspect-delay 5s
    acl sb_tls_client_hello req.ssl_hello_type 1
EOF_HAPROXY_INSPECT

        local domain route_count=0 tls_route_count=0 conditions="" i tls_host tls_port
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "    acl sb_https_${route_count} req.ssl_sni -i ${domain}"
            route_count=$((route_count + 1))
        done < <(jq -r '.https_routes | keys[]?' "$SNI_ROUTER_STATE_FILE")

        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "    acl sb_tls_route_${tls_route_count} req.ssl_sni -i ${domain}"
            tls_route_count=$((tls_route_count + 1))
        done < <(jq -r '.tls_routes | keys[]?' "$SNI_ROUTER_STATE_FILE")

        if [ -z "$reality_host" ] && [ -z "$reality_port" ] && [ $((route_count + tls_route_count)) -gt 0 ]; then
            for ((i=0; i<route_count; i++)); do conditions="${conditions} !sb_https_${i}"; done
            for ((i=0; i<tls_route_count; i++)); do conditions="${conditions} !sb_tls_route_${i}"; done
            echo "    tcp-request content reject if sb_tls_client_hello${conditions}"
        fi
        echo '    tcp-request content accept if sb_tls_client_hello'
        for ((i=0; i<route_count; i++)); do
            echo "    use_backend sb_https_backend if sb_https_${i}"
        done
        for ((i=0; i<tls_route_count; i++)); do
            echo "    use_backend sb_tls_backend_${i} if sb_tls_route_${i}"
        done
        if [ -n "$reality_host" ] && [ -n "$reality_port" ]; then
            echo '    default_backend sb_reality_backend'
        fi

        if [ "$route_count" -gt 0 ]; then
            cat <<EOF_HAPROXY_HTTPS

backend sb_https_backend
    server nginx ${https_host}:${https_port} send-proxy-v2 check
EOF_HAPROXY_HTTPS
        fi
        i=0
        while IFS=$'\t' read -r tls_host tls_port; do
            [ -n "$tls_host" ] && [ -n "$tls_port" ] || continue
            cat <<EOF_HAPROXY_TLS

backend sb_tls_backend_${i}
    server singbox_${i} ${tls_host}:${tls_port} check
EOF_HAPROXY_TLS
            i=$((i + 1))
        done < <(jq -r '.tls_routes | to_entries | sort_by(.key)[]? | [.value.backend_host, (.value.backend_port|tostring)] | @tsv' "$SNI_ROUTER_STATE_FILE")
        if [ -n "$reality_host" ] && [ -n "$reality_port" ]; then
            cat <<EOF_HAPROXY_REALITY

backend sb_reality_backend
    server singbox ${reality_host}:${reality_port} check
EOF_HAPROXY_REALITY
        fi
    } > "$output"
}

_sni_router_apply() {
    _sni_router_init_state || return 1
    if ! _sni_router_state_has_routes; then
        if [ -f "$SNI_ROUTER_HAPROXY_CONF" ] && grep -Fq "$SNI_ROUTER_MARKER" "$SNI_ROUTER_HAPROXY_CONF"; then
            systemctl disable --now haproxy >/dev/null 2>&1 || true
        fi
        return 0
    fi
    _sni_router_prepare_haproxy || return 1

    local new_conf old_conf had_old=no
    new_conf=$(mktemp) || return 1
    old_conf=$(mktemp) || { rm -f "$new_conf"; return 1; }
    _sni_router_generate_haproxy_config "$new_conf" || { rm -f "$new_conf" "$old_conf"; return 1; }
    if ! haproxy -c -f "$new_conf"; then
        _error "HAProxy 配置验证失败，未安装新配置。"
        rm -f "$new_conf" "$old_conf"
        return 1
    fi
    if [ -f "$SNI_ROUTER_HAPROXY_CONF" ]; then
        cp -a -- "$SNI_ROUTER_HAPROXY_CONF" "$old_conf" || { rm -f "$new_conf" "$old_conf"; return 1; }
        had_old=yes
    fi
    install -m 640 "$new_conf" "${SNI_ROUTER_HAPROXY_CONF}.new" || { rm -f "$new_conf" "$old_conf"; return 1; }
    mv "${SNI_ROUTER_HAPROXY_CONF}.new" "$SNI_ROUTER_HAPROXY_CONF" || { rm -f "$new_conf" "$old_conf"; return 1; }
    rm -f "$new_conf"

    systemctl enable haproxy >/dev/null 2>&1 || true
    if systemctl is-active haproxy >/dev/null 2>&1; then
        systemctl reload haproxy
    else
        systemctl start haproxy
    fi
    if [ $? -ne 0 ]; then
        _error "HAProxy 加载失败，正在恢复上一份配置。"
        if [ "$had_old" = yes ]; then
            cp -a -- "$old_conf" "$SNI_ROUTER_HAPROXY_CONF"
            systemctl restart haproxy >/dev/null 2>&1 || true
        else
            rm -f "$SNI_ROUTER_HAPROXY_CONF"
            systemctl stop haproxy >/dev/null 2>&1 || true
        fi
        rm -f "$old_conf"
        return 1
    fi
    rm -f "$old_conf"
    return 0
}

_sni_router_restore_state() {
    local backup="$1"
    cp -a -- "$backup" "$SNI_ROUTER_STATE_FILE"
    _sni_router_apply >/dev/null 2>&1 || true
}

_sni_router_register_reality() {
    local owner="$1" tag="$2" sni="$3" backend_port="$4"
    _is_valid_reality_domain "$sni" || { _error "Reality SNI 格式无效: ${sni}"; return 1; }
    _sni_router_validate_port "$backend_port" || { _error "Reality 后端端口无效。"; return 1; }
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing conflicting_https conflicting_tls backup tmp
    existing=$(jq -r '.reality.tag // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$existing" ] && [ "$existing" != "$tag" ]; then
        _error "公网 443 已登记 Reality 后端: ${existing}。一个 443 入口只能指定一个默认 Reality 后端。"
        return 1
    fi
    conflicting_https=$(jq -r --arg sni "${sni,,}" '.https_routes[$sni].owner // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$conflicting_https" ]; then
        _error "Reality SNI ${sni,,} 已被 HTTPS 路由 ${conflicting_https} 使用；两者必须使用不同域名。"
        return 1
    fi
    conflicting_tls=$(jq -r --arg sni "${sni,,}" '.tls_routes[$sni].tag // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$conflicting_tls" ]; then
        _error "Reality SNI ${sni,,} 已被 TLS 路由 ${conflicting_tls} 使用；两者必须使用不同域名。"
        return 1
    fi
    backup=$(mktemp); tmp=$(mktemp) || { rm -f "$backup"; return 1; }
    cp -a -- "$SNI_ROUTER_STATE_FILE" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    jq --arg owner "$owner" --arg tag "$tag" --arg sni "${sni,,}" --argjson port "$backend_port" \
        '.reality={owner:$owner,tag:$tag,sni:$sni,backend_host:"127.0.0.1",backend_port:$port}' \
        "$SNI_ROUTER_STATE_FILE" > "$tmp" || { rm -f "$backup" "$tmp"; return 1; }
    chmod 600 "$tmp"; mv "$tmp" "$SNI_ROUTER_STATE_FILE"
    if ! _sni_router_apply; then
        _sni_router_restore_state "$backup"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

_sni_router_remove_reality() {
    local tag="${1:-}"
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing backup tmp
    existing=$(jq -r '.reality.tag // empty' "$SNI_ROUTER_STATE_FILE")
    [ -n "$existing" ] || return 0
    if [ -n "$tag" ] && [ "$tag" != "$existing" ]; then
        _error "Reality 默认后端属于 ${existing}，拒绝按不匹配的 tag ${tag} 删除。"
        return 1
    fi
    backup=$(mktemp); tmp=$(mktemp) || { rm -f "$backup"; return 1; }
    cp -a -- "$SNI_ROUTER_STATE_FILE" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    jq '.reality=null' "$SNI_ROUTER_STATE_FILE" > "$tmp" || { rm -f "$backup" "$tmp"; return 1; }
    chmod 600 "$tmp"; mv "$tmp" "$SNI_ROUTER_STATE_FILE"
    if ! _sni_router_apply; then
        _sni_router_restore_state "$backup"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

_sni_router_register_tls() {
    local owner="$1" tag="$2" sni="${3,,}" backend_port="$4"
    _is_valid_reality_domain "$sni" || { _error "TLS SNI 格式无效: ${sni}"; return 1; }
    _sni_router_validate_port "$backend_port" || { _error "TLS 后端端口无效。"; return 1; }
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing_tag conflicting_https reality_sni backup tmp
    existing_tag=$(jq -r --arg sni "$sni" '.tls_routes[$sni].tag // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$existing_tag" ] && [ "$existing_tag" != "$tag" ]; then
        _error "TLS SNI ${sni} 已由 ${existing_tag} 登记。"
        return 1
    fi
    conflicting_https=$(jq -r --arg sni "$sni" '.https_routes[$sni].owner // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$conflicting_https" ]; then
        _error "TLS SNI ${sni} 已被 HTTPS 路由 ${conflicting_https} 使用。"
        return 1
    fi
    reality_sni=$(jq -r '.reality.sni // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$reality_sni" ] && [ "$reality_sni" = "$sni" ]; then
        _error "TLS SNI ${sni} 与 Reality SNI 相同；两者必须使用不同域名。"
        return 1
    fi
    backup=$(mktemp); tmp=$(mktemp) || { rm -f "$backup"; return 1; }
    cp -a -- "$SNI_ROUTER_STATE_FILE" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    jq --arg owner "$owner" --arg tag "$tag" --arg sni "$sni" --argjson port "$backend_port" \
        '.tls_routes[$sni]={owner:$owner,tag:$tag,backend_host:"127.0.0.1",backend_port:$port}' \
        "$SNI_ROUTER_STATE_FILE" > "$tmp" || { rm -f "$backup" "$tmp"; return 1; }
    chmod 600 "$tmp"; mv "$tmp" "$SNI_ROUTER_STATE_FILE"
    if ! _sni_router_apply; then
        _sni_router_restore_state "$backup"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

_sni_router_remove_tls() {
    local tag="$1"
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local sni backup tmp
    sni=$(jq -r --arg tag "$tag" '.tls_routes | to_entries[]? | select(.value.tag == $tag) | .key' "$SNI_ROUTER_STATE_FILE" | head -n 1)
    [ -n "$sni" ] || return 0
    backup=$(mktemp); tmp=$(mktemp) || { rm -f "$backup"; return 1; }
    cp -a -- "$SNI_ROUTER_STATE_FILE" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    jq --arg sni "$sni" 'del(.tls_routes[$sni])' "$SNI_ROUTER_STATE_FILE" > "$tmp" || {
        rm -f "$backup" "$tmp"
        return 1
    }
    chmod 600 "$tmp"; mv "$tmp" "$SNI_ROUTER_STATE_FILE"
    if ! _sni_router_apply; then
        _sni_router_restore_state "$backup"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

_sni_router_register_https() {
    local owner="$1" sni="${2,,}" backend_port="$3"
    _is_valid_reality_domain "$sni" || { _error "HTTPS SNI 格式无效: ${sni}"; return 1; }
    _sni_router_validate_port "$backend_port" || { _error "HTTPS 后端端口无效。"; return 1; }
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing_owner existing_port reality_sni conflicting_tls backup tmp
    existing_owner=$(jq -r --arg sni "$sni" '.https_routes[$sni].owner // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$existing_owner" ] && [ "$existing_owner" != "$owner" ]; then
        _error "SNI ${sni} 已由 ${existing_owner} 登记。"
        return 1
    fi
    reality_sni=$(jq -r '.reality.sni // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$reality_sni" ] && [ "$reality_sni" = "$sni" ]; then
        _error "HTTPS SNI ${sni} 与 Reality SNI 相同；两者必须使用不同域名。"
        return 1
    fi
    conflicting_tls=$(jq -r --arg sni "$sni" '.tls_routes[$sni].tag // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$conflicting_tls" ]; then
        _error "HTTPS SNI ${sni} 已被 TLS 路由 ${conflicting_tls} 使用。"
        return 1
    fi
    existing_port=$(jq -r '.https_backend.port // empty' "$SNI_ROUTER_STATE_FILE")
    if [ -n "$existing_port" ] && [ "$existing_port" != "$backend_port" ]; then
        _error "现有 HTTPS 后端为 127.0.0.1:${existing_port}，拒绝混用 ${backend_port}。"
        return 1
    fi
    backup=$(mktemp); tmp=$(mktemp) || { rm -f "$backup"; return 1; }
    cp -a -- "$SNI_ROUTER_STATE_FILE" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    jq --arg owner "$owner" --arg sni "$sni" --argjson port "$backend_port" \
        '.https_backend={host:"127.0.0.1",port:$port} | .https_routes[$sni]={owner:$owner}' \
        "$SNI_ROUTER_STATE_FILE" > "$tmp" || { rm -f "$backup" "$tmp"; return 1; }
    chmod 600 "$tmp"; mv "$tmp" "$SNI_ROUTER_STATE_FILE"
    if ! _sni_router_apply; then
        _sni_router_restore_state "$backup"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

_sni_router_remove_https() {
    local owner="$1" sni="${2,,}"
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing_owner backup tmp
    existing_owner=$(jq -r --arg sni "$sni" '.https_routes[$sni].owner // empty' "$SNI_ROUTER_STATE_FILE")
    [ -n "$existing_owner" ] || return 0
    if [ -n "$owner" ] && [ "$owner" != "$existing_owner" ]; then
        _error "SNI ${sni} 属于 ${existing_owner}，拒绝由 ${owner} 删除。"
        return 1
    fi
    backup=$(mktemp); tmp=$(mktemp) || { rm -f "$backup"; return 1; }
    cp -a -- "$SNI_ROUTER_STATE_FILE" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    jq --arg sni "$sni" \
        'del(.https_routes[$sni]) | if (.https_routes|length)==0 then .https_backend=null else . end' \
        "$SNI_ROUTER_STATE_FILE" > "$tmp" || { rm -f "$backup" "$tmp"; return 1; }
    chmod 600 "$tmp"; mv "$tmp" "$SNI_ROUTER_STATE_FILE"
    if ! _sni_router_apply; then
        _sni_router_restore_state "$backup"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

_sni_router_status() {
    _sni_router_init_state || return 1
    echo "SNI_ROUTER_API_VERSION=${SNI_ROUTER_API_VERSION}"
    jq -r '
        . as $root |
        "public=:" + (.public_port|tostring),
        (if .reality then "reality=" + .reality.sni + " -> " + .reality.backend_host + ":" + (.reality.backend_port|tostring) else "reality=未登记" end),
        (if (.https_routes|length)>0 then (.https_routes|to_entries[]|"https="+.key+" -> "+$root.https_backend.host+":"+($root.https_backend.port|tostring)+" ("+.value.owner+")") else "https=未登记" end),
        (if (.tls_routes|length)>0 then (.tls_routes|to_entries[]|"tls="+.key+" -> "+.value.backend_host+":"+(.value.backend_port|tostring)+" ("+.value.tag+")") else "tls=未登记" end)
    ' "$SNI_ROUTER_STATE_FILE"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active haproxy >/dev/null 2>&1; then
        echo 'haproxy=active'
    else
        echo 'haproxy=inactive'
    fi
}

_sni_router_check() {
    _sni_router_init_state || return 1
    if _sni_router_state_has_routes; then
        command -v haproxy >/dev/null 2>&1 || { _error "未安装 HAProxy。"; return 1; }
        local tmp
        tmp=$(mktemp) || return 1
        _sni_router_generate_haproxy_config "$tmp" || { rm -f "$tmp"; return 1; }
        haproxy -c -f "$tmp"
        local status=$?
        rm -f "$tmp"
        return "$status"
    fi
    _info "SNI 路由尚未登记任何后端。"
}

# 原子修改 JSON/YAML 文件
_atomic_modify_json() {
    local file="$1" filter="$2"
    [ ! -f "$file" ] && return 1
    local tmp="${file}.tmp"
    if jq "$filter" "$file" > "$tmp"; then mv "$tmp" "$file"
    else _error "修改JSON失败: $file"; rm -f "$tmp"; return 1; fi
}
_atomic_modify_yaml() {
    local file="$1" filter="$2"
    [ ! -f "$file" ] && return 1
    local tmp="${file}.tmp.$$"
    cp "$file" "$tmp" || return 1
    if ${YQ_BINARY} eval "$filter" -i "$file" 2>/dev/null; then
        rm -f "$tmp"
    else
        _error "修改YAML失败: $file"
        mv "$tmp" "$file"
        return 1
    fi
}

_sni_router_migrate_existing_reality() {
    [ -s "$CONFIG_FILE" ] || return 0
    _sni_router_init_state || return 1
    if jq -e '.reality != null' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi

    local candidates count tag sni backend_port config_backup metadata_backup had_metadata=no
    candidates=$(jq -r --argjson port "$SNI_ROUTER_PUBLIC_PORT" '
        [.inbounds[]?
         | select(.listen_port == $port)
         | select(.tls.reality.enabled == true)
         | [.tag, (.tls.server_name // .tls.reality.handshake.server // "")]
         | @tsv][]
    ' "$CONFIG_FILE" 2>/dev/null)
    count=$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] || return 0
    if [ "$count" -ne 1 ]; then
        _error "检测到 ${count} 个直接监听 443 的 Reality 入站，无法自动确定 HAProxy 默认后端。"
        return 1
    fi
    IFS=$'\t' read -r tag sni <<< "$candidates"
    _is_valid_reality_domain "$sni" || { _error "Reality 入站 ${tag} 的 SNI 无效。"; return 1; }
    backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1

    config_backup=$(mktemp) || return 1
    metadata_backup=$(mktemp) || { rm -f "$config_backup"; return 1; }
    cp -a -- "$CONFIG_FILE" "$config_backup" || { rm -f "$config_backup" "$metadata_backup"; return 1; }
    if [ -f "$METADATA_FILE" ]; then
        cp -a -- "$METADATA_FILE" "$metadata_backup" || { rm -f "$config_backup" "$metadata_backup"; return 1; }
        had_metadata=yes
    else
        printf '{}\n' > "$METADATA_FILE"
    fi

    _info "正在把现有 Reality ${tag} 从公网 443 迁移到 127.0.0.1:${backend_port}..."
    if ! jq --arg tag "$tag" --argjson port "$backend_port" '
        (.inbounds[] | select(.tag == $tag)) |= (.listen="127.0.0.1" | .listen_port=$port)
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" || ! mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; then
        rm -f "${CONFIG_FILE}.tmp" "$config_backup" "$metadata_backup"
        return 1
    fi
    if ! jq --arg tag "$tag" --argjson public "$SNI_ROUTER_PUBLIC_PORT" --argjson backend "$backend_port" '
        .[$tag] = ((.[$tag] // {}) + {publicPort:$public,backendPort:$backend,frontedBy:"haproxy",routerRole:"reality-default"})
    ' "$METADATA_FILE" > "${METADATA_FILE}.tmp" || ! mv "${METADATA_FILE}.tmp" "$METADATA_FILE"; then
        cp -a -- "$config_backup" "$CONFIG_FILE"
        [ "$had_metadata" = yes ] && cp -a -- "$metadata_backup" "$METADATA_FILE"
        rm -f "${CONFIG_FILE}.tmp" "${METADATA_FILE}.tmp" "$config_backup" "$metadata_backup"
        return 1
    fi

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" >/dev/null 2>&1 || \
       ! _manage_service restart || \
       ! _sni_router_register_reality sb "$tag" "$sni" "$backend_port"; then
        _error "Reality 迁移失败，正在恢复原来的公网 443 监听。"
        cp -a -- "$config_backup" "$CONFIG_FILE"
        if [ "$had_metadata" = yes ]; then cp -a -- "$metadata_backup" "$METADATA_FILE"; else rm -f "$METADATA_FILE"; fi
        _manage_service restart >/dev/null 2>&1 || true
        rm -f "$config_backup" "$metadata_backup"
        return 1
    fi
    rm -f "$config_backup" "$metadata_backup"
    _success "Reality 已迁移到 HAProxy 443 共享入口，客户端节点端口仍为 443。"
}

_sni_router_prepare() {
    _sni_router_require_systemd || return 1
    _sni_router_migrate_existing_reality || return 1
    _sni_router_init_state || return 1
    if _sni_router_state_has_routes; then
        _sni_router_apply
    fi
}

_sni_router_cli() {
    local action="${1:-status}"
    shift || true
    case "$action" in
        api-version)
            printf '%s\n' "$SNI_ROUTER_API_VERSION"
            ;;
        status)
            _sni_router_status
            ;;
        check)
            _sni_router_check
            ;;
        prepare)
            _sni_router_prepare
            ;;
        allocate-backend)
            _sni_router_allocate_backend_port "${1:-$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT}"
            ;;
        register-reality)
            [ "$#" -eq 4 ] || { _error "用法: sb sni-router register-reality OWNER TAG SNI BACKEND_PORT"; return 2; }
            _sni_router_register_reality "$1" "$2" "$3" "$4"
            ;;
        remove-reality)
            _sni_router_remove_reality "${1:-}"
            ;;
        register-tls)
            [ "$#" -eq 4 ] || { _error "用法: sb sni-router register-tls OWNER TAG SNI BACKEND_PORT"; return 2; }
            _sni_router_register_tls "$1" "$2" "$3" "$4"
            ;;
        remove-tls)
            [ "$#" -eq 1 ] || { _error "用法: sb sni-router remove-tls TAG"; return 2; }
            _sni_router_remove_tls "$1"
            ;;
        register-https)
            [ "$#" -eq 3 ] || { _error "用法: sb sni-router register-https OWNER SNI BACKEND_PORT"; return 2; }
            _sni_router_register_https "$1" "$2" "$3"
            ;;
        remove-https)
            [ "$#" -eq 2 ] || { _error "用法: sb sni-router remove-https OWNER SNI"; return 2; }
            _sni_router_remove_https "$1" "$2"
            ;;
        *)
            _error "未知 SNI 路由操作: ${action}"
            return 2
            ;;
    esac
}

# --- 资源与环境管理 ---

# 系统时间同步 (解决 TLS 握手 EOF 问题)
_sync_system_time() {
    local force="${1:-false}"
    local current_year
    current_year=$(date +%Y 2>/dev/null)

    # 自动调用仅在时钟明显失真时介入；正常情况下不安装软件、不修改系统时间。
    if [ "$force" != "true" ] && [[ "$current_year" =~ ^[0-9]+$ ]] && [ "$current_year" -ge 2024 ]; then
        return 0
    fi

    _info "正在同步系统时间..."
    if command -v timedatectl &>/dev/null && [ "$INIT_SYSTEM" = "systemd" ]; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
    elif command -v ntpdate &>/dev/null; then
        ntpdate -u pool.ntp.org >/dev/null 2>&1 || true
    elif command -v chronyd &>/dev/null; then
        chronyd -q 'server pool.ntp.org iburst' >/dev/null 2>&1 || true
    else
        # 无现成 NTP 工具时，使用 HTTPS Date 头兜底，但不会在后台安装额外软件。
        local http_time
        http_time=$(curl -fsSI --max-time 5 https://www.google.com 2>/dev/null | grep -i '^date:' | cut -f2- -d' ')
        if [ -n "$http_time" ]; then
            date -s "$http_time" >/dev/null 2>&1 || true
        fi
    fi
    _info "当前时间：$(date)"
}

# Clash YAML 节点管理
_get_proxy_field() {
    local proxy_name="$1" field="$2"
    export PROXY_NAME="$proxy_name"
    ${YQ_BINARY} eval '.proxies[] | select(.name == env(PROXY_NAME)) | '"$field" "${CLASH_YAML_FILE}" 2>/dev/null | head -n 1
}
_add_node_to_yaml() {
    local proxy_json="$1"
    local proxy_name=$(echo "$proxy_json" | jq -r .name)
    _atomic_modify_yaml "$CLASH_YAML_FILE" ".proxies |= . + [${proxy_json}] | .proxies |= unique_by(.name)" || return 1
    export PROXY_NAME="$proxy_name"
    _atomic_modify_yaml "$CLASH_YAML_FILE" '.proxy-groups[] |= (select(.name == "节点选择") | .proxies |= . + [env(PROXY_NAME)] | .proxies |= unique)'
}
_remove_node_from_yaml() {
    local proxy_name="$1"
    export PROXY_NAME="$proxy_name"
    _atomic_modify_yaml "$CLASH_YAML_FILE" 'del(.proxies[] | select(.name == env(PROXY_NAME)))' || return 1
    _atomic_modify_yaml "$CLASH_YAML_FILE" '.proxy-groups[] |= (select(.name == "节点选择") | .proxies |= del(.[] | select(. == env(PROXY_NAME))))'
}
_find_proxy_name() {
    local port="$1" type="$2" tag="$3" proxy_name=""
    if [ -n "$tag" ] && [ -f "$METADATA_FILE" ]; then
        local yaml_enabled
        yaml_enabled=$(jq -r --arg t "$tag" '.[$t].yaml // empty' "$METADATA_FILE" 2>/dev/null)
        [ "$yaml_enabled" = "false" ] && return 0
    fi
    local proxy_obj=$(${YQ_BINARY} eval '.proxies[] | select(.port == '${port}')' ${CLASH_YAML_FILE} 2>/dev/null | head -n 1)
    [ -n "$proxy_obj" ] && proxy_name=$(echo "$proxy_obj" | ${YQ_BINARY} eval '.name' -)
    [ -z "$proxy_name" ] && proxy_name=$(${YQ_BINARY} eval '.proxies[] | select(.port == '${port}' or .port == 443) | .name' ${CLASH_YAML_FILE} 2>/dev/null | grep -i "${type:-.}" | head -n 1)
    echo "$proxy_name"
}

# 内存限额计算
_get_mem_limit() {
    local total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cgroup_limit=""
    local limit

    [ -z "$total_mem_mb" ] && total_mem_mb=128

    if [ -r /sys/fs/cgroup/memory.max ]; then
        cgroup_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        if [ "$cgroup_limit" != "max" ] && [ -n "$cgroup_limit" ]; then
            total_mem_mb=$((cgroup_limit / 1024 / 1024))
        fi
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cgroup_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        if [ -n "$cgroup_limit" ] && [ "$cgroup_limit" -lt 9223372036854771712 ] 2>/dev/null; then
            total_mem_mb=$((cgroup_limit / 1024 / 1024))
        fi
    fi

    if [ "$total_mem_mb" -le 128 ]; then
        limit=48
    elif [ "$total_mem_mb" -le 256 ]; then
        limit=$((total_mem_mb * 50 / 100))
    elif [ "$total_mem_mb" -le 512 ]; then
        limit=$((total_mem_mb * 65 / 100))
    else
        limit=$((total_mem_mb * 80 / 100))
    fi

    [ "$limit" -lt 32 ] && limit=32
    echo "$limit"
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

# --- 核心变量定义 ---
export SINGBOX_DIR="/usr/local/etc/sing-box"
export SINGBOX_BIN="/usr/local/bin/sing-box"
export YQ_BINARY="/usr/local/bin/yq"
export CONFIG_FILE="${SINGBOX_DIR}/config.json"
export CLASH_YAML_FILE="${SINGBOX_DIR}/clash.yaml"
export METADATA_FILE="${SINGBOX_DIR}/metadata.json"
export ARGO_METADATA_FILE="${SINGBOX_DIR}/argo_metadata.json"
export LOG_FILE="/var/log/sing-box.log"
export ARGO_LOG_FILE="/var/log/singbox_argo.log"
export PID_FILE="/tmp/sing-box.pid"
export CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
export DEP_STATE_FILE="${SINGBOX_DIR}/dependencies.ok"
export DEP_STATE_VERSION="20260820-secure-1"

_secure_sensitive_files() {
    mkdir -p "$SINGBOX_DIR" || return 1
    chmod 700 "$SINGBOX_DIR" 2>/dev/null || true
    chmod 600 "$SINGBOX_DIR"/*.json "$SINGBOX_DIR"/*.yaml "$SINGBOX_DIR"/*.key "$SINGBOX_DIR"/*.pem 2>/dev/null || true
    chmod 600 "$LOG_FILE" "$ARGO_LOG_FILE" 2>/dev/null || true
}

_detect_init_system
case "$INIT_SYSTEM" in
    openrc) export SERVICE_FILE="/etc/init.d/sing-box" ;;
    systemd) export SERVICE_FILE="/etc/systemd/system/sing-box.service" ;;
    *) export SERVICE_FILE="" ;;
esac

export -f _info _success _warn _warning _error _url_encode _url_decode _ws_path_with_early_data _cert_sha256_hex _tls_insecure_params _get_public_ip _detect_init_system _sync_system_time _release_install_cache _atomic_modify_json _atomic_modify_yaml _manage_service _pkg_install _get_proxy_field _add_node_to_yaml _remove_node_from_yaml _find_proxy_name _nft_ensure_base _nft_delete_rules_by_comment _nft_port_expr _nft_apply_redirect_rule _nft_can_redirect _save_nftables_rules _remove_nftables_rules

server_ip=""
BATCH_MODE=false
trap 'rm -f ${SINGBOX_DIR}/*.tmp /tmp/singbox_links.tmp' EXIT
# 依赖安装
_install_dependencies() {
    local force="${1:-false}"
    if [ "$force" != "true" ] && [ -s "$DEP_STATE_FILE" ] && grep -qx "$DEP_STATE_VERSION" "$DEP_STATE_FILE" 2>/dev/null; then
        local missing_cached=""
        for cmd in bash jq curl wget openssl tar unzip sha256sum; do
            if ! command -v "$cmd" &>/dev/null; then
                missing_cached="$missing_cached $cmd"
            fi
        done
        if ! command -v nft &>/dev/null; then
            missing_cached="$missing_cached nftables"
        fi
        if [ -z "$missing_cached" ] && [ -x "$YQ_BINARY" ]; then
            return 0
        fi
        [ ! -x "$YQ_BINARY" ] && missing_cached="$missing_cached yq"
        _warn "依赖缓存存在，但关键工具缺失:${missing_cached}，将执行一次修复安装。"
    fi

    # 核心依赖：脚本运行的绝对前提，必须全部装上
    local core_pkgs="bash curl jq openssl wget tar unzip ca-certificates coreutils"
    # 可选依赖：部分功能需要，即使装失败也不致命
    local optional_pkgs="procps nftables socat iproute2 cron lsof"
    
    # 针对不同发行版的 cron 包名适配
    if command -v apk &>/dev/null; then
        optional_pkgs="${optional_pkgs/cron/dcron}"
    elif ! command -v apt-get &>/dev/null && ! command -v yum &>/dev/null && ! command -v dnf &>/dev/null; then
        optional_pkgs="${optional_pkgs/cron/cronie}"
    fi

    _info "正在安装核心依赖..."
    _pkg_install $core_pkgs
    
    _info "正在安装可选依赖..."
    _pkg_install $optional_pkgs 2>/dev/null || {
        # 可选依赖批量安装失败时逐个尝试
        _warn "部分可选依赖批量安装遇到冲突，正在逐个重试..."
        for pkg in $optional_pkgs; do
            _pkg_install "$pkg" 2>/dev/null || true
        done
    }
    
    _install_yq

    # [修复] Alpine 上 dcron 安装后需手动启动 cron 守护进程
    if command -v apk &>/dev/null; then
        if command -v crond &>/dev/null; then
            rc-service dcron start 2>/dev/null
            rc-update add dcron default 2>/dev/null
        fi
    fi

    # 关键依赖验证：如果核心工具缺失则无法继续
    local missing=""
    for cmd in bash jq curl wget openssl tar unzip sha256sum; do
        if ! command -v "$cmd" &>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ ! -x "$YQ_BINARY" ]; then
        missing="$missing yq"
    fi
    if [ -n "$missing" ]; then
        _error "以下关键依赖安装失败:${missing}"
        _error "请使用系统包管理器手动安装这些工具（如 apk add / apt-get install / yum install）"
        exit 1
    fi

    mkdir -p "$SINGBOX_DIR"
    printf '%s\n' "$DEP_STATE_VERSION" > "$DEP_STATE_FILE"
}

# 确保 nftables 可用，并检测实际 netfilter 写入能力
_ensure_nftables() {
    if ! command -v nft &>/dev/null; then
        _info "未检测到 nftables，尝试安装..."
        _pkg_install nftables
        if ! command -v nft &>/dev/null; then
            _error "nftables 安装失败。"
            return 1
        fi
        _success "nftables 安装成功。"
    fi

    if ! _nft_can_redirect 65530 65531; then
        _warn "nftables 命令存在，但当前环境无 netfilter 写权限（容器/LXC 无特权模式）。"
        _warn "端口转发将自动使用 sing-box 引擎代替。"
        return 2
    fi

    return 0
}

_install_sing_box() {
    _info "正在安装最新稳定版 sing-box..."
    local arch=$(uname -m)
    local arch_tag
    local temp_dir=""
    local archive_path=""
    local extracted_bin=""
    local config_check_output=""
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='armv7' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac
    
    # 检测 C 库类型：Alpine 等系统使用 musl，需要下载对应版本
    local libc_suffix=""
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        _info "检测到 musl libc (Alpine 等系统)，将下载 musl 版本..."
        libc_suffix="-musl"
    fi
    
    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local release_info release_tag version asset_name
    release_info=$(curl -fLsS --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: singbox-lite-kevin' \
        "$api_url") || { _error "无法获取 sing-box Release 信息。"; return 1; }
    release_tag=$(printf '%s' "$release_info" | jq -r '.tag_name // empty')
    version="${release_tag#v}"
    [ -z "$version" ] && { _error "无法解析 sing-box 稳定版本号。"; return 1; }
    asset_name="sing-box-${version}-linux-${arch_tag}${libc_suffix}.tar.gz"

    temp_dir=$(mktemp -d /root/.singbox-install.XXXXXX) || { _error "创建临时目录失败。"; return 1; }
    archive_path="${temp_dir}/sing-box.tar.gz"

    _info "正在下载 sing-box 安装包..."
    if ! _download_verified_github_asset "$api_url" "$asset_name" "$archive_path"; then
        rm -rf "$temp_dir"
        return 1
    fi

    _info "正在解压 sing-box 安装包..."
    if ! tar -xzf "$archive_path" -C "$temp_dir"; then
        _error "解压 sing-box 安装包失败，临时目录保留: $temp_dir"
        return 1
    fi

    extracted_bin=$(find "$temp_dir" -name sing-box -type f 2>/dev/null | head -n 1)
    if [ -z "$extracted_bin" ]; then
        _error "解压后未找到 sing-box 二进制文件，临时目录保留: $temp_dir"
        return 1
    fi

    chmod 700 "$extracted_bin"
    if ! "$extracted_bin" version 2>/dev/null | head -n 1 | grep -q 'sing-box version'; then
        _error "下载的 sing-box 二进制无法通过版本检查，已拒绝安装。"
        rm -rf "$temp_dir"
        return 1
    fi

    # 覆盖现有核心前，先让候选版本校验服务实际加载的合并配置。
    if [ -s "$CONFIG_FILE" ]; then
        if [ -s "${SINGBOX_DIR}/relay.json" ]; then
            if ! config_check_output=$("$extracted_bin" check -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" 2>&1); then
                _error "当前配置无法通过 sing-box ${version} 校验，已取消更新。"
                printf '%s\n' "$config_check_output" >&2
                rm -rf "$temp_dir"
                return 1
            fi
        elif ! config_check_output=$("$extracted_bin" check -c "$CONFIG_FILE" 2>&1); then
            _error "当前配置无法通过 sing-box ${version} 校验，已取消更新。"
            printf '%s\n' "$config_check_output" >&2
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    rm -f "$archive_path"

    _info "正在安装 sing-box 二进制文件..."
    mkdir -p "$(dirname "$SINGBOX_BIN")" || {
        _error "创建安装目录失败: $(dirname "$SINGBOX_BIN")"
        return 1
    }
    if ! mv -f "$extracted_bin" "$SINGBOX_BIN"; then
        _error "安装 sing-box 二进制文件失败: $SINGBOX_BIN"
        _error "临时目录保留: $temp_dir"
        return 1
    fi
    if ! chmod 700 "$SINGBOX_BIN"; then
        _error "设置 sing-box 可执行权限失败: $SINGBOX_BIN"
        _error "临时目录保留: $temp_dir"
        return 1
    fi

    touch "${SINGBOX_DIR}/.managed_sing_box"
    rm -rf "$temp_dir"
    _release_install_cache
    _success "sing-box 安装成功: ${SINGBOX_BIN}"
}

_install_cloudflared() {
    if [ -f "${CLOUDFLARED_BIN}" ]; then
        _info "cloudflared 已安装: $(${CLOUDFLARED_BIN} --version 2>&1 | head -n1)"
        return 0
    fi
    
    _info "正在安装依据环境所需的组件 (ca-certificates)..."
    _pkg_install ca-certificates # 关键修复：Alpine 等精简系统必须有证书才能进行 TLS 握手
    
    _info "正在安装 cloudflared..."
    local arch=$(uname -m)
    local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='arm' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac
    
    local asset_name="cloudflared-linux-${arch_tag}"
    _download_verified_github_asset \
        "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
        "$asset_name" "$CLOUDFLARED_BIN" || return 1
    chmod 700 "${CLOUDFLARED_BIN}"
    if ! "${CLOUDFLARED_BIN}" --version 2>/dev/null | grep -qi 'cloudflared version'; then
        _error "下载的 cloudflared 无法通过版本检查，已拒绝安装。"
        rm -f "${CLOUDFLARED_BIN}"
        return 1
    fi
    touch "${SINGBOX_DIR}/.managed_cloudflared"
    
    _success "cloudflared 安装成功: $(${CLOUDFLARED_BIN} --version 2>&1 | head -n1)"
}

# --- Argo Tunnel 功能 ---

_start_argo_tunnel() {
    local target_port="$1"

    # 基于端口生成独立的 PID 和日志文件路径
    local pid_file="/tmp/singbox_argo_${target_port}.pid"
    local log_file="/tmp/singbox_argo_${target_port}.log"
    
    _info "正在启动 Argo 隧道 (端口: $target_port)..." >&2
    
    # 检查该端口对应的隧道是否已在运行
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if _is_pid_running_cmd "$old_pid" "$CLOUDFLARED_BIN"; then
            _warning "检测到端口 $target_port 的 Argo 隧道已在运行 (PID: $old_pid)" >&2
            return 0
        fi
    fi
    
    # 清理旧日志和同步时间
    rm -f "${log_file}"
    _sync_system_time

    # 仅保留无需 Cloudflare Token 的临时隧道模式。
    _info "启动临时隧道，指向 127.0.0.1:${target_port}..." >&2
    nohup "${CLOUDFLARED_BIN}" tunnel --protocol http2 --no-autoupdate --url "http://127.0.0.1:${target_port}" \
        --logfile "${log_file}" > /dev/null 2>&1 &

    local cf_pid=$!
    echo "$cf_pid" > "${pid_file}"

    _info "等待隧道建立 (最多30秒)..." >&2
    local tunnel_domain=""
    local wait_count=0
    local max_wait=30

    while [ $wait_count -lt $max_wait ]; do
        sleep 2
        wait_count=$((wait_count + 2))
        if ! kill -0 "$cf_pid" 2>/dev/null; then
            _error "cloudflared 进程已退出，请检查日志: ${log_file}" >&2
            tail -n 20 "${log_file}" 2>/dev/null >&2
            return 1
        fi
        if [ -f "${log_file}" ]; then
            tunnel_domain=$(grep -oE 'https?://[a-zA-Z0-9-]+\.trycloudflare\.com' "${log_file}" 2>/dev/null | head -n 1 | sed -E 's|https?://||')
            [ -n "$tunnel_domain" ] && break
        fi
        echo -n "." >&2
    done
    echo "" >&2

    if [ -z "$tunnel_domain" ]; then
        _error "获取临时域名超时。请检查网络。日志最后几行：" >&2
        tail -n 5 "${log_file}" 2>/dev/null >&2
        kill "$cf_pid" 2>/dev/null
        rm -f "${pid_file}"
        return 1
    fi

    _info "域名已获取，正在进行稳定性测试 (5秒)..." >&2
    sleep 5
    if ! kill -0 "$cf_pid" 2>/dev/null; then
        _error "稳定性测试失败：cloudflared 进程异常退出。" >&2
        tail -n 10 "${log_file}" 2>/dev/null >&2
        return 1
    fi

    _enable_argo_watchdog
    _success "Argo 临时隧道建立成功: ${tunnel_domain}" >&2
    echo "$tunnel_domain"
}

_stop_argo_tunnel() {
    local target_port="$1"
    if [ -z "$target_port" ]; then
        return
    fi
    
    local pid_file="/tmp/singbox_argo_${target_port}.pid"
    local log_file="/tmp/singbox_argo_${target_port}.log"

    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
            kill "$pid" 2>/dev/null
            _success "Argo 隧道 (端口: $target_port) 已停止"
        fi
        rm -f "$pid_file" "$log_file"
    fi
}

_stop_all_argo_tunnels() {
    _info "正在停止所有 Argo 隧道..."
    local stopped_any=false
    for pid_file in /tmp/singbox_argo_*.pid; do
        [ -e "$pid_file" ] || continue
        # 解析端口
        local filename=$(basename "$pid_file")
        local port=${filename#singbox_argo_}
        port=${port%.pid}
        _stop_argo_tunnel "$port"
        stopped_any=true
    done
    if [ "$stopped_any" = false ]; then
        _warn "未找到本脚本记录的 Argo PID 文件，未执行全局 cloudflared 清理。"
    fi
}

_sanitize_argo_metadata() {
    [ -s "$ARGO_METADATA_FILE" ] || return 0
    if jq -e 'any(.[]; has("token") or .type == "fixed")' "$ARGO_METADATA_FILE" >/dev/null 2>&1; then
        local legacy_rows
        legacy_rows=$(jq -r 'to_entries[] | select(.value | has("token") or .type == "fixed") | [.key, (.value.local_port|tostring), (.value.protocol // "vless-ws"), (.value.name // .key), (.value.uuid // ""), (.value.password // ""), (.value.path // "/")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
        _warning "检测到旧版固定 Argo 配置：将停止其进程、删除本地 Token，并转换为临时隧道。"
        _atomic_modify_json "$ARGO_METADATA_FILE" 'with_entries(.value |= (del(.token) | .type = "temp"))' || return 1

        local tag port protocol name uuid password path new_domain
        while IFS=$'\t' read -r tag port protocol name uuid password path; do
            [ -z "$tag" ] && continue
            _stop_argo_tunnel "$port"
            new_domain=$(_start_argo_tunnel "$port")
            if [ -n "$new_domain" ]; then
                _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$new_domain\""
                if [ "$protocol" = "vless-ws" ]; then
                    _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$path" >/dev/null
                else
                    _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$path" >/dev/null
                fi
            else
                _warning "旧固定隧道 ${name} 已停止，但临时隧道启动失败；可在 Argo 菜单中手动重启。"
            fi
        done <<< "$legacy_rows"
    fi
    chmod 600 "$ARGO_METADATA_FILE" 2>/dev/null || true
}

# ============================================================
# 统一 Argo 节点创建函数 (消除 VLESS/Trojan 重复代码)
# 参数: $1 = 协议类型 ("vless" 或 "trojan")
# ============================================================
_add_argo_node() {
    local protocol="$1"
    local protocol_label=""
    local proto_name=""
    case "$protocol" in
        vless) protocol_label="VLESS-WS"; proto_name="Vless" ;;
        trojan) protocol_label="Trojan-WS"; proto_name="Trojan" ;;
        *) _error "不支持的 Argo 协议: $protocol"; return 1 ;;
    esac

    _info "--- 创建 ${protocol_label} + Argo 隧道节点 ---"

    # 安装 cloudflared
    _install_cloudflared || return 1

    # === [公共] 内部端口分配 ===
    read -p "请输入 Argo 内部监听端口 (回车随机生成): " input_port
    local port="$input_port"

    while true; do
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            _check_port_conflict "$port" "tcp" && port="" && continue
            _info "已使用监听端口: ${port}"
            break
        else
            [ -n "$port" ] && _warning "端口格式无效，将重新生成..."
            # 使用内建算法生成随机端口 (10000-60000)，移除 shuf 依赖
            port=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 50001 + 10000 ))
            _info "正在尝试分配随机内部端口: ${port}..."
        fi
    done

    # === [公共] WebSocket 路径 ===
    read -p "请输入 WebSocket 路径 (回车随机生成): " ws_path
    if [ -z "$ws_path" ]; then
        ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
        _info "已生成随机路径: ${ws_path}"
    else
        [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    fi

    # === [协议特定] Trojan 密码输入 ===
    local password=""
    if [ "$protocol" == "trojan" ]; then
        read -p "请输入 Trojan 密码 (回车随机生成): " password
        if [ -z "$password" ]; then
            password=$(${SINGBOX_BIN} generate rand --hex 16)
            _info "已生成随机密码: ${password}"
        fi
    fi

    # 仅保留无需 Cloudflare Token 的临时隧道。
    echo ""
    _info "将创建无需 Token 的 Argo 临时隧道；隧道重启后域名会变化。"
    _info "如需固定自有域名，请创建 WS/gRPC + TLS 节点，并按脚本提示手动配置 Cloudflare DNS/回源规则。"
    local tunnel_domain=""
    local argo_type="temp"

    # === [公共] 节点名称 ===
    local default_prefix="Argo-Temp"
    local default_name="${default_prefix}-${proto_name}-${port}"

    echo ""
    read -p "请输入节点名称 (默认: ${default_name}): " custom_name
    local name=${custom_name:-$default_name}

    # === [协议特定] 生成凭据、tag 和 Inbound ===
    local tag="argo-${protocol}-ws-${port}"
    local uuid=""
    local inbound_json=""

    if [ "$protocol" == "vless" ]; then
        uuid=$(${SINGBOX_BIN} generate uuid)
        inbound_json=$(jq -n \
            --arg t "$tag" \
            --arg p "$port" \
            --arg u "$uuid" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "type": "vless",
                "tag": $t,
                "listen": "127.0.0.1",
                "listen_port": ($p|tonumber),
                "users": [{"uuid": $u, "flow": ""}],
                "transport": {
                    "type": "ws",
                    "path": $wsp,
                    "max_early_data": $ed,
                    "early_data_header_name": $edh
                }
            }')
    elif [ "$protocol" == "trojan" ]; then
        inbound_json=$(jq -n \
            --arg t "$tag" \
            --arg p "$port" \
            --arg pw "$password" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "type": "trojan",
                "tag": $t,
                "listen": "127.0.0.1",
                "listen_port": ($p|tonumber),
                "users": [{"password": $pw}],
                "transport": {
                    "type": "ws",
                    "path": $wsp,
                    "max_early_data": $ed,
                    "early_data_header_name": $edh
                }
            }')
    fi

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

    # === [公共] 重启 + 启动隧道 ===
    _manage_service "restart"
    sleep 2

    local real_domain=$(_start_argo_tunnel "$port")
    if [ -z "$real_domain" ]; then
        _error "隧道启动失败，正在回滚配置..."
        _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
        _manage_service "restart"
        return 1
    fi
    tunnel_domain="$real_domain"

    # === [协议特定] 保存元数据 ===
    local credential_key="" credential_val=""
    if [ "$protocol" == "vless" ]; then
        credential_key="uuid"; credential_val="$uuid"
    else
        credential_key="password"; credential_val="$password"
    fi

    local argo_meta=$(jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg domain "$tunnel_domain" \
        --arg port "$port" \
        --arg cred_val "$credential_val" \
        --arg cred_key "$credential_key" \
        --arg path "$ws_path" \
        --arg protocol "${protocol}-ws" \
        --arg type "$argo_type" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, domain: $domain, local_port: ($port|tonumber), ($cred_key): $cred_val, path: $path, protocol: $protocol, type: $type, created_at: $created}}')

    if [ ! -f "$ARGO_METADATA_FILE" ]; then
        echo '{}' > "$ARGO_METADATA_FILE"
    fi
    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $argo_meta"

    # === [协议特定] Clash 配置 + 分享链接 ===
    local proxy_json=""
    if [ "$protocol" == "vless" ]; then
        proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$tunnel_domain" \
            --arg u "$uuid" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "name": $n,
                "type": "vless",
                "server": $s,
                "port": 443,
                "uuid": $u,
                "tls": true,
                "udp": true,
                "skip-cert-verify": false,
                "network": "ws",
                "servername": $s,
                "ws-opts": {
                    "path": $wsp,
                    "max-early-data": $ed,
                    "early-data-header-name": $edh,
                    "headers": {
                        "Host": $s
                    }
                }
            }')
    elif [ "$protocol" == "trojan" ]; then
        proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$tunnel_domain" \
            --arg pw "$password" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "name": $n,
                "type": "trojan",
                "server": $s,
                "port": 443,
                "password": $pw,
                "udp": true,
                "skip-cert-verify": false,
                "network": "ws",
                "sni": $s,
                "ws-opts": {
                    "path": $wsp,
                    "max-early-data": $ed,
                    "early-data-header-name": $edh,
                    "headers": {
                        "Host": $s
                    }
                }
            }')
    fi

    _add_node_to_yaml "$proxy_json"

    # === [公共] 启用守护 + 显示结果 ===
    _enable_argo_watchdog

    echo ""
    _success "${protocol_label} + Argo 节点创建成功!"
    echo "-------------------------------------------"
    echo -e "节点名称: ${GREEN}${name}${NC}"
    echo -e "隧道类型: ${CYAN}临时隧道（无需 Token）${NC}"
    echo -e "隧道域名: ${CYAN}${tunnel_domain}${NC}"
    echo -e "本地端口: ${port}"
    echo "-------------------------------------------"
    
    # 使用统一链接生成器进行展示与持久化
    if [ "$protocol" == "vless" ]; then
        _show_node_link "vless-ws" "$name" "$tunnel_domain" "443" "$tag" "$uuid" "$ws_path"
    else
        _show_node_link "trojan-ws" "$name" "$tunnel_domain" "443" "$tag" "$password" "$ws_path"
    fi
    
    echo "-------------------------------------------"
    _warning "注意: 临时隧道每次重启域名会变化！"
}

# 保留原始函数名作为薄包装器，确保向后兼容
_add_argo_vless_ws() { _add_argo_node "vless"; }

_add_argo_trojan_ws() { _add_argo_node "trojan"; }

_view_argo_nodes() {
    _info "--- Argo 隧道节点信息 ---"
    
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点。"
        return
    fi
    
    echo "==================================================="
    # 遍历并显示
    jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.type)|\(.value.protocol)|\(.value.local_port)|\(.value.domain)|\(.value.uuid // "")|\(.value.path // "")|\(.value.password // "")"' "$ARGO_METADATA_FILE" | \
    while IFS='|' read -r tag name argo_type protocol port domain uuid path password; do
        echo -e "节点: ${GREEN}${name}${NC}"
        echo -e "  协议: ${protocol}"
        echo -e "  端口: ${port}"
        
        # 检查状态
        local pid_file="/tmp/singbox_argo_${port}.pid"
        local state="${RED}已停止${NC}"
        local running_domain=""
        
        # [M4] 一次读取 PID 到变量，避免重复 cat
        local pid=""
        if [ -f "$pid_file" ]; then pid=$(cat "$pid_file" 2>/dev/null); fi
        if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
             state="${GREEN}运行中${NC} (PID: $pid)"
             # 如果是临时的，尝试从 log 读最新域名
             if [ "$argo_type" == "temp" ] || [ -z "$domain" ] || [ "$domain" == "null" ]; then
                  local log_file="/tmp/singbox_argo_${port}.log"
                  local temp_domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -1 | sed 's|https://||')
                   [ -n "$temp_domain" ] && domain="$temp_domain"
             fi
             running_domain="$domain"
        fi
        
        if [ -n "$domain" ] && [ "$domain" != "null" ]; then
             local link=""
             
             # [新架构] 优先使用持久化链接
             link=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$ARGO_METADATA_FILE")
             
              if [ -z "$link" ] || [ "$link" == "null" ]; then
                  local safe_name=$(_url_encode "$name")
                  local ed_path=$(_ws_path_with_early_data "$path")
                  local safe_path=$(_url_encode "$ed_path")
                  
                  if [[ "$protocol" == "vless-ws" ]]; then
                      link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
                 elif [[ "$protocol" == "trojan-ws" ]]; then
                     local safe_pw=$(_url_encode "$password")
                     link="trojan://${safe_pw}@${domain}:443?security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
                 fi
             fi

             if [ -n "$link" ]; then
                  echo -e "  ${YELLOW}链接:${NC} $link"
             fi
        fi
        echo "-------------------------------------------"
    done
    
    echo -e "${YELLOW}提示: 请使用 [9] 重启隧道 来刷新所有节点状态或获取新临时域名。${NC}"
    echo "==================================================="
}

_delete_argo_node() {
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点可删除。"
        return
    fi
    
    _info "--- 删除 Argo 隧道节点 ---"
    
    # 读取所有节点到数组
    local i=1
    local keys=()
    local names=()
    local ports=()
    
    # 必须使用 while read 处理 process substitution 避免子 shell 问题
    while IFS='|' read -r key name port; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE")
    
    if [ ${#keys[@]} -eq 0 ]; then
         _warning "读取元数据失败。"
         return
    fi

    echo " 0) 返回"
    read -p "请选择要删除的节点: " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "${#keys[@]}" ]; then
        _error "无效输入"
        return
    fi
    
    if [ "$choice" -eq 0 ]; then return; fi
    
    local idx=$((choice - 1))
    local selected_key="${keys[$idx]}"
    local selected_name="${names[$idx]}"
    local selected_port="${ports[$idx]}"
    
    _info "正在删除节点: ${selected_name} (端口: ${selected_port})..."
    
    # 1. 停止该节点的隧道进程
    _stop_argo_tunnel "$selected_port"
    
    # 2. 从 sing-box 配置文件中移除 inbound
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$selected_key\"))"
    
    # 3. 删除 Argo 元数据
    jq "del(.\"$selected_key\")" "$ARGO_METADATA_FILE" > "${ARGO_METADATA_FILE}.tmp" && mv "${ARGO_METADATA_FILE}.tmp" "$ARGO_METADATA_FILE"
    
    # 4. 删除 Clash 配置
    _remove_node_from_yaml "$selected_name"
    
    # 5. 检查是否还有节点，如果没有则禁用守护进程
    if [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        _disable_argo_watchdog
    fi

    # 6. 重启 sing-box
    _manage_service "restart"
    
    _success "节点 ${selected_name} 已删除！"
}

_stop_argo_menu() {
    _info "--- 停止 Argo 隧道进程 (保留配置) ---"
    # 复用选择逻辑
    local i=1
    local keys=()
    local names=()
    local ports=()
    
    while IFS='|' read -r key name port; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE")
    
    echo " a) 停止所有运行中的隧道"
    echo " 0) 返回"
    read -p "请选择: " choice
    
    if [ "$choice" == "a" ]; then
        _stop_all_argo_tunnels
        _success "所有隧道已停止指令发送。"
        return
    fi
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "${#keys[@]}" ]; then
        _error "无效输入"
        return
    fi
    if [ "$choice" -eq 0 ]; then return; fi
    
    local idx=$((choice - 1))
    local selected_port="${ports[$idx]}"
    
    _stop_argo_tunnel "$selected_port"
}

_restart_argo_tunnel_menu() {
    _info "--- 重启 Argo 隧道 ---"
    
     if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点。"
        return
    fi

    # 选择逻辑
    local i=1
    local keys=()
    local names=()
    local ports=()
    local protocols=()
    local uuids=()
    local passwords=()
    local paths=()
    
    while IFS='|' read -r key name port proto uuid pw path; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        protocols+=("$proto")
        uuids+=("$uuid")
        passwords+=("$pw")
        paths+=("$path")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)|\(.value.protocol)|\(.value.uuid // \"\")|\(.value.password // \"\")|\(.value.path // \"/\")"' "$ARGO_METADATA_FILE")
    
    echo " a) 重启所有节点"
    echo " 0) 返回"
    read -p "请选择: " choice
    
    local selected_indices=()
    if [ "$choice" == "a" ]; then
        # 生成所有索引
        for ((j=0; j<${#keys[@]}; j++)); do selected_indices+=($j); done
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#keys[@]}" ]; then
        selected_indices+=($((choice - 1)))
    else
        if [ "$choice" -ne 0 ]; then _error "无效输入"; fi
        return
    fi

    for i in "${!selected_indices[@]}"; do
        local idx="${selected_indices[$i]}"
        local tag="${keys[$idx]}"
        local name="${names[$idx]}"
        local port="${ports[$idx]}"
        local proto_full="${protocols[$idx]}"
        local uuid="${uuids[$idx]}"
        local password="${passwords[$idx]}"
        local ws_path="${paths[$idx]}"

        _info "正在重启: $name (端口: $port)..."
        
        # 停止
        _stop_argo_tunnel "$port"
        sleep 1
        
        local new_domain=$(_start_argo_tunnel "$port")
        if [ -n "$new_domain" ]; then
            _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$new_domain\" | .\"$tag\".type = \"temp\" | del(.\"$tag\".token)"
            _success "更新临时域名: $new_domain"

            if [[ "$proto_full" == "vless-ws" ]]; then
                _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$ws_path" >/dev/null
            else
                _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$ws_path" >/dev/null
            fi
        else
            _error "临时隧道重启失败: $name"
        fi
    done
    _success "操作完成。"
}

# --- Argo 守护进程逻辑 ---

_argo_keepalive() {
    # --- 性能优化: 互斥锁 ---
    local lock_dir="/tmp/singbox_keepalive.lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        # 锁目录存在，等待所有权文件写入
        sleep 0.1 2>/dev/null || sleep 1
        local pid=""
        [ -f "$lock_dir/pid" ] && pid=$(cat "$lock_dir/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # 进程仍在运行，跳过本次执行
            return
        fi
        # 进程已死，强制清除残留锁目录并重试
        rm -rf "$lock_dir" 2>/dev/null
        mkdir -p "$lock_dir" 2>/dev/null || return
    fi
    echo "$$" > "$lock_dir/pid"
    # 确保退出时删除锁
    trap 'rm -rf "$lock_dir"' RETURN EXIT

    # --- 性能优化: 日志轮转 (10MB) ---
    local max_size=$((10 * 1024 * 1024))
    for log in "$LOG_FILE" "$ARGO_LOG_FILE"; do
        if [ -f "$log" ] && [ $(wc -c < "$log" 2>/dev/null || echo 0) -ge $max_size ]; then
            tail -n 1000 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
        fi
    done

    # 如果元数据文件不存在或为空，不需要守护
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        return
    fi

    # 遍历所有节点
    local i=0
    # [资源优化] 合并提取所有必要元数据，支持域名链接同步
    while IFS=$'\t' read -r tag port protocol name uuid password path; do
        [ -z "$tag" ] && continue
        
        local pid_file="/tmp/singbox_argo_${port}.pid"
        local is_running=false
        
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
                is_running=true
            fi
        fi
        
        if [ "$is_running" = false ]; then
            logger "sing-box-watchdog: Detected dead tunnel for $tag (Port: $port). Restarting..."
            local new_domain=$(_start_argo_tunnel "$port")
            if [ -n "$new_domain" ]; then
                _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$new_domain\" | .\"$tag\".type = \"temp\" | del(.\"$tag\".token)"
                logger "sing-box-watchdog: Temp tunnel $tag restarted with new domain: $new_domain"
                if [[ "$protocol" == "vless-ws" ]]; then
                    _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$path" >/dev/null
                else
                    _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$path" >/dev/null
                fi
            else
                logger "sing-box-watchdog: Failed to restart temp tunnel $tag."
            fi
        fi
    done < <(jq -r 'to_entries[] | [.key, (.value.local_port|tostring), (.value.protocol // "vless-ws"), .value.name, (.value.uuid // ""), (.value.password // ""), (.value.path // "")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
}

_enable_argo_watchdog() {
    # 检查 crontab 是否已有任务
    local job="* * * * * bash ${SELF_SCRIPT_PATH} keepalive >/dev/null 2>&1"
    
    if ! crontab -l 2>/dev/null | grep -Fq "$job"; then
        _info "正在添加后台守护进程 (Watchdog)..."
        (crontab -l 2>/dev/null; echo "$job") | crontab -
        if [ $? -eq 0 ]; then
            _success "守护进程已启用！(每分钟检查并自动修复失效隧道)"
        else
            _warning "添加 Crontab 失败，守护进程未生效。"
        fi
    fi
}

_disable_argo_watchdog() {
    local job="bash ${SELF_SCRIPT_PATH} keepalive"
    
    if crontab -l 2>/dev/null | grep -Fq "$job"; then
        _info "正在移除后台守护进程..."
        crontab -l 2>/dev/null | grep -Fv "$job" | crontab -
        _success "守护进程已移除。"
    fi
}

_uninstall_argo() {
    local managed_cloudflared=false
    [ -f "${SINGBOX_DIR}/.managed_cloudflared" ] && managed_cloudflared=true
    _warning "！！！警告！！！"
    _warning "本操作将删除所有 Argo 临时隧道节点。"
    echo ""
    echo "即将删除的内容："
    [ "$managed_cloudflared" = "true" ] && echo -e "  ${RED}-${NC} 本脚本安装的 cloudflared: ${CLOUDFLARED_BIN}"
    echo -e "  ${RED}-${NC} 所有 Argo 日志文件和元数据文件"
    
    if [ -f "$ARGO_METADATA_FILE" ]; then
        local argo_count=$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null || echo "0")
        echo -e "  ${RED}-${NC} Argo 节点数量: ${argo_count} 个"
    fi
    
    echo ""
    read -p "$(echo -e ${YELLOW}"确定要卸载 Argo 服务吗? (y/N): "${NC})" confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        _info "卸载已取消。"
        return
    fi
    
    _info "正在卸载 Argo 服务..."
    
    # 1. 停止所有隧道进程
    _stop_all_argo_tunnels
    
    # 2. 删除 sing-box 中的 Argo inbound 配置
    if [ -f "$ARGO_METADATA_FILE" ]; then
         # 同样需要遍历删除逻辑，这里简化为遍历 metadata 删除
         # 为防止 jq 读写竞争，先收集所有 tags
        local tags=$(jq -r 'keys[]' "$ARGO_METADATA_FILE" 2>/dev/null)
        for tag in $tags; do
             if [ -n "$tag" ]; then
                _info "正在删除 Argo 隧道: $tag ..."
                # [修复] 先读取节点名，再删除元数据
                local node_name=$(jq -r ".\"$tag\".name" "$ARGO_METADATA_FILE" 2>/dev/null)
    _atomic_modify_json "$ARGO_METADATA_FILE" "del(.\""$tag"\")" 2>/dev/null
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
                
                if [ -n "$node_name" ] && [ "$node_name" != "null" ]; then
                    _remove_node_from_yaml "$node_name"
                fi
             fi
        done
    fi
    
    # 3. 移除守护进程
    _disable_argo_watchdog

    # 4. 仅删除由本脚本安装的 cloudflared，不影响系统原有 Cloudflare 配置。
    _stop_all_argo_tunnels 2>/dev/null
    rm -f /tmp/singbox_argo_*.pid /tmp/singbox_argo_*.log
    rm -f "${ARGO_METADATA_FILE}"
    if [ "$managed_cloudflared" = "true" ]; then
        rm -f "${CLOUDFLARED_BIN}" "${SINGBOX_DIR}/.managed_cloudflared"
    else
        _info "检测到 cloudflared 并非由本脚本安装，已保留二进制及 /etc/cloudflared。"
    fi
    
    # 4. 重启 sing-box
    _manage_service "restart"
    
    _success "Argo 服务已完全卸载！"
}

_view_argo_logs() {
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        _warning "当前没有任何 Argo 隧道节点。"
        return
    fi

    _info "--- 选择要查看日志的 Argo 隧道 ---"
    local tags=$(jq -r 'keys[]' "$ARGO_METADATA_FILE")
    local i=1
    local tag_list=()
    for tag in $tags; do
        local name=$(jq -r ".\"$tag\".name" "$ARGO_METADATA_FILE")
        local port=$(jq -r ".\"$tag\".local_port" "$ARGO_METADATA_FILE")
        echo "  ${i}) ${name} (端口: ${port})"
        tag_list[$i]=$tag
        ((i++))
    done
    echo "  0) 返回上级菜单"
    read -p "请输入选项: " log_choice
    [[ "$log_choice" == "0" || -z "$log_choice" ]] && return

    local selected_tag=${tag_list[$log_choice]}
    if [ -n "$selected_tag" ]; then
        local port=$(jq -r ".\"$selected_tag\".local_port" "$ARGO_METADATA_FILE")
        local log_file="/tmp/singbox_argo_${port}.log"
        if [ -f "$log_file" ]; then
            _info "正在查看隧道日志 [${selected_tag}]，按 Ctrl+C 退出。"
            tail -f "$log_file"
        else
            _error "日志文件不存在: ${log_file}"
        fi
    else
        _error "无效选项"
    fi
}

_sync_argo_early_data() {
    local config_updated=false
    local links_updated=false
    local yaml_updated=false

    export WS_ED="$WS_EARLY_DATA_SIZE"
    export WS_EDH="$WS_EARLY_DATA_HEADER"

    if [ -s "$CONFIG_FILE" ] && jq -e 'any(.inbounds[]?; ((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws") and (((.transport.max_early_data // 0) != (env.WS_ED | tonumber)) or ((.transport.early_data_header_name // "") != env.WS_EDH))))' "$CONFIG_FILE" >/dev/null 2>&1; then
        _atomic_modify_json "$CONFIG_FILE" '(.inbounds[] | select((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws")) | .transport.max_early_data) = (env.WS_ED | tonumber) | (.inbounds[] | select((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws")) | .transport.early_data_header_name) = env.WS_EDH' || return 1
        config_updated=true
    fi

    if [ -s "$ARGO_METADATA_FILE" ]; then
        while IFS=$'\t' read -r tag protocol name domain uuid password path share_link; do
            [ -z "$tag" ] && continue
            [[ "$protocol" != "vless-ws" && "$protocol" != "trojan-ws" ]] && continue
            [[ -z "$domain" || "$domain" == "null" ]] && continue

            if [ -s "$CLASH_YAML_FILE" ] && [ -x "$YQ_BINARY" ] && [ -n "$name" ] && [ "$name" != "null" ]; then
                export PROXY_NAME="$name"
                local yaml_needs_update
                yaml_needs_update=$(${YQ_BINARY} eval '.proxies[] | select(.name == env(PROXY_NAME) and .network == "ws" and (((.["ws-opts"]["max-early-data"] // "") | tostring) != strenv(WS_ED) or (.["ws-opts"]["early-data-header-name"] // "") != env(WS_EDH))) | .name' "$CLASH_YAML_FILE" 2>/dev/null | head -n 1)
                if [ -n "$yaml_needs_update" ] && [ "$yaml_needs_update" != "null" ]; then
                    _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == env(PROXY_NAME) and .network == "ws") | .["ws-opts"]["max-early-data"]) = (env(WS_ED) | tonumber) | (.proxies[] | select(.name == env(PROXY_NAME) and .network == "ws") | .["ws-opts"]["early-data-header-name"]) = env(WS_EDH)' >/dev/null 2>&1 && yaml_updated=true
                fi
            fi

            if [[ "$share_link" == *"ed%3D${WS_EARLY_DATA_SIZE}"* || "$share_link" == *"ed=${WS_EARLY_DATA_SIZE}"* ]]; then
                continue
            fi

            if [[ "$protocol" == "vless-ws" && -n "$uuid" && "$uuid" != "null" ]]; then
                _show_node_link "vless-ws" "$name" "$domain" "443" "$tag" "$uuid" "$path" >/dev/null
                links_updated=true
            elif [[ "$protocol" == "trojan-ws" && -n "$password" && "$password" != "null" ]]; then
                _show_node_link "trojan-ws" "$name" "$domain" "443" "$tag" "$password" "$path" >/dev/null
                links_updated=true
            fi
        done < <(jq -r 'to_entries[] | [.key, (.value.protocol // "vless-ws"), (.value.name // ""), (.value.domain // ""), (.value.uuid // ""), (.value.password // ""), (.value.path // "/"), (.value.share_link // "")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    if [ "$config_updated" = true ]; then
        _info "已为既有 Argo WS 节点补齐 Early Data 配置，正在重启 sing-box..."
        _manage_service restart
    elif [ "$links_updated" = true ] || [ "$yaml_updated" = true ]; then
        _info "已同步既有 Argo WS 节点的 Early Data 客户端配置。"
    fi
}

_argo_menu() {
    _sanitize_argo_metadata || return 1
    _sync_argo_early_data
    while true; do
        clear
        echo -e "${CYAN}"
        echo '  ╔═══════════════════════════════════════╗'
        echo '  ║           Argo 隧道节点管理           ║'
        echo '  ╚═══════════════════════════════════════╝'
        echo -e "${NC}"
        
        echo -e "  ${CYAN}【创建节点】${NC}"
        echo -e "    ${YELLOW}仅提供无需 Token 的临时 trycloudflare.com 隧道${NC}"
        echo -e "    ${GREEN}[1]${NC} 创建 VLESS-WS + Argo 节点"
        echo -e "    ${GREEN}[2]${NC} 创建 Trojan-WS + Argo 节点"
        echo ""
        
        echo -e "  ${CYAN}【节点管理】${NC}"
        echo -e "    ${GREEN}[3]${NC} 查看 Argo 节点信息"
        echo -e "    ${GREEN}[4]${NC} 查看 Argo 隧道日志"
        echo -e "    ${GREEN}[5]${NC} 删除 Argo 节点"
        echo ""
        
        echo -e "  ${CYAN}【隧道控制】${NC}"
        echo -e "    ${RED}[6]${NC} 卸载 Argo 服务"
        echo -e "    ${GREEN}[7]${NC} 重启 Argo 隧道"
        echo ""
        
        echo -e "  ─────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
        echo ""
        
        read -p "  请输入选项 [0-7]: " choice

        case $choice in
            1) _add_argo_vless_ws ;;
            2) _add_argo_trojan_ws ;;
            3) _view_argo_nodes ;;
            4) _view_argo_logs ;;
            5) _delete_argo_node ;;
            6) _uninstall_argo ;;
            7) _restart_argo_tunnel_menu ;;
            0) break ;;
            *) _error "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# --- 服务与配置管理 ---

_create_systemd_service() {
    local mem_limit_mb=$(_get_mem_limit)
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Environment="GOMEMLIMIT=${mem_limit_mb}MiB"
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE} -c ${SINGBOX_DIR}/relay.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

_create_openrc_service() {
    # 确保日志文件存在
    touch "${LOG_FILE}"
    local mem_limit_mb=$(_get_mem_limit)
    
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

description="sing-box service"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE} -c ${SINGBOX_DIR}/relay.json"
# 使用 supervise-daemon 实现守护和重启
supervisor="supervise-daemon"
supervise_daemon_args="--env GOMEMLIMIT=${mem_limit_mb}MiB"
respawn_delay=3
respawn_max=0

pidfile="${PID_FILE}"
# supervise-daemon 自动将 stdout/stderr 重定向功能需要 openrc 版本支持
# 如果不支持，日志可能不会输出到文件，但服务能正常运行
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$SERVICE_FILE"
}

_create_service_files() {
    
    _info "正在创建 ${INIT_SYSTEM} 服务文件..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        _create_systemd_service
        systemctl daemon-reload
        systemctl enable sing-box
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        touch "$LOG_FILE"
        _create_openrc_service
        rc-update add sing-box default
    elif [ "$INIT_SYSTEM" == "direct" ]; then
        touch "$LOG_FILE"
        _info "当前容器没有 systemd/openrc，将使用 direct 后台模式管理 sing-box。"
        return 0
    fi
    _success "${INIT_SYSTEM} 服务创建并启用成功。"
}

# 每天 03:17（服务器本地时间）清空一次本脚本产生的运行日志。
_cleanup_runtime_logs() {
    local log
    for log in "$LOG_FILE" "$ARGO_LOG_FILE" "${SINGBOX_DIR}/relay_operations.log" /tmp/singbox_argo_*.log; do
        [ -f "$log" ] && : > "$log"
    done
}

_setup_log_cleanup() {
    command -v crontab >/dev/null 2>&1 || {
        _warning "未找到 crontab，无法启用每日自动清理日志。"
        return 1
    }

    local tag="# sing-box-log-cleanup"
    local job="17 3 * * * bash ${SELF_SCRIPT_PATH} cleanup-logs >/dev/null 2>&1 ${tag}"
    local current
    current=$(crontab -l 2>/dev/null || true)
    if ! printf '%s\n' "$current" | grep -Fqx "$job"; then
        { printf '%s\n' "$current" | grep -Fv "$tag"; printf '%s\n' "$job"; } | sed '/^$/d' | crontab - || return 1
    fi
}

_remove_log_cleanup() {
    local tag="# sing-box-log-cleanup"
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$tag"; then
        crontab -l 2>/dev/null | grep -Fv "$tag" | crontab -
    fi
}


# 注意: _manage_service 已在上方定义，此处不再重复定义

_view_log() {
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        _info "按 Ctrl+C 退出日志查看。"
        journalctl -u sing-box -f --no-pager
    else # 适用于 openrc 和 direct 模式
        if [ ! -f "$LOG_FILE" ]; then
            _warning "日志文件 ${LOG_FILE} 不存在。"
            return
        fi
        _info "按 Ctrl+C 退出日志查看 (日志文件: ${LOG_FILE})。"
        tail -f "$LOG_FILE"
    fi
}

_uninstall() {
    local managed_sing_box=false
    local managed_yq=false
    local managed_cloudflared=false
    local managed_realitlscanner=false
    local managed_go_toolchain=false
    local preserve_router_manager=false
    [ -f "${SINGBOX_DIR}/.managed_sing_box" ] && managed_sing_box=true
    [ -f "${SINGBOX_DIR}/.managed_yq" ] && managed_yq=true
    [ -f "${SINGBOX_DIR}/.managed_cloudflared" ] && managed_cloudflared=true
    [ -f "${SINGBOX_DIR}/.managed_realitlscanner" ] && managed_realitlscanner=true
    [ -f "$GO_TOOLCHAIN_MARKER" ] && managed_go_toolchain=true
    if [ -s "$SNI_ROUTER_STATE_FILE" ] && \
       [ "$(jq -r '.https_routes | length' "$SNI_ROUTER_STATE_FILE" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        preserve_router_manager=true
    fi

    _warning "！！！警告！！！"
    _warning "本操作将停止并禁用 [主脚本] 服务 (sing-box)，"
    _warning "删除所有相关文件 (包括二进制、组件脚本、别名及配置文件)。"
    
    echo ""
    echo "即将删除以下内容："
    echo -e "  ${RED}-${NC} 主配置与脚本目录: ${SINGBOX_DIR}"
    [ "$managed_sing_box" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 sing-box: ${SINGBOX_BIN}"
    [ "$managed_yq" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 yq: ${YQ_BINARY}"
    [ "$managed_cloudflared" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 cloudflared: ${CLOUDFLARED_BIN}"
    [ "$managed_realitlscanner" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 RealiTLScanner: ${REALITL_SCANNER_BIN}"
    [ "$managed_go_toolchain" = true ] && echo -e "  ${RED}-${NC} RealiTLScanner 专用 Go 工具链: ${GO_TOOLCHAIN_DIR}"
    echo -e "  ${YELLOW}!${NC} Nginx、证书和 ACME 续期任务将保留，避免影响同机 Emby 反代。"
    echo -e "  ${YELLOW}!${NC} 若 HAProxy 仍登记 Emby SNI，将保留 HAProxy 与共享路由状态。"
    echo -e "  ${RED}-${NC} 系统别名: /usr/local/bin/sb"
    echo -e "  ${RED}-${NC} 管理脚本: ${SELF_SCRIPT_PATH}"
    echo ""
    
    read -p "$(echo -e ${YELLOW}"确定要执行卸载吗? (y/N): "${NC})" confirm_main
    [[ "$confirm_main" != "y" && "$confirm_main" != "Y" ]] && _info "卸载已取消。" && return

    # 1. 先注销 Reality 默认后端；失败时保持 sing-box 原状运行。
    local router_reality_tag=""
    router_reality_tag=$(jq -r '.reality.tag // empty' "$SNI_ROUTER_STATE_FILE" 2>/dev/null)
    [ -z "$router_reality_tag" ] || _sni_router_remove_reality "$router_reality_tag" || {
        _error "无法安全注销 HAProxy Reality 后端，卸载已中止。"
        return 1
    }
    local router_tls_tag
    while IFS= read -r router_tls_tag; do
        [ -n "$router_tls_tag" ] || continue
        _sni_router_remove_tls "$router_tls_tag" || {
            _error "无法安全注销 HAProxy TLS 后端 ${router_tls_tag}，卸载已中止。"
            return 1
        }
    done < <(jq -r '.tls_routes | to_entries[]? | select(.value.owner == "sb") | .value.tag' "$SNI_ROUTER_STATE_FILE" 2>/dev/null)

    # 2. 停止服务
    _manage_service "stop"
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl disable sing-box >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-update del sing-box default >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
    fi

    # 3. 清理配置与日志
    _info "正在清理配置文件与日志..."
    _remove_log_cleanup
    # 清理脚本创建的 nftables 规则
    local pf_meta="${SINGBOX_DIR}/relay_pf.json"
    [ ! -f "$pf_meta" ] && pf_meta="${SINGBOX_DIR}/pf_metadata.json"
    if [ -f "$pf_meta" ] && command -v jq &>/dev/null; then
        # 清理 DNS 动态刷新的 cron 任务
        if crontab -l 2>/dev/null | grep -qF "# pf-dns-auto-refresh"; then
            crontab -l 2>/dev/null | grep -vF "# pf-dns-auto-refresh" | crontab -
        fi
    fi
    _remove_nftables_rules

    # 4. 先停止脚本创建的 Argo 任务，再删除元数据。
    _disable_argo_watchdog 2>/dev/null
    _stop_all_argo_tunnels 2>/dev/null
    rm -rf "${SINGBOX_DIR}" "${LOG_FILE}" "${ARGO_LOG_FILE}"
    if [ "$managed_cloudflared" = true ]; then
        rm -f "${CLOUDFLARED_BIN}"
    fi
    if [ "$managed_realitlscanner" = true ]; then
        rm -f "$REALITL_SCANNER_BIN" "$REALITL_SCANNER_MARKER" "${REALITL_SCANNER_DIR}/RealiTLScanner.commit"
    fi
    if [ "$managed_go_toolchain" = true ] && [ "$GO_TOOLCHAIN_DIR" = "/usr/local/lib/singbox-lite/go-toolchain" ]; then
        rm -rf -- "$GO_TOOLCHAIN_DIR"
    fi
    rmdir "$REALITL_SCANNER_DIR" 2>/dev/null || true

    # 5. 若 Emby 仍依赖共享入口，保留管理命令，避免 deploy.sh 以后无法注销路由。
    _info "正在清理周边环境..."
    if [ "$preserve_router_manager" = true ]; then
        _warn "检测到仍在使用的 Emby SNI 路由，将保留 ${SELF_SCRIPT_PATH} 与 /usr/local/bin/sb 作为 HAProxy 管理器。"
    else
        rm -f "/usr/local/bin/sb"
    fi
    
    # 6. 仅删除带有本脚本管理标记的二进制，避免误删用户已有程序。
    local relay_script="/root/relay-install.sh"
    if [ -f "$relay_script" ]; then
        _warn "检测到 [线路机] 脚本存在，为保持其运行，将 [保留] sing-box 主程序。"
    else
        [ "$managed_sing_box" = true ] && rm -f "${SINGBOX_BIN}"
        [ "$managed_yq" = true ] && rm -f "${YQ_BINARY}"
    fi

    if [ "$preserve_router_manager" = true ]; then
        _success "Sing-box 核心与节点已清理；HAProxy/Emby 路由管理器已保留。"
    else
        _success "清理完成。脚本已自毁。再见！"
        [ -f "${SELF_SCRIPT_PATH}" ] && rm -f "${SELF_SCRIPT_PATH}"
    fi
    exit 0
}

_initialize_config_files() {
    mkdir -p ${SINGBOX_DIR}
    if [ ! -s "$CONFIG_FILE" ]; then
        # 初始化包含完整 dns 配置和路由策略的基础文件，以支持中转第三方域名节点
        cat > "$CONFIG_FILE" << 'EOF'
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-main"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [],
    "default_domain_resolver": "dns-main",
    "final": "direct"
  }
}
EOF
    fi
    [ -s "$METADATA_FILE" ] || echo "{}" > "$METADATA_FILE"
    
    # [关键修复] 初始化 relay.json - 服务启动命令会加载这个文件
    # 必须确保在服务运行前此文件物理存在，否则 sing-box 会 Fatal 退出
    local RELAY_JSON="${SINGBOX_DIR}/relay.json"
    if [ ! -s "$RELAY_JSON" ]; then
        echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$RELAY_JSON"
        _info "已初始化中转配置文件: $RELAY_JSON"
    fi
    if [ ! -s "$CLASH_YAML_FILE" ]; then
        _info "正在创建全新的 clash.yaml 配置文件..."
        cat > "$CLASH_YAML_FILE" << 'EOF'
port: 7890
socks-port: 7891
mixed-port: 7892
allow-lan: false
bind-address: '*'
mode: rule
log-level: info
ipv6: true
find-process-mode: strict
external-controller: '127.0.0.1:9090'
profile:
  store-selected: true
  store-fake-ip: true
unified-delay: true
tcp-concurrent: true
ntp:
  enable: true
  write-to-system: false
  server: ntp.aliyun.com
  port: 123
  interval: 30
dns:
  enable: true
  respect-rules: true
  use-system-hosts: true
  prefer-h3: false
  listen: '0.0.0.0:1053'
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  fake-ip-filter:
    - +.lan
    - +.local
    - localhost.ptlogin2.qq.com
    - +.msftconnecttest.com
    - +.msftncsi.com
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
    - 'https://1.1.1.1/dns-query'
    - 'https://dns.quad9.net/dns-query'
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  proxy-server-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 'https://1.0.0.1/dns-query'
    - 'https://9.9.9.10/dns-query'
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - 'any:53'
  device: SakuraiTunnel
  endpoint-independent-nat: true
proxies: []
proxy-groups:
  - name: 节点选择
    type: select
    proxies: []
rules:
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF
    fi
}

_init_relay_config() {
    # 确保中转配置文件存在 (隔离配置)
    if [ ! -s "${SINGBOX_DIR}/relay.json" ]; then
        echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "${SINGBOX_DIR}/relay.json"
        _info "已初始化中转配置文件"
    fi
}

_cleanup_legacy_config() {
    # 检查并清理 config.json 中残留的旧版中转配置 (tag 以 relay-out- 开头的 outbound)
    # 这些残留会导致路由冲突，使主脚本节点误走中转线路
    local needs_restart=false
    
    if jq -e '.outbounds[] | select(.tag | startswith("relay-out-"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warn "检测到旧版中转残留配置，正在清理..."
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_legacy"
        
        # 删除所有 relay-out- 开头的 outbounds
        jq 'del(.outbounds[] | select(.tag | startswith("relay-out-")))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        
        # 删除所有 relay-out- 开头的路由规则 (如果有)
        if jq -e '.route.rules' "$CONFIG_FILE" >/dev/null 2>&1; then
            jq 'del(.route.rules[] | select(.outbound | startswith("relay-out-")))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        
        # 确保存在 direct 出站且位于第一位 (如果没有 direct，添加一个)
        if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
             jq '.outbounds = [{"type":"direct","tag":"direct"}] + .outbounds' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        
        _success "配置清理完成。相关中转已被迁移至独立配置文件 (relay.json)。"
        needs_restart=true
    fi
    
    # [关键修复] 确保 route.final 设置为 "direct"
    # 这是核心修复：当 config.json 和 relay.json 合并时，relay-out-* outbound 会被插入到 outbounds 列表前面
    # 如果没有 route.final，sing-box 会使用列表中的第一个 outbound 作为默认出口，导致主节点流量走中转
    if ! jq -e '.route.final == "direct"' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warn "检测到 route.final 未设置或不正确，正在修复..."
        
        # 确保 route 对象存在
        if ! jq -e '.route' "$CONFIG_FILE" >/dev/null 2>&1; then
            jq '. + {"route":{"rules":[],"final":"direct"}}' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        else
            # 设置 route.final = "direct"
            jq '.route.final = "direct"' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        
        _success "route.final 已设置为 direct，主节点流量将走本机 IP。"
        needs_restart=true
    fi
    
    if [ "$needs_restart" = true ]; then
        return 0
    fi
    return 1
}

_build_dns_config() {
    local dns_address="$1" dns_strategy="$2"
    local scheme rest authority host port path default_port main_json
    local needs_bootstrap=false

    if [ "$dns_address" = "local" ]; then
        jq -n --arg strategy "$dns_strategy" \
            '{servers:[{type:"local",tag:"dns-main"}],strategy:$strategy}'
        return
    fi

    if [[ "$dns_address" == *"://"* ]]; then
        scheme="${dns_address%%://*}"
        rest="${dns_address#*://}"
    elif _is_valid_ipv4 "$dns_address" || [[ "$dns_address" =~ ^\[?[0-9A-Fa-f:]+\]?$ && "$dns_address" == *:* ]]; then
        scheme="udp"
        rest="$dns_address"
    else
        return 1
    fi
    case "$scheme" in
        udp|tcp|tls|https) ;;
        *) return 1 ;;
    esac

    if [ "$scheme" = "https" ]; then
        authority="${rest%%/*}"
        if [[ "$rest" == */* ]]; then
            path="/${rest#*/}"
        else
            path="/dns-query"
        fi
        [ -n "$path" ] || path="/dns-query"
    else
        [[ "$rest" != */* ]] || return 1
        authority="$rest"
        path=""
    fi

    if [[ "$authority" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
    elif [[ "$authority" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$authority" =~ ^[0-9A-Fa-f:]+$ && "$authority" == *:* ]]; then
        host="$authority"
        port=""
    else
        host="$authority"
        port=""
    fi
    [[ -n "$host" && "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1

    case "$scheme" in
        udp|tcp) default_port=53 ;;
        tls) default_port=853 ;;
        https) default_port=443 ;;
    esac
    port="${port:-$default_port}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1

    main_json=$(jq -n --arg type "$scheme" --arg server "$host" --argjson port "$port" --arg path "$path" '
        {type:$type,tag:"dns-main",server:$server,server_port:$port}
        | if $type == "https" then .path = $path else . end
    ') || return 1
    if ! _is_valid_ipv4 "$host" && [[ "$host" != *:* ]]; then
        needs_bootstrap=true
    fi

    if [ "$needs_bootstrap" = true ]; then
        jq -n --argjson main "$main_json" --arg strategy "$dns_strategy" '
            {servers:[($main + {domain_resolver:"dns-bootstrap"}),{type:"local",tag:"dns-bootstrap"}],strategy:$strategy}
        '
    else
        jq -n --argjson main "$main_json" --arg strategy "$dns_strategy" \
            '{servers:[$main],strategy:$strategy}'
    fi
}

_dns_current_address() {
    jq -r '
        ((.dns.servers[]? | select(.tag == "dns-main")) // .dns.servers[0]? // {}) as $server
        | if (($server.address? // "") | type) == "string" and ($server.address? // "") != "" then
            $server.address
          elif $server.type == "local" then
            "local"
          elif ($server.server? // "") != "" then
            ($server.server | if contains(":") then "[" + . + "]" else . end) as $host
            | (($server.type // "udp") + "://" + $host
               + (if $server.server_port? then ":" + ($server.server_port | tostring) else "" end)
               + (if $server.type == "https" then ($server.path // "/dns-query") else "" end))
          else
            "未设置"
          end
    ' "$CONFIG_FILE" 2>/dev/null
}

_check_and_fix_dns() {
    # 迁移脚本旧版 DNS 格式，避免 sing-box 1.14 删除兼容入口后首次启动失败。
    # 返回值：0=已修改，1=无需修改，2=迁移失败。
    if [ ! -f "$CONFIG_FILE" ]; then return 2; fi

    local has_dns has_auto_detect dns_strategy legacy_count resolver_tag
    local needs_restart=false tmp_file dns_json legacy_address
    has_dns=$(jq -r '(.dns.servers? | type == "array") and ((.dns.servers | length) > 0)' "$CONFIG_FILE" 2>/dev/null)
    has_auto_detect=$(jq -r 'try (.route.auto_detect_interface == true) catch false' "$CONFIG_FILE" 2>/dev/null)
    dns_strategy=$(jq -r '.dns.strategy // ""' "$CONFIG_FILE" 2>/dev/null)
    legacy_count=$(jq -r '[.dns.servers[]? | select(has("address"))] | length' "$CONFIG_FILE" 2>/dev/null)
    tmp_file="${CONFIG_FILE}.tmp"

    if [ "$has_dns" != "true" ]; then
        dns_json=$(_build_dns_config local "${dns_strategy:-prefer_ipv4}") || return 2
        jq --argjson dns "$dns_json" '
            .dns = $dns
            | .route = (.route // {rules:[],final:"direct"})
            | .route.default_domain_resolver = "dns-main"
            | del(.route.auto_detect_interface)
        ' "$CONFIG_FILE" > "$tmp_file" || { rm -f "$tmp_file"; return 2; }
        needs_restart=true
    elif [ "$legacy_count" -gt 0 ]; then
        if [ "$legacy_count" -ne 1 ] || [ "$(jq -r '.dns.servers | length' "$CONFIG_FILE")" -ne 1 ]; then
            _warn "检测到自定义的多服务器旧版 DNS 配置，无法无损自动迁移。"
            _warn "请先在 DNS 菜单重新选择服务器，再升级到 sing-box 1.14。"
            return 2
        fi
        legacy_address=$(jq -r '.dns.servers[0].address // empty' "$CONFIG_FILE")
        dns_json=$(_build_dns_config "$legacy_address" "${dns_strategy:-prefer_ipv4}") || {
            _warn "旧版 DNS 地址无法自动迁移: ${legacy_address}"
            return 2
        }
        jq --argjson dns "$dns_json" '
            .dns = $dns
            | .route = (.route // {rules:[],final:"direct"})
            | .route.default_domain_resolver = "dns-main"
            | del(.route.auto_detect_interface)
        ' "$CONFIG_FILE" > "$tmp_file" || { rm -f "$tmp_file"; return 2; }
        needs_restart=true
    else
        resolver_tag=$(jq -r '.dns.servers[0].tag // empty' "$CONFIG_FILE")
        if [ "$has_auto_detect" = "true" ] || [ -z "$dns_strategy" ] || { [ -n "$resolver_tag" ] && ! jq -e '.route.default_domain_resolver? | strings | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; }; then
            jq --arg strategy "${dns_strategy:-prefer_ipv4}" --arg resolver "$resolver_tag" '
                .dns.strategy = $strategy
                | .route = (.route // {rules:[],final:"direct"})
                | if $resolver != "" and ((.route.default_domain_resolver // "") == "") then .route.default_domain_resolver = $resolver else . end
                | del(.route.auto_detect_interface)
            ' "$CONFIG_FILE" > "$tmp_file" || { rm -f "$tmp_file"; return 2; }
            needs_restart=true
        fi
    fi

    if [ "$needs_restart" = true ]; then
        if [ -s "$tmp_file" ] && mv "$tmp_file" "$CONFIG_FILE"; then
            _success "DNS 配置已迁移到 sing-box 1.14 兼容格式。"
        else
            _error "DNS 配置兼容性修复失败。"
            rm -f "$tmp_file"
            return 2
        fi
    fi

    if [ -f "$CLASH_YAML_FILE" ] && [ -x "$YQ_BINARY" ]; then
        local clash_ipv6=$(${YQ_BINARY} eval '.ipv6 // false' "$CLASH_YAML_FILE" 2>/dev/null)
        local clash_dns_ipv6=$(${YQ_BINARY} eval '.dns.ipv6 // false' "$CLASH_YAML_FILE" 2>/dev/null)
        if [ "$clash_ipv6" != "true" ] || [ "$clash_dns_ipv6" != "true" ]; then
            if _atomic_modify_yaml "$CLASH_YAML_FILE" '.ipv6 = true | .dns.ipv6 = true' >/dev/null 2>&1; then
                _success "已开启 clash.yaml 的 IPv6 与 DNS IPv6 支持。"
            else
                _warn "clash.yaml IPv6 自动修复失败，请手动检查 YAML 格式。"
            fi
        fi
    fi
    
    if [ "$needs_restart" == "true" ]; then
        return 0
    fi
    return 1
}

_generate_self_signed_cert() {
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"

    _info "正在为 ${domain} 生成支持 SAN 的高级自签名证书..."
    
    # 创建临时配置文件用于生成 SAN
    local openssl_config=$(mktemp)
    cat > "$openssl_config" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${domain}
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
EOF

    # 使用 RSA 2048 生成证书 (CF 回源兼容性更佳)
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$key_path" -out "$cert_path" \
        -config "$openssl_config" >/dev/null 2>&1
    
    local status=$?
    rm -f "$openssl_config"

    if [ $status -ne 0 ]; then
        _error "为 ${domain} 生成证书失败！"
        rm -f "$cert_path" "$key_path"
        return 1
    fi
    chmod 600 "$cert_path" "$key_path" 2>/dev/null || true
    _success "证书 ${cert_path} (含 SAN) 已成功生成。"
    return 0
}

# 注意: _atomic_modify_json, _atomic_modify_yaml, _get_proxy_field, _add_node_to_yaml, _remove_node_from_yaml
# 均在上方统一定义，此处不再重复定义以避免不一致

# 显示节点分享链接（在添加节点后调用）
# 参数: $1=协议类型, $2=节点名称, $3=服务器IP(用于链接), $4=端口, $5=节点TAG, 其他参数根据协议不同
_show_node_link() {
    local type="$1"
    local name="$2"
    local link_ip="$3"
    local port="$4"
    local tag="$5"
    # [关键修复] 处理 IPv6 括号包裹逻辑
    if [[ "$link_ip" == *":"* ]] && [[ "$link_ip" != "["* ]]; then
        link_ip="[${link_ip}]"
    fi

    shift 5
    
    local url=""
    
    case "$type" in
        "vless-reality")
            # 参数: uuid, sni, public_key, short_id, flow
            local uuid="$1" pk="$3" sid="$4" flow="${5:-xtls-rprx-vision}"
            # 对 SNI 执行终极保底与净化
            local sni=$(echo "$2" | xargs)
            [[ -z "$sni" ]] && sni="$DEFAULT_SNI"
            
            url="vless://${uuid}@${link_ip}:${port}?security=reality&encryption=none&pbk=$(_url_encode "${pk}")&fp=firefox&type=tcp&flow=${flow}&sni=${sni}&sid=${sid}#$(_url_encode "$name")"
            ;;
        "vless-ws-tls")
            # 参数: uuid, sni, ws_path, skip_verify
            local uuid="$1" sni="${2:-$DEFAULT_SNI}" ws_path="$3" skip_verify="$4" cert_path="$5"
            local insecure_param=$(_tls_insecure_params "$skip_verify" "$cert_path")
            url="vless://${uuid}@${link_ip}:${port}?security=tls&encryption=none&type=ws&host=${sni}&path=$(_url_encode "$ws_path")&sni=${sni}${insecure_param}#$(_url_encode "$name")"
            ;;
        "vless-grpc-tls")
            # 参数: uuid, sni, service_name, skip_verify, cert_path
            local uuid="$1" sni="${2:-$DEFAULT_SNI}" service_name="$3" skip_verify="$4" cert_path="$5"
            local insecure_param=$(_tls_insecure_params "$skip_verify" "$cert_path")
            url="vless://${uuid}@${link_ip}:${port}?security=tls&encryption=none&type=grpc&serviceName=$(_url_encode "$service_name")&authority=${sni}&sni=${sni}${insecure_param}#$(_url_encode "$name")"
            ;;
        "vless-tcp")
            # 参数: uuid
            local uuid="$1"
            url="vless://${uuid}@${link_ip}:${port}?encryption=none&type=tcp#$(_url_encode "$name")"
            ;;
        "trojan-ws-tls")
            # 参数: password, sni, ws_path, skip_verify
            local password="$1" sni="${2:-$DEFAULT_SNI}" ws_path="$3" skip_verify="$4" cert_path="$5"
            local insecure_param=$(_tls_insecure_params "$skip_verify" "$cert_path")
            url="trojan://${password}@${link_ip}:${port}?security=tls&type=ws&host=${sni}&path=$(_url_encode "$ws_path")&sni=${sni}${insecure_param}#$(_url_encode "$name")"
            ;;
        "hysteria2")
            # 参数: password, sni, obfs_password(可选), port_hopping(可选)
            local password="$1" sni="${2:-$DEFAULT_SNI}" obfs_password="$3" port_hopping="$4"
            local obfs_param=""; [[ -n "$obfs_password" ]] && obfs_param="&obfs=salamander&obfs-password=$(_url_encode "${obfs_password}")"
            local hop_param=""; [[ -n "$port_hopping" ]] && hop_param="&mport=${port_hopping}&ports=${port_hopping}"
            local cert_path="${SINGBOX_DIR}/${tag}.pem"
            local pin_param=""
            local cert_pcs=$(_cert_sha256_hex "$cert_path")
            [ -n "$cert_pcs" ] && pin_param="&pinSHA256=${cert_pcs}"
            url="hysteria2://${password}@${link_ip}:${port}?sni=${sni}&insecure=1${obfs_param}${hop_param}${pin_param}#$(_url_encode "$name")"
            ;;
        "tuic")
            # 参数: uuid, password, sni
            local uuid="$1" password="$2" sni="${3:-$DEFAULT_SNI}"
            url="tuic://${uuid}:${password}@${link_ip}:${port}?sni=${sni}&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#$(_url_encode "$name")"
            ;;
        "anytls")
            # 参数: password, sni, skip_verify
            local password="$1" sni="${2:-$DEFAULT_SNI}" skip_verify="$3" cert_path="$4"
            local insecure_param=$(_tls_insecure_params "$skip_verify" "$cert_path")
            url="anytls://$(_url_encode "$password")@${link_ip}:${port}/?sni=$(_url_encode "$sni")${insecure_param}#$(_url_encode "$name")"
            ;;
        "any-reality")
            # 参数: password, sni, public_key, short_id
            local password="$1" sni="${2:-$DEFAULT_SNI}" public_key="$3" short_id="$4"
            url="anytls://$(_url_encode "$password")@${link_ip}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=$(_url_encode "${public_key}")&sid=${short_id}&type=tcp&headerType=none#$(_url_encode "$name")"
            ;;
        "shadowsocks")
            # 参数: method, password
            local method="$1" password="$2"
            local userinfo=$(printf '%s' "${method}:${password}" | base64 | tr -d '\n\r ' | tr '+/' '-_' | tr -d '=')
            url="ss://${userinfo}@${link_ip}:${port}#$(_url_encode "$name")"
            ;;
        "shadowsocks-shadowtls")
            # 参数: method, pw, spw, sni
            local method="$1" pw="$2" spw="$3" sni="$4"
            url=""
            echo -e "${YELLOW}====== [客户端配置参考片段 (Clash Meta / Mihomo)] ======${NC}"
            echo -e "  - name: \"${name}\""
            echo -e "    type: ss"
            echo -e "    server: ${link_ip}"
            echo -e "    port: ${port}"
            echo -e "    cipher: ${method}"
            echo -e "    password: ${pw}"
            echo -e "    plugin: shadow-tls"
            echo -e "    plugin-opts:"
            echo -e "      host: ${sni}"
            echo -e "      password: ${spw}"
            echo -e "      version: 3"
            echo -e "${YELLOW}========================================================${NC}"
            echo -e "${CYAN}[提示] ShadowTLS 需要特定的客户端配置。${NC}"
            echo -e "${CYAN}您也可以直接打开本机位于 ${YELLOW}/usr/local/etc/sing-box/clash.yaml${CYAN} 的配置文件，${NC}"
            echo -e "${CYAN}找到对应节点的 YAML 代码块，并复制到您的客户端中使用！${NC}"
            ;;
        "vless-ws")
            # Argo 专用: uuid, path
            local uuid="$1" ws_path="$2"
            local ed_path=$(_ws_path_with_early_data "$ws_path")
            url="vless://${uuid}@${link_ip}:443?encryption=none&security=tls&type=ws&host=${link_ip}&path=$(_url_encode "$ed_path")&sni=${link_ip}#$(_url_encode "$name")"
            ;;
        "trojan-ws")
            # Argo 专用: password, path
            local password="$1" ws_path="$2"
            local ed_path=$(_ws_path_with_early_data "$ws_path")
            url="trojan://$(_url_encode "${password}")@${link_ip}:443?security=tls&type=ws&host=${link_ip}&path=$(_url_encode "$ed_path")&sni=${link_ip}#$(_url_encode "$name")"
            ;;
        "socks")
            # 参数: username, password
            local username="$1" password="$2"
            echo ""
            _info "节点信息: 服务器: ${link_ip}, 端口: ${port}, 用户名: ${username}, 密码: ${password}"
            return
            ;;
    esac
    
    if [ -n "$url" ]; then
        echo ""
        local clean_url=$(echo "$url" | sed 's/&insecure=1//g' | sed 's/&pcs=[a-fA-F0-9]*//g')
        if [ "$clean_url" != "$url" ] && [[ "$type" != "anytls" ]] && [[ "$type" != "hysteria2" ]] && [[ "$type" != "tuic" ]] && [[ "$type" != "vless-reality" ]] && [[ "$type" != "any-reality" ]]; then
            echo -e "${YELLOW}═══════════════ 🔗 直连分享链接 (含防劫持指纹) ═══════════════${NC}"
            echo -e "${CYAN}${url}${NC}"
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${YELLOW}═════════════ 🔗 CF优选专用链接 (纯净版，无指纹冲突) ═════════════${NC}"
            echo -e "${CYAN}${clean_url}${NC}"
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
            echo -e "${CYAN}[提示] 如果您套用了 Cloudflare，请导入 ${YELLOW}CF优选专用链接${CYAN} 以避免握手失败！${NC}"
        else
            echo -e "${YELLOW}═══════════════════ 分享链接 ═══════════════════${NC}"
            echo -e "${CYAN}${url}${NC}"
            echo -e "${YELLOW}═════════════════════════════════════════════════${NC}"
        fi
        
        # [持久化] 将生成的链接存入元数据，防止查看时由于动态提取导致的 SNI 丢失
        if [ -n "$tag" ] && [ "$tag" != "null" ]; then
            if [[ "$tag" == argo-* ]]; then
                _atomic_modify_json "$ARGO_METADATA_FILE" ". + { \"$tag\": ((.[\"$tag\"] // {}) + { \"share_link\": \"$url\" }) }"
            else
                _atomic_modify_json "$METADATA_FILE" ". + { \"$tag\": ((.[\"$tag\"] // {}) + { \"share_link\": \"$url\" }) }"
            fi
        fi
    fi
}

_show_cdn_guidance() {
    local domain="$1"
    local port="$2"
    echo ""
    echo -e "${YELLOW}══════════════════ 🔧 如何开启 Cloudflare CDN 优选 ══════════════════${NC}"
    _info "本脚本不会读取或保存 Cloudflare API Token，请在 Cloudflare 后台手动完成："
    _info "1. ${CYAN}【DNS】${NC}新增 A/AAAA 记录指向本机公网 IP，并开启小黄云 (${ORANGE}Proxied${NC})。"
    _info "2. ${CYAN}【CF 后台】${NC}在 [SSL/TLS] 菜单中，将加密模式设为: ${GREEN}Full (完全)${NC}。"
    if [ "$port" != "443" ]; then
        _warn "3. 您的服务器监听的是 ${port} 端口。请在 [Rules] -> [Origin Rules] 中配置："
        _warn "   - 主机名 包含 \"${domain}\" -> 重写到端口: ${port}"
    else
        _info "3. 您的服务器已监听 443 端口，无需设置 Origin Rules。"
    fi
    _info "4. ${CYAN}【客户端】${NC}修改配置：地址改为优选域名/IP，端口改为 ${GREEN}443${NC}。"
    _info "   (注：Host/SNI 必须保持为您的域名 ${domain})"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════${NC}"
}

_show_grpc_cdn_guidance() {
    local domain="$1"
    local port="$2"
    echo ""
    echo -e "${YELLOW}══════════════════ 🔧 VLESS gRPC + Cloudflare 配置提示 ══════════════════${NC}"
    _info "本脚本不会读取或保存 Cloudflare API Token，请在 Cloudflare 后台手动完成："
    _info "1. ${CYAN}【DNS】${NC}新增 A/AAAA 记录指向本机公网 IP，并开启小黄云 (${ORANGE}Proxied${NC})。"
    _info "2. ${CYAN}【CF 后台】${NC}在 [SSL/TLS] 菜单中，将加密模式设为: ${GREEN}Full (完全)${NC}。"
    _info "3. ${CYAN}【CF 后台】${NC}在 [Network] 菜单中确认 gRPC 已开启。"
    if [ "$port" != "443" ]; then
        _warn "4. 您的服务器监听的是 ${port} 端口。请在 [Rules] -> [Origin Rules] 中配置："
        _warn "   - 主机名 包含 \"${domain}\" -> 重写到端口: ${port}"
    else
        _info "4. 您的服务器已监听 443 端口，无需设置 Origin Rules。"
    fi
    _info "5. ${CYAN}【客户端】${NC}地址可改为优选域名/IP，端口改为 ${GREEN}443${NC}。"
    _info "   (注：SNI 必须保持为您的域名 ${domain}，gRPC serviceName 必须保持一致)"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════${NC}"
}


_add_vless_ws_tls() {
    local camouflage_domain=""
    local port=""
    local client_server_addr="${server_ip}"

    if [ "$BATCH_MODE" = "true" ]; then
        [[ -n "$BATCH_IP" ]] && client_server_addr="$BATCH_IP"
        port="$BATCH_PORT"
        camouflage_domain="${BATCH_WS_TLS_DOMAIN:-$BATCH_SNI}"
    else
        _info "--- VLESS (WebSocket+TLS) 设置向导 ---"
        _info "请输入客户端用于“连接”的地址:"
        _info "  - (推荐) 直接回车, 使用VPS的公网 IP: ${server_ip}"
        _info "  - (其他) 您也可以手动输入一个IP或域名"
        read -p "请输入连接地址 (默认: ${server_ip}): " connection_address
        client_server_addr=${connection_address:-$server_ip}
        
        # IPv6 处理
        if [[ "$client_server_addr" == *":"* ]] && [[ "$client_server_addr" != "["* ]]; then
             client_server_addr="[${client_server_addr}]"
        fi

        _info "请输入您的“伪装域名”，这个域名必须是您证书对应的域名。"
        _info " (例如: xxx.741865.xyz)"
        read -p "请输入伪装域名: " camouflage_domain
        [[ -z "$camouflage_domain" ]] && _error "伪装域名不能为空" && return 1

        while true; do
            read -p "请输入监听端口 (直连模式下首推 443 端口): " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _check_port_conflict "$port" "tcp" && continue
            break
        done
    fi

    # 客户端连接端口默认与监听端口一致 (直连模式)
    local client_port="$port"

    # --- 步骤 4: 路径 ---
    local ws_path=""
    if [ "$BATCH_MODE" = "true" ]; then
        ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
    else
        read -p "请输入 WebSocket 路径 (回车则随机生成): " input_ws_path
        if [ -z "$input_ws_path" ]; then
            ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
            _info "已为您生成随机 WebSocket 路径: ${ws_path}"
        else
            ws_path="$input_ws_path"
            [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
        fi
    fi

    # 提前定义 tag，用于证书文件命名
    local tag="vless-ws-in-${port}"
    local cert_path=""
    local key_path=""
    local skip_verify=false

    # --- 步骤 5: 证书选择 ---
    local cert_choice="1"
    if [ "$BATCH_MODE" = "true" ]; then
        cert_choice="1"
    else
        echo ""
        echo "请选择证书类型:"
        echo "  1) 自动生成自签名证书 (适合CF回源/直连跳过验证)"
        echo "  2) 手动上传证书文件 (acme.sh签发/Cloudflare源证书等)"
        read -p "请选择 [1-2] (默认: 1): " cert_choice
        cert_choice=${cert_choice:-1}
    fi

    if [ "$cert_choice" == "1" ]; then
        # 自签名证书
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1
        skip_verify=true
        _info "已生成自签名证书，客户端将跳过证书验证。"
    else
        # 手动上传证书
        _info "请输入 ${camouflage_domain} 对应的证书文件路径。"
        _info "  - (推荐) 使用 acme.sh 签发的 fullchain.pem"
        _info "  - (或)   使用 Cloudflare 源服务器证书"
        read -p "请输入证书文件 .pem/.crt 的完整路径: " cert_path
        [[ ! -f "$cert_path" ]] && _error "证书文件不存在: ${cert_path}" && return 1

        read -p "请输入私钥文件 .key 的完整路径: " key_path
        [[ ! -f "$key_path" ]] && _error "私钥文件不存在: ${key_path}" && return 1
        
        # 询问是否跳过验证
        read -p "$(echo -e ${YELLOW}"您是否正在使用 Cloudflare 源服务器证书 (或自签名证书)? (y/N): "${NC})" use_origin_cert
        if [[ "$use_origin_cert" == "y" || "$use_origin_cert" == "Y" ]]; then
            skip_verify=true
            _warning "已启用 'skip-cert-verify: true'。这将跳过证书验证。"
        fi
    fi
    
    # [!] 自定义名称
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-VLESS-WS-${port}"
    else
        local default_name="VLESS-WS-${port}"
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi

    local uuid=$(${SINGBOX_BIN} generate uuid)
    
    # Inbound (服务器端) 配置
    local inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$port" \
        --arg u "$uuid" \
        --arg cp "$cert_path" \
        --arg kp "$key_path" \
        --arg sn "$camouflage_domain" \
        --arg wsp "$ws_path" \
        '{
            "type": "vless",
            "tag": $t,
            "listen": "::",
            "listen_port": ($p|tonumber),
            "users": [{"uuid": $u, "flow": ""}],
            "tls": {
                "enabled": true,
                "server_name": $sn,
                "certificate_path": $cp,
                "key_path": $kp
            },
            "transport": {
                "type": "ws",
                "path": $wsp
            }
        }')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    # Proxy (客户端) 配置
    local proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$client_server_addr" \
            --arg p "$client_port" \
            --arg u "$uuid" \
            --arg sn "$camouflage_domain" \
            --arg wsp "$ws_path" \
            --arg skip_verify_bool "$skip_verify" \
            --arg host_header "$camouflage_domain" \
            '{
                "name": $n,
                "type": "vless",
                "server": $s,
                "port": ($p|tonumber),
                "uuid": $u,
                "encryption": "none",
                "tls": true,
                "udp": true,
                "skip-cert-verify": ($skip_verify_bool == "true"),
                "network": "ws",
                "sni": $sn,
                "ws-opts": {
                    "path": $wsp,
                    "headers": {
                        "Host": $host_header
                    }
                }
            }')
            
    _add_node_to_yaml "$proxy_json"
    _success "VLESS (WebSocket+TLS) 节点 [${name}] 添加成功!"
    _success "客户端连接地址 (server): ${client_server_addr}"
    _success "客户端连接端口 (port): ${client_port}"
    _success "客户端伪装域名 (sni/Host): ${camouflage_domain}"
    
    # CDN 指引 (仅在非批量模式下详细显示)
    [ "$BATCH_MODE" != "true" ] && _show_cdn_guidance "${camouflage_domain}" "${port}"

    # IPv6 处理用于链接
    local link_ip="$client_server_addr"
    _show_node_link "vless-ws-tls" "$name" "$link_ip" "$client_port" "$tag" "$uuid" "$camouflage_domain" "$ws_path" "$skip_verify" "$cert_path"
}

_add_vless_grpc_tls() {
    local camouflage_domain=""
    local port=""
    local client_server_addr="${server_ip}"

    if [ "$BATCH_MODE" = "true" ]; then
        [[ -n "$BATCH_IP" ]] && client_server_addr="$BATCH_IP"
        port="$BATCH_PORT"
        camouflage_domain="${BATCH_GRPC_TLS_DOMAIN:-$BATCH_SNI}"
    else
        _info "--- VLESS (gRPC+TLS) 设置向导 ---"
        _info "请输入客户端用于“连接”的地址:"
        _info "  - (推荐) 直接回车, 使用VPS的公网 IP: ${server_ip}"
        _info "  - (其他) 您也可以手动输入一个IP或域名"
        read -p "请输入连接地址 (默认: ${server_ip}): " connection_address
        client_server_addr=${connection_address:-$server_ip}

        # IPv6 处理
        if [[ "$client_server_addr" == *":"* ]] && [[ "$client_server_addr" != "["* ]]; then
             client_server_addr="[${client_server_addr}]"
        fi

        _info "请输入您的“伪装域名”，这个域名必须是您证书对应的域名。"
        _info " (例如: xxx.741865.xyz)"
        read -p "请输入伪装域名: " camouflage_domain
        [[ -z "$camouflage_domain" ]] && _error "伪装域名不能为空" && return 1

        while true; do
            read -p "请输入监听端口 (直连模式下首推 443 端口): " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _check_port_conflict "$port" "tcp" && continue
            break
        done
    fi

    local client_port="$port"

    local generated_service_name="grpc-$(${SINGBOX_BIN} generate rand --hex 4)"
    local service_name=""
    if [ "$BATCH_MODE" = "true" ]; then
        service_name="${BATCH_GRPC_SERVICE_NAME:-$generated_service_name}"
    else
        read -p "请输入 gRPC serviceName (回车则随机生成: ${generated_service_name}): " input_service_name
        service_name=${input_service_name:-$generated_service_name}
        service_name=$(echo "$service_name" | xargs)
        [[ -z "$service_name" ]] && _error "gRPC serviceName 不能为空" && return 1
        _info "gRPC serviceName: ${service_name}"
    fi

    local tag="vless-grpc-in-${port}"
    local cert_path=""
    local key_path=""
    local skip_verify=false

    local cert_choice="1"
    if [ "$BATCH_MODE" = "true" ]; then
        cert_choice="1"
    else
        echo ""
        echo "请选择证书类型:"
        echo "  1) 自动生成自签名证书 (适合CF回源/直连跳过验证)"
        echo "  2) 手动上传证书文件 (acme.sh签发/Cloudflare源证书等)"
        read -p "请选择 [1-2] (默认: 1): " cert_choice
        cert_choice=${cert_choice:-1}
    fi

    if [ "$cert_choice" == "1" ]; then
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1
        skip_verify=true
        _info "已生成自签名证书，客户端将跳过证书验证。"
    else
        _info "请输入 ${camouflage_domain} 对应的证书文件路径。"
        _info "  - (推荐) 使用 acme.sh 签发的 fullchain.pem"
        _info "  - (或)   使用 Cloudflare 源服务器证书"
        read -p "请输入证书文件 .pem/.crt 的完整路径: " cert_path
        [[ ! -f "$cert_path" ]] && _error "证书文件不存在: ${cert_path}" && return 1

        read -p "请输入私钥文件 .key 的完整路径: " key_path
        [[ ! -f "$key_path" ]] && _error "私钥文件不存在: ${key_path}" && return 1

        read -p "$(echo -e ${YELLOW}"您是否正在使用 Cloudflare 源服务器证书 (或自签名证书)? (y/N): "${NC})" use_origin_cert
        if [[ "$use_origin_cert" == "y" || "$use_origin_cert" == "Y" ]]; then
            skip_verify=true
            _warning "已启用 'skip-cert-verify: true'。这将跳过证书验证。"
        fi
    fi

    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-VLESS-gRPC-${port}"
    else
        local default_name="VLESS-gRPC-${port}"
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi

    local uuid=$(${SINGBOX_BIN} generate uuid)

    local inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$port" \
        --arg u "$uuid" \
        --arg cp "$cert_path" \
        --arg kp "$key_path" \
        --arg sn "$camouflage_domain" \
        --arg svc "$service_name" \
        '{
            "type": "vless",
            "tag": $t,
            "listen": "::",
            "listen_port": ($p|tonumber),
            "users": [{"uuid": $u, "flow": ""}],
            "tls": {
                "enabled": true,
                "server_name": $sn,
                "alpn": ["h2"],
                "certificate_path": $cp,
                "key_path": $kp
            },
            "transport": {
                "type": "grpc",
                "service_name": $svc
            }
        }')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    local proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$client_server_addr" \
            --arg p "$client_port" \
            --arg u "$uuid" \
            --arg sn "$camouflage_domain" \
            --arg svc "$service_name" \
            --arg skip_verify_bool "$skip_verify" \
            '{
                "name": $n,
                "type": "vless",
                "server": $s,
                "port": ($p|tonumber),
                "uuid": $u,
                "encryption": "none",
                "tls": true,
                "udp": true,
                "skip-cert-verify": ($skip_verify_bool == "true"),
                "network": "grpc",
                "servername": $sn,
                "grpc-opts": {
                    "grpc-service-name": $svc
                }
            }')

    _add_node_to_yaml "$proxy_json"
    _success "VLESS (gRPC+TLS) 节点 [${name}] 添加成功!"
    _success "客户端连接地址 (server): ${client_server_addr}"
    _success "客户端连接端口 (port): ${client_port}"
    _success "客户端伪装域名 (sni): ${camouflage_domain}"
    _success "gRPC serviceName: ${service_name}"

    [ "$BATCH_MODE" != "true" ] && _show_grpc_cdn_guidance "${camouflage_domain}" "${port}"

    local link_ip="$client_server_addr"
    _show_node_link "vless-grpc-tls" "$name" "$link_ip" "$client_port" "$tag" "$uuid" "$camouflage_domain" "$service_name" "$skip_verify" "$cert_path"
}

_add_trojan_ws_tls() {
    local camouflage_domain=""
    local port=""
    local client_server_addr="${server_ip}"

    if [ "$BATCH_MODE" = "true" ]; then
        [[ -n "$BATCH_IP" ]] && client_server_addr="$BATCH_IP"
        port="$BATCH_PORT"
        camouflage_domain="${BATCH_WS_TLS_DOMAIN:-$BATCH_SNI}"
    else
        _info "--- Trojan (WebSocket+TLS) 设置向导 ---"
        _info "请输入客户端用于“连接”的地址:"
        _info "  - (推荐) 直接回车, 使用VPS的公网 IP: ${server_ip}"
        _info "  - (其他) 您也可以手动输入一个IP或域名"
        read -p "请输入连接地址 (默认: ${server_ip}): " connection_address
        client_server_addr=${connection_address:-$server_ip}
        
        # IPv6 处理
        if [[ "$client_server_addr" == *":"* ]] && [[ "$client_server_addr" != "["* ]]; then
             client_server_addr="[${client_server_addr}]"
        fi

        _info "请输入您的“伪装域名”，这个域名必须是您证书对应的域名。"
        read -p "请输入伪装域名: " camouflage_domain
        [[ -z "$camouflage_domain" ]] && _error "伪装域名不能为空" && return 1

        while true; do
            read -p "请输入监听端口 (直连模式下首推 443 端口): " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _check_port_conflict "$port" "tcp" && continue
            break
        done
    fi

    # 客户端连接端口默认与监听端口一致 (直连模式)
    local client_port="$port"

    # --- 步骤 4: 路径 ---
    local ws_path=""
    if [ "$BATCH_MODE" = "true" ]; then
        ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
    else
        read -p "请输入 WebSocket 路径 (回车则随机生成): " input_ws_path
        if [ -z "$input_ws_path" ]; then
            ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
            _info "已为您生成随机 WebSocket 路径: ${ws_path}"
        else
            ws_path="$input_ws_path"
            [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
        fi
    fi

    # 提前定义 tag，用于证书文件命名
    local tag="trojan-ws-in-${port}"
    local cert_path=""
    local key_path=""
    local skip_verify=false

    # --- 步骤 5: 证书选择 ---
    if [ "$BATCH_MODE" = "true" ]; then
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1
        skip_verify=true
    else
        echo ""
        echo "请选择证书类型:"
        echo "  1) 自动生成自签名证书 (适合CF回源/直连跳过验证)"
        echo "  2) 手动上传证书文件 (acme.sh签发/Cloudflare源证书等)"
        read -p "请选择 [1-2] (默认: 1): " cert_choice
        cert_choice=${cert_choice:-1}
        if [ "$cert_choice" == "1" ]; then
            cert_path="${SINGBOX_DIR}/${tag}.pem"
            key_path="${SINGBOX_DIR}/${tag}.key"
            _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1
            skip_verify=true
            _info "已生成自签名证书，客户端将跳过证书验证。"
        else
            # 手动上传证书
            _info "请输入 ${camouflage_domain} 对应的证书文件路径。"
            _info "  - (推荐) 使用 acme.sh 签发的 fullchain.pem"
            _info "  - (或)   使用 Cloudflare 源服务器证书"
            read -p "请输入证书文件 .pem/.crt 的完整路径: " cert_path
            [[ ! -f "$cert_path" ]] && _error "证书文件不存在: ${cert_path}" && return 1

            read -p "请输入私钥文件 .key 的完整路径: " key_path
            [[ ! -f "$key_path" ]] && _error "私钥文件不存在: ${key_path}" && return 1
            
            # 询问是否跳过验证
            read -p "$(echo -e ${YELLOW}"您是否正在使用 Cloudflare 源服务器证书 (或自签名证书)? (y/N): "${NC})" use_origin_cert
            if [[ "$use_origin_cert" == "y" || "$use_origin_cert" == "Y" ]]; then
                skip_verify=true
                _warning "已启用 'skip-cert-verify: true'。这将跳过证书验证。"
            fi
        fi
    fi

    # [!] Trojan: 使用密码
    local password=""
    if [ "$BATCH_MODE" = "true" ]; then
        password=$(${SINGBOX_BIN} generate rand --hex 16)
    else
        read -p "请输入 Trojan 密码 (回车则随机生成): " input_pw
        if [ -z "$input_pw" ]; then
            password=$(${SINGBOX_BIN} generate rand --hex 16)
            _info "已为您生成随机密码: ${password}"
        else
            password="$input_pw"
        fi
    fi

    # [!] 自定义名称
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-Trojan-WS-${port}"
    else
        local default_name="Trojan-WS-${port}"
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi

    # Inbound (服务器端) 配置
    local inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$port" \
        --arg pw "$password" \
        --arg cp "$cert_path" \
        --arg kp "$key_path" \
        --arg sn "$camouflage_domain" \
        --arg wsp "$ws_path" \
        '{
            "type": "trojan",
            "tag": $t,
            "listen": "::",
            "listen_port": ($p|tonumber),
            "users": [{"password": $pw}],
            "tls": {
                "enabled": true,
                "server_name": $sn,
                "certificate_path": $cp,
                "key_path": $kp
            },
            "transport": {
                "type": "ws",
                "path": $wsp
            }
        }')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    # Proxy (客户端) 配置
    local proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$client_server_addr" \
            --arg p "$client_port" \
            --arg pw "$password" \
            --arg sn "$camouflage_domain" \
            --arg wsp "$ws_path" \
            --arg skip_verify_bool "$skip_verify" \
            --arg host_header "$camouflage_domain" \
            '{
                "name": $n,
                "type": "trojan",
                "server": $s,
                "port": ($p|tonumber),
                "password": $pw,
                "udp": true,
                "skip-cert-verify": ($skip_verify_bool == "true"),
                "network": "ws",
                "sni": $sn,
                "ws-opts": {
                    "path": $wsp,
                    "headers": {
                        "Host": $host_header
                    }
                }
            }')
            
    _add_node_to_yaml "$proxy_json"
    _success "Trojan (WebSocket+TLS) 节点 [${name}] 添加成功!"
    _success "客户端连接地址 (server): ${client_server_addr}"
    _success "客户端连接端口 (port): ${client_port}"
    _success "客户端伪装域名 (sni/Host): ${camouflage_domain}"
    
    # CDN 指引 (仅在非批量模式下详细显示)
    [ "$BATCH_MODE" != "true" ] && _show_cdn_guidance "${camouflage_domain}" "${port}"

    # IPv6 处理用于链接
    local link_ip="$client_server_addr"
    _show_node_link "trojan-ws-tls" "$name" "$link_ip" "$client_port" "$tag" "$password" "$camouflage_domain" "$ws_path" "$skip_verify" "$cert_path"
}

_activate_anytls_sni_route() {
    local route_kind="$1" tag="$2" server_name="$3" backend_port="$4" name="$5"
    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" >/dev/null 2>&1 || \
       ! _manage_service restart; then
        _error "Sing-box 新配置未能启动，正在撤销新节点。"
        _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))" >/dev/null 2>&1 || true
        _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")" >/dev/null 2>&1 || true
        _remove_node_from_yaml "$name" >/dev/null 2>&1 || true
        rm -f "${SINGBOX_DIR}/${tag}.pem" "${SINGBOX_DIR}/${tag}.key"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    local listener_ready=false listener_attempt
    for listener_attempt in 1 2 3 4 5; do
        if _check_port_occupied "$backend_port" tcp; then
            listener_ready=true
            break
        fi
        sleep 1
    done
    if [ "$listener_ready" != true ]; then
        _error "Sing-box 未监听 AnyTLS 回环端口 ${backend_port}，正在撤销新节点。"
        _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))" >/dev/null 2>&1 || true
        _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")" >/dev/null 2>&1 || true
        _remove_node_from_yaml "$name" >/dev/null 2>&1 || true
        rm -f "${SINGBOX_DIR}/${tag}.pem" "${SINGBOX_DIR}/${tag}.key"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi

    if { [ "$route_kind" = "reality" ] && ! _sni_router_register_reality sb "$tag" "$server_name" "$backend_port"; } || \
       { [ "$route_kind" = "tls" ] && ! _sni_router_register_tls sb "$tag" "$server_name" "$backend_port"; }; then
        _error "HAProxy AnyTLS 路由登记失败，正在撤销新节点。"
        _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))" >/dev/null 2>&1 || true
        _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")" >/dev/null 2>&1 || true
        _remove_node_from_yaml "$name" >/dev/null 2>&1 || true
        rm -f "${SINGBOX_DIR}/${tag}.pem" "${SINGBOX_DIR}/${tag}.key"
        _manage_service restart >/dev/null 2>&1 || true
        return 1
    fi
    ADD_NODE_SERVICE_RESTARTED=true
    _info "公网 443 -> HAProxy -> 127.0.0.1:${backend_port} -> Sing-box AnyTLS"
}

_create_anytls_tls_node() {
    local node_ip="$1"
    local port="$2"
    local server_name="$3"
    local password="$4"
    local name="$5"
    local listen_address="${6:-::}"
    local backend_port="${7:-$port}"
    local router_mode="${8:-false}"

    # --- 步骤 4: 证书选择 ---
    local cert_choice="1"
    if [ "$BATCH_MODE" = "true" ]; then
        cert_choice="1"
    else
        echo ""
        echo "请选择证书类型:"
        echo "  1) 自动生成自签名证书 (推荐)"
        echo "  2) 手动上传证书文件 (Cloudflare源证书等)"
        read -p "请选择 [1-2] (默认: 1): " cert_choice
        cert_choice=${cert_choice:-1}
    fi
    
    local cert_path=""
    local key_path=""
    local skip_verify=true  # 默认跳过验证 (自签证书需要)
    local tag="anytls-in-${port}"
    
    if [ "$cert_choice" == "1" ]; then
        # 自签名证书
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1
        _info "已生成自签名证书，客户端将跳过证书验证。"
    else
        # 手动上传证书
        _info "请输入 ${server_name} 对应的证书文件路径。"
        read -p "请输入证书文件 .pem/.crt 的完整路径: " cert_path
        [[ ! -f "$cert_path" ]] && _error "证书文件不存在: ${cert_path}" && return 1
        
        read -p "请输入私钥文件 .key 的完整路径: " key_path
        [[ ! -f "$key_path" ]] && _error "私钥文件不存在: ${key_path}" && return 1
        
        # 询问是否跳过验证
        read -p "$(echo -e ${YELLOW}"您是否正在使用自签名证书或Cloudflare源证书? (y/N): "${NC})" use_self_signed
        if [[ "$use_self_signed" == "y" || "$use_self_signed" == "Y" ]]; then
            skip_verify=true
            _warning "已启用 'skip-cert-verify: true'，客户端将跳过证书验证。"
        else
            skip_verify=false
        fi
    fi
    
    # IPv6 处理
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    
    # --- 生成 Inbound 配置 ---
    # 不固定 padding_scheme，让当前 sing-box 自动使用并跟随上游默认填充方案。
    local inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$backend_port" \
        --arg listen "$listen_address" \
        --arg pw "$password" \
        --arg sn "$server_name" \
        --arg cp "$cert_path" \
        --arg kp "$key_path" \
        '{
            "type": "anytls",
            "tag": $t,
            "listen": $listen,
            "listen_port": ($p|tonumber),
            "users": [{"name": "default", "password": $pw}],
            "tls": {
                "enabled": true,
                "alpn": ["http/1.1"],
                "certificate_path": $cp,
                "key_path": $kp
            }
        }')
    
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1
    
    # --- 生成 Clash YAML 配置 ---
    # 根据用户提供的格式：包含 client-fingerprint, udp, alpn
    local proxy_json=$(jq -n \
        --arg n "$name" \
        --arg s "$yaml_ip" \
        --arg p "$port" \
        --arg pw "$password" \
        --arg sn "$server_name" \
        --arg skip_verify_bool "$skip_verify" \
        '{
            "name": $n,
            "type": "anytls",
            "server": $s,
            "port": ($p|tonumber),
            "password": $pw,
            "client-fingerprint": "firefox",
            "udp": true,
            "idle-session-check-interval": 30,
            "idle-session-timeout": 30,
            "min-idle-session": 0,
            "sni": $sn,
            "alpn": ["h2", "http/1.1"],
            "skip-cert-verify": ($skip_verify_bool == "true")
        }')
    
    _add_node_to_yaml "$proxy_json"
    
    # --- 保存元数据 ---
    local meta_json
    meta_json=$(jq -n --arg n "$name" --arg sn "$server_name" --argjson public "$port" \
        --argjson backend "$backend_port" --argjson routed "$router_mode" \
        '{name:$n, server_name:$sn, yaml:true, publicPort:$public, backendPort:$backend} +
         (if $routed then {frontedBy:"haproxy",routerRole:"tls-sni"} else {} end)')
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta_json}" || return 1

    [ "$router_mode" != true ] || _activate_anytls_sni_route tls "$tag" "$server_name" "$backend_port" "$name" || return 1
    
    _success "AnyTLS 节点 [${name}] 添加成功!"
    _show_node_link "anytls" "$name" "$link_ip" "$port" "$tag" "$password" "$server_name" "$skip_verify"
}

_create_anyreality_node() {
    local node_ip="$1"
    local port="$2"
    local server_name="$3"
    local password="$4"
    local name="$5"
    local handshake_server="${6:-$server_name}"
    local handshake_port="${7:-443}"
    local listen_address="${8:-::}"
    local backend_port="${9:-$port}"
    local router_mode="${10:-false}"
    local tag="any-reality-in-${port}"

    local keypair private_key public_key short_id
    keypair=$(${SINGBOX_BIN} generate reality-keypair)
    private_key=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    public_key=$(echo "$keypair" | awk '/PublicKey/ {print $2}')
    short_id=$(${SINGBOX_BIN} generate rand --hex 8)

    local inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$backend_port" \
        --arg listen "$listen_address" \
        --arg pw "$password" \
        --arg sn "$server_name" \
        --arg hs "$handshake_server" \
        --arg hp "$handshake_port" \
        --arg pk "$private_key" \
        --arg sid "$short_id" \
        '{
            "type": "anytls",
            "tag": $t,
            "listen": $listen,
            "listen_port": ($p|tonumber),
            "users": [{"name": "default", "password": $pw}],
            "tls": {
                "enabled": true,
                "server_name": $sn,
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": $hs,
                        "server_port": ($hp|tonumber)
                    },
                    "private_key": $pk,
                    "short_id": [$sid]
                }
            }
        }')

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local share_link="anytls://$(_url_encode "$password")@${link_ip}:${port}?security=reality&sni=${server_name}&fp=firefox&pbk=$(_url_encode "$public_key")&sid=${short_id}&type=tcp&headerType=none#$(_url_encode "$name")"
    local meta_json
    meta_json=$(jq -n \
        --arg type "any-reality" \
        --arg sn "$server_name" \
        --arg hs "$handshake_server" \
        --arg hp "$handshake_port" \
        --arg pub "$public_key" \
        --arg sid "$short_id" \
        --arg link "$share_link" \
        --arg n "$name" \
        --argjson public "$port" \
        --argjson backend "$backend_port" \
        --argjson routed "$router_mode" \
        '{type:$type, name:$n, server_name:$sn, handshake_server:$hs, handshake_port:($hp|tonumber), publicKey:$pub, shortId:$sid, share_link:$link, yaml:false, publicPort:$public, backendPort:$backend} +
         (if $routed then {frontedBy:"haproxy",routerRole:"reality-default"} else {} end)')
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta_json}" || return 1

    [ "$router_mode" != true ] || _activate_anytls_sni_route reality "$tag" "$server_name" "$backend_port" "$name" || return 1

    _success "Any-Reality 节点 [${name}] 添加成功!"
    _warning "Any-Reality 为 AnyTLS + Reality，Mihomo/Clash 不支持，已跳过写入 clash.yaml。"
    _show_node_link "any-reality" "$name" "$link_ip" "$port" "$tag" "$password" "$server_name" "$public_key" "$short_id"
}

_add_anytls() {
    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    local server_name="$DEFAULT_SNI"
    local reality_handshake_server="$DEFAULT_REALITY_SNI"
    local reality_handshake_port=443
    local mode_choice="1"
    local tls_backend_port="" reality_backend_port="" any_reality_port=""
    local tls_listen_address="::" reality_listen_address="::"
    local tls_router_mode=false reality_router_mode=false

    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
        server_name="${BATCH_SNI:-$DEFAULT_SNI}"
        reality_handshake_server="${BATCH_REALITY_HANDSHAKE_SERVER:-${BATCH_SNI:-$DEFAULT_REALITY_SNI}}"
        reality_handshake_port="${BATCH_REALITY_HANDSHAKE_PORT:-443}"
        mode_choice="${BATCH_ANYTLS_MODE:-1}"
    else
        _info "--- 添加 AnyTLS / Any-Reality 节点 ---"
        echo "请选择节点协议:"
        echo "  1) AnyTLS"
        echo "  2) Any-Reality"
        echo "  1,2) 同时创建 AnyTLS 和 Any-Reality"
        read -p "请选择 [1/2/1,2] (默认: 1): " mode_choice
        mode_choice=${mode_choice:-1}
        mode_choice=$(echo "$mode_choice" | tr '，' ',' | xargs)
        case "$mode_choice" in
            1|2|1,2|2,1|"1 2"|"2 1") ;;
            *) _error "无效选择"; return 1 ;;
        esac

        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
        while true; do
            read -p "请输入起始监听端口: " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                _error "端口必须在 1-65535 之间。"
                continue
            fi
            tls_backend_port="$port"
            reality_backend_port="$port"
            tls_listen_address="::"
            reality_listen_address="::"
            tls_router_mode=false
            reality_router_mode=false
            any_reality_port="$port"
            if [[ "$mode_choice" == "1,2" || "$mode_choice" == "2,1" || "$mode_choice" == "1 2" || "$mode_choice" == "2 1" ]]; then
                any_reality_port=$((port + 1))
                reality_backend_port="$any_reality_port"
                if [ "$any_reality_port" -gt 65535 ]; then
                    _error "同时创建两个节点时，起始端口不能为 65535。"
                    continue
                fi
            fi

            local router_target=""
            if [[ "$mode_choice" == *"1"* ]] && [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                router_target="AnyTLS"
            elif [[ "$mode_choice" == *"2"* ]] && [ "$any_reality_port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                router_target="Any-Reality"
            fi
            if [ -n "$router_target" ]; then
                local use_router router_compat="与 Reality/Emby 可共存"
                [ "$router_target" != "Any-Reality" ] || router_compat="可与 Emby 共存；Reality 默认后端只能有一个"
                read -r -p "是否由 HAProxy 复用公网 443（${router_target} ${router_compat}）？[Y/n]: " use_router
                if [[ ! "$use_router" =~ ^[Nn]$ ]]; then
                    _sni_router_prepare || continue
                    if [ "$router_target" = "Any-Reality" ]; then
                        if jq -e '.reality != null' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
                            _error "HAProxy 443 已经登记了一个 Reality 默认后端，请先删除该节点。"
                            continue
                        fi
                        reality_backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || continue
                        reality_listen_address="127.0.0.1"
                        reality_router_mode=true
                    else
                        tls_backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || continue
                        tls_listen_address="127.0.0.1"
                        tls_router_mode=true
                    fi
                fi
            fi
            if [[ "$mode_choice" == *"1"* ]] && [ "$tls_router_mode" != true ]; then
                _check_port_conflict "$port" "tcp" && continue
            fi
            if [[ "$mode_choice" == *"2"* ]] && [ "$reality_router_mode" != true ]; then
                _check_port_conflict "$any_reality_port" "tcp" && continue
            fi
            break
        done
        if [[ "$mode_choice" == *"2"* ]]; then
            _select_reality_sni || return 1
            server_name="$SELECTED_REALITY_SNI"
            reality_handshake_server="$SELECTED_REALITY_HANDSHAKE_SERVER"
            reality_handshake_port="$SELECTED_REALITY_HANDSHAKE_PORT"
        else
            read -p "请输入 AnyTLS 伪装域名/SNI (默认: ${DEFAULT_SNI}): " camouflage_domain
            server_name=${camouflage_domain:-$DEFAULT_SNI}
        fi
    fi

    if [ "$BATCH_MODE" = "true" ]; then
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            _error "批量创建错误: AnyTLS 端口无效。"
            return 1
        fi
        tls_backend_port="$port"
        reality_backend_port="$port"
        any_reality_port="$port"
        if [[ "$mode_choice" == "1,2" || "$mode_choice" == "2,1" || "$mode_choice" == "1 2" || "$mode_choice" == "2 1" ]]; then
            any_reality_port=$((port + 1))
            reality_backend_port="$any_reality_port"
            [ "$any_reality_port" -le 65535 ] || { _error "批量创建错误: Any-Reality 端口超出范围。"; return 1; }
        fi
        if [ "${BATCH_SNI_ROUTER:-false}" = "true" ]; then
            if [[ "$mode_choice" == *"1"* ]] && [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                _sni_router_prepare || return 1
                tls_backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
                tls_listen_address="127.0.0.1"
                tls_router_mode=true
            elif [[ "$mode_choice" == *"2"* ]] && [ "$any_reality_port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                _sni_router_prepare || return 1
                jq -e '.reality == null' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1 || {
                    _error "HAProxy 443 已经登记了一个 Reality 默认后端。"
                    return 1
                }
                reality_backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
                reality_listen_address="127.0.0.1"
                reality_router_mode=true
            fi
        fi
    fi

    local password=""
    if [ "$BATCH_MODE" = "true" ]; then
        password=$(${SINGBOX_BIN} generate uuid)
    else
        read -p "请输入密码/UUID (回车则随机生成，两种模式共用): " input_pw
        password=${input_pw:-$(${SINGBOX_BIN} generate uuid)}
    fi

    local created=false
    case "$mode_choice" in
        1)
            local name
            if [ "$BATCH_MODE" = "true" ]; then
                name="Batch-AnyTLS-${port}"
            else
                local default_name="AnyTLS-${port}"
                read -p "请输入 AnyTLS 节点名称 (默认: ${default_name}): " custom_name
                name=${custom_name:-$default_name}
            fi
            _create_anytls_tls_node "$node_ip" "$port" "$server_name" "$password" "$name" \
                "$tls_listen_address" "$tls_backend_port" "$tls_router_mode" || return 1
            created=true
            ;;
        2)
            local name
            if [ "$BATCH_MODE" = "true" ]; then
                name="Batch-Any-Reality-${port}"
            else
                local default_name="Any-Reality-${port}"
                read -p "请输入 Any-Reality 节点名称 (默认: ${default_name}): " custom_name
                name=${custom_name:-$default_name}
            fi
            _validate_reality_no_self_loop "$port" "$reality_handshake_server" "$reality_handshake_port" || return 1
            _create_anyreality_node "$node_ip" "$port" "$server_name" "$password" "$name" "$reality_handshake_server" "$reality_handshake_port" \
                "$reality_listen_address" "$reality_backend_port" "$reality_router_mode" || return 1
            created=true
            ;;
        1,2|2,1|"1 2"|"2 1")
            local tls_port="$port"
            local reality_port="$any_reality_port"
            local tls_name reality_name
            if [ "$BATCH_MODE" = "true" ]; then
                tls_name="Batch-AnyTLS-${tls_port}"
                reality_name="Batch-Any-Reality-${reality_port}"
            else
                local default_tls_name="AnyTLS-${tls_port}"
                local default_reality_name="Any-Reality-${reality_port}"
                _info "同时创建时，Any-Reality 将使用端口 ${reality_port}。"
                read -p "请输入 AnyTLS 节点名称 (默认: ${default_tls_name}): " custom_tls_name
                tls_name=${custom_tls_name:-$default_tls_name}
                read -p "请输入 Any-Reality 节点名称 (默认: ${default_reality_name}): " custom_reality_name
                reality_name=${custom_reality_name:-$default_reality_name}
            fi
            _validate_reality_no_self_loop "$reality_port" "$reality_handshake_server" "$reality_handshake_port" || return 1
            _create_anytls_tls_node "$node_ip" "$tls_port" "$server_name" "$password" "$tls_name" \
                "$tls_listen_address" "$tls_backend_port" "$tls_router_mode" || return 1
            _create_anyreality_node "$node_ip" "$reality_port" "$server_name" "$password" "$reality_name" "$reality_handshake_server" "$reality_handshake_port" \
                "$reality_listen_address" "$reality_backend_port" "$reality_router_mode" || return 1
            created=true
            ;;
    esac

    [ "$created" = true ]
}

_add_vless_reality() {
    [ -z "$server_ip" ] && server_ip=$(_get_ip)
    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local server_name="$DEFAULT_REALITY_SNI"
    local handshake_server="$DEFAULT_REALITY_SNI"
    local handshake_port=443
    local port=""
    local backend_port=""
    local listen_address="::"
    local router_mode=false
    local name=""

    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
        # 批量模式变量预加载，增加多层保底，防止变量泄露
        server_name=$(echo "${BATCH_SNI}" | xargs)
        [[ -z "$server_name" ]] && server_name="$DEFAULT_REALITY_SNI"
        handshake_server="${BATCH_REALITY_HANDSHAKE_SERVER:-$server_name}"
        handshake_port="${BATCH_REALITY_HANDSHAKE_PORT:-443}"
        name="Batch-Reality-${port}"
        # 批量模式下如果不显式指定，可能丢失 IP，此处进行双重保险
        [ -z "$node_ip" ] && node_ip="$server_ip"
        if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ] && [ "${BATCH_SNI_ROUTER:-false}" = "true" ]; then
            _sni_router_prepare || return 1
            backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
            listen_address="127.0.0.1"
            router_mode=true
        else
            backend_port="$port"
        fi
    else
        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
        _select_reality_sni || return 1
        server_name="$SELECTED_REALITY_SNI"
        handshake_server="$SELECTED_REALITY_HANDSHAKE_SERVER"
        handshake_port="$SELECTED_REALITY_HANDSHAKE_PORT"
        while true; do
            read -p "请输入监听端口: " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                local use_router
                read -r -p "是否由 HAProxy 复用公网 443（Emby 与 Reality 可共存）？[Y/n]: " use_router
                if [[ ! "$use_router" =~ ^[Nn]$ ]]; then
                    _sni_router_prepare || continue
                    if jq -e '.reality != null' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
                        _error "HAProxy 443 已经登记了一个 Reality 默认后端，请复用或删除该节点。"
                        continue
                    fi
                    backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || continue
                    listen_address="127.0.0.1"
                    router_mode=true
                    break
                fi
            fi
            _check_port_conflict "$port" "tcp" && continue
            backend_port="$port"
            break
        done
        local default_name="VLESS-REALITY-${port}"
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi

    local uuid=$(${SINGBOX_BIN} generate uuid)
    local keypair=$(${SINGBOX_BIN} generate reality-keypair)
    local private_key=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    local public_key=$(echo "$keypair" | awk '/PublicKey/ {print $2}')
    local short_id=$(${SINGBOX_BIN} generate rand --hex 8)
    [ -n "$backend_port" ] || backend_port="$port"
    local tag="vless-in-${port}"
    _validate_reality_no_self_loop "$port" "$handshake_server" "$handshake_port" || return 1
    # IPv6处理：YAML用原始IP，链接用带[]的IP
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    
    local inbound_json=$(jq -n --arg t "$tag" --arg p "$backend_port" --arg listen "$listen_address" --arg u "$uuid" --arg sn "$server_name" --arg hs "$handshake_server" --arg hp "$handshake_port" --arg pk "$private_key" --arg sid "$short_id" \
        '{"type":"vless","tag":$t,"listen":$listen,"listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sn,"reality":{"enabled":true,"handshake":{"server":$hs,"server_port":($hp|tonumber)},"private_key":$pk,"short_id":[$sid]}}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1
    local meta_json
    meta_json=$(jq -n --arg n "$name" --arg pub "$public_key" --arg sid "$short_id" \
        --arg hs "$handshake_server" --arg hp "$handshake_port" --argjson public_port "$port" \
        --argjson backend "$backend_port" --argjson routed "$router_mode" \
        '{name:$n,publicKey:$pub,shortId:$sid,handshakeServer:$hs,handshakePort:($hp|tonumber),publicPort:$public_port,backendPort:$backend} +
         (if $routed then {frontedBy:"haproxy",routerRole:"reality-default"} else {} end)')
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta_json}" || return 1
    
    local proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg u "$uuid" --arg sn "$server_name" --arg pbk "$public_key" --arg sid "$short_id" \
        '{"name":$n,"type":"vless","server":$s,"port":($p|tonumber),"uuid":$u,"tls":true,"network":"tcp","flow":"xtls-rprx-vision","servername":$sn,"client-fingerprint":"firefox","reality-opts":{"public-key":$pbk,"short-id":$sid}}')
    _add_node_to_yaml "$proxy_json"
    if [ "$router_mode" = true ]; then
        if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" >/dev/null 2>&1 || \
           ! _manage_service restart; then
            _error "Sing-box 新配置未能启动，正在撤销新节点。"
            _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))" >/dev/null 2>&1 || true
            _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")" >/dev/null 2>&1 || true
            _remove_node_from_yaml "$name" >/dev/null 2>&1 || true
            _manage_service restart >/dev/null 2>&1 || true
            return 1
        fi

        local listener_ready=false listener_attempt
        for listener_attempt in 1 2 3 4 5; do
            if _check_port_occupied "$backend_port" tcp; then
                listener_ready=true
                break
            fi
            sleep 1
        done
        if [ "$listener_ready" != true ]; then
            _error "Sing-box 未监听 Reality 回环端口 ${backend_port}，正在撤销新节点。"
            _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))" >/dev/null 2>&1 || true
            _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")" >/dev/null 2>&1 || true
            _remove_node_from_yaml "$name" >/dev/null 2>&1 || true
            _manage_service restart >/dev/null 2>&1 || true
            return 1
        fi

        if ! _sni_router_register_reality sb "$tag" "$server_name" "$backend_port"; then
            _error "HAProxy Reality 路由登记失败，正在撤销新节点。"
            _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))" >/dev/null 2>&1 || true
            _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")" >/dev/null 2>&1 || true
            _remove_node_from_yaml "$name" >/dev/null 2>&1 || true
            _manage_service restart >/dev/null 2>&1 || true
            return 1
        fi
        ADD_NODE_SERVICE_RESTARTED=true
        _info "公网 443 -> HAProxy -> 127.0.0.1:${backend_port} -> Sing-box Reality"
    fi
    _success "VLESS (REALITY) 节点 [${name}] 添加成功!"
    _show_node_link "vless-reality" "$name" "$link_ip" "$port" "$tag" "$uuid" "$server_name" "$public_key" "$short_id"
}

_add_vless_tcp() {
    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
        if [ -z "$port" ]; then
            _error "批量创建错误: BATCH_PORT 为空，跳过 VLESS (TCP) 安装。"
            return 1
        fi
    else
        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
        while true; do
            read -p "请输入监听端口: " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _check_port_conflict "$port" "tcp" && continue
            break
        done
    fi
    # [!] 自定义名称 (批量模式下自动分配)
    local default_name="VLESS-TCP-${port}"
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-TCP-${port}"
    else
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi

    local uuid=$(${SINGBOX_BIN} generate uuid)
    local tag="vless-tcp-in-${port}"
    # IPv6处理：YAML用原始IP，链接用带[]的IP
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    
    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" \
        '{"type":"vless","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":""}],"tls":{"enabled":false}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1
    
    local proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg u "$uuid" \
        '{"name":$n,"type":"vless","server":$s,"port":($p|tonumber),"uuid":$u,"tls":false,"network":"tcp"}')
    _add_node_to_yaml "$proxy_json"
    _success "VLESS (TCP) 节点 [${name}] 添加成功!"
    _show_node_link "vless-tcp" "$name" "$link_ip" "$port" "$tag" "$uuid"
}

_add_hysteria2() {
    [ -z "$server_ip" ] && server_ip=$(_get_ip)
    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    local server_name="www.amd.com"
    local obfs_password=""
    local port_hopping=""
    local use_multiport="false"

    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
        if [ -z "$port" ]; then
            _error "批量创建错误: BATCH_PORT 为空，跳过 Hysteria2 安装。"
            return 1
        fi
        server_name="$BATCH_SNI"
        # 批量模式 double check
        [ -z "$node_ip" ] && node_ip="$server_ip"
        [ "$BATCH_HY2_OBFS" != "none" ] && obfs_password=$(${SINGBOX_BIN} generate rand --hex 16)
        port_hopping="$BATCH_HY2_HOP"
        if [ -n "$port_hopping" ]; then
            local port_range_start=$(echo $port_hopping | cut -d'-' -f1)
            local port_range_end=$(echo $port_hopping | cut -d'-' -f2)
            if [ "$port_range_start" -lt 1 ] || [ "$port_range_end" -gt 65535 ] || [ "$port_range_start" -gt "$port_range_end" ]; then
                _error "批量创建错误: HY2 端口跳跃范围 ${port_hopping} 无效。"
                return 1
            fi
            local pf_conflict
            pf_conflict=$(_find_pf_udp_conflict_in_range "$port_range_start" "$port_range_end")
            if [ -n "$pf_conflict" ]; then
                local c_port c_name c_net c_target
                IFS=$'\t' read -r c_port c_name c_net c_target <<< "$pf_conflict"
                _error "批量创建错误: HY2 端口跳跃范围 ${port_hopping} 覆盖已有 ${c_net} 端口转发入口 ${c_port}（${c_name} -> ${c_target}）。"
                return 1
            fi
            local hop_conflict
            hop_conflict=$(_find_udp_hop_conflict_in_range "$port_range_start" "$port_range_end" "hy2-in-${port}")
            if [ -n "$hop_conflict" ]; then
                local c_tag c_name c_range c_mode
                IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$hop_conflict"
                _error "批量创建错误: HY2 端口跳跃范围 ${port_hopping} 与已有跳跃范围 ${c_range} 重叠。"
                _error "冲突节点: ${c_name} (${c_tag}, ${c_mode})。"
                return 1
            fi
            use_multiport="true"
        fi
    else
        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
        while true; do
            read -p "请输入监听端口: " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _check_port_conflict "$port" "udp" && continue
            break
        done
        read -p "请输入伪装域名 (默认: www.amd.com): " camouflage_domain
        server_name=${camouflage_domain:-"www.amd.com"}
    fi

    local tag="hy2-in-${port}"
    local cert_path="${SINGBOX_DIR}/${tag}.pem"
    local key_path="${SINGBOX_DIR}/${tag}.key"
    _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1

    local password=""
    if [ "$BATCH_MODE" = "true" ]; then
        password=$(${SINGBOX_BIN} generate rand --hex 16)
    else
        read -p "请输入密码 (默认随机): " password; password=${password:-$(${SINGBOX_BIN} generate rand --hex 16)}
        read -p "是否开启 QUIC 流量混淆 (salamander)? (y/N): " h_choice
        if [[ "$h_choice" == "y" ]]; then
            obfs_password=$(${SINGBOX_BIN} generate rand --hex 16)
        fi
        read -p "是否开启端口跳跃? (y/N): " hop_choice
        if [[ "$hop_choice" == "y" ]]; then
            read -p "请输入端口范围 (如 20000-30000): " port_range
            if [[ "$port_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                port_range_start="${BASH_REMATCH[1]}"
                port_range_end="${BASH_REMATCH[2]}"
                if [ "$port_range_start" -lt 1 ] || [ "$port_range_end" -gt 65535 ] || [ "$port_range_start" -gt "$port_range_end" ]; then
                    _error "端口跳跃范围无效。"
                    return 1
                fi
                local pf_conflict
                pf_conflict=$(_find_pf_udp_conflict_in_range "$port_range_start" "$port_range_end")
                if [ -n "$pf_conflict" ]; then
                    local c_port c_name c_net c_target
                    IFS=$'\t' read -r c_port c_name c_net c_target <<< "$pf_conflict"
                    _error "端口跳跃范围 ${port_range} 覆盖了已有 ${c_net} 端口转发入口 ${c_port}（${c_name} -> ${c_target}）。"
                    _error "请调整跳跃范围或先删除/修改该端口转发规则。"
                    return 1
                fi
                local hop_conflict
                hop_conflict=$(_find_udp_hop_conflict_in_range "$port_range_start" "$port_range_end" "$tag")
                if [ -n "$hop_conflict" ]; then
                    local c_tag c_name c_range c_mode
                    IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$hop_conflict"
                    _error "端口跳跃范围 ${port_range} 与已有跳跃范围 ${c_range} 重叠。"
                    _error "冲突节点: ${c_name} (${c_tag}, ${c_mode})。请调整跳跃范围。"
                    return 1
                fi
                port_hopping="$port_range"
                use_multiport="true"
            fi
        fi
    fi
    
    # [!] 自定义名称
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-Hysteria2-${port}"
    else
        local default_name="Hysteria2-${port}"
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi
    
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local up="${up_speed:-100}"
    local down="${down_speed:-100}"

    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$password" --arg op "$obfs_password" --arg cert "$cert_path" --arg key "$key_path" \
        '{"type":"hysteria2","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"password":$pw}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}} | if $op != "" then .obfs={"type":"salamander","password":$op} else . end')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    # [!] 多端口监听模式逻辑：优先使用 nftables，失败则降级到 JSON Inbound (带数量保护)
    local port_hopping_mode=""
    if [ "$use_multiport" == "true" ] && [ -n "$port_hopping" ]; then
        if _nft_apply_redirect_rule add "$port_range_start" "$port_range_end" "$port" "singboxlite-hy2-hop-${tag}"; then
            _save_nftables_rules 2>/dev/null
            port_hopping_mode="nftables"
            _success "已启动底层 nftables 高效 UDP 端口跳跃范围映射: ${port_hopping} -> ${port}"
        fi

        if [ "$port_hopping_mode" != "nftables" ]; then
            _warn "发现防火墙受限 (无 nftables redirect 写权限)，准备降级至 Sing-box 原生多实例监听方案..."
            local hop_count=$((port_range_end - port_range_start + 1))
            if [ "$hop_count" -le 1000 ]; then
                _info "正在生成原生大量监听配置块 (${port_range_start}-${port_range_end})..."
                local batch_array="[]"
                local skipped=0
                for ((p=port_range_start; p<=port_range_end; p++)); do
                    if [ "$p" -eq "$port" ]; then continue; fi
                    if _check_port_conflict "$p" "udp" "true"; then ((skipped++)); continue; fi
                    local hop_tag="${tag}-hop-${p}"
                    batch_array=$(echo "$batch_array" | jq --arg t "$hop_tag" --arg p "$p" --arg pw "$password" --arg cert "$cert_path" --arg key "$key_path" --arg op "$obfs_password" \
                        '. += [{"type":"hysteria2","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"password":$pw}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}} | if $op != "" then .obfs={"type":"salamander","password":$op} else . end]')
                done
                _atomic_modify_json "$CONFIG_FILE" ".inbounds += $batch_array | .inbounds |= unique_by(.tag)" || return 1
                local added_count=$(echo "$batch_array" | jq 'length')
                port_hopping_mode="native"
                _success "安全降级成功：已硬编码 ${added_count} 个原生辅助监听节点 (跳过 ${skipped} 个冲突端口)。"
            else
                _error "降级失败：目标跳跃端口数量 (${hop_count}) 超出低配原生环境的内存承载安全阈值 (1000)！"
                _warn "鉴于当前系统容器不支持内核级 nftables 重定向，且端口数量超配，已自动取消该节点的跳跃设定。"
                port_hopping=""
                port_hopping_mode=""
            fi
        fi
    fi
    
    # 保存元数据（包含端口跳跃信息）
    local meta_json=$(jq -n --arg up "$up" --arg down "$down" --arg op "$obfs_password" --arg hop "$port_hopping" --arg hop_mode "$port_hopping_mode" \
        '{ "up": $up, "down": $down } | if $op != "" then .obfsPassword = $op else . end | if $hop != "" then .portHopping = $hop else . end | if $hop_mode != "" then .portHoppingMode = $hop_mode else . end')
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta_json}" || return 1

    # Clash 配置中的端口（如果有端口跳跃，使用范围格式）
    local clash_ports="$port"
    if [ -n "$port_hopping" ]; then
        clash_ports="$port_hopping"
    fi
    
    local proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg ports "$clash_ports" --arg pw "$password" --arg sn "$server_name" --arg up "$up" --arg down "$down" --arg op "$obfs_password" --arg hop "$port_hopping" \
        '{
            "name": $n,
            "type": "hysteria2",
            "server": $s,
            "port": ($p|tonumber),
            "password": $pw,
            "sni": $sn,
            "skip-cert-verify": true,
            "alpn": ["h3"],
            "up": ($up|tonumber),
            "down": ($down|tonumber)
        } | if $op != "" then .obfs = "salamander" | .["obfs-password"] = $op else . end | if $hop != "" then .ports = $hop else . end')
    _add_node_to_yaml "$proxy_json"
    
    _success "Hysteria2 节点 [${name}] 添加成功!"
    
    # 显示端口跳跃信息
    if [ -n "$port_hopping" ]; then
        _info "端口跳跃范围: ${port_hopping}"
    fi
    
    _show_node_link "hysteria2" "$name" "$link_ip" "$port" "$tag" "$password" "$server_name" "$obfs_password" "$port_hopping"
}

_add_tuic() {
    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    local server_name="www.amd.com"

    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
        server_name="${BATCH_SNI:-www.amd.com}"
    else
        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
        while true; do
            read -p "请输入监听端口: " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _check_port_conflict "$port" "udp" && continue
            break
        done
        read -p "请输入伪装域名 (默认: www.amd.com): " camouflage_domain
        server_name=${camouflage_domain:-"www.amd.com"}
    fi

    local tag="tuic-in-${port}"
    local cert_path="${SINGBOX_DIR}/${tag}.pem"
    local key_path="${SINGBOX_DIR}/${tag}.key"
    
    _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1

    local uuid=$(${SINGBOX_BIN} generate uuid); local password=$(${SINGBOX_BIN} generate rand --hex 16)
    
    # [!] 自主生成与名称分配
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-TUICv5-${port}"
    else
        local default_name="TUICv5-${port}"
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi

    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" --arg pw "$password" --arg cert "$cert_path" --arg key "$key_path" \
        '{"type":"tuic","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"password":$pw}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1
    
    local proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg u "$uuid" --arg pw "$password" --arg sn "$server_name" \
        '{"name":$n,"type":"tuic","server":$s,"port":($p|tonumber),"uuid":$u,"password":$pw,"sni":$sn,"skip-cert-verify":true,"alpn":["h3"],"udp-relay-mode":"native","congestion-controller":"bbr"}')
    _add_node_to_yaml "$proxy_json"
    _success "TUICv5 节点 [${name}] 添加成功!"
    _show_node_link "tuic" "$name" "$link_ip" "$port" "$tag" "$uuid" "$password" "$server_name"
}

_add_shadowsocks_menu() {
    local choice=""
    if [ "$BATCH_MODE" = "true" ]; then
        choice="$BATCH_SS_VARIANT"
    else
        clear
        echo "========================================"
        _info "          添加 Shadowsocks 节点"
        echo "========================================"
        echo " [经典 SS]"
        echo " 1) aes-256-gcm"
        echo " 2) chacha20-ietf-poly1305"
        echo " [SS-2022 (强抗重放保护)]"
        echo " 3) 2022-blake3-aes-256-gcm"
        echo " 4) 2022-blake3-aes-256-gcm (带 Padding)"
        echo " [SS-2022 + ShadowTLS (完美伪装组合)]"
        echo " 5) 2022-blake3-aes-256-gcm + ShadowTLS v3"
        echo " 0) 返回"
        echo "========================================"
        read -p "请选择加密方式 [0-5]: " choice
    fi

    local method="" password="" name_prefix="" use_multiplex=false use_shadowtls=false
    case $choice in
        1) 
            method="aes-256-gcm"
            password=$(${SINGBOX_BIN} generate rand --hex 16)
            name_prefix="SS-aes256"
            ;;
        2) 
            method="chacha20-ietf-poly1305"
            password=$(${SINGBOX_BIN} generate rand --hex 16)
            name_prefix="SS-chacha20"
            ;;
        3)
            method="2022-blake3-aes-256-gcm"
            # SS-2022 的 aes-256 需要严格的 32 字节 (256位) base64 密钥
            password=$(${SINGBOX_BIN} generate rand --base64 32)
            name_prefix="SS-2022"
            ;;
        4)
            method="2022-blake3-aes-256-gcm"
            password=$(${SINGBOX_BIN} generate rand --base64 32)
            name_prefix="SS-2022-Padding"
            use_multiplex=true
            _info "已启用 Multiplex + Padding 模式"
            _warning "注意：客户端也必须启用 Multiplex + Padding 才能连接！"
            ;;
        5)
            # SS-2022 256 位版本（抗重放增强）
            method="2022-blake3-aes-256-gcm"
            password=$(${SINGBOX_BIN} generate rand --base64 32)
            name_prefix="SS-ShadowTLS"
            use_shadowtls=true
            ;;
        0) return 1 ;;
        *) _error "无效输入"; return 1 ;;
    esac

    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
    else
        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
        read -p "请输入监听端口: " port; [[ -z "$port" ]] && _error "端口不能为空" && return 1
    fi
    
    # [!] 新增：自定义名称
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-${name_prefix}-${port}"
    else
        local default_name="${name_prefix}-${port}"
        read -p "请输入节点名称 (默认: ${default_name}): " custom_name
        name=${custom_name:-$default_name}
    fi
    
    local shadowtls_password=""
    local shadowtls_sni="www.amd.com"
    if [ "$use_shadowtls" == "true" ]; then
        shadowtls_password=$(${SINGBOX_BIN} generate rand --hex 16)
        read -p "请输入 ShadowTLS 伪装白名单域名 (默认: www.amd.com): " custom_sni
        shadowtls_sni=${custom_sni:-www.amd.com}
    fi

    local tag="${name_prefix}-in-${port}"
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    # 根据是否启用 Multiplex 或 ShadowTLS 生成不同配置
    local inbound_json=""
    local jq_modify_expr=".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)"
    
    if [ "$use_shadowtls" == "true" ]; then
        local ss_tag="${tag}-ss"
        inbound_json=$(jq -n --arg t "$tag" --arg st "$ss_tag" --arg p "$port" --arg m "$method" --arg pw "$password" --arg spw "$shadowtls_password" --arg sni "$shadowtls_sni" \
            '[
                {
                    "type": "shadowtls",
                    "tag": $t,
                    "listen": "::",
                    "listen_port": ($p|tonumber),
                    "version": 3,
                    "users": [
                        {
                            "password": $spw
                        }
                    ],
                    "handshake": {
                        "server": $sni,
                        "server_port": 443
                    },
                    "detour": $st
                },
                {
                    "type": "shadowsocks",
                    "tag": $st,
                    "method": $m,
                    "password": $pw
                }
            ]')
        jq_modify_expr=".inbounds += $inbound_json | .inbounds |= unique_by(.tag)"
    elif [ "$use_multiplex" == "true" ]; then
        # 带 Multiplex + Padding 的配置
        inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg m "$method" --arg pw "$password" \
            '{
                "type": "shadowsocks",
                "tag": $t,
                "listen": "::",
                "listen_port": ($p|tonumber),
                "method": $m,
                "password": $pw,
                "multiplex": {
                    "enabled": true,
                    "padding": true
                }
            }')
        jq_modify_expr=".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)"
    else
        # 标准配置
        inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg m "$method" --arg pw "$password" \
            '{
                "type": "shadowsocks",
                "tag": $t,
                "listen": "::",
                "listen_port": ($p|tonumber),
                "method": $m,
                "password": $pw
            }')
        jq_modify_expr=".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)"
    fi
    _atomic_modify_json "$CONFIG_FILE" "$jq_modify_expr" || return 1

    # YAML 配置也需要根据特定状态生成
    local proxy_json=""
    if [ "$use_shadowtls" == "true" ]; then
        proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg m "$method" --arg pw "$password" --arg spw "$shadowtls_password" --arg sni "$shadowtls_sni" \
            '{
                "name": $n,
                "type": "ss",
                "server": $s,
                "port": ($p|tonumber),
                "cipher": $m,
                "password": $pw,
                "plugin": "shadow-tls",
                "plugin-opts": {
                    "host": $sni,
                    "password": $spw,
                    "version": 3
                }
            }')
    elif [ "$use_multiplex" == "true" ]; then
        proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg m "$method" --arg pw "$password" \
            '{
                "name": $n,
                "type": "ss",
                "server": $s,
                "port": ($p|tonumber),
                "cipher": $m,
                "password": $pw,
                "smux": {
                    "enabled": true,
                    "padding": true
                }
            }')
    else
        proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg m "$method" --arg pw "$password" \
            '{
                "name": $n,
                "type": "ss",
                "server": $s,
                "port": ($p|tonumber),
                "cipher": $m,
                "password": $pw
            }')
    fi
    _add_node_to_yaml "$proxy_json"

    _success "Shadowsocks (${method}) 节点 [${name}] 添加成功!"
    if [ "$use_multiplex" == "true" ]; then
        _info "Multiplex + Padding 已启用，客户端需配置对应选项"
    fi
    if [ "$use_shadowtls" == "true" ]; then
        _show_node_link "shadowsocks-shadowtls" "$name" "$link_ip" "$port" "$tag" "$method" "$password" "$shadowtls_password" "$shadowtls_sni"
    else
        _show_node_link "shadowsocks" "$name" "$link_ip" "$port" "$tag" "$method" "$password"
    fi
    return 0
}

_add_socks() {
    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    local username=""
    local password=""

    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
        if [ -z "$port" ]; then
            _error "批量创建错误: BATCH_PORT 为空，跳过 SOCKS5 安装。"
            return 1
        fi
        username=$(${SINGBOX_BIN} generate rand --hex 8)
        password=$(${SINGBOX_BIN} generate rand --hex 16)
    else
        read -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip
        node_ip=${custom_ip:-$server_ip}
        while true; do
            read -p "请输入监听端口: " port
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _check_port_conflict "$port" "tcp" && continue
            break
        done
        read -p "请输入用户名 (默认随机): " username; username=${username:-$(${SINGBOX_BIN} generate rand --hex 8)}
        read -p "请输入密码 (默认随机): " password; password=${password:-$(${SINGBOX_BIN} generate rand --hex 16)}
    fi
    local tag="socks-in-${port}"
    local name="Batch-SOCKS5-${port}"
    [ "$BATCH_MODE" != "true" ] && name="SOCKS5-${port}"
    local display_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && display_ip="[$node_ip]"

    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$username" --arg pw "$password" \
        '{"type":"socks","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"username":$u,"password":$pw}]}')
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json] | .inbounds |= unique_by(.tag)" || return 1

    local proxy_json=$(jq -n --arg n "$name" --arg s "$display_ip" --arg p "$port" --arg u "$username" --arg pw "$password" \
        '{"name":$n,"type":"socks5","server":$s,"port":($p|tonumber),"username":$u,"password":$pw}')
    _add_node_to_yaml "$proxy_json"
    _success "SOCKS5 节点添加成功!"
    _show_node_link "socks" "$name" "$display_ip" "$port" "$tag" "$username" "$password"
}

_view_nodes() {
    if ! jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then _warning "当前没有任何节点。"; return; fi
    
    # 统计有效节点数量（排除辅助节点）
    local node_count=$(jq '[.inbounds[] | select(.tag | contains("-hop-") | not)] | length' "$CONFIG_FILE")
    _info "--- 当前节点信息 (共 ${node_count} 个) ---"
    
    # [关键修复] 确保在查看前清空之前的临时链接缓存
    rm -f /tmp/singbox_links.tmp
    
    # [资源优化] 传递紧凑 JSON，循环内用单次 jq 提取 tag/type/port (3次→1次)
    jq -c '.inbounds[]' "$CONFIG_FILE" | while IFS= read -r node; do
        # 合并3次字段提取为1次
        local _base_fields
        _base_fields=$(echo "$node" | jq -r '[.tag, .type, (.listen_port|tostring)] | @tsv')
        local tag type port
        IFS=$'\t' read -r tag type port <<< "$_base_fields"
        
        # 过滤掉多端口监听生成的辅助节点（跳过 tag 中包含 -hop- 的节点）
        if [[ "$tag" == *"-hop-"* ]]; then continue; fi

        # HAProxy 共享节点的 Sing-box 实际监听端口是回环后端端口；客户端必须使用 publicPort。
        local backend_port="$port"
        local public_port
        public_port=$(jq -r --arg t "$tag" --argjson fallback "$port" '.[$t].publicPort // $fallback' "$METADATA_FILE" 2>/dev/null)
        [ -n "$public_port" ] && [ "$public_port" != "null" ] && port="$public_port"
        
        # 使用统一查找函数
        local proxy_name_to_find=$(_find_proxy_name "$port" "$type" "$tag")

        # 创建显示名称，优先使用 clash.yaml 中的名称，失败则回退到 tag
        local meta_name=$(jq -r --arg t "$tag" '.[$t].name // empty' "$METADATA_FILE" 2>/dev/null)
        local display_name=${proxy_name_to_find:-${meta_name:-$tag}}

        # 优先使用 metadata.json 中的 IP (用于 REALITY 和 TCP)
        local display_server=$(_get_proxy_field "$proxy_name_to_find" ".server")
        # 移除方括号
        local display_ip=$(echo "$display_server" | tr -d '[]')
        # IPv6链接格式：添加[]
        local link_ip="$display_ip"; [[ "$display_ip" == *":"* ]] && link_ip="[$display_ip]"
        
        echo "-------------------------------------"
        # [!] 已修改：使用 display_name
        _info " 节点: ${display_name}"
        if [ "$backend_port" != "$port" ]; then
            _info " 入口: 公网 ${port} -> HAProxy -> 127.0.0.1:${backend_port}"
        fi
        local url=""
        
        # [新架构] 优先使用持久化生成的链接（从极源解决动态提取可能存在的 SNI 丢失死角）
        url=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$METADATA_FILE")
        if { [ -z "$url" ] || [ "$url" == "null" ]; } && [[ "$tag" == argo-* ]] && [ -f "$ARGO_METADATA_FILE" ]; then
            url=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
        fi
        
        if [ -n "$url" ] && [ "$url" != "null" ]; then
            : # 直接使用持久化链接
        else
            case "$type" in
            "vless")
                # [资源优化] 合并 VLESS 关键字段读取，避免循环内多次 jq
                local _vless_fields
                # [加固] 智能回溯 SNI: 优先 .tls.server_name, 备选 .tls.reality.handshake.server。
            _vless_fields=$(echo "$node" | jq -r --arg default_sni "$DEFAULT_REALITY_SNI" '[.users[0].uuid, (.users[0].flow // ""), (.tls.reality.enabled // false | tostring), (.transport.type // ""), (.tls.enabled // false | tostring), (.tls.server_name // .tls.reality.handshake.server // $default_sni), (.tls.certificate_path // ""), (.transport.path // ""), (.transport.service_name // "")] | @tsv')
            IFS=$'\t' read -r uuid flow is_reality transport_type tls_enabled tls_sn cert_path ws_path grpc_service_name <<< "$_vless_fields"
                
                # [加固] 确保 Reality 模式下的流量控制字段非空 (v2rayN 要求)
                [ "$is_reality" == "true" ] && [ -z "$flow" ] && flow="xtls-rprx-vision"
                
                if [ "$is_reality" == "true" ]; then
                    # [修复] 放弃对 Base64/Hex 密钥使用 @tsv，避免损坏
                    local pk=$(jq -r --arg t "$tag" '.[$t].publicKey // empty' "$METADATA_FILE")
                    local sid=$(jq -r --arg t "$tag" '.[$t].shortId // empty' "$METADATA_FILE")
                    local sn="$tls_sn"
                    local fp="firefox"
                    url="vless://${uuid}@${link_ip}:${port}?security=reality&encryption=none&pbk=$(_url_encode "${pk}")&fp=${fp}&type=tcp&flow=${flow}&sni=${sn}&sid=${sid}#$(_url_encode "$display_name")"
                elif [ "$transport_type" == "ws" ]; then
                    # ws_path 已在上方合并提取
                    local sn="$tls_sn"
                    [ -z "$sn" ] || [ "$sn" == "null" ] && sn=$(_get_proxy_field "$proxy_name_to_find" ".servername")
                    url="vless://${uuid}@${link_ip}:${port}?security=tls&encryption=none&type=ws&host=${sn}&path=$(_url_encode "$ws_path")&sni=${sn}#$(_url_encode "$display_name")"
                    
                    # Argo 节点元数据已迁移到 argo_metadata.json
                    local argo_domain=""
                    if [[ "$tag" == argo-* ]] && [ -f "$ARGO_METADATA_FILE" ]; then
                        argo_domain=$(jq -r --arg t "$tag" '.[$t].domain // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
                    fi
                    if [ -n "$argo_domain" ] && [ "$argo_domain" != "null" ]; then
                        local argo_ws_path=$(_ws_path_with_early_data "$ws_path")
                        url="vless://${uuid}@${argo_domain}:443?security=tls&encryption=none&type=ws&host=${argo_domain}&path=$(_url_encode "$argo_ws_path")&sni=${argo_domain}#$(_url_encode "$display_name")"
                    fi
                elif [ "$transport_type" == "grpc" ]; then
                    local sn="$tls_sn"
                    [ -z "$sn" ] || [ "$sn" == "null" ] && sn=$(_get_proxy_field "$proxy_name_to_find" ".servername")
                    [ -z "$sn" ] || [ "$sn" == "null" ] && sn="$DEFAULT_SNI"
                    local svc="$grpc_service_name"
                    if [ -z "$svc" ] || [ "$svc" == "null" ]; then
                        svc=$(_get_proxy_field "$proxy_name_to_find" '.["grpc-opts"]["grpc-service-name"]')
                    fi
                    [ -z "$svc" ] || [ "$svc" == "null" ] && svc="grpc"
                    local skip_verify=$(_get_proxy_field "$proxy_name_to_find" '.["skip-cert-verify"]')
                    local insecure_param=""
                    if [[ "$skip_verify" == "true" ]]; then
                        insecure_param="&insecure=1"
                        local cert_pcs=$(_cert_sha256_hex "$cert_path")
                        [ -n "$cert_pcs" ] && insecure_param="${insecure_param}&pcs=${cert_pcs}"
                    fi
                    url="vless://${uuid}@${link_ip}:${port}?security=tls&encryption=none&type=grpc&serviceName=$(_url_encode "$svc")&sni=${sn}${insecure_param}#$(_url_encode "$display_name")"
                elif [ "$tls_enabled" == "true" ]; then
                    local sn="$tls_sn"
                    url="vless://${uuid}@${link_ip}:${port}?security=tls&encryption=none&type=tcp&sni=${sn}#$(_url_encode "$display_name")"
                else
                    url="vless://${uuid}@${link_ip}:${port}?encryption=none&type=tcp#$(_url_encode "$display_name")"
                fi
                ;;
            "trojan")
                # [资源优化] 合并3次jq为1次
                local _trojan_fields
                _trojan_fields=$(echo "$node" | jq -r '[.users[0].password, (.transport.type // ""), (.transport.path // "")] | @tsv')
                local password transport_type ws_path
                IFS=$'\t' read -r password transport_type ws_path <<< "$_trojan_fields"
                
                if [ "$transport_type" == "ws" ]; then
                    local sn=$(_get_proxy_field "$proxy_name_to_find" ".sni")
                    url="trojan://${password}@${link_ip}:${port}?security=tls&type=ws&host=${sn}&path=$(_url_encode "$ws_path")&sni=${sn}#$(_url_encode "$display_name")"
                    
                    # Argo 节点元数据已迁移到 argo_metadata.json
                    local argo_domain=""
                    if [[ "$tag" == argo-* ]] && [ -f "$ARGO_METADATA_FILE" ]; then
                        argo_domain=$(jq -r --arg t "$tag" '.[$t].domain // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
                    fi
                    if [ -n "$argo_domain" ] && [ "$argo_domain" != "null" ]; then
                        local argo_ws_path=$(_ws_path_with_early_data "$ws_path")
                        url="trojan://${password}@${argo_domain}:443?security=tls&type=ws&host=${argo_domain}&path=$(_url_encode "$argo_ws_path")&sni=${argo_domain}#$(_url_encode "$display_name")"
                    fi
                else
                    local sn=$(_get_proxy_field "$proxy_name_to_find" ".sni")
                    url="trojan://${password}@${link_ip}:${port}?security=tls&type=tcp&sni=${sn}#$(_url_encode "$display_name")"
                fi
                ;;
            "hysteria2")
                local pw=$(echo "$node" | jq -r '.users[0].password')
                local sn="$tls_sn"
                [ -z "$sn" ] || [ "$sn" == "null" ] && sn=$(_get_proxy_field "$proxy_name_to_find" ".sni")
                # [修复] 放弃对混合类型元数据使用 @tsv，避免损坏
                local op=$(jq -r --arg t "$tag" '.[$t].obfsPassword // empty' "$METADATA_FILE")
                local hop=$(jq -r --arg t "$tag" '.[$t].portHopping // empty' "$METADATA_FILE")
                local obfs_param=""; [[ -n "$op" && "$op" != "null" ]] && obfs_param="&obfs=salamander&obfs-password=$(_url_encode "${op}")"
                # 端口跳跃参数
                local hop_param=""; [[ -n "$hop" && "$hop" != "null" ]] && hop_param="&mport=${hop}&ports=${hop}"
                url="hysteria2://${pw}@${link_ip}:${port}?sni=${sn}&insecure=1${obfs_param}${hop_param}#$(_url_encode "$display_name")"
                ;;
            "tuic")
                # [资源优化] 合并2次jq为1次
                local uuid pw
                IFS=$'\t' read -r uuid pw <<< "$(echo "$node" | jq -r '[.users[0].uuid, .users[0].password] | @tsv')"
                local sn=$(_get_proxy_field "$proxy_name_to_find" ".sni")
                url="tuic://${uuid}:${pw}@${link_ip}:${port}?sni=${sn}&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#$(_url_encode "$display_name")"
                ;;
            "anytls")
                # [资源优化] 合并2次jq为1次
                local pw sn
                # [加固] 允许 server_name 回溯
                IFS=$'\t' read -r pw sn <<< "$(echo "$node" | jq -r '[.users[0].password, (.tls.server_name // "www.amd.com")] | @tsv')"
                local skip_verify=$(_get_proxy_field "$proxy_name_to_find" ".skip-cert-verify")
                local insecure_param=""
                if [ "$skip_verify" == "true" ]; then
                    insecure_param="&insecure=1"
                fi
                url="anytls://$(_url_encode "$pw")@${link_ip}:${port}/?sni=$(_url_encode "$sn")${insecure_param}#$(_url_encode "$display_name")"
                ;;
            "shadowsocks")
                # [资源优化] 合并2次jq为1次
                local method password
                IFS=$'\t' read -r method password <<< "$(echo "$node" | jq -r '[.method, .password] | @tsv')"
                url="ss://$(_url_encode "${method}:${password}")@${link_ip}:${port}#$(_url_encode "$display_name")"
                ;;
            "socks")
                # [资源优化] 合并2次jq为1次
                local u p
                IFS=$'\t' read -r u p <<< "$(echo "$node" | jq -r '[.users[0].username, .users[0].password] | @tsv')"
                _info "  类型: SOCKS5, 地址: $display_server, 端口: $port, 用户: $u, 密码: $p"
                ;;
        esac
        fi
        [ -n "$url" ] && echo -e "  ${YELLOW}分享链接:${NC} ${url}"
        # 收集链接到临时文件
        [ -n "$url" ] && echo "$url" >> /tmp/singbox_links.tmp
    done
    echo "-------------------------------------"
    
    # 生成聚合 Base64 选项
    if [ -f /tmp/singbox_links.tmp ]; then
        echo ""
        read -p "是否生成聚合 Base64 订阅? (y/N): " gen_base64
        if [[ "$gen_base64" == "y" || "$gen_base64" == "Y" ]]; then
            echo ""
            _info "=== 聚合 Base64 订阅 ==="
            local base64_result=$(cat /tmp/singbox_links.tmp | base64 | tr -d '\n')
            echo -e "${CYAN}${base64_result}${NC}"
            echo ""
            _success "可直接复制上方内容导入 v2rayN 等客户端"
        fi
        rm -f /tmp/singbox_links.tmp
    fi
}

_delete_node() {
    if ! jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then _warning "当前没有任何节点。"; return; fi
    _info "--- 节点删除 ---"
    
    # --- [!] 新的列表逻辑 ---
    # 我们需要先构建一个数组，来映射用户输入和节点信息
    local inbound_tags=()
    local inbound_ports=()
    local inbound_public_ports=()
    local inbound_types=()
    local display_names=() # 存储显示名称
    local i=1
    # [资源优化] 一次性提取 tag/type/port，避免循环内多次 fork jq
    while IFS=$'\t' read -r tag type port; do
        
        # [!] 过滤辅助节点
        if [[ "$tag" == *"-hop-"* ]]; then continue; fi
        
        local public_port
        public_port=$(jq -r --arg t "$tag" --argjson fallback "$port" '.[$t].publicPort // $fallback' "$METADATA_FILE" 2>/dev/null)
        [ -n "$public_port" ] && [ "$public_port" != "null" ] || public_port="$port"

        # 存储信息
        inbound_tags+=("$tag")
        inbound_ports+=("$port")
        inbound_public_ports+=("$public_port")
        inbound_types+=("$type")

        # 使用 utils.sh 中的统一查找函数
        local proxy_name_to_find=$(_find_proxy_name "$public_port" "$type" "$tag")
        
        local meta_name=$(jq -r --arg t "$tag" '.[$t].name // empty' "$METADATA_FILE" 2>/dev/null)
        local display_name=${proxy_name_to_find:-${meta_name:-$tag}} # 回退到 metadata/tag
        display_names+=("$display_name") # 存储显示名称
        
        # [!] 已修改：显示自定义名称、类型和端口
        if [ "$public_port" != "$port" ]; then
            echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}) @ 公网 ${public_port} -> 回环 ${port}"
        else
            echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}) @ ${port}"
        fi
        ((i++))
    done < <(jq -r '.inbounds[] | [.tag, .type, (.listen_port|tostring)] | @tsv' "$CONFIG_FILE")
    # --- 列表逻辑结束 ---
    
    # 添加删除所有选项
    local count=${#inbound_tags[@]}
    echo ""
    echo -e "  ${RED}99)${NC} 删除所有节点"

    read -p "请输入要删除的节点编号 (输入 0 返回): " num
    
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -eq 0 ] && return
    
    # 处理删除所有节点
    if [ "$num" -eq 99 ]; then
        read -p "$(echo -e ${RED}"确定要删除所有节点吗? 此操作不可恢复! (输入 yes 确认): "${NC})" confirm_all
        if [ "$confirm_all" != "yes" ]; then
            _info "删除已取消。"
            return
        fi
        
        _info "正在删除所有节点..."

        local router_reality_tag
        router_reality_tag=$(jq -r 'to_entries[] | select(.value.frontedBy == "haproxy" and .value.routerRole == "reality-default") | .key' "$METADATA_FILE" 2>/dev/null | head -n 1)
        if [ -n "$router_reality_tag" ]; then
            _sni_router_remove_reality "$router_reality_tag" || {
                _error "无法注销 HAProxy Reality 后端，已取消删除所有节点。"
                return 1
            }
        fi
        local router_tls_tag
        while IFS= read -r router_tls_tag; do
            [ -n "$router_tls_tag" ] || continue
            _sni_router_remove_tls "$router_tls_tag" || {
                _error "无法注销 HAProxy TLS 后端 ${router_tls_tag}，已取消删除所有节点。"
                return 1
            }
        done < <(jq -r 'to_entries[] | select(.value.frontedBy == "haproxy" and .value.routerRole == "tls-sni") | .key' "$METADATA_FILE" 2>/dev/null)
        
        # [安全性加固] 精准分离并销毁仅关联本脚本的 nftables 跳跃端口规则（必须在清空 metadata 之前执行！）
        if [ -f "$METADATA_FILE" ]; then
            jq -r 'to_entries | .[] | select(.value.portHopping) | "\(.key)|\(.value.portHopping)|\(.value.portHoppingMode // \"\")"' "$METADATA_FILE" 2>/dev/null | while IFS="|" read -r ptag hop hop_mode; do
                local psuffix=$(echo "$ptag" | grep -oE "[0-9]+$")
                local hstart="${hop%-*}"
                local hend="${hop#*-}"
                if [ -z "$hop_mode" ]; then
                    if jq -e --arg prefix "${ptag}-hop-" '.inbounds[] | select(.tag | startswith($prefix))' "$CONFIG_FILE" >/dev/null 2>&1; then
                        hop_mode="native"
                    else
                        hop_mode="nftables"
                    fi
                fi
                if [ "$hop_mode" = "nftables" ]; then
                    _nft_apply_redirect_rule delete "$hstart" "$hend" "$psuffix" "singboxlite-hy2-hop-${ptag}"
                fi
            done
            _save_nftables_rules 2>/dev/null
        fi
        
        # 清空配置
        _atomic_modify_json "$CONFIG_FILE" '.inbounds = []'
        _atomic_modify_json "$METADATA_FILE" '{}'
        
        # 清空 clash.yaml 中的代理
        _atomic_modify_yaml "$CLASH_YAML_FILE" '.proxies = []'
        _atomic_modify_yaml "$CLASH_YAML_FILE" '.proxy-groups[] |= (select(.name == "节点选择") | .proxies = ["DIRECT"])'
        
        # 删除所有证书文件
        rm -f ${SINGBOX_DIR}/*.pem ${SINGBOX_DIR}/*.key 2>/dev/null
        
        _success "所有节点已删除！"
        _manage_service "restart"
        return
    fi
    
    # [!] 已修改：现在 count 会在循环外被正确计算
    if [ "$num" -gt "$count" ]; then _error "编号超出范围。"; return; fi

    local index=$((num - 1))
    # [!] 已修改：从数组中获取正确的信息
    local tag_to_del=${inbound_tags[$index]}
    local type_to_del=${inbound_types[$index]}
    local port_to_del=${inbound_ports[$index]}
    local public_port_to_del=${inbound_public_ports[$index]}
    local display_name_to_del=${display_names[$index]}

    # --- [!] 新的删除逻辑 ---
    # 使用统一查找函数确定 clash.yaml 中的确切名称
    local proxy_name_to_del=$(_find_proxy_name "$public_port_to_del" "$type_to_del" "$tag_to_del")

    # [!] 已修改：使用显示名称进行确认
    read -p "$(echo -e ${YELLOW}"确定要删除节点 ${display_name_to_del} 吗? (y/N): "${NC})" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        _info "删除已取消。"
        return
    fi
    
    # === 关键修复：必须先读取 metadata 判断节点类型，再删除！===
    local node_metadata=$(jq -r --arg tag "$tag_to_del" '.[$tag] // empty' "$METADATA_FILE" 2>/dev/null)
    local node_type=""
    if [ -n "$node_metadata" ]; then
        node_type=$(echo "$node_metadata" | jq -r '.type // empty')
    fi

    local router_backed=false router_sni="" router_backend="" router_role=""
    if [ -n "$node_metadata" ] && [ "$(echo "$node_metadata" | jq -r '.frontedBy // empty')" = "haproxy" ]; then
        router_backed=true
        router_role=$(echo "$node_metadata" | jq -r '.routerRole // empty')
        router_sni=$(echo "$node_metadata" | jq -r '.server_name // empty')
        [ -n "$router_sni" ] || router_sni=$(jq -r --arg tag "$tag_to_del" '.inbounds[] | select(.tag == $tag) | .tls.server_name // empty' "$CONFIG_FILE")
        router_backend=$(echo "$node_metadata" | jq -r '.backendPort // empty')
        if [ "$router_role" = "tls-sni" ]; then
            _sni_router_remove_tls "$tag_to_del"
        else
            _sni_router_remove_reality "$tag_to_del"
        fi || {
            _error "无法注销 HAProxy 后端，节点未删除。"
            return 1
        }
    fi
    
    # [!] 重要修正：不使用索引删除（因为列表已过滤），改为使用 Tag 精确匹配删除
    if ! _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag_to_del\"))"; then
        if [ "$router_backed" = true ]; then
            if [ "$router_role" = "tls-sni" ]; then
                _sni_router_register_tls sb "$tag_to_del" "$router_sni" "$router_backend" >/dev/null 2>&1 || true
            else
                _sni_router_register_reality sb "$tag_to_del" "$router_sni" "$router_backend" >/dev/null 2>&1 || true
            fi
        fi
        return
    fi
    
    # [!] 新增：精准剥离该节点绑定的系统级防火墙端口跳跃策略
    local port_hopping=$(echo "$node_metadata" | jq -r '.portHopping // empty' 2>/dev/null)
    local port_hopping_mode=$(echo "$node_metadata" | jq -r '.portHoppingMode // empty' 2>/dev/null)
    if [ -n "$port_hopping" ]; then
        if [ -z "$port_hopping_mode" ]; then
            if jq -e --arg prefix "${tag_to_del}-hop-" '.inbounds[] | select(.tag | startswith($prefix))' "$CONFIG_FILE" >/dev/null 2>&1; then
                port_hopping_mode="native"
            else
                port_hopping_mode="nftables"
            fi
        fi
        local hop_start="${port_hopping%-*}"
        local hop_end="${port_hopping#*-}"
        if [ "$port_hopping_mode" = "nftables" ]; then
            _nft_apply_redirect_rule delete "$hop_start" "$hop_end" "$port_to_del" "singboxlite-hy2-hop-${tag_to_del}"
            _save_nftables_rules 2>/dev/null
            _info "已卸载关联的底层 nftables UDP 端口映射策略 (${port_hopping})"
        fi
    fi
    # [!] 级联清理：同时删除 JSON Fallback 模式可能生成的辅助跳跃子 inbounds (格式: tag-hop-xxx)
    _atomic_modify_json "$CONFIG_FILE" ".inbounds |= map(select(.tag | startswith(\"$tag_to_del-hop-\") | not))" 2>/dev/null
    
    _atomic_modify_json "$METADATA_FILE" "del(.\"$tag_to_del\")" || return
    
    # [!] 已修改：使用找到的 proxy_name_to_del 从 clash.yaml 中删除
    if [ -n "$proxy_name_to_del" ]; then
        _remove_node_from_yaml "$proxy_name_to_del"
    fi

    # 证书清理逻辑 - 包含 hysteria2, tuic, anytls (基于 tag)
    if [ "$type_to_del" == "hysteria2" ] || [ "$type_to_del" == "tuic" ] || [ "$type_to_del" == "anytls" ]; then
        local cert_to_del="${SINGBOX_DIR}/${tag_to_del}.pem"
        local key_to_del="${SINGBOX_DIR}/${tag_to_del}.key"
        if [ -f "$cert_to_del" ] || [ -f "$key_to_del" ]; then
            _info "正在删除节点关联的证书文件: ${cert_to_del}, ${key_to_del}"
            rm -f "$cert_to_del" "$key_to_del"
        fi
    fi
    
    # === 根据之前读取的节点类型清理相关配置 ===
    if [ "$node_type" == "third-party-adapter" ]; then
        # === 第三方适配层：删除 outbound 和 route ===
        _info "检测到第三方适配层，正在清理关联配置..."
        
        # 先查找对应的 outbound (必须在删除 route 之前)
        local outbound_tag=$(jq -r --arg inbound "$tag_to_del" '.route.rules[] | select(.inbound == $inbound) | .outbound' "$CONFIG_FILE" 2>/dev/null | head -n 1)
        
        # 删除 route 规则
        _atomic_modify_json "$CONFIG_FILE" "del(.route.rules[] | select(.inbound == \"$tag_to_del\"))" || true
        
        # 删除对应的 outbound
        if [ -n "$outbound_tag" ] && [ "$outbound_tag" != "null" ]; then
            _atomic_modify_json "$CONFIG_FILE" "del(.outbounds[] | select(.tag == \"$outbound_tag\"))" || true
            _info "已删除关联的 outbound: $outbound_tag"
        fi
    else
        # === 普通节点：只有 inbound，没有额外的 outbound 和 route ===
        # 主脚本创建的节点通常只包含 inbound，outbound 是全局的（如 direct）
        # 如果有特殊的 outbound（如某些协议的专用配置），也要删除
        
        # 检查是否有基于此 inbound 的 route 规则（通常不应该有，但为了清理干净）
        local has_route=$(jq -e ".route.rules[]? | select(.inbound == \"$tag_to_del\")" "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$has_route" ]; then
            _info "检测到关联的路由规则，正在清理..."
            _atomic_modify_json "$CONFIG_FILE" "del(.route.rules[] | select(.inbound == \"$tag_to_del\"))" || true
        fi
        
        # 注意：不删除任何 outbound，因为普通节点的 outbound 通常是共享的全局 outbound
        # （如 "direct"），删除会影响其他节点
    fi
    # === 清理逻辑结束 ===
    
    _success "节点 ${display_name_to_del} 已删除！"
    _manage_service "restart"
}

_check_config() {
    _info "正在检查 sing-box 配置文件..."
    # 捕获所有输出（包括 stderr 产生的大量 WARN 和 TRACE 弃用警告）
    local result
    result=$("${SINGBOX_BIN}" check -c "${CONFIG_FILE}" -c "${SINGBOX_DIR}/relay.json" 2>&1)
    if [[ $? -eq 0 ]]; then
        _success "主配置与中转配置合并校验通过。"
    else
        _error "配置文件检查失败:"
        echo "$result"
    fi
}

_apply_dns_config() {
    local dns_address="$1"
    local dns_strategy="$2"
    local tmp_file="${CONFIG_FILE}.dns.tmp.$$"
    local backup_file="${CONFIG_FILE}.bak_dns_$(date +%Y%m%d_%H%M%S)"
    local check_result dns_json

    dns_json=$(_build_dns_config "$dns_address" "$dns_strategy") || {
        _error "DNS 地址格式无效，仅支持 local、IP 或 udp/tcp/tls/https URL。"
        return 1
    }
    if ! jq --argjson dns "$dns_json" '
        .dns = $dns
        | .route = (.route // {rules:[],final:"direct"})
        | .route.default_domain_resolver = "dns-main"
        | del(.route.auto_detect_interface)
    ' "$CONFIG_FILE" > "$tmp_file"; then
        _error "生成 DNS 配置失败。"
        rm -f "$tmp_file"
        return 1
    fi

    check_result=$(${SINGBOX_BIN} check -c "$tmp_file" 2>&1)
    if [ $? -ne 0 ]; then
        _error "新的 DNS 配置未通过 sing-box 校验，原配置未修改："
        echo "$check_result"
        rm -f "$tmp_file"
        return 1
    fi

    if ! cp "$CONFIG_FILE" "$backup_file" || ! mv "$tmp_file" "$CONFIG_FILE"; then
        _error "保存 DNS 配置失败。"
        rm -f "$tmp_file"
        return 1
    fi

    _success "DNS 配置已保存，备份文件：${backup_file}"
    _manage_service "restart"
}

_dns_config_menu() {
    local current_address current_strategy choice dns_address dns_strategy

    while true; do
        current_address=$(_dns_current_address)
        current_strategy=$(jq -r '.dns.strategy // "prefer_ipv4"' "$CONFIG_FILE" 2>/dev/null)
        [ -z "$current_address" ] || [ "$current_address" = "null" ] && current_address="未设置"
        [ -z "$current_strategy" ] || [ "$current_strategy" = "null" ] && current_strategy="prefer_ipv4"

        clear
        echo -e "${CYAN}"
        echo "  ╔═══════════════════════════════════════╗"
        echo "  ║          sing-box DNS 设置            ║"
        echo "  ╚═══════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  当前 DNS:  ${GREEN}${current_address}${NC}"
        echo -e "  当前策略:  ${GREEN}${current_strategy}${NC}"
        echo ""
        echo -e "    ${GREEN}[1]${NC} 系统 DNS（local）"
        echo -e "    ${GREEN}[2]${NC} 阿里 DNS（DoH）"
        echo -e "    ${GREEN}[3]${NC} 腾讯 DNSPod（DoH）"
        echo -e "    ${GREEN}[4]${NC} Cloudflare（DoH）"
        echo -e "    ${GREEN}[5]${NC} Google（DoH）"
        echo -e "    ${GREEN}[6]${NC} 自定义 DNS 地址"
        echo -e "    ${GREEN}[7]${NC} 修改域名解析策略"
        echo -e "    ${GREEN}[8]${NC} 查看完整 DNS 配置"
        echo ""
        echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
        echo ""
        read -p "  请输入选项 [0-8]: " choice

        dns_address=""
        dns_strategy="$current_strategy"
        case "$choice" in
            1) dns_address="local" ;;
            2) dns_address="https://dns.alidns.com/dns-query" ;;
            3) dns_address="https://doh.pub/dns-query" ;;
            4) dns_address="https://1.1.1.1/dns-query" ;;
            5) dns_address="https://dns.google/dns-query" ;;
            6)
                echo ""
                echo "  支持 local、IP、udp://、tcp://、tls://、https:// 等 sing-box DNS 地址。"
                read -r -p "  请输入 DNS 地址（留空取消）: " dns_address
                [ -z "$dns_address" ] && continue
                if [[ "$dns_address" =~ [[:space:]] ]]; then
                    _error "DNS 地址不能包含空白字符。"
                    read -n 1 -s -r -p "按任意键继续..."
                    continue
                fi
                ;;
            7)
                echo ""
                echo "    1) prefer_ipv4（推荐，IPv4 优先）"
                echo "    2) prefer_ipv6（IPv6 优先）"
                echo "    3) ipv4_only（仅 IPv4）"
                echo "    4) ipv6_only（仅 IPv6）"
                read -p "  请选择解析策略 [1-4]: " strategy_choice
                case "$strategy_choice" in
                    1) dns_strategy="prefer_ipv4" ;;
                    2) dns_strategy="prefer_ipv6" ;;
                    3) dns_strategy="ipv4_only" ;;
                    4) dns_strategy="ipv6_only" ;;
                    *) _error "无效输入。"; read -n 1 -s -r -p "按任意键继续..."; continue ;;
                esac
                dns_address="$current_address"
                if [ "$dns_address" = "未设置" ]; then
                    dns_address="local"
                fi
                ;;
            8)
                echo ""
                jq '.dns' "$CONFIG_FILE" 2>/dev/null || _error "无法读取 DNS 配置。"
                echo ""
                read -n 1 -s -r -p "按任意键继续..."
                continue
                ;;
            0) return ;;
            *) _error "无效输入，请重试。"; read -n 1 -s -r -p "按任意键继续..."; continue ;;
        esac

        echo ""
        _info "准备设置 DNS 为 ${dns_address}，解析策略为 ${dns_strategy}。"
        read -r -p "  确认保存并重启 sing-box？[Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            continue
        fi
        _apply_dns_config "$dns_address" "$dns_strategy"
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

_switch_reality_public_port() {
    local tag="$1" type="$2" actual_port="$3" old_public="$4" new_public="$5"
    local currently_routed=false target_routed=false
    local old_backend="$actual_port" target_port="$new_public" target_listen="::"
    local sni new_tag old_proxy_name new_proxy_name current_link new_link current_name new_name
    local config_backup metadata_backup yaml_backup had_yaml=no

    jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag and .tls.reality.enabled == true)' \
        "$CONFIG_FILE" >/dev/null 2>&1 || return 2
    [ "$(jq -r --arg tag "$tag" '.[$tag].frontedBy // empty' "$METADATA_FILE")" = "haproxy" ] && currently_routed=true
    [ "$new_public" -eq "$SNI_ROUTER_PUBLIC_PORT" ] && target_routed=true
    if [ "$currently_routed" = false ] && [ "$target_routed" = false ]; then return 2; fi
    if [ "$currently_routed" = true ] && [ "$new_public" -eq "$old_public" ]; then
        _warning "新端口与当前公网端口相同，无需修改。"
        return 0
    fi

    sni=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .tls.server_name // empty' "$CONFIG_FILE")
    _is_valid_reality_domain "$sni" || { _error "Reality SNI 无效，无法切换 443 共享模式。"; return 1; }
    if [ "$target_routed" = true ]; then
        _sni_router_prepare || return 1
        local registered_tag
        registered_tag=$(jq -r '.reality.tag // empty' "$SNI_ROUTER_STATE_FILE")
        if [ -n "$registered_tag" ] && [ "$registered_tag" != "$tag" ]; then
            _error "HAProxy 443 已登记 Reality 后端 ${registered_tag}。"
            return 1
        fi
        target_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
        target_listen="127.0.0.1"
    else
        _check_port_conflict "$new_public" tcp && return 1
    fi

    new_tag=$(printf '%s' "$tag" | sed "s/${old_public}/${new_public}/g")
    [ "$new_tag" != "$tag" ] || new_tag="${tag}-public-${new_public}"
    if jq -e --arg tag "$new_tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        _error "目标 Tag 已存在: ${new_tag}"
        return 1
    fi

    config_backup=$(mktemp); metadata_backup=$(mktemp); yaml_backup=$(mktemp) || {
        rm -f "$config_backup" "$metadata_backup" "$yaml_backup"
        return 1
    }
    cp -a -- "$CONFIG_FILE" "$config_backup" || return 1
    cp -a -- "$METADATA_FILE" "$metadata_backup" || return 1
    if [ -f "$CLASH_YAML_FILE" ]; then cp -a -- "$CLASH_YAML_FILE" "$yaml_backup" && had_yaml=yes; fi

    if [ "$currently_routed" = true ]; then
        _sni_router_remove_reality "$tag" || { rm -f "$config_backup" "$metadata_backup" "$yaml_backup"; return 1; }
    fi

    if ! jq --arg tag "$tag" --arg new_tag "$new_tag" --arg listen "$target_listen" --argjson port "$target_port" '
        (.inbounds[] | select(.tag == $tag)) |= (.tag=$new_tag | .listen=$listen | .listen_port=$port)
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" || ! mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; then
        cp -a -- "$config_backup" "$CONFIG_FILE"
        [ "$currently_routed" = true ] && _sni_router_register_reality sb "$tag" "$sni" "$old_backend" >/dev/null 2>&1 || true
        rm -f "$config_backup" "$metadata_backup" "$yaml_backup"
        return 1
    fi

    current_link=$(jq -r --arg tag "$tag" '.[$tag].share_link // empty' "$METADATA_FILE")
    new_link=$(printf '%s' "$current_link" | sed -E "s/(:${old_public})([?&#\/]|$)/:${new_public}\\2/g; s/(-${old_public})([?&#\/]|$)/-${new_public}\\2/g")
    current_name=$(jq -r --arg tag "$tag" '.[$tag].name // empty' "$METADATA_FILE")
    new_name=$(printf '%s' "$current_name" | sed "s/${old_public}/${new_public}/g")
    local routing_filter
    if [ "$target_routed" = true ]; then
        routing_filter='.[$new_tag] += {frontedBy:"haproxy",routerRole:"reality-default"}'
    else
        routing_filter='del(.[$new_tag].frontedBy, .[$new_tag].routerRole)'
    fi
    if ! jq --arg tag "$tag" --arg new_tag "$new_tag" --arg link "$new_link" --arg name "$new_name" \
        --argjson public "$new_public" --argjson backend "$target_port" \
        ".[$new_tag]=.[$tag] | del(.[$tag]) | .[$new_tag].publicPort=\$public | .[$new_tag].backendPort=\$backend | .[$new_tag].share_link=\$link | .[$new_tag].name=\$name | ${routing_filter}" \
        "$METADATA_FILE" > "${METADATA_FILE}.tmp" || ! mv "${METADATA_FILE}.tmp" "$METADATA_FILE"; then
        cp -a -- "$config_backup" "$CONFIG_FILE"
        cp -a -- "$metadata_backup" "$METADATA_FILE"
        [ "$currently_routed" = true ] && _sni_router_register_reality sb "$tag" "$sni" "$old_backend" >/dev/null 2>&1 || true
        rm -f "$config_backup" "$metadata_backup" "$yaml_backup"
        return 1
    fi

    old_proxy_name=$(_find_proxy_name "$old_public" "$type" "$tag")
    if [ -n "$old_proxy_name" ] && [ -f "$CLASH_YAML_FILE" ]; then
        new_proxy_name=$(printf '%s' "$old_proxy_name" | sed "s/${old_public}/${new_public}/g")
        export OLD_NAME="$old_proxy_name" NEW_NAME="$new_proxy_name" NEW_PORT_VAL="$new_public"
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == env(OLD_NAME)) | .name) = env(NEW_NAME) | (.proxies[] | select(.name == env(NEW_NAME)) | .port) = (env(NEW_PORT_VAL)|tonumber) | (.proxy-groups[].proxies[] | select(. == env(OLD_NAME))) = env(NEW_NAME)' || true
    fi

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" >/dev/null 2>&1 || \
       ! _manage_service restart || \
       { [ "$target_routed" = true ] && ! _sni_router_register_reality sb "$new_tag" "$sni" "$target_port"; }; then
        _error "端口模式切换失败，正在恢复。"
        cp -a -- "$config_backup" "$CONFIG_FILE"
        cp -a -- "$metadata_backup" "$METADATA_FILE"
        [ "$had_yaml" = yes ] && cp -a -- "$yaml_backup" "$CLASH_YAML_FILE"
        _sni_router_remove_reality "$new_tag" >/dev/null 2>&1 || true
        [ "$currently_routed" = true ] && _sni_router_register_reality sb "$tag" "$sni" "$old_backend" >/dev/null 2>&1 || true
        _manage_service restart >/dev/null 2>&1 || true
        rm -f "$config_backup" "$metadata_backup" "$yaml_backup"
        return 1
    fi
    rm -f "$config_backup" "$metadata_backup" "$yaml_backup"
    _success "Reality 公网端口已切换: ${old_public} -> ${new_public}（实际监听 ${target_listen}:${target_port}）"
    return 0
}

_modify_port() {
    if ! jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warning "当前没有任何节点。"
        return
    fi
    
    _info "--- 修改节点端口 ---"
    
    # 列出所有节点
    local inbound_tags=()
    local inbound_ports=()
    local inbound_public_ports=()
    local inbound_types=()
    local display_names=()
    
    local i=1
    # [资源优化] 合并3次jq为1次 + 使用公共函数 _find_proxy_name 替代内联查找
    while IFS=$'\t' read -r tag type port; do
        # [!] 过滤辅助跳跃子节点（与 _view_nodes / _delete_node 保持一致）
        if [[ "$tag" == *"-hop-"* ]]; then continue; fi

        inbound_tags+=("$tag")
        inbound_ports+=("$port")
        inbound_types+=("$type")
        local public_port
        public_port=$(jq -r --arg t "$tag" --argjson fallback "$port" '.[$t].publicPort // $fallback' "$METADATA_FILE" 2>/dev/null)
        [ -n "$public_port" ] && [ "$public_port" != "null" ] || public_port="$port"
        inbound_public_ports+=("$public_port")
        
        # [M1] 使用公共函数替代内联重复的代理名查找逻辑
        local proxy_name_to_find=$(_find_proxy_name "$public_port" "$type" "$tag")
        
        local meta_name=$(jq -r --arg t "$tag" '.[$t].name // empty' "$METADATA_FILE" 2>/dev/null)
        local display_name=${proxy_name_to_find:-${meta_name:-$tag}}
        display_names+=("$display_name")
        
        if [ "$public_port" != "$port" ]; then
            echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}) @ ${GREEN}公网 ${public_port} -> 回环 ${port}${NC}"
        else
            echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}) @ ${GREEN}${port}${NC}"
        fi
        ((i++))
    done < <(jq -r '.inbounds[] | [.tag, .type, (.listen_port|tostring)] | @tsv' "$CONFIG_FILE")
    
    read -p "请输入要修改端口的节点编号 (输入 0 返回): " num
    
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -eq 0 ] && return
    
    local count=${#inbound_tags[@]}
    if [ "$num" -gt "$count" ]; then
        _error "编号超出范围。"
        return
    fi
    
    local index=$((num - 1))
    local tag_to_modify=${inbound_tags[$index]}
    local type_to_modify=${inbound_types[$index]}
    local old_port=${inbound_ports[$index]}
    local old_public_port=${inbound_public_ports[$index]}
    local display_name_to_modify=${display_names[$index]}
    local hop_info=""
    local hop_mode=""
    local hop_range_input=""
    local final_hop_info=""
    local final_hop_start=""
    local final_hop_end=""
    
    _info "当前节点: ${display_name_to_modify} (${type_to_modify})"
    _info "当前公网端口: ${old_public_port}"
    [ "$old_public_port" = "$old_port" ] || _info "当前回环后端端口: ${old_port}"
    
    if [ "$type_to_modify" = "hysteria2" ] && [ -f "$METADATA_FILE" ] && jq -e ".\"$tag_to_modify\"" "$METADATA_FILE" >/dev/null 2>&1; then
        hop_info=$(jq -r ".\"$tag_to_modify\".portHopping // \"\"" "$METADATA_FILE" 2>/dev/null)
        hop_mode=$(jq -r ".\"$tag_to_modify\".portHoppingMode // \"\"" "$METADATA_FILE" 2>/dev/null)
        if [ -n "$hop_info" ] && [ -z "$hop_mode" ]; then
            if jq -e --arg prefix "${tag_to_modify}-hop-" '.inbounds[] | select(.tag | startswith($prefix))' "$CONFIG_FILE" >/dev/null 2>&1; then
                hop_mode="native"
            else
                hop_mode="nftables"
            fi
        fi
    fi
    
    read -p "请输入新的端口号: " new_port
    
    # 验证端口
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        _error "无效的端口号！"
        return
    fi
    
    if [ "$new_port" -eq "$old_public_port" ]; then
        _warning "新端口与当前端口相同，无需修改。"
        return
    fi

    if [ "$(jq -r --arg tag "$tag_to_modify" '.[$tag].routerRole // empty' "$METADATA_FILE" 2>/dev/null)" = "tls-sni" ]; then
        _error "HAProxy 443 复用模式下的普通 AnyTLS 暂不支持直接修改端口，请删除后重新创建。"
        return 1
    fi

    _switch_reality_public_port "$tag_to_modify" "$type_to_modify" "$old_port" "$old_public_port" "$new_port"
    local router_switch_status=$?
    if [ "$router_switch_status" -ne 2 ]; then
        return "$router_switch_status"
    fi
    
    # 检查端口是否已被占用
    if jq -e --arg tag "$tag_to_modify" --argjson port "$new_port" '.inbounds[] | select(.listen_port == $port and .tag != $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        _error "端口 $new_port 已被其他节点使用！"
        return
    fi

    if [[ "$type_to_modify" == "hysteria2" || "$type_to_modify" == "tuic" ]]; then
        local new_port_hop_conflict
        new_port_hop_conflict=$(_find_udp_hop_conflict_in_range "$new_port" "$new_port" "$tag_to_modify")
        if [ -n "$new_port_hop_conflict" ]; then
            local c_tag c_name c_range c_mode
            IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$new_port_hop_conflict"
            _error "新端口 ${new_port} 落在已有 HY2 端口跳跃范围 ${c_range} 内。"
            _error "冲突节点: ${c_name} (${c_tag}, ${c_mode})。请换端口。"
            return
        fi
    fi
    
    if [ -n "$hop_info" ]; then
        _info "检测到当前 HY2 节点启用了端口跳跃 (${hop_mode:-unknown}): ${hop_info}"
        read -p "请输入新的端口跳跃范围（直接回车保留原范围，输入 none 关闭）: " hop_range_input
        if [ -z "$hop_range_input" ]; then
            final_hop_info="$hop_info"
        elif [ "$hop_range_input" = "none" ]; then
            final_hop_info=""
        else
            if [[ ! "$hop_range_input" =~ ^[0-9]+-[0-9]+$ ]]; then
                _error "端口跳跃范围格式无效，应为 start-end。"
                return
            fi
            final_hop_start="${hop_range_input%-*}"
            final_hop_end="${hop_range_input#*-}"
            if [ "$final_hop_start" -lt 1 ] || [ "$final_hop_end" -gt 65535 ] || [ "$final_hop_start" -gt "$final_hop_end" ]; then
                _error "端口跳跃范围无效。"
                return
            fi
            local pf_conflict
            pf_conflict=$(_find_pf_udp_conflict_in_range "$final_hop_start" "$final_hop_end")
            if [ -n "$pf_conflict" ]; then
                local c_port c_name c_net c_target
                IFS=$'\t' read -r c_port c_name c_net c_target <<< "$pf_conflict"
                _error "端口跳跃范围 ${hop_range_input} 覆盖了已有 ${c_net} 端口转发入口 ${c_port}（${c_name} -> ${c_target}）。"
                _error "请调整跳跃范围或先删除/修改该端口转发规则。"
                return
            fi
            local hop_conflict
            hop_conflict=$(_find_udp_hop_conflict_in_range "$final_hop_start" "$final_hop_end" "$tag_to_modify")
            if [ -n "$hop_conflict" ]; then
                local c_tag c_name c_range c_mode
                IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$hop_conflict"
                _error "端口跳跃范围 ${hop_range_input} 与已有跳跃范围 ${c_range} 重叠。"
                _error "冲突节点: ${c_name} (${c_tag}, ${c_mode})。请调整跳跃范围。"
                return
            fi
            final_hop_info="$hop_range_input"
        fi
    fi
    
    if [ -n "$final_hop_info" ]; then
        final_hop_start="${final_hop_info%-*}"
        final_hop_end="${final_hop_info#*-}"
    fi
    
    _info "正在修改端口: ${old_port} -> ${new_port}"
    
    # 1. 修改 config.json 主节点端口（按 tag 精确匹配，避免过滤 hop 子节点后索引错位）
    _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag_to_modify\") | .listen_port) = $new_port" || return
    
    # 2. 修改 clash.yaml (全链路同步模式)
    local old_proxy_name=$(_find_proxy_name "$old_port" "$type_to_modify" "$tag_to_modify")
    if [ -n "$old_proxy_name" ]; then
        # 生成新名字：将名字中的旧端口替换为新端口
        local new_proxy_name=$(echo "$old_proxy_name" | sed "s/${old_port}/${new_port}/g")
        
        export OLD_NAME="$old_proxy_name"
        export NEW_NAME="$new_proxy_name"
        export NEW_PORT_VAL="$new_port"
        
        # 原子改名与改端口
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == env(OLD_NAME)) | .name) = env(NEW_NAME)'
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == env(NEW_NAME)) | .port) = (env(NEW_PORT_VAL)|tonumber)'
        
        # 全局同步更新所有分组中的引用
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxy-groups[].proxies[] | select(. == env(OLD_NAME))) = env(NEW_NAME)'
        
        if [ -n "$final_hop_info" ]; then
            export NEW_PORTS_VAL="$final_hop_info"
            _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == env(NEW_NAME)) | .ports) = env(NEW_PORTS_VAL)'
        elif [ -n "$hop_info" ]; then
            _atomic_modify_yaml "$CLASH_YAML_FILE" 'del(.proxies[] | select(.name == env(NEW_NAME)) | .ports)'
        fi
        
        _info "Clash 节点名同步: ${old_proxy_name} -> ${new_proxy_name}"
    fi
    
    # [修复] 3. 全局同步更新 metadata.json 中的链接端口与备注名
    if [ -f "$METADATA_FILE" ]; then
        if jq -e ".\"$tag_to_modify\"" "$METADATA_FILE" >/dev/null 2>&1; then
            # [关键修复] _view_nodes 优先读取的是 .share_link 字段 (非 .link)
            local current_link=$(jq -r ".\"$tag_to_modify\".share_link // \"\"" "$METADATA_FILE")
            if [ -n "$current_link" ]; then
                # 精准替换：仅替换 URL 中端口位置的数字（@IP:PORT? 和 #name-PORT 部分），避免误伤 UUID/密码
                local new_link=$(echo "$current_link" | sed -E "s/(:${old_port})([?&#\/]|$)/:${new_port}\2/g; s/(-${old_port})([?&#\/]|$)/-${new_port}\2/g")
                if [ -n "$hop_info" ]; then
                    if [ -n "$final_hop_info" ]; then
                        # 更新 mport 参数
                        if [[ "$new_link" == *"&mport="* ]] || [[ "$new_link" == *"?mport="* ]]; then
                            new_link=$(echo "$new_link" | sed -E "s/([?&]mport=)[0-9]+-[0-9]+/\1${final_hop_info}/g")
                        else
                            new_link="${new_link}&mport=${final_hop_info}"
                        fi
                        # 更新 ports 参数
                        if [[ "$new_link" == *"&ports="* ]] || [[ "$new_link" == *"?ports="* ]]; then
                            new_link=$(echo "$new_link" | sed -E "s/([?&]ports=)[0-9]+-[0-9]+/\1${final_hop_info}/g")
                        else
                            new_link="${new_link}&ports=${final_hop_info}"
                        fi
                    else
                        new_link=$(echo "$new_link" | sed -E 's/[?&]mport=[0-9]+-[0-9]+//g')
                        new_link=$(echo "$new_link" | sed -E 's/[?&]ports=[0-9]+-[0-9]+//g')
                        new_link=$(echo "$new_link" | sed -E 's/\?&/?/g; s/&$//g; s/\?$//g')
                    fi
                fi
                _atomic_modify_json "$METADATA_FILE" ".\"$tag_to_modify\".share_link = \"$new_link\""
                _info "分享链接已同步更新。"
            fi
            local current_meta_name
            current_meta_name=$(jq -r ".\"$tag_to_modify\".name // \"\"" "$METADATA_FILE")
            if [ -n "$current_meta_name" ]; then
                local new_meta_name
                new_meta_name=$(echo "$current_meta_name" | sed "s/${old_port}/${new_port}/g")
                if [ "$new_meta_name" != "$current_meta_name" ]; then
                    _atomic_modify_json "$METADATA_FILE" ".\"$tag_to_modify\".name = \"$new_meta_name\"" || return
                fi
            fi
            if [ -n "$hop_info" ]; then
                if [ -n "$final_hop_info" ]; then
                    _atomic_modify_json "$METADATA_FILE" ".\"$tag_to_modify\".portHopping = \"$final_hop_info\"" || return
                    if [ -n "$hop_mode" ]; then
                        _atomic_modify_json "$METADATA_FILE" ".\"$tag_to_modify\".portHoppingMode = \"$hop_mode\"" || return
                    fi
                else
                    _atomic_modify_json "$METADATA_FILE" "del(.\"$tag_to_modify\".portHopping, .\"$tag_to_modify\".portHoppingMode)" || return
                fi
            fi
        fi
    fi

    # 4. 通用 tag 重命名（所有含端口的 tag 都可能需要更新）
    local new_tag=$(echo "$tag_to_modify" | sed "s/${old_port}/${new_port}/g")
    if [ "$new_tag" != "$tag_to_modify" ]; then
        # 4a. 处理证书文件重命名（仅 Hysteria2, TUIC, AnyTLS 有独立证书）
        if [ "$type_to_modify" == "hysteria2" ] || [ "$type_to_modify" == "tuic" ] || [ "$type_to_modify" == "anytls" ]; then
            local old_cert="${SINGBOX_DIR}/${tag_to_modify}.pem"
            local old_key="${SINGBOX_DIR}/${tag_to_modify}.key"
            local new_cert="${SINGBOX_DIR}/${new_tag}.pem"
            local new_key="${SINGBOX_DIR}/${new_tag}.key"
            
            if [ -f "$old_cert" ] && [ -f "$old_key" ]; then
                mv "$old_cert" "$new_cert"
                mv "$old_key" "$new_key"
                _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag_to_modify\") | .tls.certificate_path) = \"$new_cert\"" || return
                _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag_to_modify\") | .tls.key_path) = \"$new_key\"" || return
            fi
        fi
        
        # 4b. 更新 config.json 中主节点的 tag
        _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag_to_modify\") | .tag) = \"$new_tag\"" || return
        
        # 4c. 迁移 metadata.json 中的 key (旧tag -> 新tag)
        if [ -f "$METADATA_FILE" ] && jq -e ".\"$tag_to_modify\"" "$METADATA_FILE" >/dev/null 2>&1; then
            local meta_content=$(jq ".\"$tag_to_modify\"" "$METADATA_FILE")
            _atomic_modify_json "$METADATA_FILE" "del(.\"$tag_to_modify\") | . + {\"$new_tag\": $meta_content}" || return
        fi
        
        _info "Tag 同步: ${tag_to_modify} -> ${new_tag}"
    fi
    
    # 5. 联动更新端口跳跃规则
    local final_tag="${new_tag:-$tag_to_modify}"
    if [ -n "$hop_info" ]; then
        if [ "$hop_mode" = "nftables" ]; then
            # [修复] 事务性 nftables 更新：先尝试写入新规则，成功后再持久化，失败则回滚
            local nft_ok="false"
            local old_hop_start="${hop_info%-*}"
            local old_hop_end="${hop_info#*-}"

            if [ -n "$final_hop_info" ]; then
                if [ "$final_tag" != "$tag_to_modify" ]; then
                    _nft_apply_redirect_rule delete "$old_hop_start" "$old_hop_end" "$old_port" "singboxlite-hy2-hop-${tag_to_modify}"
                fi
                if _nft_apply_redirect_rule add "$final_hop_start" "$final_hop_end" "$new_port" "singboxlite-hy2-hop-${final_tag}"; then
                    nft_ok="true"
                    _save_nftables_rules 2>/dev/null
                    _info "已将端口跳跃映射从 ${old_port} 联动更新到 ${new_port}，范围: ${final_hop_info}"
                else
                    _nft_apply_redirect_rule delete "$final_hop_start" "$final_hop_end" "$new_port" "singboxlite-hy2-hop-${final_tag}"
                    _error "端口跳跃 nftables 规则更新失败，旧映射保持不变。端口修改仍会继续，但 HY2 跳跃可能失效，请手动检查 nftables 规则！"
                fi
            else
                # === 无新跳跃范围：仅删除旧规则 ===
                _nft_apply_redirect_rule delete "$old_hop_start" "$old_hop_end" "$old_port" "singboxlite-hy2-hop-${tag_to_modify}"
                _save_nftables_rules 2>/dev/null
                _info "已移除端口跳跃映射。"
            fi
        elif [ "$hop_mode" = "native" ]; then
            _atomic_modify_json "$CONFIG_FILE" ".inbounds |= map(select(.tag | startswith(\"${tag_to_modify}-hop-\") | not))" || return
            if [ -n "$new_tag" ] && [ "$new_tag" != "$tag_to_modify" ]; then
                _atomic_modify_json "$CONFIG_FILE" ".inbounds |= map(select(.tag | startswith(\"${new_tag}-hop-\") | not))" || return
            fi
            if [ -n "$final_hop_info" ]; then
                local cert_path="${SINGBOX_DIR}/${final_tag}.pem"
                local key_path="${SINGBOX_DIR}/${final_tag}.key"
                local hy2_password=$(jq -r --arg t "$final_tag" '.inbounds[] | select(.tag == $t) | .users[0].password // ""' "$CONFIG_FILE")
                local hy2_obfs_password=$(jq -r --arg t "$final_tag" '.inbounds[] | select(.tag == $t) | .obfs.password // ""' "$CONFIG_FILE")
                local batch_array="[]"
                local skipped=0
                local p
                for ((p=final_hop_start; p<=final_hop_end; p++)); do
                    if [ "$p" -eq "$new_port" ]; then continue; fi
                    # 仅检查 config.json 中是否有其他节点占用（排除自身旧 hop 端口在进程中仍占用的误判）
                    if _check_port_in_config "$p"; then ((skipped++)); continue; fi
                    local hop_tag="${final_tag}-hop-${p}"
                    batch_array=$(echo "$batch_array" | jq --arg t "$hop_tag" --arg p "$p" --arg pw "$hy2_password" --arg cert "$cert_path" --arg key "$key_path" --arg op "$hy2_obfs_password" '. += [{"type":"hysteria2","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"password":$pw}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}} | if $op != "" then .obfs={"type":"salamander","password":$op} else . end]')
                done
                if [ "$(echo "$batch_array" | jq 'length')" -gt 0 ]; then
                    _atomic_modify_json "$CONFIG_FILE" ".inbounds += $batch_array" || return
                fi
                _info "已重建原生端口跳跃子节点，范围: ${final_hop_info}"
                if [ "$skipped" -gt 0 ]; then
                    _warning "有 ${skipped} 个跳跃端口因冲突被跳过。"
                fi
            else
                _info "已移除原生端口跳跃子节点。"
            fi
        fi
    fi
    
    _success "端口修改成功: ${old_port} -> ${new_port}"
    _manage_service "restart"
}

# --- 更新管理脚本 ---
_component_sha256() {
    case "$1" in
        advanced_relay.sh) printf '%s' "$ADVANCED_RELAY_SHA256" ;;
        parser.sh) printf '%s' "$PARSER_SHA256" ;;
        *) return 1 ;;
    esac
}

_verify_component_script() {
    local file="$1"
    local script_name="$2"
    local expected actual
    expected=$(_component_sha256 "$script_name") || return 1
    [ -s "$file" ] || return 1
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    [ "$actual" = "$expected" ] || return 1
    bash -n "$file" >/dev/null 2>&1
}

_ensure_component_script() {
    local script_name="$1"
    local script_path="${SINGBOX_DIR}/${script_name}"
    local temp_path="${script_path}.tmp.$$"

    mkdir -p "$SINGBOX_DIR" || return 1
    if _verify_component_script "$script_path" "$script_name"; then
        return 0
    fi

    _info "正在下载并校验组件: ${script_name}..."
    rm -f "$temp_path"
    if ! wget -qO "$temp_path" "${COMPONENT_RAW_BASE}/${script_name}"; then
        _error "组件下载失败: ${script_name}"
        rm -f "$temp_path"
        return 1
    fi
    if ! _verify_component_script "$temp_path" "$script_name"; then
        _error "组件 ${script_name} 的 SHA-256 或 Bash 语法校验失败，已拒绝安装。"
        rm -f "$temp_path"
        return 1
    fi
    chmod 700 "$temp_path" && mv -f "$temp_path" "$script_path"
}

_update_script() {
    _info "--- 更新脚本 ---"
    
    # 更新主脚本。时间戳查询参数用于绕过代理/CDN 的旧文件缓存。
    _info "正在从 GitHub 下载最新版本..."
    local temp_script_path="${SELF_SCRIPT_PATH}.tmp"
    local cache_bust
    local main_script_url
    local downloaded_version
    cache_bust=$(date +%s)
    main_script_url="${SCRIPT_UPDATE_URL}?v=${cache_bust}"
    
    if wget -qO "$temp_script_path" "$main_script_url"; then
        if [ ! -s "$temp_script_path" ]; then
            _error "主脚本下载失败或文件为空！"
            rm -f "$temp_script_path"
            return 1
        fi

        downloaded_version=$(sed -n 's/^export SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$temp_script_path" | head -n 1)
        if [ -z "$downloaded_version" ] || ! head -n 1 "$temp_script_path" | grep -q '^#!/bin/bash'; then
            _error "下载内容不是有效的 sb.sh，已拒绝覆盖本地脚本。"
            rm -f "$temp_script_path"
            return 1
        fi
        if ! bash -n "$temp_script_path" 2>/dev/null; then
            _error "下载的新脚本未通过 Bash 语法检查，已拒绝覆盖本地脚本。"
            rm -f "$temp_script_path"
            return 1
        fi
        
        chmod +x "$temp_script_path"
        mv "$temp_script_path" "$SELF_SCRIPT_PATH"
        _success "主脚本更新成功：v${SCRIPT_VERSION} -> v${downloaded_version}"
    else
        _error "主脚本下载失败！请检查网络或 GitHub 链接。"
        rm -f "$temp_script_path"
        return 1
    fi
    
    # 当前 Bash 进程仍持有旧版本的组件固定值；组件改由新脚本在进入进阶功能时校验。
    _success "主脚本已更新至 v${downloaded_version}。"
    _info "请重新运行脚本应用新版本；进入 [17] 时会自动校验并下载进阶组件："
    echo -e "${YELLOW}bash ${SELF_SCRIPT_PATH}${NC}"
    exit 0
}

# 守卫函数：检查 sing-box 核心是否已安装
_require_singbox() {
    if [ ! -f "${SINGBOX_BIN}" ]; then
        _error "此功能需要先安装 Sing-box 核心。请前往主菜单【核心管理】-> [15] 进行安装。"
        return 1
    fi
    return 0
}

# [安装/更新 Sing-box 核心] — 双模态：未装就装、已装就更新
_install_or_update_singbox() {
    if [ -f "${SINGBOX_BIN}" ]; then
        local current_ver=$(${SINGBOX_BIN} version 2>/dev/null | head -n1 | awk '{print $3}')
        _info "当前 Sing-box 版本: v${current_ver}，正在检查更新..."
    else
        _info "Sing-box 核心未安装，正在执行首次安装..."
    fi
    _do_update_singbox
}

# 执行 sing-box 核心的安装/更新
_do_update_singbox() {
    _info "--- 安装/更新 Sing-box 核心 ---"
    local update_backup_dir=""
    local had_previous_binary=false
    local dns_fix_status=1
    local config_check_output=""

    _install_dependencies true
    mkdir -p "$SINGBOX_DIR" || { _error "无法创建 sing-box 配置目录。"; return 1; }

    if [ -f "$SINGBOX_BIN" ]; then
        update_backup_dir=$(mktemp -d /root/.singbox-update.XXXXXX) || {
            _error "无法创建升级回滚目录，已取消更新。"
            return 1
        }
        if ! cp -a "$SINGBOX_BIN" "${update_backup_dir}/sing-box"; then
            _error "备份当前 sing-box 核心失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        if [ -f "$CONFIG_FILE" ] && ! cp -a "$CONFIG_FILE" "${update_backup_dir}/config.json"; then
            _error "备份主配置失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        if [ -f "${SINGBOX_DIR}/relay.json" ] && ! cp -a "${SINGBOX_DIR}/relay.json" "${update_backup_dir}/relay.json"; then
            _error "备份中转配置失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        if [ -f "$CLASH_YAML_FILE" ] && ! cp -a "$CLASH_YAML_FILE" "${update_backup_dir}/clash.yaml"; then
            _error "备份订阅配置失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        had_previous_binary=true
    fi

    if [ -f "$CONFIG_FILE" ]; then
        if _check_and_fix_dns; then
            dns_fix_status=0
        else
            dns_fix_status=$?
            if [ "$dns_fix_status" -eq 2 ]; then
                _error "DNS 配置无法安全迁移，已取消 sing-box 核心更新。"
                [ -n "$update_backup_dir" ] && rm -rf "$update_backup_dir"
                return 1
            fi
        fi
    fi

    if ! _install_sing_box; then
        _error "Sing-box 核心安装/更新失败。"
    else
        _success "sing-box 安装/更新成功！"
        # 确保配置文件存在
        if [ ! -f "${CONFIG_FILE}" ] || [ ! -f "${CLASH_YAML_FILE}" ]; then
            _info "检测到主配置文件缺失，正在初始化..."
            _initialize_config_files
        fi
        _init_relay_config
        _create_service_files
        _setup_log_cleanup || true

        if config_check_output=$("$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${SINGBOX_DIR}/relay.json" 2>&1); then
            _info "正在启动/重启 [主] 服务 (sing-box)..."
            if _manage_service "restart"; then
                [ -n "$update_backup_dir" ] && rm -rf "$update_backup_dir"
                _success "[主] 服务已就绪。"
                return 0
            fi
            _error "新核心启动失败。"
        else
            _error "新核心安装后的合并配置校验失败："
            printf '%s\n' "$config_check_output" >&2
        fi
    fi

    if [ "$had_previous_binary" = true ] && [ -n "$update_backup_dir" ]; then
        local rollback_ok=true
        _warn "正在回滚到更新前的 sing-box 核心与配置..."
        install -m 700 "${update_backup_dir}/sing-box" "$SINGBOX_BIN" || rollback_ok=false
        if [ -f "${update_backup_dir}/config.json" ]; then
            cp -a "${update_backup_dir}/config.json" "$CONFIG_FILE" || rollback_ok=false
        fi
        if [ -f "${update_backup_dir}/relay.json" ]; then
            cp -a "${update_backup_dir}/relay.json" "${SINGBOX_DIR}/relay.json" || rollback_ok=false
        fi
        if [ -f "${update_backup_dir}/clash.yaml" ]; then
            cp -a "${update_backup_dir}/clash.yaml" "$CLASH_YAML_FILE" || rollback_ok=false
        fi
        if [ "$rollback_ok" = true ] && _manage_service "restart"; then
            _success "已恢复更新前版本，原服务已重新启动。"
        else
            _error "自动回滚未完全成功，请从 ${update_backup_dir} 手动恢复并检查服务日志。"
            return 1
        fi
    fi
    [ -n "$update_backup_dir" ] && rm -rf "$update_backup_dir"
    return 1
}

# --- 进阶功能 (子脚本) ---
_advanced_features() {
    # advanced_relay.sh 会调用 parser.sh；两者都必须来自同仓库并通过固定哈希校验。
    _ensure_component_script "parser.sh" || return 1
    _ensure_component_script "advanced_relay.sh" || return 1
    bash "${SINGBOX_DIR}/advanced_relay.sh"
}

_main_menu() {
    while true; do
        clear
        # ASCII Logo
        echo -e "${CYAN}"
        echo '  ____  _             ____            '
        echo ' / ___|(_)_ __   __ _| __ )  _____  __'
        echo ' \___ \| | '\''_ \ / _` |  _ \ / _ \ \/ /'
        echo '  ___) | | | | | (_| | |_) | (_) >  < '
        echo ' |____/|_|_| |_|\__, |____/ \___/_/\_\'
        echo '                |___/    Lite Manager '
        echo -e "${NC}"
        
        # 版本标题
        echo -e "${CYAN}"
        echo "  ╔═══════════════════════════════════════╗"
        echo "  ║         sing-box 管理脚本 v${SCRIPT_VERSION}         ║"
        echo "  ╚═══════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        
        # 获取系统信息
        local os_info="未知"
        if [ -f /etc/os-release ]; then
            os_info=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
            [ -z "$os_info" ] && os_info=$(grep -E "^NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
        fi
        [ -z "$os_info" ] && os_info=$(uname -s)
        
        # 获取 Sing-box 版本和状态
        local sb_version=""
        local service_status="○ 未知"
        if [ -f "$SINGBOX_BIN" ]; then
            sb_version=" v$($SINGBOX_BIN version 2>/dev/null | head -n1 | awk '{print $3}')"
            if [ "$INIT_SYSTEM" == "systemd" ]; then
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            elif [ "$INIT_SYSTEM" == "openrc" ]; then
                if rc-service sing-box status 2>/dev/null | grep -q "started"; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            elif [ "$INIT_SYSTEM" == "direct" ]; then
                if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            fi
        else
            service_status="${RED}○ 未安装${NC}"
        fi
        
        # 获取 Argo 状态 (修复 Alpine/BusyBox 的 ps 截断问题：优先使用 PID 文件检测)
        local argo_status="${RED}○ 未安装${NC}"
        if [ -f "$CLOUDFLARED_BIN" ]; then
            local argo_running=false
            # 方式1 (精准): 遍历 PID 文件，与守护进程 _argo_keepalive 使用相同的检测方式
            for pid_file in /tmp/singbox_argo_*.pid; do
                [ -f "$pid_file" ] || continue
                local pid=$(cat "$pid_file" 2>/dev/null)
                if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
                    argo_running=true
                    break
                fi
            done
            # 方式2 (兜底): PID 文件不存在时，尝试 pgrep 或 ps 匹配进程名
            if [ "$argo_running" = false ]; then
                if command -v pgrep &>/dev/null; then
                    pgrep -x cloudflared &>/dev/null && argo_running=true
                elif ps w 2>/dev/null | grep -v "grep" | grep -q "cloudflared"; then
                    argo_running=true
                fi
            fi
            if [ "$argo_running" = true ]; then
                argo_status="${GREEN}● 运行中${NC}"
            else
                argo_status="${YELLOW}○ 已安装 (未运行)${NC}"
            fi
        fi
        
        echo -e "  系统: ${CYAN}${os_info}${NC}  |  模式: ${CYAN}${INIT_SYSTEM}${NC}"
        echo -e "  Sing-box${CYAN}${sb_version}${NC}: ${service_status}  |  Argo: ${argo_status}"
        echo ""
        
        # 节点管理
        echo -e "  ${CYAN}【节点管理】${NC}"
        echo -e "    ${GREEN}[1]${NC} 添加节点          ${GREEN}[2]${NC} Argo 隧道节点"
        echo -e "    ${GREEN}[3]${NC} 查看节点链接      ${GREEN}[4]${NC} 删除节点"
        echo -e "    ${GREEN}[5]${NC} 修改节点端口"
        echo ""
        
        # 服务控制
        echo -e "  ${CYAN}【服务控制】${NC}"
        echo -e "    ${GREEN}[6]${NC} 重启服务          ${GREEN}[7]${NC} 停止服务"
        echo -e "    ${GREEN}[8]${NC} 查看运行状态      ${GREEN}[9]${NC} 查看实时日志"
        echo -e "    ${GREEN}[10]${NC} 定时重启设置"
        echo -e "    ${GREEN}[11]${NC} 同步系统时间"
        echo ""
        
        # 配置与更新
        echo -e "  ${CYAN}【配置与更新】${NC}"
        echo -e "    ${GREEN}[12]${NC} 检查配置文件    ${GREEN}[13]${NC} 更新脚本"
        echo -e "    ${GREEN}[14]${NC} DNS 设置"
        echo ""
        
        # 核心管理
        echo -e "  ${CYAN}【核心管理】${NC}"
        echo -e "    ${GREEN}[15]${NC} 安装/更新 Sing-box 核心"
        echo -e "    ${RED}[16]${NC} 卸载脚本"
        echo ""
        
        # 进阶功能
        echo -e "  ${CYAN}【进阶功能】${NC}"
        echo -e "    ${GREEN}[17]${NC} 落地/中转/第三方节点导入"
        echo ""
        
        echo -e "  ─────────────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC} 退出脚本"
        echo ""
        
        read -p "  请输入选项 [0-17]: " choice
 
        case $choice in
            1) _require_singbox && _show_add_node_menu ;;
            2) _require_singbox && _argo_menu ;;
            3) _require_singbox && _view_nodes ;;
            4) _require_singbox && _delete_node ;;
            5) _require_singbox && _modify_port ;;
            6) _require_singbox && _manage_service "restart" ;;
            7) _require_singbox && _manage_service "stop" ;;
            8) _require_singbox && _manage_service "status" ;;
            9) _require_singbox && _view_log ;;
            10) _require_singbox && _scheduled_restart_menu ;;
            11) _sync_system_time true ;;
            12) _require_singbox && _check_config ;;
            13) _update_script ;;
            14) _require_singbox && _dns_config_menu ;;
            15) _install_or_update_singbox ;;
            16) _uninstall ;;
            17) _require_singbox && _advanced_features ;;
            0) exit 0 ;;
            *) _error "无效输入，请重试。" ;;
        esac
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

    # 定时重启功能 - 零依赖版本 (Systemd Timer & OpenRC Logic)
    _scheduled_restart_menu() {
        clear
        echo -e "${CYAN}"
        echo '  ╔═══════════════════════════════════════╗'
        echo '  ║         定时重启 sing-box             ║'
        echo '  ╚═══════════════════════════════════════╝'
        echo -e "${NC}"
        echo ""
        
        # [!] 零依赖策略：不再安装 cron
        # 仅简单的环境预判
        if [ "$INIT_SYSTEM" == "direct" ]; then
            _error "未能识别系统初始化环境 (systemd/openrc)，定时重启功能暂不可用。"
            read -n 1 -s -r -p "按任意键返回..."
            return
        fi

    
    # 获取服务器时间信息
    local server_time=$(date '+%Y-%m-%d %H:%M:%S')
    local server_tz_offset=$(date +%z)  # 如: +0800, +0000, -0500
    local server_tz_name=$(date +%Z 2>/dev/null || echo "Unknown")  # 如: CST, UTC
    
    # 解析时区偏移 (格式: +0800 或 -0500)
    local offset_sign="${server_tz_offset:0:1}"
    local offset_hours="${server_tz_offset:1:2}"
    local offset_mins="${server_tz_offset:3:2}"
    
    # 去除前导零
    offset_hours=$((10#$offset_hours))
    offset_mins=$((10#$offset_mins))
    
    # 计算总偏移分钟数
    local server_offset_mins=$((offset_hours * 60 + offset_mins))
    if [ "$offset_sign" == "-" ]; then
        server_offset_mins=$((-server_offset_mins))
    fi
    
    # 北京时间 = UTC+8 = +480 分钟
    local beijing_offset_mins=480
    local diff_mins=$((beijing_offset_mins - server_offset_mins))
    local diff_hours=$((diff_mins / 60))
    local diff_remaining_mins=$((diff_mins % 60))
    
    # 格式化显示
    local diff_display=""
    if [ $diff_mins -gt 0 ]; then
        diff_display="北京时间比服务器快 ${diff_hours} 小时"
        if [ $diff_remaining_mins -ne 0 ]; then
            diff_display="${diff_display} ${diff_remaining_mins} 分钟"
        fi
    elif [ $diff_mins -lt 0 ]; then
        diff_display="北京时间比服务器慢 $((-diff_hours)) 小时"
        if [ $diff_remaining_mins -ne 0 ]; then
            diff_display="${diff_display} $((-diff_remaining_mins)) 分钟"
        fi
    else
        diff_display="服务器与北京时间同步"
    fi
    
    # 检查当前定时任务状态
    local cron_status="未设置"
    local cron_time=""
    
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        if [ -f "/etc/systemd/system/sing-box-restart.timer" ]; then
            cron_time=$(grep "OnCalendar" /etc/systemd/system/sing-box-restart.timer | cut -d' ' -f2 | cut -d: -f1,2)
            cron_status="已启用 (每天 ${cron_time} 重启 - Systemd)"
        fi
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        if [ -f "/etc/init.d/sing-box-timer" ] && rc-service sing-box-timer status &>/dev/null; then
            cron_time=$(grep "RESTART_TIME=" /etc/init.d/sing-box-timer | cut -d'"' -f2)
            cron_status="已启用 (每天 ${cron_time} 重启 - OpenRC)"
        fi
    fi
    
    echo -e "  ${CYAN}【服务器时间信息】${NC}"
    echo -e "    当前时间: ${GREEN}${server_time}${NC}"
    echo -e "    时区: ${GREEN}${server_tz_name} (UTC${server_tz_offset})${NC}"
    echo -e "    与北京时间: ${YELLOW}${diff_display}${NC}"
    echo ""
    echo -e "  ${CYAN}【定时重启状态】${NC}"
    if [ "$cron_status" != "未设置" ]; then
        echo -e "    状态: ${GREEN}${cron_status}${NC}"
    else
        echo -e "    状态: ${YELLOW}${cron_status}${NC}"
    fi
    echo ""
    echo -e "  ─────────────────────────────────────────"
    echo -e "    ${GREEN}[1]${NC} 设置定时重启"
    echo -e "    ${GREEN}[2]${NC} 查看当前设置"
    echo -e "    ${RED}[3]${NC} 取消定时重启"
    echo ""
    echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
    echo ""
    
    read -p "  请输入选项 [0-3]: " choice
    
    case $choice in
        1)
            echo ""
            echo -e "  ${CYAN}设置定时重启时间${NC}"
            echo -e "  提示: 输入服务器时区的时间 (24小时制)"
            echo ""
            read -p "  请输入重启时间 (格式 HH:MM, 如 04:30): " restart_time
            
            # 验证时间格式
            if [[ ! "$restart_time" =~ ^([0-1]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
                _error "时间格式错误！请使用 HH:MM 格式 (如 04:30)"
                return
            fi
            
            local hour=$(echo "$restart_time" | cut -d: -f1)
            local min=$(echo "$restart_time" | cut -d: -f2)
            local time_str=$(printf "%02d:%02d" "$((10#$hour))" "$((10#$min))")

            if [ "$INIT_SYSTEM" == "systemd" ]; then
                # Systemd Timer 方案
                cat > /etc/systemd/system/sing-box-restart.service <<EOF
[Unit]
Description=Sing-box Scheduled Restart
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart sing-box
EOF
                cat > /etc/systemd/system/sing-box-restart.timer <<EOF
[Unit]
Description=Sing-box Scheduled Restart Timer
[Timer]
OnCalendar=*-*-* ${time_str}:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
                systemctl daemon-reload
                systemctl enable --now sing-box-restart.timer
            elif [ "$INIT_SYSTEM" == "openrc" ]; then
                # OpenRC 调度服务方案
                cat > /usr/local/bin/sb-timer.sh <<EOF
#!/bin/bash
TARGET_TIME="\$1"
while true; do
    [ "\$(date +%H:%M)" == "\$TARGET_TIME" ] && rc-service sing-box restart && sleep 61
    sleep 30
done
EOF
                chmod +x /usr/local/bin/sb-timer.sh
                cat > /etc/init.d/sing-box-timer <<EOF
#!/sbin/openrc-run
description="Sing-box Scheduled Restart Timer"
command="/usr/local/bin/sb-timer.sh"
command_args="${time_str}"
pidfile="/run/sing-box-timer.pid"
command_background=true
RESTART_TIME="${time_str}"
EOF
                chmod +x /etc/init.d/sing-box-timer
                rc-service sing-box-timer restart 2>/dev/null
                rc-update add sing-box-timer default 2>/dev/null
            fi
            
            _success "定时重启已通过 ${INIT_SYSTEM} 原生组件设置完成！"
            echo ""
            echo -e "  重启时间: ${GREEN}每天 ${time_str}${NC} (服务器时区)"
                
                # 计算对应的北京时间
                local beijing_hour=$((hour + diff_hours))
                local beijing_min=$((min + diff_remaining_mins))
                
                # 处理分钟溢出
                if [ $beijing_min -ge 60 ]; then
                    beijing_min=$((beijing_min - 60))
                    beijing_hour=$((beijing_hour + 1))
                elif [ $beijing_min -lt 0 ]; then
                    beijing_min=$((beijing_min + 60))
                    beijing_hour=$((beijing_hour - 1))
                fi
                
                # 处理小时溢出
                if [ $beijing_hour -ge 24 ]; then
                    beijing_hour=$((beijing_hour - 24))
                elif [ $beijing_hour -lt 0 ]; then
                    beijing_hour=$((beijing_hour + 24))
                fi
                
                echo -e "  对应北京时间: ${YELLOW}$(printf "%02d:%02d" "$beijing_hour" "$beijing_min")${NC}"
            ;;
        2)
            echo ""
            echo -e "  ${CYAN}当前定时任务详情:${NC}"
            if [ "$INIT_SYSTEM" == "systemd" ]; then
                systemctl list-timers sing-box-restart.timer --no-pager
            elif [ "$INIT_SYSTEM" == "openrc" ]; then
                rc-service sing-box-timer status
            fi
            ;;
        3)
            echo ""
            if [ "$cron_status" == "未设置" ]; then
                _warning "当前没有设置定时重启"
            else
                read -p "$(echo -e ${YELLOW}"  确定取消定时重启? (y/N): "${NC})" confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    if [ "$INIT_SYSTEM" == "systemd" ]; then
                        systemctl disable --now sing-box-restart.timer 2>/dev/null
                        rm -f /etc/systemd/system/sing-box-restart.timer /etc/systemd/system/sing-box-restart.service
                        systemctl daemon-reload
                    elif [ "$INIT_SYSTEM" == "openrc" ]; then
                        rc-service sing-box-timer stop 2>/dev/null
                        rc-update del sing-box-timer default 2>/dev/null
                        rm -f /etc/init.d/sing-box-timer /usr/local/bin/sb-timer.sh
                    fi
                    _success "定时重启已取消，相关系统组件已清理。"
                else
                    _info "已取消操作"
                fi
            fi
            ;;
        0)
            return
            ;;
        *)
            _error "无效输入"
            ;;
    esac
    
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
}

# 批量创建节点 (v11.3 深度向导版)
_batch_create_nodes() {
    local input_str="$1"
    if [ -z "$input_str" ]; then
        _info "请输入协议编号 (空格或逗号分隔，如: 1,6,9)"
        _warn "注：批量部署不支持含有 CDN 的协议 (2, 3, 4)"
        read -p "协议列表: " input_str
    fi
    [ -z "$input_str" ] && return 1

    # 1. 解析协议列表
    local proto_ids=$(echo "$input_str" | tr ',' ' ' | xargs)
    local proto_count=0
    local has_complex=false 
    local has_sni_req=false 
    local has_reality=false
    local has_hy2=false     
    local has_ss=false      
    local ss_occurences=0

    for pid in $proto_ids; do
        if [[ ! "$pid" =~ ^(1|2|3|4|5|6|7|8|9|10)$ ]]; then
            _error "协议 ID $pid 无效，请输入 1-10 范围内的协议编号。"
            return 1
        fi
        if [[ "$pid" =~ ^(2|3|4)$ ]]; then
            _error "协议 ID $pid (WebSocket/gRPC+TLS) 不支持批量创建，请使用单节点模式单独创建以开启高级 CDN 优化。"
            return 1
        fi
        ((proto_count++))
        if [[ "$pid" == "8" ]]; then
            has_ss=true
            ((ss_occurences++))
        fi
        [[ "$pid" =~ ^(6|8)$ ]] && has_complex=true
        [[ "$pid" =~ ^(1|4|5|6|7)$ ]] && has_sni_req=true
        [[ "$pid" == "1" ]] && has_reality=true
        [[ "$pid" == "6" ]] && has_hy2=true
    done

    [ $proto_count -eq 0 ] && { _error "未选择任何协议"; return 1; }

    # 2. 引导向导
    _info "--- 批量部署引导向导 ---"
    
    # [修复] 强制初始化服务器 IP，防止各协议函数因变量未定义生成空配置
    [ -z "$server_ip" ] && server_ip=$(_get_ip)
    local batch_ip="${server_ip}"
    read -p "请输入批量节点绑定的IP地址 (回车默认: ${server_ip}): " custom_batch_ip
    batch_ip=${custom_batch_ip:-$server_ip}
    export BATCH_IP="$batch_ip"
    
    # 2.1 SNI 收集 (强制净化处理)
    export BATCH_SNI="$DEFAULT_SNI"
    export BATCH_REALITY_HANDSHAKE_SERVER="$DEFAULT_REALITY_SNI"
    export BATCH_REALITY_HANDSHAKE_PORT=443
    if [ "$has_reality" = true ]; then
        _select_reality_sni || return 1
        BATCH_SNI="$SELECTED_REALITY_SNI"
        BATCH_REALITY_HANDSHAKE_SERVER="$SELECTED_REALITY_HANDSHAKE_SERVER"
        BATCH_REALITY_HANDSHAKE_PORT="$SELECTED_REALITY_HANDSHAKE_PORT"
        export BATCH_SNI
        export BATCH_REALITY_HANDSHAKE_SERVER
        export BATCH_REALITY_HANDSHAKE_PORT
    elif [ "$has_sni_req" = true ]; then
        read -p "请输入统一伪装域名 (SNI) [默认: $BATCH_SNI]: " input_sni
        input_sni=$(echo "$input_sni" | xargs)
        [ -n "$input_sni" ] && BATCH_SNI="$input_sni"
    fi

    # 2.2 Hy2 专项
    local hy2_obfs="none"
    local hy2_hop="false"
    local hy2_hop_range=""
    if [ "$has_hy2" = true ]; then
        read -p "是否开启 Hysteria2 QUIC 混淆? (y/N): " hy2_q_choice
        [[ "$hy2_q_choice" == "y" ]] && hy2_obfs="salamander"
        read -p "是否开启 Hysteria2 端口跳跃? (y/N): " hy2_h_choice
        if [[ "$hy2_h_choice" == "y" ]]; then
            hy2_hop="true"
            read -p "请输入端口跳跃范围 (如 20000-30000): " hy2_hop_range
        fi
    fi

    # 2.4 SS 专项 (支持多选)
    local ss_variant="1"
    if [ "$has_ss" = true ]; then
        echo "选择 Shadowsocks 批量加密方式 (支持多选，如 1,2,3,4):"
        echo " 1) aes-256-gcm"
        echo " 2) chacha20-ietf-poly1305"
        echo " 3) 2022-blake3-aes-256-gcm"
        echo " 4) 2022-blake3-aes-256-gcm (带 Padding)"
        read -p "选择 [1-4] (默认1): " ss_choice
        ss_variant=${ss_choice:-1}
        # 计算 SS 实际需要的端口数
        local ss_needed=$(echo "$ss_variant" | tr ',' ' ' | wc -w)
        # 每个 Shadowsocks ID (7) 额外需要 (ss_needed - 1) 个端口
        proto_count=$((proto_count + (ss_needed - 1) * ss_occurences))
    fi

    # 3. 端口规划
    local ports_list=()
    _info "共需规划 $proto_count 个批量监听端口。"
    while true; do
        read -p "请输入端口号 (范围如 10001-10010 或空格分隔): " p_input
        local current_p_list=()
        local invalid_port=false
        local duplicate_port=false
        local occupied_port=false
        local seen_ports=" "
        p_input=$(echo "$p_input" | tr ',' ' ' | xargs)
        [ -z "$p_input" ] && { _error "端口不能为空，请重新输入。"; continue; }
        if [[ "$p_input" == *"-"* ]]; then
            local start_p=$(echo $p_input | cut -d'-' -f1)
            local end_p=$(echo $p_input | cut -d'-' -f2)
            if [[ ! "$start_p" =~ ^[0-9]+$ ]] || [[ ! "$end_p" =~ ^[0-9]+$ ]] || [ "$start_p" -lt 1 ] || [ "$end_p" -gt 65535 ] || [ "$start_p" -gt "$end_p" ]; then
                _error "端口范围无效，应为 1-65535 内的 start-end。"
                continue
            fi
            for ((p=start_p; p<=end_p; p++)); do current_p_list+=($p); done
        else
            current_p_list=($p_input)
        fi

        local p
        for p in "${current_p_list[@]}"; do
            if [[ ! "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                _error "端口 ${p} 无效，应为 1-65535。"
                invalid_port=true
                break
            fi
            if [[ "$seen_ports" == *" $p "* ]]; then
                _error "端口 ${p} 重复，请重新输入。"
                duplicate_port=true
                break
            fi
            seen_ports="${seen_ports}${p} "
            if _check_port_conflict "$p" "tcp" "true"; then
                _error "端口 ${p} 已被占用，请重新输入。"
                occupied_port=true
                break
            fi
        done
        if [ "$invalid_port" = true ] || [ "$duplicate_port" = true ] || [ "$occupied_port" = true ]; then
            continue
        fi
        
        if [ ${#current_p_list[@]} -lt $proto_count ]; then
            _error "输入端口数量不足（仅 ${#current_p_list[@]} 个），请重新输入。"
        else
            ports_list=("${current_p_list[@]}")
            break
        fi
    done

    # 4. 执行安装循环
    local bulk_idx=0
    local proto_array=($proto_ids)
    for i in "${!proto_array[@]}"; do
        local pid=${proto_array[$i]}
        
        if [ "$pid" == "8" ]; then
            local ss_variants=$(echo "$ss_variant" | tr ',' ' ')
            for v in $ss_variants; do
                local current_port=${ports_list[$bulk_idx]}
                _info "正在安装 Shadowsocks (变体 $v) 到端口 $current_port..."
                export BATCH_MODE="true"
                export BATCH_PORT="$current_port"
                export BATCH_SS_VARIANT="$v"
                _add_shadowsocks_menu
                ((bulk_idx++))
            done
        else
            local current_port=${ports_list[$bulk_idx]}
            _info "正在安装协议 [$pid] 到端口 $current_port..."
            
            export BATCH_MODE="true"
            export BATCH_PORT="$current_port"
            export BATCH_HY2_OBFS="$hy2_obfs"
            export BATCH_HY2_HOP="$hy2_hop_range"

            case $pid in
                1) _add_vless_reality ;;
                2) _add_vless_ws_tls ;;
                3) _add_trojan_ws_tls ;;
                4) _add_vless_grpc_tls ;;
                5) _add_anytls ;;
                6) _add_hysteria2 ;;
                7) _add_tuic ;;
                9) _add_vless_tcp ;;
                10) _add_socks ;;
            esac
            ((bulk_idx++))
        fi
    done

    unset BATCH_MODE BATCH_PORT BATCH_SNI BATCH_SNI_ROUTER BATCH_REALITY_HANDSHAKE_SERVER BATCH_REALITY_HANDSHAKE_PORT BATCH_HY2_OBFS BATCH_HY2_HOP BATCH_SS_VARIANT BATCH_ANYTLS_MODE BATCH_IP BATCH_GRPC_TLS_DOMAIN BATCH_GRPC_SERVICE_NAME
    
    echo ""
    echo -e "${YELLOW}══════════════════ 批量创建完成提示 ══════════════════${NC}"
    _success "所有节点已按直连模式部署完毕。"
    _info "所有批量节点已就绪，您可以运行 sb 查看具体配置。"
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"

    _success "批量创建任务已全部完成。"
    _manage_service restart
}

_show_add_node_menu() {
    local needs_restart=false
    local action_result
    ADD_NODE_SERVICE_RESTARTED=false
    [ -z "$server_ip" ] && _init_server_ip
    clear
    echo -e "${CYAN}"
    echo '  ╔═══════════════════════════════════════╗'
    echo '  ║          sing-box 添加节点            ║'
    echo '  ╚═══════════════════════════════════════╝'
    echo -e "${NC}"
    echo ""
    
    echo -e "  ${CYAN}【协议选择】${NC}"
    echo -e "    ${GREEN}[1]${NC} VLESS (Vision+REALITY)"
    echo -e "    ${GREEN}[2]${NC} VLESS (WebSocket+TLS)"
    echo -e "    ${GREEN}[3]${NC} Trojan (WebSocket+TLS)"
    echo -e "    ${GREEN}[4]${NC} VLESS (gRPC+TLS)"
    echo -e "    ${GREEN}[5]${NC} AnyTLS"
    echo -e "    ${GREEN}[6]${NC} Hysteria2"
    echo -e "    ${GREEN}[7]${NC} TUICv5"
    echo -e "    ${GREEN}[8]${NC} Shadowsocks"
    echo -e "    ${GREEN}[9]${NC} VLESS (TCP)"
    echo -e "    ${GREEN}[10]${NC} SOCKS5"
    echo ""
    
    echo -e "  ${CYAN}【快捷功能】${NC}"
    echo -e "   ${GREEN}[11]${NC} 批量创建节点"
    echo ""
    
    echo -e "  ─────────────────────────────────────────"
    echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
    echo ""
    
    read -p "  请输入选项 [0-11]: " choice

    # 如果输入包含逗号或空格，自动进入批量处理模式
    if [[ "$choice" == *","* ]] || [[ "$choice" == *" "* ]]; then
        _batch_create_nodes "$choice"
        return
    fi

    case $choice in
        1) _add_vless_reality; action_result=$? ;;
        2) _add_vless_ws_tls; action_result=$? ;;
        3) _add_trojan_ws_tls; action_result=$? ;;
        4) _add_vless_grpc_tls; action_result=$? ;;
        5) _add_anytls; action_result=$? ;;
        6) _add_hysteria2; action_result=$? ;;
        7) _add_tuic; action_result=$? ;;
        8) _add_shadowsocks_menu; action_result=$? ;;
        9) _add_vless_tcp; action_result=$? ;;
        10) _add_socks; action_result=$? ;;
        11) _batch_create_nodes; return ;;
        0) return ;;
        *) _error "无效输入，请重试。" ;;
    esac

    if [ "$action_result" -eq 0 ] 2>/dev/null; then
        needs_restart=true
    fi

    if [ "$needs_restart" = true ] && [ "${ADD_NODE_SERVICE_RESTARTED:-false}" != true ]; then
        _info "配置已更新"
        _manage_service "restart"
    fi
}

# --- 脚本入口 ---

main() {
    _check_root
    _detect_init_system
    
    # 强制预创建目录，防止后续 cp/mv 因路径不存在报错 (保底机制)
    mkdir -p "${SINGBOX_DIR}" 2>/dev/null
    _secure_sensitive_files
    
    # 1. 首次安装或依赖状态失效时才完整检查，避免每次 sb 进入菜单都触发包管理器
    _install_dependencies
    _ensure_quick_command
    
    # 2. 根据核心安装状态决定初始化路径
    if [ -f "${SINGBOX_BIN}" ]; then
        # --- sing-box 已安装：执行完整的初始化与自愈检测 ---
        
        # 3. 检查配置文件
        if [ ! -f "${CONFIG_FILE}" ] || [ ! -f "${CLASH_YAML_FILE}" ]; then
             _info "检测到主配置文件缺失，正在初始化..."
             _initialize_config_files
        fi

        # 3.1 初始化中转配置 (配置隔离)
        _init_relay_config
        
        # 3.2 [关键修复] 清理主配置文件中的旧版残留
        local config_updated=false
        if _cleanup_legacy_config; then
            config_updated=true
        fi
        
        # 3.3 [热修复] 检测并补充 DNS 模块
        local dns_fix_status=1
        if _check_and_fix_dns; then
            config_updated=true
        else
            dns_fix_status=$?
            if [ "$dns_fix_status" -eq 2 ]; then
                _warn "DNS 配置自动迁移失败；升级核心前必须先处理该配置。"
            fi
        fi
        
        if [ "$config_updated" = true ]; then
            _manage_service restart
        fi
        
        # [BUG FIX] 检查并修复旧版服务文件
        if [ -f "$SERVICE_FILE" ]; then
            local need_update=false
            if grep -q "\-C " "$SERVICE_FILE"; then
                _warn "检测到旧版服务配置(目录加载模式导致冲突)，正在修复..."
                need_update=true
            fi
            if [ "$INIT_SYSTEM" == "openrc" ] && ! grep -q "supervisor=" "$SERVICE_FILE"; then
                _warn "检测到旧版 OpenRC 服务配置，正在修复以兼容 Alpine..."
                need_update=true
            fi
            if grep -q "ENABLE_DEPRECATED_" "$SERVICE_FILE"; then
                _warn "检测到 sing-box 旧版 DNS 兼容环境变量，正在移除..."
                need_update=true
            fi
            if [ "$need_update" = true ]; then
                if [ "$INIT_SYSTEM" == "systemd" ]; then
                     _create_systemd_service
                     systemctl daemon-reload
                elif [ "$INIT_SYSTEM" == "openrc" ]; then
                     _create_openrc_service
                fi
                if { [ "$INIT_SYSTEM" == "systemd" ] && systemctl is-active sing-box >/dev/null 2>&1; } || { [ "$INIT_SYSTEM" == "openrc" ] && rc-service sing-box status >/dev/null 2>&1; }; then
                    _manage_service restart
                fi
                _success "服务配置修复完成。"
            fi
        fi

        # [PATH FIX] 确保 relay.json 存在
        if [ ! -s "${SINGBOX_DIR}/relay.json" ]; then
            echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "${SINGBOX_DIR}/relay.json"
        fi

        # 4. 首次安装或服务文件缺失时才创建，避免每次进入菜单都重写服务文件
        if [ -n "$SERVICE_FILE" ] && [ ! -f "$SERVICE_FILE" ]; then
            _create_service_files
        elif [ "$INIT_SYSTEM" == "direct" ] && [ ! -f "$LOG_FILE" ]; then
            touch "$LOG_FILE"
        fi
        _setup_log_cleanup
        _sanitize_argo_metadata || true
        _secure_sensitive_files
    else
        # --- sing-box 未安装：仅显示提示，不自动安装 ---
        _warn "sing-box 核心未安装。请通过主菜单【核心管理】进行安装。"
    fi
    
    _main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # 解析命令行参数；直接执行 sb 时保持原有交互入口。
    while [[ $# -gt 0 ]]; do
        case "$1" in
            sni-router)
                _check_root
                shift
                _sni_router_cli "$@"
                exit $?
                ;;
            keepalive)
                _argo_keepalive
                exit 0
                ;;
            cleanup-logs)
                _cleanup_runtime_logs
                exit $?
                ;;
            install-realitlscanner)
                _check_root
                mkdir -p "$SINGBOX_DIR"
                _install_realitlscanner
                exit $?
                ;;
            install-reality-origin)
                _check_root
                local_origin_domain="${2:-}"
                [ -n "$local_origin_domain" ] || { _error "缺少自有域名参数。"; exit 1; }
                mkdir -p "$SINGBOX_DIR"
                _install_dependencies
                _prepare_local_reality_origin "$local_origin_domain"
                exit $?
                ;;
            *)
                shift
                ;;
        esac
    done

    main
fi
