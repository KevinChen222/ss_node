#!/usr/bin/env bash
# PROXYALL_LIB=sb_proto_tls.sh
# TLS/CDN 类节点（sing-box）：VLESS WS TLS、VLESS gRPC TLS、Trojan WS TLS。由 sb 加载。

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
_add_vless_ws_tls() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_vless_ws_tls_impl; else _node_operation _add_vless_ws_tls_impl; fi; }
_add_vless_grpc_tls() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_vless_grpc_tls_impl; else _node_operation _add_vless_grpc_tls_impl; fi; }
_add_trojan_ws_tls() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_trojan_ws_tls_impl; else _node_operation _add_trojan_ws_tls_impl; fi; }
