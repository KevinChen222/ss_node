#!/usr/bin/env bash
# PROXYALL_LIB=sb_origin.sh
# 本机 Nginx HTTPS 源站与 acme.sh 证书：Reality 自有域名回落、XHTTP/AnyTLS 证书复用与自签证书。由 sb 加载。

_sb_nginx_running() {
    [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null
}

_sb_reload_or_start_nginx() {
    nginx -t || return 1
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl is-active nginx >/dev/null 2>&1; then
            systemctl reload nginx 8>&- 9>&-
        else
            systemctl enable --now nginx 8>&- 9>&-
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service nginx status >/dev/null 2>&1; then rc-service nginx reload 8>&- 9>&-; else rc-service nginx start 8>&- 9>&-; fi
    elif _sb_nginx_running; then
        nginx -s reload 8>&- 9>&-
    else
        nginx 8>&- 9>&-
    fi
}

_sb_backup_nginx_file() {
    local target="$1" stamp staged saved
    [ -f "$target" ] || return 0
    mkdir -p "$NGINX_BACKUP_DIR" || return 1
    chmod 700 "$NGINX_BACKUP_DIR" 2>/dev/null || true
    stamp=$(date +%Y%m%d_%H%M%S)
    saved="${NGINX_BACKUP_DIR}/$(basename "$target").${stamp}.$$"
    staged=$(mktemp "$NGINX_BACKUP_DIR/.backup.XXXXXXXX") || return 1
    if ! cp -a -- "$target" "$staged" || ! mv -f -- "$staged" "$saved"; then
        rm -f -- "$staged"; return 1
    fi
    _retain_latest_backups dated "${NGINX_BACKUP_DIR}/$(basename "$target")."*
}

_ensure_nginx_conf_d_include() {
    [ -f "$NGINX_MAIN_CONF" ] || { _error "未找到 ${NGINX_MAIN_CONF}。"; return 1; }
    grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' "$NGINX_MAIN_CONF" && return 0

    local tmp rollback
    tmp=$(mktemp) || return 1
    rollback=$(mktemp) || { rm -f "$tmp"; return 1; }
    cp -a -- "$NGINX_MAIN_CONF" "$rollback" || { rm -f "$tmp" "$rollback"; return 1; }
    awk '
        BEGIN {in_http=0; depth=0; inserted=0}
        {
            line=$0; opens=gsub(/\{/, "{", line); closes=gsub(/\}/, "}", line)
            if (!in_http && $0 ~ /^[[:space:]]*http[[:space:]]*\{/) {in_http=1; depth=opens-closes; print; next}
            if (in_http) {
                if (depth==1 && $0 ~ /^[[:space:]]*}[[:space:]]*$/ && !inserted) {print "    include /etc/nginx/conf.d/*.conf;"; inserted=1}
                depth += opens-closes; if (depth==0) in_http=0
            }
            print
        }
        END {if (!inserted) exit 12}
    ' "$NGINX_MAIN_CONF" > "$tmp" || {
        rm -f "$tmp" "$rollback"
        _error "无法安全地向 nginx.conf 添加 conf.d include。"
        return 1
    }
    _sb_backup_nginx_file "$NGINX_MAIN_CONF" || { rm -f "$tmp" "$rollback"; return 1; }
    if ! cp -- "$tmp" "$NGINX_MAIN_CONF"; then
        cp -a -- "$rollback" "$NGINX_MAIN_CONF" 2>/dev/null || true
        rm -f "$tmp" "$rollback"
        return 1
    fi
    rm -f "$tmp"
    if ! nginx -t >/dev/null 2>&1; then
        cp -a -- "$rollback" "$NGINX_MAIN_CONF"
        rm -f "$rollback"
        _error "添加 conf.d include 后 Nginx 测试失败，已回滚。"
        return 1
    fi
    rm -f "$rollback"
    _success "已向 nginx.conf 添加 ${NGINX_CONF_DIR}/*.conf。"
}

_install_managed_nginx_config() {
    local source="$1" target="$2" marker="$3" rollback="" existed=false
    if [ -e "$target" ]; then
        if ! grep -Fqx "$marker" "$target" 2>/dev/null; then
            _error "Nginx 配置已存在且不属于本脚本，拒绝覆盖: ${target}"
            return 1
        fi
        existed=true
        rollback=$(mktemp) || return 1
        cp -a -- "$target" "$rollback" || { rm -f "$rollback"; return 1; }
        _sb_backup_nginx_file "$target" || { rm -f "$rollback"; return 1; }
    fi
    if ! install -m 644 "$source" "$target"; then
        if [ "$existed" = true ]; then cp -a -- "$rollback" "$target"; else rm -f -- "$target"; fi
        [ -n "$rollback" ] && rm -f "$rollback"
        return 1
    fi
    if ! _sb_reload_or_start_nginx; then
        if [ "$existed" = true ]; then cp -a -- "$rollback" "$target"; else rm -f -- "$target"; fi
        rm -f "$rollback"
        _sb_reload_or_start_nginx >/dev/null 2>&1 || true
        _error "Nginx 配置加载失败，已回滚: ${target}"
        return 1
    fi
    if [ -n "$rollback" ]; then
        rm -f "$rollback"
    fi
    return 0
}

_setup_official_nginx_stable_apt_repo() {
    local ID='' VERSION_CODENAME='' arch key_file keyring_tmp fingerprints path
    local keyring=/usr/share/keyrings/proxyall-nginx.gpg
    local source_file=/etc/apt/sources.list.d/proxyall-nginx.list
    local pin_file=/etc/apt/preferences.d/99proxyall-nginx
    [ -r /etc/os-release ] || { _error '无法识别系统版本，不能配置 Nginx 官方仓库。'; return 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID:${VERSION_CODENAME:-}" in
        debian:bullseye|debian:bookworm|debian:trixie|ubuntu:jammy|ubuntu:noble|ubuntu:resolute) ;;
        *) _error "Nginx 官方仓库尚未适配此系统: $ID ${VERSION_CODENAME:-未知}"; return 1 ;;
    esac
    arch=$(dpkg --print-architecture) || return 1
    case $arch in
        amd64|arm64) ;;
        *) _error "Nginx 官方仓库尚未适配此架构: $arch"; return 1 ;;
    esac
    for path in "$source_file" "$pin_file"; do
        if [ -e "$path" ] && ! grep -Fqx '# Managed by proxyall: nginx stable' "$path"; then
            _error "APT 配置已存在且不属于本脚本: $path"
            return 1
        fi
    done

    key_file=$(mktemp) || return 1
    keyring_tmp=$(mktemp) || { rm -f -- "$key_file"; return 1; }
    if ! curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 30 \
        https://nginx.org/keys/nginx_signing.key -o "$key_file"; then
        rm -f -- "$key_file" "$keyring_tmp"
        _error '下载 Nginx 官方仓库签名密钥失败。'
        return 1
    fi
    fingerprints=$(gpg --show-keys --with-colons "$key_file" 2>/dev/null | \
        awk -F: '$1=="fpr" {print toupper($10)}') || true
    if ! grep -Fxq '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62' <<<"$fingerprints" || \
       ! gpg --batch --yes --dearmor --output "$keyring_tmp" "$key_file"; then
        rm -f -- "$key_file" "$keyring_tmp"
        _error 'Nginx 官方仓库签名密钥指纹不匹配或无法导入。'
        return 1
    fi
    install -m 644 "$keyring_tmp" "$keyring" || { rm -f -- "$key_file" "$keyring_tmp"; return 1; }
    rm -f -- "$key_file" "$keyring_tmp"
    printf '%s\n' '# Managed by proxyall: nginx stable' \
        "deb [signed-by=$keyring] https://nginx.org/packages/$ID $VERSION_CODENAME nginx" > "$source_file" || return 1
    printf '%s\n' '# Managed by proxyall: nginx stable' 'Package: nginx' \
        'Pin: origin nginx.org' 'Pin-Priority: 900' > "$pin_file" || return 1
    chmod 644 "$source_file" "$pin_file" || return 1
    _info "已配置 Nginx 官方 stable 仓库: $ID $VERSION_CODENAME"
}

_ensure_local_origin_dependencies() {
    local nginx_was_missing=0 nginx_version nginx_candidate=''
    local -a nginx_package=()
    _info "正在安装/检查 Nginx 与证书依赖..."
    if ! command -v nginx >/dev/null 2>&1; then
        nginx_was_missing=1
        nginx_package=(nginx)
        _warn "首次安装 Nginx 时包管理器可能数分钟没有输出，请勿重复运行或中断脚本。"
        _info "正在调用系统包管理器安装 Nginx、cron 与 socat..."
    fi
    if [ "$nginx_was_missing" = 0 ] && command -v crontab >/dev/null && command -v socat >/dev/null; then
        : # Emby 与节点共用已安装的 Nginx 和 HTTP-01 工具。
    elif command -v apk >/dev/null 2>&1; then
        SB_PKG_VERBOSE=1 _pkg_install "${nginx_package[@]}" dcron socat || { _error "包管理器安装 Nginx 依赖失败。"; return 1; }
    elif command -v apt-get >/dev/null 2>&1; then
        if [ "$nginx_was_missing" = 1 ]; then
            SB_PKG_VERBOSE=1 _pkg_install curl ca-certificates gnupg || return 1
            _setup_official_nginx_stable_apt_repo || return 1
            apt-get update || return 1
            nginx_candidate=$(LC_ALL=C apt-cache policy nginx | awk '/Candidate:/ {print $2; exit}')
            if ! _version_at_least "${nginx_candidate%%-*}" '1.30.0'; then
                _error "APT 未选中高版本 Nginx，候选版本: ${nginx_candidate:-无}"
                return 1
            fi
            _info "将从官方 stable 仓库安装 Nginx: $nginx_candidate"
        fi
        SB_PKG_VERBOSE=1 _pkg_install "${nginx_package[@]}" cron socat || { _error "包管理器安装 Nginx 依赖失败。"; return 1; }
    else
        SB_PKG_VERBOSE=1 _pkg_install "${nginx_package[@]}" cronie socat || { _error "包管理器安装 Nginx 依赖失败。"; return 1; }
    fi
    command -v nginx >/dev/null 2>&1 || { _error "Nginx 安装失败。"; return 1; }
    nginx_version=$(nginx -v 2>&1 | sed 's#^nginx version: ##')
    if [ "$nginx_was_missing" = 1 ]; then
        _success "Nginx 已安装并通过命令检查：${nginx_version:-版本未知}。"
    else
        _success "检测到已有 Nginx，继续复用：${nginx_version:-版本未知}。"
    fi
    command -v socat >/dev/null 2>&1 || { _error "socat 安装失败。"; return 1; }
    install -d -m 755 "$NGINX_CONF_DIR" "$NGINX_CERT_DIR" "$ACME_WEBROOT/.well-known/acme-challenge" || return 1
    install -d -m 700 "$NGINX_BACKUP_DIR" || return 1
    _ensure_nginx_conf_d_include
}

_validate_local_origin_dns() {
    local domain="$1" public_v4 public_v6 resolved_a resolved_aaaa ip local_v6=""
    resolved_a=$(getent ahostsv4 "$domain" 2>/dev/null | awk '$2 == "STREAM" {print $1}' | sort -u)
    resolved_aaaa=$(getent ahostsv6 "$domain" 2>/dev/null | awk '$2 == "STREAM" && $1 ~ /:/ && $1 !~ /^::ffff:/ {print tolower($1)}' | sort -u)
    [ -n "$resolved_a$resolved_aaaa" ] || { _error "公共 DNS 尚未解析出 ${domain} 的 A/AAAA 记录。"; return 1; }

    public_v4=$(timeout 8 curl -fsS4 --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '\r\n ' || true)
    public_v6=$(timeout 8 curl -fsS6 --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '\r\n ' | tr '[:upper:]' '[:lower:]' || true)
    if [ -n "$resolved_a" ]; then
        _is_valid_ipv4 "$public_v4" || { _error "无法获取本机公网 IPv4，不能核对域名 A 记录。"; return 1; }
        while read -r ip; do
            [ -z "$ip" ] && continue
            _is_cloudflare_ipv4 "$ip" && { _error "${domain} 的 A 记录 ${ip} 属于 Cloudflare；请改为 DNS only。"; return 1; }
            [ "$ip" = "$public_v4" ] || { _error "${domain} 的 A 记录 ${ip} 未指向本机公网 IPv4 ${public_v4}。"; return 1; }
        done <<< "$resolved_a"
    fi
    if [ -n "$resolved_aaaa" ]; then
        if command -v ip >/dev/null 2>&1; then
            local_v6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print tolower($4)}' | sort -u)
        fi
        while read -r ip; do
            [ -z "$ip" ] && continue
            if ! printf '%s\n%s\n' "$local_v6" "$public_v6" | grep -Fxiq "$ip"; then
                _error "${domain} 的 AAAA 记录 ${ip} 未指向本机；请修正或删除该 AAAA 记录。"
                return 1
            fi
        done <<< "$resolved_aaaa"
    fi
    _success "域名 DNS 已确认直连本机（DNS only）。"
}

_install_sb_acme() {
    local current_version archive extract_dir source_dir
    if [ -x "$SB_ACME_SH" ]; then
        current_version=$("$SB_ACME_SH" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1 || true)
        if _version_at_least "$current_version" "$SB_ACME_VERSION"; then
            "$SB_ACME_SH" --set-default-ca --server letsencrypt >/dev/null
            return 0
        fi
        _warn "现有 acme.sh ${current_version:-未知} 过旧，将升级到 ${SB_ACME_VERSION}。"
    fi

    archive=$(mktemp) || return 1
    extract_dir=$(mktemp -d /tmp/sb-acme-install.XXXXXX) || { rm -f "$archive"; return 1; }
    _info "正在安装 acme.sh ${SB_ACME_VERSION}..."
    if ! curl -fsSL --connect-timeout 10 --max-time 120 "$SB_ACME_ARCHIVE_URL" -o "$archive" || \
       ! printf '%s  %s\n' "$SB_ACME_ARCHIVE_SHA256" "$archive" | sha256sum -c - >/dev/null 2>&1 || \
       ! tar -xzf "$archive" -C "$extract_dir"; then
        rm -f "$archive"; rm -rf -- "$extract_dir"
        _error "acme.sh 下载、校验或解压失败。"
        return 1
    fi
    source_dir="${extract_dir}/acme.sh-${SB_ACME_VERSION}"
    if [ ! -f "$source_dir/acme.sh" ] || ! (cd "$source_dir" && sh ./acme.sh --install --home "$SB_ACME_HOME" --nocron); then
        rm -f "$archive"; rm -rf -- "$extract_dir"
        _error "acme.sh 安装失败。"
        return 1
    fi
    rm -f "$archive"; rm -rf -- "$extract_dir"
    [ -x "$SB_ACME_SH" ] || return 1
    "$SB_ACME_SH" --set-default-ca --server letsencrypt >/dev/null
    touch "${SINGBOX_DIR}/.managed_acme"
}

_ensure_acme_renewal() {
    local cron_file="/etc/cron.d/singbox-reality-acme" marker="# Managed by singbox-lite Reality ACME"
    if ! { command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$SB_ACME_SH"; } && \
       ! grep -RqsF "$SB_ACME_SH" /etc/cron.d 2>/dev/null; then
        if [ -e "$cron_file" ] && ! grep -Fqx "$marker" "$cron_file" 2>/dev/null; then
            _error "续期任务文件已存在且不属于本脚本: ${cron_file}"
            return 1
        fi
        local tmp
        tmp=$(mktemp) || return 1
        {
            echo "$marker"
            printf '23 3 * * * root "%s" --cron --home "%s" >/dev/null 2>&1\n' "$SB_ACME_SH" "$SB_ACME_HOME"
        } > "$tmp"
        install -m 644 "$tmp" "$cron_file" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable --now cron >/dev/null 2>&1 8>&- 9>&- || systemctl enable --now crond >/dev/null 2>&1 8>&- 9>&- || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service dcron start >/dev/null 2>&1 8>&- 9>&- || rc-service crond start >/dev/null 2>&1 8>&- 9>&- || true
        rc-update add dcron default >/dev/null 2>&1 || rc-update add crond default >/dev/null 2>&1 || true
    fi
}

_acme_ecc_cert_is_usable() {
    local domain="$1" info cert_path
    [ -x "$SB_ACME_SH" ] || return 1
    info=$("$SB_ACME_SH" --info -d "$domain" --ecc 2>/dev/null || true)
    cert_path=$(printf '%s\n' "$info" | sed -n 's/^Le_RealFullChainPath=//p' | head -n 1)
    cert_path=${cert_path#\'}
    cert_path=${cert_path%\'}
    [ -n "$cert_path" ] && [ -s "$cert_path" ] && openssl x509 -in "$cert_path" -checkend 604800 -noout >/dev/null 2>&1
}

_acme_record_uses_webroot() {
    local domain="$1" info webroot
    info=$("$SB_ACME_SH" --info -d "$domain" --ecc 2>/dev/null || true)
    webroot=$(printf '%s\n' "$info" | sed -n 's/^Le_Webroot=//p' | head -n 1)
    webroot=${webroot#\'}
    webroot=${webroot%\'}
    [ "$webroot" = "$ACME_WEBROOT" ]
}

_issue_local_origin_certificate() {
    local domain="$1"
    local cert_dir="${NGINX_CERT_DIR}/${domain}"
    local -a force_args=()
    if ! _acme_ecc_cert_is_usable "$domain" || ! _acme_record_uses_webroot "$domain"; then
        if "$SB_ACME_SH" --info -d "$domain" --ecc >/dev/null 2>&1; then
            force_args+=(--force)
            _warn "现有证书续期方式不是本机 HTTP-01 webroot，将迁移为无 Token 的自动续期。"
        fi
        _info "正在通过 HTTP-01 webroot 申请 Let's Encrypt 证书: ${domain}"
        "$SB_ACME_SH" --issue --server letsencrypt --webroot "$ACME_WEBROOT" \
            -d "$domain" --keylength ec-256 "${force_args[@]}" 8>&- 9>&- || return 1
    else
        _info "检测到仍有效的现有 ECC 证书，将直接复用。"
    fi
    install -d -m 700 "$cert_dir" || return 1
    "$SB_ACME_SH" --install-cert -d "$domain" --ecc \
        --fullchain-file "$cert_dir/cert" \
        --key-file "$cert_dir/key" \
        --reloadcmd "$SB_ACME_RELOAD_CMD" 8>&- 9>&- || return 1
    [ -s "$cert_dir/cert" ] && [ -s "$cert_dir/key" ] || return 1
    chmod 600 "$cert_dir/cert" "$cert_dir/key" 2>/dev/null || true
}

_prepare_local_reality_origin() {
    local domain="${1,,}" safe_domain challenge_conf origin_conf site_root tmp marker
    _is_valid_reality_domain "$domain" || { _error "自有域名格式无效: ${domain}"; return 1; }
    safe_domain="${domain//[^a-z0-9.-]/_}"
    challenge_conf="${NGINX_CONF_DIR}/00-sb-reality-acme-${safe_domain}.conf"
    origin_conf="${NGINX_CONF_DIR}/${safe_domain}.${REALITY_LOCAL_ORIGIN_PORT}.reality.conf"
    site_root="/var/www/singbox-reality/${safe_domain}"

    _validate_local_origin_dns "$domain" || return 1
    _ensure_local_origin_dependencies || return 1
    local target
    for target in "$challenge_conf" "$origin_conf" "$NGINX_CERT_DIR/$domain/cert" "$NGINX_CERT_DIR/$domain/key"; do
        _xhttp_snapshot_nginx "$target" || return 1
    done

    marker="# Generated by singbox-lite Reality local origin"
    tmp=$(mktemp) || return 1
    {
        echo "$marker"
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
    _install_managed_nginx_config "$tmp" "$challenge_conf" "$marker" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    if ! _local_certificate_usable "$domain"; then
        _install_sb_acme || return 1
        _ensure_acme_renewal || return 1
        _issue_local_origin_certificate "$domain" || return 1
    elif [ -x "$SB_ACME_SH" ]; then
        _ensure_acme_renewal || return 1
    fi

    install -d -m 755 "$site_root" || return 1
    if [ ! -f "$site_root/index.html" ]; then
        tmp=$(mktemp) || return 1
        printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>Welcome</h1></body></html>' > "$tmp"
        install -m 644 "$tmp" "$site_root/index.html" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi

    local origin_listen_http2=' http2' origin_http2_directive='' nginx_version
    nginx_version=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p')
    if [ -n "$nginx_version" ] && _version_at_least "$nginx_version" '1.25.1'; then
        origin_listen_http2=''
        origin_http2_directive='    http2 on;'
    fi
    tmp=$(mktemp) || return 1
    cat > "$tmp" <<EOF_REALITY_ORIGIN
$marker
server {
    listen ${REALITY_LOCAL_ORIGIN_HOST}:${REALITY_LOCAL_ORIGIN_PORT} ssl${origin_listen_http2};
${origin_http2_directive}
    server_name ${domain};

    ssl_certificate ${NGINX_CERT_DIR}/${domain}/cert;
    ssl_certificate_key ${NGINX_CERT_DIR}/${domain}/key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SBRealitySSL:10m;
    ssl_session_timeout 1h;
    server_tokens off;

    root ${site_root};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF_REALITY_ORIGIN
    _install_managed_nginx_config "$tmp" "$origin_conf" "$marker" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    local probe_ok=false probe_attempt
    for probe_attempt in 1 2 3 4 5; do
        if _probe_reality_target "$REALITY_LOCAL_ORIGIN_HOST" "$domain" "$REALITY_LOCAL_ORIGIN_PORT"; then
            probe_ok=true
            break
        fi
        if [ "$probe_attempt" -lt 5 ]; then
            [ "$probe_attempt" -eq 1 ] && _info "Nginx 正在切换到新的 HTTPS 配置，稍候重试本机源站探测..."
            sleep 1
        fi
    done
    if [ "$probe_ok" != true ]; then
        _error "本机 HTTPS 源站复核失败: ${REALITY_PROBE_ERROR}"
        return 1
    fi
    _success "自有证书、本机 Nginx HTTPS 源站与自动续期已配置完成。"
    _info "Reality SNI: ${domain} | 握手目标: ${REALITY_LOCAL_ORIGIN_HOST}:${REALITY_LOCAL_ORIGIN_PORT}"
}

_generate_self_signed_cert() {
    _node_tx_begin || return 1
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"
    local cert_existed=false key_existed=false
    [ ! -e "$cert_path" ] || cert_existed=true
    [ ! -e "$key_path" ] || key_existed=true

    _info "正在为 ${domain} 生成支持 SAN 的高级自签名证书..."
    
    # 创建临时配置文件用于生成 SAN
    local openssl_config=$(mktemp)
    cat > "$openssl_config" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${domain}
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
EOF

    # 使用 RSA 2048 生成证书 (CF 回源兼容性更佳)
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$key_path" -out "$cert_path" \
        -config "$openssl_config" >/dev/null 2>&1
    
    local status=$?
    rm -f "$openssl_config"

    if [ $status -ne 0 ]; then
        _error "为 ${domain} 生成证书失败！"
        [ "$cert_existed" = true ] || rm -f "$cert_path"
        [ "$key_existed" = true ] || rm -f "$key_path"
        return 1
    fi
    chmod 600 "$cert_path" "$key_path" 2>/dev/null || true
    if [ -n "${NODE_TX_DIR:-}" ]; then
        [ "$cert_existed" = true ] || printf '%s\n' "$cert_path" >> "$NODE_TX_DIR/created-files"
        [ "$key_existed" = true ] || printf '%s\n' "$key_path" >> "$NODE_TX_DIR/created-files"
    fi
    _success "证书 ${cert_path} (含 SAN) 已成功生成。"
    return 0
}

_local_certificate_usable() {
    local domain="$1"
    [ -s "$NGINX_CERT_DIR/$domain/cert" ] && [ -s "$NGINX_CERT_DIR/$domain/key" ] &&
       openssl x509 -in "$NGINX_CERT_DIR/$domain/cert" -checkend 604800 -noout >/dev/null 2>&1 &&
       _cert_matches_hostname "$NGINX_CERT_DIR/$domain/cert" "$domain" &&
       [ "$(openssl x509 -in "$NGINX_CERT_DIR/$domain/cert" -pubkey -noout)" = "$(openssl pkey -in "$NGINX_CERT_DIR/$domain/key" -passin pass: -pubout 2>/dev/null)" ]
}
