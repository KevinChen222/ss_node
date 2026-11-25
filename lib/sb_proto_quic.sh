#!/usr/bin/env bash
# PROXYALL_LIB=sb_proto_quic.sh
# QUIC 类节点（sing-box）：Hysteria2 与 TUICv5。由 sb 加载。

_add_hysteria2_impl() {
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
        local custom_ip="" camouflage_domain=""
        _node_read -r -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip || return $?
        node_ip=${custom_ip:-$server_ip}
        while true; do
            _node_read -r -p "请输入监听端口: " port || return $?
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; continue; }
            _check_port_conflict "$port" "udp" && continue
            break
        done
        _node_read -r -p "请输入伪装域名 (默认: www.amd.com): " camouflage_domain || return $?
        server_name=${camouflage_domain:-"www.amd.com"}
    fi

    local password=""
    if [ "$BATCH_MODE" = "true" ]; then
        password=$(${SINGBOX_BIN} generate rand --hex 16)
    else
        local h_choice="" hop_choice="" port_range=""
        _node_read -r -p "请输入密码 (默认随机): " password || return $?
        password=${password:-$(${SINGBOX_BIN} generate rand --hex 16)}
        _node_read_yes_no "是否开启 QUIC 流量混淆 (salamander)? [y/N]: " h_choice || return $?
        if [[ "$h_choice" == "y" || "$h_choice" == "Y" ]]; then
            obfs_password=$(${SINGBOX_BIN} generate rand --hex 16)
        fi
        _node_read_yes_no "是否开启端口跳跃? [y/N]: " hop_choice || return $?
        if [[ "$hop_choice" == "y" || "$hop_choice" == "Y" ]]; then
            _node_read -r -p "请输入端口范围 (如 20000-30000): " port_range || return $?
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
                hop_conflict=$(_find_udp_hop_conflict_in_range "$port_range_start" "$port_range_end" "")
                if [ -n "$hop_conflict" ]; then
                    local c_tag c_name c_range c_mode
                    IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$hop_conflict"
                    _error "端口跳跃范围 ${port_range} 与已有跳跃范围 ${c_range} 重叠。"
                    _error "冲突节点: ${c_name} (${c_tag}, ${c_mode})。请调整跳跃范围。"
                    return 1
                fi
                port_hopping="$port_range"
                use_multiport="true"
            else
                _error "端口跳跃范围格式无效，应为 start-end。"
                return 1
            fi
        fi
    fi
    
    # [!] 自定义名称
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-Hysteria2-${port}"
    else
        local default_name="Hysteria2-${port}" custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "hy2-in") || return 1
    local cert_path="${SINGBOX_DIR}/${tag}.pem"
    local key_path="${SINGBOX_DIR}/${tag}.key"
    _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1
    
    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local up="${up_speed:-100}"
    local down="${down_speed:-100}"

    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$password" --arg op "$obfs_password" --arg cert "$cert_path" --arg key "$key_path" \
        '{"type":"hysteria2","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"password":$pw}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}} | if $op != "" then .obfs={"type":"salamander","password":$op} else . end')
    _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

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
                _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += $batch_array" || return 1
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
    _add_node_to_yaml "$proxy_json" || return 1
    
    _success "Hysteria2 节点 [${name}] 添加成功!"
    
    # 显示端口跳跃信息
    if [ -n "$port_hopping" ]; then
        _info "端口跳跃范围: ${port_hopping}"
    fi
    
    _show_node_link "hysteria2" "$name" "$link_ip" "$port" "$tag" "$password" "$server_name" "$obfs_password" "$port_hopping"
}

_add_tuic_impl() {
    local node_ip="${server_ip}"
    [[ "$BATCH_MODE" == "true" && -n "$BATCH_IP" ]] && node_ip="$BATCH_IP"
    local port=""
    local server_name="www.amd.com"

    if [ "$BATCH_MODE" = "true" ]; then
        port="$BATCH_PORT"
        server_name="${BATCH_SNI:-www.amd.com}"
    else
        local custom_ip="" camouflage_domain=""
        _node_read -r -p "请输入服务器IP地址 (默认: ${server_ip}): " custom_ip || return $?
        node_ip=${custom_ip:-$server_ip}
        while true; do
            _node_read -r -p "请输入监听端口: " port || return $?
            [[ -z "$port" ]] && _error "端口不能为空" && continue
            _sni_router_validate_port "$port" || { _error "端口必须在 1-65535 之间。"; continue; }
            _check_port_conflict "$port" "udp" && continue
            break
        done
        _node_read -r -p "请输入伪装域名 (默认: www.amd.com): " camouflage_domain || return $?
        server_name=${camouflage_domain:-"www.amd.com"}
    fi

    # [!] 自主生成与名称分配
    local name=""
    if [ "$BATCH_MODE" = "true" ]; then
        name="Batch-TUICv5-${port}"
    else
        local default_name="TUICv5-${port}" custom_name=""
        _node_read -r -p "请输入节点名称 (默认: ${default_name}): " custom_name || return $?
        name=${custom_name:-$default_name}
    fi

    _node_tx_begin || return 1
    _assert_node_name_free "$name" || return 1
    local tag
    tag=$(_new_node_tag "tuic-in") || return 1
    local cert_path="${SINGBOX_DIR}/${tag}.pem"
    local key_path="${SINGBOX_DIR}/${tag}.key"
    
    _generate_self_signed_cert "$server_name" "$cert_path" "$key_path" || return 1

    local uuid=$(${SINGBOX_BIN} generate uuid); local password=$(${SINGBOX_BIN} generate rand --hex 16)

    local yaml_ip="$node_ip"
    local link_ip="$node_ip"; [[ "$node_ip" == *":"* ]] && link_ip="[$node_ip]"

    local inbound_json=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$uuid" --arg pw "$password" --arg cert "$cert_path" --arg key "$key_path" \
        '{"type":"tuic","tag":$t,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"password":$pw}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}')
    _assert_node_name_free "$name" || return 1
    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1
    
    local proxy_json=$(jq -n --arg n "$name" --arg s "$yaml_ip" --arg p "$port" --arg u "$uuid" --arg pw "$password" --arg sn "$server_name" \
        '{"name":$n,"type":"tuic","server":$s,"port":($p|tonumber),"uuid":$u,"password":$pw,"sni":$sn,"skip-cert-verify":true,"alpn":["h3"],"udp-relay-mode":"native","congestion-controller":"bbr"}')
    _add_node_to_yaml "$proxy_json" || return 1
    _success "TUICv5 节点 [${name}] 添加成功!"
    _show_node_link "tuic" "$name" "$link_ip" "$port" "$tag" "$uuid" "$password" "$server_name"
}
_add_hysteria2() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_hysteria2_impl; else _node_operation _add_hysteria2_impl; fi; }
_add_tuic() { if [ -n "${NODE_TX_DIR:-}" ]; then _add_tuic_impl; else _node_operation _add_tuic_impl; fi; }
