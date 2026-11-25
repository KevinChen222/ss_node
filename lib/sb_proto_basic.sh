#!/usr/bin/env bash
# PROXYALL_LIB=sb_proto_basic.sh
# 基础代理节点（sing-box）：Shadowsocks（含 SS2022、ShadowTLS）与 SOCKS5。由 sb 加载。

_add_shadowsocks_menu_impl() {
    local choice=""
    if [ "$BATCH_MODE" = "true" ]; then
        choice="$BATCH_SS_VARIANT"
    else
        [ ! -t 0 ] || [ ! -t 1 ] || clear
        echo "========================================"
        _info "          添加 Shadowsocks 节点"
        echo "========================================"
        echo " TCP 多路复用: mihomo smux"
        echo " [经典 SS]"
        echo " 1) aes-256-gcm"
        echo " 2) chacha20-ietf-poly1305"
        echo " [SS-2022 (强抗重放保护)]"
        echo " 3) 2022-blake3-aes-256-gcm"
        echo " 4) 2022-blake3-aes-256-gcm (多路复用 + Padding)"
        echo " [SS-2022 + ShadowTLS (完美伪装组合)]"
        echo " 5) 2022-blake3-aes-256-gcm + ShadowTLS v3"
        echo " 0) 返回"
        echo "========================================"
        _node_read -r -p "请选择加密方式 [0-5]: " choice || return $?
    fi

    local method="" password="" name_prefix="" use_padding=false use_shadowtls=false
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
            use_padding=true
            ;;
        5)
            # SS-2022 256 位版本（抗重放增强）
            method="2022-blake3-aes-256-gcm"
            password=$(${SINGBOX_BIN} generate rand --base64 32)
            name_prefix="SS-ShadowTLS"
            use_shadowtls=true
            ;;
        0) _node_cancel; return 2 ;;
        *) _error "无效输入"; return 1 ;;
    esac

    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
    else
        local custom_ip=""
        _node_read -r -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip || return $?
        node_ip=${custom_ip:-$server_ip}
        _node_read -r -p "请输入监听端口: " port || return $?
        [[ -z "$port" ]] && _error "端口不能为空" && return 1
        _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; return 1; }
    fi
    
    # [!] 新增：自定义名称
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-${name_prefix}-${port}"
    else
        local default_name="${name_prefix}-${port}" custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi
    
    local shadowtls_password=""
    local shadowtls_sni="www.amd.com"
    if [ "$use_shadowtls" == "true" ]; then
        local custom_sni=""
        shadowtls_password=$(${SINGBOX_BIN} generate rand --hex 16)
        if [ "$BATCH_MODE" != "true" ]; then
            _node_read -r -p "请输入 ShadowTLS 伪装白名单域名 (默认: www.amd.com): " custom_sni || return $?
        fi
        shadowtls_sni=${custom_sni:-www.amd.com}
    fi

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "${name_prefix}-in") || return 1
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local inbound_json=""
    local jq_modify_expr=".inbounds += [$inbound_json]"
    
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
                    "password": $pw,
                    "multiplex": {"enabled": true, "padding": false}
                }
            ]')
        jq_modify_expr=".inbounds += $inbound_json"
    else
        inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg m "$method" --arg pw "$password" --argjson padding "$use_padding" \
            '{
                "type": "shadowsocks",
                "tag": $t,
                "listen": "::",
                "listen_port": ($p|tonumber),
                "method": $m,
                "password": $pw,
                "multiplex": {
                    "enabled": true,
                    "padding": $padding
                }
            }')
        jq_modify_expr=".inbounds += [$inbound_json]"
    fi
    _atomic_modify_json "$CONFIG_FILE" "$jq_modify_expr" || return 1

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
    proxy_json=$(jq -c --argjson padding "$use_padding" '. + {smux: {
        enabled: true, protocol: "h2mux", "max-connections": 4,
        "min-streams": 4, "only-tcp": true, padding: $padding
    }}' <<< "$proxy_json") || return 1
    _add_node_to_yaml "$proxy_json" || return 1

    _success "Shadowsocks (${method}) 节点 [${name}] 添加成功!"
    _info "TCP 多路复用: h2mux，Padding: ${use_padding}"
    if [ "$use_shadowtls" == "true" ]; then
        _show_node_link "shadowsocks-shadowtls" "$name" "$link_ip" "$port" "$tag" "$method" "$password" "$shadowtls_password" "$shadowtls_sni"
    else
        _show_node_link "shadowsocks" "$name" "$link_ip" "$port" "$tag" "$method" "$password"
    fi
    return 0
}

_add_socks_impl() {
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
        _node_read -r -p "请输入用户名 (默认随机): " username || return $?
        username=${username:-$(${SINGBOX_BIN} generate rand --hex 8)}
        _node_read -r -p "请输入密码 (默认随机): " password || return $?
        password=${password:-$(${SINGBOX_BIN} generate rand --hex 16)}
    fi
    local name="Batch-SOCKS5-${port}"
    [ "$BATCH_MODE" != "true" ] && name="SOCKS5-${port}"
    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "socks-in") || return 1
    local display_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && display_ip="[$node_ip]"

    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$username" --arg pw "$password" \
        '{"type":"socks","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"username":$u,"password":$pw}]}')
    _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

    local proxy_json=$(jq -n --arg n "$name" --arg s "$display_ip" --arg p "$port" --arg u "$username" --arg pw "$password" \
        '{"name":$n,"type":"socks5","server":$s,"port":($p|tonumber),"username":$u,"password":$pw}')
    _add_node_to_yaml "$proxy_json" || return 1
    _success "SOCKS5 节点添加成功!"
    _show_node_link "socks" "$name" "$display_ip" "$port" "$tag" "$username" "$password"
}
_add_shadowsocks_menu() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_shadowsocks_menu_impl; else _node_operation _add_shadowsocks_menu_impl; fi; }
_add_socks() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_socks_impl; else _node_operation _add_socks_impl; fi; }
