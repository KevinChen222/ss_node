#!/usr/bin/env bash
# PROXYALL_LIB=sni_router.sh

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

# Entry scripts supply logging, systemd/package policy, and prepare hooks.
# common.sh supplies _config_write_lock. sb owns node migration and port allocation.
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

# --- HAProxy TCP/443 SNI 共享入口 ---

_sni_router_lock() {
    _config_write_lock || return 1
    [ -z "${NODE_TX_DIR:-}" ] || touch "$NODE_TX_DIR/router-touched" || return 1
    mkdir -p "$(dirname "$SNI_ROUTER_LOCK_FILE")" || return 1
    exec 9>"$SNI_ROUTER_LOCK_FILE" || return 1
    flock -x -w 30 9 || { _sni_router_error "SNI 路由正在被其他进程修改，请稍后重试。"; return 1; }
}

_sni_router_init_state() {
    mkdir -p "$SNI_ROUTER_STATE_DIR" || return 1
    chmod 700 "$SNI_ROUTER_STATE_DIR" 2>/dev/null || true
    if [ ! -e "$SNI_ROUTER_STATE_FILE" ]; then
        if [ -L "$SNI_ROUTER_STATE_FILE" ] || grep -Fxq -- "$SNI_ROUTER_MARKER" "$SNI_ROUTER_HAPROXY_CONF" 2>/dev/null; then
            _sni_router_error "SNI 路由状态丢失，拒绝重新初始化: ${SNI_ROUTER_STATE_FILE}"
            return 1
        fi
        local tmp
        tmp=$(mktemp "${SNI_ROUTER_STATE_DIR}/state.XXXXXX") || return 1
        if ! jq -n --argjson version "$SNI_ROUTER_API_VERSION" --argjson port "$SNI_ROUTER_PUBLIC_PORT" \
            '{version:$version,public_port:$port,reality:null,https_backend:null,https_routes:{},tls_routes:{}}' > "$tmp" ||
           ! mv -- "$tmp" "$SNI_ROUTER_STATE_FILE"; then
            rm -f -- "$tmp"
            return 1
        fi
    fi
    if ! jq -se --argjson version "$SNI_ROUTER_API_VERSION" '
        def port: type == "number" and . >= 1 and . <= 65535 and . == floor;
        def sni: type == "string" and test("^[a-z0-9][a-z0-9.-]*\\z"; "i") and contains(".");
        def backend: .backend_host == "127.0.0.1" and (.backend_port | port);
        length == 1 and (.[0] |
            .version == $version and (.public_port | port) and
            (.reality | . == null or (backend and (.sni | sni))) and
            (.https_routes | type == "object" and all(keys[]; sni)) and
            ((.https_routes | length) == 0 or
                (.https_backend | .host == "127.0.0.1" and (.port | port))) and
            (.tls_routes | . == null or (type == "object" and all(to_entries[]; (.key | sni) and (.value | backend)))))
    ' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
        _sni_router_error "SNI 路由状态损坏或版本不兼容: ${SNI_ROUTER_STATE_FILE}"
        return 1
    fi
}

_sni_router_routes_present() {
    jq -r '(.reality != null) or ((.https_routes | length) > 0) or ((.tls_routes | length) > 0)' \
        "$SNI_ROUTER_STATE_FILE"
}

_sni_router_validate_port() {
    if [[ ${sni_router_standalone:-no} == yes && ! $1 =~ ^[1-9][0-9]{0,4}$ ]]; then return 1; fi
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_sni_router_prepare_haproxy() {
    _sni_router_require_systemd || return 1
    command -v haproxy >/dev/null 2>&1 || _sni_router_install_haproxy || return 1

    mkdir -p "$(dirname "$SNI_ROUTER_HAPROXY_CONF")" "$SNI_ROUTER_HAPROXY_BACKUP_DIR" || return 1
    chmod 700 "$SNI_ROUTER_HAPROXY_BACKUP_DIR" 2>/dev/null || true
    if [ -f "$SNI_ROUTER_HAPROXY_CONF" ] && ! grep -Fxq -- "$SNI_ROUTER_MARKER" "$SNI_ROUTER_HAPROXY_CONF"; then
        if grep -Eq '^[[:space:]]*(frontend|listen)[[:space:]]' "$SNI_ROUTER_HAPROXY_CONF"; then
            _sni_router_error "检测到非 sb.sh 管理的 HAProxy 前端，拒绝覆盖: ${SNI_ROUTER_HAPROXY_CONF}"
            _sni_router_error "请先手动整合现有 HAProxy 配置。"
            return 1
        fi
        cp -a -- "$SNI_ROUTER_HAPROXY_CONF" \
            "${SNI_ROUTER_HAPROXY_BACKUP_DIR}/haproxy.cfg.$(date +%Y%m%d_%H%M%S).$$" || return 1
    fi
}

_sni_router_generate_haproxy_config() {
    local output="$1" public_port reality_host reality_port https_host https_port https_domains tls_domains tls_backends
    public_port=$(jq -r '.public_port' "$SNI_ROUTER_STATE_FILE") || return 1
    reality_host=$(jq -r '.reality.backend_host // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    reality_port=$(jq -r '.reality.backend_port // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    https_host=$(jq -r '.https_backend.host // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    https_port=$(jq -r '.https_backend.port // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    https_domains=$(jq -r '.https_routes | keys[]?' "$SNI_ROUTER_STATE_FILE") || return 1
    tls_domains=$(jq -r '(.tls_routes // {}) | keys[]?' "$SNI_ROUTER_STATE_FILE") || return 1
    tls_backends=$(jq -r '(.tls_routes // {}) | to_entries | sort_by(.key)[]? |
        [.value.backend_host, (.value.backend_port|tostring)] | @tsv' "$SNI_ROUTER_STATE_FILE") || return 1

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
        done <<< "$https_domains"

        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "    acl sb_tls_route_${tls_route_count} req.ssl_sni -i ${domain}"
            tls_route_count=$((tls_route_count + 1))
        done <<< "$tls_domains"

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
    server nginx ${https_host}:${https_port} send-proxy-v2
EOF_HAPROXY_HTTPS
        fi
        i=0
        while IFS=$'\t' read -r tls_host tls_port; do
            [ -n "$tls_host" ] && [ -n "$tls_port" ] || continue
            cat <<EOF_HAPROXY_TLS

backend sb_tls_backend_${i}
    server tls_${i} ${tls_host}:${tls_port}
EOF_HAPROXY_TLS
            i=$((i + 1))
        done <<< "$tls_backends"
        if [ -n "$reality_host" ] && [ -n "$reality_port" ]; then
            cat <<EOF_HAPROXY_REALITY

backend sb_reality_backend
    server reality ${reality_host}:${reality_port}
EOF_HAPROXY_REALITY
        fi
    } > "$output"
}

_sni_router_apply() {
    local routes_present
    _sni_router_init_state || return 1
    routes_present=$(_sni_router_routes_present) || return 1
    if [ "$routes_present" = false ]; then
        if grep -Fxq -- "$SNI_ROUTER_MARKER" "$SNI_ROUTER_HAPROXY_CONF" 2>/dev/null; then
            local was_active=no was_enabled=no
            if systemctl is-active --quiet haproxy; then was_active=yes; fi
            if systemctl is-enabled --quiet haproxy; then was_enabled=yes; fi
            if ! systemctl disable --now haproxy 8>&- 9>&-; then
                _sni_router_error "无法停用 HAProxy，路由操作失败。"
                if [ "$was_enabled" = yes ]; then systemctl enable haproxy 8>&- 9>&- || _sni_router_error "无法恢复 HAProxy 开机启动。"; fi
                if [ "$was_active" = yes ]; then systemctl start haproxy 8>&- 9>&- || _sni_router_error "无法恢复 HAProxy 服务。"; fi
                return 1
            fi
        fi
        return 0
    fi
    _sni_router_prepare_haproxy || return 1

    local new_conf old_conf had_old=no action=start
    new_conf=$(mktemp) || return 1
    if ! _sni_router_generate_haproxy_config "$new_conf" || ! haproxy -c -f "$new_conf"; then
        _sni_router_error "HAProxy 配置验证失败，未安装新配置。"
        rm -f -- "$new_conf"
        return 1
    fi
    if systemctl is-active --quiet haproxy; then
        action=reload
        if cmp -s "$new_conf" "$SNI_ROUTER_HAPROXY_CONF"; then
            rm -f -- "$new_conf"
            return 0
        fi
    fi
    old_conf=$(mktemp "${SNI_ROUTER_HAPROXY_CONF}.rollback.XXXXXX") || { rm -f -- "$new_conf"; return 1; }
    if [ -f "$SNI_ROUTER_HAPROXY_CONF" ]; then
        cp -a -- "$SNI_ROUTER_HAPROXY_CONF" "$old_conf" || { rm -f -- "$new_conf" "$old_conf"; return 1; }
        had_old=yes
    fi
    if ! install -m 640 "$new_conf" "${SNI_ROUTER_HAPROXY_CONF}.new" ||
       ! mv -- "${SNI_ROUTER_HAPROXY_CONF}.new" "$SNI_ROUTER_HAPROXY_CONF"; then
        rm -f -- "$new_conf" "$old_conf" "${SNI_ROUTER_HAPROXY_CONF}.new"
        return 1
    fi
    rm -f -- "$new_conf"

    if ! systemctl "$action" haproxy 8>&- 9>&-; then
        _sni_router_error "HAProxy 加载失败，正在恢复上一份配置。"
        local config_restored=yes
        if [ "$had_old" = yes ]; then
            if ! mv -- "$old_conf" "$SNI_ROUTER_HAPROXY_CONF"; then
                _sni_router_error "无法恢复 HAProxy 配置，备份保留在 $old_conf"
                config_restored=no
            fi
        else
            rm -f -- "$old_conf"
            if ! rm -f -- "$SNI_ROUTER_HAPROXY_CONF"; then
                _sni_router_error "无法移除失败的 HAProxy 配置: $SNI_ROUTER_HAPROXY_CONF"
                config_restored=no
            fi
        fi
        if [ "$action" = reload ] && [ "$had_old" = yes ] && [ "$config_restored" = yes ]; then
            if systemctl restart haproxy 8>&- 9>&-; then return 1; fi
            _sni_router_error "恢复旧配置后 HAProxy 重启失败，将停止服务。"
        fi
        systemctl stop haproxy 8>&- 9>&- || _sni_router_error "无法停止 HAProxy，请检查当前运行配置。"
        return 1
    fi
    rm -f -- "$old_conf"
    systemctl enable haproxy >/dev/null 2>&1 8>&- 9>&- || true
}

# 调用方持有路由锁。apply 自行恢复 HAProxy 配置及服务，这里只恢复路由状态。
_sni_router_update_state() {
    local backup tmp
    backup=$(mktemp "${SNI_ROUTER_STATE_DIR}/state.rollback.XXXXXX") || return 1
    tmp=$(mktemp "${SNI_ROUTER_STATE_DIR}/state.XXXXXX") || { rm -f -- "$backup"; return 1; }
    if ! cp -a -- "$SNI_ROUTER_STATE_FILE" "$backup" ||
       ! jq "$@" "$SNI_ROUTER_STATE_FILE" > "$tmp" ||
       ! mv -- "$tmp" "$SNI_ROUTER_STATE_FILE"; then
        rm -f -- "$backup" "$tmp"
        return 1
    fi
    if ! _sni_router_apply; then
        mv -- "$backup" "$SNI_ROUTER_STATE_FILE" || _sni_router_error "无法恢复 SNI 状态，备份保留在 $backup"
        return 1
    fi
    rm -f -- "$backup"
}

_sni_router_restore_state() {
    local backup="$1"
    cp -a -- "$backup" "$SNI_ROUTER_STATE_FILE" && _sni_router_apply
}

_sni_router_assert_sni_available() (
    local sni="${1,,}" conflict
    _is_valid_reality_domain "$sni" || { _sni_router_error "SNI 格式无效: ${sni}"; return 1; }
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    conflict=$(jq -r --arg sni "$sni" '
        if ((.reality.sni // "") | ascii_downcase) == $sni then
            "Reality: " + (.reality.tag // "unknown")
        elif .https_routes[$sni] != null then
            "HTTPS/Emby: " + (.https_routes[$sni].owner // "unknown")
        elif .tls_routes[$sni] != null then
            "TLS: " + (.tls_routes[$sni].tag // "unknown")
        else "" end
    ' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$conflict" ]; then
        _sni_router_error "完整域名 ${sni} 已被共享 443 路由占用（${conflict}）；请改用另一个子域名。"
        return 1
    fi
)

_sni_router_register_reality() (
    # 子 shell 在所有返回路径释放路由锁，避免交互菜单长期持锁。
    local owner="$1" tag="$2" sni="$3" backend_port="$4"
    _is_valid_reality_domain "$sni" || { _sni_router_error "Reality SNI 格式无效: ${sni}"; return 1; }
    _sni_router_validate_port "$backend_port" || { _sni_router_error "Reality 后端端口无效。"; return 1; }
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing conflicting_https conflicting_tls
    existing=$(jq -r '.reality.tag // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$existing" ] && [ "$existing" != "$tag" ]; then
        _sni_router_error "公网 443 已登记 Reality 后端: ${existing}。一个 443 入口只能指定一个默认 Reality 后端。"
        return 1
    fi
    conflicting_https=$(jq -r --arg sni "${sni,,}" '.https_routes[$sni].owner // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$conflicting_https" ]; then
        _sni_router_error "Reality SNI ${sni,,} 已被 HTTPS 路由 ${conflicting_https} 使用；两者必须使用不同域名。"
        return 1
    fi
    conflicting_tls=$(jq -r --arg sni "${sni,,}" '.tls_routes[$sni].tag // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$conflicting_tls" ]; then
        _sni_router_error "Reality SNI ${sni,,} 已被 TLS 路由 ${conflicting_tls} 使用；两者必须使用不同域名。"
        return 1
    fi
    _sni_router_update_state --arg owner "$owner" --arg tag "$tag" --arg sni "${sni,,}" --argjson port "$backend_port" \
        '.reality={owner:$owner,tag:$tag,sni:$sni,backend_host:"127.0.0.1",backend_port:$port}'
)

_sni_router_remove_reality() (
    local tag="${1:-}"
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing
    existing=$(jq -r '.reality.tag // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    [ -n "$existing" ] || return 0
    if [ -n "$tag" ] && [ "$tag" != "$existing" ]; then
        _sni_router_error "Reality 默认后端属于 ${existing}，拒绝按不匹配的 tag ${tag} 删除。"
        return 1
    fi
    _sni_router_update_state '.reality=null'
)

_sni_router_register_tls() (
    local owner="$1" tag="$2" sni="${3,,}" backend_port="$4"
    _is_valid_reality_domain "$sni" || { _sni_router_error "TLS SNI 格式无效: ${sni}"; return 1; }
    _sni_router_validate_port "$backend_port" || { _sni_router_error "TLS 后端端口无效。"; return 1; }
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local existing_tag conflicting_https reality_sni
    existing_tag=$(jq -r --arg sni "$sni" '.tls_routes[$sni].tag // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$existing_tag" ] && [ "$existing_tag" != "$tag" ]; then
        _sni_router_error "TLS SNI ${sni} 已由 ${existing_tag} 登记。"
        return 1
    fi
    conflicting_https=$(jq -r --arg sni "$sni" '.https_routes[$sni].owner // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$conflicting_https" ]; then
        _sni_router_error "TLS SNI ${sni} 已被 HTTPS 路由 ${conflicting_https} 使用。"
        return 1
    fi
    reality_sni=$(jq -r '.reality.sni // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$reality_sni" ] && [ "${reality_sni,,}" = "$sni" ]; then
        _sni_router_error "TLS SNI ${sni} 与 Reality SNI 相同；两者必须使用不同域名。"
        return 1
    fi
    _sni_router_update_state --arg owner "$owner" --arg tag "$tag" --arg sni "$sni" --argjson port "$backend_port" \
        '.tls_routes[$sni]={owner:$owner,tag:$tag,backend_host:"127.0.0.1",backend_port:$port}'
)

_sni_router_remove_tls() (
    local tag="$1"
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local sni
    sni=$(jq -r --arg tag "$tag" 'first((.tls_routes // {}) | to_entries[] | select(.value.tag == $tag) | .key)' "$SNI_ROUTER_STATE_FILE") || return 1
    [ -n "$sni" ] || return 0
    _sni_router_update_state --arg sni "$sni" 'del(.tls_routes[$sni])'
)

# Legacy state can contain mixed-case keys. Match them as HAProxy does and
# preserve the stored spelling when updating or removing an HTTPS route.
_sni_router_https_key() {
    jq -r --arg sni "$1" '
        .https_routes | if has($sni) then $sni else first(keys[] | select(ascii_downcase == $sni)) end
    ' "$SNI_ROUTER_STATE_FILE"
}

_sni_router_register_https() (
    local owner="$1" sni="${2,,}" backend_port="$3"
    _sni_router_validate_https_sni "$sni" || { _sni_router_error "HTTPS SNI 格式无效: ${sni}"; return 1; }
    _sni_router_validate_port "$backend_port" || { _sni_router_error "HTTPS 后端端口无效。"; return 1; }
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local key existing_owner existing_port reality_sni conflicting_tls
    key=$(_sni_router_https_key "$sni") || return 1
    key=${key:-$sni}
    existing_owner=$(jq -r --arg key "$key" '.https_routes[$key].owner // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$existing_owner" ] && [ "$existing_owner" != "$owner" ]; then
        _sni_router_error "SNI ${sni} 已由 ${existing_owner} 登记。"
        return 1
    fi
    reality_sni=$(jq -r '.reality.sni // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$reality_sni" ] && [ "${reality_sni,,}" = "$sni" ]; then
        _sni_router_error "HTTPS SNI ${sni} 与 Reality SNI 相同；两者必须使用不同域名。"
        return 1
    fi
    conflicting_tls=$(jq -r --arg sni "$sni" '
        first((.tls_routes // {}) | to_entries[] | select((.key | ascii_downcase) == $sni) |
            if (.value.tag // "") == "" then .key else .value.tag end)
    ' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$conflicting_tls" ]; then
        _sni_router_error "HTTPS SNI ${sni} 已被 TLS 路由 ${conflicting_tls} 使用。"
        return 1
    fi
    existing_port=$(jq -r '.https_backend.port // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    if [ -n "$existing_port" ] && [ "$existing_port" != "$backend_port" ]; then
        _sni_router_error "现有 HTTPS 后端为 127.0.0.1:${existing_port}，拒绝混用 ${backend_port}。"
        return 1
    fi
    _sni_router_update_state --arg owner "$owner" --arg key "$key" --argjson port "$backend_port" \
        '.https_backend={host:"127.0.0.1",port:$port} | .https_routes[$key]={owner:$owner}'
)

_sni_router_remove_https() (
    local owner="$1" sni="${2,,}"
    _sni_router_lock || return 1
    _sni_router_init_state || return 1
    local key existing_owner
    key=$(_sni_router_https_key "$sni") || return 1
    [ -n "$key" ] || return 0
    existing_owner=$(jq -r --arg key "$key" '.https_routes[$key].owner // empty' "$SNI_ROUTER_STATE_FILE") || return 1
    [ -n "$existing_owner" ] || return 0
    if [ -n "$owner" ] && [ "$owner" != "$existing_owner" ]; then
        _sni_router_error "SNI ${sni} 属于 ${existing_owner}，拒绝由 ${owner} 删除。"
        return 1
    fi
    _sni_router_update_state --arg key "$key" \
        'del(.https_routes[$key]) | if (.https_routes|length)==0 then .https_backend=null else . end'
)

_sni_router_status() {
    _sni_router_init_state || return 1
    echo "SNI_ROUTER_API_VERSION=${SNI_ROUTER_API_VERSION}"
    jq -r '
        . as $root |
        "public=:" + (.public_port|tostring),
        (if .reality then "reality=" + .reality.sni + " -> " + .reality.backend_host + ":" + (.reality.backend_port|tostring) else "reality=未登记" end),
        (if (.https_routes|length)>0 then (.https_routes|to_entries[]|"https="+.key+" -> "+$root.https_backend.host+":"+($root.https_backend.port|tostring)+" ("+.value.owner+")") else "https=未登记" end),
        (if (.tls_routes|length)>0 then (.tls_routes|to_entries[]|"tls="+.key+" -> "+.value.backend_host+":"+(.value.backend_port|tostring)+" ("+.value.tag+")") else "tls=未登记" end)
    ' "$SNI_ROUTER_STATE_FILE" || return 1
    if _sni_router_status_has_systemd && systemctl is-active haproxy >/dev/null 2>&1; then
        echo 'haproxy=active'
    else
        echo 'haproxy=inactive'
    fi
}

_sni_router_check() {
    local routes_present
    _sni_router_init_state || return 1
    routes_present=$(_sni_router_routes_present) || return 1
    if [ "$routes_present" = true ]; then
        command -v haproxy >/dev/null 2>&1 || { _sni_router_error "未安装 HAProxy。"; return 1; }
        local tmp status=0
        tmp=$(mktemp) || return 1
        _sni_router_generate_haproxy_config "$tmp" || { rm -f "$tmp"; return 1; }
        haproxy -c -f "$tmp" || status=$?
        rm -f "$tmp"
        return "$status"
    fi
    _sni_router_info "SNI 路由尚未登记任何后端。"
}

_sni_router_prepare_routes() {
    local routes_present
    _sni_router_init_state || return 1
    routes_present=$(_sni_router_routes_present) || return 1
    if [ "$routes_present" = true ]; then
        _sni_router_apply
    elif [[ ${sni_router_standalone:-no} == yes ]]; then
        _sni_router_info '未检测到 sb.sh，将由 nginxproxy 初始化 HAProxy SNI 分流。'
    fi
}

_sni_router_cli() (
    if [ "${1:-status}" != api-version ]; then _config_write_lock || exit 1; fi
    _sni_router_cli_impl "$@"
)

_sni_router_cli_impl() {
    local action="${1:-status}"
    shift || true
    if [[ ${sni_router_standalone:-no} == yes ]]; then
        case "$action" in
            api-version|status|check|prepare|register-https|remove-https) ;;
            *) _sni_router_error "nginxproxy 内置 SNI 路由器不支持操作: $action"; return 2 ;;
        esac
    fi
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
        check-sni-free)
            [ "$#" -eq 1 ] || { _sni_router_error "用法: sb sni-router check-sni-free SNI"; return 2; }
            _sni_router_assert_sni_available "$1"
            ;;
        register-reality)
            [ "$#" -eq 4 ] || { _sni_router_error "用法: sb sni-router register-reality OWNER TAG SNI BACKEND_PORT"; return 2; }
            _sni_router_register_reality "$1" "$2" "$3" "$4"
            ;;
        remove-reality)
            _sni_router_remove_reality "${1:-}"
            ;;
        register-tls)
            [ "$#" -eq 4 ] || { _sni_router_error "用法: sb sni-router register-tls OWNER TAG SNI BACKEND_PORT"; return 2; }
            _sni_router_register_tls "$1" "$2" "$3" "$4"
            ;;
        remove-tls)
            [ "$#" -eq 1 ] || { _sni_router_error "用法: sb sni-router remove-tls TAG"; return 2; }
            _sni_router_remove_tls "$1"
            ;;
        register-https)
            [ "$#" -eq 3 ] || { _sni_router_error "用法: sb sni-router register-https OWNER SNI BACKEND_PORT"; return 2; }
            _sni_router_register_https "$1" "$2" "$3"
            ;;
        remove-https)
            [ "$#" -eq 2 ] || { _sni_router_error "用法: sb sni-router remove-https OWNER SNI"; return 2; }
            _sni_router_remove_https "$1" "$2"
            ;;
        *)
            _sni_router_error "未知 SNI 路由操作: ${action}"
            return 2
            ;;
    esac
}
