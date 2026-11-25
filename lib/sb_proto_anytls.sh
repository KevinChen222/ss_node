#!/usr/bin/env bash
# PROXYALL_LIB=sb_proto_anytls.sh
# AnyTLS 类节点（sing-box）：AnyTLS 自签/自有证书与 Any-Reality。由 sb 加载。

_cert_matches_hostname() {
    # x509 -checkhost 在域名不匹配时也可能返回 0。
    local result
    result=$(LC_ALL=C openssl x509 -in "$1" -noout -checkhost "$2" 2>/dev/null) &&
        [[ "$result" == "Hostname $2 does match certificate" ]]
}

_validate_anytls_certificate() {
    local cert="$1" key="$2" sni="$3" trusted="${4:-true}" cert_pub key_pub
    [ -r "$cert" ] && [ -r "$key" ] || { _error '证书或私钥不可读。'; return 1; }
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || { _error '证书已过期或无效。'; return 1; }
    _cert_matches_hostname "$cert" "$sni" || { _error '证书未覆盖节点 SNI。'; return 1; }
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout) || return 1
    key_pub=$(openssl pkey -in "$key" -pubout -passin pass:) || return 1
    [ "$cert_pub" = "$key_pub" ] || { _error '私钥与证书不匹配。'; return 1; }
    if [ "$trusted" = true ]; then
        openssl verify -purpose sslserver -verify_hostname "$sni" -untrusted "$cert" "$cert" >/dev/null 2>&1 || {
            _error '证书未通过系统信任链验证。请提供公网可信的完整证书链；Cloudflare Origin CA 不是普通客户端默认信任的证书。'
            return 1
        }
    fi
}

_create_anytls_tls_node_impl() {
    local node_ip="$1"
    local port="$2"
    local server_name="$3"
    local password="$4"
    local name="$5"
    local listen_address="${6:-::}"
    local backend_port="${7:-$port}"
    local router_mode="${8:-false}"

    local cert_choice="1" cert_path="" key_path="" skip_verify=false tag cert_owner=""
    if [ "$BATCH_MODE" = true ]; then
        cert_path="${BATCH_ANYTLS_CERT:-}"
        key_path="${BATCH_ANYTLS_KEY:-}"
        if [ "${BATCH_ANYTLS_INSECURE:-false}" = true ]; then cert_choice=2
        elif [ -z "$cert_path" ] || [ -z "$key_path" ]; then
            _error '批量 AnyTLS 需要 BATCH_ANYTLS_CERT/BATCH_ANYTLS_KEY；自签兼容模式必须显式设置 BATCH_ANYTLS_INSECURE=true。'
            return 1
        fi
    else
        echo '请选择证书方式:'
        echo '  1) 复用公网可信证书与私钥（默认，验证证书链、SNI 和有效期）'
        echo '  2) 生成自签证书，客户端需支持分享链接中的证书指纹固定'
        _node_read -r -p '请选择 [1-2] (默认: 1): ' cert_choice || return $?
        cert_choice=${cert_choice:-1}
    fi
    case "$cert_choice" in
        1)
            if [ "$BATCH_MODE" != true ]; then
                _node_read -r -p '完整证书链 .pem/.crt 路径: ' cert_path || return $?
                _node_read -r -p '私钥 .key 路径: ' key_path || return $?
            fi
            _validate_anytls_certificate "$cert_path" "$key_path" "$server_name" true || return 1
            ;;
        2)
            skip_verify=true
            ;;
        *) _error '无效证书选项。'; return 1 ;;
    esac

    # IPv6 处理
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"
    [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    tag=$(_new_node_tag "anytls-in") || return 1
    if [ "$router_mode" = true ]; then
        _sni_router_prepare || return 1
        _sni_router_assert_sni_available "$server_name" || return 1
        if [ "$listen_address" != "127.0.0.1" ] || [ "$backend_port" = "$port" ]; then
            backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
            listen_address="127.0.0.1"
        fi
    elif _check_port_conflict "$port" tcp; then
        return 1
    fi
    local cert_pin=""
    if [ "$cert_choice" = 2 ]; then
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        cert_owner="$tag"
        _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1
        cert_pin=$(_cert_sha256_hex "$cert_path")
        _warning '自签模式依赖分享链接的 pcs 校验证书。转换为 mihomo 后须保留 fingerprint；忽略指纹的客户端将无法验证服务端身份。'
    fi
    jq -e --argjson p "$backend_port" '[.inbounds[] | select(.listen_port == $p and (.type != "hysteria2" and .type != "tuic"))] | length == 0' "$CONFIG_FILE" >/dev/null || {
        _error "后端 TCP 端口已被节点使用: $backend_port"; return 1;
    }

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
    
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1
    
    # --- 生成 Clash YAML 配置 ---
    # 根据用户提供的格式：包含 client-fingerprint, udp, alpn；自签模式同时固定叶证书 fingerprint。
    local proxy_json=$(jq -n \
        --arg n "$name" \
        --arg s "$yaml_ip" \
        --arg p "$port" \
        --arg pw "$password" \
        --arg sn "$server_name" \
        --arg skip_verify_bool "$skip_verify" \
        --arg pin "$cert_pin" \
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
        } + (if ($skip_verify_bool == "true") and ($pin != "") then {"fingerprint": $pin} else {} end)')
    
    _add_node_to_yaml "$proxy_json" || return 1
    
    # --- 保存元数据 ---
    local meta_json
    meta_json=$(jq -n --arg n "$name" --arg sn "$server_name" --argjson public "$port" \
        --argjson backend "$backend_port" --argjson routed "$router_mode" \
        --arg cert "$cert_path" --arg key "$key_path" --arg owner "$cert_owner" \
        '{certificatePath:$cert,keyPath:$key,certificateOwner:$owner,name:$n, clientName:$n, server_name:$sn, yaml:true, publicPort:$public, backendPort:$backend} +
         (if $routed then {frontedBy:"haproxy",routerRole:"tls-sni"} else {} end)')
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta_json}" || return 1

    _show_node_link "anytls" "$name" "$link_ip" "$port" "$tag" "$password" "$server_name" "$skip_verify" "$cert_path" || return 1
    if [ "$router_mode" = true ]; then
        _sni_router_register_tls sb "$tag" "$server_name" "$backend_port" || return 1
        _info "公网 443 -> HAProxy -> 127.0.0.1:${backend_port} -> Sing-box AnyTLS"
    fi
    
    _success "AnyTLS 节点 [${name}] 添加成功!"
}

_create_anyreality_node_impl() {
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
    local tag
    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    tag=$(_new_node_tag "any-reality-in") || return 1
    if [ "$router_mode" = true ]; then
        _sni_router_prepare || return 1
        _sni_router_assert_sni_available "$server_name" || return 1
        jq -e '.reality == null' "$SNI_ROUTER_STATE_FILE" >/dev/null || {
            _error '公网 443 已登记 Reality 后端，请使用其他端口。'; return 1;
        }
        if [ "$listen_address" != "127.0.0.1" ] || [ "$backend_port" = "$port" ]; then
            backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
            listen_address="127.0.0.1"
        fi
    elif _check_port_conflict "$port" tcp; then
        return 1
    fi
    if [ -n "${NODE_PENDING_ORIGIN:-}" ]; then
        _prepare_local_reality_origin "$NODE_PENDING_ORIGIN" || return 1
        NODE_PENDING_ORIGIN=''
    fi

    local keypair private_key public_key short_id
    keypair=$(${SINGBOX_BIN} generate reality-keypair) || return 1
    private_key=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    public_key=$(echo "$keypair" | awk '/PublicKey/ {print $2}')
    short_id=$(${SINGBOX_BIN} generate rand --hex 8) || return 1
    [ -n "$private_key" ] && [ -n "$public_key" ] && [ -n "$short_id" ] || {
        _error 'sing-box 未返回有效的 Reality 密钥对。'; return 1;
    }

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

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

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

    if [ "$router_mode" = true ]; then
        _sni_router_register_reality sb "$tag" "$server_name" "$backend_port" || return 1
        _info "公网 443 -> HAProxy -> 127.0.0.1:${backend_port} -> Sing-box Any-Reality"
    fi

    _success "Any-Reality 节点 [${name}] 添加成功!"
    _warning "mihomo 不支持 AnyTLS + Reality；Sub-Store 的 Clash.Meta 导出会过滤此节点。请用支持该组合的 sing-box 客户端导入完整链接。"
    _show_node_link "any-reality" "$name" "$link_ip" "$port" "$tag" "$password" "$server_name" "$public_key" "$short_id"
}

_add_anytls_impl() {
    [ -n "$server_ip" ] || server_ip=$(_get_ip)
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
        _node_read -r -p "请选择 [1/2/1,2] (默认: 1): " mode_choice || return $?
        mode_choice=${mode_choice:-1}
        mode_choice=$(echo "$mode_choice" | tr '，' ',' | xargs)
        case "$mode_choice" in
            1|2|1,2|2,1|"1 2"|"2 1") ;;
            *) _error "无效选择"; return 1 ;;
        esac

        local custom_ip=""
        _node_read -r -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip || return $?
        node_ip=${custom_ip:-$server_ip}
        node_ip="${node_ip#[}"; node_ip="${node_ip%]}"
        if ! _is_valid_ipv4 "$node_ip" && ! _is_valid_reality_domain "$node_ip" && ! [[ "$node_ip" == *:* && "$node_ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
            _error '客户端连接地址须为 IP 或域名。'; return 1
        fi
        while true; do
            _node_read -r -p "请输入起始监听端口 (默认: 443): " port || return $?
            port="${port:-443}"
            if ! _sni_router_validate_port "$port"; then
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
                _node_read_yes_no "是否由 HAProxy 复用公网 443（${router_target} ${router_compat}）？[Y/n]: " use_router || return $?
                if [[ ! "$use_router" =~ ^[Nn]$ ]]; then
                    if [ "$router_target" = "Any-Reality" ]; then
                        if [ -f "$SNI_ROUTER_STATE_FILE" ] && jq -e '.reality != null' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
                            _error "HAProxy 443 已经登记了一个 Reality 默认后端，请先删除该节点。"
                            continue
                        fi
                        reality_listen_address="127.0.0.1"
                        reality_router_mode=true
                    else
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
            _select_reality_sni || return $?
            server_name="$SELECTED_REALITY_SNI"
            reality_handshake_server="$SELECTED_REALITY_HANDSHAKE_SERVER"
            reality_handshake_port="$SELECTED_REALITY_HANDSHAKE_PORT"
        else
            local camouflage_domain=""
            _node_read -r -p "请输入 AnyTLS 伪装域名/SNI (默认: ${DEFAULT_SNI}): " camouflage_domain || return $?
            server_name=${camouflage_domain:-$DEFAULT_SNI}
        fi
    fi

    if [ "$BATCH_MODE" = "true" ]; then
        if ! _sni_router_validate_port "$port"; then
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
                tls_listen_address="127.0.0.1"
                tls_router_mode=true
            elif [[ "$mode_choice" == *"2"* ]] && [ "$any_reality_port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                reality_listen_address="127.0.0.1"
                reality_router_mode=true
            fi
        fi
    fi

    local password="" input_pw=""
    if [ "$BATCH_MODE" = "true" ]; then
        password=$(${SINGBOX_BIN} generate uuid) || return 1
    else
        _node_read -r -p "请输入密码/UUID (回车则随机生成，两种模式共用): " input_pw || return $?
        password=${input_pw:-$(${SINGBOX_BIN} generate uuid)} || return 1
    fi

    local created=false
    case "$mode_choice" in
        1)
            local name custom_name=""
            if [ "$BATCH_MODE" = "true" ]; then
                name="Batch-AnyTLS-${port}"
            else
                local default_name="AnyTLS-${port}"
                _node_read -r -p "请输入 AnyTLS 节点名称 (默认: ${default_name}): " custom_name || return $?
                name=${custom_name:-$default_name}
            fi
            _create_anytls_tls_node "$node_ip" "$port" "$server_name" "$password" "$name" \
                "$tls_listen_address" "$tls_backend_port" "$tls_router_mode" || return $?
            created=true
            ;;
        2)
            local name custom_name=""
            if [ "$BATCH_MODE" = "true" ]; then
                name="Batch-Any-Reality-${port}"
            else
                local default_name="Any-Reality-${port}"
                _node_read -r -p "请输入 Any-Reality 节点名称 (默认: ${default_name}): " custom_name || return $?
                name=${custom_name:-$default_name}
            fi
            _validate_reality_no_self_loop "$port" "$reality_handshake_server" "$reality_handshake_port" || return 1
            _create_anyreality_node "$node_ip" "$port" "$server_name" "$password" "$name" "$reality_handshake_server" "$reality_handshake_port" \
                "$reality_listen_address" "$reality_backend_port" "$reality_router_mode" || return $?
            created=true
            ;;
        1,2|2,1|"1 2"|"2 1")
            local tls_port="$port"
            local reality_port="$any_reality_port"
            local tls_name reality_name custom_tls_name="" custom_reality_name=""
            if [ "$BATCH_MODE" = "true" ]; then
                tls_name="Batch-AnyTLS-${tls_port}"
                reality_name="Batch-Any-Reality-${reality_port}"
            else
                local default_tls_name="AnyTLS-${tls_port}"
                local default_reality_name="Any-Reality-${reality_port}"
                _info "同时创建时，Any-Reality 将使用端口 ${reality_port}。"
                _node_read -r -p "请输入 AnyTLS 节点名称 (默认: ${default_tls_name}): " custom_tls_name || return $?
                tls_name=${custom_tls_name:-$default_tls_name}
                _node_read -r -p "请输入 Any-Reality 节点名称 (默认: ${default_reality_name}): " custom_reality_name || return $?
                reality_name=${custom_reality_name:-$default_reality_name}
            fi
            _validate_reality_no_self_loop "$reality_port" "$reality_handshake_server" "$reality_handshake_port" || return 1
            _create_anytls_tls_node "$node_ip" "$tls_port" "$server_name" "$password" "$tls_name" \
                "$tls_listen_address" "$tls_backend_port" "$tls_router_mode" || return $?
            _create_anyreality_node "$node_ip" "$reality_port" "$server_name" "$password" "$reality_name" "$reality_handshake_server" "$reality_handshake_port" \
                "$reality_listen_address" "$reality_backend_port" "$reality_router_mode" || return $?
            created=true
            ;;
    esac

    [ "$created" = true ]
}

# 每次节点操作独立提交；菜单等待输入时不长期持有写锁。
_create_anytls_tls_node() { if [ -n "${NODE_TX_DIR:-}" ]; then _create_anytls_tls_node_impl "$@"; else _node_operation _create_anytls_tls_node_impl "$@"; fi; }
_create_anyreality_node() { if [ -n "${NODE_TX_DIR:-}" ]; then _create_anyreality_node_impl "$@"; else _node_operation _create_anyreality_node_impl "$@"; fi; }
_add_anytls() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_anytls_impl; else _node_operation _add_anytls_impl; fi; }
