#!/usr/bin/env bash
# PROXYALL_LIB=sb_core.sh
# sing-box 核心：服务管理、依赖与内核安装升级、配置初始化与 DNS、时间同步、卸载。由 sb 加载。

# 公网 IP 初始化
_init_server_ip() {
    _info "正在获取服务器公网 IP..."
    server_ip=$(_get_public_ip)
    if [ -z "$server_ip" ] || [ "$server_ip" == "null" ]; then
        _warn "自动获取 IP 失败，将回退到 127.0.0.1"
        server_ip="127.0.0.1"
    else
        _success "当前服务器公网 IP: ${server_ip}"
    fi
}

# 统一服务管理
_manage_service() {
    if [ -n "${NODE_TX_DIR:-}" ] || [ "$1" = status ]; then _manage_service_impl "$@"
    else ( _config_write_lock || exit 1; _manage_service_impl "$@" ); fi
}
_manage_service_impl() {
    if [ "$1" = status ]; then
        local sb_rc=0 xray_active=false
        if [ -x "$SINGBOX_BIN" ]; then
            _manage_singbox_service_impl status || sb_rc=$?
        else
            _info 'Sing-box: 未安装'
        fi
        _xray_service status || true
        if [ -x "$XRAY_BIN" ] && _xray_running; then
            xray_active=true
        fi
        if [ "$sb_rc" -eq 0 ] || [ "$xray_active" = true ]; then
            return 0
        fi
        return "$sb_rc"
    fi
    if [ -x "$SINGBOX_BIN" ]; then
        _manage_singbox_service_impl "$@" || return 1
    fi
    if [ -x "$XRAY_BIN" ] && [ -f "$XRAY_CONFIG_FILE" ]; then
        _xray_service "$1" || return 1
    fi
}
_manage_singbox_service_impl() {
    local action="$1"
    if [ "$action" = restart ] && [ "${NODE_TX_STARTED:-0}" = 1 ]; then
        _node_tx_publish || return 1
        touch "$NODE_TX_DIR/service-touched"
    fi

    [ -z "$INIT_SYSTEM" ] && _detect_init_system
    [ "$action" == "status" ] || _info "正在使用 ${INIT_SYSTEM} 执行: $action..."
    case "$INIT_SYSTEM" in
        systemd)
            if [ "$action" == "status" ]; then systemctl status sing-box --no-pager -l; return; fi
            systemctl "$action" sing-box 8>&- 9>&- || return 1
            if [[ "$action" == start || "$action" == restart ]]; then
                systemctl is-active --quiet sing-box || return 1
            fi ;;
        openrc)
            if [ "$action" == "status" ]; then rc-service sing-box status; return; fi
            rc-service sing-box "$action" 8>&- 9>&- || return 1
            if [[ "$action" == start || "$action" == restart ]]; then
                rc-service sing-box status >/dev/null 2>&1 || return 1
            fi ;;
        direct)
            case "$action" in
                start)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box 已在 direct 模式运行。"
                        return 0
                    fi
                    rm -f "$PID_FILE"
                    local run_config="$CONFIG_FILE" run_relay="${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}"
                    if [ "${NODE_TX_STARTED:-0}" = 1 ]; then run_config=${NODE_TX_FILES[0]}; run_relay=${NODE_TX_FILES[3]}; fi
                    nohup env GOMEMLIMIT="$(_get_mem_limit)MiB" \
                        "$SINGBOX_BIN" run -c "$run_config" -c "$run_relay" \
                        >> "$LOG_FILE" 2>&1 8>&- 9>&- &
                    echo $! > "$PID_FILE"
                    sleep 1
                    _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN" || return 1
                    _success "sing-box 已以 direct 后台模式启动。"
                    ;;
                stop)
                    if [ -s "$PID_FILE" ]; then
                        local pid
                        pid=$(cat "$PID_FILE" 2>/dev/null)
                        if _is_pid_running_cmd "$pid" "$SINGBOX_BIN"; then
                            kill "$pid" 2>/dev/null
                        fi
                    fi
                    rm -f "$PID_FILE"
                    _success "sing-box direct 后台进程已停止。"
                    ;;
                restart)
                    _manage_singbox_service_impl stop
                    sleep 1
                    _manage_singbox_service_impl start
                    ;;
                status)
                    if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                        _success "sing-box direct 后台模式运行中 (PID: $(cat "$PID_FILE"))"
                    else
                        rm -f "$PID_FILE"
                        _warn "sing-box direct 后台模式未运行。"
                        return 1
                    fi
                    ;;
                *) _error "direct 模式不支持的服务操作: $action"; return 1 ;;
            esac
            ;;
        *) _error "不支持的服务管理系统"; return 1 ;;
    esac
}

# --- 资源与环境管理 ---

# chrony 系统校时服务
_enable_chrony_service() {
    local service sync_output
    if ! command -v chronyc &>/dev/null || ! command -v chronyd &>/dev/null; then
        _info "正在安装 chrony..."
        if ! _pkg_install chrony; then
            _warn "chrony 安装失败，正在尝试其他校时方式。"
            return 1
        fi
    fi
    for service in chrony.service chronyd.service; do
        [ "$(systemctl show -p LoadState --value "$service" 2>/dev/null)" = loaded ] || continue
        if sync_output=$(systemctl enable --now "$service" 2>&1 8>&- 9>&-) &&
           systemctl is-active --quiet "$service"; then
            _info "chrony 服务已启用，正在确认时间同步..."
            return 0
        fi
        _warn "chrony 服务启用失败：${sync_output:-服务未运行}"
        return 1
    done
    _warn "未找到 chrony 服务，正在尝试其他校时方式。"
    return 1
}

# 系统时间同步
_sync_system_time() {
    local force="${1:-false}"
    local sync_status=1 sync_output http_time http_age url attempt request_id
    local chrony_service_ready=false chrony_wait_attempts=5

    if [ "$force" != "true" ] && [ "$INIT_SYSTEM" = systemd ] && \
       command -v timedatectl &>/dev/null && \
       [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
        return 0
    fi

    _info "正在同步系统时间..."
    if command -v timedatectl &>/dev/null && [ "$INIT_SYSTEM" = "systemd" ]; then
        if sync_output=$(timedatectl set-ntp true 2>&1); then
            for attempt in 1 2 3 4 5; do
                if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
                    sync_status=0
                    break
                fi
                [ "$attempt" = 5 ] || sleep 1
            done
            [ "$sync_status" = 0 ] || _warn "网络校时服务尚未确认同步完成，正在尝试其他校时方式。"
        else
            _warn "timedatectl：${sync_output:-无法启用网络校时服务}"
        fi
        if [ "$sync_status" -ne 0 ]; then
            if _enable_chrony_service; then
                chrony_service_ready=true
                chrony_wait_attempts=30
            fi
        fi
    fi

    if [ "$sync_status" -ne 0 ] && command -v chronyc &>/dev/null; then
        if sync_output=$(chronyc -m 'makestep 0.1 1' 'burst 1/2' "waitsync ${chrony_wait_attempts} 0.1 0 1" 2>&1); then
            sync_status=0
        else
            _warn "chronyc：${sync_output:-未能完成时间同步}"
        fi
    fi
    if [ "$sync_status" -ne 0 ] && command -v ntpdate &>/dev/null; then
        if sync_output=$(ntpdate -u -t 5 pool.ntp.org 2>&1); then
            sync_status=0
        else
            _warn "ntpdate：${sync_output:-未能完成时间同步}"
        fi
    fi
    if [ "$sync_status" -ne 0 ] && [ "$chrony_service_ready" != true ] && command -v chronyd &>/dev/null; then
        if sync_output=$(chronyd -q -t 10 'server pool.ntp.org iburst' 2>&1); then
            sync_status=0
        else
            _warn "chronyd：${sync_output:-未能完成时间同步}"
        fi
    fi
    if [ "$sync_status" -ne 0 ] && command -v curl &>/dev/null; then
        request_id="$(date +%s)-${RANDOM}"
        for url in https://www.google.com https://www.cloudflare.com; do
            if ! sync_output=$(curl --noproxy '*' -fsSI --max-time 5 \
                -H 'Cache-Control: no-cache, no-store' "${url}/?sb_time=${request_id}" 2>&1); then
                _warn "获取 ${url} 时间失败：${sync_output}"
                continue
            fi
            http_time=$(printf '%s\n' "$sync_output" | awk 'tolower($1) == "date:" {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0} END {print value}')
            if [ -z "$http_time" ]; then
                _warn "${url} 未返回 Date 时间。"
                continue
            fi
            http_age=$(printf '%s\n' "$sync_output" | awk 'tolower($1) == "age:" {gsub(/\r/, "", $2); value=$2} END {print value}')
            if { [ -n "$http_age" ] && [ "$http_age" != 0 ]; } ||
               ! date -u -d "$http_time" +%s >/dev/null 2>&1; then
                _warn "${url} 返回的时间无效或来自缓存。"
                continue
            fi
            if sync_output=$(date -s "$http_time" 2>&1); then
                sync_status=0
                break
            fi
            _warn "设置系统时间失败：${sync_output}"
        done
    fi
    if [ "$sync_status" -ne 0 ]; then
        _error "系统时间同步失败，请检查校时服务、网络及系统时间修改权限。"
        return 1
    fi
    _info "当前时间：$(date)"
}

_setup_time_sync() {
    command -v crontab >/dev/null 2>&1 || {
        _warning "未找到 crontab，无法设置定时同步系统时间。"
        return 1
    }

    local tag="# sing-box-time-sync"
    local schedule script_path job current
    schedule=$(date '+%M %H') || return 1
    printf -v script_path '%q' "$SELF_SCRIPT_PATH"
    script_path=${script_path//%/\\%}
    job="${schedule} * * * bash ${script_path} sync-time >/dev/null 2>&1 ${tag}"
    current=$(crontab -l 2>/dev/null || true)
    if ! { printf '%s\n' "$current" | awk -v tag="$tag" 'index($0, tag) == 0'; printf '%s\n' "$job"; } | crontab -; then
        _error "定时同步系统时间任务写入失败。"
        return 1
    fi
    _success "定时同步系统时间已设置，每天 $(date '+%H:%M')（服务器本地时间）执行一次。"
}

_remove_time_sync() {
    local tag="# sing-box-time-sync" current
    command -v crontab >/dev/null 2>&1 || return 0
    current=$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "$current" | grep -Fq "$tag"; then
        printf '%s\n' "$current" | awk -v tag="$tag" 'index($0, tag) == 0' | crontab -
    fi
}

_sync_system_time_interactive() {
    _sync_system_time true || return 1
    local answer
    read -r -p "是否添加每 24 小时同步一次系统时间的定时任务？[y/N]: " answer || return 0
    case "$answer" in
        y|Y|yes|YES|Yes) _setup_time_sync ;;
    esac
}

# 内存限额计算
_get_mem_limit() {
    local total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cgroup_limit=""
    local limit

    [ -z "$total_mem_mb" ] && total_mem_mb=128

    if [ -r /sys/fs/cgroup/memory.max ]; then
        cgroup_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        if [ "$cgroup_limit" != "max" ] && [ -n "$cgroup_limit" ]; then
            total_mem_mb=$((cgroup_limit / 1024 / 1024))
        fi
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cgroup_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        if [ -n "$cgroup_limit" ] && [ "$cgroup_limit" -lt 9223372036854771712 ] 2>/dev/null; then
            total_mem_mb=$((cgroup_limit / 1024 / 1024))
        fi
    fi

    if [ "$total_mem_mb" -le 128 ]; then
        limit=48
    elif [ "$total_mem_mb" -le 256 ]; then
        limit=$((total_mem_mb * 50 / 100))
    elif [ "$total_mem_mb" -le 512 ]; then
        limit=$((total_mem_mb * 65 / 100))
    else
        limit=$((total_mem_mb * 80 / 100))
    fi

    [ "$limit" -lt 32 ] && limit=32
    echo "$limit"
}

_secure_sensitive_files() {
    mkdir -p "$SINGBOX_DIR" || return 1
    chmod 700 "$SINGBOX_DIR" 2>/dev/null || true
    chmod 600 "$SINGBOX_DIR"/*.json "$SINGBOX_DIR"/*.yaml "$SINGBOX_DIR"/*.key "$SINGBOX_DIR"/*.pem 2>/dev/null || true
    chmod 600 "$LOG_FILE" "$ARGO_LOG_FILE" 2>/dev/null || true
}
# 临时文件由创建它们的操作负责清理，禁止目录级 EXIT 清理。
# 依赖安装
_install_dependencies() {
    local force="${1:-false}"
    if [ "$force" != "true" ] && [ -s "$DEP_STATE_FILE" ] && grep -qx "$DEP_STATE_VERSION" "$DEP_STATE_FILE" 2>/dev/null; then
        local missing_cached=""
        for cmd in bash jq curl wget openssl tar unzip sha256sum; do
            if ! command -v "$cmd" &>/dev/null; then
                missing_cached="$missing_cached $cmd"
            fi
        done
        if ! command -v nft &>/dev/null; then
            missing_cached="$missing_cached nftables"
        fi
        if [ -z "$missing_cached" ] && [ -x "$YQ_BINARY" ]; then
            return 0
        fi
        [ ! -x "$YQ_BINARY" ] && missing_cached="$missing_cached yq"
        _warn "依赖缓存存在，但关键工具缺失:${missing_cached}，将执行一次修复安装。"
    fi

    # 核心依赖：脚本运行的绝对前提，必须全部装上
    local core_pkgs="bash curl jq openssl wget tar unzip ca-certificates coreutils"
    # 可选依赖：部分功能需要，即使装失败也不致命
    local optional_pkgs="procps nftables socat iproute2 cron lsof"
    
    # 针对不同发行版的 cron 包名适配
    if command -v apk &>/dev/null; then
        optional_pkgs="${optional_pkgs/cron/dcron}"
    elif ! command -v apt-get &>/dev/null && ! command -v yum &>/dev/null && ! command -v dnf &>/dev/null; then
        optional_pkgs="${optional_pkgs/cron/cronie}"
    fi

    _info "正在安装核心依赖..."
    _pkg_install $core_pkgs
    
    _info "正在安装可选依赖..."
    _pkg_install $optional_pkgs 2>/dev/null || {
        # 可选依赖批量安装失败时逐个尝试
        _warn "部分可选依赖批量安装遇到冲突，正在逐个重试..."
        for pkg in $optional_pkgs; do
            _pkg_install "$pkg" 2>/dev/null || true
        done
    }
    
    _install_yq

    # [修复] Alpine 上 dcron 安装后需手动启动 cron 守护进程
    if command -v apk &>/dev/null; then
        if command -v crond &>/dev/null; then
            rc-service dcron start 2>/dev/null 8>&- 9>&-
            rc-update add dcron default 2>/dev/null
        fi
    fi

    # 关键依赖验证：如果核心工具缺失则无法继续
    local missing=""
    for cmd in bash jq curl wget openssl tar unzip sha256sum; do
        if ! command -v "$cmd" &>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ ! -x "$YQ_BINARY" ]; then
        missing="$missing yq"
    fi
    if [ -n "$missing" ]; then
        _error "以下关键依赖安装失败:${missing}"
        _error "请使用系统包管理器手动安装这些工具（如 apk add / apt-get install / yum install）"
        exit 1
    fi

    mkdir -p "$SINGBOX_DIR"
    printf '%s\n' "$DEP_STATE_VERSION" > "$DEP_STATE_FILE"
}

# 确保 nftables 可用，并检测实际 netfilter 写入能力
_ensure_nftables() {
    if ! command -v nft &>/dev/null; then
        _info "未检测到 nftables，尝试安装..."
        _pkg_install nftables
        if ! command -v nft &>/dev/null; then
            _error "nftables 安装失败。"
            return 1
        fi
        _success "nftables 安装成功。"
    fi

    if ! _nft_can_redirect 65530 65531; then
        _warn "nftables 命令存在，但当前环境无 netfilter 写权限（容器/LXC 无特权模式）。"
        _warn "端口转发将自动使用 sing-box 引擎代替。"
        return 2
    fi

    return 0
}

# 每次更新均基于候选核心迁移配置副本；此函数不修改运行中的配置。
_prepare_core_config_upgrade() {
    local candidate="$1" stage="$2" version major minor file index output deprecated_var
    local -a sources=() names=() check_args=()
    mkdir -p "$stage" || return 1
    version=$("$candidate" version 2>/dev/null | sed -n 's/^sing-box version \([^ ]*\).*/\1/p')
    if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
        _error "无法识别候选核心版本，已取消更新。"; return 1
    fi
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
    for file in "$CONFIG_FILE" "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}"; do
        if [ -e "$file" ]; then
            [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || {
                _error "配置不是有效的普通文件，已保留: $file"; return 1;
            }
            sources+=("$file")
            if [ "$file" = "$CONFIG_FILE" ]; then names+=(config.json); else names+=(relay.json); fi
        fi
    done
    [ "${#sources[@]}" -gt 0 ] || return 0
    _info "检查并适配 sing-box ${version}：主配置 + 中转配置（临时副本）..."
    if ! jq -s --argjson modern "$((major > 1 || minor >= 12))" \
        --argjson hy2 "$((major > 1 || minor >= 14))" '
        def arr: if . == null then [] elif type == "array" then . else [.] end;
        def rename($old; $new):
            if has($old) then
                if has($new) and .[$new] != .[$old] then error("新旧字段冲突: \($old) / \($new)")
                else .[$new]=.[$old] | del(.[$old]) end
            else . end;
        def rule_walk(f):
            if has("rules") then .rules |= map(rule_walk(f)) else . end | f;
        def endpoint:
            if startswith("[") then (capture("^\\[(?<host>[^]]+)\\](?::(?<port>[0-9]+))?$") // error("无效的 DNS IPv6 地址"))
            elif test("^[^:]+:[0-9]+$") then capture("^(?<host>[^:]+):(?<port>[0-9]+)$")
            else {host:.} end
            | if .host == "" then error("DNS 地址为空") else . end;
        def dns_server($fake; $default_out; $strategy):
            if has("address") | not then . else
                . as $old
                | if has("type") then error("DNS 同时包含新旧格式") else . end
                | del(.address,.address_resolver,.address_strategy,.strategy,.client_subnet)
                | if $old.address == "local" then .type="local"
                  elif $old.address == "fakeip" then . + {type:"fakeip"} + ($fake | del(.enabled))
                  elif ($old.address | startswith("dhcp://")) then
                    .type="dhcp" | if $old.address != "dhcp://auto" then .interface=($old.address|ltrimstr("dhcp://")) else . end
                  else
                    ($old.address | if contains("://") then capture("^(?<kind>[^:]+)://(?<rest>.*)$") else {kind:"udp",rest:.} end) as $url
                    | if (["udp","tcp","tls","https","quic","h3"] | index($url.kind)) == null
                      then error("无法转换的 DNS 协议: \($url.kind)") else . end
                    | ($url.rest | split("/")) as $parts
                    | ($parts[0] | endpoint) as $ep
                    | . + {type:$url.kind,server:$ep.host}
                    | if $ep.port != null then .server_port=($ep.port|tonumber) else . end
                    | if ($parts|length) > 1 then
                        if $url.kind == "https" or $url.kind == "h3" then .path=("/"+($parts[1:]|join("/")))
                        else error("非 HTTP DNS 地址包含路径") end
                      else . end
                    # 旧 DNS 默认走默认出站，新格式默认直连；显式保留旧路径。
                    | if (.detour // "") == "" and $default_out != "" then .detour=$default_out else . end
                  end
                | if ($old.address_resolver // "") != "" then
                    .domain_resolver={server:$old.address_resolver}
                    | if ($old.address_strategy // $strategy // "") != "" then
                        .domain_resolver.strategy=($old.address_strategy // $strategy)
                      else . end
                  elif ($old.address_strategy // "") != "" then error("DNS address_strategy 缺少 address_resolver")
                  else . end
            end;
        if all(.[]; type == "object") | not then error("配置顶层必须是对象") else . end
        | if $modern == 0 then . else
          # 为需要新规则的无标签旧入站分配标签；已有标签一律保留。
          [.[].inbounds[]?.tag] as $used_tags
          | [.[].dns.servers[]?.tag] as $used_dns_tags
          | to_entries | map(.key as $doc | .value |
              if .inbounds then .inbounds |= (to_entries | map(.key as $idx | .value |
                if (.tag // "") == "" and (.sniff == true or
                    ((.domain_strategy // "as_is") != "as_is") or .udp_disable_domain_unmapping == true) then
                    ("sb-upgrade-in-\($doc)-\($idx)") as $tag
                    | if ($used_tags | index($tag)) != null then error("自动入站标签冲突") else .tag=$tag end
                else . end))
              else . end
              | if .dns.servers then .dns.servers |= (to_entries | map(.key as $idx | .value |
                  if (.tag // "") == "" then
                    ("sb-upgrade-dns-\($doc)-\($idx)") as $tag
                    | if ($used_dns_tags|index($tag)) != null then error("自动 DNS 标签冲突") else .tag=$tag end
                  else . end))
                else . end)
          | [.[].outbounds[]?] as $outs
          | ([.[].route.final? | select(. != null and . != "")] | last // $outs[0].tag // "") as $default_out
          | [.[].dns.servers[]?] as $servers
          | if any($servers[]; has("address") and
                ((keys-["address","tag","address_resolver","address_strategy","strategy","detour","client_subnet"])|length)>0) then
                error("旧 DNS 服务器包含未支持的自定义字段，不能无损迁移")
            else . end
          | ([.[].dns.final? | select(. != null and . != "")] | last // $servers[0].tag // "") as $dns_final
          | ([.[].dns.strategy? | select(. != null)] | last // "") as $dns_strategy
          | (reduce $servers[] as $s ({}; if $s.tag != null then .[$s.tag]=$s else . end)) as $dns_map
          | [.[].dns.rules[]? | select(has("outbound"))] as $resolve_rules
          | if any($resolve_rules[]; ((keys-["outbound","server","action","strategy","disable_cache","rewrite_ttl","client_subnet"])|length)>0
                or (.action // "route") != "route" or .server == null) then
                error("带条件的 outbound DNS 规则无法等价转换为固定域名解析器")
            else . end
          | def resolver_options:
              . as $rule | $dns_map[.server] as $server
              | {server:.server}
                + ($server | {strategy,client_subnet} | with_entries(select(.value != null and .value != "")))
                + ($rule | {strategy,disable_cache,rewrite_ttl,client_subnet} | with_entries(select(.value != null)));
          def resolver_for($tag):
              ([$resolve_rules[] | select((.outbound|arr|index("any")) != null or
                    (.outbound|arr|index($tag)) != null)] | first) as $rule
              | if $rule != null then ($rule | resolver_options) else null end;
          ([.[].route.default_domain_resolver? | select(. != null and . != "")] | last) as $existing_resolver
          | (resolver_for("any") // $existing_resolver //
                (if $dns_final != "" and (($dns_map[$dns_final].address // "" | startswith("rcode://"))|not)
                    then ({server:$dns_final} | resolver_options) else null end)) as $default_resolver
          | (reduce $outs[] as $o ({}; if $o.type == "block" or $o.type == "dns" then
                if ($o.tag // "") == "" then error("无标签的旧特殊出站无法安全迁移")
                else .[$o.tag]=(if $o.type=="block" then "reject" else "hijack-dns" end) end
              else . end)) as $special
          | (reduce $outs[] as $o ({}; if $o.type=="direct" and ($o|has("override_address") or has("override_port")) then
                if ($o.tag // "")=="" then error("旧 direct override 出站缺少 tag")
                else .[$o.tag]=($o|{override_address,override_port}|with_entries(select(.value != null))) end
              else . end)) as $overrides
          | def dns_rule:
              if .server != null and $dns_map[.server].address != null then
                $dns_map[.server] as $s
                | if ($s.address | startswith("rcode://")) then
                    ($s.address | ltrimstr("rcode://")) as $rcode
                    | .action="predefined" | .rcode=({"success":"NOERROR","format_error":"FORMERR","server_failure":"SERVFAIL","name_error":"NXDOMAIN","not_implemented":"NOTIMP","refused":"REFUSED"}[$rcode] // error("未知 DNS RCode"))
                    | del(.server,.disable_cache,.rewrite_ttl,.client_subnet,.strategy)
                  else
                    if .strategy == null and ($s.strategy // "") != "" then .strategy=$s.strategy else . end
                    | if .client_subnet == null and $s.client_subnet != null then .client_subnet=$s.client_subnet else . end
                  end
              else . end;
          def route_rule:
              rename("rule_set_ipcidr_match_source";"rule_set_ip_cidr_match_source")
              | if .outbound != null and $special[.outbound] != null then
                  .action=$special[.outbound] | del(.outbound)
                elif .outbound != null and $overrides[.outbound] != null then
                  . as $rule | $overrides[.outbound] as $options
                  | if any($options|keys[]; $rule[.] != null and $rule[.] != $options[.]) then
                        error("direct 出站与规则的目标覆盖选项冲突")
                    else . + $options end
                else . end;
          # 两份文件生成的入站动作统一放到主路由最前，避免被旧终止规则截断。
          if any(.[].inbounds[]?; .sniff_override_destination == true) then
                error("sniff_override_destination=true 没有等价新选项，请先明确目标地址覆盖策略")
            else . end
          | [.[].inbounds[]? |
            if (.sniff == true or ((.domain_strategy // "as_is") != "as_is")) and (.tag // "") == ""
              then error("旧 sniff/domain_strategy 入站缺少 tag，无法保持规则作用范围") else empty end,
            (if ((.domain_strategy // "as_is") != "as_is") then
                {inbound:.tag,action:"resolve",strategy:.domain_strategy} else empty end),
            (if .sniff == true then
                {inbound:.tag,action:"sniff"} + (if .sniff_timeout then {timeout:.sniff_timeout} else {} end)
                else empty end),
            (if .udp_disable_domain_unmapping == true then
                if (.tag // "") == "" then error("旧 UDP 入站缺少 tag")
                else {inbound:.tag,action:"route-options",udp_disable_domain_unmapping:true} end
                else empty end)
          ] as $in_rules
          | if any($outs[]; any(.outbounds[]?, .detour?; . != null and $special[.] != null)) then
              error("selector/urltest/detour 引用了旧 block/dns 出站，无法保持选择语义")
            else . end
          | if any($outs[]; any(.outbounds[]?, .detour?; . != null and $overrides[.] != null)) then
              error("selector/urltest/detour 引用了旧 direct override 出站，无法保持目标覆盖语义")
            else . end
          | if any($servers[]; ((if (.detour // "")=="" then $default_out else .detour end) as $tag | $overrides[$tag] != null)
                and (.address // "local") != "local" and .address != "fakeip") then
              error("DNS 使用了旧 direct override 出站，无法用普通路由动作保持 DNS 目标覆盖语义")
            else . end
          | map(
              if has("dns") then
                .dns as $dns
                | if .dns.servers then
                    .dns.servers |= map(select((.address // "" | startswith("rcode://")) | not)
                        | dns_server($dns.fakeip // {}; $default_out; $dns_strategy))
                  else . end
                | if .dns.rules then .dns.rules |= map(select(has("outbound")|not) | rule_walk(dns_rule)) else . end
                | if $dns.fakeip != null and any($servers[]; .address == "fakeip") then del(.dns.fakeip) else . end
                | if $dns_map[$dns_final].address != null then
                    if ($dns_map[$dns_final].address | startswith("rcode://")) then del(.dns.final)
                    else
                      if ($dns_map[$dns_final].strategy // "") != "" then .dns.strategy=$dns_map[$dns_final].strategy else . end
                      | if $dns_map[$dns_final].client_subnet != null then .dns.client_subnet=$dns_map[$dns_final].client_subnet else . end
                    end
                  else . end
              else . end
              | if .route.rules then .route.rules |= map(rule_walk(route_rule)) else . end
              | if .outbounds then .outbounds |= map(select(.type != "block" and .type != "dns")
                    | . as $out
                    | (resolver_for(.tag // "") // .domain_resolver // $default_resolver) as $resolver
                    | if resolver_for(.tag // "") != null and .domain_resolver == null then .domain_resolver=$resolver else . end
                    | if (.domain_strategy // "") != "" and .domain_strategy != "as_is" then
                        if $resolver == null then error("domain_strategy 缺少可用 DNS 解析器") else
                            .domain_resolver=(if ($resolver|type)=="string" then {server:$resolver} else $resolver end)
                            | if .domain_resolver.strategy != null and .domain_resolver.strategy != $out.domain_strategy
                              then error("domain_strategy 与 domain_resolver.strategy 冲突")
                              else .domain_resolver.strategy=$out.domain_strategy end
                        end
                      else . end | del(.domain_strategy)
                    | if .type=="direct" then del(.override_address,.override_port) else . end)
                else . end
              | if .inbounds then .inbounds |= map(
                    del(.sniff,.sniff_timeout,.sniff_override_destination,.domain_strategy,.udp_disable_domain_unmapping)
                    | if .type == "tun" then
                        reduce ["address","route_address","route_exclude_address"][] as $key (.;
                            if has("inet4_"+$key) or has("inet6_"+$key) then
                                .[$key]=((.[$key]|arr)+(.["inet4_"+$key]|arr)+(.["inet6_"+$key]|arr)
                                    | reduce .[] as $ip ([]; if index($ip)==null then .+[$ip] else . end))
                                | del(.["inet4_"+$key],.["inet6_"+$key])
                            else . end)
                        | del(.gso)
                      else . end
                ) else . end
              | walk(if type=="object" and has("ech") and (.ech|type)=="object" then
                    .ech |= del(.pq_signature_schemes_enabled,.dynamic_record_sizing_disabled)
                  else . end)
            )
          | if ($in_rules|length)>0 then .[0].route.rules=($in_rules+(.[0].route.rules // [])) else . end
          | if $existing_resolver == null and $default_resolver != null then
                .[0].route.default_domain_resolver=$default_resolver
            else . end
          | if ($dns_map[$dns_final].address // "" | startswith("rcode://")) then
                .[-1].dns.rules=((.[-1].dns.rules // []) + [({server:$dns_final} | dns_rule)])
            else . end
          | if $special[$default_out] != null then
                map(if .route.final then del(.route.final) else . end)
                | .[-1].route.rules=((.[-1].route.rules // [])+[{action:$special[$default_out]}])
            elif $overrides[$default_out] != null then
                .[-1].route.rules=((.[-1].route.rules // [])+[{action:"route",outbound:$default_out}+$overrides[$default_out]])
            else . end
        end
        | if $hy2 == 1 then map(
            if .outbounds then .outbounds |= map(
                if .type=="hysteria2" and (has("disable_chrome_parrot")|not)
                  then .disable_chrome_parrot=true else . end)
            else . end)
          else . end
    ' "${sources[@]}" > "$stage/bundle.json"; then
        _error "配置自动适配失败，运行中的配置和核心未改动。请根据上方字段说明处理后重试。"
        return 1
    fi
    for index in "${!sources[@]}"; do
        file="$stage/${names[$index]}"
        jq --argjson index "$index" '.[$index]' "$stage/bundle.json" > "$file" || return 1
        # 无语义变化则保留原始字节，避免每次升级无意义地重排配置。
        if [ "$(jq -Sc . "${sources[$index]}")" = "$(jq -Sc . "$file")" ]; then
            cp -p "${sources[$index]}" "$file" || return 1
        else
            _info "已在副本中适配: ${names[$index]}"
        fi
        check_args+=(-c "$file")
    done
    if ! output=$(
        for deprecated_var in ${!ENABLE_DEPRECATED_@}; do unset "$deprecated_var"; done
        "$candidate" check "${check_args[@]}" 2>&1
    ); then
        _error "自动适配后仍未通过 sing-box ${version} 合并校验；取消更新，保留原服务。"
        printf '%s\n' "$output" >&2
        return 1
    fi
    _success "配置已通过目标核心 ${version} 校验。"
}

_install_sing_box() {
    _info "正在安装最新稳定版 sing-box..."
    local arch=$(uname -m)
    local arch_tag
    local temp_dir=""
    local archive_path=""
    local extracted_bin=""
    case $arch in
        x86_64|amd64) arch_tag='amd64' ;;
        aarch64|arm64) arch_tag='arm64' ;;
        armv7l) arch_tag='armv7' ;;
        *) _error "不支持的架构：$arch"; return 1 ;;
    esac
    
    # 检测 C 库类型：Alpine 等系统使用 musl，需要下载对应版本
    local libc_suffix=""
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        _info "检测到 musl libc (Alpine 等系统)，将下载 musl 版本..."
        libc_suffix="-musl"
    fi
    
    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local release_info release_tag version asset_name
    release_info=$(curl -fLsS --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: singbox-lite-kevin' \
        "$api_url") || { _error "无法获取 sing-box Release 信息。"; return 1; }
    release_tag=$(printf '%s' "$release_info" | jq -r '.tag_name // empty')
    version="${release_tag#v}"
    [ -z "$version" ] && { _error "无法解析 sing-box 稳定版本号。"; return 1; }
    asset_name="sing-box-${version}-linux-${arch_tag}${libc_suffix}.tar.gz"

    temp_dir=$(mktemp -d /root/.singbox-install.XXXXXX) || { _error "创建临时目录失败。"; return 1; }
    archive_path="${temp_dir}/sing-box.tar.gz"

    _info "正在下载 sing-box 安装包..."
    if ! _download_verified_github_asset "$api_url" "$asset_name" "$archive_path"; then
        rm -rf "$temp_dir"
        return 1
    fi

    _info "正在解压 sing-box 安装包..."
    if ! tar -xzf "$archive_path" -C "$temp_dir"; then
        _error "解压 sing-box 安装包失败，临时目录保留: $temp_dir"
        return 1
    fi

    extracted_bin=$(find "$temp_dir" -name sing-box -type f 2>/dev/null | head -n 1)
    if [ -z "$extracted_bin" ]; then
        _error "解压后未找到 sing-box 二进制文件，临时目录保留: $temp_dir"
        return 1
    fi

    chmod 700 "$extracted_bin"
    if ! "$extracted_bin" version 2>/dev/null | head -n 1 | grep -q 'sing-box version'; then
        _error "下载的 sing-box 二进制无法通过版本检查，已拒绝安装。"
        rm -rf "$temp_dir"
        return 1
    fi

    _prepare_core_config_upgrade "$extracted_bin" "$temp_dir/compat" || {
        rm -rf "$temp_dir"; return 1;
    }
    # 全部通过才应用；外层升级事务负责核心、配置与服务文件的回滚。
    CORE_UPGRADE_APPLIED=1
    local config_source config_target config_tmp
    for config_source in "$temp_dir/compat/config.json" "$temp_dir/compat/relay.json"; do
        [ -f "$config_source" ] || continue
        if [[ "$config_source" == */config.json ]]; then config_target="$CONFIG_FILE"
        else config_target="${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}"; fi
        cmp -s "$config_source" "$config_target" && continue
        config_tmp=$(mktemp "${config_target}.upgrade.XXXXXX") || return 1
        if ! install -m 600 "$config_source" "$config_tmp" || ! mv -f "$config_tmp" "$config_target"; then
            rm -f "$config_tmp"; return 1
        fi
    done

    rm -f "$archive_path"

    _info "正在安装 sing-box 二进制文件..."
    mkdir -p "$(dirname "$SINGBOX_BIN")" || {
        _error "创建安装目录失败: $(dirname "$SINGBOX_BIN")"
        return 1
    }
    local binary_tmp
    binary_tmp=$(mktemp "${SINGBOX_BIN}.upgrade.XXXXXX") || return 1
    if ! install -m 700 "$extracted_bin" "$binary_tmp" || ! mv -f "$binary_tmp" "$SINGBOX_BIN"; then
        rm -f "$binary_tmp"
        _error "安装 sing-box 二进制文件失败: $SINGBOX_BIN"
        _error "临时目录保留: $temp_dir"
        return 1
    fi
    touch "${SINGBOX_DIR}/.managed_sing_box"
    rm -rf "$temp_dir"
    _release_install_cache
    _success "sing-box 安装成功: ${SINGBOX_BIN}"
}

# --- 服务与配置管理 ---

_create_systemd_service() {
    local mem_limit_mb=$(_get_mem_limit)
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Environment="GOMEMLIMIT=${mem_limit_mb}MiB"
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE} -c ${SINGBOX_DIR}/relay.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

_create_openrc_service() {
    # 确保日志文件存在
    touch "${LOG_FILE}"
    local mem_limit_mb=$(_get_mem_limit)
    
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

description="sing-box service"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE} -c ${SINGBOX_DIR}/relay.json"
# 使用 supervise-daemon 实现守护和重启
supervisor="supervise-daemon"
supervise_daemon_args="--env GOMEMLIMIT=${mem_limit_mb}MiB"
respawn_delay=3
respawn_max=0

pidfile="${PID_FILE}"
# supervise-daemon 自动将 stdout/stderr 重定向功能需要 openrc 版本支持
# 如果不支持，日志可能不会输出到文件，但服务能正常运行
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$SERVICE_FILE"
}

_create_service_files() {
    
    _info "正在创建 ${INIT_SYSTEM} 服务文件..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        _create_systemd_service
        systemctl daemon-reload
        systemctl enable sing-box
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        touch "$LOG_FILE"
        _create_openrc_service
        rc-update add sing-box default
    elif [ "$INIT_SYSTEM" == "direct" ]; then
        touch "$LOG_FILE"
        _info "当前容器没有 systemd/openrc，将使用 direct 后台模式管理 sing-box。"
        return 0
    fi
    _success "${INIT_SYSTEM} 服务创建并启用成功。"
}


# 注意: _manage_service 已在上方定义，此处不再重复定义

_view_log() (
    local -a logs=()
    local -a readers=()
    local log
    trap '[ "${#readers[@]}" = 0 ] || kill "${readers[@]}" 2>/dev/null; wait 2>/dev/null || true' EXIT
    trap 'exit 0' INT TERM
    for log in "$LOG_FILE" "$XRAY_LOG_FILE"; do [ ! -f "$log" ] || logs+=("$log"); done
    _info "按 Ctrl+C 退出日志查看。"
    if [ "$INIT_SYSTEM" = systemd ]; then
        journalctl -u sing-box -u proxyall-xray -f --no-pager &
        readers+=("$!")
    fi
    if [ "${#logs[@]}" -gt 0 ]; then
        tail -n 50 -F -- "${logs[@]}" &
        readers+=("$!")
    fi
    if [ "${#readers[@]}" = 0 ]; then _warning '日志文件不存在。'; return 0; fi
    wait "${readers[@]}"
)

_uninstall() ( _config_write_lock || exit 1; _uninstall_locked; )

_uninstall_locked() {
    local managed_sing_box=false
    local managed_yq=false
    local managed_cloudflared=false
    local managed_realitlscanner=false
    local managed_go_toolchain=false
    local preserve_router_manager=false
    [ -f "${SINGBOX_DIR}/.managed_sing_box" ] && managed_sing_box=true
    [ -f "${SINGBOX_DIR}/.managed_yq" ] && managed_yq=true
    [ -f "${SINGBOX_DIR}/.managed_cloudflared" ] && managed_cloudflared=true
    [ -f "${SINGBOX_DIR}/.managed_realitlscanner" ] && managed_realitlscanner=true
    [ -f "$GO_TOOLCHAIN_MARKER" ] && managed_go_toolchain=true
    if [ -s "$SNI_ROUTER_STATE_FILE" ] && \
       [ "$(jq -r '.https_routes | length' "$SNI_ROUTER_STATE_FILE" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        preserve_router_manager=true
    fi

    _warning "！！！警告！！！"
    _warning "本操作将停止并禁用 [主脚本] 服务 (sing-box)，"
    _warning "删除所有相关文件 (包括二进制、组件脚本、别名及配置文件)。"
    
    echo ""
    echo "即将删除以下内容："
    echo -e "  ${RED}-${NC} 主配置与脚本目录: ${SINGBOX_DIR}"
    [ "$managed_sing_box" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 sing-box: ${SINGBOX_BIN}"
    [ "$managed_yq" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 yq: ${YQ_BINARY}"
    [ "$managed_cloudflared" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 cloudflared: ${CLOUDFLARED_BIN}"
    [ "$managed_realitlscanner" = true ] && echo -e "  ${RED}-${NC} 本脚本安装的 RealiTLScanner: ${REALITL_SCANNER_BIN}"
    [ "$managed_go_toolchain" = true ] && echo -e "  ${RED}-${NC} RealiTLScanner 专用 Go 工具链: ${GO_TOOLCHAIN_DIR}"
    echo -e "  ${YELLOW}!${NC} Nginx、证书和 ACME 续期任务将保留，避免影响同机 Emby 反代。"
    echo -e "  ${YELLOW}!${NC} 若 HAProxy 仍登记 Emby SNI，将保留 HAProxy 与共享路由状态。"
    echo -e "  ${RED}-${NC} 系统别名: /usr/local/bin/sb"
    echo -e "  ${RED}-${NC} 管理脚本: ${SELF_SCRIPT_PATH}"
    echo ""
    
    read -p "$(echo -e ${YELLOW}"确定要执行卸载吗? (y/N): "${NC})" confirm_main
    [[ "$confirm_main" != "y" && "$confirm_main" != "Y" ]] && _info "卸载已取消。" && return

    # 1. 先注销 Reality 默认后端；失败时保持 sing-box 原状运行。
    local router_reality_tag=""
    router_reality_tag=$(jq -r '.reality.tag // empty' "$SNI_ROUTER_STATE_FILE" 2>/dev/null)
    [ -z "$router_reality_tag" ] || _sni_router_remove_reality "$router_reality_tag" || {
        _error "无法安全注销 HAProxy Reality 后端，卸载已中止。"
        return 1
    }
    local router_tls_tag
    while IFS= read -r router_tls_tag; do
        [ -n "$router_tls_tag" ] || continue
        _sni_router_remove_tls "$router_tls_tag" || {
            _error "无法安全注销 HAProxy TLS 后端 ${router_tls_tag}，卸载已中止。"
            return 1
        }
    done < <(jq -r '.tls_routes | to_entries[]? | select(.value.owner == "sb" or .value.owner == "sb-xray") | .value.tag' "$SNI_ROUTER_STATE_FILE" 2>/dev/null)

    if [ -f "$XRAY_CONFIG_FILE" ] || [ -e "$XRAY_BIN" ] || [ -f "$SYSTEMD_UNIT_DIR/proxyall-xray.service" ] || [ -f /etc/init.d/proxyall-xray ]; then
        if [ -f "$METADATA_FILE" ]; then
            local xhttp_tag
            while IFS= read -r xhttp_tag; do
                [ -n "$xhttp_tag" ] || continue
                _delete_xhttp_node "$xhttp_tag" || return 1
            done < <(jq -r 'to_entries[] | select(.value.core == "xray") | .key' "$METADATA_FILE")
        fi
        _xray_service stop || return 1
        if [ "$INIT_SYSTEM" = systemd ]; then
            systemctl disable proxyall-xray >/dev/null 2>&1 || true
            rm -f "$SYSTEMD_UNIT_DIR/proxyall-xray.service"
        elif [ "$INIT_SYSTEM" = openrc ]; then
            rc-update del proxyall-xray default >/dev/null 2>&1 || true
            rm -f /etc/init.d/proxyall-xray
        fi
        if [ -f "${SINGBOX_DIR}/.managed_xray" ]; then rm -f "$XRAY_BIN"; fi
    fi

    preserve_router_manager=false
    if [ -s "$SNI_ROUTER_STATE_FILE" ] && jq -e '.https_routes | length > 0' "$SNI_ROUTER_STATE_FILE" >/dev/null 2>&1; then
        preserve_router_manager=true
    fi

    # 2. 停止服务并清理定时重启与日志配置
    _manage_service "stop"
    _remove_restart_timer
    _remove_log_cleanup
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl disable sing-box >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-update del sing-box default >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
    fi

    # 3. 清理配置与日志
    _info "正在清理配置文件与日志..."
    _remove_time_sync
    # 清理脚本创建的 nftables 规则
    local pf_meta="${SINGBOX_DIR}/relay_pf.json"
    [ ! -f "$pf_meta" ] && pf_meta="${SINGBOX_DIR}/pf_metadata.json"
    if [ -f "$pf_meta" ] && command -v jq &>/dev/null; then
        # 清理 DNS 动态刷新的 cron 任务
        if crontab -l 2>/dev/null | grep -qF "# pf-dns-auto-refresh"; then
            crontab -l 2>/dev/null | grep -vF "# pf-dns-auto-refresh" | crontab -
        fi
    fi
    _remove_nftables_rules

    # 4. 先停止脚本创建的 Argo 任务，再删除元数据。
    _disable_argo_watchdog 2>/dev/null
    _stop_all_argo_tunnels 2>/dev/null
    rm -rf "${SINGBOX_DIR}" "${LOG_FILE}" "${XRAY_LOG_FILE}" "${ARGO_LOG_FILE}"
    if [ "$managed_cloudflared" = true ]; then
        rm -f "${CLOUDFLARED_BIN}"
    fi
    if [ "$managed_realitlscanner" = true ]; then
        rm -f "$REALITL_SCANNER_BIN" "$REALITL_SCANNER_MARKER" "${REALITL_SCANNER_DIR}/RealiTLScanner.commit"
    fi
    if [ "$managed_go_toolchain" = true ] && [ "$GO_TOOLCHAIN_DIR" = "/usr/local/lib/singbox-lite/go-toolchain" ]; then
        rm -rf -- "$GO_TOOLCHAIN_DIR"
    fi
    rmdir "$REALITL_SCANNER_DIR" 2>/dev/null || true

    # 5. 若 Emby 仍依赖共享入口，保留管理命令，避免 deploy.sh 以后无法注销路由。
    _info "正在清理周边环境..."
    if [ "$preserve_router_manager" = true ]; then
        _warn "检测到仍在使用的 Emby SNI 路由，将保留 ${SELF_SCRIPT_PATH} 与 /usr/local/bin/sb 作为 HAProxy 管理器。"
    else
        rm -f "/usr/local/bin/sb"
    fi
    
    # 6. 仅删除带有本脚本管理标记的二进制，避免误删用户已有程序。
    local relay_script="/root/relay-install.sh"
    if [ -f "$relay_script" ]; then
        _warn "检测到 [线路机] 脚本存在，为保持其运行，将 [保留] sing-box 主程序。"
    else
        [ "$managed_sing_box" = true ] && rm -f "${SINGBOX_BIN}"
        [ "$managed_yq" = true ] && rm -f "${YQ_BINARY}"
    fi

    if [ "$preserve_router_manager" = true ]; then
        _success "Sing-box 核心与节点已清理；HAProxy/Emby 路由管理器已保留。"
    else
        _success "清理完成。脚本已自毁。再见！"
        [ -f "${SELF_SCRIPT_PATH}" ] && rm -f "${SELF_SCRIPT_PATH}"
    fi
    exit 0
}

_initialize_config_files() {
    mkdir -p ${SINGBOX_DIR}
    if [ ! -s "$CONFIG_FILE" ]; then
        # 初始化包含完整 dns 配置和路由策略的基础文件，以支持中转第三方域名节点
        cat > "$CONFIG_FILE" << 'EOF'
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-main"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [],
    "default_domain_resolver": "dns-main",
    "final": "direct"
  }
}
EOF
    fi
    [ -s "$METADATA_FILE" ] || echo "{}" > "$METADATA_FILE"
    
    # [关键修复] 初始化 relay.json - 服务启动命令会加载这个文件
    # 必须确保在服务运行前此文件物理存在，否则 sing-box 会 Fatal 退出
    local RELAY_JSON="${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}"
    if [ ! -s "$RELAY_JSON" ]; then
        echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$RELAY_JSON"
        _info "已初始化中转配置文件: $RELAY_JSON"
    fi
    if [ ! -s "$CLASH_YAML_FILE" ]; then
        _info "正在创建全新的 clash.yaml 配置文件..."
        cat > "$CLASH_YAML_FILE" << 'EOF'
port: 7890
socks-port: 7891
mixed-port: 7892
allow-lan: false
bind-address: '*'
mode: rule
log-level: info
ipv6: true
find-process-mode: strict
external-controller: '127.0.0.1:9090'
profile:
  store-selected: true
  store-fake-ip: true
unified-delay: true
tcp-concurrent: true
ntp:
  enable: true
  write-to-system: false
  server: ntp.aliyun.com
  port: 123
  interval: 30
dns:
  enable: true
  respect-rules: true
  use-system-hosts: true
  prefer-h3: false
  listen: '0.0.0.0:1053'
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  fake-ip-filter:
    - +.lan
    - +.local
    - localhost.ptlogin2.qq.com
    - +.msftconnecttest.com
    - +.msftncsi.com
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
    - 'https://1.1.1.1/dns-query'
    - 'https://dns.quad9.net/dns-query'
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  proxy-server-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 'https://1.0.0.1/dns-query'
    - 'https://9.9.9.10/dns-query'
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - 'any:53'
  device: SakuraiTunnel
  endpoint-independent-nat: true
proxies: []
proxy-groups:
  - name: 节点选择
    type: select
    proxies: []
rules:
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF
    fi
}

_init_relay_config() {
    # 确保中转配置文件存在 (隔离配置)
    if [ ! -s "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" ]; then
        echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}"
        _info "已初始化中转配置文件"
    fi
}

_cleanup_legacy_config() {
    # 检查并清理 config.json 中残留的旧版中转配置 (tag 以 relay-out- 开头的 outbound)
    # 这些残留会导致路由冲突，使主脚本节点误走中转线路
    local needs_restart=false
    
    if jq -e '.outbounds[] | select(.tag | startswith("relay-out-"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warn "检测到旧版中转残留配置，正在清理..."
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_legacy"
        
        # 删除所有 relay-out- 开头的 outbounds
        jq 'del(.outbounds[] | select(.tag | startswith("relay-out-")))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        
        # 删除所有 relay-out- 开头的路由规则 (如果有)
        if jq -e '.route.rules' "$CONFIG_FILE" >/dev/null 2>&1; then
            jq 'del(.route.rules[] | select(.outbound | startswith("relay-out-")))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        
        # 确保存在 direct 出站且位于第一位 (如果没有 direct，添加一个)
        if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
             jq '.outbounds = [{"type":"direct","tag":"direct"}] + .outbounds' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        
        _success "配置清理完成。相关中转已被迁移至独立配置文件 (relay.json)。"
        needs_restart=true
    fi
    
    # [关键修复] 确保 route.final 设置为 "direct"
    # 这是核心修复：当 config.json 和 relay.json 合并时，relay-out-* outbound 会被插入到 outbounds 列表前面
    # 如果没有 route.final，sing-box 会使用列表中的第一个 outbound 作为默认出口，导致主节点流量走中转
    if ! jq -e '.route.final == "direct"' "$CONFIG_FILE" >/dev/null 2>&1; then
        _warn "检测到 route.final 未设置或不正确，正在修复..."
        
        # 确保 route 对象存在
        if ! jq -e '.route' "$CONFIG_FILE" >/dev/null 2>&1; then
            jq '. + {"route":{"rules":[],"final":"direct"}}' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        else
            # 设置 route.final = "direct"
            jq '.route.final = "direct"' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        
        _success "route.final 已设置为 direct，主节点流量将走本机 IP。"
        needs_restart=true
    fi
    
    if [ "$needs_restart" = true ]; then
        return 0
    fi
    return 1
}

_build_dns_config() {
    local dns_address="$1" dns_strategy="$2"
    local scheme rest authority host port path default_port main_json
    local needs_bootstrap=false

    if [ "$dns_address" = "local" ]; then
        jq -n --arg strategy "$dns_strategy" \
            '{servers:[{type:"local",tag:"dns-main"}],strategy:$strategy}'
        return
    fi

    if [[ "$dns_address" == *"://"* ]]; then
        scheme="${dns_address%%://*}"
        rest="${dns_address#*://}"
    elif _is_valid_ipv4 "$dns_address" || [[ "$dns_address" =~ ^\[?[0-9A-Fa-f:]+\]?$ && "$dns_address" == *:* ]]; then
        scheme="udp"
        rest="$dns_address"
    else
        return 1
    fi
    case "$scheme" in
        udp|tcp|tls|https) ;;
        *) return 1 ;;
    esac

    if [ "$scheme" = "https" ]; then
        authority="${rest%%/*}"
        if [[ "$rest" == */* ]]; then
            path="/${rest#*/}"
        else
            path="/dns-query"
        fi
        [ -n "$path" ] || path="/dns-query"
    else
        [[ "$rest" != */* ]] || return 1
        authority="$rest"
        path=""
    fi

    if [[ "$authority" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
    elif [[ "$authority" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$authority" =~ ^[0-9A-Fa-f:]+$ && "$authority" == *:* ]]; then
        host="$authority"
        port=""
    else
        host="$authority"
        port=""
    fi
    [[ -n "$host" && "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1

    case "$scheme" in
        udp|tcp) default_port=53 ;;
        tls) default_port=853 ;;
        https) default_port=443 ;;
    esac
    port="${port:-$default_port}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1

    main_json=$(jq -n --arg type "$scheme" --arg server "$host" --argjson port "$port" --arg path "$path" '
        {type:$type,tag:"dns-main",server:$server,server_port:$port}
        | if $type == "https" then .path = $path else . end
    ') || return 1
    if ! _is_valid_ipv4 "$host" && [[ "$host" != *:* ]]; then
        needs_bootstrap=true
    fi

    if [ "$needs_bootstrap" = true ]; then
        jq -n --argjson main "$main_json" --arg strategy "$dns_strategy" '
            {servers:[($main + {domain_resolver:"dns-bootstrap"}),{type:"local",tag:"dns-bootstrap"}],strategy:$strategy}
        '
    else
        jq -n --argjson main "$main_json" --arg strategy "$dns_strategy" \
            '{servers:[$main],strategy:$strategy}'
    fi
}

_dns_current_address() {
    jq -r '
        ((.dns.servers[]? | select(.tag == "dns-main")) // .dns.servers[0]? // {}) as $server
        | if (($server.address? // "") | type) == "string" and ($server.address? // "") != "" then
            $server.address
          elif $server.type == "local" then
            "local"
          elif ($server.server? // "") != "" then
            ($server.server | if contains(":") then "[" + . + "]" else . end) as $host
            | (($server.type // "udp") + "://" + $host
               + (if $server.server_port? then ":" + ($server.server_port | tostring) else "" end)
               + (if $server.type == "https" then ($server.path // "/dns-query") else "" end))
          else
            "未设置"
          end
    ' "$CONFIG_FILE" 2>/dev/null
}

_check_and_fix_dns() {
    # 迁移脚本旧版 DNS 格式，避免 sing-box 1.14 删除兼容入口后首次启动失败。
    # 返回值：0=已修改，1=无需修改，2=迁移失败。
    if [ ! -f "$CONFIG_FILE" ]; then return 2; fi

    local has_dns dns_strategy legacy_count resolver_tag
    local needs_restart=false tmp_file dns_json legacy_address legacy_tag
    has_dns=$(jq -r '(.dns.servers? | type == "array") and ((.dns.servers | length) > 0)' "$CONFIG_FILE" 2>/dev/null)
    dns_strategy=$(jq -r '.dns.strategy // ""' "$CONFIG_FILE" 2>/dev/null)
    legacy_count=$(jq -r '[.dns.servers[]? | select(has("address"))] | length' "$CONFIG_FILE" 2>/dev/null)
    tmp_file="${CONFIG_FILE}.tmp"

    if [ "$has_dns" != "true" ]; then
        dns_json=$(_build_dns_config local "${dns_strategy:-prefer_ipv4}") || return 2
        jq --argjson dns "$dns_json" '
            .dns = ((.dns // {}) + $dns)
            | .route = (.route // {rules:[],final:"direct"})
            | .route.default_domain_resolver = "dns-main"
        ' "$CONFIG_FILE" > "$tmp_file" || { rm -f "$tmp_file"; return 2; }
        needs_restart=true
    elif [ "$legacy_count" -gt 0 ]; then
        if [ "$legacy_count" -ne 1 ] || [ "$(jq -r '.dns.servers | length' "$CONFIG_FILE")" -ne 1 ]; then
            _warn "检测到自定义的多服务器旧版 DNS 配置，无法无损自动迁移。"
            _warn "请先在 DNS 菜单重新选择服务器，再升级到 sing-box 1.14。"
            return 2
        fi
        if ! jq -e '(.dns.servers[0] | keys - ["address","tag"]) | length == 0' "$CONFIG_FILE" >/dev/null; then
            _warn "旧 DNS 服务器包含额外自定义选项，不能无损自动迁移；请手动按官方迁移指南处理。"
            return 2
        fi
        legacy_address=$(jq -r '.dns.servers[0].address // empty' "$CONFIG_FILE")
        legacy_tag=$(jq -r '.dns.servers[0].tag // "dns-main"' "$CONFIG_FILE")
        dns_json=$(_build_dns_config "$legacy_address" "${dns_strategy:-prefer_ipv4}") || {
            _warn "旧版 DNS 地址无法自动迁移: ${legacy_address}"
            return 2
        }
        dns_json=$(jq --arg tag "$legacy_tag" '.servers[0].tag=$tag' <<< "$dns_json") || return 2
        jq --argjson dns "$dns_json" --arg tag "$legacy_tag" '
            .dns = (.dns + $dns)
            | .route = (.route // {rules:[],final:"direct"})
            | .route.default_domain_resolver = (.route.default_domain_resolver // $tag)
        ' "$CONFIG_FILE" > "$tmp_file" || { rm -f "$tmp_file"; return 2; }
        needs_restart=true
    else
        resolver_tag=$(jq -r '.dns.servers[0].tag // empty' "$CONFIG_FILE")
        if [ -z "$dns_strategy" ] || { [ -n "$resolver_tag" ] && ! jq -e '.route.default_domain_resolver? | (type == "object") or (type == "string" and length > 0)' "$CONFIG_FILE" >/dev/null 2>&1; }; then
            jq --arg strategy "${dns_strategy:-prefer_ipv4}" --arg resolver "$resolver_tag" '
                .dns.strategy = $strategy
                | .route = (.route // {rules:[],final:"direct"})
                | if $resolver != "" and ((.route.default_domain_resolver // "") == "") then .route.default_domain_resolver = $resolver else . end
            ' "$CONFIG_FILE" > "$tmp_file" || { rm -f "$tmp_file"; return 2; }
            needs_restart=true
        fi
    fi

    if [ "$needs_restart" = true ]; then
        if [ -s "$tmp_file" ] && mv "$tmp_file" "$CONFIG_FILE"; then
            _success "DNS 配置已迁移到 sing-box 1.14 兼容格式。"
        else
            _error "DNS 配置兼容性修复失败。"
            rm -f "$tmp_file"
            return 2
        fi
    fi

    if [ -f "$CLASH_YAML_FILE" ] && [ -x "$YQ_BINARY" ]; then
        local clash_ipv6=$(${YQ_BINARY} eval '.ipv6 // false' "$CLASH_YAML_FILE" 2>/dev/null)
        local clash_dns_ipv6=$(${YQ_BINARY} eval '.dns.ipv6 // false' "$CLASH_YAML_FILE" 2>/dev/null)
        if [ "$clash_ipv6" != "true" ] || [ "$clash_dns_ipv6" != "true" ]; then
            if _atomic_modify_yaml "$CLASH_YAML_FILE" '.ipv6 = true | .dns.ipv6 = true' >/dev/null 2>&1; then
                _success "已开启 clash.yaml 的 IPv6 与 DNS IPv6 支持。"
            else
                _warn "clash.yaml IPv6 自动修复失败，请手动检查 YAML 格式。"
            fi
        fi
    fi
    
    if [ "$needs_restart" == "true" ]; then
        return 0
    fi
    return 1
}

_check_config() {
    _xray_validate || return 1
    if [ ! -x "$SINGBOX_BIN" ]; then
        if [ -f "$CONFIG_FILE" ] && jq -e '(.inbounds // [] | length) > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
            _error "未找到 sing-box 核心: ${SINGBOX_BIN}"
            return 1
        fi
        _success "Xray 配置校验通过。"
        return 0
    fi
    _info "正在检查 sing-box 配置文件..."
    # 捕获所有输出（包括 stderr 产生的大量 WARN 和 TRACE 弃用警告）
    local result
    result=$("${SINGBOX_BIN}" check -c "${CONFIG_FILE}" -c "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" 2>&1)
    if [[ $? -eq 0 ]]; then
        _success "主配置与中转配置合并校验通过。"
    else
        _error "配置文件检查失败:"
        echo "$result"
        return 1
    fi
}

_apply_dns_config_locked() {
    local dns_address="$1"
    local dns_strategy="$2"
    local tmp_file="${CONFIG_FILE}.dns.tmp.$$"
    local backup_file="${CONFIG_FILE}.bak_dns_$(date +%Y%m%d_%H%M%S)"
    local check_result dns_json

    dns_json=$(_build_dns_config "$dns_address" "$dns_strategy") || {
        _error "DNS 地址格式无效，仅支持 local、IP 或 udp/tcp/tls/https URL。"
        return 1
    }
    if ! jq --argjson dns "$dns_json" '
        .dns = $dns
        | .route = (.route // {rules:[],final:"direct"})
        | .route.default_domain_resolver = "dns-main"
        | del(.route.auto_detect_interface)
    ' "$CONFIG_FILE" > "$tmp_file"; then
        _error "生成 DNS 配置失败。"
        rm -f "$tmp_file"
        return 1
    fi

    check_result=$(${SINGBOX_BIN} check -c "$tmp_file" 2>&1)
    if [ $? -ne 0 ]; then
        _error "新的 DNS 配置未通过 sing-box 校验，原配置未修改："
        echo "$check_result"
        rm -f "$tmp_file"
        return 1
    fi

    if ! cp "$CONFIG_FILE" "$backup_file" || ! mv "$tmp_file" "$CONFIG_FILE"; then
        _error "保存 DNS 配置失败。"
        rm -f "$tmp_file"
        return 1
    fi

    _retain_latest_backups dns "$CONFIG_FILE".bak_dns_* || return 1

    _success "DNS 配置已保存，备份文件：${backup_file}"
    _manage_service "restart"
}

_dns_config_menu() {
    local current_address current_strategy choice dns_address dns_strategy

    while true; do
        current_address=$(_dns_current_address)
        current_strategy=$(jq -r '.dns.strategy // "prefer_ipv4"' "$CONFIG_FILE" 2>/dev/null)
        [ -z "$current_address" ] || [ "$current_address" = "null" ] && current_address="未设置"
        [ -z "$current_strategy" ] || [ "$current_strategy" = "null" ] && current_strategy="prefer_ipv4"

        [ ! -t 0 ] || [ ! -t 1 ] || clear
        echo -e "${CYAN}"
        echo "  ╔═══════════════════════════════════════╗"
        echo "  ║          sing-box DNS 设置            ║"
        echo "  ╚═══════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  当前 DNS:  ${GREEN}${current_address}${NC}"
        echo -e "  当前策略:  ${GREEN}${current_strategy}${NC}"
        echo ""
        echo -e "    ${GREEN}[1]${NC} 系统 DNS（local）"
        echo -e "    ${GREEN}[2]${NC} 阿里 DNS（DoH）"
        echo -e "    ${GREEN}[3]${NC} 腾讯 DNSPod（DoH）"
        echo -e "    ${GREEN}[4]${NC} Cloudflare（DoH）"
        echo -e "    ${GREEN}[5]${NC} Google（DoH）"
        echo -e "    ${GREEN}[6]${NC} 自定义 DNS 地址"
        echo -e "    ${GREEN}[7]${NC} 修改域名解析策略"
        echo -e "    ${GREEN}[8]${NC} 查看完整 DNS 配置"
        echo ""
        echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
        echo ""
        read -p "  请输入选项 [0-8]: " choice

        dns_address=""
        dns_strategy="$current_strategy"
        case "$choice" in
            1) dns_address="local" ;;
            2) dns_address="https://dns.alidns.com/dns-query" ;;
            3) dns_address="https://doh.pub/dns-query" ;;
            4) dns_address="https://1.1.1.1/dns-query" ;;
            5) dns_address="https://dns.google/dns-query" ;;
            6)
                echo ""
                echo "  支持 local、IP、udp://、tcp://、tls://、https:// 等 sing-box DNS 地址。"
                read -r -p "  请输入 DNS 地址（留空取消）: " dns_address
                [ -z "$dns_address" ] && continue
                if [[ "$dns_address" =~ [[:space:]] ]]; then
                    _error "DNS 地址不能包含空白字符。"
                    read -n 1 -s -r -p "按任意键继续..."
                    continue
                fi
                ;;
            7)
                echo ""
                echo "    1) prefer_ipv4（推荐，IPv4 优先）"
                echo "    2) prefer_ipv6（IPv6 优先）"
                echo "    3) ipv4_only（仅 IPv4）"
                echo "    4) ipv6_only（仅 IPv6）"
                read -p "  请选择解析策略 [1-4]: " strategy_choice
                case "$strategy_choice" in
                    1) dns_strategy="prefer_ipv4" ;;
                    2) dns_strategy="prefer_ipv6" ;;
                    3) dns_strategy="ipv4_only" ;;
                    4) dns_strategy="ipv6_only" ;;
                    *) _error "无效输入。"; read -n 1 -s -r -p "按任意键继续..."; continue ;;
                esac
                dns_address="$current_address"
                if [ "$dns_address" = "未设置" ]; then
                    dns_address="local"
                fi
                ;;
            8)
                echo ""
                jq '.dns' "$CONFIG_FILE" 2>/dev/null || _error "无法读取 DNS 配置。"
                echo ""
                read -n 1 -s -r -p "按任意键继续..."
                continue
                ;;
            0) return ;;
            *) _error "无效输入，请重试。"; read -n 1 -s -r -p "按任意键继续..."; continue ;;
        esac

        echo ""
        _info "准备设置 DNS 为 ${dns_address}，解析策略为 ${dns_strategy}。"
        read -r -p "  确认保存并重启 sing-box？[Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            continue
        fi
        _apply_dns_config "$dns_address" "$dns_strategy"
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

_update_script() {
    _proxyall_require_bundle_install
}

# 守卫函数：检查 sing-box 核心是否已安装
_require_singbox() {
    if [ ! -f "${SINGBOX_BIN}" ]; then
        _error "此功能需要先安装 Sing-box 核心。请前往主菜单【核心管理】-> [15] 进行安装。"
        return 1
    fi
    return 0
}

_require_any_core() {
    if [ ! -f "${SINGBOX_BIN}" ] && [ ! -x "${XRAY_BIN}" ]; then
        _error "尚未安装 Sing-box 或 Xray 核心。请先在主菜单选择 [15] 安装 Sing-box，或选择 [1] 添加 XHTTP 节点按需安装 Xray。"
        return 1
    fi
    return 0
}

# [安装/更新 Sing-box 核心] — 双模态：未装就装、已装就更新
_install_or_update_singbox() {
    if [ -f "${SINGBOX_BIN}" ]; then
        local current_ver=$(${SINGBOX_BIN} version 2>/dev/null | head -n1 | awk '{print $3}')
        _info "当前 Sing-box 版本: v${current_ver}，正在检查更新..."
    else
        _info "Sing-box 核心未安装，正在执行首次安装..."
    fi
    _do_update_singbox
}

_rollback_core_upgrade() {
    local backup="$1" tmp name target failed=0
    _warn "正在恢复升级前的 sing-box 核心、配置与服务文件..."
    tmp=$(mktemp "${SINGBOX_BIN}.rollback.XXXXXX") || return 1
    if ! install -m 700 "$backup/sing-box" "$tmp" || ! mv -f "$tmp" "$SINGBOX_BIN"; then
        rm -f "$tmp"; failed=1
    fi
    for name in config.json relay.json clash.yaml service; do
        case "$name" in
            config.json) target="$CONFIG_FILE" ;;
            relay.json) target="${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" ;;
            clash.yaml) target="$CLASH_YAML_FILE" ;;
            service) target="$SERVICE_FILE" ;;
        esac
        [ -n "$target" ] || continue
        if [ -f "$backup/$name" ]; then cp -a "$backup/$name" "$target" || failed=1
        else rm -f "$target" || failed=1; fi
    done
    if [ "$INIT_SYSTEM" = systemd ]; then systemctl daemon-reload || failed=1; fi
    if [ "$failed" = 0 ] && _manage_service restart 9>&-; then
        _success "已恢复升级前版本与配置。备份保留在 $backup"
        return 0
    fi
    _error "自动恢复未完全成功，请从 $backup 手动恢复并检查日志。"
    return 1
}

# 子 shell 将升级锁和中断回滚 trap 限定在本次操作，不影响菜单/SSH。
_do_update_singbox() (
    _config_write_lock || exit 1
    _info "--- 安装/更新 Sing-box 核心 ---"
    local update_backup_dir=""
    local had_previous_binary=false
    local config_check_output=""
    local CORE_UPGRADE_APPLIED=0

    _install_dependencies true || return 1
    mkdir -p "$SINGBOX_DIR" || { _error "无法创建 sing-box 配置目录。"; return 1; }
    command -v flock >/dev/null 2>&1 || _pkg_install util-linux || return 1
    exec 9>"$SINGBOX_DIR/.core-upgrade.lock" || return 1
    flock -n 9 || { _error "另一个内核升级正在进行，请稍后再试。"; return 1; }
    _core_upgrade_exit() {
        local status="$1"
        trap - EXIT INT TERM HUP
        if [ "$CORE_UPGRADE_APPLIED" = 1 ] && [ "$had_previous_binary" = true ]; then
            _rollback_core_upgrade "$update_backup_dir" || true
        fi
        exit "$status"
    }
    trap '_core_upgrade_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    if [ -f "$SINGBOX_BIN" ]; then
        update_backup_dir=$(mktemp -d /root/.singbox-update.XXXXXX) || {
            _error "无法创建升级回滚目录，已取消更新。"
            return 1
        }
        if ! cp -a "$SINGBOX_BIN" "${update_backup_dir}/sing-box"; then
            _error "备份当前 sing-box 核心失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        if [ -f "$CONFIG_FILE" ] && ! cp -a "$CONFIG_FILE" "${update_backup_dir}/config.json"; then
            _error "备份主配置失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        if [ -f "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" ] && ! cp -a "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" "${update_backup_dir}/relay.json"; then
            _error "备份中转配置失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        if [ -f "$CLASH_YAML_FILE" ] && ! cp -a "$CLASH_YAML_FILE" "${update_backup_dir}/clash.yaml"; then
            _error "备份订阅配置失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        if [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ] && \
           ! cp -a "$SERVICE_FILE" "${update_backup_dir}/service"; then
            _error "备份原服务文件失败，已取消更新。"
            rm -rf "$update_backup_dir"
            return 1
        fi
        had_previous_binary=true
    fi

    if ! _install_sing_box; then
        _error "Sing-box 核心安装/更新失败。"
        if [ "$CORE_UPGRADE_APPLIED" = 0 ]; then
            _info "升级前检查未通过，原核心、配置和运行服务保持不变。"
            [ -z "$update_backup_dir" ] || _info "升级前备份已保留: $update_backup_dir"
            return 1
        fi
    else
        _success "sing-box 安装/更新成功！"
        # 确保配置文件存在
        if [ ! -f "${CONFIG_FILE}" ] || [ ! -f "${CLASH_YAML_FILE}" ]; then
            _info "检测到主配置文件缺失，正在初始化..."
            _initialize_config_files
        fi
        _init_relay_config
        _create_service_files
        _setup_log_cleanup || true

        if config_check_output=$("$SINGBOX_BIN" check -c "$CONFIG_FILE" -c "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" 2>&1); then
            _info "正在启动/重启 [主] 服务 (sing-box)..."
            if _manage_service "restart" 9>&-; then
                CORE_UPGRADE_APPLIED=0
                _retain_latest_backups core "$SB_ROOT_HOME"/.singbox-update.* || _warn '核心备份清理失败。'
                [ -z "$update_backup_dir" ] || _info "升级前核心与配置备份已保留: ${update_backup_dir}"
                _success "[主] 服务已就绪。"
                return 0
            fi
            _error "新核心启动失败。"
        else
            _error "新核心安装后的合并配置校验失败："
            printf '%s\n' "$config_check_output" >&2
        fi
    fi

    # EXIT trap 对失败和中断统一回滚，备份不自动删除。
    [ -z "$update_backup_dir" ] || _info "升级前备份已保留: ${update_backup_dir}"
    return 1
)
_apply_dns_config() ( _config_write_lock || exit 1; _apply_dns_config_locked "$@"; )
