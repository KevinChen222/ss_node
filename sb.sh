#!/bin/bash

# SB_MANAGER_MANAGED_COMMAND=1

# >>> proxyall bootstrap
# 本段在 sb.sh 与 deploy.sh 中逐字一致（tests/common.py 校验）。已安装入口只从固定库目录
# /usr/local/lib/proxyall 加载，经符号链接调用也一样；从仓库检出运行时使用同目录下的 lib/。
_proxyall_trusted_lib_path() {
    local path=$1 depth=${2:-0} owner mode link
    (( depth < 40 )) || return 1
    while :; do
        if [[ -L $path ]]; then
            [[ $(stat -c '%u' -- "$path") == 0 ]] || return 1
            link=$(readlink -- "$path") || return 1
            [[ $link == /* ]] || link="${path%/*}/$link"
            _proxyall_trusted_lib_path "$link" "$((depth + 1))" || return 1
        fi
        read -r owner mode < <(stat -Lc '%u %a' -- "$path") || return 1
        [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
        [[ $path != / ]] || break
        path=${path%/*}; path=${path:-/}
    done
}

# 用法：_proxyall_check_libraries 目录 文件名...
# 每个文件须是带 "# PROXYALL_LIB=文件名" 标记的普通文件；固定库目录还要求整条路径只有 root 可写。
_proxyall_check_libraries() {
    local dir=$1 name
    shift
    [[ -d $dir && ! -L $dir ]] || return 1
    for name in "$@"; do
        [[ -f $dir/$name && -r $dir/$name && ! -L $dir/$name ]] || return 1
        if [[ $dir == /usr/local/lib/proxyall ]]; then
            _proxyall_trusted_lib_path "$dir/$name" || return 1
        fi
        grep -Fqx -- "# PROXYALL_LIB=$name" "$dir/$name" || return 1
    done
}

# 用法：_proxyall_resolve_lib_dir 检出文件名 安装路径
_proxyall_resolve_lib_dir() {
    local entry
    entry=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null) || entry=
    if [[ $entry == */"$1" && -f $entry && ! $entry -ef $2 ]]; then
        printf '%s\n' "${entry%/*}/lib"
    else
        printf '%s\n' /usr/local/lib/proxyall
    fi
}
# <<< proxyall bootstrap

_proxyall_lib_dir=$(_proxyall_resolve_lib_dir sb.sh /usr/local/bin/sb)
# 启动时加载的功能模块，依赖顺序在前；中转与链接解析组件在进入中转菜单时再加载。
SB_MODULES=(nft.sh reality.sh sb_tx.sh sb_core.sh sb_origin.sh sb_nodes.sh sb_argo.sh
    sb_proto_vless.sh sb_proto_anytls.sh sb_proto_tls.sh sb_proto_quic.sh sb_proto_basic.sh
    sb_proto_xhttp.sh)
SB_COMPONENTS=(relay.sh parser.sh)
SB_LIB_DIR=$_proxyall_lib_dir
SB_MODULES_READY=false
if _proxyall_check_libraries "$_proxyall_lib_dir" common.sh sni_router.sh &&
    source "$_proxyall_lib_dir/common.sh" && source "$_proxyall_lib_dir/sni_router.sh"; then
    # 两步升级的第一步只换入口和公共库；此时维护命令可用，其余功能提示再更新一次。
    if _proxyall_check_libraries "$_proxyall_lib_dir" "${SB_MODULES[@]}" "${SB_COMPONENTS[@]}"; then
        SB_MODULES_READY=true
    fi
elif [[ ${BASH_SOURCE[0]} == "$0" && $(readlink -f -- "$0" 2>/dev/null) -ef /usr/local/bin/sb &&
    ${PROXYALL_MANAGED:-0} == 1 && $# == 1 && $1 == setup-maintenance &&
    ! -e $_proxyall_lib_dir/common.sh && ! -L $_proxyall_lib_dir/common.sh &&
    ! -e $_proxyall_lib_dir/sni_router.sh && ! -L $_proxyall_lib_dir/sni_router.sh ]]; then
    # 三文件旧版安装器在库尚未安装时调用本命令；维护任务在下一次更新补齐配套库后设置。
    printf '%s\n' '配套库尚未安装，日志维护将在下一次 proxyall 更新补齐配套库后设置。' >&2
    exit 0
else
    printf '配套库缺失或不可信（%s）。请运行 proxyall --install 或 proxyall --update，或从完整仓库运行。\n' "$_proxyall_lib_dir" >&2
    return 1 2>/dev/null || exit 1
fi
unset _proxyall_lib_dir
unset -f _proxyall_trusted_lib_path _proxyall_check_libraries _proxyall_resolve_lib_dir

# 所有运行时配置、节点凭据和私钥默认仅允许 root 读取。
umask 077

# 基础路径定义
export SCRIPT_VERSION="23-singbox.2"
export DEFAULT_SNI="www.icloud.com"
export DEFAULT_REALITY_SNI="www.amd.com"
export WS_EARLY_DATA_SIZE="2560"
export WS_EARLY_DATA_HEADER="Sec-WebSocket-Protocol"
SELF_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF_SCRIPT_PATH")"
SINGBOX_DIR="/usr/local/etc/sing-box"

# 单机自有域名模式与 nginx_proxy/deploy.sh 使用相同的 Nginx/证书目录结构。
REALITY_LOCAL_ORIGIN_HOST="127.0.0.1"
REALITY_LOCAL_ORIGIN_PORT=8443
SB_ROOT_HOME="$(awk -F: '$3 == 0 {print $6; exit}' /etc/passwd 2>/dev/null || true)"
SB_ROOT_HOME="${SB_ROOT_HOME:-/root}"
NGINX_ROOT="/etc/nginx"
NGINX_MAIN_CONF="${NGINX_ROOT}/nginx.conf"
NGINX_CONF_DIR="${NGINX_ROOT}/conf.d"
NGINX_CERT_DIR="${NGINX_ROOT}/certs"
NGINX_BACKUP_DIR="${NGINX_ROOT}/backup"
ACME_WEBROOT="/var/www/acme-challenge"
SB_ACME_HOME="${SB_ROOT_HOME}/.acme.sh"
SB_ACME_SH="${SB_ACME_HOME}/acme.sh"
SB_ACME_VERSION="$PROXYALL_ACME_VERSION"
SB_ACME_ARCHIVE_SHA256="$PROXYALL_ACME_ARCHIVE_SHA256"
SB_ACME_ARCHIVE_URL="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${SB_ACME_VERSION}.tar.gz"
SB_ACME_RELOAD_CMD='if [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s reload 8>&- 9>&-; elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx 8>&- 9>&-; elif command -v service >/dev/null 2>&1 && service nginx start 8>&- 9>&-; then :; else nginx 8>&- 9>&-; fi'
SB_ACME_NAIVE_RELOAD_CMD="${SB_ACME_RELOAD_CMD}; if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sing-box 2>/dev/null; then systemctl restart sing-box 8>&- 9>&-; elif command -v rc-service >/dev/null 2>&1 && rc-service sing-box status >/dev/null 2>&1; then rc-service sing-box restart 8>&- 9>&-; fi"


# --- 核心变量定义 ---
export SINGBOX_DIR="/usr/local/etc/sing-box"
export XRAY_BIN="/usr/local/lib/singbox-lite/xray"
export XRAY_CONFIG_FILE="${SINGBOX_DIR}/xray.json"
export XRAY_PID_FILE="${SINGBOX_DIR}/xray.pid"
export XRAY_LOG_FILE="${SINGBOX_DIR}/xray.log"

export SINGBOX_BIN="/usr/local/bin/sing-box"
export YQ_BINARY="/usr/local/bin/yq"
export CONFIG_FILE="${SINGBOX_DIR}/config.json"
export CLASH_YAML_FILE="${SINGBOX_DIR}/clash.yaml"
export METADATA_FILE="${SINGBOX_DIR}/metadata.json"
export ARGO_METADATA_FILE="${SINGBOX_DIR}/argo_metadata.json"
export LOG_FILE="/var/log/sing-box.log"
export ARGO_LOG_FILE="/var/log/singbox_argo.log"
export PID_FILE="/tmp/sing-box.pid"
export CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
export DEP_STATE_FILE="${SINGBOX_DIR}/dependencies.ok"
export DEP_STATE_VERSION="20260820-secure-1"

if [ "$SB_MODULES_READY" = true ]; then
    for _sb_module in "${SB_MODULES[@]}"; do
        source "$SB_LIB_DIR/$_sb_module" || {
            printf 'sb 功能模块加载失败：%s\n' "$SB_LIB_DIR/$_sb_module" >&2
            return 1 2>/dev/null || exit 1
        }
    done
    unset _sb_module
fi

# 主菜单、节点操作和中转需要全部功能模块；维护命令只依赖入口与公共库。
_sb_require_modules() {
    [ "$SB_MODULES_READY" = true ] && return 0
    _error "sb 功能模块缺失或不可信（${SB_LIB_DIR}）。请再运行一次 proxyall --update，或在 proxyall 菜单选择 3 检查脚本更新，以补齐全部模块。"
    return 1
}

_detect_init_system
case "$INIT_SYSTEM" in
    openrc) export SERVICE_FILE="/etc/init.d/sing-box" ;;
    systemd) export SERVICE_FILE="/etc/systemd/system/sing-box.service" ;;
    *) export SERVICE_FILE="" ;;
esac


server_ip=""
BATCH_MODE=false

MAINTENANCE_DIR="${PROXYALL_MAINTENANCE_DIR:-/var/lib/proxyall-maintenance}"
LOGROTATE_DIR="${PROXYALL_LOGROTATE_DIR:-/etc/logrotate.d}"
SYSTEMD_UNIT_DIR="${PROXYALL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
NGINX_LOG_DIR="${PROXYALL_NGINX_LOG_DIR:-/var/log/nginx}"
HAPROXY_LOG_FILE="${PROXYALL_HAPROXY_LOG_FILE:-/var/log/haproxy.log}"
ARGO_LOG_DIR="${PROXYALL_ARGO_LOG_DIR:-/tmp}"

_maintenance_safe_path() {
    local path="$1"
    [[ "$path" = /* && "$path" != *$'\n'* && "$path" != *'"'* && "$path" != *'\\'* ]] || return 1
    while [ "$path" != / ]; do
        [ ! -L "$path" ] || return 1
        path=$(dirname -- "$path")
    done
}

# 同一来源的备份保留最新一份；日期后缀用于配置文件，修改时间用于快照目录。
_retain_latest_backups() {
    local mode="$1" path key order existing failed=0
    shift
    local -A latest=() orders=()
    local -a paths=() keys=()
    for path in "$@"; do
        [ -e "$path" ] && _maintenance_safe_path "$path" || continue
        case "$mode" in
            dated)
                [[ "$path" =~ ^(.*)\.([0-9]{8}_[0-9]{6})(\.[0-9]+)?$ ]] || continue
                [ -f "$path" ] || continue
                key="${BASH_REMATCH[1]}"; order="${BASH_REMATCH[2]}${BASH_REMATCH[3]:-}" ;;
            dns)
                [[ "$path" =~ ^(.*\.bak_dns_)([0-9]{8}_[0-9]{6})$ ]] || continue
                [ -f "$path" ] || continue
                key="${BASH_REMATCH[1]}"; order="${BASH_REMATCH[2]}" ;;
            log)
                [[ "$path" =~ ^(.*\.log)(\.[0-9]+(\.gz)?|-[0-9]{8}(\.gz)?)$ ]] || continue
                [ -f "$path" ] || continue
                key="${BASH_REMATCH[1]}"; order=$(stat -c %Y -- "$path") || return 1 ;;
            bundle|core)
                [ -d "$path" ] || continue
                if [ "$mode" = core ]; then [ -f "$path/sing-box" ] && [ ! -L "$path/sing-box" ] || continue; fi
                key="$mode"; order=$(stat -c %Y -- "$path") || return 1 ;;
            certificate)
                [ -d "$path" ] && [ -f "$path/paths.txt" ] && [ ! -L "$path/paths.txt" ] || continue
                [ ! -e "$path/archived" ] || continue
                IFS= read -r key < "$path/paths.txt" || continue
                [[ "$key" == certificate=/* ]] || continue
                order=$(stat -c %Y -- "$path") || return 1 ;;
            *) return 1 ;;
        esac
        paths+=("$path"); keys+=("$key")
        existing="${latest[$key]:-}"
        if [ "$mode" = log ]; then
            if [ "$path" = "$key.1" ]; then latest[$key]="$path"; orders[$key]="$order"; continue; fi
            [ "$existing" != "$key.1" ] || continue
        fi
        if [ -z "$existing" ] || { [[ "$mode" = dated || "$mode" = dns ]] && [[ "$order" > "${orders[$key]}" ]]; } || \
           { [[ "$mode" != dated && "$mode" != dns ]] && [ "$order" -gt "${orders[$key]}" ]; } || \
           { [ "$order" = "${orders[$key]}" ] && [[ "$path" > "$existing" ]]; }; then
            latest[$key]="$path"; orders[$key]="$order"
        fi
    done
    local i
    for i in "${!paths[@]}"; do
        path="${paths[$i]}"; key="${keys[$i]}"
        [ "$path" = "${latest[$key]}" ] || rm -rf -- "$path" || failed=1
    done
    return "$failed"
}

_cleanup_config_backups() (
    _config_write_lock || exit 1
    local failed=0 state="${PROXYALL_STATE_DIR:-/var/lib/proxyall}"
    _retain_latest_backups dated "$NGINX_BACKUP_DIR/"* "$SNI_ROUTER_HAPROXY_BACKUP_DIR/"* || failed=1
    _retain_latest_backups dns "$CONFIG_FILE".bak_dns_* || failed=1
    _retain_latest_backups core "$SB_ROOT_HOME"/.singbox-update.* || failed=1
    _retain_latest_backups certificate "$state"/certificates/operation.* || failed=1
    # 脚本更新目录由统一入口的会话锁保护。
    if _maintenance_safe_path "$state" && [ -f "$state/.managed" ] && \
       grep -Fqx '# PROXYALL_MANAGED_COMMAND=1' "$state/.managed"; then
        exec 7>"$state/manager.lock" || exit 1
        if flock -n 7; then _retain_latest_backups bundle "$state"/backup.* || failed=1; fi
    fi
    exit "$failed"
)

_runtime_log_policy() {
    printf '# Managed by proxyall log maintenance\n'
    printf '"%s" ' "$@"
    cat <<'EOF'
{
    size 157286401
    rotate 1
    missingok
    notifempty
    copytruncate
    nocompress
    nodateext
EOF
    printf '    su %s %s\n' "$(id -un)" "$(id -gn)"
    printf '}\n'
}

_install_runtime_log_policy() {
    local name="$1" target="$LOGROTATE_DIR/$1" tmp
    shift
    _maintenance_safe_path "$target" || return 1
    tmp=$(mktemp "$LOGROTATE_DIR/.proxyall-logrotate.XXXXXX") || return 1
    _runtime_log_policy "$@" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    if [ -f "$target" ] && cmp -s -- "$tmp" "$target"; then rm -f -- "$tmp"; return 0; fi
    if [ -f "$target" ]; then
        cp -p -- "$target" "$MAINTENANCE_DIR/logrotate-$name.latest" || { rm -f -- "$tmp"; return 1; }
    fi
    chmod 600 "$tmp" && mv -f -- "$tmp" "$target"
}

_configure_runtime_log_rotation() {
    local path
    for path in "$MAINTENANCE_DIR" "$LOGROTATE_DIR" "$LOG_FILE" "$ARGO_LOG_FILE" "$XRAY_LOG_FILE" \
        "$SINGBOX_DIR" "$ARGO_LOG_DIR" "$NGINX_LOG_DIR" "$HAPROXY_LOG_FILE"; do
        _maintenance_safe_path "$path" || return 1
    done
    install -d -m 700 "$MAINTENANCE_DIR" || return 1
    mkdir -p -- "$LOGROTATE_DIR" || return 1
    _install_runtime_log_policy proxyall "$LOG_FILE" "$ARGO_LOG_FILE" "$SINGBOX_DIR/*.log" \
        "$ARGO_LOG_DIR/singbox_argo_*.log" || return 1
    if [ -d "$NGINX_LOG_DIR" ] || [ -f "$LOGROTATE_DIR/nginx" ]; then
        _install_runtime_log_policy nginx "$NGINX_LOG_DIR/*.log" || return 1
    fi
    if [ -f "$HAPROXY_LOG_FILE" ] || [ -f "$LOGROTATE_DIR/haproxy" ]; then
        _install_runtime_log_policy haproxy "$HAPROXY_LOG_FILE" || return 1
    fi
}

# 服务标准输出写入可轮转文件；服务下次启动时使用该设置。
_configure_runtime_log_output() {
    [ "$INIT_SYSTEM" = systemd ] || return 0
    local unit log dir tmp changed=false version
    version=$(systemctl --version | awk 'NR==1 {print $2}')
    [[ "$version" =~ ^[0-9]+$ ]] && [ "$version" -ge 240 ] || {
        _warning 'systemd 低于 240，服务标准输出继续由系统 journal 管理。'; return 0;
    }
    local units=(sing-box proxyall-xray)
    for unit in "${units[@]}"; do
        [ -f "$SYSTEMD_UNIT_DIR/$unit.service" ] || continue
        if [ "$unit" = sing-box ]; then log="$LOG_FILE"; else log="$XRAY_LOG_FILE"; fi
        dir="$SYSTEMD_UNIT_DIR/$unit.service.d"
        _maintenance_safe_path "$dir/90-proxyall-logging.conf" && _maintenance_safe_path "$log" || return 1
        if [ -f "$dir/90-proxyall-logging.conf" ] && ! grep -Fqx '# Managed by proxyall log maintenance' "$dir/90-proxyall-logging.conf"; then
            _error "日志配置文件已被其他配置占用：$dir/90-proxyall-logging.conf"; return 1
        fi
        install -d -m 755 "$dir" || return 1
        mkdir -p -- "$(dirname -- "$log")" || return 1
        touch -- "$log" && chmod 600 "$log" || return 1
        tmp=$(mktemp "$dir/.proxyall-logging.XXXXXX") || return 1
        printf '# Managed by proxyall log maintenance\n[Service]\nStandardOutput=append:%s\nStandardError=inherit\n' "$log" > "$tmp"
        if [ -f "$dir/90-proxyall-logging.conf" ] && cmp -s "$tmp" "$dir/90-proxyall-logging.conf"; then
            rm -f -- "$tmp"
        else
            chmod 644 "$tmp" && mv -f -- "$tmp" "$dir/90-proxyall-logging.conf" || return 1
            changed=true
        fi
    done
    [ "$changed" != true ] || systemctl daemon-reload
}

_cleanup_runtime_logs() (
    _maintenance_safe_path "$MAINTENANCE_DIR" || exit 1
    install -d -m 700 "$MAINTENANCE_DIR" || exit 1
    exec 6>"$MAINTENANCE_DIR/cleanup.lock" || exit 1
    flock -n 6 || exit 0
    local failed=0 name
    _configure_runtime_log_rotation || exit 1
    command -v logrotate >/dev/null 2>&1 || { _error '未找到 logrotate。'; exit 1; }
    # 使用系统 logrotate 状态文件，与系统自身的轮转任务共用状态锁。
    for name in proxyall nginx haproxy; do
        [ -f "$LOGROTATE_DIR/$name" ] || continue
        logrotate "$LOGROTATE_DIR/$name" || failed=1
    done
    _retain_latest_backups log "$LOG_FILE".* "$ARGO_LOG_FILE".* "$SINGBOX_DIR/"*.log.* \
        "$ARGO_LOG_DIR/"singbox_argo_*.log.* "$NGINX_LOG_DIR/"*.log.* "$NGINX_LOG_DIR/"*.log-* \
        "$HAPROXY_LOG_FILE".* "$HAPROXY_LOG_FILE"-* || failed=1
    _cleanup_config_backups || failed=1
    exit "$failed"
)

_setup_log_cleanup() {
    command -v logrotate >/dev/null 2>&1 || _pkg_install logrotate || return 1
    if ! command -v crontab >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then _pkg_install dcron || return 1
        elif command -v apt-get >/dev/null 2>&1; then _pkg_install cron || return 1
        else _pkg_install cronie || return 1; fi
    fi
    command -v crontab >/dev/null 2>&1 || {
        _warning "未找到 crontab，无法启用自动日志清理。"
        return 1
    }

    local tag="# sing-box-log-cleanup"
    _configure_runtime_log_rotation && _configure_runtime_log_output || return 1
    local job="*/15 * * * * bash ${SELF_SCRIPT_PATH} cleanup-logs >/dev/null 2>&1 ${tag}"
    local current
    current=$(crontab -l 2>/dev/null || true)
    if [ "$(printf '%s\n' "$current" | grep -Fc "$tag")" != 1 ] || ! printf '%s\n' "$current" | grep -Fqx "$job"; then
        { printf '%s\n' "$current" | grep -Fv "$tag"; printf '%s\n' "$job"; } | sed '/^$/d' | crontab - || return 1
    fi
    if [ "$INIT_SYSTEM" = systemd ]; then
        systemctl enable --now cron >/dev/null 2>&1 8>&- 9>&- || systemctl enable --now crond >/dev/null 2>&1 8>&- 9>&- || return 1
    elif [ "$INIT_SYSTEM" = openrc ]; then
        rc-service dcron start >/dev/null 2>&1 8>&- 9>&- || rc-service crond start >/dev/null 2>&1 8>&- 9>&- || return 1
        rc-update add dcron default >/dev/null 2>&1 || rc-update add crond default >/dev/null 2>&1 || return 1
    elif command -v crond >/dev/null 2>&1; then
        pgrep -x crond >/dev/null 2>&1 || crond 8>&- 9>&- || return 1
    elif command -v cron >/dev/null 2>&1; then
        pgrep -x cron >/dev/null 2>&1 || cron 8>&- 9>&- || return 1
    else
        _error '未找到 cron 服务，自动维护任务尚未运行。'
        return 1
    fi
}

_remove_restart_timer() {
    if [ "$INIT_SYSTEM" = systemd ] || [ -f "$SYSTEMD_UNIT_DIR/sing-box-restart.timer" ] || [ -f "$SYSTEMD_UNIT_DIR/sing-box-restart.service" ]; then
        if [ "$INIT_SYSTEM" = systemd ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl disable --now sing-box-restart.timer >/dev/null 2>&1 8>&- 9>&- || true
        fi
        rm -f "$SYSTEMD_UNIT_DIR/sing-box-restart.timer" "$SYSTEMD_UNIT_DIR/sing-box-restart.service"
    fi
    if [ "$INIT_SYSTEM" = openrc ] || [ -f /etc/init.d/sing-box-timer ] || [ -f /usr/local/bin/sb-timer.sh ]; then
        if command -v rc-service >/dev/null 2>&1; then
            rc-service sing-box-timer stop >/dev/null 2>&1 8>&- 9>&- || true
        fi
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del sing-box-timer default >/dev/null 2>&1 || true
        fi
        rm -f /etc/init.d/sing-box-timer /usr/local/bin/sb-timer.sh
    fi
}

_remove_log_cleanup() {
    local tag="# sing-box-log-cleanup" unit dropin logrotate_file
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$tag"; then
        crontab -l 2>/dev/null | grep -Fv "$tag" | crontab -
    fi
    logrotate_file="$LOGROTATE_DIR/proxyall"
    if [ -f "$logrotate_file" ] && [ ! -L "$logrotate_file" ] &&
       grep -Fqx '# Managed by proxyall log maintenance' "$logrotate_file" 2>/dev/null; then
        rm -f -- "$logrotate_file"
    fi
    for unit in sing-box proxyall-xray; do
        dropin="$SYSTEMD_UNIT_DIR/$unit.service.d/90-proxyall-logging.conf"
        if [ -f "$dropin" ] && [ ! -L "$dropin" ] &&
           grep -Fqx '# Managed by proxyall log maintenance' "$dropin" 2>/dev/null; then
            rm -f -- "$dropin"
            rmdir "$SYSTEMD_UNIT_DIR/$unit.service.d" 2>/dev/null || true
        fi
    done
}


# --- 进阶功能 (子脚本) ---
# 中转与链接解析组件随整套脚本安装在库目录。旧版按需下载到配置目录的副本在此删除，
# 指向旧副本的域名刷新任务改为通过 sb 调用；功能模块未就绪时保持原样，等待下一次更新。
_migrate_legacy_relay_component() {
    [ "$SB_MODULES_READY" = true ] || return 0
    local tag='# pf-dns-auto-refresh' current job
    if command -v crontab >/dev/null 2>&1; then
        current=$(crontab -l 2>/dev/null || true)
        if printf '%s\n' "$current" | grep -F "$tag" | grep -Fq 'advanced_relay.sh'; then
            job="* * * * * /bin/bash \"${SELF_SCRIPT_PATH}\" pf-dns-refresh >/dev/null 2>&1 ${tag}"
            { printf '%s\n' "$current" | grep -Fv "$tag"; printf '%s\n' "$job"; } | sed '/^$/d' | crontab - || return 1
        fi
    fi
    rm -f -- "$SINGBOX_DIR/advanced_relay.sh" "$SINGBOX_DIR/parser.sh"
}

# 中转模块（落地 Token、中转导入、端口转发、规则集分流）在子 shell 中加载并运行，
# 中转函数内的 exit 只结束本次中转操作，返回后主菜单状态不变。
_relay_command() {
    _sb_require_modules || return 1
    ( source "$SB_LIB_DIR/relay.sh" && "$@" )
}

_advanced_features() {
    _relay_command _relay_menu
}

_main_menu() {
    while true; do
        [ ! -t 0 ] || [ ! -t 1 ] || clear
        # ASCII Logo
        echo -e "${CYAN}"
        echo '  ____  _             ____            '
        echo ' / ___|(_)_ __   __ _| __ )  _____  __'
        echo ' \___ \| | '\''_ \ / _` |  _ \ / _ \ \/ /'
        echo '  ___) | | | | | (_| | |_) | (_) >  < '
        echo ' |____/|_|_| |_|\__, |____/ \___/_/\_\'
        echo '                |___/    Lite Manager '
        echo -e "${NC}"
        
        # 版本标题
        echo -e "${CYAN}"
        echo "  ╔═══════════════════════════════════════╗"
        echo "  ║         sing-box 管理脚本 v${SCRIPT_VERSION}         ║"
        echo "  ╚═══════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        
        # 获取系统信息
        local os_info="未知"
        if [ -f /etc/os-release ]; then
            os_info=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
            [ -z "$os_info" ] && os_info=$(grep -E "^NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
        fi
        [ -z "$os_info" ] && os_info=$(uname -s)
        
        # 获取 Sing-box 版本和状态
        local sb_version=""
        local service_status="○ 未知"
        if [ -f "$SINGBOX_BIN" ]; then
            sb_version=" v$($SINGBOX_BIN version 2>/dev/null | head -n1 | awk '{print $3}')"
            if [ "$INIT_SYSTEM" == "systemd" ]; then
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            elif [ "$INIT_SYSTEM" == "openrc" ]; then
                if rc-service sing-box status 2>/dev/null | grep -q "started"; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            elif [ "$INIT_SYSTEM" == "direct" ]; then
                if _is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"; then
                    service_status="${GREEN}● 运行中${NC}"
                else
                    service_status="${RED}○ 已停止${NC}"
                fi
            fi
        else
            service_status="${RED}○ 未安装${NC}"
        fi
        
        # 获取 Argo 状态 (修复 Alpine/BusyBox 的 ps 截断问题：优先使用 PID 文件检测)
        local argo_status="${RED}○ 未安装${NC}"
        if [ -f "$CLOUDFLARED_BIN" ]; then
            local argo_running=false
            # 方式1 (精准): 遍历 PID 文件，与守护进程 _argo_keepalive 使用相同的检测方式
            for pid_file in /tmp/singbox_argo_*.pid; do
                [ -f "$pid_file" ] || continue
                local pid=$(cat "$pid_file" 2>/dev/null)
                if _is_pid_running_cmd "$pid" "$CLOUDFLARED_BIN"; then
                    argo_running=true
                    break
                fi
            done
            # 方式2 (兜底): PID 文件不存在时，尝试 pgrep 或 ps 匹配进程名
            if [ "$argo_running" = false ]; then
                if command -v pgrep &>/dev/null; then
                    pgrep -x cloudflared &>/dev/null && argo_running=true
                elif ps w 2>/dev/null | grep -v "grep" | grep -q "cloudflared"; then
                    argo_running=true
                fi
            fi
            if [ "$argo_running" = true ]; then
                argo_status="${GREEN}● 运行中${NC}"
            else
                argo_status="${YELLOW}○ 已安装 (未运行)${NC}"
            fi
        fi
        
        # 获取 Xray 版本和状态（备用核心：仅用于 XHTTP 节点）
        local xray_version=""
        local xray_status="${RED}○ 未安装${NC}"
        if [ -x "$XRAY_BIN" ]; then
            xray_version=" v$($XRAY_BIN version 2>/dev/null | head -n1 | awk '{print $2}')"
            if _xray_running; then
                xray_status="${GREEN}● 运行中${NC}"
            else
                xray_status="${YELLOW}○ 已安装 (未运行)${NC}"
            fi
        fi

        echo -e "  系统: ${CYAN}${os_info}${NC}  |  模式: ${CYAN}${INIT_SYSTEM}${NC}"
        echo -e "  Sing-box${CYAN}${sb_version}${NC}: ${service_status}  |  Xray${CYAN}${xray_version}${NC}: ${xray_status}"
        echo -e "  Argo: ${argo_status}"
        if [ ! -f "$SINGBOX_BIN" ]; then
            echo -e "  ${YELLOW}首次使用：先选 [15] 安装 Sing-box 主核心，再选 [1] 添加节点（XHTTP 节点自动按需安装 Xray）。${NC}"
        fi
        echo ""
        
        # 节点管理
        echo -e "  ${CYAN}【节点管理】${NC}"
        echo -e "    ${GREEN}[1]${NC} 添加节点          ${GREEN}[2]${NC} Argo 隧道节点"
        echo -e "    ${GREEN}[3]${NC} 查看节点链接      ${GREEN}[4]${NC} 删除节点"
        echo -e "    ${GREEN}[5]${NC} 修改节点参数 / 端口"
        echo ""
        
        # 服务控制
        echo -e "  ${CYAN}【服务控制】${NC}"
        echo -e "    ${GREEN}[6]${NC} 重启服务          ${GREEN}[7]${NC} 停止服务"
        echo -e "    ${GREEN}[8]${NC} 查看运行状态      ${GREEN}[9]${NC} 查看实时日志"
        echo -e "    ${GREEN}[10]${NC} 定时重启设置     ${GREEN}[11]${NC} 同步系统时间"
        echo ""
        
        # 配置与更新
        echo -e "  ${CYAN}【配置与更新】${NC}"
        echo -e "    ${GREEN}[12]${NC} 检查配置文件     ${GREEN}[13]${NC} 更新脚本"
        echo -e "    ${GREEN}[14]${NC} DNS 设置"
        echo ""
        
        # 核心管理
        echo -e "  ${CYAN}【核心管理】${NC}"
        echo -e "    ${GREEN}[15]${NC} 安装/更新 Sing-box 主核心"
        echo -e "    ${GREEN}[18]${NC} 安装/更新 Xray 备用核心 (XHTTP)"
        echo -e "    ${RED}[16]${NC} 卸载核心及全部节点"
        echo ""
        
        # 进阶功能
        echo -e "  ${CYAN}【进阶功能】${NC}"
        echo -e "    ${GREEN}[17]${NC} 落地/中转/第三方节点导入"
        echo ""
        
        echo -e "  ─────────────────────────────────────────────────"
        if [ "${PROXYALL_MANAGED:-0}" = 1 ]; then
            echo -e "    ${YELLOW}[0]${NC} 返回 proxyall 主菜单"
        else
            echo -e "    ${YELLOW}[0]${NC} 退出脚本"
        fi
        echo ""
        
        read -r -p "  请输入选项 [0-18]: " choice || return 0
 
        case $choice in
            1) _show_add_node_menu; continue ;;
            2) _require_singbox && _argo_menu ;;
            3) _require_any_core && _view_nodes ;;
            4) _require_any_core && _delete_node ;;
            5) _require_any_core && _edit_node_menu ;;
            6) _require_any_core && _manage_service "restart" ;;
            7) _require_any_core && _manage_service "stop" ;;
            8) _require_any_core && _manage_service "status" ;;
            9) _require_any_core && _view_log ;;
            10) _require_singbox && _scheduled_restart_menu ;;
            11) _sync_system_time_interactive ;;
            12) _require_any_core && _check_config ;;
            13) _update_script ;;
            14) _require_singbox && _dns_config_menu ;;
            15) _install_or_update_singbox ;;
            16) _uninstall; [ -d "$SINGBOX_DIR" ] || return 0 ;;
            17) _require_singbox && _advanced_features ;;
            18)
                local xray_confirm=""
                read -r -p "更新 Xray 备用核心并按需重启服务？[y/N，0 返回]: " xray_confirm || return 0
                [[ "$xray_confirm" =~ ^[Yy]$ ]] && ( _config_write_lock && _install_xray true ) ;;
            0) exit 0 ;;
            *) _error "无效输入，请重试。" ;;
        esac
        echo
        read -r -p "按回车键返回主菜单..." _ || return 0
    done
}

    # 定时重启功能 - 零依赖版本 (Systemd Timer & OpenRC Logic)
    _scheduled_restart_menu() {
        [ ! -t 0 ] || [ ! -t 1 ] || clear
        echo -e "${CYAN}"
        echo '  ╔═══════════════════════════════════════╗'
        echo '  ║         定时重启 sing-box             ║'
        echo '  ╚═══════════════════════════════════════╝'
        echo -e "${NC}"
        echo ""
        
        # [!] 零依赖策略：不再安装 cron
        # 仅简单的环境预判
        if [ "$INIT_SYSTEM" == "direct" ]; then
            _error "未能识别系统初始化环境 (systemd/openrc)，定时重启功能暂不可用。"
            read -n 1 -s -r -p "按任意键返回..."
            return
        fi

    
    # 获取服务器时间信息
    local server_time=$(date '+%Y-%m-%d %H:%M:%S')
    local server_tz_offset=$(date +%z)  # 如: +0800, +0000, -0500
    local server_tz_name=$(date +%Z 2>/dev/null || echo "Unknown")  # 如: CST, UTC
    
    # 解析时区偏移 (格式: +0800 或 -0500)
    local offset_sign="${server_tz_offset:0:1}"
    local offset_hours="${server_tz_offset:1:2}"
    local offset_mins="${server_tz_offset:3:2}"
    
    # 去除前导零
    offset_hours=$((10#$offset_hours))
    offset_mins=$((10#$offset_mins))
    
    # 计算总偏移分钟数
    local server_offset_mins=$((offset_hours * 60 + offset_mins))
    if [ "$offset_sign" == "-" ]; then
        server_offset_mins=$((-server_offset_mins))
    fi
    
    # 北京时间 = UTC+8 = +480 分钟
    local beijing_offset_mins=480
    local diff_mins=$((beijing_offset_mins - server_offset_mins))
    local diff_hours=$((diff_mins / 60))
    local diff_remaining_mins=$((diff_mins % 60))
    
    # 格式化显示
    local diff_display=""
    if [ $diff_mins -gt 0 ]; then
        diff_display="北京时间比服务器快 ${diff_hours} 小时"
        if [ $diff_remaining_mins -ne 0 ]; then
            diff_display="${diff_display} ${diff_remaining_mins} 分钟"
        fi
    elif [ $diff_mins -lt 0 ]; then
        diff_display="北京时间比服务器慢 $((-diff_hours)) 小时"
        if [ $diff_remaining_mins -ne 0 ]; then
            diff_display="${diff_display} $((-diff_remaining_mins)) 分钟"
        fi
    else
        diff_display="服务器与北京时间同步"
    fi
    
    # 检查当前定时任务状态
    local cron_status="未设置"
    local cron_time=""
    
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        if [ -f "/etc/systemd/system/sing-box-restart.timer" ]; then
            cron_time=$(grep "OnCalendar" /etc/systemd/system/sing-box-restart.timer | cut -d' ' -f2 | cut -d: -f1,2)
            cron_status="已启用 (每天 ${cron_time} 重启 - Systemd)"
        fi
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        if [ -f "/etc/init.d/sing-box-timer" ] && rc-service sing-box-timer status &>/dev/null; then
            cron_time=$(grep "RESTART_TIME=" /etc/init.d/sing-box-timer | cut -d'"' -f2)
            cron_status="已启用 (每天 ${cron_time} 重启 - OpenRC)"
        fi
    fi
    
    echo -e "  ${CYAN}【服务器时间信息】${NC}"
    echo -e "    当前时间: ${GREEN}${server_time}${NC}"
    echo -e "    时区: ${GREEN}${server_tz_name} (UTC${server_tz_offset})${NC}"
    echo -e "    与北京时间: ${YELLOW}${diff_display}${NC}"
    echo ""
    echo -e "  ${CYAN}【定时重启状态】${NC}"
    if [ "$cron_status" != "未设置" ]; then
        echo -e "    状态: ${GREEN}${cron_status}${NC}"
    else
        echo -e "    状态: ${YELLOW}${cron_status}${NC}"
    fi
    echo ""
    echo -e "  ─────────────────────────────────────────"
    echo -e "    ${GREEN}[1]${NC} 设置定时重启"
    echo -e "    ${GREEN}[2]${NC} 查看当前设置"
    echo -e "    ${RED}[3]${NC} 取消定时重启"
    echo ""
    echo -e "    ${YELLOW}[0]${NC} 返回主菜单"
    echo ""
    
    read -p "  请输入选项 [0-3]: " choice
    
    case $choice in
        1)
            echo ""
            echo -e "  ${CYAN}设置定时重启时间${NC}"
            echo -e "  提示: 输入服务器时区的时间 (24小时制)"
            echo ""
            read -p "  请输入重启时间 (格式 HH:MM, 如 04:30): " restart_time
            
            # 验证时间格式
            if [[ ! "$restart_time" =~ ^([0-1]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
                _error "时间格式错误！请使用 HH:MM 格式 (如 04:30)"
                return
            fi
            
            local hour=$(echo "$restart_time" | cut -d: -f1)
            local min=$(echo "$restart_time" | cut -d: -f2)
            local time_str=$(printf "%02d:%02d" "$((10#$hour))" "$((10#$min))")

            if [ "$INIT_SYSTEM" == "systemd" ]; then
                # Systemd Timer 方案
                cat > /etc/systemd/system/sing-box-restart.service <<EOF
[Unit]
Description=Sing-box Scheduled Restart
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart sing-box
EOF
                cat > /etc/systemd/system/sing-box-restart.timer <<EOF
[Unit]
Description=Sing-box Scheduled Restart Timer
[Timer]
OnCalendar=*-*-* ${time_str}:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
                systemctl daemon-reload
                systemctl enable --now sing-box-restart.timer 8>&- 9>&-
            elif [ "$INIT_SYSTEM" == "openrc" ]; then
                # OpenRC 调度服务方案
                cat > /usr/local/bin/sb-timer.sh <<EOF
#!/bin/bash
TARGET_TIME="\$1"
while true; do
    [ "\$(date +%H:%M)" == "\$TARGET_TIME" ] && rc-service sing-box restart && sleep 61
    sleep 30
done
EOF
                chmod +x /usr/local/bin/sb-timer.sh
                cat > /etc/init.d/sing-box-timer <<EOF
#!/sbin/openrc-run
description="Sing-box Scheduled Restart Timer"
command="/usr/local/bin/sb-timer.sh"
command_args="${time_str}"
pidfile="/run/sing-box-timer.pid"
command_background=true
RESTART_TIME="${time_str}"
EOF
                chmod +x /etc/init.d/sing-box-timer
                rc-service sing-box-timer restart 2>/dev/null 8>&- 9>&-
                rc-update add sing-box-timer default 2>/dev/null
            fi
            
            _success "定时重启已通过 ${INIT_SYSTEM} 原生组件设置完成！"
            echo ""
            echo -e "  重启时间: ${GREEN}每天 ${time_str}${NC} (服务器时区)"
                
                # 计算对应的北京时间
                local beijing_hour=$((hour + diff_hours))
                local beijing_min=$((min + diff_remaining_mins))
                
                # 处理分钟溢出
                if [ $beijing_min -ge 60 ]; then
                    beijing_min=$((beijing_min - 60))
                    beijing_hour=$((beijing_hour + 1))
                elif [ $beijing_min -lt 0 ]; then
                    beijing_min=$((beijing_min + 60))
                    beijing_hour=$((beijing_hour - 1))
                fi
                
                # 处理小时溢出
                if [ $beijing_hour -ge 24 ]; then
                    beijing_hour=$((beijing_hour - 24))
                elif [ $beijing_hour -lt 0 ]; then
                    beijing_hour=$((beijing_hour + 24))
                fi
                
                echo -e "  对应北京时间: ${YELLOW}$(printf "%02d:%02d" "$beijing_hour" "$beijing_min")${NC}"
            ;;
        2)
            echo ""
            echo -e "  ${CYAN}当前定时任务详情:${NC}"
            if [ "$INIT_SYSTEM" == "systemd" ]; then
                systemctl list-timers sing-box-restart.timer --no-pager
            elif [ "$INIT_SYSTEM" == "openrc" ]; then
                rc-service sing-box-timer status
            fi
            ;;
        3)
            echo ""
            if [ "$cron_status" == "未设置" ]; then
                _warning "当前没有设置定时重启"
            else
                read -p "$(echo -e ${YELLOW}"  确定取消定时重启? (y/N): "${NC})" confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    _remove_restart_timer
                    if [ "$INIT_SYSTEM" == "systemd" ]; then
                        systemctl daemon-reload
                    fi
                    _success "定时重启已取消，相关系统组件已清理。"
                else
                    _info "已取消操作"
                fi
            fi
            ;;
        0)
            return
            ;;
        *)
            _error "无效输入"
            ;;
    esac
    
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
}

_show_add_node_menu() {
    [ -z "$server_ip" ] && _init_server_ip
    local choice NODE_UI=true NODE_PENDING_ORIGIN=''
    while true; do
        [ ! -t 0 ] || [ ! -t 1 ] || clear
        echo -e "${CYAN}"
        echo '  ╔═══════════════════════════════════════╗'
        echo '  ║        Sing-box / Xray 添加节点       ║'
        echo '  ╚═══════════════════════════════════════╝'
        echo -e "${NC}"
        echo ""

        echo -e "  ${CYAN}【Sing-box 主核心协议】${NC}"
        echo -e "    ${GREEN}[1]${NC}  VLESS (Vision + Reality)  ${YELLOW}[推荐主力]${NC}"
        echo -e "    ${GREEN}[5]${NC}  AnyTLS / Any-Reality"
        echo -e "    ${GREEN}[2]${NC}  VLESS (WebSocket + TLS)"
        echo -e "    ${GREEN}[3]${NC}  Trojan (WebSocket + TLS)"
        echo -e "    ${GREEN}[4]${NC}  VLESS (gRPC + TLS)"
        echo -e "    ${GREEN}[6]${NC}  Hysteria2"
        echo -e "    ${GREEN}[7]${NC}  TUICv5"
        echo -e "    ${GREEN}[8]${NC}  Shadowsocks"
        echo -e "    ${GREEN}[9]${NC}  VLESS (裸 TCP，无 TLS)"
        echo -e "    ${GREEN}[10]${NC} SOCKS5"
        echo -e "    ${GREEN}[14]${NC} NaiveProxy (HTTP/2 / QUIC)"
        echo ""

        echo -e "  ${CYAN}【Xray 备用核心协议 (XHTTP)】${NC}"
        echo -e "    ${GREEN}[12]${NC} VLESS (XHTTP + TLS / H2)  ${YELLOW}[Xray]${NC}"
        echo -e "    ${GREEN}[13]${NC} VLESS (XHTTP + Reality)   ${YELLOW}[Xray]${NC}"
        echo ""

        echo -e "  ${CYAN}【快捷功能】${NC}"
        echo -e "    ${GREEN}[11]${NC} 批量创建节点 (Sing-box)"
        echo ""

        echo -e "  ─────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC}  返回主菜单"
        echo ""

        read -r -p "  请输入选项 [0-14]: " choice || return 0

        local op_status=0
        # 如果输入包含逗号或空格，自动进入批量处理模式
        if [[ "$choice" == *","* ]] || [[ "$choice" == *" "* ]]; then
            _require_singbox && _batch_create_nodes "$choice" || op_status=$?
            if [ "$op_status" -eq 0 ]; then
                _pause_for_enter "批量创建完成，按回车键返回主菜单..."
            elif [ "$op_status" -eq 1 ]; then
                _pause_for_enter "按回车键返回主菜单..."
            fi
            return "$op_status"
        fi

        if [[ "$choice" =~ ^([1-9]|10|12|13|14)$ ]]; then
            _info '填写节点参数时输入 0 可取消并返回协议选择；回车保留提示中的默认值。'
        fi

        case "$choice" in
            0) return 0 ;;
            1) _require_singbox && _add_vless_reality || op_status=$? ;;
            2) _require_singbox && _add_vless_ws_tls || op_status=$? ;;
            3) _require_singbox && _add_trojan_ws_tls || op_status=$? ;;
            4) _require_singbox && _add_vless_grpc_tls || op_status=$? ;;
            5) _require_singbox && _add_anytls || op_status=$? ;;
            6) _require_singbox && _add_hysteria2 || op_status=$? ;;
            7) _require_singbox && _add_tuic || op_status=$? ;;
            8) _require_singbox && _add_shadowsocks_menu || op_status=$? ;;
            9) _require_singbox && _add_vless_tcp || op_status=$? ;;
            10) _require_singbox && _add_socks || op_status=$? ;;
            11)
                _require_singbox && _batch_create_nodes || op_status=$?
                if [ "$op_status" -eq 0 ]; then
                    _pause_for_enter "批量创建完成，按回车键返回主菜单..."
                elif [ "$op_status" -eq 1 ]; then
                    _pause_for_enter "按回车键返回主菜单..."
                fi
                return "$op_status" ;;
            12) _add_vless_xhttp_tls || op_status=$? ;;
            13) _add_vless_xhttp_reality || op_status=$? ;;
            14) _require_singbox && _add_naive || op_status=$? ;;
            *) _error "无效输入，请重试。"; continue ;;
        esac
        if [ "$op_status" -eq 0 ]; then
            _pause_for_enter "节点创建完成，按回车键返回..."
        elif [ "$op_status" -eq 1 ]; then
            _pause_for_enter "按回车键返回..."
        fi
    done
}

# --- 脚本入口 ---

main() {
    _check_root
    _sb_require_modules || return 1
    _detect_init_system
    _config_write_lock || return 1
    
    # 强制预创建目录，防止后续 cp/mv 因路径不存在报错 (保底机制)
    mkdir -p "${SINGBOX_DIR}" 2>/dev/null
    _secure_sensitive_files
    
    # 1. 首次安装或依赖状态失效时才完整检查，避免每次 sb 进入菜单都触发包管理器
    _install_dependencies
    
    # 2. 根据核心安装状态决定初始化路径
    if [ -f "${SINGBOX_BIN}" ]; then
        # --- sing-box 已安装：执行完整的初始化与自愈检测 ---
        
        # 3. 检查配置文件
        if [ ! -f "${CONFIG_FILE}" ] || [ ! -f "${CLASH_YAML_FILE}" ]; then
             _info "检测到主配置文件缺失，正在初始化..."
             _initialize_config_files
        fi

        # 3.1 初始化中转配置 (配置隔离)
        _init_relay_config
        
        # 打开管理菜单不删除旧中转、不改 DNS 或默认出口、不重启业务。
        # 节点操作及核心更新在候选副本中迁移 DNS，并校验主配置与中转配置。
        
        # [BUG FIX] 检查并修复旧版服务文件
        if [ -f "$SERVICE_FILE" ]; then
            local need_update=false
            if grep -q "\-C " "$SERVICE_FILE"; then
                _warn "检测到旧版服务目录加载模式，需要迁移..."
                need_update=true
            fi
            if [ "$INIT_SYSTEM" == "openrc" ] && ! grep -q "supervisor=" "$SERVICE_FILE"; then
                _warn "检测到旧版 OpenRC 服务配置，需要迁移以兼容 Alpine..."
                need_update=true
            fi
            if grep -q "ENABLE_DEPRECATED_" "$SERVICE_FILE"; then
                _warn "检测到 sing-box 旧版 DNS 兼容环境变量，需要在配置迁移后移除..."
                need_update=true
            fi
            if [ "$need_update" = true ]; then
                _warn "保留现有服务文件；请通过【核心管理】安装/更新，在配置校验成功后统一迁移服务。"
            fi
        fi

        # [PATH FIX] 确保 relay.json 存在
        if [ ! -s "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}" ]; then
            echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "${NODE_RELAY_FILE:-${SINGBOX_DIR}/relay.json}"
        fi

        # 4. 首次安装或服务文件缺失时才创建，避免每次进入菜单都重写服务文件
        if [ -n "$SERVICE_FILE" ] && [ ! -f "$SERVICE_FILE" ]; then
            _create_service_files
        elif [ "$INIT_SYSTEM" == "direct" ] && [ ! -f "$LOG_FILE" ]; then
            touch "$LOG_FILE"
        fi
        _setup_log_cleanup
        _sanitize_argo_metadata || true
        _secure_sensitive_files
    else
        # --- sing-box 未安装：仅显示提示，不自动安装 ---
        _warn "sing-box 核心未安装。请通过主菜单【核心管理】进行安装。"
    fi
    
    exec 8>&-
    unset PROXYALL_WRITE_LOCK_HELD
    _main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # 解析命令行参数；直接执行 sb 时进入 Sing-box / Xray 交互主菜单。
    while [[ $# -gt 0 ]]; do
        case "$1" in
            sync-time)
                _check_root
                _sb_require_modules || exit 1
                _sync_system_time true
                exit $?
                ;;
            sni-router)
                _check_root
                _sb_require_modules || exit 1
                shift
                _sni_router_cli "$@"
                exit $?
                ;;
            keepalive)
                _sb_require_modules || exit 1
                _argo_keepalive
                exit 0
                ;;
            pf-dns-refresh)
                _check_root
                _relay_command _pf_dns_refresh
                exit $?
                ;;
            cleanup-logs)
                _cleanup_runtime_logs
                exit $?
                ;;
            setup-maintenance)
                _check_root
                _config_write_lock || exit 1
                _setup_log_cleanup || exit 1
                _migrate_legacy_relay_component
                exit $?
                ;;
            cleanup-backups)
                _check_root
                _cleanup_config_backups
                exit $?
                ;;
            install-realitlscanner)
                _check_root
                _sb_require_modules || exit 1
                mkdir -p "$SINGBOX_DIR"
                _install_realitlscanner
                exit $?
                ;;
            install-reality-origin)
                _check_root
                _sb_require_modules || exit 1
                local_origin_domain="${2:-}"
                [ -n "$local_origin_domain" ] || { _error "缺少自有域名参数。"; exit 1; }
                _config_write_lock || exit 1
                mkdir -p "$SINGBOX_DIR"
                command -v jq >/dev/null || _pkg_install jq || exit 1
                _prepare_local_reality_origin "$local_origin_domain"
                exit $?
                ;;
            *)
                _error "未知命令：$1"; exit 2
                ;;
        esac
    done

    main
fi
