#!/usr/bin/env bash
# PROXYALL_LIB=reality.sh
# Reality 目标选择：RealiTLScanner 扫描、握手探测、GreatFire 大陆可达性筛查与自有域名入口，供 sb 与中转模块共用。

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
    _node_read -r -p "是否从 go.dev 安装满足要求的官方 Go 工具链？[Y/n]: " install_go || return $?
    if [[ "$install_go" == "n" || "$install_go" == "N" ]]; then
        _warn "已取消 RealiTLScanner 安装。"
        return 1
    fi
    _install_managed_go_toolchain || return 1
    _find_compatible_go
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
        _node_read_yes_no "仍要使用这个未经大陆验证的 SNI？[y/N]: " force_unverified || return $?
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
            _node_read_yes_no "仍要使用这个结果不明确的 SNI？[y/N]: " force_unverified || return $?
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
        if [ "${NODE_UI:-false}" = true ]; then
            IFS= _node_read -r raw_line || return $?
        else IFS= read -r raw_line || break; fi
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
    _node_read -r -p "请选择 [1-3] (默认: 2): " scan_mode || { scan_status=$?; rm -rf -- "$temp_dir"; return "$scan_status"; }
    scan_mode="${scan_mode:-2}"
    case "$scan_mode" in
        1)
            _warn "上游建议在本地而非云 VPS 扫描；本模式限制为最多 /24、16 线程、3 秒单目标超时。"
            _node_read -r -p "请输入扫描 IPv4 CIDR [${default_cidr:-例如 203.0.113.0/24}]: " scan_cidr || { scan_status=$?; rm -rf -- "$temp_dir"; return "$scan_status"; }
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

    _install_realitlscanner || {
        rm -rf -- "$temp_dir"
        _error "RealiTLScanner 安装或校验失败，尚未开始扫描。"
        return 1
    }
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
    NODE_PENDING_ORIGIN=''

    echo "Reality 目标优先使用你自己控制的、真实可访问的 HTTPS 域名。"
    _node_read_yes_no "你是否有符合条件的自有域名？[y/N]: " own_domain_choice || return $?
    if [[ "$own_domain_choice" == "y" || "$own_domain_choice" == "Y" ]]; then
        echo "  自有域名使用方式："
        echo "  1) 单机自动模式：本机安装 Nginx、申请证书并配置自动续期（默认）"
        echo "  2) 使用已经存在的独立 HTTPS 源站"
        local own_mode own_domain
        _node_read -r -p "请选择 [1-2] (默认: 1): " own_mode || return $?
        own_mode="${own_mode:-1}"
        if [ "$own_mode" = "1" ]; then
            echo "  单机自动模式要求："
            echo "  1) 域名 A/AAAA 已指向本机，且使用 DNS only。"
            echo "  2) 公网 TCP 80 可访问，用于 Let's Encrypt HTTP-01；不需要 Cloudflare Token。"
            echo "  3) Nginx 仅在 127.0.0.1:${REALITY_LOCAL_ORIGIN_PORT} 提供 Reality HTTPS 源站。"
            echo "  4) 若 Reality 与 Emby 都使用公网 443，请启用 HAProxy SNI 分流，并确保两个域名不同。"
            _node_read -r -p "请输入自有域名: " own_domain || return $?
            own_domain=$(printf '%s' "$own_domain" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
            _is_valid_reality_domain "$own_domain" || { _error "自有域名格式无效。"; return 1; }
            if [ "${NODE_UI:-false}" = true ]; then NODE_PENDING_ORIGIN="$own_domain"
            else _prepare_local_reality_origin "$own_domain" || return 1; fi
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
        _node_read -r -p "请输入自有 Reality 目标域名: " own_domain || return $?
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
    _node_read_yes_no "是否启用 GreatFire 大陆可达性筛查？[Y/n]: " greatfire_choice || return $?
    if [[ "$greatfire_choice" == "n" || "$greatfire_choice" == "N" ]]; then
        REALITY_CHINA_CHECK_ENABLED=false
        _warn "已关闭大陆侧校验；选择候选时需要再次明确确认风险。"
    else
        REALITY_CHINA_CHECK_ENABLED=true
    fi

    _node_read_yes_no "是否使用 XTLS/RealiTLScanner 查找 Reality 候选？[Y/n]: " scan_choice || return $?
    if [[ "$scan_choice" != "n" && "$scan_choice" != "N" ]]; then
        while ! _scan_reality_sni_once; do
            [ ! -f "${NODE_TX_DIR:-}/cancelled" ] || return 2
            while true; do
                echo "  1) 重新扫描（默认）"
                echo "  2) 跳过扫描，进入默认域名选择"
                echo "  0) 取消本次 Reality 节点添加"
                _node_read -r -p "扫描未成功，请选择 [0-2] (默认: 1): " scan_action || return $?
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
        _node_read -r -p "请输入候选编号，回车使用 ${DEFAULT_REALITY_SNI}，或输入 0 取消: " sni_choice || return $?
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
            _node_read_yes_no "仍要继续检查该默认目标的大陆可达性？[y/N]: " force_default || return $?
            if [[ "$force_default" != "y" && "$force_default" != "Y" ]]; then
                continue
            fi
        fi
        if _confirm_reality_china_reachability "$SELECTED_REALITY_SNI"; then
            break
        fi
        [ ! -f "${NODE_TX_DIR:-}/cancelled" ] || return 2
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
