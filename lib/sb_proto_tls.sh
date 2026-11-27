#!/usr/bin/env bash
# PROXYALL_LIB=sb_proto_tls.sh
# TLS/CDN 类节点（sing-box）：VLESS WS TLS、VLESS gRPC TLS、Trojan WS TLS、NaiveProxy。由 sb 加载。

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


_add_vless_ws_tls_impl() {
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
        local connection_address=""
        _node_read -r -p "请输入连接地址 (默认: ${server_ip}): " connection_address || return $?
        client_server_addr=${connection_address:-$server_ip}
        
        # IPv6 处理
        if [[ "$client_server_addr" == *":"* ]] && [[ "$client_server_addr" != "["* ]]; then
             client_server_addr="[${client_server_addr}]"
        fi

        _info "请输入您的“伪装域名”，这个域名必须是您证书对应的域名。"
        _info " (例如: xxx.741865.xyz)"
        _node_read -r -p "请输入伪装域名: " camouflage_domain || return $?
        [[ -z "$camouflage_domain" ]] && _error "伪装域名不能为空" && return 1

        while true; do
            _node_read -r -p "请输入监听端口 (直连模式下首推 443 端口): " port || return $?
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; continue; }
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
        local input_ws_path=""
        _node_read -r -p "请输入 WebSocket 路径 (回车则随机生成): " input_ws_path || return $?
        if [ -z "$input_ws_path" ]; then
            ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
            _info "已为您生成随机 WebSocket 路径: ${ws_path}"
        else
            ws_path="$input_ws_path"
            [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
        fi
    fi

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
        _node_read -r -p "请选择 [1-2] (默认: 1): " cert_choice || return $?
        cert_choice=${cert_choice:-1}
    fi

    if [ "$cert_choice" == "1" ]; then
        skip_verify=true
    else
        # 手动上传证书
        _info "请输入 ${camouflage_domain} 对应的证书文件路径。"
        _info "  - (推荐) 使用 acme.sh 签发的 fullchain.pem"
        _info "  - (或)   使用 Cloudflare 源服务器证书"
        _node_read -r -p "请输入证书文件 .pem/.crt 的完整路径: " cert_path || return $?
        [[ ! -f "$cert_path" ]] && _error "证书文件不存在: ${cert_path}" && return 1

        _node_read -r -p "请输入私钥文件 .key 的完整路径: " key_path || return $?
        [[ ! -f "$key_path" ]] && _error "私钥文件不存在: ${key_path}" && return 1
        
        # 询问是否跳过验证
        local use_origin_cert=""
        _node_read_yes_no "$(echo -e ${YELLOW}"您是否正在使用 Cloudflare 源服务器证书 (或自签名证书)? [y/N]: "${NC})" use_origin_cert || return $?
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
        local default_name="VLESS-WS-${port}" custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "vless-ws-in") || return 1
    if [ "$cert_choice" == "1" ]; then
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1
        _info "已生成自签名证书，客户端将跳过证书验证。"
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
    _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

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
            
    _add_node_to_yaml "$proxy_json" || return 1
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

_add_vless_grpc_tls_impl() {
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
        local connection_address=""
        _node_read -r -p "请输入连接地址 (默认: ${server_ip}): " connection_address || return $?
        client_server_addr=${connection_address:-$server_ip}

        # IPv6 处理
        if [[ "$client_server_addr" == *":"* ]] && [[ "$client_server_addr" != "["* ]]; then
             client_server_addr="[${client_server_addr}]"
        fi

        _info "请输入您的“伪装域名”，这个域名必须是您证书对应的域名。"
        _info " (例如: xxx.741865.xyz)"
        _node_read -r -p "请输入伪装域名: " camouflage_domain || return $?
        [[ -z "$camouflage_domain" ]] && _error "伪装域名不能为空" && return 1

        while true; do
            _node_read -r -p "请输入监听端口 (直连模式下首推 443 端口): " port || return $?
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; continue; }
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
        local input_service_name=""
        _node_read -r -p "请输入 gRPC serviceName (回车则随机生成: ${generated_service_name}): " input_service_name || return $?
        service_name=${input_service_name:-$generated_service_name}
        service_name=$(echo "$service_name" | xargs)
        [[ -z "$service_name" ]] && _error "gRPC serviceName 不能为空" && return 1
        _info "gRPC serviceName: ${service_name}"
    fi

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
        _node_read -r -p "请选择 [1-2] (默认: 1): " cert_choice || return $?
        cert_choice=${cert_choice:-1}
    fi

    if [ "$cert_choice" == "1" ]; then
        skip_verify=true
    else
        _info "请输入 ${camouflage_domain} 对应的证书文件路径。"
        _info "  - (推荐) 使用 acme.sh 签发的 fullchain.pem"
        _info "  - (或)   使用 Cloudflare 源服务器证书"
        _node_read -r -p "请输入证书文件 .pem/.crt 的完整路径: " cert_path || return $?
        [[ ! -f "$cert_path" ]] && _error "证书文件不存在: ${cert_path}" && return 1

        _node_read -r -p "请输入私钥文件 .key 的完整路径: " key_path || return $?
        [[ ! -f "$key_path" ]] && _error "私钥文件不存在: ${key_path}" && return 1

        local use_origin_cert=""
        _node_read_yes_no "$(echo -e ${YELLOW}"您是否正在使用 Cloudflare 源服务器证书 (或自签名证书)? [y/N]: "${NC})" use_origin_cert || return $?
        if [[ "$use_origin_cert" == "y" || "$use_origin_cert" == "Y" ]]; then
            skip_verify=true
            _warning "已启用 'skip-cert-verify: true'。这将跳过证书验证。"
        fi
    fi

    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-VLESS-gRPC-${port}"
    else
        local default_name="VLESS-gRPC-${port}" custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "vless-grpc-in") || return 1
    if [ "$cert_choice" == "1" ]; then
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1
        _info "已生成自签名证书，客户端将跳过证书验证。"
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
    _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

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

    _add_node_to_yaml "$proxy_json" || return 1
    _success "VLESS (gRPC+TLS) 节点 [${name}] 添加成功!"
    _success "客户端连接地址 (server): ${client_server_addr}"
    _success "客户端连接端口 (port): ${client_port}"
    _success "客户端伪装域名 (sni): ${camouflage_domain}"
    _success "gRPC serviceName: ${service_name}"

    [ "$BATCH_MODE" != "true" ] && _show_grpc_cdn_guidance "${camouflage_domain}" "${port}"

    local link_ip="$client_server_addr"
    _show_node_link "vless-grpc-tls" "$name" "$link_ip" "$client_port" "$tag" "$uuid" "$camouflage_domain" "$service_name" "$skip_verify" "$cert_path"
}

_add_trojan_ws_tls_impl() {
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
        local connection_address=""
        _node_read -r -p "请输入连接地址 (默认: ${server_ip}): " connection_address || return $?
        client_server_addr=${connection_address:-$server_ip}
        
        # IPv6 处理
        if [[ "$client_server_addr" == *":"* ]] && [[ "$client_server_addr" != "["* ]]; then
             client_server_addr="[${client_server_addr}]"
        fi

        _info "请输入您的“伪装域名”，这个域名必须是您证书对应的域名。"
        _node_read -r -p "请输入伪装域名: " camouflage_domain || return $?
        [[ -z "$camouflage_domain" ]] && _error "伪装域名不能为空" && return 1

        while true; do
            _node_read -r -p "请输入监听端口 (直连模式下首推 443 端口): " port || return $?
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; continue; }
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
        local input_ws_path=""
        _node_read -r -p "请输入 WebSocket 路径 (回车则随机生成): " input_ws_path || return $?
        if [ -z "$input_ws_path" ]; then
            ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
            _info "已为您生成随机 WebSocket 路径: ${ws_path}"
        else
            ws_path="$input_ws_path"
            [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
        fi
    fi

    local cert_path=""
    local key_path=""
    local skip_verify=false
    local cert_choice="1"

    # --- 步骤 5: 证书选择 ---
    if [ "$BATCH_MODE" = "true" ]; then
        cert_choice="1"
        skip_verify=true
    else
        echo ""
        echo "请选择证书类型:"
        echo "  1) 自动生成自签名证书 (适合CF回源/直连跳过验证)"
        echo "  2) 手动上传证书文件 (acme.sh签发/Cloudflare源证书等)"
        _node_read -r -p "请选择 [1-2] (默认: 1): " cert_choice || return $?
        cert_choice=${cert_choice:-1}
        if [ "$cert_choice" == "1" ]; then
            skip_verify=true
        else
            # 手动上传证书
            _info "请输入 ${camouflage_domain} 对应的证书文件路径。"
            _info "  - (推荐) 使用 acme.sh 签发的 fullchain.pem"
            _info "  - (或)   使用 Cloudflare 源服务器证书"
            _node_read -r -p "请输入证书文件 .pem/.crt 的完整路径: " cert_path || return $?
            [[ ! -f "$cert_path" ]] && _error "证书文件不存在: ${cert_path}" && return 1

            _node_read -r -p "请输入私钥文件 .key 的完整路径: " key_path || return $?
            [[ ! -f "$key_path" ]] && _error "私钥文件不存在: ${key_path}" && return 1
            
            # 询问是否跳过验证
            local use_origin_cert=""
            _node_read_yes_no "$(echo -e ${YELLOW}"您是否正在使用 Cloudflare 源服务器证书 (或自签名证书)? [y/N]: "${NC})" use_origin_cert || return $?
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
        local input_pw=""
        _node_read -r -p "请输入 Trojan 密码 (回车则随机生成): " input_pw || return $?
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
        local default_name="Trojan-WS-${port}" custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "trojan-ws-in") || return 1
    if [ "$cert_choice" == "1" ]; then
        cert_path="${SINGBOX_DIR}/${tag}.pem"
        key_path="${SINGBOX_DIR}/${tag}.key"
        _generate_self_signed_cert "$camouflage_domain" "$cert_path" "$key_path" || return 1
        [ "$BATCH_MODE" = "true" ] || _info "已生成自签名证书，客户端将跳过证书验证。"
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
    _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

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
            
    _add_node_to_yaml "$proxy_json" || return 1
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
_naive_random_alnum() {
    local len="${1:-16}" raw="" chunk
    while [ "${#raw}" -lt "$len" ]; do
        chunk=$(openssl rand -base64 "$((len * 3))" 2>/dev/null | tr -dc 'A-Za-z0-9') || return 1
        raw="${raw}${chunk}"
    done
    printf '%s\n' "${raw:0:len}"
}

_naive_prepare_certificate() {
    local domain="$1"
    local cert_path="${NGINX_CERT_DIR}/${domain}/cert"
    local key_path="${NGINX_CERT_DIR}/${domain}/key"
    if _local_certificate_usable "$domain"; then
        if _validate_anytls_certificate "$cert_path" "$key_path" "$domain" true >/dev/null 2>&1; then
            _info "检测到本机已有有效公网可信证书，将直接复用: ${cert_path}"
            return 0
        fi
        _warn "检测到本机已有证书但未通过系统信任链验证，将尝试通过 acme.sh 申请公网可信证书..."
    fi
    _validate_local_origin_dns "$domain" || return 1
    _ensure_local_origin_dependencies || return 1
    local target="${NGINX_CONF_DIR}/00-sb-naive-acme-${domain}.conf" tmp file status=0
    for file in "$target" "$cert_path" "$key_path"; do
        _xhttp_snapshot_nginx "$file" || return 1
    done
    tmp=$(mktemp) || return 1
    {
        echo '# Managed by proxyall Naive ACME'
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
    _install_managed_nginx_config "$tmp" "$target" '# Managed by proxyall Naive ACME' || status=$?
    rm -f "$tmp"
    [ "$status" = 0 ] || return 1
    _install_sb_acme && _ensure_acme_renewal && _issue_local_origin_certificate "$domain" "$SB_ACME_NAIVE_RELOAD_CMD" || return 1
    _validate_anytls_certificate "$cert_path" "$key_path" "$domain" true
}

_create_naive_node_impl() {
    local domain="${1,,}"
    local port="$2"
    local username="$3"
    local password="$4"
    local name="$5"
    local naive_network="${6:-tcp}"
    local cert_mode="${7:-acme}"
    local cert_path="${8:-}"
    local key_path="${9:-}"
    local listen_address="${10:-::}"
    local backend_port="${11:-$port}"
    local router_mode="${12:-false}"

    _is_valid_reality_domain "$domain" || { _error "域名格式无效: ${domain:-空}"; return 1; }
    _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; return 1; }
    [ -n "$username" ] && [ -n "$password" ] && [ -n "$name" ] || { _error "NaiveProxy 用户名、密码和节点名称不能为空。"; return 1; }
    if [[ "$username" == *:* || "$username" =~ [[:space:][:cntrl:]] ]]; then
        _error "NaiveProxy 用户名不能包含冒号 ':'、空白或控制字符。"
        return 1
    fi
    case "$naive_network" in
        tcp|both) ;;
        *) _error "无效的 NaiveProxy 传输模式: ${naive_network}"; return 1 ;;
    esac
    [ "$router_mode" != true ] || naive_network="tcp"

    case "$cert_mode" in
        acme) ;;
        manual)
            _validate_anytls_certificate "$cert_path" "$key_path" "$domain" true || return 1
            ;;
        *) _error "无效证书模式: ${cert_mode}"; return 1 ;;
    esac

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "naive-in") || return 1

    if [ "$router_mode" = true ]; then
        _sni_router_prepare || return 1
        _sni_router_assert_sni_available "$domain" || return 1
        if [ "$listen_address" != "127.0.0.1" ] || [ "$backend_port" = "$port" ]; then
            backend_port=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
            listen_address="127.0.0.1"
        fi
    else
        _check_port_conflict "$port" tcp && return 1
        if [ "$naive_network" = "both" ]; then
            _check_port_conflict "$port" udp && return 1
        fi
    fi

    jq -e --argjson p "$backend_port" '[.inbounds[] | select(.listen_port == $p and (.type != "hysteria2" and .type != "tuic"))] | length == 0' "$CONFIG_FILE" >/dev/null || {
        _error "后端 TCP 端口已被节点使用: $backend_port"; return 1;
    }

    if [ "$cert_mode" = "acme" ]; then
        _naive_prepare_certificate "$domain" || return 1
        cert_path="${NGINX_CERT_DIR}/${domain}/cert"
        key_path="${NGINX_CERT_DIR}/${domain}/key"
    fi

    local inbound_json
    inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$backend_port" \
        --arg listen "$listen_address" \
        --arg u "$username" \
        --arg pw "$password" \
        --arg sn "$domain" \
        --arg cp "$cert_path" \
        --arg kp "$key_path" \
        --arg net "$naive_network" \
        '{
            "type": "naive",
            "tag": $t,
            "listen": $listen,
            "listen_port": ($p|tonumber),
            "users": [{"username": $u, "password": $pw}],
            "tls": {
                "enabled": true,
                "server_name": $sn,
                "certificate_path": $cp,
                "key_path": $kp
            }
        } + (if $net == "tcp" then {"network": "tcp"} else {} end)') || return 1

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

    local meta_json
    meta_json=$(jq -n \
        --arg n "$name" \
        --arg domain "$domain" \
        --arg net "$naive_network" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        --argjson public "$port" \
        --argjson backend "$backend_port" \
        --argjson routed "$router_mode" \
        '{
            name: $n,
            clientName: $n,
            domain: $domain,
            server_name: $domain,
            yaml: false,
            publicPort: $public,
            backendPort: $backend,
            naiveNetwork: $net,
            certificatePath: $cert,
            keyPath: $key
        } + (if $routed then {frontedBy: "haproxy", routerRole: "tls-sni"} else {} end)') || return 1
    _atomic_modify_json "$METADATA_FILE" ". + {\"$tag\": $meta_json}" || return 1

    if [ "$router_mode" = true ]; then
        _sni_router_register_tls sb "$tag" "$domain" "$backend_port" || return 1
        _info "公网 443 -> HAProxy -> 127.0.0.1:${backend_port} -> Sing-box NaiveProxy (HTTP/2)"
    fi

    _show_node_link "naive" "$name" "$domain" "$port" "$tag" "$username" "$password" "$naive_network" || return 1
    _success "NaiveProxy 节点 [${name}] 添加成功!"
}

_add_naive_impl() {
    local domain="" port="" naive_network="tcp" cert_mode="acme" cert_path="" key_path=""
    local username="" password="" name=""
    local listen_address="::" backend_port="" router_mode=false

    if [ "$BATCH_MODE" = "true" ]; then
        domain="${BATCH_DOMAIN:-${BATCH_SNI:-}}"
        domain=$(echo "$domain" | xargs)
        domain="${domain,,}"
        port="${BATCH_PORT:-443}"
        backend_port="$port"
        if [ "${BATCH_SNI_ROUTER:-false}" = "true" ] && [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
            router_mode=true
            listen_address="127.0.0.1"
            naive_network="tcp"
        else
            naive_network="${BATCH_NAIVE_NETWORK:-tcp}"
        fi
        if [ -n "${BATCH_NAIVE_CERT:-}" ] || [ -n "${BATCH_NAIVE_KEY:-}" ]; then
            cert_mode="manual"
            cert_path="${BATCH_NAIVE_CERT:-}"
            key_path="${BATCH_NAIVE_KEY:-}"
        else
            cert_mode="${BATCH_NAIVE_CERT_MODE:-acme}"
        fi
        username="${BATCH_NAIVE_USER:-$(_naive_random_alnum 16)}" || return 1
        password="${BATCH_NAIVE_PASS:-$(_naive_random_alnum 24)}" || return 1
        name="${BATCH_NAIVE_NAME:-Batch-Naive-${port}}"
    else
        _info "--- 添加 NaiveProxy 节点 (Sing-box) ---"
        _info "说明: sing-box NaiveProxy 客户端要求公网可信 CA 证书，不支持自签证书或 insecure/pcs 跳过验证。"

        _node_read -r -p "请输入节点域名/SNI (必填，需与公网可信证书匹配): " domain || return $?
        domain=$(echo "$domain" | xargs)
        domain="${domain,,}"
        if ! _is_valid_reality_domain "$domain"; then
            _error "域名格式无效: ${domain:-空}，请输入有效的公网域名。"
            return 1
        fi

        while true; do
            _node_read -r -p "请输入监听端口 (默认: 443): " port || return $?
            port="${port:-443}"
            if ! _sni_router_validate_port "$port"; then
                _error "端口必须在 1-65535 之间。"
                continue
            fi
            listen_address="::"
            backend_port="$port"
            router_mode=false
            if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                local use_router=""
                _node_read_yes_no "是否由 HAProxy 复用公网 443（NaiveProxy 可与 Reality/Emby/AnyTLS 共存，仅支持 TCP HTTP/2）？[Y/n]: " use_router || return $?
                if [[ ! "$use_router" =~ ^[Nn]$ ]]; then
                    listen_address="127.0.0.1"
                    router_mode=true
                fi
            fi
            if [ "$router_mode" != true ]; then
                _check_port_conflict "$port" "tcp" && continue
            fi
            break
        done

        if [ "$router_mode" = true ]; then
            naive_network="tcp"
            _info "HAProxy 共享 443 为纯 TCP 透传，本节点仅启用 HTTP/2 (TCP)。"
        else
            echo "请选择传输协议:"
            echo "  1) 仅 HTTP/2 (TCP，默认)"
            echo "  2) HTTP/2 + HTTP/3 QUIC (TCP + UDP)"
            local transport_choice=""
            _node_read -r -p "请选择传输协议 [1-2] (默认: 1): " transport_choice || return $?
            transport_choice="${transport_choice:-1}"
            case "$transport_choice" in
                1) naive_network="tcp" ;;
                2)
                    naive_network="both"
                    if _check_port_conflict "$port" "udp"; then
                        return 1
                    fi
                    ;;
                *) _error "无效传输选项。"; return 1 ;;
            esac
        fi

        echo "请选择公网可信 TLS 证书方式:"
        echo "  1) 自动复用本机有效公网证书或通过 acme.sh 申请 Let's Encrypt 证书（默认）"
        echo "  2) 指定已有公网可信证书与私钥路径（校验信任链、域名和有效期）"
        local cert_choice=""
        _node_read -r -p "请选择证书方式 [1-2] (默认: 1): " cert_choice || return $?
        cert_choice="${cert_choice:-1}"
        case "$cert_choice" in
            1)
                cert_mode="acme"
                cert_path="${NGINX_CERT_DIR}/${domain}/cert"
                key_path="${NGINX_CERT_DIR}/${domain}/key"
                ;;
            2)
                cert_mode="manual"
                _node_read -r -p "完整证书链 .pem/.crt 路径: " cert_path || return $?
                _node_read -r -p "私钥 .key 路径: " key_path || return $?
                ;;
            *) _error "无效证书选项。"; return 1 ;;
        esac

        local default_user default_pass input_user="" input_pass=""
        default_user=$(_naive_random_alnum 16) || return 1
        default_pass=$(_naive_random_alnum 24) || return 1
        _node_read -r -p "请输入用户名 (回车随机生成，不可含冒号 ':'): " input_user || return $?
        username="${input_user:-$default_user}"
        if [[ "$username" == *:* || "$username" =~ [[:space:][:cntrl:]] ]]; then
            _error "NaiveProxy 用户名不能包含冒号 ':'、空白或控制字符。"
            return 1
        fi
        _node_read -r -p "请输入密码 (回车随机生成): " input_pass || return $?
        password="${input_pass:-$default_pass}"

        local default_name="Naive-${port}" custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name="${custom_name:-$default_name}"
    fi

    _create_naive_node_impl "$domain" "$port" "$username" "$password" "$name" \
        "$naive_network" "$cert_mode" "$cert_path" "$key_path" \
        "$listen_address" "$backend_port" "$router_mode"
}

_add_vless_ws_tls() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_vless_ws_tls_impl; else _node_operation _add_vless_ws_tls_impl; fi; }
_add_vless_grpc_tls() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_vless_grpc_tls_impl; else _node_operation _add_vless_grpc_tls_impl; fi; }
_add_trojan_ws_tls() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_trojan_ws_tls_impl; else _node_operation _add_trojan_ws_tls_impl; fi; }
_create_naive_node() { if [ -n "${NODE_TX_DIR:-}" ]; then _create_naive_node_impl "$@"; else _node_operation _create_naive_node_impl "$@"; fi; }
_add_naive() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_naive_impl; else _node_operation _add_naive_impl; fi; }
