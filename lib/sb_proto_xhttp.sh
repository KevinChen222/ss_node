#!/usr/bin/env bash
# PROXYALL_LIB=sb_proto_xhttp.sh
# Xray 备用核心与两种 XHTTP 节点（TLS/H2、Reality）：安装、创建、改端口、编辑与删除。由 sb 加载。

_xray_begin_add() {
    _node_tx_begin || return 1
    _assert_node_name_free "$1"
}

_xray_validate() {
    local config
    config=$(_node_candidate_path "$XRAY_CONFIG_FILE")
    [ -f "$config" ] || return 0
    jq -e 'type == "object" and (.inbounds | type == "array")' "$config" >/dev/null || return 1
    jq -e '.inbounds | length > 0' "$config" >/dev/null || return 0
    [ -x "$XRAY_BIN" ] || { _error '未找到 Xray 内核。'; return 1; }
    "$XRAY_BIN" run -test -format json -config stdin: < "$config" || return 1
}

_xray_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet proxyall-xray ;;
        openrc) rc-service proxyall-xray status >/dev/null 2>&1 ;;
        *) _is_pid_file_running_cmd "$XRAY_PID_FILE" "$XRAY_BIN" ;;
    esac
}

_xray_service() {
    local action="$1" pid
    if [ ! -x "$XRAY_BIN" ]; then
        [ "$action" != status ] || _info 'Xray: 未安装'
        return 0
    fi
    [ -z "${NODE_TX_DIR:-}" ] || touch "$NODE_TX_DIR/xray-touched"
    if [ "$action" = status ]; then
        if _xray_running; then _info 'Xray: 运行中'; else _info 'Xray: 已停止'; fi
        return 0
    fi
    if [[ "$action" == start || "$action" == restart ]]; then
        if ! jq -e '.inbounds | length > 0' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then action=stop; fi
    fi
    case "$INIT_SYSTEM" in
        systemd)
            [ -f /etc/systemd/system/proxyall-xray.service ] || { [ "$action" = stop ] || _error '缺少 proxyall-xray 服务，请从菜单更新内核。'; [ "$action" = stop ]; return $?; }
            if [ "$action" != stop ]; then
                systemctl is-enabled --quiet proxyall-xray || systemctl enable proxyall-xray || return 1
            elif ! jq -e '.inbounds | length>0' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
                systemctl disable proxyall-xray || return 1
            fi
            systemctl "$action" proxyall-xray 8>&- 9>&- || return 1
            [[ "$action" == stop ]] || _xray_running || return 1 ;;
        openrc)
            [ -f /etc/init.d/proxyall-xray ] || { [ "$action" = stop ]; return $?; }
            if [ "$action" != stop ]; then rc-update add proxyall-xray default || return 1
            elif [ -L /etc/runlevels/default/proxyall-xray ] && ! jq -e '.inbounds | length>0' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
                rc-update del proxyall-xray default || return 1
            fi
            rc-service proxyall-xray "$action" 8>&- 9>&- || return 1
            [[ "$action" == stop ]] || _xray_running || return 1 ;;
        *)
            if [[ "$action" == stop || "$action" == restart ]]; then
                if _is_pid_file_running_cmd "$XRAY_PID_FILE" "$XRAY_BIN"; then
                    pid=$(cat "$XRAY_PID_FILE")
                    kill "$pid" || return 1
                    local attempt
                    for attempt in {1..30}; do
                        _is_pid_running_cmd "$pid" "$XRAY_BIN" || break
                        sleep 0.1
                    done
                    _is_pid_running_cmd "$pid" "$XRAY_BIN" && return 1
                fi
                rm -f "$XRAY_PID_FILE"
            fi
            if [[ "$action" == start || "$action" == restart ]]; then
                _xray_running && return 0
                nohup "$XRAY_BIN" run -config "$XRAY_CONFIG_FILE" >> "$XRAY_LOG_FILE" 2>&1 8>&- 9>&- &
                echo $! > "$XRAY_PID_FILE"
                sleep 1
                _xray_running || { _error "Xray 启动失败，请检查 ${XRAY_LOG_FILE}。"; return 1; }
            fi ;;
    esac
    return 0
}

_xray_restore_install() {
    if [ -f "$work/previous" ]; then mv -f "$work/previous" "$XRAY_BIN" || return 1
    else rm -f "$XRAY_BIN" || return 1; fi
    if [ -n "$service" ]; then
        if [ -f "$work/service" ]; then cp -p "$work/service" "$service" || return 1
        else rm -f "$service" || return 1; fi
        [ "$INIT_SYSTEM" != systemd ] || systemctl daemon-reload || return 1
    fi
    [ "$had_marker" = true ] || rm -f "${SINGBOX_DIR}/.managed_xray"
    [ "$was_running" != true ] || _xray_service restart
}

_install_xray() {
    local update="${1:-false}" asset work target_dir service had_marker=false was_running=false
    [ "$update" = true ] || [ ! -x "$XRAY_BIN" ] || return 0
    target_dir=$(dirname "$XRAY_BIN")
    if [ -e "$XRAY_BIN" ] && [ ! -f "${SINGBOX_DIR}/.managed_xray" ]; then
        _error "Xray 路径已有其他程序，拒绝覆盖: $XRAY_BIN"; return 1
    fi
    case "$INIT_SYSTEM" in
        systemd) service=/etc/systemd/system/proxyall-xray.service ;;
        openrc) service=/etc/init.d/proxyall-xray ;;
        *) service='' ;;
    esac
    if [ -n "$service" ] && [ -e "$service" ] && ! grep -Fqx '# Managed by proxyall Xray' "$service"; then
        _error "服务文件不属于本脚本: $service"; return 1
    fi
    case "$(uname -m)" in
        x86_64|amd64) asset=Xray-linux-64.zip ;;
        aarch64|arm64) asset=Xray-linux-arm64-v8a.zip ;;
        armv7l) asset=Xray-linux-arm32-v7a.zip ;;
        *) _error 'Xray 不支持当前 CPU 架构。'; return 1 ;;
    esac
    local dependency
    for dependency in curl wget jq unzip; do
        command -v "$dependency" >/dev/null 2>&1 || _pkg_install "$dependency" || return 1
    done
    install -d -m 700 "$target_dir" "$SINGBOX_DIR" || return 1
    work=$(mktemp -d "$target_dir/.xray-install.XXXXXX") || return 1
    _info '正在下载并校验官方 Xray 内核...'
    if ! _download_verified_github_asset https://api.github.com/repos/XTLS/Xray-core/releases/latest "$asset" "$work/xray.zip" ||
       ! unzip -p "$work/xray.zip" xray > "$work/xray" || ! chmod 700 "$work/xray" || ! "$work/xray" version; then
        rm -rf -- "$work"; return 1
    fi
    if [ -f "$XRAY_CONFIG_FILE" ] && jq -e '.inbounds | length > 0' "$XRAY_CONFIG_FILE" >/dev/null; then
        "$work/xray" run -test -config "$XRAY_CONFIG_FILE" || { rm -rf -- "$work"; return 1; }
    fi
    [ ! -f "$XRAY_BIN" ] || cp -p "$XRAY_BIN" "$work/previous" || { rm -rf -- "$work"; return 1; }
    [ -z "$service" ] || [ ! -f "$service" ] || cp -p "$service" "$work/service" || { rm -rf -- "$work"; return 1; }
    [ ! -f "${SINGBOX_DIR}/.managed_xray" ] || had_marker=true
    _xray_running && was_running=true
    mv -f "$work/xray" "$XRAY_BIN" || { rm -rf -- "$work"; return 1; }
    touch "${SINGBOX_DIR}/.managed_xray"
    if [ "$INIT_SYSTEM" = systemd ]; then
        cat > "$service" <<EOF
# Managed by proxyall Xray
[Unit]
Description=Proxyall Xray
ConditionPathExists=$XRAY_CONFIG_FILE
After=network.target nss-lookup.target
[Service]
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload || { _xray_restore_install; rm -rf -- "$work"; return 1; }
    elif [ "$INIT_SYSTEM" = openrc ]; then
        cat > "$service" <<EOF
#!/sbin/openrc-run
# Managed by proxyall Xray
description="Proxyall Xray"
command="$XRAY_BIN"
command_args="run -config $XRAY_CONFIG_FILE"
supervisor="supervise-daemon"
respawn_delay=3
pidfile="$XRAY_PID_FILE"
output_log="$XRAY_LOG_FILE"
error_log="$XRAY_LOG_FILE"
depend() {
    need net
}
EOF
        chmod 700 "$service"
    fi
    if ! _configure_runtime_log_output; then
        _xray_restore_install
        rm -rf -- "$work"; return 1
    fi
    if [ "$was_running" = true ] && ! _xray_service restart; then
        _xray_restore_install
        rm -rf -- "$work"; return 1
    fi
    rm -rf -- "$work"
    _success 'Xray 内核安装完成。'
}

_xhttp_snapshot_nginx() {
    [ -n "${NODE_TX_DIR:-}" ] || return 0
    local target="$1" index
    touch "$NODE_TX_DIR/nginx-paths"
    grep -Fxq "$target" "$NODE_TX_DIR/nginx-paths" && return 0
    index=$(wc -l < "$NODE_TX_DIR/nginx-paths")
    [ ! -e "$target" ] || cp -p -- "$target" "$NODE_TX_DIR/nginx.$index" || return 1
    printf '%s\n' "$target" >> "$NODE_TX_DIR/nginx-paths"
}

_xhttp_restore_nginx() {
    [ -f "$NODE_TX_DIR/nginx-paths" ] || return 0
    local target index=0
    while IFS= read -r target; do
        if [ -f "$NODE_TX_DIR/nginx.$index" ]; then cp -p -- "$NODE_TX_DIR/nginx.$index" "$target" || return 1
        else rm -f -- "$target" || return 1; fi
        index=$((index+1))
    done < "$NODE_TX_DIR/nginx-paths"
    _sb_reload_or_start_nginx
}

_xhttp_nginx_config() {
    local domain="$1" path="$2" backend="$3" public="$4" routed="$5"
    local listen="0.0.0.0:$public" options='' http2=' http2' directive='' version ipv6=''
    if [ "$routed" = true ]; then listen="127.0.0.1:$SNI_ROUTER_HTTPS_BACKEND_PORT"; options=' proxy_protocol'; fi
    version=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p')
    if [ -n "$version" ] && _version_at_least "$version" 1.25.1; then http2=''; directive='    http2 on;'; fi
    if [ "$routed" != true ] && [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 0 ]; then
        ipv6="    listen [::]:$public ssl$http2;"
    fi
    cat <<EOF
# Managed by proxyall XHTTP
server {
    listen $listen ssl$options$http2;
$ipv6
$directive
    server_name $domain;
    ssl_certificate $NGINX_CERT_DIR/$domain/cert;
    ssl_certificate_key $NGINX_CERT_DIR/$domain/key;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    location ^~ $path {
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:$backend;
    }
    location / { return 404; }
}
EOF
}

_xhttp_prepare_certificate() {
    local domain="$1" target="$NGINX_CONF_DIR/00-sb-xhttp-acme-$1.conf" tmp file
    _local_certificate_usable "$domain" && return 0
    _validate_local_origin_dns "$domain" || return 1
    for file in "$target" "$NGINX_CERT_DIR/$domain/cert" "$NGINX_CERT_DIR/$domain/key"; do
        _xhttp_snapshot_nginx "$file" || return 1
    done
    tmp=$(mktemp) || return 1
    cat > "$tmp" <<EOF
# Managed by proxyall XHTTP ACME
server {
    listen 80;
    server_name $domain;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF
    _install_managed_nginx_config "$tmp" "$target" '# Managed by proxyall XHTTP ACME'
    local status=$?
    rm -f "$tmp"
    [ "$status" = 0 ] || return 1
    _install_sb_acme && _ensure_acme_renewal && _issue_local_origin_certificate "$domain"
}

_xhttp_prepare_domain() {
    local domain="$1" dump origin challenge allow_origin=false allow_challenge=false status xr
    origin="$NGINX_CONF_DIR/$domain.$REALITY_LOCAL_ORIGIN_PORT.reality.conf"
    challenge="$NGINX_CONF_DIR/00-sb-reality-acme-$domain.conf"
    xr=$(_node_candidate_path "$XRAY_CONFIG_FILE") || return 1
    if [ -f "$xr" ]; then
        status=0
        jq -e --arg domain "$domain" 'any(.inbounds[]; .streamSettings.security == "reality" and any(.streamSettings.realitySettings.serverNames[]; ascii_downcase == $domain))' "$xr" >/dev/null || status=$?
        if [ "$status" = 0 ]; then
            _error '此域名仍有 Reality 节点使用，请先删除相关节点或更换域名。'; return 1
        elif [ "$status" != 1 ]; then
            _error '无法检查 Xray Reality 配置，域名配置未改动。'; return 1
        fi
    fi
    dump=$(nginx -T 2>/dev/null) || return 1
    if [ -f "$origin" ] && [ ! -L "$origin" ] && grep -Fqx '# Generated by singbox-lite Reality local origin' "$origin"; then
        allow_origin=true
        status=0
        jq -se --arg domain "$domain" '
            any(.[] | .. | objects;
                .tls.reality.enabled == true and
                (((.tls.server_name // "") | ascii_downcase) == $domain or
                 ((.tls.reality.handshake.server // "") | ascii_downcase) == $domain))
        ' "$CONFIG_FILE" "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" >/dev/null || status=$?
        if [ "$status" = 0 ]; then
            _error '此域名仍有 Reality 节点或中转使用，请先删除相关节点或更换域名。'; return 1
        elif [ "$status" != 1 ]; then
            _error '无法检查 Reality 配置，域名配置未改动。'; return 1
        fi
    fi
    if [ -f "$challenge" ] && [ ! -L "$challenge" ] && grep -Fqx '# Generated by singbox-lite Reality local origin' "$challenge"; then
        allow_challenge=true
    fi
    if awk -v domain="$domain" -v origin="$origin" -v challenge="$challenge" \
        -v allow_origin="$allow_origin" -v allow_challenge="$allow_challenge" '
        /^# configuration file / {file=$0; sub(/^# configuration file /,"",file); sub(/:$/,"",file)}
        file == origin && allow_origin == "true" {next}
        file == challenge && allow_challenge == "true" {next}
        $1 == "server_name" {
            for(i=2;i<=NF;i++) {gsub(/;/,"",$i); if(tolower($i)==domain) found=1}
        }
        END {exit !found}
    ' <<< "$dump"; then
        _error '此域名已有 Nginx 站点，请使用独立的 XHTTP 子域名。'; return 1
    fi
    if [ "$allow_origin" = true ]; then
        _xhttp_snapshot_nginx "$origin" && _sb_backup_nginx_file "$origin" || return 1
        rm -f -- "$origin" || return 1
        _sb_reload_or_start_nginx || return 1
    fi
    return 0
}

# 在开启写事务前读取公共创建选项，保留 _node_read 的取消状态。
_xhttp_read_node_options() {
    local default_name="$1" input_path input_name input_concurrency input_profile
    _node_read -r -p '请输入 XHTTP 路径 (默认: 自动生成): ' input_path || return $?
    input_path="${input_path:-/$(openssl rand -hex 12)/}"
    [[ "$input_path" =~ ^/([a-zA-Z0-9_-]+/)+$ ]] || { _error '路径须以 / 开始和结束，中间使用字母、数字、下划线或短横线。'; return 1; }
    _node_read -r -p "请输入节点名称 (默认: ${default_name}): " input_name || return $?
    input_name="${input_name:-$default_name}"
    while true; do
        _node_read -r -p '请输入 XHTTP XMUX 每条连接的最大并发数 (默认: 1): ' input_concurrency || return $?
        input_concurrency="${input_concurrency:-1}"
        if [[ "$input_concurrency" =~ ^[0-9]{1,10}$ ]] && (( 10#$input_concurrency >= 1 && 10#$input_concurrency <= 2147483647 )); then
            break
        fi
        _error 'XMUX 并发数必须是 1-2147483647 之间的整数。'
    done
    input_profile=$(_vless_encryption_profile_prompt) || return $?
    printf -v "$2" '%s' "$input_path"
    printf -v "$3" '%s' "$input_name"
    printf -v "$4" '%d' "$((10#$input_concurrency))"
    printf -v "$5" '%s' "$input_profile"
}

# TLS 和 Reality 共用 mihomo 节点结构，后两项参数仅供 Reality 使用。
_xhttp_client_proxy() {
    local name="$1" server="$2" port="$3" uuid="$4" encryption="$5" domain="$6" path="$7" concurrency="$8"
    jq -nc --arg name "$name" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" \
        --arg enc "$encryption" --arg domain "$domain" --arg path "$path" --arg concurrency "$concurrency" \
        --arg pub "${9:-}" --arg sid "${10:-}" '
        {name:$name,type:"vless",server:$server,port:$port,uuid:$uuid,encryption:$enc,tls:true,udp:true,
         network:"xhttp",servername:$domain,alpn:["h2"],"client-fingerprint":"chrome"} +
        (if $pub == "" then {"skip-cert-verify":false}
         else {"reality-opts":{"public-key":$pub,"short-id":$sid,"support-x25519mlkem768":true}} end) +
        {"xhttp-opts":{path:$path,host:$domain,mode:"stream-up",
         "reuse-settings":{"max-concurrency":$concurrency,"h-max-reusable-secs":"1800"}}}'
}

_add_vless_xhttp_tls_impl() {
    local profile decryption=none encryption=none
    local node_ip domain port name path tag uuid backend routed=false use_router target proxy meta inbound custom_ip concurrency
    [ -n "$server_ip" ] || server_ip=$(_get_ip)
    _node_read -r -p "请输入服务器IP地址或连接域名 (默认: ${server_ip}): " custom_ip || return $?
    node_ip="${custom_ip:-$server_ip}"
    if ! _is_valid_reality_domain "$node_ip" && ! _is_valid_ipv4 "$node_ip" && ! [[ "$node_ip" == *:* && "$node_ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
        _error '服务器地址须为 IP 或域名。'; return 1
    fi
    echo '自有域名需解析到本机。Nginx 提供 TLS / HTTP/2；申请证书需要公网 TCP 80 可达。'
    _node_read -r -p '请输入 XHTTP 自有域名: ' domain || return $?
    domain="${domain,,}"
    _is_valid_reality_domain "$domain" || { _error '自有域名格式无效。'; return 1; }
    _node_read -r -p '请输入监听端口 (默认: 443): ' port || return $?
    port="${port:-443}"
    _sni_router_validate_port "$port" || { _error '端口必须在 1-65535 之间。'; return 1; }
    if [ "$port" = 443 ]; then
        _node_read_yes_no '是否由 HAProxy 复用公网 443（Emby 与 Reality 可共存）？[Y/n]: ' use_router || return $?
        [[ "$use_router" =~ ^[Nn]$ ]] || routed=true
    fi
    _xhttp_read_node_options "VLESS-XHTTP-${port}" path name concurrency profile || return $?
    _xray_begin_add "$name" || return 1
    _ensure_local_origin_dependencies || return 1
    _xhttp_prepare_domain "$domain" || return 1
    if [ "$routed" = true ]; then
        _sni_router_prepare || return 1
        _sni_router_assert_sni_available "$domain" || return 1
    elif _check_port_in_config "$port"; then
        _error "端口 $port 已被现有节点配置占用。"; return 1
    elif _check_port_occupied "$port" tcp; then
        # Nginx 的同端口虚拟主机可按域名共存。
        if ! ss -lnpt "sport = :$port" 2>/dev/null | grep -q '"nginx"'; then
            _error "端口 $port 已被其他服务使用。"; return 1
        fi
    fi
    _install_xray || return 1
    _vless_encryption_keypair "$profile" || return 1
    _xhttp_prepare_certificate "$domain" || return 1
    backend=$(_sni_router_allocate_backend_port 10080) || return 1
    tag=$(_new_node_tag xhttp-in) || return 1
    uuid=$(cat /proc/sys/kernel/random/uuid) || return 1
    target="$NGINX_CONF_DIR/$tag.xhttp.conf"
    _xhttp_snapshot_nginx "$target" || return 1
    inbound=$(jq -nc --arg dec "$decryption" --arg tag "$tag" --arg id "$uuid" --arg path "$path" --arg host "$domain" --argjson port "$backend" \
        '{tag:$tag,listen:"127.0.0.1",port:$port,protocol:"vless",settings:{clients:[{id:$id}],decryption:$dec},streamSettings:{network:"xhttp",security:"none",xhttpSettings:{path:$path,host:$host,mode:"stream-up"}}}') || return 1
    _atomic_modify_json "$XRAY_CONFIG_FILE" ".inbounds += [$inbound]" || return 1
    meta=$(jq -nc --arg name "$name" --arg domain "$domain" --arg path "$path" --arg conf "$target" --argjson public "$port" --argjson backend "$backend" --argjson routed "$routed" \
        '{name:$name,core:"xray",type:"vless-xhttp",server_name:$domain,path:$path,nginxConfig:$conf,publicPort:$public,backendPort:$backend,frontedBy:(if $routed then "haproxy" else "nginx" end),routerRole:"xhttp-https"}') || return 1
    _atomic_modify_json "$METADATA_FILE" ".[$(jq -Rn --arg t "$tag" '$t')] = $meta" || return 1
    proxy=$(_xhttp_client_proxy "$name" "$node_ip" "$port" "$uuid" "$encryption" "$domain" "$path" "$concurrency") || return 1
    _add_node_to_yaml "$proxy" || return 1
    _xhttp_nginx_config "$domain" "$path" "$backend" "$port" "$routed" > "$NODE_TX_DIR/xhttp-nginx"
    _install_managed_nginx_config "$NODE_TX_DIR/xhttp-nginx" "$target" '# Managed by proxyall XHTTP' || return 1
    if [ "$routed" = true ]; then _sni_router_register_https sb-xhttp "$domain" "$SNI_ROUTER_HTTPS_BACKEND_PORT" || return 1; fi
    _show_node_link vless-xhttp-tls "$name" "$node_ip" "$port" "$tag" "$uuid" "$domain" "$path" "$concurrency"
}

_add_vless_xhttp_reality_impl() {
    local profile decryption=none encryption=none
    local node_ip domain handshake_server handshake_port port backend listen="::" routed=false answer
    local path name concurrency tag uuid keypair private_key public_key short_id target inbound meta proxy
    [ -n "$server_ip" ] || server_ip=$(_get_ip)
    _node_read -r -p "请输入服务器IP地址或连接域名 (默认: ${server_ip}): " node_ip || return $?
    node_ip="${node_ip:-$server_ip}"
    if ! _is_valid_reality_domain "$node_ip" && ! _is_valid_ipv4 "$node_ip" && ! [[ "$node_ip" == *:* && "$node_ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
        _error '服务器地址须为 IP 或域名。'; return 1
    fi
    _select_reality_sni || return $?
    domain="$SELECTED_REALITY_SNI"
    handshake_server="$SELECTED_REALITY_HANDSHAKE_SERVER"
    handshake_port="$SELECTED_REALITY_HANDSHAKE_PORT"
    _node_read -r -p '请输入监听端口 (默认: 443): ' port || return $?
    port="${port:-443}"
    _sni_router_validate_port "$port" || { _error '端口必须在 1-65535 之间。'; return 1; }
    if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
        _node_read_yes_no '是否由 HAProxy 复用公网 443？[Y/n]: ' answer || return $?
        [[ "$answer" =~ ^[Nn]$ ]] || routed=true
    fi
    _xhttp_read_node_options "VLESS-XHTTP-REALITY-${port}" path name concurrency profile || return $?
    _validate_reality_no_self_loop "$port" "$handshake_server" "$handshake_port" || return 1
    _xray_begin_add "$name" || return 1
    backend="$port"
    if [ "$routed" = true ]; then
        _sni_router_prepare || return 1
        _sni_router_assert_sni_available "$domain" || return 1
        jq -e '.reality == null' "$SNI_ROUTER_STATE_FILE" >/dev/null || {
            _error '公网 443 已登记 Reality 后端，请使用其他端口。'; return 1;
        }
        backend=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
        listen=127.0.0.1
    elif _check_port_conflict "$port" tcp; then return 1; fi
    if [ -n "${NODE_PENDING_ORIGIN:-}" ]; then
        _prepare_local_reality_origin "$NODE_PENDING_ORIGIN" || return 1
        NODE_PENDING_ORIGIN=''
    fi
    _install_xray || return 1
    _vless_encryption_keypair "$profile" || return 1
    uuid=$("$XRAY_BIN" uuid) || return 1
    keypair=$("$XRAY_BIN" x25519) || return 1
    private_key=$(awk -F': ' '$1=="PrivateKey"{print $2}' <<< "$keypair")
    public_key=$(awk -F': ' '$1=="Password (PublicKey)" || $1=="PublicKey" || $1=="Password"{print $2}' <<< "$keypair")
    short_id=$(openssl rand -hex 8) || return 1
    [ -n "$uuid" ] && [ -n "$private_key" ] && [ -n "$public_key" ] || return 1
    tag=$(_new_node_tag xhttp-in) || return 1
    target="$handshake_server"
    [[ "$target" != *:* || "$target" == \[* ]] || target="[$target]"
    target="${target}:${handshake_port}"
    inbound=$(jq -nc --arg dec "$decryption" --arg tag "$tag" --arg id "$uuid" --arg path "$path" --arg host "$domain" \
        --arg listen "$listen" --argjson port "$backend" --arg target "$target" --arg key "$private_key" --arg sid "$short_id" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$id}],decryption:$dec},streamSettings:{network:"xhttp",security:"reality",realitySettings:{target:$target,serverNames:[$host],privateKey:$key,shortIds:[$sid],minClientVer:"1.8.2"},xhttpSettings:{path:$path,host:$host,mode:"stream-up"}}}') || return 1
    _atomic_modify_json "$XRAY_CONFIG_FILE" ".inbounds += [$inbound]" || return 1
    meta=$(jq -nc --arg name "$name" --arg domain "$domain" --arg path "$path" --arg hs "$handshake_server" \
        --argjson hp "$handshake_port" --arg pub "$public_key" --arg sid "$short_id" \
        --argjson public "$port" --argjson backend "$backend" --argjson routed "$routed" \
        '{name:$name,core:"xray",type:"vless-xhttp-reality",server_name:$domain,path:$path,publicKey:$pub,shortId:$sid,handshakeServer:$hs,handshakePort:$hp,publicPort:$public,backendPort:$backend} + (if $routed then {frontedBy:"haproxy",routerRole:"reality-default"} else {} end)') || return 1
    _atomic_modify_json "$METADATA_FILE" ".[$(jq -Rn --arg t "$tag" '$t')] = $meta" || return 1
    proxy=$(_xhttp_client_proxy "$name" "$node_ip" "$port" "$uuid" "$encryption" "$domain" "$path" "$concurrency" \
        "$public_key" "$short_id") || return 1
    _add_node_to_yaml "$proxy" || return 1
    [ "$routed" != true ] || _sni_router_register_reality sb-xhttp "$tag" "$domain" "$backend" || return 1
    _show_node_link vless-xhttp-reality "$name" "$node_ip" "$port" "$tag" "$uuid" "$domain" "$path" "$public_key" "$short_id" "$concurrency"
}

_modify_xhttp_reality_port() {
    local tag="$1" port="$2" meta name domain backend="$2" listen="::" routed="${3:-false}" answer
    meta=$(jq -ce --arg t "$tag" '.[$t]' "$METADATA_FILE") || return 1
    name=$(jq -r '.clientName' <<< "$meta"); domain=$(jq -r '.server_name' <<< "$meta")
    _validate_reality_no_self_loop "$port" "$(jq -r '.handshakeServer' <<< "$meta")" "$(jq -r '.handshakePort' <<< "$meta")" || return 1
    if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ] && [ -z "${3:-}" ]; then
        _node_read_yes_no '是否由 HAProxy 复用公网 443？[Y/n，0 返回节点列表]: ' answer || return $?
        [[ "$answer" =~ ^[Nn]$ ]] || routed=true
    fi
    _node_tx_begin || return 1
    if [ "$routed" = true ]; then
        _sni_router_prepare || return 1
        if [ "$(jq -r '.frontedBy // empty' <<< "$meta")" = haproxy ]; then
            backend=$(jq -r '.backendPort' <<< "$meta")
        else
            _sni_router_assert_sni_available "$domain" || return 1
            backend=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
        fi
        listen=127.0.0.1
        _sni_router_register_reality sb-xhttp "$tag" "$domain" "$backend" || return 1
    else
        _check_port_conflict "$port" tcp && return 1
        [ "$(jq -r '.frontedBy // empty' <<< "$meta")" != haproxy ] || _sni_router_remove_reality "$tag" || return 1
    fi
    _atomic_modify_json "$XRAY_CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag\")) |= (.port=$backend | .listen=\"$listen\")" || return 1
    _atomic_modify_json "$METADATA_FILE" ".\"$tag\" |= (.publicPort=$port | .backendPort=$backend | del(.frontedBy,.routerRole) + $(if [ "$routed" = true ]; then echo '{"frontedBy":"haproxy","routerRole":"reality-default"}'; else echo '{}'; fi))" || return 1
    PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[] | select(.name == strenv(PROXY_NAME)) | .port)=$port" || return 1
    local uuid server concurrency
    uuid=$(_get_proxy_field "$name" '.uuid'); server=$(_get_proxy_field "$name" '.server')
    concurrency=$(_get_proxy_field "$name" '.["xhttp-opts"]["reuse-settings"]["max-concurrency"] // ""') || return 1
    _show_node_link vless-xhttp-reality "$name" "$server" "$port" "$tag" "$uuid" "$domain" "$(jq -r '.path' <<< "$meta")" "$(jq -r '.publicKey' <<< "$meta")" "$(jq -r '.shortId' <<< "$meta")" "$concurrency"
}

_delete_xhttp_node() {
    local tag="$1" meta type conf domain name fronted role
    _node_tx_begin || return 1
    meta=$(jq -ce --arg t "$tag" '.[$t] | select(.core == "xray")' "$METADATA_FILE") || return 1
    type=$(jq -r '.type // empty' <<< "$meta")
    fronted=$(jq -r '.frontedBy // empty' <<< "$meta")
    role=$(jq -r '.routerRole // empty' <<< "$meta")
    domain=$(jq -r '.server_name // empty' <<< "$meta")
    name=$(jq -r '.clientName // .name // empty' <<< "$meta")
    conf=$(jq -r '.nginxConfig // empty' <<< "$meta")

    if [ "$type" = vless-xhttp ] || [ -n "$conf" ]; then
        [ "$conf" = "$NGINX_CONF_DIR/$tag.xhttp.conf" ] || return 1
        [ ! -e "$conf" ] || grep -Fqx '# Managed by proxyall XHTTP' "$conf" || return 1
        _xhttp_snapshot_nginx "$conf" || return 1
        if [ "$fronted" = haproxy ]; then _sni_router_remove_https sb-xhttp "$domain" || return 1; fi
        rm -f -- "$conf" || return 1
        _sb_reload_or_start_nginx || return 1
    elif [ "$fronted" = haproxy ]; then
        if [ "$role" = tls-sni ]; then
            _sni_router_remove_tls "$tag" || return 1
        elif [ "$role" = xhttp-https ] && [ -n "$domain" ]; then
            _sni_router_remove_https sb-xhttp "$domain" || return 1
        else
            _sni_router_remove_reality "$tag" || return 1
        fi
    fi

    _atomic_modify_json "$XRAY_CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))" || return 1
    _atomic_modify_json "$METADATA_FILE" "del(.\"$tag\")" || return 1
    if [ -n "$name" ] && [ "$(jq -r '.yaml == false' <<< "$meta")" != true ]; then
        _remove_node_from_yaml "$name" || return 1
    fi
}

# 由节点事务恢复失败的改端口操作。Nginx 对重复域名只发警告。
_xhttp_install_port_nginx_config() {
    local source="$1" conf="$2" domain="$3" port="$4" routed="$5" check
    if [ -e "$conf" ] && ! grep -Fqx '# Managed by proxyall XHTTP' "$conf"; then
        _error "Nginx 配置不属于 XHTTP 节点，拒绝覆盖: $conf"
        return 1
    fi
    _xhttp_snapshot_nginx "$conf" && _sb_backup_nginx_file "$conf" || return 1
    install -m 644 "$source" "$conf" || return 1
    if ! check=$(LC_ALL=C nginx -T 2>&1); then
        printf '%s\n' "$check" >&2
        return 1
    fi
    if awk -v domain="${domain,,}" -v port="$port" '
        index($0, "conflicting server name \"" domain "\" on ") && index($0, ":" port ", ignored") {found=1}
        END {exit !found}
    ' <<< "$check"; then
        _error "Nginx 端口 $port 上已有同名站点 $domain。"
        return 1
    fi
    # Nginx 在地址级复用 TLS 监听，也会把 PROXY protocol 应用于整个监听。
    # 独占地址的 vhost 会优先于新建的公网通配监听。
    if awk '/^# configuration file / {print ";"; next} {sub(/#.*/, ""); print}' <<< "$check" |
        awk -v port="$port" -v routed="$routed" '
        BEGIN {RS="[;{}]"}
        {
            gsub(/[\r\n\t]/, " ")
            sub(/^ +/, "")
            if ($1 != "listen") next
            addr=$2; gsub(/["\047]/, "", addr)
            if (addr != port && addr !~ (":" port "$")) next
            proxy=0
            for (i=3; i<=NF; i++) if ($i == "proxy_protocol") proxy=1
            wildcard=(addr == port || addr == "*:" port || addr == "0.0.0.0:" port || addr == "[::]:" port)
            if (routed == "true") {
                if ((wildcard || addr == "127.0.0.1:" port) && !proxy) found=1
            } else if (!wildcard || proxy) found=1
        }
        END {exit !found}
    '; then
        _error "Nginx 端口 $port 的现有监听地址或 PROXY protocol 设置与 XHTTP 不兼容。"
        return 1
    fi
    _sb_reload_or_start_nginx
}

_modify_legacy_xray_port() {
    local tag="$1" port="$2" meta="$3" routed="${4:-false}"
    local type name old sni backend="$2" listen="::" prev_fronted prev_role answer link_json new_link xray_path
    type=$(jq -r '.type // empty' <<< "$meta")
    name=$(jq -r '.clientName // .name // empty' <<< "$meta")
    old=$(jq -r '.publicPort // empty' <<< "$meta")
    if [ -z "$old" ]; then
        xray_path=$(_node_candidate_path "$XRAY_CONFIG_FILE")
        old=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .port // empty' "$xray_path" 2>/dev/null)
    fi
    sni=$(jq -r '.server_name // empty' <<< "$meta")
    prev_fronted=$(jq -r '.frontedBy // empty' <<< "$meta")
    prev_role=$(jq -r '.routerRole // empty' <<< "$meta")

    if [ "$type" = vless-vision-reality ]; then
        _validate_reality_no_self_loop "$port" "$(jq -r '.handshakeServer // empty' <<< "$meta")" "$(jq -r '.handshakePort // 443' <<< "$meta")" || return 1
        if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ] && [ -z "${4:-}" ]; then
            _node_read_yes_no '是否由 HAProxy 复用公网 443？[Y/n，0 返回节点列表]: ' answer || return $?
            [[ "$answer" =~ ^[Nn]$ ]] || routed=true
        fi
        _node_tx_begin || return 1
        if [ "$routed" = true ]; then
            _sni_router_prepare || return 1
            if [ "$prev_fronted" = haproxy ]; then
                backend=$(jq -r '.backendPort' <<< "$meta")
            else
                _sni_router_assert_sni_available "$sni" || return 1
                backend=$(_sni_router_allocate_backend_port "$SNI_ROUTER_DEFAULT_REALITY_BACKEND_PORT") || return 1
            fi
            listen=127.0.0.1
            _sni_router_register_reality sb-xray "$tag" "$sni" "$backend" || return 1
        else
            _check_port_conflict "$port" tcp && return 1
            [ "$prev_fronted" != haproxy ] || _sni_router_remove_reality "$tag" || return 1
        fi
        link_json=$(jq -c --arg t "$tag" --arg old ":$old" --arg new ":$port" '
            .[$t].share_link | if type == "string" then
                if $old != ":" then sub($old + "(?=[/?#]|$)"; $new) else . end
            else null end
        ' "$METADATA_FILE") || return 1
        _atomic_modify_json "$XRAY_CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag\")) |= (.port=$backend | .listen=\"$listen\")" || return 1
        _atomic_modify_json "$METADATA_FILE" ".\"$tag\" |= (.publicPort=$port | .backendPort=$backend | (if ($link_json) != null then .share_link = ($link_json) else . end) | del(.frontedBy,.routerRole) + $(if [ "$routed" = true ]; then echo '{"frontedBy":"haproxy","routerRole":"reality-default"}'; else echo '{}'; fi))" || return 1
        if [ -n "$name" ] && [ "$(jq -r '.yaml == false' <<< "$meta")" != true ]; then
            PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[] | select(.name == strenv(PROXY_NAME)) | .port)=$port" || return 1
        fi
        new_link=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$METADATA_FILE")
        if [ -n "$new_link" ]; then
            if [ -n "${NODE_TX_DIR:-}" ]; then printf '%s\n' "$new_link" >> "$NODE_TX_DIR/share-links"; else printf '%s\n' "$new_link"; fi
        fi
        return 0
    fi

    _node_tx_begin || return 1
    if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ] && [ -n "$sni" ]; then
        _sni_router_prepare || return 1
        if [ "$prev_fronted" = haproxy ] && [ "$prev_role" = tls-sni ]; then
            backend=$(jq -r '.backendPort' <<< "$meta")
        else
            _sni_router_assert_sni_available "$sni" || return 1
            backend=$(_sni_router_allocate_backend_port 10443) || return 1
        fi
        listen=127.0.0.1
        routed=true
    else
        _check_port_conflict "$port" tcp && return 1
        if [[ "$type" =~ ^native-(socks|shadowsocks)$ ]]; then
            _check_port_conflict "$port" udp && return 1
        fi
    fi
    if [ "$prev_fronted" = haproxy ]; then
        if [ "$prev_role" = tls-sni ]; then _sni_router_remove_tls "$tag" || return 1
        else _sni_router_remove_reality "$tag" || return 1; fi
    fi
    [ "$routed" != true ] || _sni_router_register_tls sb-xray "$tag" "$sni" "$backend" || return 1
    link_json=$(jq -c --arg t "$tag" --arg old ":$old" --arg new ":$port" '
        .[$t].share_link | if type == "string" then
            if $old != ":" then sub($old + "(?=[/?#]|$)"; $new) else . end
        else null end
    ' "$METADATA_FILE") || return 1
    _atomic_modify_json "$XRAY_CONFIG_FILE" "(.inbounds[] | select(.tag == \"$tag\")) |= (.port=$backend | .listen=\"$listen\")" || return 1
    if [ -n "$name" ] && [ "$(jq -r '.yaml == false' <<< "$meta")" != true ]; then
        PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[] | select(.name == strenv(PROXY_NAME)) | .port)=$port" || return 1
    fi
    _atomic_modify_json "$METADATA_FILE" ".\"$tag\" |= (.publicPort=$port | .backendPort=$backend | (if ($link_json) != null then .share_link = ($link_json) else . end) | del(.frontedBy,.routerRole) + $(if [ "$routed" = true ]; then echo '{"frontedBy":"haproxy","routerRole":"tls-sni"}'; else echo '{}'; fi))" || return 1
    new_link=$(jq -r --arg t "$tag" '.[$t].share_link // empty' "$METADATA_FILE")
    if [ -n "$new_link" ]; then
        if [ -n "${NODE_TX_DIR:-}" ]; then printf '%s\n' "$new_link" >> "$NODE_TX_DIR/share-links"; else printf '%s\n' "$new_link"; fi
    fi
}

_modify_xhttp_port() {
    local tag="$1" port="$2" meta type domain path backend conf routed="${3:-false}" answer
    local prev_fronted listen_port="$2" sockets
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && _sni_router_validate_port "$port" || return 1
    meta=$(jq -ce --arg t "$tag" '.[$t]' "$METADATA_FILE") || return 1
    type=$(jq -r '.type // empty' <<< "$meta")
    if [ "$type" = vless-xhttp-reality ]; then
        _modify_xhttp_reality_port "$tag" "$port" "${3:-}"
        return $?
    elif [ "$type" != vless-xhttp ]; then
        _modify_legacy_xray_port "$tag" "$port" "$meta" "${3:-}"
        return $?
    fi
    domain=$(jq -r '.server_name' <<< "$meta"); path=$(jq -r '.path' <<< "$meta")
    backend=$(jq -r '.backendPort' <<< "$meta"); conf=$(jq -r '.nginxConfig' <<< "$meta")
    prev_fronted=$(jq -r '.frontedBy // empty' <<< "$meta")
    if [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ] && [ -z "${3:-}" ]; then
        _node_read_yes_no '是否由 HAProxy 复用公网 443？[Y/n，0 返回节点列表]: ' answer || return $?
        [[ "$answer" =~ ^[Nn]$ ]] || routed=true
    fi
    [ "$conf" = "$NGINX_CONF_DIR/$tag.xhttp.conf" ] && [ ! -L "$conf" ] || return 1
    if [ "$routed" = true ]; then
        [ "$port" = "$SNI_ROUTER_PUBLIC_PORT" ] || return 1
        listen_port="$SNI_ROUTER_HTTPS_BACKEND_PORT"
    elif [ "$port" = "$SNI_ROUTER_HTTPS_BACKEND_PORT" ]; then
        _error "端口 $port 保留给共享 SNI 入口的 Nginx 回环后端。"
        return 1
    fi
    _node_tx_begin || return 1
    if _check_port_in_config "$listen_port"; then
        _error "端口 $listen_port 已被现有节点配置占用。"
        return 1
    fi
    if _check_port_occupied "$listen_port" tcp; then
        # 只有全部 TCP 监听都归属 Nginx 时，才能按域名复用。
        if ! sockets=$(ss -Hlnpt "sport = :$listen_port" 2>/dev/null) || [ -z "$sockets" ] ||
            grep -Eqv 'users:\(\("nginx",pid=[0-9]+,fd=[0-9]+\)(,\("nginx",pid=[0-9]+,fd=[0-9]+\))*\)[[:space:]]*$' <<< "$sockets"; then
            _error "端口 $listen_port 已被其他服务使用，或无法确认监听者。"
            return 1
        fi
    fi
    if [ "$routed" = true ]; then
        _sni_router_prepare || return 1
        if [ "$prev_fronted" != haproxy ]; then
            _sni_router_assert_sni_available "$domain" || return 1
        fi
    fi
    _xhttp_nginx_config "$domain" "$path" "$backend" "$port" "$routed" > "$NODE_TX_DIR/xhttp-nginx" || return 1
    _xhttp_install_port_nginx_config "$NODE_TX_DIR/xhttp-nginx" "$conf" "$domain" "$listen_port" "$routed" || return 1
    if [ "$routed" = true ]; then _sni_router_register_https sb-xhttp "$domain" "$SNI_ROUTER_HTTPS_BACKEND_PORT" || return 1
    elif [ "$prev_fronted" = haproxy ]; then _sni_router_remove_https sb-xhttp "$domain" || return 1; fi
    _atomic_modify_json "$METADATA_FILE" ".\"$tag\".publicPort=$port | .\"$tag\".frontedBy=\"$(if [ "$routed" = true ]; then echo haproxy; else echo nginx; fi)\"" || return 1
    local name uuid server concurrency
    name=$(jq -r '.clientName' <<< "$meta")
    uuid=$(_get_proxy_field "$name" '.uuid'); server=$(_get_proxy_field "$name" '.server')
    concurrency=$(_get_proxy_field "$name" '.["xhttp-opts"]["reuse-settings"]["max-concurrency"] // ""') || return 1
    PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[] | select(.name == strenv(PROXY_NAME)) | .port)=$port" || return 1
    _show_node_link vless-xhttp-tls "$name" "$server" "$port" "$tag" "$uuid" "$domain" "$path" "$concurrency"
}

_vless_encryption_profile_prompt() {
    local choice unencrypted="仍使用 TLS / Reality"
    [ "${1:-}" != none ] || unencrypted="无加密，仅用于受控网络或已有加密隧道"
    printf '\nVLESS 附加加密（ENC）：\n  [1] ML-KEM-768 认证（默认，后量子认证）\n  [2] X25519 认证（握手更小）\n  [3] 不启用 ENC（%s）\n  [0] 返回协议选择\n两种 ENC 均使用混合密钥交换；会增加握手和计算开销，不保证提速。\n' "$unencrypted" >&2
    while true; do
        _node_read -r -p '请选择 [0-3]（默认 1）：' choice || return $?
        case "${choice:-1}" in
            1) echo mlkem768; return ;; 2) echo x25519; return ;; 3) echo none; return ;;
            0) _node_cancel; return 2 ;;
            *) _error '无效的 VLESS 加密选项，请重新选择。' ;;
        esac
    done
}

# 仅输出给客户端的 encryption 可进入分享链接；decryption 留在服务端。
_vless_encryption_keypair() {
    local profile="$1" pair section
    decryption=none; encryption=none
    if [ "$profile" != none ]; then
        case "$profile" in x25519) section=X25519 ;; mlkem768) section=ML-KEM-768 ;; *) return 1 ;; esac
        pair=$("$XRAY_BIN" vlessenc) || return 1
        pair=$(awk -F'"' -v section="$section" '/^Authentication: / {ok=index($0,"Authentication: "section",")==1}
            ok && ($2=="decryption" || $2=="encryption") {print $2"="$4}' <<< "$pair")
        decryption=$(sed -n 's/^decryption=//p' <<< "$pair")
        encryption=$(sed -n 's/^encryption=//p' <<< "$pair")
        [[ "$decryption" =~ ^mlkem768x25519plus\.native\.600s\.[A-Za-z0-9_-]+$ &&
           "$encryption" =~ ^mlkem768x25519plus\.native\.0rtt\.[A-Za-z0-9_-]+$ ]] || {
            _error 'Xray 未返回匹配的 VLESS Encryption 密钥对。'; return 1;
        }
    fi
}
_add_vless_xhttp_reality() { _node_operation _add_vless_xhttp_reality_impl; }
_add_vless_xhttp_tls() { _node_operation _add_vless_xhttp_tls_impl; }

# 按字段更新现有 XHTTP 链接，保留未编辑的协议参数与凭据。
_xray_edit_link() {
    python3 - "$2" "$3" 3<<< "$1" <<'PY'
import json, os, sys
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit
field, value = sys.argv[1:]
u = urlsplit(os.fdopen(3).read().strip())
q = dict(parse_qsl(u.query, keep_blank_values=True))
netloc, fragment = u.netloc, u.fragment
if field == 'name':
    fragment = quote(value, safe='')
elif field == 'server':
    host = '['+value+']' if ':' in value else value
    netloc = u.netloc.rsplit('@', 1)[0]+'@'+host+':'+str(u.port)
elif field == 'enc':
    q['encryption'] = value
elif field == 'sni':
    q['sni'] = value
    if q.get('type') == 'xhttp' or 'host' in q: q['host'] = value
elif field == 'path':
    q['path'] = value
elif field == 'concurrency':
    extra = json.loads(q.get('extra', '{}'))
    extra.setdefault('xmux', {})['maxConcurrency'] = int(value)
    q['extra'] = json.dumps(extra, separators=(',', ':'))
else:
    raise ValueError('unsupported node field')
if q.get('security') == 'reality': q['support-x25519mlkem768'] = 'true'
print(urlunsplit((u.scheme, netloc, u.path, urlencode(q, quote_via=quote), fragment)))
PY
}

_xray_enc_editable() {
    [[ "$1" =~ ^vless-(xhttp|xhttp-reality)$ ]]
}

_xray_edit_node_menu() {
    local tag="$1" meta kind name choice field status
    while true; do
        meta=$(jq -ce --arg t "$tag" '.[$t] | select(.core=="xray" and (.type=="vless-xhttp" or .type=="vless-xhttp-reality"))' "$METADATA_FILE") || return 1
        kind=$(jq -r .type <<< "$meta"); name=$(jq -r .clientName <<< "$meta")
        printf '\n  修改 XHTTP 节点：%s [%s]\n  [1] 节点名称\n  [2] 客户端连接地址\n  [3] 公网端口\n  [4] SNI 域名 / 证书源站\n  [5] VLESS ENC 方式\n  [6] XHTTP 传输路径\n  [7] XHTTP XMUX 并发数\n  [0] 返回节点列表\n\n' "$name" "$kind"
        read -r -p '请选择要修改的参数：' choice || return 2
        field=''
        case "$choice" in
            0) return 2 ;;
            1) field=name ;; 2) field=server ;; 3) field=port ;;
            4) field=sni ;; 5) field=enc ;; 6) field=path ;; 7) field=concurrency ;;
        esac
        [ -n "$field" ] || { _error '无效选择。'; continue; }
        local before_fp after_fp
        before_fp=$(_node_fingerprint "$CONFIG_FILE" "$METADATA_FILE" "$CLASH_YAML_FILE" "$XRAY_CONFIG_FILE" "$SNI_ROUTER_STATE_FILE" 2>/dev/null || true)
        status=0
        _node_operation _xray_edit_field "$tag" "$field" "$meta" || status=$?
        after_fp=$(_node_fingerprint "$CONFIG_FILE" "$METADATA_FILE" "$CLASH_YAML_FILE" "$XRAY_CONFIG_FILE" "$SNI_ROUTER_STATE_FILE" 2>/dev/null || true)
        if [ "$status" = 0 ] && [ "$before_fp" != "$after_fp" ]; then
            _info '可继续修改其他参数；客户端请使用最新分享链接。'
            _pause_for_enter "按回车键继续..."
        fi
    done
}

_xray_edit_field() {
    local tag="$1" field="$2" meta kind name ib security network proxy value old json answer link label
    local NODE_UI=true NODE_PENDING_ORIGIN='' decryption=none encryption=none profile routed=false
    meta=$(jq -ce --arg t "$tag" '.[$t] | select(.core=="xray" and (.type=="vless-xhttp" or .type=="vless-xhttp-reality"))' "$METADATA_FILE") || return 1
    [ "$meta" = "$3" ] || { _error '节点记录已变化，请重新选择。'; return 1; }
    name=$(jq -er .clientName <<< "$meta"); kind=$(jq -r .type <<< "$meta")
    ib=$(jq -ce --arg t "$tag" '[.inbounds[]|select(.tag==$t)]|select(length==1)|.[0]' "$XRAY_CONFIG_FILE") || return 1
    proxy=$(PROXY_NAME="$name" "$YQ_BINARY" eval -o=json -I=0 '[.proxies[]|select(.name==strenv(PROXY_NAME))]' "$CLASH_YAML_FILE") || return 1
    proxy=$(jq -ce 'select(length==1)|.[0]' <<< "$proxy") || return 1
    security=$(jq -r '.streamSettings.security // "none"' <<< "$ib")
    network=$(jq -r '.streamSettings.network // "xhttp"' <<< "$ib")
    case "$field" in
        name) label=节点名称 ;; server) label=连接地址 ;; port) label=公网端口 ;;
        enc) label=ENC方式 ;; sni) label=SNI域名 ;; path) label=XHTTP路径 ;; concurrency) label=XMUX并发数 ;;
        *) return 1 ;;
    esac
    _info '回车保留当前值；输入 0 取消本项修改。'
    case "$field" in
        name|server)
            old=$(jq -r --arg f "$field" '.[$f]' <<< "$proxy")
            _node_read -r -p "当前${label}: $old；新值：" value || return $?
            value="${value:-$old}"
            if [ "$field" = server ]; then
                value="${value#[}"; value="${value%]}"
                if ! _is_valid_reality_domain "$value" && ! _is_valid_ipv4 "$value" && ! [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:]+$ ]]; then
                    _error '连接地址须为 IP 或域名。'; return 1
                fi
            elif [ "$value" != "$old" ]; then
                [[ "$value" != *$'\r'* && "$value" != *$'\t'* ]] && _assert_node_name_free "$value" || return 1
            fi ;;
        port)
            old=$(jq -r .publicPort <<< "$meta")
            _node_read -r -p "当前公网端口 $old；新端口：" value || return $?
            value="${value:-$old}"
            [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && _sni_router_validate_port "$value" || { _error '端口必须在 1-65535 之间。'; return 1; }
            if [ "$value" = "$old" ]; then
                _info '端口未改变。'
                [ "$value" != "$SNI_ROUTER_PUBLIC_PORT" ] || _info '切换当前 443 的共享方式时，请先改到空闲端口，再改回 443。'
                return 0
            fi
            if [ "$value" = "$SNI_ROUTER_PUBLIC_PORT" ]; then
                _node_read_yes_no '是否由 HAProxy 复用公网 443？[Y/n，0 取消]: ' answer || return $?
                [[ "$answer" =~ ^[Nn]$ ]] || routed=true
            fi ;;
        enc)
            _xray_enc_editable "$kind" || return 1
            encryption=$(jq -r '.encryption // "none"' <<< "$proxy")
            old=none
            if [ "$encryption" != none ]; then
                old=x25519
                [ "${#encryption}" -lt 1000 ] || old=mlkem768
            fi
            printf '当前 ENC 认证：%s\n' "$old"
            # 编辑时回车保持原设置；创建节点仍使用默认 ML-KEM-768。
            printf '  [1] ML-KEM-768\n  [2] X25519\n  [3] 关闭 ENC\n'
            _node_read -r -p '新 ENC 方式（回车保持，0 取消）：' answer || return $?
            case "$answer" in '') value="$old" ;; 1) value=mlkem768 ;; 2) value=x25519 ;; 3) value=none ;; *) _error '无效的 ENC 选项。'; return 1 ;; esac ;;
        sni)
            old=$(jq -r '.server_name // ""' <<< "$meta")
            printf '当前 SNI：%s\n' "$old"
            if [ "$kind" = vless-xhttp-reality ]; then
                _node_read_yes_no '重新选择 Reality SNI 和源站？[y/N，0 取消]: ' answer || return $?
                [[ "$answer" =~ ^[Yy]$ ]] || return 0
                _select_reality_sni || return $?
                value="$SELECTED_REALITY_SNI"
                _validate_reality_no_self_loop "$(jq -r .publicPort <<< "$meta")" "$SELECTED_REALITY_HANDSHAKE_SERVER" "$SELECTED_REALITY_HANDSHAKE_PORT" || return 1
            else
                _node_read -r -p '新证书域名 / SNI（回车保留并检查证书）：' value || return $?
                value="${value:-$old}"; value="${value,,}"
                _is_valid_reality_domain "$value" || { _error '域名格式无效。'; return 1; }
            fi ;;
        path)
            [ "$network" = xhttp ] || return 1
            old=$(jq -r '.streamSettings.xhttpSettings.path' <<< "$ib")
            _node_read -r -p "当前 XHTTP 路径 $old；新值：" value || return $?
            value="${value:-$old}"
            [[ "$value" =~ ^/([a-zA-Z0-9_-]+/)+$ ]] || { _error '路径须以 / 开始和结束，中间使用字母、数字、下划线或短横线。'; return 1; } ;;
        concurrency)
            [ "$network" = xhttp ] || return 1
            old=$(jq -r '.["xhttp-opts"]["reuse-settings"]["max-concurrency"] // "未设置"' <<< "$proxy")
            _node_read -r -p "当前 XMUX 并发数 $old；新值：" value || return $?
            [ -n "$value" ] || return 0
            [[ "$value" =~ ^[0-9]{1,10}$ ]] && (( 10#$value >= 1 && 10#$value <= 2147483647 )) || { _error 'XMUX 并发数必须在 1-2147483647 之间。'; return 1; }
            value=$((10#$value)) ;;
        *) return 1 ;;
    esac
    if [ "$field" != sni ] && [ "$value" = "$old" ]; then _info '参数未改变。'; return 0; fi
    printf '将修改 %s：%s → %s\n' "$label" "$old" "$value"
    _node_read_yes_no '保存修改并重启节点服务？[y/N，0 取消]: ' answer || return $?
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    if [ "$field" = port ]; then
        _modify_xhttp_port "$tag" "$value" "$routed"
        return $?
    fi
    _node_tx_begin || return 1
    command -v python3 >/dev/null || _pkg_install python3 || return 1
    json=$(jq -Rn --arg v "$value" '$v') || return 1
    case "$field" in
        name)
            _atomic_modify_json "$METADATA_FILE" ".[\"$tag\"] |= (.name=$json | .clientName=$json)" || return 1
            PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[]|select(.name==strenv(PROXY_NAME))|.name)=$json | (.proxy-groups[]?.proxies[]?|select(.==strenv(PROXY_NAME)))=$json" || return 1 ;;
        server)
            PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[]|select(.name==strenv(PROXY_NAME))|.server)=$json" || return 1 ;;
        enc)
            _vless_encryption_keypair "$value" || return 1
            json=$(jq -Rn --arg v "$decryption" '$v') || return 1
            _atomic_modify_json "$XRAY_CONFIG_FILE" "(.inbounds[]|select(.tag==\"$tag\")|.settings.decryption)=$json" || return 1
            json=$(jq -Rn --arg v "$encryption" '$v') || return 1
            PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[]|select(.name==strenv(PROXY_NAME))|.encryption)=$json" || return 1
            value="$encryption" ;;
        sni)
            _xray_edit_sni "$tag" "$meta" "$ib" "$value" || return 1 ;;
        path)
            _atomic_modify_json "$XRAY_CONFIG_FILE" "(.inbounds[]|select(.tag==\"$tag\")|.streamSettings.xhttpSettings.path)=$json" || return 1
            PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[]|select(.name==strenv(PROXY_NAME))|.[\"xhttp-opts\"].path)=$json" || return 1
            _atomic_modify_json "$METADATA_FILE" ".[\"$tag\"].path=$json" || return 1
            [ "$kind" != vless-xhttp ] || _xray_edit_xhttp_nginx "$tag" || return 1 ;;
        concurrency)
            PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[]|select(.name==strenv(PROXY_NAME))|.[\"xhttp-opts\"][\"reuse-settings\"][\"max-concurrency\"])=$json" || return 1 ;;
    esac
    link=$(_xray_edit_link "$(jq -er .share_link <<< "$meta")" "$field" "$value") || return 1
    json=$(jq -Rn --arg v "$link" '$v') || return 1
    _atomic_modify_json "$METADATA_FILE" ".[\"$tag\"].share_link=$json" || return 1
    printf '%s\n' "$link" >> "$NODE_TX_DIR/share-links"
}

_xray_edit_xhttp_nginx() {
    local tag="$1" meta conf domain path backend public routed
    meta=$(jq -ce --arg t "$tag" '.[$t]' "$METADATA_FILE") || return 1
    conf=$(jq -r .nginxConfig <<< "$meta")
    [ "$conf" = "$NGINX_CONF_DIR/$tag.xhttp.conf" ] || return 1
    domain=$(jq -r .server_name <<< "$meta"); path=$(jq -r .path <<< "$meta")
    backend=$(jq -r .backendPort <<< "$meta"); public=$(jq -r .publicPort <<< "$meta")
    routed=$(jq -r '.frontedBy=="haproxy"' <<< "$meta")
    _xhttp_snapshot_nginx "$conf" || return 1
    _xhttp_nginx_config "$domain" "$path" "$backend" "$public" "$routed" > "$NODE_TX_DIR/xhttp-nginx" || return 1
    _install_managed_nginx_config "$NODE_TX_DIR/xhttp-nginx" "$conf" '# Managed by proxyall XHTTP'
}

_xray_edit_sni() {
    local tag="$1" meta="$2" ib="$3" domain="$4" name old kind target data
    name=$(jq -r .clientName <<< "$meta"); old=$(jq -r .server_name <<< "$meta")
    kind=$(jq -r .type <<< "$meta")
    if [ "$domain" != "$old" ] && [ "$(jq -r '.frontedBy // ""' <<< "$meta")" = haproxy ]; then
        _sni_router_assert_sni_available "$domain" || return 1
    fi
    if [ "$kind" = vless-xhttp-reality ]; then
        if [ -n "${NODE_PENDING_ORIGIN:-}" ]; then
            for target in "$NGINX_CONF_DIR/00-sb-reality-acme-$domain.conf" "$NGINX_CONF_DIR/$domain.$REALITY_LOCAL_ORIGIN_PORT.reality.conf" "$NGINX_CERT_DIR/$domain/cert" "$NGINX_CERT_DIR/$domain/key"; do
                _xhttp_snapshot_nginx "$target" || return 1
            done
            target="$NGINX_CONF_DIR/$domain.$REALITY_LOCAL_ORIGIN_PORT.reality.conf"
            if ! _local_certificate_usable "$domain" && [ -e "$target" ]; then
                grep -Fqx '# Generated by singbox-lite Reality local origin' "$target" || return 1
                rm -f -- "$target" || return 1
            fi
            _prepare_local_reality_origin "$domain" || return 1
            NODE_PENDING_ORIGIN=''
        fi
        target="$SELECTED_REALITY_HANDSHAKE_SERVER"
        [[ "$target" != *:* || "$target" == \[* ]] || target="[$target]"
        data=$(jq -nc --arg t "$target:$SELECTED_REALITY_HANDSHAKE_PORT" --arg sn "$domain" '{target:$t,serverNames:[$sn]}') || return 1
        _atomic_modify_json "$XRAY_CONFIG_FILE" "(.inbounds[]|select(.tag==\"$tag\")|.streamSettings.realitySettings) |= (. + $data | del(.dest))" || return 1
        data=$(jq -nc --arg sn "$domain" --arg hs "$SELECTED_REALITY_HANDSHAKE_SERVER" --argjson hp "$SELECTED_REALITY_HANDSHAKE_PORT" '{server_name:$sn,handshakeServer:$hs,handshakePort:$hp}') || return 1
    else
        [ "$kind" = vless-xhttp ] || return 1
        if [ "$domain" != "$old" ]; then _xhttp_prepare_domain "$domain" || return 1; fi
        _ensure_local_origin_dependencies || return 1
        for target in "$NGINX_CERT_DIR/$domain/cert" "$NGINX_CERT_DIR/$domain/key"; do _xhttp_snapshot_nginx "$target" || return 1; done
        if [ "$domain" = "$old" ] && ! _local_certificate_usable "$domain"; then
            target=$(jq -r .nginxConfig <<< "$meta")
            [ "$target" = "$NGINX_CONF_DIR/$tag.xhttp.conf" ] || return 1
            if [ -e "$target" ]; then
                grep -Fqx '# Managed by proxyall XHTTP' "$target" || return 1
                _xhttp_snapshot_nginx "$target" && rm -f -- "$target" || return 1
            fi
        fi
        _xhttp_prepare_certificate "$domain" || return 1
        data=$(jq -nc --arg sn "$domain" '{server_name:$sn}') || return 1
    fi
    _atomic_modify_json "$METADATA_FILE" ".[\"$tag\"] += $data" || return 1
    data=$(jq -Rn --arg sn "$domain" '$sn') || return 1
    PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[]|select(.name==strenv(PROXY_NAME))|.servername)=$data" || return 1
    _atomic_modify_json "$XRAY_CONFIG_FILE" "(.inbounds[]|select(.tag==\"$tag\")|.streamSettings.xhttpSettings.host)=$data" || return 1
    PROXY_NAME="$name" _atomic_modify_yaml "$CLASH_YAML_FILE" "(.proxies[]|select(.name==strenv(PROXY_NAME))|.[\"xhttp-opts\"].host)=$data" || return 1
    [ "$kind" != vless-xhttp ] || _xray_edit_xhttp_nginx "$tag" || return 1
    if [ "$(jq -r '.frontedBy // ""' <<< "$meta")" = haproxy ]; then
        case "$(jq -r .routerRole <<< "$meta")" in
            reality-default)
                _sni_router_register_reality sb-xhttp "$tag" "$domain" "$(jq -r .backendPort <<< "$meta")" || return 1 ;;
            xhttp-https)
                if [ "$domain" != "$old" ]; then _sni_router_remove_https sb-xhttp "$old" || return 1; fi
                _sni_router_register_https sb-xhttp "$domain" "$SNI_ROUTER_HTTPS_BACKEND_PORT" || return 1 ;;
            *) return 1 ;;
        esac
    fi
}
