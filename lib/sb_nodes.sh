#!/usr/bin/env bash
# PROXYALL_LIB=sb_nodes.sh
# 节点通用管理：分享链接、查看、删除、改端口、编辑菜单与批量创建。由 sb 加载。

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
_get_ip() { _get_public_ip; } # 别名兼容

# 注意: _atomic_modify_json, _atomic_modify_yaml, _get_proxy_field, _add_node_to_yaml, _remove_node_from_yaml
# 均在上方统一定义，此处不再重复定义以避免不一致

_ss_share_link() {
    local proxy_name="$1" proxy_json server port name userinfo query plugin smux
    proxy_json=$(PROXY_NAME="$proxy_name" "$YQ_BINARY" eval -o=json -I=0 \
        '[.proxies[] | select(.name == strenv(PROXY_NAME))]' "$CLASH_YAML_FILE") || return 1
    proxy_json=$(jq -ce 'if length == 1 and .[0].type == "ss" then .[0] else empty end' <<< "$proxy_json") || {
        _error "找不到 mihomo 节点配置: ${proxy_name}"
        return 1
    }
    server=$(jq -r '.server' <<< "$proxy_json")
    server="${server#[}"; server="${server%]}"
    [[ "$server" != *:* ]] || server="[$server]"
    port=$(jq -r '.port' <<< "$proxy_json")
    name=$(jq -r '.name' <<< "$proxy_json")
    userinfo=$(jq -jr '.cipher + ":" + .password' <<< "$proxy_json" | base64 | tr -d '\n\r=' | tr '+/' '-_') || return 1
    query="udp=$(jq -r 'if .udp == true then 1 else 0 end' <<< "$proxy_json")"
    smux=$(jq -c '.smux // empty' <<< "$proxy_json")
    [ -z "$smux" ] || query="${query}&smux=$(_url_encode "$smux")"
    plugin=$(jq -r 'if .plugin == "shadow-tls" then
        "shadow-tls;host=" + .["plugin-opts"].host + ";password=" + .["plugin-opts"].password
        + ";version=" + (.["plugin-opts"].version | tostring) else empty end' <<< "$proxy_json") || return 1
    [ -z "$plugin" ] || query="${query}&plugin=$(_url_encode "$plugin")"
    printf 'ss://%s@%s:%s/?%s#%s\n' "$userinfo" "$server" "$port" "$query" "$(_url_encode "$name")"
}

_anytls_share_link() {
    local name="$1" cert="$2" proxy pin=""
    proxy=$(PROXY_NAME="$name" "$YQ_BINARY" eval -o=json -I=0 \
        '[.proxies[] | select(.name == strenv(PROXY_NAME) and .type == "anytls")]' "$CLASH_YAML_FILE") || return 1
    proxy=$(jq -ce 'select(length == 1) | .[0]' <<< "$proxy") || return 1
    if jq -e '.["skip-cert-verify"] == true' <<< "$proxy" >/dev/null; then
        pin=$(_cert_sha256_hex "$cert")
        [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || { _error '无法读取 AnyTLS 证书指纹，未生成跳过证书验证的链接。'; return 1; }
        pin="&insecure=1&pcs=$pin"
    fi
    jq -er --arg pin "$pin" '
        (.server | ltrimstr("[") | rtrimstr("]") | if contains(":") then "["+.+"]" else . end) as $host |
        ({sni:.sni, fp:.["client-fingerprint"], alpn:(.alpn // [] | join(",")),
         udp:(if .udp == null then null elif .udp then 1 else 0 end),
         "idle-session-check-interval":.["idle-session-check-interval"],
         "idle-session-timeout":.["idle-session-timeout"], "min-idle-session":.["min-idle-session"]} |
        to_entries | map(select(.value != null and .value != "") | .key+"="+(.value|tostring|@uri)) | join("&")) as $query |
        "anytls://\(.password|@uri)@\($host):\(.port)/?\($query)\($pin)#\(.name|@uri)"' <<< "$proxy"
}

_naive_share_link() {
    local scheme="$1" username="$2" password="$3" domain="$4" port="$5" name="$6"
    local enc_user enc_pass enc_name
    enc_user=$(_url_encode "$username") || return 1
    enc_pass=$(_url_encode "$password") || return 1
    enc_name=$(_url_encode "$name") || return 1
    printf '%s://%s:%s@%s:%s?padding=1#%s\n' "$scheme" "$enc_user" "$enc_pass" "$domain" "$port" "$enc_name"
}

_naive_singbox_json() {
    local mode="$1" username="$2" password="$3" domain="$4" port="$5" name="$6"
    if [ "$mode" = "quic" ]; then
        jq -cn \
            --arg tag "${name}-QUIC" \
            --arg server "$domain" \
            --arg p "$port" \
            --arg user "$username" \
            --arg pass "$password" \
            '{type:"naive",tag:$tag,server:$server,server_port:($p|tonumber),username:$user,password:$pass,udp_over_tcp:true,quic:true,quic_congestion_control:"bbr",tls:{enabled:true,server_name:$server}}'
    else
        jq -cn \
            --arg tag "$name" \
            --arg server "$domain" \
            --arg p "$port" \
            --arg user "$username" \
            --arg pass "$password" \
            '{type:"naive",tag:$tag,server:$server,server_port:($p|tonumber),username:$user,password:$pass,udp_over_tcp:true,quic:false,tls:{enabled:true,server_name:$server}}'
    fi
}

_naive_substore_json() {
    local mode="$1" username="$2" password="$3" domain="$4" port="$5" name="$6"
    if [ "$mode" = "quic" ]; then
        jq -cn \
            --arg name "${name}-QUIC" \
            --arg server "$domain" \
            --arg p "$port" \
            --arg user "$username" \
            --arg pass "$password" \
            '{name:$name,type:"naive",server:$server,port:($p|tonumber),username:$user,password:$pass,sni:$server,"udp-over-tcp":true,quic:true,"quic-congestion-control":"bbr"}'
    else
        jq -cn \
            --arg name "$name" \
            --arg server "$domain" \
            --arg p "$port" \
            --arg user "$username" \
            --arg pass "$password" \
            '{name:$name,type:"naive",server:$server,port:($p|tonumber),username:$user,password:$pass,sni:$server,"udp-over-tcp":true,quic:false}'
    fi
}

_naive_export_block() {
    local url="$1" quic_url="$2" username="$3" password="$4" domain="$5" port="$6" name="$7" naive_network="${8:-tcp}"
    local sb_h2="" sb_quic="" sub_h2="" sub_quic=""
    if [ -n "$username" ] && [ -n "$password" ] && [ -n "$domain" ] && [ -n "$port" ]; then
        sb_h2=$(_naive_singbox_json "h2" "$username" "$password" "$domain" "$port" "$name") || return 1
        sub_h2=$(_naive_substore_json "h2" "$username" "$password" "$domain" "$port" "$name") || return 1
        if [ "$naive_network" = "both" ]; then
            sb_quic=$(_naive_singbox_json "quic" "$username" "$password" "$domain" "$port" "$name") || return 1
            sub_quic=$(_naive_substore_json "quic" "$username" "$password" "$domain" "$port" "$name") || return 1
        fi
    fi

    printf '\n%b═══════════════════ NaiveProxy 分享链接 ═══════════════════%b\n' "$YELLOW" "$NC"
    if [ -n "$url" ]; then
        printf '%b[HTTP/2 (TCP)]%b\n%b%s%b\n' "$GREEN" "$NC" "$CYAN" "$url" "$NC"
    fi
    if [ -n "$quic_url" ]; then
        printf '%b[HTTP/3 (QUIC/UDP)]%b\n%b%s%b\n' "$GREEN" "$NC" "$CYAN" "$quic_url" "$NC"
    fi
    if [ -n "$sb_h2" ]; then
        printf '%b─────────────────── sing-box 出站 JSON ───────────────────%b\n' "$YELLOW" "$NC"
        printf '%b[sing-box HTTP/2 (TCP)]%b\n%b%s%b\n' "$GREEN" "$NC" "$CYAN" "$sb_h2" "$NC"
        if [ -n "$sb_quic" ]; then
            printf '%b[sing-box HTTP/3 (QUIC/UDP)]%b\n%b%s%b\n' "$GREEN" "$NC" "$CYAN" "$sb_quic" "$NC"
        fi
    fi
    if [ -n "$sub_h2" ]; then
        printf '%b─────────────────── Sub-Store 节点 JSON ──────────────────%b\n' "$YELLOW" "$NC"
        printf '%b[Sub-Store HTTP/2 (TCP)]%b\n%b%s%b\n' "$GREEN" "$NC" "$CYAN" "$sub_h2" "$NC"
        if [ -n "$sub_quic" ]; then
            printf '%b[Sub-Store HTTP/3 (QUIC/UDP)]%b\n%b%s%b\n' "$GREEN" "$NC" "$CYAN" "$sub_quic" "$NC"
        fi
    fi
    printf '%b══════════════════════════════════════════════════════════%b\n' "$YELLOW" "$NC"
    printf '%b[提示] mihomo 不支持 NaiveProxy，本节点未写入 clash.yaml；以上 JSON 可直接复制到 sing-box 或 Sub-Store。%b\n' "$YELLOW" "$NC"
}

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
    local quic_url=""
    
    case "$type" in
        "vless-reality")
            # 参数: uuid, sni, public_key, short_id, flow
            local uuid="$1" pk="$3" sid="$4" flow="${5:-xtls-rprx-vision}"
            # 对 SNI 执行终极保底与净化
            local sni=$(echo "$2" | xargs)
            [[ -z "$sni" ]] && sni="$DEFAULT_SNI"
            
            url="vless://${uuid}@${link_ip}:${port}?security=reality&encryption=none&pbk=$(_url_encode "${pk}")&fp=firefox&type=tcp&flow=${flow}&sni=${sni}&sid=${sid}#$(_url_encode "$name")"
            ;;
        vless-xhttp-tls|vless-xhttp-reality)
            local uuid="$1" sni="$2" path="$3" security="${type#vless-xhttp-}"
            local concurrency="${4:-}" reality_query="" extra="" encryption
            if [ "$security" = reality ]; then
                reality_query="&pbk=$(_url_encode "$4")&sid=$5&support-x25519mlkem768=true"
                concurrency="${6:-}"
            fi
            encryption=$(_get_proxy_field "$name" '.encryption // "none"') || return 1
            if [ -n "$concurrency" ]; then
                extra=$(jq -nc --arg concurrency "$concurrency" '{xmux:{maxConcurrency:$concurrency,hMaxReusableSecs:1800}}') || return 1
                extra="&extra=$(_url_encode "$extra")"
            fi
            url="vless://${uuid}@${link_ip}:${port}?encryption=$(_url_encode "$encryption")&security=${security}&type=xhttp&mode=stream-up&path=$(_url_encode "$path")&host=${sni}&sni=${sni}&alpn=h2&fp=chrome${reality_query}${extra}#$(_url_encode "$name")"
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
            url="vless://${uuid}@${link_ip}:${port}?security=none&encryption=none&type=tcp#$(_url_encode "$name")"
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
            url=$(_anytls_share_link "$name" "$4") || return 1
            ;;
        "any-reality")
            # 参数: password, sni, public_key, short_id
            local password="$1" sni="${2:-$DEFAULT_SNI}" public_key="$3" short_id="$4"
            url="anytls://$(_url_encode "$password")@${link_ip}:${port}?security=reality&sni=${sni}&fp=firefox&pbk=$(_url_encode "${public_key}")&sid=${short_id}&type=tcp&headerType=none#$(_url_encode "$name")"
            ;;
        "shadowsocks"|"shadowsocks-shadowtls")
            url=$(_ss_share_link "$name") || return 1
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
        "naive")
            # 参数: username, password, naive_network (tcp|both)
            local username="$1" password="$2" naive_network="${3:-tcp}"
            url=$(_naive_share_link "naive+https" "$username" "$password" "$link_ip" "$port" "$name") || return 1
            if [ "$naive_network" = "both" ]; then
                quic_url=$(_naive_share_link "naive+quic" "$username" "$password" "$link_ip" "$port" "$name") || return 1
            fi
            ;;
    esac
    if [ -n "$url" ]; then
        local clean_url display_block
        clean_url=$(echo "$url" | sed 's/&insecure=1//g' | sed 's/&pcs=[a-fA-F0-9]*//g')
        if [ "$type" = "naive" ]; then
            display_block=$(_naive_export_block "$url" "$quic_url" "$username" "$password" "$link_ip" "$port" "$name" "$naive_network") || return 1
        elif [ "$clean_url" != "$url" ] && [[ "$type" != "anytls" ]] && [[ "$type" != "hysteria2" ]] && [[ "$type" != "tuic" ]] && [[ "$type" != "vless-reality" ]] && [[ "$type" != "any-reality" ]] && [[ "$type" != "naive" ]]; then
            display_block=$(printf '\n%b═══════════════ 🔗 直连分享链接 (含防劫持指纹) ═══════════════%b\n%b%s%b\n%b══════════════════════════════════════════════════════════════%b\n\n%b═════════════ 🔗 CF优选专用链接 (纯净版，无指纹冲突) ═════════════%b\n%b%s%b\n%b══════════════════════════════════════════════════════════════%b\n%b[提示] 如果您套用了 Cloudflare，请导入 %bCF优选专用链接%b 以避免握手失败！%b\n' \
                "$YELLOW" "$NC" "$CYAN" "$url" "$NC" "$YELLOW" "$NC" \
                "$YELLOW" "$NC" "$CYAN" "$clean_url" "$NC" "$YELLOW" "$NC" \
                "$CYAN" "$YELLOW" "$CYAN" "$NC")
        else
            display_block=$(printf '\n%b═══════════════════ 分享链接 ═══════════════════%b\n%b%s%b\n%b═════════════════════════════════════════════════%b\n' \
                "$YELLOW" "$NC" "$CYAN" "$url" "$NC" "$YELLOW" "$NC")
        fi

        # [持久化] 将生成的链接存入元数据，防止查看时由于动态提取导致的 SNI 丢失
        if [ -n "$tag" ] && [ "$tag" != "null" ]; then
            local entry
            if [ -n "$quic_url" ]; then
                entry=$(jq -nc --arg tag "$tag" --arg url "$url" --arg qurl "$quic_url" '{($tag):{share_link:$url,share_link_quic:$qurl}}') || return 1
            else
                entry=$(jq -nc --arg tag "$tag" --arg url "$url" '{($tag):{share_link:$url}}') || return 1
            fi
            if [[ "$tag" == argo-* ]]; then
                _atomic_modify_json "$ARGO_METADATA_FILE" ". * $entry" || return 1
            else
                _atomic_modify_json "$METADATA_FILE" ". * $entry" || return 1
            fi
        fi

        if [ -n "${NODE_TX_DIR:-}" ]; then
            printf '%s\n' "$display_block" >> "$NODE_TX_DIR/share-links"
        else
            printf '%s\n' "$display_block"
        fi
    fi
}

# 将两种内核的监听端口归入同一冲突检查，并保留历史 Xray 原生节点的匹配字段。
_node_catalog() {
    local xray proj
    xray=$(_node_candidate_path "$XRAY_CONFIG_FILE")
    if [ ! -f "$xray" ]; then
        if [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else printf '{"inbounds":[]}\n'; fi
        return
    fi
    proj='{
        tag, type:.protocol, listen:.listen, listen_port:.port,
        method:.settings.method, password:.settings.password,
        users:(
            if .protocol == "socks" then [(.settings.accounts[0]? // {} | {username:.user, password:.pass})]
            elif .protocol == "trojan" then [(.settings.clients[0]? // {} | {password:.password})]
            else [(.settings.clients[0]? // {} | {uuid:.id, flow:.flow})]
            end
        ),
        transport:{
            type:.streamSettings.network,
            path:(.streamSettings.xhttpSettings.path // .streamSettings.wsSettings.path),
            service_name:.streamSettings.grpcSettings.serviceName
        }
    }'
    if [ ! -f "$CONFIG_FILE" ]; then
        jq "{inbounds:[.inbounds[] | ${proj}]}" "$xray"
        return
    fi
    jq -s ".[0] as \$sb | .[1] as \$xr | \$sb | .inbounds += [\$xr.inbounds[] | ${proj}]" "$CONFIG_FILE" "$xray"
}

_view_nodes() {
    if ! _node_catalog | jq -e '.inbounds | length > 0' >/dev/null 2>&1; then _warning "当前没有任何节点。"; return; fi
    
    # 统计有效节点数量（排除辅助节点）
    local node_count=$(_node_catalog | jq '[.inbounds[] | select(.tag | contains("-hop-") | not) | select(.listen_port != null)] | length')
    _info "--- 当前节点信息 (共 ${node_count} 个) ---"
    
    # [关键修复] 确保在查看前清空之前的临时链接缓存
    local links_tmp
    links_tmp=$(mktemp) || return 1
    
    # [资源优化] 传递紧凑 JSON，循环内用单次 jq 提取 tag/type/port (3次→1次)
    _node_catalog | jq -c '.inbounds[]' | while IFS= read -r node; do
        # 合并3次字段提取为1次
        local _base_fields
        _base_fields=$(echo "$node" | jq -r '[.tag, .type, (.listen_port|tostring)] | @tsv')
        local tag type port
        IFS=$'\t' read -r tag type port <<< "$_base_fields"
        
        # 过滤掉多端口监听生成的辅助节点（跳过 tag 中包含 -hop- 的节点）
        if [[ "$tag" == *"-hop-"* ]]; then continue; fi
        local ss_tag=""
        if [ "$type" = shadowtls ]; then
            ss_tag=$(jq -r '.detour' <<< "$node")
            node=$(_node_catalog | jq -ce --argjson wrapper "$node" '
                .inbounds[] | select(.tag == $wrapper.detour and .type == "shadowsocks")
                | . + {tag:$wrapper.tag,listen_port:$wrapper.listen_port}') || continue
            type=shadowsocks
        elif [ "$type" = shadowsocks ] && [ "$port" = null ]; then
            continue
        fi

        # HAProxy 共享节点的 Sing-box 实际监听端口是回环后端端口；客户端必须使用 publicPort。
        local backend_port="$port"
        local public_port
        public_port=$(jq -r --arg t "$tag" --argjson fallback "$port" '.[$t].publicPort // $fallback' "$METADATA_FILE" 2>/dev/null)
        [ -n "$public_port" ] && [ "$public_port" != "null" ] && port="$public_port"
        
        # 使用统一查找函数
        local proxy_name_to_find=$(_find_proxy_name "$port" "$type" "${ss_tag:-$tag}")

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
        local naive_net="" naive_domain="" naive_label="" naive_user="" naive_pass=""
        if [ "$type" = "naive" ]; then
            naive_domain=$(jq -r --arg t "$tag" '.[$t].domain // .[$t].server_name // empty' "$METADATA_FILE" 2>/dev/null)
            [ -n "$naive_domain" ] || naive_domain=$(jq -r '.tls.server_name // empty' <<< "$node")
            naive_user=$(jq -r '.users[0].username // empty' <<< "$node")
            naive_pass=$(jq -r '.users[0].password // empty' <<< "$node")
            naive_net=$(jq -r --arg t "$tag" '.[$t].naiveNetwork // empty' "$METADATA_FILE" 2>/dev/null)
            if [ -z "$naive_net" ]; then
                if [ "$(jq -r '.network // empty' <<< "$node")" = "tcp" ]; then naive_net="tcp"; else naive_net="both"; fi
            fi
            if [ "$naive_net" = "both" ]; then
                naive_label="NaiveProxy (H2+H3)"
            else
                naive_label="NaiveProxy (H2)"
            fi
            _info " 协议: ${naive_label} | 域名/SNI: ${naive_domain} | 公网端口: ${port}"
        fi
        if [ "$backend_port" != "$port" ]; then
            if [ "$(jq -r --arg t "$tag" '.[$t].routerRole // empty' "$METADATA_FILE")" = xhttp-https ]; then
                _info " 入口: 公网 ${port} -> Nginx -> Xray 127.0.0.1:${backend_port}"
            else
                _info " 入口: 公网 ${port} -> HAProxy -> 127.0.0.1:${backend_port}"
            fi
        fi
        local url=""
        local quic_url=""
        
        # [新架构] 优先使用持久化生成的链接（从极源解决动态提取可能存在的 SNI 丢失死角）
        if [ "$type" = shadowsocks ]; then
            url=$(_ss_share_link "$proxy_name_to_find") || continue
        elif [ "$type" = anytls ] && [ -n "$proxy_name_to_find" ] &&
             jq -e '.tls.enabled and (.tls.reality.enabled != true)' <<< "$node" >/dev/null; then
            url=$(_anytls_share_link "$proxy_name_to_find" "$(jq -r '.tls.certificate_path // empty' <<< "$node")") || continue
        else
            url=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$METADATA_FILE")
            if [ "$type" = "naive" ]; then
                quic_url=$(jq -r --arg t "$tag" '.[$t].share_link_quic // empty' "$METADATA_FILE")
            fi
        fi
        if { [ -z "$url" ] || [ "$url" == "null" ]; } && [[ "$tag" == argo-* ]] && [ -f "$ARGO_METADATA_FILE" ]; then
            url=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
        fi
        if [ "$type" = "naive" ] && [ "$naive_net" = "both" ] && { [ -z "$quic_url" ] || [ "$quic_url" = "null" ]; }; then
            if [ -n "$naive_user" ] && [ -n "$naive_pass" ] && [ -n "$naive_domain" ]; then
                quic_url=$(_naive_share_link "naive+quic" "$naive_user" "$naive_pass" "$naive_domain" "$port" "$display_name") || quic_url=""
            fi
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
             # Tab 属于 IFS 空白；连续的空列不能折叠，否则 SNI 和传输参数会错位。
             IFS=$'\x1f' read -r uuid flow is_reality transport_type tls_enabled tls_sn cert_path ws_path grpc_service_name <<< "${_vless_fields//$'\t'/$'\x1f'}"
                
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
                    url="vless://${uuid}@${link_ip}:${port}?security=none&encryption=none&type=tcp#$(_url_encode "$display_name")"
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
                _warning "缺少 ${display_name} 的客户端映射或原始分享链接，无法重建完整 AnyTLS 链接。"
                ;;
            "naive")
                if [ -n "$naive_user" ] && [ -n "$naive_pass" ] && [ -n "$naive_domain" ]; then
                    url=$(_naive_share_link "naive+https" "$naive_user" "$naive_pass" "$naive_domain" "$port" "$display_name") || url=""
                    if [ "$naive_net" = "both" ]; then
                        quic_url=$(_naive_share_link "naive+quic" "$naive_user" "$naive_pass" "$naive_domain" "$port" "$display_name") || quic_url=""
                    fi
                else
                    _warning "缺少 ${display_name} 的用户名、密码或域名，无法重建 NaiveProxy 链接。"
                fi
                ;;
            "socks")
                # [资源优化] 合并2次jq为1次
                local u p
                IFS=$'\t' read -r u p <<< "$(echo "$node" | jq -r '[.users[0].username, .users[0].password] | @tsv')"
                _info "  类型: SOCKS5, 地址: $display_server, 端口: $port, 用户: $u, 密码: $p"
                ;;
        esac
        fi
        if [ "$type" = "naive" ] && [ -n "$quic_url" ]; then
            [ -n "$url" ] && printf '  %b分享链接 (H2):%b %s\n' "$YELLOW" "$NC" "$url"
            printf '  %b分享链接 (H3/QUIC):%b %s\n' "$YELLOW" "$NC" "$quic_url"
            [ -n "$url" ] && printf '%s\n' "$url" >> "$links_tmp"
            printf '%s\n' "$quic_url" >> "$links_tmp"
        else
            [ -n "$url" ] && echo -e "  ${YELLOW}分享链接:${NC} ${url}"
            # 收集链接到临时文件
            [ -n "$url" ] && echo "$url" >> "$links_tmp"
        fi
        if [ "$type" = "naive" ] && [ -n "$naive_user" ] && [ -n "$naive_pass" ] && [ -n "$naive_domain" ] && [ -n "$port" ]; then
            local sb_h2_json="" sb_quic_json="" sub_h2_json="" sub_quic_json=""
            sb_h2_json=$(_naive_singbox_json "h2" "$naive_user" "$naive_pass" "$naive_domain" "$port" "$display_name") || sb_h2_json=""
            sub_h2_json=$(_naive_substore_json "h2" "$naive_user" "$naive_pass" "$naive_domain" "$port" "$display_name") || sub_h2_json=""
            [ -n "$sb_h2_json" ] && printf '  %bsing-box JSON (H2):%b\n%b%s%b\n' "$YELLOW" "$NC" "$CYAN" "$sb_h2_json" "$NC"
            if [ "$naive_net" = "both" ]; then
                sb_quic_json=$(_naive_singbox_json "quic" "$naive_user" "$naive_pass" "$naive_domain" "$port" "$display_name") || sb_quic_json=""
                [ -n "$sb_quic_json" ] && printf '  %bsing-box JSON (H3/QUIC):%b\n%b%s%b\n' "$YELLOW" "$NC" "$CYAN" "$sb_quic_json" "$NC"
            fi
            [ -n "$sub_h2_json" ] && printf '  %bSub-Store JSON (H2):%b\n%b%s%b\n' "$YELLOW" "$NC" "$CYAN" "$sub_h2_json" "$NC"
            if [ "$naive_net" = "both" ]; then
                sub_quic_json=$(_naive_substore_json "quic" "$naive_user" "$naive_pass" "$naive_domain" "$port" "$display_name") || sub_quic_json=""
                [ -n "$sub_quic_json" ] && printf '  %bSub-Store JSON (H3/QUIC):%b\n%b%s%b\n' "$YELLOW" "$NC" "$CYAN" "$sub_quic_json" "$NC"
            fi
        fi
    done
    echo "-------------------------------------"
    
    # 生成聚合 Base64 选项
    if [ -f "$links_tmp" ]; then
        echo ""
        read -p "是否生成聚合 Base64 订阅? (y/N): " gen_base64
        if [[ "$gen_base64" == "y" || "$gen_base64" == "Y" ]]; then
            echo ""
            _info "=== 聚合 Base64 订阅 ==="
            local base64_result=$(cat "$links_tmp" | base64 | tr -d '\n')
            echo -e "${CYAN}${base64_result}${NC}"
            echo ""
            _success "可直接复制上方内容导入 v2rayN 等客户端"
        fi
        rm -f "$links_tmp"
    fi
}

_sync_node_relay_metadata() {
    local tag="$1" file="${NODE_RELAY_LINKS_FILE:-${SINGBOX_DIR}/relay_links.json}" data key
    [ -f "$file" ] || return 0
    data=$(jq -c --arg t "$tag" '.[$t] // {}' "$METADATA_FILE") || return 1
    key=$(jq -nr --arg t "$tag" '$t | @json') || return 1
    _atomic_modify_json "$file" "if .[$key].inbound_source == \"main\" then .[$key] +=
        (($data) | {listen_port:.backendPort,link:.share_link,node_name:.name}) else . end"
}

_remove_node_relay_references() {
    local tag="$1" filter key prune links_file removed remaining cache_before
    key=$(jq -nr --arg t "$tag" '$t | @json') || return 1
    prune="def prune(\$t):
        (if has(\"inbound\") then
            .inbound |= (if type == \"array\" then map(select(. != \$t))
                         elif . == \$t then [] else . end)
            | if .inbound == [] and .invert == true and .action == \"resolve\"
                 and ((keys - [\"inbound\",\"invert\",\"action\",\"server\"]) | length) == 0
              then del(.inbound,.invert) else select(.inbound != []) end else . end)
        | if (.rules? | type) == \"array\" then
            (.rules | length) as \$before | .rules |= map(prune(\$t))
            | select((.rules | length) > 0)
            | select(.mode != \"and\" or (.rules | length) == \$before)
          else . end;"
    filter="$prune if (.route.rules? | type) == \"array\" then .route.rules |= map(prune($key)) else . end"
    _atomic_modify_json "$CONFIG_FILE" "$filter" || return 1
    _atomic_modify_json "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" "$filter" || return 1
    links_file="${NODE_RELAY_LINKS_FILE:-${SINGBOX_DIR}/relay_links.json}"
    if [ -f "$links_file" ]; then
        removed=$(jq -c --arg t "$tag" '[.__ruleset_routing.policies[]? | select(.inbound == $t) | .id]' "$(_node_candidate_path "$links_file")") || return 1
        _atomic_modify_json "$links_file" "$prune del(.[$key])
            | if .__ruleset_routing != null then
                .__ruleset_routing.policies |= map(select(.inbound != $key))
                | .__ruleset_routing.rules |= map(prune($key)) else . end" || return 1
        if [ "$removed" != '[]' ]; then
            remaining=$(jq '.__ruleset_routing.policies | length' "$(_node_candidate_path "$links_file")") || return 1
            cache_before=$(jq -c '.__ruleset_routing.cache_file_before' "$(_node_candidate_path "$links_file")") || return 1
            _atomic_modify_json "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" "
                ($removed) as \$ids
                | .outbounds |= map(.tag as \$t | select((\$ids | map(\"ruleset-out-\" + .) | index(\$t)) == null))
                | .route.rule_set |= map(.tag as \$t | select((\$ids | map(\"ruleset-set-\" + .) | index(\$t)) == null))
                | .dns.servers |= map(.tag as \$t | select((\$ids | map(\"ruleset-dns-\" + .) | index(\$t)) == null))
                | if $remaining == 0 then
                    .outbounds |= map(select(.tag != \"ruleset-direct\"))
                    | if $cache_before == null then del(.experimental.cache_file)
                      else .experimental.cache_file = $cache_before end
                  else . end" || return 1
        fi
    fi
}

_delete_node_impl() {
    if ! _node_catalog | jq -e '.inbounds | length > 0' >/dev/null 2>&1; then _warning "当前没有任何节点。"; return; fi
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
    done < <(_node_catalog | jq -r '.inbounds[] | [.tag, .type, (.listen_port|tostring)] | @tsv')
    # --- 列表逻辑结束 ---
    
    # 添加删除所有选项
    local count=${#inbound_tags[@]}
    echo ""
    echo -e "  ${RED}99)${NC} 删除所有节点"

    local NODE_UI=true
    _node_read -r -p "请输入要删除的节点编号 (输入 0 返回): " num || return $?

    [[ ! "$num" =~ ^[0-9]+$ ]] && { _error "无效编号。"; return 1; }

    # 处理删除所有节点
    if [ "$num" -eq 99 ]; then
        read -r -p "$(echo -e ${RED}"确定要删除所有节点吗? 此操作不可恢复! (输入 yes 确认，0 取消): "${NC})" confirm_all || return 2
        if [ "$confirm_all" != "yes" ]; then
            _info "删除已取消。"
            return 0
        fi
        
        _node_tx_begin || return 1
        _info "正在删除所有节点..."
        local xhttp_tag
        while IFS= read -r xhttp_tag; do
            [ -n "$xhttp_tag" ] || continue
            _delete_xhttp_node "$xhttp_tag" || return 1
        done < <(jq -r 'to_entries[] | select(.value.core == "xray") | .key' "$METADATA_FILE")

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
                local psuffix
                psuffix=$(jq -r --arg t "$ptag" '.inbounds[] | select(.tag == $t) | .listen_port' "$CONFIG_FILE")
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
        
        if [ -f "$NODE_TX_DIR/backup.0" ] || [ -f "$NODE_TX_DIR/backup.3" ] || [ -f "$NODE_TX_DIR/backup.4" ]; then
            local deleted_tag
            for deleted_tag in "${inbound_tags[@]}"; do
                _remove_node_relay_references "$deleted_tag" || return 1
            done
        fi
        # 清空配置（纯 Xray 主机不生成空 config.json）
        if [ -f "$NODE_TX_DIR/backup.0" ]; then
            _atomic_modify_json "$CONFIG_FILE" '.inbounds = []' || return 1
        fi
        _atomic_modify_json "$METADATA_FILE" '{}' || return 1
        
        # 清空 clash.yaml 中的代理
        _atomic_modify_yaml "$CLASH_YAML_FILE" '.proxies = []' || return 1
        _atomic_modify_yaml "$CLASH_YAML_FILE" '.proxy-groups[] |= (select(.name == "节点选择") | .proxies = ["DIRECT"])' || return 1
        
        _info "证书与续期记录已保留；删除节点不销毁可能共享的证书。"
        
        _check_config || return 1
        _success "所有节点已删除！"
        return 0
    fi
    
    # [!] 已修改：现在 count 会在循环外被正确计算
    if [ "$num" -gt "$count" ]; then _error "编号超出范围。"; return 1; fi

    local index=$((num - 1))
    # [!] 已修改：从数组中获取正确的信息
    local tag_to_del=${inbound_tags[$index]}
    local type_to_del=${inbound_types[$index]}
    local port_to_del=${inbound_ports[$index]}
    local public_port_to_del=${inbound_public_ports[$index]}
    local display_name_to_del=${display_names[$index]}

    # --- [!] 新的删除逻辑 ---
    # 使用统一查找函数确定 clash.yaml 中的确切名称
    local proxy_name_to_del
    proxy_name_to_del=$(_find_proxy_name "$public_port_to_del" "$type_to_del" "$tag_to_del") || return 1

    # [!] 已修改：使用显示名称进行确认
    local confirm=""
    _node_read_yes_no "$(echo -e ${YELLOW}"确定要删除节点 ${display_name_to_del} 吗? [y/N，0 返回]: "${NC})" confirm || return $?
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        _info "删除已取消。"
        return 0
    fi
    
    _node_tx_begin || return 1
    # === 关键修复：必须先读取 metadata 判断节点类型，再删除！===
    local node_metadata=$(jq -r --arg tag "$tag_to_del" '.[$tag] // empty' "$METADATA_FILE" 2>/dev/null)
    local node_type=""
    if [ -n "$node_metadata" ]; then
        node_type=$(echo "$node_metadata" | jq -r '.type // empty')
    fi

    if [ "$(jq -r '.core // empty' <<< "$node_metadata")" = xray ]; then
        _delete_xhttp_node "$tag_to_del" || return 1
        return 0
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
        return 1
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
    
    _atomic_modify_json "$METADATA_FILE" "del(.\"$tag_to_del\")" || return 1
    
    # [!] 已修改：使用找到的 proxy_name_to_del 从 clash.yaml 中删除
    if [ -n "$proxy_name_to_del" ]; then
        _remove_node_from_yaml "$proxy_name_to_del" || return 1
    fi

    _remove_node_relay_references "$tag_to_del" || return 1
    _info "节点证书已保留，供其他节点、中转或 Nginx 继续使用。"

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
    
    _check_config || return 1
    _success "节点 ${display_name_to_del} 已删除！"
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

    new_tag="$tag"
    old_proxy_name=$(_find_proxy_name "$old_public" "$type" "$tag") || return 1

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
    new_link=$(printf '%s' "$current_link" | sed -E "s#^([^:]+://[^/?#]*):${old_public}([/?#].*|$)#\\1:${new_public}\\2#")
    current_name=$(jq -r --arg tag "$tag" '.[$tag].name // empty' "$METADATA_FILE")
    new_name="$current_name"
    if ! jq --arg new_tag "$new_tag" --arg link "$new_link" --arg name "$new_name" \
        --argjson public "$new_public" --argjson backend "$target_port" --argjson routed "$target_routed" '
        .[$new_tag].publicPort=$public | .[$new_tag].backendPort=$backend |
        .[$new_tag].share_link=$link | .[$new_tag].name=$name |
        if $routed then .[$new_tag] += {frontedBy:"haproxy",routerRole:"reality-default"}
        else del(.[$new_tag].frontedBy, .[$new_tag].routerRole) end
    ' "$METADATA_FILE" > "${METADATA_FILE}.tmp" || ! mv "${METADATA_FILE}.tmp" "$METADATA_FILE"; then
        cp -a -- "$config_backup" "$CONFIG_FILE"
        cp -a -- "$metadata_backup" "$METADATA_FILE"
        [ "$currently_routed" = true ] && _sni_router_register_reality sb "$tag" "$sni" "$old_backend" >/dev/null 2>&1 || true
        rm -f "$config_backup" "$metadata_backup" "$yaml_backup"
        return 1
    fi

    if [ -n "$old_proxy_name" ] && [ -f "$CLASH_YAML_FILE" ]; then
        new_proxy_name="$old_proxy_name"
        export OLD_NAME="$old_proxy_name" NEW_NAME="$new_proxy_name" NEW_PORT_VAL="$new_public"
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == strenv(OLD_NAME)) | .name) = strenv(NEW_NAME) | (.proxies[] | select(.name == strenv(NEW_NAME)) | .port) = (env(NEW_PORT_VAL)|tonumber) | (.proxy-groups[].proxies[] | select(. == strenv(OLD_NAME))) = strenv(NEW_NAME)' || return 1
    fi

    _sync_node_relay_metadata "$tag" || return 1
    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" >/dev/null 2>&1 || \
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
    if [ -n "$new_link" ] && [ -n "${NODE_TX_DIR:-}" ]; then
        printf '\n%b═══════════════════ 分享链接 ═══════════════════%b\n%b%s%b\n%b═════════════════════════════════════════════════%b\n' \
            "$YELLOW" "$NC" "$CYAN" "$new_link" "$NC" "$YELLOW" "$NC" >> "$NODE_TX_DIR/share-links"
    fi
    _success "Reality 公网端口已切换: ${old_public} -> ${new_public}（实际监听 ${target_listen}:${target_port}）"
    return 0
}

_pause_for_enter() {
    local prompt="${1:-按回车键继续...}" _pause_dummy=""
    echo ""
    read -r -p "$prompt" _pause_dummy || return 0
}

_edit_node_menu() {
    if ! _node_catalog | jq -e '.inbounds | length > 0' >/dev/null 2>&1; then
        _warning "当前没有任何节点。"
        return 0
    fi

    while true; do
        _info "--- 修改节点参数 / 端口 ---"
        local inbound_tags=()
        local inbound_ports=()
        local inbound_public_ports=()
        local inbound_types=()
        local inbound_cores=()
        local inbound_meta_types=()
        local display_names=()
        local i=1 tag type port public_port proxy_name_to_find meta_name meta_type display_name core core_label
        while IFS=$'\t' read -r tag type port; do
            if [[ "$tag" == *"-hop-"* ]]; then continue; fi
            public_port=$(jq -r --arg t "$tag" --argjson fallback "$port" '.[$t].publicPort // $fallback' "$METADATA_FILE" 2>/dev/null)
            [ -n "$public_port" ] && [ "$public_port" != "null" ] || public_port="$port"
            core=$(jq -r --arg t "$tag" '.[$t].core // "sing-box"' "$METADATA_FILE" 2>/dev/null)
            [ -n "$core" ] && [ "$core" != "null" ] || core="sing-box"
            meta_type=$(jq -r --arg t "$tag" '.[$t].type // empty' "$METADATA_FILE" 2>/dev/null)
            proxy_name_to_find=$(_find_proxy_name "$public_port" "$type" "$tag" 2>/dev/null || true)
            meta_name=$(jq -r --arg t "$tag" '.[$t].name // empty' "$METADATA_FILE" 2>/dev/null)
            display_name=${proxy_name_to_find:-${meta_name:-$tag}}

            inbound_tags+=("$tag")
            inbound_ports+=("$port")
            inbound_public_ports+=("$public_port")
            inbound_types+=("$type")
            inbound_cores+=("$core")
            inbound_meta_types+=("$meta_type")
            display_names+=("$display_name")

            if [ "$core" = "xray" ] && [[ "$meta_type" == "vless-xhttp" || "$meta_type" == "vless-xhttp-reality" ]]; then
                core_label="Xray XHTTP · 全参数编辑"
            elif [ "$core" = "xray" ]; then
                core_label="Xray 历史节点 · 修改端口"
            else
                core_label="Sing-box · 修改端口"
            fi
            if [ "$public_port" != "$port" ]; then
                echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}, ${core_label}) @ ${GREEN}公网 ${public_port} -> 回环 ${port}${NC}"
            else
                echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}, ${core_label}) @ ${GREEN}${port}${NC}"
            fi
            ((i++))
        done < <(_node_catalog | jq -r '.inbounds[] | [.tag, .type, (.listen_port|tostring)] | @tsv')

        local count=${#inbound_tags[@]}
        if [ "$count" -eq 0 ]; then
            _warning "当前没有任何可编辑节点。"
            return 0
        fi
        echo -e "  ${YELLOW}0)${NC} 返回主菜单"
        local num=""
        read -r -p "请输入要修改的节点编号 (输入 0 返回): " num || return 0
        [ "$num" != "0" ] || return 0
        if [[ ! "$num" =~ ^[1-9][0-9]*$ ]] || [ "$num" -gt "$count" ]; then
            _error "无效编号，请重试。"
            continue
        fi

        local index=$((num - 1))
        local selected_tag=${inbound_tags[$index]}
        local selected_core=${inbound_cores[$index]}
        local selected_meta_type=${inbound_meta_types[$index]}
        if [ "$selected_core" = "xray" ] && [[ "$selected_meta_type" == "vless-xhttp" || "$selected_meta_type" == "vless-xhttp-reality" ]]; then
            _xray_edit_node_menu "$selected_tag" || true
        else
            local before_fp after_fp edit_status=0
            before_fp=$(_node_fingerprint "$CONFIG_FILE" "$METADATA_FILE" "$CLASH_YAML_FILE" "$XRAY_CONFIG_FILE" "$SNI_ROUTER_STATE_FILE" 2>/dev/null || true)
            _node_operation _modify_port_impl "$selected_tag" || edit_status=$?
            after_fp=$(_node_fingerprint "$CONFIG_FILE" "$METADATA_FILE" "$CLASH_YAML_FILE" "$XRAY_CONFIG_FILE" "$SNI_ROUTER_STATE_FILE" 2>/dev/null || true)
            if [ "$edit_status" -eq 0 ] && [ "$before_fp" != "$after_fp" ]; then
                _pause_for_enter "端口修改完成，按回车键返回..."
            fi
        fi
    done
}

_modify_port_impl() {
    local preselected_tag="${1:-}"
    local NODE_UI=true
    if ! _node_catalog | jq -e '.inbounds | length > 0' >/dev/null 2>&1; then
        _warning "当前没有任何节点。"
        return
    fi
    
    [ -n "$preselected_tag" ] || _info "--- 修改节点端口 ---"
    
    # 列出所有节点
    local inbound_tags=()
    local inbound_ports=()
    local inbound_public_ports=()
    local inbound_types=()
    local display_names=()
    
    local i=1 selected_index=-1
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
        if [ -n "$preselected_tag" ] && [ "$tag" = "$preselected_tag" ]; then
            selected_index=$((i - 1))
        elif [ -z "$preselected_tag" ]; then
            if [ "$public_port" != "$port" ]; then
                echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}) @ ${GREEN}公网 ${public_port} -> 回环 ${port}${NC}"
            else
                echo -e "  ${CYAN}$i)${NC} ${display_name} (${YELLOW}${type}${NC}) @ ${GREEN}${port}${NC}"
            fi
        fi
        ((i++))
    done < <(_node_catalog | jq -r '.inbounds[] | [.tag, .type, (.listen_port|tostring)] | @tsv')

    local index
    if [ -n "$preselected_tag" ]; then
        if [ "$selected_index" -lt 0 ]; then
            _error "未找到节点: ${preselected_tag}"
            return 1
        fi
        index="$selected_index"
    else
        local num=""
        _node_read -r -p "请输入要修改端口的节点编号 (输入 0 返回): " num || return $?
        [[ ! "$num" =~ ^[0-9]+$ ]] && { _error "无效编号。"; return 1; }
        local count=${#inbound_tags[@]}
        if [ "$num" -gt "$count" ]; then
            _error "编号超出范围。"
            return 1
        fi
        index=$((num - 1))
    fi
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
    
    local new_port=""
    _node_read -r -p "请输入新的端口号 (输入 0 取消): " new_port || return $?
    
    # 验证端口
    if [[ ! "$new_port" =~ ^[1-9][0-9]{0,4}$ ]] || ! _sni_router_validate_port "$new_port"; then
        _error "无效的端口号！"
        return 1
    fi
    
    if [ "$new_port" -eq "$old_public_port" ]; then
        _warning "新端口与当前端口相同，无需修改。"
        return 0
    fi

    if [ "$(jq -r --arg t "$tag_to_modify" '.[$t].core // empty' "$METADATA_FILE")" = xray ]; then
        _modify_xhttp_port "$tag_to_modify" "$new_port"
        return $?
    fi

    if [ "$(jq -r --arg tag "$tag_to_modify" '.[$tag].routerRole // empty' "$METADATA_FILE" 2>/dev/null)" = "tls-sni" ]; then
        _error "HAProxy 443 复用模式下的 TLS SNI 节点暂不支持直接修改端口，请删除后重新创建。"
        return 1
    fi

    if [ -n "$hop_info" ]; then
        _info "检测到当前 HY2 节点启用了端口跳跃 (${hop_mode:-unknown}): ${hop_info}"
        _node_read -r -p "请输入新的端口跳跃范围（直接回车保留原范围，输入 none 关闭，0 取消）: " hop_range_input || return $?
        if [ -z "$hop_range_input" ]; then
            final_hop_info="$hop_info"
        elif [ "$hop_range_input" = "none" ]; then
            final_hop_info=""
        else
            if [[ ! "$hop_range_input" =~ ^[0-9]+-[0-9]+$ ]]; then
                _error "端口跳跃范围格式无效，应为 start-end。"
                return 1
            fi
            final_hop_start="${hop_range_input%-*}"
            final_hop_end="${hop_range_input#*-}"
            if [ "$final_hop_start" -lt 1 ] || [ "$final_hop_end" -gt 65535 ] || [ "$final_hop_start" -gt "$final_hop_end" ]; then
                _error "端口跳跃范围无效。"
                return 1
            fi
            local pf_conflict
            pf_conflict=$(_find_pf_udp_conflict_in_range "$final_hop_start" "$final_hop_end")
            if [ -n "$pf_conflict" ]; then
                local c_port c_name c_net c_target
                IFS=$'\t' read -r c_port c_name c_net c_target <<< "$pf_conflict"
                _error "端口跳跃范围 ${hop_range_input} 覆盖了已有 ${c_net} 端口转发入口 ${c_port}（${c_name} -> ${c_target}）。"
                _error "请调整跳跃范围或先删除/修改该端口转发规则。"
                return 1
            fi
            local hop_conflict
            hop_conflict=$(_find_udp_hop_conflict_in_range "$final_hop_start" "$final_hop_end" "$tag_to_modify")
            if [ -n "$hop_conflict" ]; then
                local c_tag c_name c_range c_mode
                IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$hop_conflict"
                _error "端口跳跃范围 ${hop_range_input} 与已有跳跃范围 ${c_range} 重叠。"
                _error "冲突节点: ${c_name} (${c_tag}, ${c_mode})。请调整跳跃范围。"
                return 1
            fi
            final_hop_info="$hop_range_input"
        fi
    fi

    _node_tx_begin || return 1
    _switch_reality_public_port "$tag_to_modify" "$type_to_modify" "$old_port" "$old_public_port" "$new_port"
    local router_switch_status=$?
    if [ "$router_switch_status" -ne 2 ]; then
        return "$router_switch_status"
    fi

    # 检查端口是否已被占用
    if jq -e --arg tag "$tag_to_modify" --argjson port "$new_port" '.inbounds[] | select(.listen_port == $port and .tag != $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        _error "端口 $new_port 已被其他节点使用！"
        return 1
    fi

    local naive_uses_udp=false
    if [ "$type_to_modify" = "naive" ]; then
        if _check_port_in_config "$new_port"; then
            _error "端口 ${new_port} 已被现有节点配置占用！"
            return 1
        fi
        if _check_port_occupied "$new_port" "tcp"; then
            _error "TCP 端口 ${new_port} 已被系统其他程序占用，无法修改端口。"
            return 1
        fi
        local naive_net_meta naive_net_cfg
        naive_net_meta=$(jq -r --arg t "$tag_to_modify" '.[$t].naiveNetwork // empty' "$METADATA_FILE" 2>/dev/null)
        naive_net_cfg=$(jq -r --arg t "$tag_to_modify" '.inbounds[] | select(.tag == $t) | .network // empty' "$CONFIG_FILE" 2>/dev/null)
        if [ "$naive_net_meta" = "both" ] || { [ -z "$naive_net_meta" ] && [ "$naive_net_cfg" != "tcp" ]; }; then
            naive_uses_udp=true
        fi
    fi

    if [[ "$type_to_modify" == "hysteria2" || "$type_to_modify" == "tuic" ]] || [ "$naive_uses_udp" = true ]; then
        if [ "$naive_uses_udp" = true ] && _check_port_occupied "$new_port" "udp"; then
            _error "UDP 端口 ${new_port} 已被系统其他程序占用，无法修改端口。"
            return 1
        fi
        local new_port_hop_conflict
        new_port_hop_conflict=$(_find_udp_hop_conflict_in_range "$new_port" "$new_port" "$tag_to_modify")
        if [ -n "$new_port_hop_conflict" ]; then
            local c_tag c_name c_range c_mode
            IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$new_port_hop_conflict"
            _error "新端口 ${new_port} 落在已有 HY2 端口跳跃范围 ${c_range} 内。"
            _error "冲突节点: ${c_name} (${c_tag}, ${c_mode})。请换端口。"
            return 1
        fi
        if [ "$naive_uses_udp" = true ]; then
            local new_port_pf_conflict
            new_port_pf_conflict=$(_find_pf_udp_conflict_in_range "$new_port" "$new_port")
            if [ -n "$new_port_pf_conflict" ]; then
                local c_port c_name c_net c_target
                IFS=$'\t' read -r c_port c_name c_net c_target <<< "$new_port_pf_conflict"
                _error "新端口 ${new_port} 与已有 ${c_net} 端口转发入口 ${c_port} 冲突（${c_name} -> ${c_target}）。请换端口。"
                return 1
            fi
        fi
    fi
    
    if [ -n "$final_hop_info" ]; then
        final_hop_start="${final_hop_info%-*}"
        final_hop_end="${final_hop_info#*-}"
    fi
    
    local old_proxy_name
    old_proxy_name=$(_find_proxy_name "$old_port" "$type_to_modify" "$tag_to_modify") || return 1
    _info "正在修改端口: ${old_port} -> ${new_port}"
    
    # 1. 修改 config.json 主节点端口（按 tag 精确匹配，避免过滤 hop 子节点后索引错位）
    _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag_to_modify\") | .listen_port) = $new_port" || return 1
    
    # 2. 修改 clash.yaml (全链路同步模式)
    if [ -n "$old_proxy_name" ]; then
        # 生成新名字：将名字中的旧端口替换为新端口
        local new_proxy_name="$old_proxy_name"
        
        export OLD_NAME="$old_proxy_name"
        export NEW_NAME="$new_proxy_name"
        export NEW_PORT_VAL="$new_port"
        
        # 原子改名与改端口
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == strenv(OLD_NAME)) | .name) = strenv(NEW_NAME)' || return 1
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == strenv(NEW_NAME)) | .port) = (env(NEW_PORT_VAL)|tonumber)' || return 1
        
        # 全局同步更新所有分组中的引用
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxy-groups[].proxies[] | select(. == strenv(OLD_NAME))) = strenv(NEW_NAME)' || return 1
        
        if [ -n "$final_hop_info" ]; then
            export NEW_PORTS_VAL="$final_hop_info"
            _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == strenv(NEW_NAME)) | .ports) = env(NEW_PORTS_VAL)' || return 1
        elif [ -n "$hop_info" ]; then
            _atomic_modify_yaml "$CLASH_YAML_FILE" 'del(.proxies[] | select(.name == strenv(NEW_NAME)) | .ports)' || return 1
        fi
        
        _info "Clash 节点名同步: ${old_proxy_name} -> ${new_proxy_name}"
    fi
    
    # [修复] 3. 全局同步更新 metadata.json 中的链接端口与备注名
    local updated_share_link="" updated_quic_link=""
    if [ -f "$METADATA_FILE" ]; then
        if jq -e ".\"$tag_to_modify\"" "$METADATA_FILE" >/dev/null 2>&1; then
            # [关键修复] _view_nodes 优先读取的是 .share_link 字段 (非 .link)
            local current_link=$(jq -r ".\"$tag_to_modify\".share_link // \"\"" "$METADATA_FILE")
            if [ -n "$current_link" ]; then
                # 精准替换：仅替换 URL 中端口位置的数字（@IP:PORT? 和 #name-PORT 部分），避免误伤 UUID/密码
                local new_link=$(echo "$current_link" | sed -E "s#^([^:]+://[^/?#]*):${old_port}([/?#].*|$)#\1:${new_port}\2#")
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
                updated_share_link="$new_link"
                _atomic_modify_json "$METADATA_FILE" ".\"$tag_to_modify\".share_link = $(jq -Rn --arg v "$new_link" '$v')" || return 1
                _info "分享链接已同步更新。"
                if [ "$type_to_modify" != "naive" ] && [ -n "${NODE_TX_DIR:-}" ]; then
                    printf '\n%b═══════════════════ 分享链接 ═══════════════════%b\n%b%s%b\n%b═════════════════════════════════════════════════%b\n' \
                        "$YELLOW" "$NC" "$CYAN" "$new_link" "$NC" "$YELLOW" "$NC" >> "$NODE_TX_DIR/share-links"
                fi
            fi
            local current_quic_link
            current_quic_link=$(jq -r --arg t "$tag_to_modify" '.[$t].share_link_quic // ""' "$METADATA_FILE")
            if [ -n "$current_quic_link" ]; then
                local new_quic_link
                new_quic_link=$(printf '%s' "$current_quic_link" | sed -E "s#^([^:]+://[^/?#]*):${old_port}([/?#].*|$)#\1:${new_port}\2#")
                updated_quic_link="$new_quic_link"
                _atomic_modify_json "$METADATA_FILE" ".\"$tag_to_modify\".share_link_quic = $(jq -Rn --arg v "$new_quic_link" '$v')" || return 1
                if [ "$type_to_modify" != "naive" ] && [ -n "${NODE_TX_DIR:-}" ]; then
                    printf '\n%b═══════════════════ 分享链接 (H3/QUIC) ═══════════════════%b\n%b%s%b\n%b═════════════════════════════════════════════════════════%b\n' \
                        "$YELLOW" "$NC" "$CYAN" "$new_quic_link" "$NC" "$YELLOW" "$NC" >> "$NODE_TX_DIR/share-links"
                fi
            fi
            local current_meta_name
            current_meta_name=$(jq -r ".\"$tag_to_modify\".name // \"\"" "$METADATA_FILE")
            if [ -n "$current_meta_name" ]; then
                local new_meta_name
                new_meta_name="$current_meta_name"
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

    # 节点 ID 和证书路径终身不随端口变化；relay.json 的引用保持有效。
    local new_tag="$tag_to_modify"
    _atomic_modify_json "$METADATA_FILE" ".\"$tag_to_modify\".publicPort = $new_port | .\"$tag_to_modify\".backendPort = $new_port" || return 1

    if [ "$type_to_modify" = "naive" ]; then
        local naive_user naive_pass naive_domain naive_net_out="tcp" naive_block=""
        naive_user=$(jq -r --arg t "$tag_to_modify" '.inbounds[] | select(.tag == $t) | .users[0].username // empty' "$CONFIG_FILE")
        naive_pass=$(jq -r --arg t "$tag_to_modify" '.inbounds[] | select(.tag == $t) | .users[0].password // empty' "$CONFIG_FILE")
        naive_domain=$(jq -r --arg t "$tag_to_modify" '.[$t].domain // .[$t].server_name // empty' "$METADATA_FILE" 2>/dev/null)
        [ -n "$naive_domain" ] || naive_domain=$(jq -r --arg t "$tag_to_modify" '.inbounds[] | select(.tag == $t) | .tls.server_name // empty' "$CONFIG_FILE")
        [ "$naive_uses_udp" = true ] && naive_net_out="both"
        if [ -z "$updated_share_link" ] && [ -n "$naive_user" ] && [ -n "$naive_pass" ] && [ -n "$naive_domain" ]; then
            updated_share_link=$(_naive_share_link "naive+https" "$naive_user" "$naive_pass" "$naive_domain" "$new_port" "$display_name_to_modify") || updated_share_link=""
        fi
        if [ "$naive_net_out" = "both" ] && [ -z "$updated_quic_link" ] && [ -n "$naive_user" ] && [ -n "$naive_pass" ] && [ -n "$naive_domain" ]; then
            updated_quic_link=$(_naive_share_link "naive+quic" "$naive_user" "$naive_pass" "$naive_domain" "$new_port" "$display_name_to_modify") || updated_quic_link=""
        fi
        naive_block=$(_naive_export_block "$updated_share_link" "$updated_quic_link" "$naive_user" "$naive_pass" "$naive_domain" "$new_port" "$display_name_to_modify" "$naive_net_out") || return 1
        if [ -n "${NODE_TX_DIR:-}" ]; then
            printf '%s\n' "$naive_block" >> "$NODE_TX_DIR/share-links"
        else
            printf '%s\n' "$naive_block"
        fi
    fi

    _sync_node_relay_metadata "$tag_to_modify" || return 1

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
                    _error "端口跳跃规则更新失败，撤销本次端口修改。"
                    return 1
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
    
    _check_config || return 1
    _success "端口修改成功: ${old_port} -> ${new_port}"
}

# 批量创建节点（单事务原子提交：统一锁、统一校验、单次服务重启、任一失败全量回滚）
_batch_create_nodes() {
    local status=0
    _node_operation _batch_create_nodes_impl "$@" || status=$?
    if [ "$status" -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}══════════════════ 批量创建完成提示 ══════════════════${NC}"
        _success "所有节点已按直连模式部署完毕。"
        _info "所有批量节点已就绪，您可以运行 sb 查看具体配置。"
        echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
        _success "批量创建任务已全部完成。"
    fi
    return "$status"
}

_batch_create_nodes_impl() {
    local input_str="$1" NODE_UI=true NODE_PENDING_ORIGIN=''
    if [ -z "$input_str" ]; then
        _info "请输入协议编号 (空格或逗号分隔，如: 1,6,9；输入 0 返回)"
        _warn "注：批量部署不支持含有 CDN 的协议 (2, 3, 4)"
        _node_read -r -p "协议列表: " input_str || return $?
    fi
    [ -z "$input_str" ] && return 2

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

    # 2. 引导向导（输入阶段尚未持锁，写入前由 _node_tx_begin 统一取锁并核对快照）
    _info "--- 批量部署引导向导 ---"

    # [修复] 强制初始化服务器 IP，防止各协议函数因变量未定义生成空配置
    [ -z "$server_ip" ] && server_ip=$(_get_ip)
    local batch_ip="${server_ip}" custom_batch_ip=""
    read -r -p "请输入批量节点绑定的IP地址 (回车默认: ${server_ip}): " custom_batch_ip || return 1
    batch_ip=${custom_batch_ip:-$server_ip}
    export BATCH_IP="$batch_ip"

    # 2.1 SNI 收集 (强制净化处理)
    export BATCH_SNI="$DEFAULT_SNI"
    export BATCH_REALITY_HANDSHAKE_SERVER="$DEFAULT_REALITY_SNI"
    export BATCH_REALITY_HANDSHAKE_PORT=443
    if [ "$has_reality" = true ]; then
        _select_reality_sni || return $?
        BATCH_SNI="$SELECTED_REALITY_SNI"
        BATCH_REALITY_HANDSHAKE_SERVER="$SELECTED_REALITY_HANDSHAKE_SERVER"
        BATCH_REALITY_HANDSHAKE_PORT="$SELECTED_REALITY_HANDSHAKE_PORT"
        export BATCH_SNI
        export BATCH_REALITY_HANDSHAKE_SERVER
        export BATCH_REALITY_HANDSHAKE_PORT
    elif [ "$has_sni_req" = true ]; then
        local input_sni=""
        read -r -p "请输入统一伪装域名 (SNI) [默认: $BATCH_SNI]: " input_sni || return 1
        input_sni=$(echo "$input_sni" | xargs)
        [ -n "$input_sni" ] && BATCH_SNI="$input_sni"
    fi

    # 2.2 Hy2 专项
    local hy2_obfs="none"
    local hy2_hop="false"
    local hy2_hop_range=""
    if [ "$has_hy2" = true ]; then
        local hy2_q_choice="" hy2_h_choice=""
        read -r -p "是否开启 Hysteria2 QUIC 混淆? (y/N): " hy2_q_choice || return 1
        [[ "$hy2_q_choice" == "y" || "$hy2_q_choice" == "Y" ]] && hy2_obfs="salamander"
        read -r -p "是否开启 Hysteria2 端口跳跃? (y/N): " hy2_h_choice || return 1
        if [[ "$hy2_h_choice" == "y" || "$hy2_h_choice" == "Y" ]]; then
            hy2_hop="true"
            read -r -p "请输入端口跳跃范围 (如 20000-30000): " hy2_hop_range || return 1
        fi
    fi

    # 2.4 SS 专项 (支持多选，提前校验变体编号)
    local ss_variant="1"
    local ss_variants_list=()
    if [ "$has_ss" = true ]; then
        echo "选择 Shadowsocks 批量加密方式 (支持多选，如 1,2,3,4):"
        echo " 1) aes-256-gcm"
        echo " 2) chacha20-ietf-poly1305"
        echo " 3) 2022-blake3-aes-256-gcm"
        echo " 4) 2022-blake3-aes-256-gcm (多路复用 + Padding)"
        local ss_choice="" v
        read -r -p "选择 [1-4] (默认1): " ss_choice || return 1
        ss_variant=${ss_choice:-1}
        local ss_needed=0
        for v in $(echo "$ss_variant" | tr ',' ' '); do
            if [[ ! "$v" =~ ^[1-5]$ ]]; then
                _error "Shadowsocks 变体 ${v} 无效，请输入 1-4。"
                return 1
            fi
            ss_variants_list+=("$v")
            ((ss_needed++))
        done
        [ "$ss_needed" -gt 0 ] || { _error "未选择有效的 Shadowsocks 变体。"; return 1; }
        proto_count=$((proto_count + (ss_needed - 1) * ss_occurences))
    fi

    # 3. 端口规划
    local ports_list=()
    _info "共需规划 $proto_count 个批量监听端口。"
    while true; do
        local p_input=""
        read -r -p "请输入端口号 (范围如 10001-10010 或空格分隔): " p_input || return 1
        local current_p_list=()
        local invalid_port=false
        local duplicate_port=false
        local occupied_port=false
        local seen_ports=" "
        p_input=$(echo "$p_input" | tr ',' ' ' | xargs)
        [ -z "$p_input" ] && { _error "端口不能为空，请重新输入。"; continue; }
        if [[ "$p_input" == *"-"* ]]; then
            local start_p=$(echo "$p_input" | cut -d'-' -f1)
            local end_p=$(echo "$p_input" | cut -d'-' -f2)
            if [[ ! "$start_p" =~ ^[0-9]+$ ]] || [[ ! "$end_p" =~ ^[0-9]+$ ]] || [ "$start_p" -lt 1 ] || [ "$end_p" -gt 65535 ] || [ "$start_p" -gt "$end_p" ]; then
                _error "端口范围无效，应为 1-65535 内的 start-end。"
                continue
            fi
            local p
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

    # 4. 单事务写入循环：所有节点写入同一候选副本，由外层 _node_operation 统一校验、发布与重启
    local bulk_idx=0
    local proto_array=($proto_ids)
    local i pid current_port v
    for i in "${!proto_array[@]}"; do
        pid=${proto_array[$i]}

        if [ "$pid" == "8" ]; then
            for v in "${ss_variants_list[@]}"; do
                current_port=${ports_list[$bulk_idx]}
                _info "正在安装 Shadowsocks (变体 $v) 到端口 $current_port..."
                export BATCH_MODE="true"
                export BATCH_PORT="$current_port"
                export BATCH_SS_VARIANT="$v"
                _add_shadowsocks_menu || return 1
                ((bulk_idx++))
            done
        else
            current_port=${ports_list[$bulk_idx]}
            _info "正在安装协议 [$pid] 到端口 $current_port..."

            export BATCH_MODE="true"
            export BATCH_PORT="$current_port"
            export BATCH_HY2_OBFS="$hy2_obfs"
            export BATCH_HY2_HOP="$hy2_hop_range"

            case $pid in
                1) _add_vless_reality && NODE_PENDING_ORIGIN='' ;;
                2) _add_vless_ws_tls ;;
                3) _add_trojan_ws_tls ;;
                4) _add_vless_grpc_tls ;;
                5) _add_anytls ;;
                6) _add_hysteria2 ;;
                7) _add_tuic ;;
                9) _add_vless_tcp ;;
                10) _add_socks ;;
            esac || return 1
            ((bulk_idx++))
        fi
    done

    unset BATCH_MODE BATCH_PORT BATCH_SNI BATCH_SNI_ROUTER BATCH_REALITY_HANDSHAKE_SERVER BATCH_REALITY_HANDSHAKE_PORT BATCH_HY2_OBFS BATCH_HY2_HOP BATCH_SS_VARIANT BATCH_ANYTLS_MODE BATCH_IP BATCH_GRPC_TLS_DOMAIN BATCH_GRPC_SERVICE_NAME
}
_delete_node() { if [ -n "${NODE_TX_DIR:-}" ]; then _delete_node_impl; else _node_operation _delete_node_impl; fi; }
_modify_port() { if [ -n "${NODE_TX_DIR:-}" ]; then _modify_port_impl; else _node_operation _modify_port_impl; fi; }
