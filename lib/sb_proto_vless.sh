#!/usr/bin/env bash
# PROXYALL_LIB=sb_proto_vless.sh
# VLESS TCP 类节点（sing-box）：VLESS Vision Reality 与裸 VLESS TCP。由 sb 加载。

_add_vless_reality_impl() {
    [ -n "$server_ip" ] || server_ip=$(_get_ip)
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
        [ -z "$node_ip" ] && node_ip="$server_ip"
        _sni_router_validate_port "$port" || return 1
        if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ] && [ "${BATCH_SNI_ROUTER:-true}" = "true" ]; then
            router_mode=true
        fi
    else
        local custom_ip="" custom_name=""
        _node_read -r -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip || return $?
        node_ip=${custom_ip:-$server_ip}
        _select_reality_sni || return $?
        server_name="$SELECTED_REALITY_SNI"
        handshake_server="$SELECTED_REALITY_HANDSHAKE_SERVER"
        handshake_port="$SELECTED_REALITY_HANDSHAKE_PORT"
        while true; do
            _node_read -r -p "请输入监听端口 (默认: 443，共享 SNI 入口): " port || return $?
            port="${port:-443}"
            _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; continue; }
            router_mode=false
            listen_address="::"
            if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                local use_router=""
                _node_read_yes_no "是否由 HAProxy 复用公网 443（Emby 与 Reality 可共存）？[Y/n]: " use_router || return $?
                if [[ ! "$use_router" =~ ^[Nn]$ ]]; then
                    if [ -f "$SNI_ROUTER_STATE_FILE" ] && jq -e '.reality != null' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
                        _error "HAProxy 443 已经登记了一个 Reality 默认后端，请复用或删除该节点。"
                        continue
                    fi
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
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi

    [ -n "$backend_port" ] || backend_port="$port"
    _validate_reality_no_self_loop "$port" "$handshake_server" "$handshake_port" || return 1
    node_ip="${node_ip#[}"; node_ip="${node_ip%]}"
    if ! _is_valid_ipv4 "$node_ip" && ! _is_valid_reality_domain "$node_ip" && ! [[ "$node_ip" == *:* && "$node_ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
        _error '客户端连接地址须为 IP 或域名。'; return 1
    fi
    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "vless-in") || return 1
    if [ "$router_mode" = true ]; then
        _sni_router_prepare || return 1
        _sni_router_assert_sni_available "$server_name" || return 1
        jq -e '.reality == null' "$SNI_ROUTER_STATE_FILE" >/dev/null || {
            _error '公网 443 已登记 Reality 后端，请使用其他端口。'; return 1;
        }
        backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
        listen_address="127.0.0.1"
    elif _check_port_conflict "$port" tcp; then
        return 1
    fi
    if [ -n "${NODE_PENDING_ORIGIN:-}" ]; then
        _prepare_local_reality_origin "$NODE_PENDING_ORIGIN" || return 1
        NODE_PENDING_ORIGIN=''
    fi

    local uuid keypair private_key public_key short_id
    uuid=$("$SINGBOX_BIN" generate uuid) || return 1
    keypair=$("$SINGBOX_BIN" generate reality-keypair) || return 1
    private_key=$(awk '/PrivateKey/ {print $2}' <<< "$keypair")
    public_key=$(awk '/PublicKey/ {print $2}' <<< "$keypair")
    short_id=$("$SINGBOX_BIN" generate rand --hex 8) || return 1
    [ -n "$uuid" ] && [ -n "$private_key" ] && [ -n "$public_key" ] && [ -n "$short_id" ] || {
        _error 'sing-box 未返回有效的 UUID 或 Reality 密钥对。'; return 1;
    }

    local yaml_ip="$node_ip"
    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local inbound_json
    inbound_json=$(jq -n --arg t "$tag" --arg p "$backend_port" --arg listen "$listen_address" --arg u "$uuid" \
        --arg sn "$server_name" --arg hs "$handshake_server" --arg hp "$handshake_port" --arg pk "$private_key" --arg sid "$short_id" \
        '{"type":"vless","tag":$t,"listen":$listen,"listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sn,"reality":{"enabled":true,"handshake":{"server":$hs,"server_port":($hp|tonumber)},"private_key":$pk,"short_id":[$sid]}}}') || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

    local meta_json
    meta_json=$(jq -n --arg n "$name" --arg sn "$server_name" --arg pub "$public_key" --arg sid "$short_id" \
        --arg hs "$handshake_server" --arg hp "$handshake_port" --argjson public_port "$port" \
        --argjson backend "$backend_port" --argjson routed "$router_mode" \
        '{name:$n,server_name:$sn,publicKey:$pub,shortId:$sid,handshakeServer:$hs,handshakePort:($hp|tonumber),publicPort:$public_port,backendPort:$backend} +
         (if $routed then {frontedBy:"haproxy",routerRole:"reality-default"} else {} end)') || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta_json}" || return 1

    local proxy_json
    proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg u "$uuid" --arg sn "$server_name" --arg pbk "$public_key" --arg sid "$short_id" \
        '{"name":$n,"type":"vless","server":$s,"port":($p|tonumber),"uuid":$u,"tls":true,"udp":true,"network":"tcp","flow":"xtls-rprx-vision","servername":$sn,"client-fingerprint":"firefox","reality-opts":{"public-key":$pbk,"short-id":$sid}}') || return 1
    _add_node_to_yaml "$proxy_json" || return 1

    if [ "$router_mode" = true ]; then
        _sni_router_register_reality sb "$tag" "$server_name" "$backend_port" || return 1
        _info "公网 443 -> HAProxy -> 127.0.0.1:${backend_port} -> Sing-box Reality"
    fi
    _success "VLESS (Vision + Reality) 节点 [${name}] 添加成功!"
    _show_node_link "vless-reality" "$name" "$link_ip" "$port" "$tag" "$uuid" "$server_name" "$public_key" "$short_id" || return 1
}

_add_vless_tcp_impl() {
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
        local custom_ip=""
        _node_read -r -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip || return $?
        node_ip=${custom_ip:-$server_ip}
        while true; do
            _node_read -r -p "请输入监听端口: " port || return $?
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; continue; }
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
        local custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local uuid=$(${SINGBOX_BIN} generate uuid)
    local tag
    tag=$(_new_node_tag "vless-tcp-in") || return 1
    # IPv6处理：YAML用原始IP，链接用带[]的IP
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"
    
    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" \
        '{"type":"vless","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":""}],"tls":{"enabled":false}}')
    _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1
    
    local proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg u "$uuid" \
        '{"name":$n,"type":"vless","server":$s,"port":($p|tonumber),"uuid":$u,"tls":false,"network":"tcp"}')
    _add_node_to_yaml "$proxy_json" || return 1
    _success "VLESS (裸 TCP，无 TLS) 节点 [${name}] 添加成功!"
    _show_node_link "vless-tcp" "$name" "$link_ip" "$port" "$tag" "$uuid"
}
_add_vless_reality() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_vless_reality_impl; else _node_operation _add_vless_reality_impl; fi; }
_add_vless_tcp() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_vless_tcp_impl; else _node_operation _add_vless_tcp_impl; fi; }
