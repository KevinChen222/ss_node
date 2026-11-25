#!/usr/bin/env bash
# PROXYALL_LIB=sb_tx.sh
# 节点事务：配置写锁内的候选副本、校验、统一发布与失败回滚，以及 clash.yaml 节点读写和 SNI 路由适配。由 sb 加载。

# 配置文件端口扫描 (预检是否已被本程序占用)
_check_port_in_config() {
    local port="$1" xray file
    xray=$(_node_candidate_path "$XRAY_CONFIG_FILE") || return 1
    jq -e --arg p "$port" '($p | tonumber) as $port | any(.inbounds[]?; (.port | tonumber?) == $port)' \
        "$xray" >/dev/null 2>&1 && return 0
    for file in "$CONFIG_FILE" "${NODE_RELAY_FILE:-$SINGBOX_DIR/relay.json}"; do
        jq -e --arg p "$port" '($p | tonumber) as $port | any(.inbounds[]?; .listen_port == $port)' \
            "$file" >/dev/null 2>&1 && return 0
    done
    return 1
}

# 综合端口碰撞检测
_check_port_conflict() {
    local port=$1
    local proto=${2:-tcp}
    local silent=${3:-false}
    if _check_port_in_config "$port"; then
        [ "$silent" != "true" ] && _error "端口 ${port} 已被现有节点配置占用。"
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

# --- sb adapters for the shared SNI router ---

_sni_router_error() { _error "$@"; }
_sni_router_info() { _info "$@"; }
_sni_router_status_has_systemd() { command -v systemctl >/dev/null 2>&1; }
_sni_router_validate_https_sni() { _is_valid_reality_domain "$1"; }

_sni_router_require_systemd() {
    _detect_init_system
    if [ "$INIT_SYSTEM" != "systemd" ]; then
        _error "HAProxy SNI 共享入口当前仅支持 systemd。"
        return 1
    fi
}

_sni_router_install_haproxy() {
    _info "正在安装 HAProxy（仅用于 TCP/443 SNI 分流）..."
    _pkg_install haproxy util-linux || {
        _error "HAProxy 安装失败。"
        return 1
    }
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
        if [ -f "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" ] && jq -e --argjson p "$port" \
            '.inbounds[]? | select(.listen_port == $p)' "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" >/dev/null 2>&1; then
            continue
        fi
        if jq -e --argjson p "$port" '.inbounds[]? | select(.port == $p)' "$(_node_candidate_path "$XRAY_CONFIG_FILE")" >/dev/null 2>&1; then continue; fi
        _check_port_occupied "$port" tcp && continue
        printf '%s\n' "$port"
        return 0
    done
    _error "未找到可用的 TLS 回环后端端口。"
    return 1
}

# 节点操作在独立子 shell 内执行。收集输入时不取锁；首次写入前重新核对快照。
_node_tx_nft_snapshot() {
    _node_tx_begin || return 1
    [ -n "${NODE_TX_DIR:-}" ] || return 0
    [ ! -f "$NODE_TX_DIR/nft-touched" ] || return 0
    local tables
    tables=$(nft list tables) || { _node_tx_fail; return 1; }
    if grep -Fxq "table inet $NFT_TABLE" <<< "$tables"; then
        nft list table inet "$NFT_TABLE" > "$NODE_TX_DIR/nft-backup" || { _node_tx_fail; return 1; }
    fi
    touch "$NODE_TX_DIR/nft-touched"
}

_node_tx_fail() {
    [ -z "${NODE_TX_DIR:-}" ] || touch "$NODE_TX_DIR/failed"
    return 0
}
_node_fingerprint() {
    local file
    for file in "$@"; do
        if [ -e "$file" ]; then sha256sum -- "$file" || return 1
        else printf 'missing %s\n' "$file"; fi
    done
}
_node_candidate_path() {
    local i
    if [ "${NODE_TX_STARTED:-0}" = 1 ]; then
        for i in 0 1 2 3 4 9; do
            if [ "$1" = "${NODE_TX_FILES[$i]:-}" ]; then
                printf '%s/candidate.%s\n' "$NODE_TX_DIR" "$i"
                return
            fi
        done
    fi
    printf '%s\n' "$1"
}
_node_tx_file_changed() {
    local i="$1" base="$NODE_TX_DIR/backup.$1"
    [ -f "$base" ] || base="$NODE_TX_DIR/initial.$1"
    [ -f "$NODE_TX_DIR/candidate.$i" ] && [ -f "$base" ] && ! cmp -s "$NODE_TX_DIR/candidate.$i" "$base"
}
_node_tx_begin() {
    [ -n "${NODE_TX_DIR:-}" ] || return 0
    [ ! -f "$NODE_TX_DIR/failed" ] || return 1
    [ "${NODE_TX_STARTED:-0}" != 1 ] || return 0
    _config_write_lock || { _node_tx_fail; return 1; }
    local current i file
    current=$(_node_fingerprint "${NODE_TX_SNAPSHOT_FILES[@]}") || { _node_tx_fail; return 1; }
    [ "$current" = "$NODE_TX_BASE" ] || {
        _error '输入期间配置已变化，请重新选择节点；本次操作未提交。'
        _node_tx_fail; return 1;
    }
    for i in "${!NODE_TX_FILES[@]}"; do
        file=${NODE_TX_FILES[$i]}
        if [ -e "$file" ]; then
            cp -p -- "$file" "$NODE_TX_DIR/backup.$i" || { _node_tx_fail; return 1; }
        fi
    done
    for i in 0 1 2 3 4 9; do
        if [ -s "$NODE_TX_DIR/backup.$i" ] || { [ "$i" != 2 ] && [ -f "$NODE_TX_DIR/backup.$i" ]; }; then
            cp -p -- "$NODE_TX_DIR/backup.$i" "$NODE_TX_DIR/candidate.$i" || { _node_tx_fail; return 1; }
        else
            case "$i" in
                0) printf '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}\n' > "$NODE_TX_DIR/candidate.$i" || { _node_tx_fail; return 1; } ;;
                2) printf '%s\n' '{"proxies":[],"proxy-groups":[{"name":"节点选择","type":"select","proxies":["DIRECT"]}]}' > "$NODE_TX_DIR/candidate.$i" || { _node_tx_fail; return 1; } ;;
                3) printf '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}\n' > "$NODE_TX_DIR/candidate.$i" || { _node_tx_fail; return 1; } ;;
                9) printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}\n' > "$NODE_TX_DIR/candidate.$i" || { _node_tx_fail; return 1; } ;;
                *) printf '{}\n' > "$NODE_TX_DIR/candidate.$i" || { _node_tx_fail; return 1; } ;;
            esac
            cp -p -- "$NODE_TX_DIR/candidate.$i" "$NODE_TX_DIR/initial.$i" || { _node_tx_fail; return 1; }
        fi
    done
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet sing-box && touch "$NODE_TX_DIR/was-running" ;;
        openrc) rc-service sing-box status >/dev/null 2>&1 && touch "$NODE_TX_DIR/was-running" ;;
        direct) _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN" && touch "$NODE_TX_DIR/was-running" ;;
    esac
    if _xray_running; then touch "$NODE_TX_DIR/xray-was-running"; fi
    NODE_TX_STARTED=1
    CONFIG_FILE="$NODE_TX_DIR/candidate.0"
    METADATA_FILE="$NODE_TX_DIR/candidate.1"
    CLASH_YAML_FILE="$NODE_TX_DIR/candidate.2"
    NODE_RELAY_FILE="$NODE_TX_DIR/candidate.3"
    NODE_RELAY_LINKS_FILE="$NODE_TX_DIR/candidate.4"
    if [ -x "$SINGBOX_BIN" ]; then
        local legacy_dns compat_dir="$NODE_TX_DIR/compat"
        legacy_dns=$(jq -s 'any(.[];
            any(.dns.servers[]?; has("address")) or
            any(.dns.rules[]? | .. | objects; has("outbound")))' \
            "$CONFIG_FILE" "$NODE_RELAY_FILE") || { _node_tx_fail; return 1; }
        if [ "$legacy_dns" = true ]; then
            _prepare_core_config_upgrade "$SINGBOX_BIN" "$compat_dir" || { _node_tx_fail; return 1; }
            cp -p "$compat_dir/config.json" "$CONFIG_FILE" &&
                cp -p "$compat_dir/relay.json" "$NODE_RELAY_FILE" || { _node_tx_fail; return 1; }
        fi
    fi
    return 0
}
_node_tx_validate() {
    [ ! -f "$NODE_TX_DIR/failed" ] || return 1
    jq -e '[.inbounds[]?.tag] | length == (unique | length)' "$CONFIG_FILE" >/dev/null || return 1
    jq -se '
        [.[].inbounds[]?.tag] as $tags |
        ($tags | length == (unique | length)) and
        ([.[].route.rules[]? | .. | objects | .inbound? // empty |
          if type == "array" then .[] else . end] |
         all(.[]; . as $tag | $tags | index($tag) != null))
    ' "$CONFIG_FILE" "$NODE_RELAY_FILE" >/dev/null || {
        _error '主配置/中转存在重复 ID 或指向不存在入站的路由。'; return 1;
    }
    local proxies
    proxies=$(${YQ_BINARY} eval -o=json -I=0 '.proxies' "$CLASH_YAML_FILE") || return 1
    jq -e '[.[]?.name] | length == (unique | length)' <<< "$proxies" >/dev/null || return 1
    local catalog
    catalog=$(_node_catalog) || return 1
    jq -e '[.inbounds[]?.tag] | length == (unique | length)' <<< "$catalog" >/dev/null || return 1
    jq -e --argjson config "$catalog" --argjson proxies "$proxies" '
        to_entries | all(.[];
            .key as $tag | .value as $m |
            ([$config.inbounds[] | select(.tag == $tag)] | .[0]) as $ib |
            ($ib != null) and
            ($m.backendPort == null or $m.backendPort == $ib.listen_port) and
            ($m.core == "xray" or $m.frontedBy == "haproxy" or $m.publicPort == null or $m.publicPort == $ib.listen_port) and
            ($m.core != "xray" or ($m.share_link | type == "string" and length > 0)) and
            ($m.clientName == null or $m.yaml == false or
              ([$proxies[] | select(.name == $m.clientName and (.port == ($m.publicPort // $ib.listen_port)))] | length == 1)))
    ' "$METADATA_FILE" >/dev/null || { _error '节点元数据与客户端导出不一致。'; return 1; }
    if [ -x "$SINGBOX_BIN" ]; then
        "$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "$NODE_RELAY_FILE" || return 1
    elif jq -se 'any(.[]; (.inbounds // [] | length) > 0)' "$CONFIG_FILE" "$NODE_RELAY_FILE" >/dev/null 2>&1; then
        _error '未找到 sing-box 内核。'; return 1
    fi
    _xray_validate || return 1
}
_node_tx_publish() {
    [ "${NODE_TX_STARTED:-0}" = 1 ] || return 0
    _node_tx_validate || { _node_tx_fail; return 1; }
    local i file tmp
    # 验证所有候选之后才逐文件提交；EXIT 回滚覆盖任一提交中断。
    touch "$NODE_TX_DIR/published" || { _node_tx_fail; return 1; }
    for i in 0 1 2 3 4 9; do
        [ -n "${NODE_TX_FILES[$i]:-}" ] || continue
        _node_tx_file_changed "$i" || continue
        if [ "$i" = 9 ] && [ ! -f "$NODE_TX_DIR/backup.9" ] && ! jq -e '.inbounds | length > 0' "$NODE_TX_DIR/candidate.9" >/dev/null; then continue; fi
        file=${NODE_TX_FILES[$i]}
        if [ -f "$file" ] && cmp -s "$NODE_TX_DIR/candidate.$i" "$file"; then continue; fi
        tmp=$(mktemp "${file}.XXXXXX") || { _node_tx_fail; return 1; }
        if ! cp -p -- "$NODE_TX_DIR/candidate.$i" "$tmp" || ! touch "$NODE_TX_DIR/published.$i" || ! mv -- "$tmp" "$file"; then
            rm -f -- "$tmp"; _node_tx_fail; return 1
        fi
    done
}

_node_tx_finish() {
    local status="$1" i file failed=0
    trap - EXIT INT TERM HUP
    if [ "${NODE_TX_COMMITTED:-0}" != 1 ] && [ ! -f "$NODE_TX_DIR/published" ] &&
       [ ! -f "$NODE_TX_DIR/router-touched" ] && [ ! -f "$NODE_TX_DIR/nginx-paths" ] &&
       [ ! -f "$NODE_TX_DIR/service-touched" ] && [ ! -f "$NODE_TX_DIR/xray-touched" ] &&
       [ ! -f "$NODE_TX_DIR/nft-touched" ] && [ ! -f "$NODE_TX_DIR/created-files" ]; then
        # 候选文件尚未发布，无需覆盖原件或重启任何服务。
        NODE_TX_STARTED=0
    fi
    if [ "${NODE_TX_STARTED:-0}" = 1 ] && [ "${NODE_TX_COMMITTED:-0}" != 1 ]; then
        _error '节点操作失败或中断，正在恢复配置与路由。'
        CONFIG_FILE=${NODE_TX_FILES[0]:-$SINGBOX_DIR/config.json}; METADATA_FILE=${NODE_TX_FILES[1]}
        CLASH_YAML_FILE=${NODE_TX_FILES[2]}; NODE_RELAY_FILE=${NODE_TX_FILES[3]:-$SINGBOX_DIR/relay.json}
        for i in "${!NODE_TX_FILES[@]}"; do
            if [ ! -f "$NODE_TX_DIR/published.$i" ]; then
                case "$i" in
                    5|6) [ -f "$NODE_TX_DIR/router-touched" ] || continue ;;
                    7|8) [ -f "$NODE_TX_DIR/nft-touched" ] || continue ;;
                    *) continue ;;
                esac
            fi
            file=${NODE_TX_FILES[$i]}
            if [ -f "$NODE_TX_DIR/backup.$i" ]; then
                cp -p -- "$NODE_TX_DIR/backup.$i" "$file" || failed=1
            else rm -f -- "$file" || failed=1; fi
        done
        if [ -f "$NODE_TX_DIR/nft-touched" ]; then
            if [ -s "$NODE_TX_DIR/nft-backup" ]; then
                { printf 'delete table inet %s\n' "$NFT_TABLE"; cat "$NODE_TX_DIR/nft-backup"; } > "$NODE_TX_DIR/nft-restore"
                nft -f "$NODE_TX_DIR/nft-restore" || failed=1
            else nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || failed=1; fi
        fi
        NODE_TX_STARTED=0
        if [ -f "$NODE_TX_DIR/created-files" ]; then
            local created_path
            while IFS= read -r created_path; do
                [ -z "$created_path" ] || rm -f -- "$created_path" || failed=1
            done < "$NODE_TX_DIR/created-files"
        fi
        _xhttp_restore_nginx || failed=1
        if [ -f "$NODE_TX_DIR/service-touched" ]; then
            if [ -f "$NODE_TX_DIR/was-running" ]; then _manage_singbox_service_impl restart || failed=1
            else _manage_singbox_service_impl stop || failed=1; fi
        fi
        if [ -f "$NODE_TX_DIR/xray-touched" ]; then
            if [ -f "$NODE_TX_DIR/xray-was-running" ]; then _xray_service restart || failed=1
            else _xray_service stop || failed=1; fi
        fi
        if [ -f "$NODE_TX_DIR/router-touched" ]; then
            if [ -f "$SNI_ROUTER_STATE_FILE" ]; then _sni_router_apply || failed=1
            else systemctl stop haproxy >/dev/null 2>&1 8>&- 9>&- || failed=1; fi
        fi
        [ "$status" -ne 0 ] || status=1
    fi
    if [ "$failed" = 0 ]; then rm -rf -- "$NODE_TX_DIR"
    else _error "自动恢复未完全成功；受保护备份保留在 $NODE_TX_DIR"; status=1; fi
    exit "$status"
}
_node_operation() {
    if [ -n "${NODE_TX_DIR:-}" ]; then "$@"; else _node_operation_impl "$@"; fi
}

_node_operation_impl() (
    local NODE_TX_DIR NODE_TX_BASE NODE_TX_STARTED=0 NODE_TX_COMMITTED=0 status=0
    local NODE_TX_FILES=("$CONFIG_FILE" "$METADATA_FILE" "$CLASH_YAML_FILE"
        "${SINGBOX_DIR}/relay.json" "${SINGBOX_DIR}/relay_links.json"
        "$SNI_ROUTER_STATE_FILE" "$SNI_ROUTER_HAPROXY_CONF"
        "$NFT_PERSIST_FILE" "${NODE_NFT_CONFIG_FILE:-/etc/nftables.conf}"
        "$XRAY_CONFIG_FILE")
    NODE_TX_DIR=$(mktemp -d "${SINGBOX_DIR}/.node-op.XXXXXX") || exit 1
    chmod 700 "$NODE_TX_DIR" || exit 1
    trap '_node_tx_finish "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    local -a NODE_TX_SNAPSHOT_FILES=("${NODE_TX_FILES[@]}")
    NODE_TX_BASE=$(_node_fingerprint "${NODE_TX_SNAPSHOT_FILES[@]}") || exit 1
    "$@" || status=$?
    if [ -f "$NODE_TX_DIR/cancelled" ]; then exit 2; fi
    [ ! -f "$NODE_TX_DIR/failed" ] || status=1
    if [ "$status" = 0 ] && [ "$NODE_TX_STARTED" = 1 ]; then
        local changed=false i
        for i in 0 1 2 3 4 9; do
            _node_tx_file_changed "$i" && changed=true
        done
        if [ "$changed" = false ] && [ ! -f "$NODE_TX_DIR/router-touched" ] && [ ! -f "$NODE_TX_DIR/nginx-paths" ] &&
           [ ! -f "$NODE_TX_DIR/xray-touched" ] && [ ! -f "$NODE_TX_DIR/service-touched" ] && [ ! -f "$NODE_TX_DIR/nft-touched" ] &&
           [ ! -f "$NODE_TX_DIR/created-files" ]; then
            NODE_TX_COMMITTED=1
            exit 0
        fi
        _node_tx_publish && _manage_service restart || status=1
    fi
    if [ "$status" = 0 ]; then
        NODE_TX_COMMITTED=1
        [ "$NODE_TX_STARTED" != 1 ] || _success '节点操作已提交，配置校验与服务重启通过。'
        [ ! -s "$NODE_TX_DIR/share-links" ] || cat "$NODE_TX_DIR/share-links"
    fi
    exit "$status"
)

# 原子修改 JSON/YAML 文件
_atomic_modify_json() {
    if [ -n "${NODE_TX_DIR:-}" ]; then _atomic_modify_json_impl "$@"
    else ( _config_write_lock || exit 1; _atomic_modify_json_impl "$@" ); fi
}

_atomic_modify_json_impl() {
    _node_tx_begin || return 1
    local file="$1" filter="$2" tmp
    file=$(_node_candidate_path "$file")
    [ -f "$file" ] || { _node_tx_fail; return 1; }
    tmp=$(mktemp "${file}.XXXXXX") || { _node_tx_fail; return 1; }
    if jq "$filter" "$file" > "$tmp" &&
       jq -e 'if has("inbounds") then ([.inbounds[].tag] | length == (unique | length)) else true end' "$tmp" >/dev/null &&
       mv -- "$tmp" "$file"; then
        return 0
    fi
    _error "修改 JSON 失败或入站 ID 冲突: $file"
    rm -f -- "$tmp"
    _node_tx_fail
    return 1
}
_atomic_modify_yaml() {
    if [ -n "${NODE_TX_DIR:-}" ]; then _atomic_modify_yaml_impl "$@"
    else ( _config_write_lock || exit 1; _atomic_modify_yaml_impl "$@" ); fi
}

_atomic_modify_yaml_impl() {
    _node_tx_begin || return 1
    local file="$1" filter="$2" tmp
    file=$(_node_candidate_path "$file")
    [ -f "$file" ] || { _node_tx_fail; return 1; }
    tmp=$(mktemp "${file}.XXXXXX") || { _node_tx_fail; return 1; }
    if ${YQ_BINARY} eval "$filter" "$file" > "$tmp" &&
       ${YQ_BINARY} eval '.' "$tmp" >/dev/null && mv -- "$tmp" "$file"; then
        return 0
    fi
    _error "修改 YAML 失败: $file"
    rm -f -- "$tmp"
    _node_tx_fail
    return 1
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

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" >/dev/null 2>&1 || \
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
    _node_tx_begin || return 1
    _sni_router_require_systemd || return 1
    _sni_router_migrate_existing_reality || return 1
    [ -z "${NODE_TX_DIR:-}" ] || touch "$NODE_TX_DIR/router-touched" || return 1
    _sni_router_prepare_routes
}

# Clash YAML 节点管理
_get_proxy_field() {
    local proxy_name="$1" field="$2"
    export PROXY_NAME="$proxy_name"
    ${YQ_BINARY} eval '.proxies[] | select(.name == strenv(PROXY_NAME)) | '"$field" "${CLASH_YAML_FILE}" 2>/dev/null | head -n 1
}
_add_node_to_yaml() {
    local proxy_json="$1"
    local proxy_name
    proxy_name=$(jq -er .name <<< "$proxy_json") || return 1
    export PROXY_NAME="$proxy_name"
    local existing
    existing=$(${YQ_BINARY} eval -o=json -I=0 '[.proxies[] | select(.name == strenv(PROXY_NAME))] | length' "$CLASH_YAML_FILE") || return 1
    [ "$existing" = 0 ] || { _error "客户端名称已存在: $proxy_name"; return 1; }
    _atomic_modify_yaml "$CLASH_YAML_FILE" ".proxies |= . + [${proxy_json}]" || return 1
    if [ -n "${tag:-}" ]; then
        local mapping
        mapping=$(jq -nc --arg t "$tag" --arg n "$proxy_name" '.[$t]={name:$n,clientName:$n,yaml:true}') || return 1
        _atomic_modify_json "$METADATA_FILE" ". * $mapping" || return 1
    fi
    export PROXY_NAME="$proxy_name"
    _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxy-groups[] | select(.name == "节点选择") | .proxies) |= (. + [strenv(PROXY_NAME)] | unique)'
}
_remove_node_from_yaml() {
    local proxy_name="$1"
    export PROXY_NAME="$proxy_name"
    _atomic_modify_yaml "$CLASH_YAML_FILE" 'del(.proxies[] | select(.name == strenv(PROXY_NAME)))' || return 1
    _atomic_modify_yaml "$CLASH_YAML_FILE" 'del(.proxy-groups[] | select(.name == "节点选择") | .proxies[] | select(. == strenv(PROXY_NAME)))'
}
_find_proxy_name() {
    local port="$1" type="$2" tag="$3" inbound metadata proxies matches count
    # yaml:false 是显式禁用，不能用 // empty（会吞掉 false）。
    metadata=$(jq -ce --arg t "$tag" '.[$t] // {}' "$METADATA_FILE") || return 1
    [ "$(jq -r '.yaml == false' <<< "$metadata")" != true ] || return 0
    inbound=$(_node_catalog | jq -ce --arg t "$tag" '[.inbounds[] | select(.tag == $t)] | if length == 1 then .[0] else error("入站 ID 不唯一") end') || return 1
    proxies=$(${YQ_BINARY} eval -o=json -I=0 '.proxies' "$CLASH_YAML_FILE") || return 1
    # 新节点使用显式映射；旧节点使用协议和凭据核对，SNI 可用时也必须一致。
    matches=$(jq -c --argjson ib "$inbound" --argjson meta "$metadata" '
        [.[] | select(.type == (if $ib.type == "shadowsocks" then "ss" elif $ib.type == "socks" then "socks5" else $ib.type end))
         | select(if $meta.clientName then .name == $meta.clientName else true end)
         | select(if $ib.type == "vless" or $ib.type == "vmess" then
                      ($ib.users[0].uuid != null and .uuid == $ib.users[0].uuid)
                  elif $ib.type == "tuic" then
                      (.uuid == $ib.users[0].uuid and .password == $ib.users[0].password)
                  elif $ib.type == "shadowsocks" then
                      (.cipher == $ib.method and .password == $ib.password)
                  elif $ib.type == "socks" then
                      ($ib.users[0].username != null and .username == $ib.users[0].username and .password == $ib.users[0].password)
                  else ($ib.users[0].password != null and .password == $ib.users[0].password) end)
         | ($meta.server_name // $ib.tls.server_name // "") as $sni
         | select($sni == "" or (.sni // .servername // "") == $sni)]
    ' <<< "$proxies") || return 1
    count=$(jq 'length' <<< "$matches") || return 1
    if [ "$count" != 1 ]; then
        _error "节点 ${tag} 的客户端关联不唯一（${count} 项）；请核对协议、凭据、SNI 和 metadata.clientName。"
        return 1
    fi
    # 即使凭据唯一，也不能允许相同名称删除另一条 YAML。
    local name
    name=$(jq -r '.[0].name' <<< "$matches") || return 1
    [ "$(jq --arg n "$name" '[.[] | select(.name == $n)] | length' <<< "$proxies")" = 1 ] || {
        _error "客户端名称重复: $name"; return 1;
    }
    printf '%s\n' "$name"
}

_new_node_tag() {
    local prefix="$1" id tag xray
    id=$(openssl rand -hex 16) || return 1
    tag="${prefix}-${id}"
    [ ! -f "$CONFIG_FILE" ] || jq -e --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length == 0' "$CONFIG_FILE" >/dev/null || return 1
    xray=$(_node_candidate_path "$XRAY_CONFIG_FILE") || return 1
    [ ! -f "$xray" ] || jq -e --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length == 0' "$xray" >/dev/null || return 1
    [ ! -f "$METADATA_FILE" ] || jq -e --arg t "$tag" 'has($t) | not' "$METADATA_FILE" >/dev/null || return 1
    [ ! -e "${SINGBOX_DIR}/${tag}.pem" ] && [ ! -e "${SINGBOX_DIR}/${tag}.key" ] || return 1
    printf '%s\n' "$tag"
}

_assert_node_name_free() {
    local name="$1" proxies
    [ -n "$name" ] || return 1
    _ensure_node_yq || return 1
    jq -e --arg n "$name" '[.[] | select(.name == $n or .clientName == $n)] | length == 0' "$METADATA_FILE" >/dev/null || {
        _error "节点名称已存在: $name"; return 1;
    }
    proxies=$(${YQ_BINARY} eval -o=json -I=0 '.proxies' "$CLASH_YAML_FILE") || return 1
    jq -e --arg n "$name" '[.[] | select(.name == $n)] | length == 0' <<< "$proxies" >/dev/null || {
        _error "客户端名称已存在: $name"; return 1;
    }
}

_ensure_node_yq() {
    command -v "$YQ_BINARY" >/dev/null || ( _config_write_lock && _install_yq )
}
