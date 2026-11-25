#!/usr/bin/env bash
# PROXYALL_LIB=sb_argo.sh
# Argo 隧道节点：cloudflared 安装、隧道启动停止、守护与卸载。由 sb 加载。

_install_cloudflared() {
    if [ -f "${CLOUDFLARED_BIN}" ]; then
        _info "cloudflared 已安装: $(${CLOUDFLARED_BIN} --version 2>&1 | head -n1)"
        return 0
    fi
    
    _info "正在安装依据环境所需的组件 (ca-certificates)..."
    _pkg_install ca-certificates # 关键修复：Alpine 等精简系统必须有证书才能进行 TLS 握手
    
    _info "正在安装 cloudflared..."
    local arch=$(uname -m)
    local arch_tag
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='arm' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac
    
    local asset_name="cloudflared-linux-${arch_tag}"
    _download_verified_github_asset \
        "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
        "$asset_name" "$CLOUDFLARED_BIN" || return 1
    chmod 700 "${CLOUDFLARED_BIN}"
    if ! "${CLOUDFLARED_BIN}" --version 2>/dev/null | grep -qi 'cloudflared version'; then
        _error "下载的 cloudflared 无法通过版本检查，已拒绝安装。"
        rm -f "${CLOUDFLARED_BIN}"
        return 1
    fi
    touch "${SINGBOX_DIR}/.managed_cloudflared"
    
    _success "cloudflared 安装成功: $(${CLOUDFLARED_BIN} --version 2>&1 | head -n1)"
}

# --- Argo Tunnel 功能 ---

_start_argo_tunnel() {
    local target_port="$1"

    # 基于端口生成独立的 PID 和日志文件路径
    local pid_file="/tmp/singbox_argo_${target_port}.pid"
    local log_file="/tmp/singbox_argo_${target_port}.log"
    
    _info "正在启动 Argo 隧道 (端口: $target_port)..." >&2
    
    # 检查该端口对应的隧道是否已在运行
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if _is_pid_running_cmd "$old_pid" "$CLOUDFLARED_BIN"; then
            _warning "检测到端口 $target_port 的 Argo 隧道已在运行 (PID: $old_pid)" >&2
            return 0
        fi
    fi
    
    # 清理旧日志和同步时间
    rm -f "${log_file}"
    _sync_system_time

    # 仅保留无需 Cloudflare Token 的临时隧道模式。
    _info "启动临时隧道，指向 127.0.0.1:${target_port}..." >&2
    nohup "${CLOUDFLARED_BIN}" tunnel --protocol http2 --no-autoupdate --url "http://127.0.0.1:${target_port}" \
        --logfile "${log_file}" > /dev/null 2>&1 8>&- 9>&- &

    local cf_pid=$!
    echo "$cf_pid" > "${pid_file}"

    _info "等待隧道建立 (最多30秒)..." >&2
    local tunnel_domain=""
    local wait_count=0
    local max_wait=30

    while [ $wait_count -lt $max_wait ]; do
        sleep 2
        wait_count=$((wait_count + 2))
        if ! kill -0 "$cf_pid" 2>/dev/null; then
            _error "cloudflared 进程已退出，请检查日志: ${log_file}" >&2
            tail -n 20 "${log_file}" 2>/dev/null >&2
            return 1
        fi
        if [ -f "${log_file}" ]; then
            tunnel_domain=$(grep -oE 'https?://[a-zA-Z0-9-]+\.trycloudflare\.com' "${log_file}" 2>/dev/null | head -n 1 | sed -E 's|https?://||')
            [ -n "$tunnel_domain" ] && break
        fi
        echo -n "." >&2
    done
    echo "" >&2

    if [ -z "$tunnel_domain" ]; then
        _error "获取临时域名超时。请检查网络。日志最后几行：" >&2
        tail -n 5 "${log_file}" 2>/dev/null >&2
        kill "$cf_pid" 2>/dev/null
        rm -f "${pid_file}"
        return 1
    fi

    _info "域名已获取，正在进行稳定性测试 (5秒)..." >&2
    sleep 5
    if ! kill -0 "$cf_pid" 2>/dev/null; then
        _error "稳定性测试失败：cloudflared 进程异常退出。" >&2
        tail -n 10 "${log_file}" 2>/dev/null >&2
        return 1
    fi

    _enable_argo_watchdog
    _success "Argo 临时隧道建立成功: ${tunnel_domain}" >&2
    echo "$tunnel_domain"
}

_stop_argo_tunnel() {
    local target_port="$1"
    if [ -z "$target_port" ]; then
        return
    fi
    
    local pid_file="/tmp/singbox_argo_${target_port}.pid"
    local log_file="/tmp/singbox_argo_${target_port}.log"

    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
            kill "$pid" 2>/dev/null
            _success "Argo 隧道 (端口: $target_port) 已停止"
        fi
        rm -f "$pid_file" "$log_file"
    fi
}

_stop_all_argo_tunnels() {
    _info "正在停止所有 Argo 隧道..."
    local stopped_any=false
    for pid_file in /tmp/singbox_argo_*.pid; do
        [ -e "$pid_file" ] || continue
        # 解析端口
        local filename=$(basename "$pid_file")
        local port=${filename#singbox_argo_}
        port=${port%.pid}
        _stop_argo_tunnel "$port"
        stopped_any=true
    done
    if [ "$stopped_any" = false ]; then
        _warn "未找到本脚本记录的 Argo PID 文件，未执行全局 cloudflared 清理。"
    fi
}

_sanitize_argo_metadata() {
    [ -s "$ARGO_METADATA_FILE" ] || return 0
    if jq -e 'any(.[]; has("token") or .type == "fixed")' "$ARGO_METADATA_FILE" >/dev/null 2>&1; then
        local legacy_rows
        legacy_rows=$(jq -r 'to_entries[] | select(.value | has("token") or .type == "fixed") | [.key, (.value.local_port|tostring), (.value.protocol // "vless-ws"), (.value.name // .key), (.value.uuid // ""), (.value.password // ""), (.value.path // "/")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
        _warning "检测到旧版固定 Argo 配置：将停止其进程、删除本地 Token，并转换为临时隧道。"
        _atomic_modify_json "$ARGO_METADATA_FILE" 'with_entries(.value |= (del(.token) | .type = "temp"))' || return 1

        local tag port protocol name uuid password path new_domain
        while IFS=$'\t' read -r tag port protocol name uuid password path; do
            [ -z "$tag" ] && continue
            _stop_argo_tunnel "$port"
            new_domain=$(_start_argo_tunnel "$port")
            if [ -n "$new_domain" ]; then
                _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$new_domain\""
                if [ "$protocol" = "vless-ws" ]; then
                    _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$path" >/dev/null
                else
                    _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$path" >/dev/null
                fi
            else
                _warning "旧固定隧道 ${name} 已停止，但临时隧道启动失败；可在 Argo 菜单中手动重启。"
            fi
        done <<< "$legacy_rows"
    fi
    chmod 600 "$ARGO_METADATA_FILE" 2>/dev/null || true
}

# ============================================================
# 统一 Argo 节点创建函数 (消除 VLESS/Trojan 重复代码)
# 参数: $1 = 协议类型 ("vless" 或 "trojan")
# ============================================================
_add_argo_node_locked() {
    local protocol="$1"
    local protocol_label=""
    local proto_name=""
    case "$protocol" in
        vless) protocol_label="VLESS-WS"; proto_name="Vless" ;;
        trojan) protocol_label="Trojan-WS"; proto_name="Trojan" ;;
        *) _error "不支持的 Argo 协议: $protocol"; return 1 ;;
    esac

    _info "--- 创建 ${protocol_label} + Argo 隧道节点 ---"

    # 安装 cloudflared
    _install_cloudflared || return 1

    # === [公共] 内部端口分配 ===
    read -p "请输入 Argo 内部监听端口 (回车随机生成): " input_port
    local port="$input_port"

    while true; do
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            _check_port_conflict "$port" "tcp" && port="" && continue
            _info "已使用监听端口: ${port}"
            break
        else
            [ -n "$port" ] && _warning "端口格式无效，将重新生成..."
            # 使用内建算法生成随机端口 (10000-60000)，移除 shuf 依赖
            port=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 50001 + 10000 ))
            _info "正在尝试分配随机内部端口: ${port}..."
        fi
    done

    # === [公共] WebSocket 路径 ===
    read -p "请输入 WebSocket 路径 (回车随机生成): " ws_path
    if [ -z "$ws_path" ]; then
        ws_path="/"$(${SINGBOX_BIN} generate rand --hex 8)
        _info "已生成随机路径: ${ws_path}"
    else
        [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"
    fi

    # === [协议特定] Trojan 密码输入 ===
    local password=""
    if [ "$protocol" == "trojan" ]; then
        read -p "请输入 Trojan 密码 (回车随机生成): " password
        if [ -z "$password" ]; then
            password=$(${SINGBOX_BIN} generate rand --hex 16)
            _info "已生成随机密码: ${password}"
        fi
    fi

    # 仅保留无需 Cloudflare Token 的临时隧道。
    echo ""
    _info "将创建无需 Token 的 Argo 临时隧道；隧道重启后域名会变化。"
    _info "如需固定自有域名，请创建 WS/gRPC + TLS 节点，并按脚本提示手动配置 Cloudflare DNS/回源规则。"
    local tunnel_domain=""
    local argo_type="temp"

    # === [公共] 节点名称 ===
    local default_prefix="Argo-Temp"
    local default_name="${default_prefix}-${proto_name}-${port}"

    echo ""
    read -p "请输入节点名称 (默认: ${default_name}): " custom_name
    local name=${custom_name:-$default_name}

    # === [协议特定] 生成凭据、tag 和 Inbound ===
    local tag="argo-${protocol}-ws-${port}"
    local uuid=""
    local inbound_json=""

    if [ "$protocol" == "vless" ]; then
        uuid=$(${SINGBOX_BIN} generate uuid)
        inbound_json=$(jq -n \
            --arg t "$tag" \
            --arg p "$port" \
            --arg u "$uuid" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "type": "vless",
                "tag": $t,
                "listen": "127.0.0.1",
                "listen_port": ($p|tonumber),
                "users": [{"uuid": $u, "flow": ""}],
                "transport": {
                    "type": "ws",
                    "path": $wsp,
                    "max_early_data": $ed,
                    "early_data_header_name": $edh
                }
            }')
    elif [ "$protocol" == "trojan" ]; then
        inbound_json=$(jq -n \
            --arg t "$tag" \
            --arg p "$port" \
            --arg pw "$password" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "type": "trojan",
                "tag": $t,
                "listen": "127.0.0.1",
                "listen_port": ($p|tonumber),
                "users": [{"password": $pw}],
                "transport": {
                    "type": "ws",
                    "path": $wsp,
                    "max_early_data": $ed,
                    "early_data_header_name": $edh
                }
            }')
    fi

    _atomic_modify_json "$CONFIG_FILE" ".inbounds += [$inbound_json]" || return 1

    # === [公共] 重启 + 启动隧道 ===
    _manage_service "restart"
    sleep 2

    local real_domain=$(_start_argo_tunnel "$port")
    if [ -z "$real_domain" ]; then
        _error "隧道启动失败，正在回滚配置..."
        _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
        _manage_service "restart"
        return 1
    fi
    tunnel_domain="$real_domain"

    # === [协议特定] 保存元数据 ===
    local credential_key="" credential_val=""
    if [ "$protocol" == "vless" ]; then
        credential_key="uuid"; credential_val="$uuid"
    else
        credential_key="password"; credential_val="$password"
    fi

    local argo_meta=$(jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg domain "$tunnel_domain" \
        --arg port "$port" \
        --arg cred_val "$credential_val" \
        --arg cred_key "$credential_key" \
        --arg path "$ws_path" \
        --arg protocol "${protocol}-ws" \
        --arg type "$argo_type" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, domain: $domain, local_port: ($port|tonumber), ($cred_key): $cred_val, path: $path, protocol: $protocol, type: $type, created_at: $created}}')

    if [ ! -f "$ARGO_METADATA_FILE" ]; then
        echo '{}' > "$ARGO_METADATA_FILE"
    fi
    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $argo_meta"

    # === [协议特定] Clash 配置 + 分享链接 ===
    local proxy_json=""
    if [ "$protocol" == "vless" ]; then
        proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$tunnel_domain" \
            --arg u "$uuid" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "name": $n,
                "type": "vless",
                "server": $s,
                "port": 443,
                "uuid": $u,
                "tls": true,
                "udp": true,
                "skip-cert-verify": false,
                "network": "ws",
                "servername": $s,
                "ws-opts": {
                    "path": $wsp,
                    "max-early-data": $ed,
                    "early-data-header-name": $edh,
                    "headers": {
                        "Host": $s
                    }
                }
            }')
    elif [ "$protocol" == "trojan" ]; then
        proxy_json=$(jq -n \
            --arg n "$name" \
            --arg s "$tunnel_domain" \
            --arg pw "$password" \
            --arg wsp "$ws_path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" \
            --arg edh "$WS_EARLY_DATA_HEADER" \
            '{
                "name": $n,
                "type": "trojan",
                "server": $s,
                "port": 443,
                "password": $pw,
                "udp": true,
                "skip-cert-verify": false,
                "network": "ws",
                "sni": $s,
                "ws-opts": {
                    "path": $wsp,
                    "max-early-data": $ed,
                    "early-data-header-name": $edh,
                    "headers": {
                        "Host": $s
                    }
                }
            }')
    fi

    _add_node_to_yaml "$proxy_json"

    # === [公共] 启用守护 + 显示结果 ===
    _enable_argo_watchdog

    echo ""
    _success "${protocol_label} + Argo 节点创建成功!"
    echo "-------------------------------------------"
    echo -e "节点名称: ${GREEN}${name}${NC}"
    echo -e "隧道类型: ${CYAN}临时隧道（无需 Token）${NC}"
    echo -e "隧道域名: ${CYAN}${tunnel_domain}${NC}"
    echo -e "本地端口: ${port}"
    echo "-------------------------------------------"
    
    # 使用统一链接生成器进行展示与持久化
    if [ "$protocol" == "vless" ]; then
        _show_node_link "vless-ws" "$name" "$tunnel_domain" "443" "$tag" "$uuid" "$ws_path"
    else
        _show_node_link "trojan-ws" "$name" "$tunnel_domain" "443" "$tag" "$password" "$ws_path"
    fi
    
    echo "-------------------------------------------"
    _warning "注意: 临时隧道每次重启域名会变化！"
}

# 保留原始函数名作为薄包装器，确保向后兼容
_add_argo_vless_ws() { _add_argo_node "vless"; }

_add_argo_trojan_ws() { _add_argo_node "trojan"; }

_view_argo_nodes() {
    _info "--- Argo 隧道节点信息 ---"
    
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点。"
        return
    fi
    
    echo "==================================================="
    # 遍历并显示
    jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.type)|\(.value.protocol)|\(.value.local_port)|\(.value.domain)|\(.value.uuid // "")|\(.value.path // "")|\(.value.password // "")"' "$ARGO_METADATA_FILE" | \
    while IFS='|' read -r tag name argo_type protocol port domain uuid path password; do
        echo -e "节点: ${GREEN}${name}${NC}"
        echo -e "  协议: ${protocol}"
        echo -e "  端口: ${port}"
        
        # 检查状态
        local pid_file="/tmp/singbox_argo_${port}.pid"
        local state="${RED}已停止${NC}"
        local running_domain=""
        
        # [M4] 一次读取 PID 到变量，避免重复 cat
        local pid=""
        if [ -f "$pid_file" ]; then pid=$(cat "$pid_file" 2>/dev/null); fi
        if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
             state="${GREEN}运行中${NC} (PID: $pid)"
             # 如果是临时的，尝试从 log 读最新域名
             if [ "$argo_type" == "temp" ] || [ -z "$domain" ] || [ "$domain" == "null" ]; then
                  local log_file="/tmp/singbox_argo_${port}.log"
                  local temp_domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -1 | sed 's|https://||')
                   [ -n "$temp_domain" ] && domain="$temp_domain"
             fi
             running_domain="$domain"
        fi
        
        if [ -n "$domain" ] && [ "$domain" != "null" ]; then
             local link=""
             
             # [新架构] 优先使用持久化链接
             link=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$ARGO_METADATA_FILE")
             
              if [ -z "$link" ] || [ "$link" == "null" ]; then
                  local safe_name=$(_url_encode "$name")
                  local ed_path=$(_ws_path_with_early_data "$path")
                  local safe_path=$(_url_encode "$ed_path")
                  
                  if [[ "$protocol" == "vless-ws" ]]; then
                      link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
                 elif [[ "$protocol" == "trojan-ws" ]]; then
                     local safe_pw=$(_url_encode "$password")
                     link="trojan://${safe_pw}@${domain}:443?security=tls&type=ws&host=${domain}&path=${safe_path}&sni=${domain}#${safe_name}"
                 fi
             fi

             if [ -n "$link" ]; then
                  echo -e "  ${YELLOW}链接:${NC} $link"
             fi
        fi
        echo "-------------------------------------------"
    done
    
    echo -e "${YELLOW}提示: 请使用 [9] 重启隧道 来刷新所有节点状态或获取新临时域名。${NC}"
    echo "==================================================="
}

_delete_argo_node_locked() {
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点可删除。"
        return
    fi
    
    _info "--- 删除 Argo 隧道节点 ---"
    
    # 读取所有节点到数组
    local i=1
    local keys=()
    local names=()
    local ports=()
    
    # 必须使用 while read 处理 process substitution 避免子 shell 问题
    while IFS='|' read -r key name port; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE")
    
    if [ ${#keys[@]} -eq 0 ]; then
         _warning "读取元数据失败。"
         return
    fi

    echo " 0) 返回"
    read -p "请选择要删除的节点: " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "${#keys[@]}" ]; then
        _error "无效输入"
        return
    fi
    
    if [ "$choice" -eq 0 ]; then return; fi
    
    local idx=$((choice - 1))
    local selected_key="${keys[$idx]}"
    local selected_name="${names[$idx]}"
    local selected_port="${ports[$idx]}"
    
    _info "正在删除节点: ${selected_name} (端口: ${selected_port})..."
    
    # 1. 停止该节点的隧道进程
    _stop_argo_tunnel "$selected_port"
    
    # 2. 从 sing-box 配置文件中移除 inbound
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$selected_key\"))"
    
    # 3. 删除 Argo 元数据
    jq "del(.\"$selected_key\")" "$ARGO_METADATA_FILE" > "${ARGO_METADATA_FILE}.tmp" && mv "${ARGO_METADATA_FILE}.tmp" "$ARGO_METADATA_FILE"
    
    # 4. 删除 Clash 配置
    _remove_node_from_yaml "$selected_name"
    
    # 5. 检查是否还有节点，如果没有则禁用守护进程
    if [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        _disable_argo_watchdog
    fi

    # 6. 重启 sing-box
    _manage_service "restart"
    
    _success "节点 ${selected_name} 已删除！"
}

_stop_argo_menu() {
    _info "--- 停止 Argo 隧道进程 (保留配置) ---"
    # 复用选择逻辑
    local i=1
    local keys=()
    local names=()
    local ports=()
    
    while IFS='|' read -r key name port; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE")
    
    echo " a) 停止所有运行中的隧道"
    echo " 0) 返回"
    read -p "请选择: " choice
    
    if [ "$choice" == "a" ]; then
        _stop_all_argo_tunnels
        _success "所有隧道已停止指令发送。"
        return
    fi
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "${#keys[@]}" ]; then
        _error "无效输入"
        return
    fi
    if [ "$choice" -eq 0 ]; then return; fi
    
    local idx=$((choice - 1))
    local selected_port="${ports[$idx]}"
    
    _stop_argo_tunnel "$selected_port"
}

_restart_argo_tunnel_menu_locked() {
    _info "--- 重启 Argo 隧道 ---"
    
     if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE")" -eq 0 ]; then
        _warning "没有 Argo 隧道节点。"
        return
    fi

    # 选择逻辑
    local i=1
    local keys=()
    local names=()
    local ports=()
    local protocols=()
    local uuids=()
    local passwords=()
    local paths=()
    
    while IFS='|' read -r key name port proto uuid pw path; do
        keys+=("$key")
        names+=("$name")
        ports+=("$port")
        protocols+=("$proto")
        uuids+=("$uuid")
        passwords+=("$pw")
        paths+=("$path")
        echo -e " ${CYAN}$i)${NC} ${name} (端口: $port)"
        ((i++))
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.local_port)|\(.value.protocol)|\(.value.uuid // \"\")|\(.value.password // \"\")|\(.value.path // \"/\")"' "$ARGO_METADATA_FILE")
    
    echo " a) 重启所有节点"
    echo " 0) 返回"
    read -p "请选择: " choice
    
    local selected_indices=()
    if [ "$choice" == "a" ]; then
        # 生成所有索引
        for ((j=0; j<${#keys[@]}; j++)); do selected_indices+=($j); done
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#keys[@]}" ]; then
        selected_indices+=($((choice - 1)))
    else
        if [ "$choice" -ne 0 ]; then _error "无效输入"; fi
        return
    fi

    for i in "${!selected_indices[@]}"; do
        local idx="${selected_indices[$i]}"
        local tag="${keys[$idx]}"
        local name="${names[$idx]}"
        local port="${ports[$idx]}"
        local proto_full="${protocols[$idx]}"
        local uuid="${uuids[$idx]}"
        local password="${passwords[$idx]}"
        local ws_path="${paths[$idx]}"

        _info "正在重启: $name (端口: $port)..."
        
        # 停止
        _stop_argo_tunnel "$port"
        sleep 1
        
        local new_domain=$(_start_argo_tunnel "$port")
        if [ -n "$new_domain" ]; then
            _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$new_domain\" | .\"$tag\".type = \"temp\" | del(.\"$tag\".token)"
            _success "更新临时域名: $new_domain"

            if [[ "$proto_full" == "vless-ws" ]]; then
                _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$ws_path" >/dev/null
            else
                _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$ws_path" >/dev/null
            fi
        else
            _error "临时隧道重启失败: $name"
        fi
    done
    _success "操作完成。"
}

# --- Argo 守护进程逻辑 ---

_argo_keepalive_locked() {
    # --- 性能优化: 互斥锁 ---
    local lock_dir="/tmp/singbox_keepalive.lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        # 锁目录存在，等待所有权文件写入
        sleep 0.1 2>/dev/null || sleep 1
        local pid=""
        [ -f "$lock_dir/pid" ] && pid=$(cat "$lock_dir/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # 进程仍在运行，跳过本次执行
            return
        fi
        # 进程已死，强制清除残留锁目录并重试
        rm -rf "$lock_dir" 2>/dev/null
        mkdir -p "$lock_dir" 2>/dev/null || return
    fi
    echo "$$" > "$lock_dir/pid"
    # 确保退出时删除锁
    trap 'rm -rf "$lock_dir"' RETURN EXIT

    # 如果元数据文件不存在或为空，不需要守护
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        return
    fi

    # 遍历所有节点
    local i=0
    # [资源优化] 合并提取所有必要元数据，支持域名链接同步
    while IFS=$'\t' read -r tag port protocol name uuid password path; do
        [ -z "$tag" ] && continue
        
        local pid_file="/tmp/singbox_argo_${port}.pid"
        local is_running=false
        
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
                is_running=true
            fi
        fi
        
        if [ "$is_running" = false ]; then
            logger "sing-box-watchdog: Detected dead tunnel for $tag (Port: $port). Restarting..."
            local new_domain=$(_start_argo_tunnel "$port")
            if [ -n "$new_domain" ]; then
                _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$tag\".domain = \"$new_domain\" | .\"$tag\".type = \"temp\" | del(.\"$tag\".token)"
                logger "sing-box-watchdog: Temp tunnel $tag restarted with new domain: $new_domain"
                if [[ "$protocol" == "vless-ws" ]]; then
                    _show_node_link "vless-ws" "$name" "$new_domain" "443" "$tag" "$uuid" "$path" >/dev/null
                else
                    _show_node_link "trojan-ws" "$name" "$new_domain" "443" "$tag" "$password" "$path" >/dev/null
                fi
            else
                logger "sing-box-watchdog: Failed to restart temp tunnel $tag."
            fi
        fi
    done < <(jq -r 'to_entries[] | [.key, (.value.local_port|tostring), (.value.protocol // "vless-ws"), .value.name, (.value.uuid // ""), (.value.password // ""), (.value.path // "")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
}

_enable_argo_watchdog() {
    # 检查 crontab 是否已有任务
    local job="* * * * * bash ${SELF_SCRIPT_PATH} keepalive >/dev/null 2>&1"
    
    if ! crontab -l 2>/dev/null | grep -Fq "$job"; then
        _info "正在添加后台守护进程 (Watchdog)..."
        (crontab -l 2>/dev/null; echo "$job") | crontab -
        if [ $? -eq 0 ]; then
            _success "守护进程已启用！(每分钟检查并自动修复失效隧道)"
        else
            _warning "添加 Crontab 失败，守护进程未生效。"
        fi
    fi
}

_disable_argo_watchdog() {
    local job="bash ${SELF_SCRIPT_PATH} keepalive"
    
    if crontab -l 2>/dev/null | grep -Fq "$job"; then
        _info "正在移除后台守护进程..."
        crontab -l 2>/dev/null | grep -Fv "$job" | crontab -
        _success "守护进程已移除。"
    fi
}

_uninstall_argo_locked() {
    local managed_cloudflared=false
    [ -f "${SINGBOX_DIR}/.managed_cloudflared" ] && managed_cloudflared=true
    _warning "！！！警告！！！"
    _warning "本操作将删除所有 Argo 临时隧道节点。"
    echo ""
    echo "即将删除的内容："
    [ "$managed_cloudflared" = "true" ] && echo -e "  ${RED}-${NC} 本脚本安装的 cloudflared: ${CLOUDFLARED_BIN}"
    echo -e "  ${RED}-${NC} 所有 Argo 日志文件和元数据文件"
    
    if [ -f "$ARGO_METADATA_FILE" ]; then
        local argo_count=$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null || echo "0")
        echo -e "  ${RED}-${NC} Argo 节点数量: ${argo_count} 个"
    fi
    
    echo ""
    read -p "$(echo -e ${YELLOW}"确定要卸载 Argo 服务吗? (y/N): "${NC})" confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        _info "卸载已取消。"
        return
    fi
    
    _info "正在卸载 Argo 服务..."
    
    # 1. 停止所有隧道进程
    _stop_all_argo_tunnels
    
    # 2. 删除 sing-box 中的 Argo inbound 配置
    if [ -f "$ARGO_METADATA_FILE" ]; then
         # 同样需要遍历删除逻辑，这里简化为遍历 metadata 删除
         # 为防止 jq 读写竞争，先收集所有 tags
        local tags=$(jq -r 'keys[]' "$ARGO_METADATA_FILE" 2>/dev/null)
        for tag in $tags; do
             if [ -n "$tag" ]; then
                _info "正在删除 Argo 隧道: $tag ..."
                # [修复] 先读取节点名，再删除元数据
                local node_name=$(jq -r ".\"$tag\".name" "$ARGO_METADATA_FILE" 2>/dev/null)
    _atomic_modify_json "$ARGO_METADATA_FILE" "del(.\""$tag"\")" 2>/dev/null
    _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"
                
                if [ -n "$node_name" ] && [ "$node_name" != "null" ]; then
                    _remove_node_from_yaml "$node_name"
                fi
             fi
        done
    fi
    
    # 3. 移除守护进程
    _disable_argo_watchdog

    # 4. 仅删除由本脚本安装的 cloudflared，不影响系统原有 Cloudflare 配置。
    _stop_all_argo_tunnels 2>/dev/null
    rm -f /tmp/singbox_argo_*.pid /tmp/singbox_argo_*.log
    rm -f "${ARGO_METADATA_FILE}"
    if [ "$managed_cloudflared" = "true" ]; then
        rm -f "${CLOUDFLARED_BIN}" "${SINGBOX_DIR}/.managed_cloudflared"
    else
        _info "检测到 cloudflared 并非由本脚本安装，已保留二进制及 /etc/cloudflared。"
    fi
    
    # 4. 重启 sing-box
    _manage_service "restart"
    
    _success "Argo 服务已完全卸载！"
}

_view_argo_logs() {
    if [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null)" -eq 0 ]; then
        _warning "当前没有任何 Argo 隧道节点。"
        return
    fi

    _info "--- 选择要查看日志的 Argo 隧道 ---"
    local tags=$(jq -r 'keys[]' "$ARGO_METADATA_FILE")
    local i=1
    local tag_list=()
    for tag in $tags; do
        local name=$(jq -r ".\"$tag\".name" "$ARGO_METADATA_FILE")
        local port=$(jq -r ".\"$tag\".local_port" "$ARGO_METADATA_FILE")
        echo "  ${i}) ${name} (端口: ${port})"
        tag_list[$i]=$tag
        ((i++))
    done
    echo "  0) 返回上级菜单"
    read -p "请输入选项: " log_choice
    [[ "$log_choice" == "0" || -z "$log_choice" ]] && return

    local selected_tag=${tag_list[$log_choice]}
    if [ -n "$selected_tag" ]; then
        local port=$(jq -r ".\"$selected_tag\".local_port" "$ARGO_METADATA_FILE")
        local log_file="/tmp/singbox_argo_${port}.log"
        if [ -f "$log_file" ]; then
            _info "正在查看隧道日志 [${selected_tag}]，按 Ctrl+C 退出。"
            tail -f "$log_file"
        else
            _error "日志文件不存在: ${log_file}"
        fi
    else
        _error "无效选项"
    fi
}

_sync_argo_early_data_locked() {
    local config_updated=false
    local links_updated=false
    local yaml_updated=false

    export WS_ED="$WS_EARLY_DATA_SIZE"
    export WS_EDH="$WS_EARLY_DATA_HEADER"

    if [ -s "$CONFIG_FILE" ] && jq -e 'any(.inbounds[]?; ((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws") and (((.transport.max_early_data // 0) != (env.WS_ED | tonumber)) or ((.transport.early_data_header_name // "") != env.WS_EDH))))' "$CONFIG_FILE" >/dev/null 2>&1; then
        _atomic_modify_json "$CONFIG_FILE" '(.inbounds[] | select((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws")) | .transport.max_early_data) = (env.WS_ED | tonumber) | (.inbounds[] | select((.tag // "" | startswith("argo-")) and ((.transport.type // "") == "ws")) | .transport.early_data_header_name) = env.WS_EDH' || return 1
        config_updated=true
    fi

    if [ -s "$ARGO_METADATA_FILE" ]; then
        while IFS=$'\t' read -r tag protocol name domain uuid password path share_link; do
            [ -z "$tag" ] && continue
            [[ "$protocol" != "vless-ws" && "$protocol" != "trojan-ws" ]] && continue
            [[ -z "$domain" || "$domain" == "null" ]] && continue

            if [ -s "$CLASH_YAML_FILE" ] && [ -x "$YQ_BINARY" ] && [ -n "$name" ] && [ "$name" != "null" ]; then
                export PROXY_NAME="$name"
                local yaml_needs_update
                yaml_needs_update=$(${YQ_BINARY} eval '.proxies[] | select(.name == strenv(PROXY_NAME) and .network == "ws" and (((.["ws-opts"]["max-early-data"] // "") | tostring) != strenv(WS_ED) or (.["ws-opts"]["early-data-header-name"] // "") != env(WS_EDH))) | .name' "$CLASH_YAML_FILE" 2>/dev/null | head -n 1)
                if [ -n "$yaml_needs_update" ] && [ "$yaml_needs_update" != "null" ]; then
                    _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == strenv(PROXY_NAME) and .network == "ws") | .["ws-opts"]["max-early-data"]) = (env(WS_ED) | tonumber) | (.proxies[] | select(.name == strenv(PROXY_NAME) and .network == "ws") | .["ws-opts"]["early-data-header-name"]) = env(WS_EDH)' >/dev/null 2>&1 && yaml_updated=true
                fi
            fi

            if [[ "$share_link" == *"ed%3D${WS_EARLY_DATA_SIZE}"* || "$share_link" == *"ed=${WS_EARLY_DATA_SIZE}"* ]]; then
                continue
            fi

            if [[ "$protocol" == "vless-ws" && -n "$uuid" && "$uuid" != "null" ]]; then
                _show_node_link "vless-ws" "$name" "$domain" "443" "$tag" "$uuid" "$path" >/dev/null
                links_updated=true
            elif [[ "$protocol" == "trojan-ws" && -n "$password" && "$password" != "null" ]]; then
                _show_node_link "trojan-ws" "$name" "$domain" "443" "$tag" "$password" "$path" >/dev/null
                links_updated=true
            fi
        done < <(jq -r 'to_entries[] | [.key, (.value.protocol // "vless-ws"), (.value.name // ""), (.value.domain // ""), (.value.uuid // ""), (.value.password // ""), (.value.path // "/"), (.value.share_link // "")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    if [ "$config_updated" = true ]; then
        _info "已为既有 Argo WS 节点补齐 Early Data 配置，正在重启 sing-box..."
        _manage_service restart
    elif [ "$links_updated" = true ] || [ "$yaml_updated" = true ]; then
        _info "已同步既有 Argo WS 节点的 Early Data 客户端配置。"
    fi
}

_argo_menu() {
    _sanitize_argo_metadata || return 1
    _sync_argo_early_data
    while true; do
        [ ! -t 0 ] || [ ! -t 1 ] || clear
        echo -e "${CYAN}"
        echo '  ╔═══════════════════════════════════════╗'
        echo '  ║           Argo 隧道节点管理           ║'
        echo '  ╚═══════════════════════════════════════╝'
        echo -e "${NC}"
        
        echo -e "  ${CYAN}【创建节点】${NC}"
        echo -e "    ${YELLOW}仅提供无需 Token 的临时 trycloudflare.com 隧道${NC}"
        echo -e "    ${GREEN}[1]${NC} 创建 VLESS-WS + Argo 节点"
        echo -e "    ${GREEN}[2]${NC} 创建 Trojan-WS + Argo 节点"
        echo ""
        
        echo -e "  ${CYAN}【节点管理】${NC}"
        echo -e "    ${GREEN}[3]${NC} 查看 Argo 节点信息"
        echo -e "    ${GREEN}[4]${NC} 查看 Argo 隧道日志"
        echo -e "    ${GREEN}[5]${NC} 删除 Argo 节点"
        echo ""
        
        echo -e "  ${CYAN}【隧道控制】${NC}"
        echo -e "    ${RED}[6]${NC} 卸载 Argo 服务"
        echo -e "    ${GREEN}[7]${NC} 重启 Argo 隧道"
        echo ""
        
        echo -e "  ─────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
        echo ""
        
        read -p "  请输入选项 [0-7]: " choice

        case $choice in
            1) _add_argo_vless_ws ;;
            2) _add_argo_trojan_ws ;;
            3) _view_argo_nodes ;;
            4) _view_argo_logs ;;
            5) _delete_argo_node ;;
            6) _uninstall_argo ;;
            7) _restart_argo_tunnel_menu ;;
            0) break ;;
            *) _error "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# 辅助写入同样串行化，避免节点回滚覆盖保活、DNS 或核心升级的修改。
_add_argo_node() ( _config_write_lock || exit 1; _add_argo_node_locked "$@"; )
_delete_argo_node() ( _config_write_lock || exit 1; _delete_argo_node_locked; )
_restart_argo_tunnel_menu() ( _config_write_lock || exit 1; _restart_argo_tunnel_menu_locked; )
_argo_keepalive() ( _config_write_lock || exit 1; _argo_keepalive_locked; )
_uninstall_argo() ( _config_write_lock || exit 1; _uninstall_argo_locked; )
_sync_argo_early_data() ( _config_write_lock || exit 1; _sync_argo_early_data_locked; )
