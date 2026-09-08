#!/usr/bin/env bash
# MH_MANAGER_MANAGED_COMMAND=1
# Mihomo server-side node manager used by proxyall.
MH_VERSION=2.0.0
set -Eeuo pipefail
umask 077

BIN=/usr/local/bin/mihomo
ROOT=/usr/local/etc/mihomo
CFG=$ROOT/config.yaml
CLIENTS=$ROOT/clients.yaml
META=$ROOT/nodes.json
MH_TMP=$ROOT/.tmp
SNI=/usr/local/bin/sb
SERVICE=mihomo
API=https://api.github.com/repos/MetaCubeX/mihomo/releases/latest
MARKER='# MH_MANAGER_STATE=1'
STATE_MARKER=$ROOT/.managed
MH_LOCKED=0

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
root_only() { [ "$(id -u)" = 0 ] || fail "请以 root 运行。"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "缺少依赖：$1"; }
fetch() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fLsS \
    --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 "$@"
}
atomic_install() {
  local source=$1 target=$2 mode=$3 stage
  stage=$(mktemp "$(dirname -- "$target")/.mh-install.XXXXXXXX") || return 1
  if ! install -m "$mode" -- "$source" "$stage" || ! mv -f -- "$stage" "$target"; then
    rm -f -- "$stage"
    return 1
  fi
}
domain_ok() {
  local domain=${1%.} label
  local -a labels
  [ "$domain" = "$1" ] || return 1
  [ -n "$domain" ] && [ "${#domain}" -le 253 ] && [[ "$domain" == *.* ]] || return 1
  [[ ! "$domain" =~ ^[0-9.]+$ ]] || return 1
  IFS='.' read -r -a labels <<<"$domain"
  for label in "${labels[@]}"; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] &&
      [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  return 0
}
rand_port() { shuf -i 20000-50000 -n 1; }
rand_text() {
  local chars=$1 bytes value
  bytes=$(( (chars + 1) / 2 ))
  value=$(od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n')
  printf '%s' "${value:0:chars}"
}
rand_path() { printf '/%s' "$(rand_text 16)"; }
uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else local value; value=$(rand_text 32); printf '%s-%s-4%s-a%s-%s\n' "${value:0:8}" "${value:8:4}" "${value:13:3}" "${value:17:3}" "${value:20:12}"; fi
}
uri_host() {
  if [[ "$1" == *:* ]] && [[ "$1" != \[*\] ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}
normalize_host() {
  if [[ "$1" =~ ^\[([^]]+)\]$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf '%s' "$1"; fi
}
url_encode() { printf '%s' "$1" | jq -sRr @uri; }
port_ok() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
host_ok() { [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "$1" != -* ]]; }
default_bind() {
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 0 ]; then printf '::'
  else printf '0.0.0.0'; fi
}
public_ip() {
  local address
  address=$(curl -4 -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null) ||
    address=$(curl -6 -fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null) || return 0
  host_ok "$address" && printf '%s' "$address"
}
ask_host() {
  local default=${1:-} answer
  [ -n "$default" ] || default=$(public_ip)
  while :; do
    read -r -p "服务器连接地址/IP [${default:-必填}]: " answer || exit 0
    HOST=$(normalize_host "${answer:-$default}")
    host_ok "$HOST" && break
    say "请输入域名或 IP，不要包含协议、端口或路径。"
  done
}
ask_port() {
  local proto=$1 default=${2:-random} answer attempts
  while :; do
    read -r -p "监听端口 [${default/random/随机空闲端口}]: " answer || exit 0
    if [ -z "$answer" ] && [ "$default" = random ]; then
      for ((attempts=0; attempts<100; attempts++)); do
        answer=$(rand_port)
        if ! port_used "$proto" "$answer"; then break; fi
      done
    else answer=${answer:-$default}; fi
    if port_ok "$answer"; then PORT=$((10#$answer)); return 0; fi
    say "端口范围为 1–65535。"
  done
}

init() {
  [ ! -L "$ROOT" ] || fail "$ROOT 是符号链接，拒绝写入。"
  local managed_path
  for managed_path in "$CFG" "$CLIENTS" "$META" "$MH_TMP" "$STATE_MARKER"; do
    [ ! -L "$managed_path" ] || fail "$managed_path 是符号链接，拒绝写入。"
  done
  if [ -f "$STATE_MARKER" ] && ! grep -Fqx "$MARKER" "$STATE_MARKER"; then
    fail "$STATE_MARKER 内容无效，拒绝接管。"
  fi
  if [ -f "$STATE_MARKER" ]; then
    for managed_path in "$CFG" "$CLIENTS" "$META"; do
      [ -f "$managed_path" ] || fail "已管理状态缺少 $managed_path，拒绝自动重建。"
    done
  fi
  if [ -e "$ROOT" ] && [ ! -f "$STATE_MARKER" ]; then
    if [ -f "$CFG" ] && [ -f "$CLIENTS" ] && [ -f "$META" ] &&
       command -v jq >/dev/null 2>&1 &&
       jq -e '(.nodes|type)=="array" and (.relays|type)=="array"' "$META" >/dev/null 2>&1; then
      say "检测到旧版 mh 状态，正在加入所有权标记。"
    elif [ -n "$(find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
      fail "$ROOT 已存在但不属于 mh 管理器，拒绝接管或覆盖。"
    fi
  fi
  install -d -m 700 "$ROOT" "$MH_TMP"
  lock_state
  [ -f "$CFG" ] || cat >"$CFG" <<'EOF'
mixed-port: 0
mode: rule
log-level: info
allow-lan: false
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
listeners: []
EOF
  [ -f "$CLIENTS" ] || printf 'proxies: []\n' >"$CLIENTS"
  [ -f "$META" ] || printf '{"nodes":[],"relays":[]}\n' >"$META"
  chmod 600 "$CFG" "$CLIENTS" "$META"
  jq -e '(.nodes|type)=="array" and (.relays|type)=="array"' "$META" >/dev/null || fail "$META 格式无效。"
  yq eval -e '(.listeners | type) == "!!seq"' "$CFG" >/dev/null || fail "$CFG 缺少有效 listeners 数组。"
  yq eval -e '(.proxies | type) == "!!seq"' "$CLIENTS" >/dev/null || fail "$CLIENTS 缺少有效 proxies 数组。"
  printf '%s\n' "$MARKER" >"$STATE_MARKER"
}
lock_state() {
  [ "$MH_LOCKED" = 1 ] && return 0
  exec 9>"$ROOT/manager.lock"
  flock -n 9 || fail "已有另一个 mh 管理会话正在运行。"
  MH_LOCKED=1
}
yq_is_v4() {
  local version_text
  version_text=$(yq --version 2>/dev/null) || return 1
  [[ "${version_text,,}" == *mikefarah* ]] && [[ "$version_text" =~ version[[:space:]]+v?4\. ]]
}
check_yq() { need yq; yq_is_v4 || fail "需要 mikefarah/yq v4。"; }
check_runtime_deps() {
  local command_name
  for command_name in curl jq yq gzip sha256sum install mktemp shuf base64 od ss flock tee openssl; do
    need "$command_name"
  done
  check_yq
}
install_base_deps() {
  local command_name missing=0
  for command_name in curl jq gzip sha256sum install mktemp shuf base64 od ss flock tee openssl; do
    command -v "$command_name" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" = 0 ] && return 0
  say "正在安装 Mihomo 管理依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates jq gzip coreutils util-linux iproute2 openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates jq gzip coreutils util-linux iproute openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates jq gzip coreutils util-linux iproute openssl
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates jq gzip coreutils util-linux iproute2 openssl
  else
    fail "无法识别包管理器，请先安装 curl、jq、gzip、coreutils、util-linux、iproute2。"
  fi
}
yq_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf amd64 ;;
    aarch64|arm64) printf arm64 ;;
    armv7l|armv7) printf arm ;;
    *) fail "yq 不支持当前架构：$(uname -m)" ;;
  esac
}
install_yq() {
  if command -v yq >/dev/null 2>&1 && yq_is_v4; then return 0; fi
  local version asset tmp checksum_line actual
  version=$(fetch https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r '.tag_name')
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "无法取得 yq 版本。"
  asset="yq_linux_$(yq_arch)"
  tmp=$(mktemp -d)
  fetch -o "$tmp/yq" "https://github.com/mikefarah/yq/releases/download/$version/$asset"
  fetch -o "$tmp/checksums" "https://github.com/mikefarah/yq/releases/download/$version/checksums"
  checksum_line=$(awk -v name="$asset" '$1 == name {print; exit}' "$tmp/checksums")
  [ -n "$checksum_line" ] || { rm -rf "$tmp"; fail "无法取得 yq 校验值。"; }
  actual=$(sha256sum "$tmp/yq" | awk '{print $1}')
  printf '%s\n' "$checksum_line" | grep -Eiq "(^|[[:space:]])$actual([[:space:]]|$)" ||
    { rm -rf "$tmp"; fail "yq SHA-256 校验失败。"; }
  atomic_install "$tmp/yq" /usr/local/bin/yq 755 || { rm -rf "$tmp"; fail "安装 yq 失败。"; }
  rm -rf "$tmp"
}
check_ready() {
  root_only
  check_runtime_deps
  init
  lock_state
  [ -x "$BIN" ] || fail "请先安装 mihomo 核心。"
}
check_port() {
  local proto=$1 port=$2
  port_ok "$port" || fail "端口无效。"
  if port_used "$proto" "$port"; then fail "$proto 端口已占用：$port"; fi
  return 0
}
port_used() {
  local proto=$1 port=$2
  config_port_used "$proto" "$port" && return 0
  [ "$proto" != both ] || { port_used tcp "$port" || port_used udp "$port"; return $?; }
  local flags=-lnt
  [ "$proto" != udp ] || flags=-lnu
  ss "$flags" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"
}
config_port_used() {
  local proto=$1 port=$2
  if [ "$proto" != tcp ] && jq -e --argjson port "$port" '.nodes[]|select(.udp_hop!=null)|select($port>=.udp_hop.start and $port<=.udp_hop.end)' "$META" >/dev/null; then return 0; fi
  yq -o=json '.' "$CFG" | jq -e --arg proto "$proto" --argjson port "$port" '
    .listeners[]? | select(.port == $port) |
    select($proto == "both" or
      (if (.type == "hysteria2" or .type == "tuic") then $proto == "udp"
       elif .type == "tunnel" then ((.network//[])|index($proto)) != null
       elif (.type == "shadowsocks" or .type == "socks") then ($proto == "tcp" or .udp == true)
       else $proto == "tcp" end))' >/dev/null
}
reload_service() {
  prepare_runtime_env || return 1
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE" >/dev/null || return 1
    if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
      systemctl restart "$SERVICE" || return 1
    else
      systemctl start "$SERVICE" || return 1
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add "$SERVICE" default >/dev/null 2>&1 || return 1
    if rc-service "$SERVICE" status >/dev/null 2>&1; then
      rc-service "$SERVICE" restart 9>&- || return 1
    else
      rc-service "$SERVICE" start 9>&- || return 1
    fi
  else
    say "错误：仅支持 systemd 或 OpenRC。" >&2
    return 1
  fi
  wait_listeners
}
certificate_safe_paths() {
  local config=$1 file resolved paths="$ROOT"
  while IFS= read -r file; do
    [[ "$file" = /* ]] || continue
    [[ "$file" != *:* && ! "$file" =~ [[:cntrl:]] ]] || return 1
    resolved=$(readlink -f -- "$file") || return 1
    paths+=":$file"
    [ "$resolved" = "$file" ] || paths+=":$resolved"
  done < <(yq -o=json '.' "$config" | jq -r '..|objects|(.certificate?, ."private-key"?, ."client-auth-cert"?)|select(type=="string")')
  printf '%s' "$paths"
}
prepare_runtime_env() {
  local paths envfile="$ROOT/runtime.env" raw="$ROOT/safe-paths" file
  [ ! -L "$envfile" ] && [ ! -L "$raw" ] || return 1
  paths=$(certificate_safe_paths "$CFG") || return 1
  printf '%s' "$paths" >"$raw" || return 1
  printf 'SAFE_PATHS=%s\n' "$(jq -Rn --arg value "$paths" '$value')" >"$envfile" || return 1
  chmod 600 "$envfile" "$raw" || return 1
  if [ -d /run/systemd/system ]; then
    file=/etc/systemd/system/mihomo.service.d/20-mh-paths.conf
    [ ! -L /etc/systemd/system/mihomo.service.d ] && [ ! -L "$file" ] || return 1
    [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_PATHS=1' "$file" || return 1
    install -d -m 755 /etc/systemd/system/mihomo.service.d || return 1
    printf '# MH_MANAGER_PATHS=1\n[Service]\nEnvironmentFile=%s\n' "$envfile" >"$file" || return 1
    chmod 644 "$file" || return 1
  elif [ -f /etc/init.d/mihomo ]; then
    if ! grep -Fq 'safe-paths' /etc/init.d/mihomo; then
      # 只为可识别的旧版 mh 服务补上授权，不改动其他 OpenRC 服务。
      grep -Fqx "command=\"$BIN\"" /etc/init.d/mihomo || return 1
      [ ! -L /etc/init.d/mihomo ] || return 1
      printf '\nexport SAFE_PATHS="$(cat %s/safe-paths)"\n' "$ROOT" >>/etc/init.d/mihomo || return 1
    fi
  fi
}
wait_listeners() {
  local attempt proto port sockets missing
  for ((attempt=0; attempt<20; attempt++)); do
    missing=0
    while IFS=$'\t' read -r proto port; do
      [ -n "$port" ] || continue
      if [ "$proto" = udp ]; then sockets=$(ss -H -lnup) || return 1
      else sockets=$(ss -H -lntp) || return 1; fi
      if ! printf '%s\n' "$sockets" | awk -v port="$port" '$4 ~ ("[:.]" port "$") && /"mihomo"/ {found=1} END {exit !found}'; then missing=1; break; fi
    done < <(yq -o=json '.' "$CFG" | jq -r '.listeners[]? |
      (if .type=="hysteria2" or .type=="tuic" then ["udp"]
       elif (.type=="shadowsocks" or .type=="socks") and .udp==true then ["tcp","udp"]
       elif .type=="tunnel" then .network else ["tcp"] end)[] as $proto | [$proto,.port]|@tsv')
    [ "$missing" = 1 ] || return 0
    sleep 0.25
  done
  say "错误：Mihomo 未建立预期的 $proto 监听端口 $port，请检查服务日志。" >&2
  return 1
}
validate_state() {
  local config=$1 clients=$2 meta=$3
  "$BIN" -t -d "$ROOT" -f "$config" || return 1
  "$BIN" -t -d "$ROOT" -f "$clients" || return 1
  yq eval -e '(.listeners | type) == "!!seq"' "$config" >/dev/null || return 1
  yq eval -e '(.proxies | type) == "!!seq"' "$clients" >/dev/null || return 1
  jq -e '(.nodes|type)=="array" and (.relays|type)=="array" and
    ([.nodes[].name]|length)==([.nodes[].name]|unique|length) and
    ([.relays[].listener]|length)==([.relays[].listener]|unique|length)' "$meta" >/dev/null || return 1
  { yq -o=json '.' "$config" || return 1; yq -o=json '.' "$clients" || return 1; cat "$meta"; } |
    jq -se '.[0] as $s | .[1] as $c | .[2] as $m |
      all($m.nodes[]; . as $n |
        [$s.listeners[]|select(.name==$n.name)] as $in |
        [$c.proxies[]|select(.name==$n.name)] as $out |
        ($in|length)==1 and ($out|length)==1 and
        $in[0].port==($n.backend_port//$n.public_port) and $out[0].port==$n.public_port) and
      all($m.relays[]; . as $r |
        ([$s.proxies[]|select(.name==$r.proxy)]|length)==1 and
        ([$s.listeners[]|select(.name==$r.listener and .proxy==$r.proxy)]|length)==1) and
      all(($m.forwards//[])[]; . as $f |
        ([$s.listeners[]|select(.name==$f.name and .type=="tunnel" and .port==$f.port and .target==$f.target)]|length)==1)' >/dev/null
}
apply_state() {
  local newcfg=$1 newclients=$2 newmeta=$3 backup rollback_ok=1 restart=${4:-yes}
  if [ "$restart" = no ] && ! cmp -s "$newcfg" "$CFG"; then return 1; fi
  if ! validate_state "$newcfg" "$newclients" "$newmeta"; then
    say "错误：候选服务端或客户端 Mihomo 配置未通过校验。" >&2
    return 1
  fi
  if ! yq eval -e '(.proxies | type) == "!!seq"' "$newclients" >/dev/null ||
     ! jq -e '(.nodes|type)=="array" and (.relays|type)=="array"' "$newmeta" >/dev/null; then
    say "错误：候选客户端配置或元数据无效。" >&2
    return 1
  fi
  backup=$(mktemp -d "$MH_TMP/state-backup.XXXXXX") || return 1
  if ! cp "$CFG" "$backup/config.yaml" ||
     ! cp "$CLIENTS" "$backup/clients.yaml" ||
     ! cp "$META" "$backup/nodes.json"; then
    rm -rf "$backup"
    say "错误：无法创建状态备份，未写入新配置。" >&2
    return 1
  fi
  if ! atomic_install "$newcfg" "$CFG" 600 ||
     ! atomic_install "$newclients" "$CLIENTS" 600 ||
     ! atomic_install "$newmeta" "$META" 600 ||
     ! { [ "$restart" = no ] || apply_udp_hops "$META"; } ||
     ! { [ "$restart" = no ] || reload_service; }; then
    atomic_install "$backup/config.yaml" "$CFG" 600 || rollback_ok=0
    atomic_install "$backup/clients.yaml" "$CLIENTS" 600 || rollback_ok=0
    atomic_install "$backup/nodes.json" "$META" 600 || rollback_ok=0
    if [ "$rollback_ok" = 1 ] && [ "$restart" != no ] && ! apply_udp_hops "$META"; then rollback_ok=0; fi
    if [ "$rollback_ok" = 1 ] && [ "$restart" != no ] && ! reload_service; then rollback_ok=0; fi
    if [ "$rollback_ok" = 1 ]; then
      rm -rf "$backup"
      say "错误：状态提交失败，已恢复上一版本。" >&2
    else
      say "错误：状态提交和自动恢复均失败；备份保留在 $backup。" >&2
    fi
    return 1
  fi
  rm -rf "$backup"
  return 0
}
sni() {
  [ -x "$SNI" ] || fail "未找到 SNI 路由组件 $SNI；请先安装 proxyall/sb.sh。"
  "$SNI" sni-router "$@" 9>&-
}
new_name() {
  CERT=; KEY=; CERT_MANAGED=false; CERT_DOMAINS_JSON='[]'
  EXTRA_SNI=; SNI_NAME=; ROUTE=none; SKIP_CERT=false; CDN=false; ARGO_SERVICE=; ARGO_KIND=; UDP_HOP=null
  IFS= read -r -p "节点名称（留空自动生成，0 返回）: " NAME || exit 0
  [ "$NAME" != 0 ] || exit 0
  [ -n "$NAME" ] || NAME="mh-$(rand_text 6)"
  [[ ! "$NAME" =~ [[:cntrl:]] ]] || fail "名称不能包含控制字符。"
  if jq -e --arg n "$NAME" '.nodes[] | select(.name==$n)' "$META" >/dev/null; then fail "节点名称已存在。"; fi
  if MH_YQ_NAME="$NAME" yq eval -e '(.listeners[]?, .proxies[]?) | select(.name == strenv(MH_YQ_NAME))' "$CFG" >/dev/null 2>&1; then
    fail "Mihomo 配置中已存在同名入口或出站。"
  fi
  while :; do
    NODE_ID=$(rand_text 16)
    ROUTE_TAG="mh:$NODE_ID"
    if ! jq -e --arg t "$ROUTE_TAG" '.nodes[] | select((.route_tag // "") == $t)' "$META" >/dev/null; then break; fi
  done
  LINK_NAME=$(url_encode "$NAME")
  return 0
}
tcp_endpoint() {
  local asked preferred attempts shared selected_sni=${1:-}
  ask_port tcp 443
  asked=$PORT
  BIND=$(default_bind); PORT=$asked; ROUTE=none; SNI_NAME=; EXTRA_SNI=
  if [ "$asked" = 443 ]; then
    read -r -p "启用 SNI 分流，与 Emby/sing-box 共用 TCP 443？[Y/n]: " shared || exit 0
    if [[ "$shared" = n || "$shared" = N ]]; then check_port tcp "$PORT"; return 0; fi
    [ "$(sni api-version)" = 1 ] || fail "当前 sb 的 SNI 路由 API 不兼容，请先用 proxyall 更新整套脚本。"
    sni prepare
    if [ -n "$selected_sni" ]; then SNI_NAME=$selected_sni
    else read -r -p "分流域名/SNI（与 Emby、其他节点使用不同的完整域名）: " SNI_NAME; fi
    SNI_NAME=${SNI_NAME,,}
    domain_ok "$SNI_NAME" || fail "域名无效。"
    sni check-sni-free "$SNI_NAME" || fail "该完整域名不能用于新的共享 443 入站。"
    preferred=2543
    for ((attempts=0; attempts<100; attempts++)); do
      PORT=$(sni allocate-backend "$preferred") || fail "无法分配 SNI 回环后端端口。"
      if ! config_port_used tcp "$PORT"; then
        break
      fi
      preferred=$((PORT + 1))
      PORT=
    done
    [ -n "$PORT" ] || fail "无法为 Mihomo 分配空闲的 SNI 回环后端端口。"
    BIND=127.0.0.1; ROUTE=tls
  else
    check_port tcp "$PORT"
  fi
}
reality_endpoint() {
  tcp_endpoint
  if [ "$ROUTE" = none ]; then
    read -r -p "Reality SNI（客户端连接域名）: " SNI_NAME
    SNI_NAME=${SNI_NAME,,}
    domain_ok "$SNI_NAME" || fail "域名无效。"
  else
    ROUTE=reality
  fi
}
get_cert() {
  local choice output_file domain automatic=1
  [ "$#" -ge 1 ] || fail "未提供证书域名。"
  for domain in "$@"; do domain_ok "$domain" || automatic=0; done
  if [ "$automatic" = 1 ]; then
    say "证书方式："
    say "  [1] 自动申请/续期 Let's Encrypt（默认）"
    say "  [2] 使用已有证书"
    say "  [3] 自签证书（仅直连；客户端将跳过证书校验）"
    read -r -p "请选择 [1-3]: " choice
    [ -n "$choice" ] || choice=1
  else
    say "IP 地址可使用已有证书或直连自签证书。"
    read -r -p "证书方式 [2 已有证书 / 3 自签，默认 3]: " choice
    choice=${choice:-3}
  fi
  case "$choice" in
    1)
      [ -x "$SNI" ] || fail "未找到证书管理组件 $SNI；请先安装或更新 proxyall。"
      output_file=$(mktemp "$MH_TMP/cert-output.XXXXXX") || fail "无法创建证书操作临时文件。"
      if ! "$SNI" issue-mihomo-certificate "$@" 9>&- | tee "$output_file" | sed '/^MH_CERT_PATH=/d; /^MH_KEY_PATH=/d'; then
        rm -f "$output_file"
        fail "证书申请失败；请确认域名解析正确、TCP 80 可访问，且 CDN 未拦截 ACME challenge。"
      fi
      CERT=$(sed -n 's/^MH_CERT_PATH=//p' "$output_file" | tail -n 1)
      KEY=$(sed -n 's/^MH_KEY_PATH=//p' "$output_file" | tail -n 1)
      rm -f "$output_file"
      [ -r "$CERT" ] && [ -r "$KEY" ] || fail "证书已签发，但返回的证书路径无效。"
      CERT_MANAGED=true
      CERT_DOMAINS_JSON=$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')
      say "证书已就绪，并已配置自动续期：$CERT"
      ;;
    2)
      read -r -p "证书路径（须覆盖全部节点域名）: " CERT
      read -r -p "私钥路径: " KEY
      [ -r "$CERT" ] && [ -r "$KEY" ] || fail "证书或私钥不可读。"
      CERT_MANAGED=false
      CERT_DOMAINS_JSON=$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')
      ;;
    3)
      [ "${CDN:-false}" != true ] || fail "CDN 回源请使用有效的公网证书或已有 Origin 证书。"
      install -d -m 700 "$ROOT/certs"
      CERT="$ROOT/certs/$NODE_ID.crt"; KEY="$ROOT/certs/$NODE_ID.key"
      local san= entry
      for domain in "$@"; do
        if domain_ok "$domain"; then entry="DNS:$domain"; else entry="IP:$domain"; fi
        san+="${san:+,}$entry"
      done
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
        -keyout "$KEY" -out "$CERT" -subj /CN=mihomo -addext "subjectAltName=$san" >/dev/null 2>&1
      SKIP_CERT=true
      CERT_DOMAINS_JSON=$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')
      ;;
    *) fail "证书方式无效。" ;;
  esac
  # 先验证证书、私钥及名称，避免核心 -t 忽略监听器字段后误报成功。
  [[ "$CERT" = /* ]] || CERT="$PWD/$CERT"
  [[ "$KEY" = /* ]] || KEY="$PWD/$KEY"
  [[ ! "$CERT$KEY" =~ [[:cntrl:]] && "$CERT$KEY" != *:* ]] || fail "证书路径不能包含控制字符或冒号。"
  openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null || fail "证书已过期或格式无效。"
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$CERT" -pubkey -noout)
  key_pub=$(openssl pkey -in "$KEY" -passin pass: -pubout 2>/dev/null) || fail "私钥无效或带有密码。"
  [ "$cert_pub" = "$key_pub" ] || fail "证书与私钥不匹配。"
  for domain in "$@"; do
    if domain_ok "$domain"; then
      openssl x509 -in "$CERT" -noout -checkhost "$domain" | grep -q 'does match' || fail "证书未覆盖 $domain。"
    else
      openssl x509 -in "$CERT" -noout -checkip "$domain" | grep -q 'does match' || fail "证书未覆盖 $domain。"
    fi
  done
}
direct_domain() {
  HOST=$SNI_NAME
  if [ -z "$HOST" ]; then
    ask_host
  fi
  HOST=$(normalize_host "$HOST")
  host_ok "$HOST" || fail "服务器地址格式无效。"
}
begin_files() {
  LC=$(mktemp "$MH_TMP/listener.XXXXXX")
  CC=$(mktemp "$MH_TMP/client.XXXXXX")
  NC=$(mktemp "$MH_TMP/config.XXXXXX")
  CL=$(mktemp "$MH_TMP/clients.XXXXXX")
  NM=$(mktemp "$MH_TMP/meta.XXXXXX")
}
register_routes() {
  [ "$ROUTE" = none ] && return 0
  if [ "$ROUTE" = reality ]; then
    sni register-reality mh "$ROUTE_TAG" "$SNI_NAME" "$PORT" || return 1
  else
    sni register-tls mh "$ROUTE_TAG" "$SNI_NAME" "$PORT" || return 1
  fi
  if [ -n "$EXTRA_SNI" ]; then
    if ! sni register-tls mh "$ROUTE_TAG:down" "$EXTRA_SNI" "$PORT"; then
      if [ "$ROUTE" = reality ]; then
        sni remove-reality "$ROUTE_TAG" || return 2
      else
        sni remove-tls "$ROUTE_TAG" || return 2
      fi
      return 1
    fi
  fi
}
unregister_routes() {
  local kind=$1 tag=$2 extra=$3 backend_port=$4 removed_extra=0
  [ "$kind" = none ] && return 0
  if [ -n "$extra" ]; then
    sni remove-tls "$tag:down" || return 1
    removed_extra=1
  fi
  if [ "$kind" = reality ]; then
    if ! sni remove-reality "$tag"; then
      if [ "$removed_extra" = 1 ] && ! sni register-tls mh "$tag:down" "$extra" "$backend_port"; then return 2; fi
      return 1
    fi
  elif ! sni remove-tls "$tag"; then
    if [ "$removed_extra" = 1 ] && ! sni register-tls mh "$tag:down" "$extra" "$backend_port"; then return 2; fi
    return 1
  fi
  return 0
}
commit_node() {
  local protocol=$1 link=$2 public=$3 route_status oldcfg oldclients oldmeta
  MH_YQ_NAME="$NAME" yq eval -i '.listeners[0].name = strenv(MH_YQ_NAME)' "$LC"
  MH_YQ_NAME="$NAME" yq eval -i '.proxies[0].name = strenv(MH_YQ_NAME)' "$CC"
  yq eval-all 'select(fileIndex == 0) *+ {"listeners": (select(fileIndex == 1).listeners)}' "$CFG" "$LC" >"$NC"
  yq eval-all 'select(fileIndex == 0) *+ {"proxies": (select(fileIndex == 1).proxies)}' "$CLIENTS" "$CC" >"$CL"
  jq --arg n "$NAME" --arg p "$protocol" --arg l "$link" --arg r "$ROUTE" --arg s "$SNI_NAME" --arg t "$ROUTE_TAG" --arg e "$EXTRA_SNI" \
    --arg c "${CERT:-}" --arg k "${KEY:-}" --argjson cm "${CERT_MANAGED:-false}" --argjson cd "${CERT_DOMAINS_JSON:-[]}" \
    --arg argo "${ARGO_SERVICE:-}" --arg kind "${ARGO_KIND:-}" \
    --argjson hop "${UDP_HOP:-null}" \
    --argjson x "$public" --argjson b "$PORT" \
    '.nodes += [{name:$n,protocol:$p,link:$l,route:$r,sni:$s,route_tag:$t,extra_sni:$e,public_port:$x,backend_port:$b,cert_managed:$cm,cert_path:$c,key_path:$k,cert_domains:$cd} +
      (if $argo!="" then {argo_service:$argo,argo_kind:$kind} else {} end) +
      (if $hop!=null then {udp_hop:$hop} else {} end)]' "$META" >"$NM"
  if ! "$BIN" -t -f "$NC" >/dev/null || ! "$BIN" -t -f "$CL" >/dev/null; then
    fail "候选服务端或客户端 Mihomo 配置未通过校验。"
  fi
  oldcfg=$(mktemp "$MH_TMP/pre-route-config.XXXXXX")
  oldclients=$(mktemp "$MH_TMP/pre-route-clients.XXXXXX")
  oldmeta=$(mktemp "$MH_TMP/pre-route-meta.XXXXXX")
  cp "$CFG" "$oldcfg"; cp "$CLIENTS" "$oldclients"; cp "$META" "$oldmeta"
  if ! apply_state "$NC" "$CL" "$NM"; then
    rm -f "$oldcfg" "$oldclients" "$oldmeta"
    fail "节点状态提交失败，未登记 SNI 路由。"
  fi
  if register_routes; then
    :
  else
    route_status=$?
    if apply_state "$oldcfg" "$oldclients" "$oldmeta"; then
      rm -f "$oldcfg" "$oldclients" "$oldmeta"
      [ "$route_status" = 2 ] && fail "SNI 路由登记失败，节点配置已恢复，但路由自动回收不完整；请运行 sb sni-router status 检查。"
      fail "SNI 路由登记失败，节点配置已恢复。"
    fi
    fail "SNI 路由登记失败，且节点配置自动恢复失败；恢复材料保留在 $oldcfg、$oldclients、$oldmeta。"
  fi
  rm -f "$LC" "$CC" "$NC" "$CL" "$NM" "$oldcfg" "$oldclients" "$oldmeta"
  say ""
  say "══════════════════ 节点创建成功 ══════════════════"
  say "名称：$NAME"
  say "协议：$protocol"
  say "公网端口：$public"
  [ -n "$SNI_NAME" ] && say "域名/SNI：$SNI_NAME"
  say ""
  say "分享链接（可复制到 v2rayN 或支持该协议的客户端导入）："
  say "$link"
  if [ "$protocol" = vless-xhttp ] && [ -n "$EXTRA_SNI" ]; then
    say ""
    say "链接已附带 Xray 格式 extra.downloadSettings；客户端支持有差异，Mihomo 请优先导入完整 YAML。"
  fi
  say "═══════════════════════════════════════════════════"
}
public_port() { if [ "$ROUTE" = none ]; then printf '%s' "$PORT"; else printf 443; fi; }

json_edit() {
  local file=$1; shift
  jq "$@" "$file" >"$file.next"
  mv -f "$file.next" "$file"
}
node_documents() {
  begin_files
  jq -n --arg name "$NAME" --arg bind "$BIND" --argjson port "$PORT" \
    '{listeners:[{name:$name,listen:$bind,port:$port}]}' >"$LC"
  jq -n --arg name "$NAME" --arg host "$HOST" --argjson port "$(public_port)" \
    '{proxies:[{name:$name,server:$host,port:$port,udp:true}]}' >"$CC"
}
node_tls() {
  json_edit "$LC" --arg cert "$CERT" --arg key "$KEY" \
    '.listeners[0] += {certificate:$cert,"private-key":$key}'
  json_edit "$CC" --arg sni "$TLS_NAME" --argjson skip "${SKIP_CERT:-false}" \
    '.proxies[0] += {tls:true,"skip-cert-verify":$skip,"client-fingerprint":"chrome"} |
    .proxies[0] |= (if .type == "vless" then .servername=$sni else .sni=$sni end)'
}
node_vless() {
  local id; id=$(uuid)
  json_edit "$LC" --arg id "$id" '.listeners[0] += {type:"vless",users:[{username:"default",uuid:$id}]}'
  json_edit "$CC" --arg id "$id" '.proxies[0] += {type:"vless",uuid:$id}'
}
client_link() {
  # 分享链接只从客户端配置生成；端口修改、导出、节点展示使用同一来源。
  jq -r '
    def enc: tostring | @uri;
    def host: if contains(":") then "["+.+"]" else . end;
    def query: to_entries | map(select(.value != null and .value != "") | (.key|enc)+"="+(.value|enc)) | join("&");
    . as $p | (.server|host) as $host | (.name|enc) as $name |
    {sni:(.servername//.sni),alpn:((.alpn//[])|join(",")),fp:."client-fingerprint",
     insecure:(if ."skip-cert-verify" then "1" else null end)} as $tls |
    if .type == "vless" or .type == "trojan" then
      ($tls + {security:(if ."reality-opts" then "reality" elif .tls or .type == "trojan" then "tls" else "none" end),
        type:(.network//"tcp"),encryption:(if .type=="vless" then "none" else null end),flow:.flow,
        pbk:."reality-opts"."public-key",sid:."reality-opts"."short-id",
        path:(."ws-opts".path//."xhttp-opts".path),host:(."ws-opts".headers.Host//."xhttp-opts".host),
        serviceName:."grpc-opts"."grpc-service-name",mode:."xhttp-opts".mode,
        extra:(if ."xhttp-opts"."download-settings" then
          ."xhttp-opts"."download-settings" as $d |
          {downloadSettings:{address:$d.server,port:$d.port,network:"xhttp",security:"tls",
            tlsSettings:{serverName:$d.servername,alpn:$d.alpn,fingerprint:($d."client-fingerprint"//"chrome"),allowInsecure:($d."skip-cert-verify"//$p."skip-cert-verify"//false)},
            xhttpSettings:{path:$d.path,host:$d.host}}} | tojson else null end)}) as $q |
      .type+"://"+((.uuid//.password)|enc)+"@"+$host+":"+(.port|tostring)+"?"+($q|query)+"#"+$name
    elif .type == "ss" then
      "ss://"+((.cipher+":"+.password)|@base64|gsub("\\+";"-")|gsub("/";"_")|gsub("=";""))+"@"+$host+":"+(.port|tostring)+"#"+$name
    elif .type == "socks5" then
      "socks5://"+(.username|enc)+":"+(.password|enc)+"@"+$host+":"+(.port|tostring)+"#"+$name
    elif .type == "tuic" then
      "tuic://"+(.uuid|enc)+":"+(.password|enc)+"@"+$host+":"+(.port|tostring)+"?"+
      ($tls+{congestion_control:."congestion-controller",udp_relay_mode:."udp-relay-mode"}|query)+"#"+$name
    elif .type == "anytls" or .type == "hysteria2" then
      .type+"://"+(.password|enc)+"@"+$host+":"+(.port|tostring)+"?"+
      ($tls+{obfs:.obfs,"obfs-password":."obfs-password",mport:.ports}|query)+"#"+$name
    else error("该协议请导出 Mihomo YAML") end'
}
finish_node() {
  local protocol=$1 link
  link=$(jq '.proxies[0]' "$CC" | client_link)
  commit_node "$protocol" "$link" "$(public_port)"
}
tls_address() {
  direct_domain
  TLS_NAME=$HOST
  if [ "${CDN:-false}" = true ]; then
    domain_ok "$TLS_NAME" || fail "CDN 节点需要有效域名。"
    say "客户端地址可填写 CDN 优选 IP/域名；证书域名和 SNI 保持 $TLS_NAME。"
    ask_host "$TLS_NAME"
  fi
}
cdn_guide() {
  say "CDN 设置：DNS 指向此 VPS；SSL 使用 Full (strict)，节点路径绕过缓存、重定向和质询。"
  say "共享 443 使用 HAProxy TCP 透传；节点 TLS 由 Mihomo 终止，Emby 使用另一个子域名。"
}
add_reality() {
  check_ready; new_name
  local pair pri pub sid dest target target_port choice selection selected_sni
  read -r -p "Reality 目标 [1 使用 sb 同款扫描/自有源站向导 / 2 手动，默认 1]: " choice
  case "${choice:-1}" in
    1)
      [ -x "$SNI" ] || fail "请先安装整套 proxyall 脚本。"
      selection=$(mktemp "$MH_TMP/reality-selection.XXXXXX")
      "$SNI" select-mihomo-reality 9>&- | tee "$selection" | sed '/^MH_REALITY_/d'
      selected_sni=$(sed -n 's/^MH_REALITY_SNI=//p' "$selection" | tail -n1)
      target=$(sed -n 's/^MH_REALITY_HOST=//p' "$selection" | tail -n1)
      target_port=$(sed -n 's/^MH_REALITY_PORT=//p' "$selection" | tail -n1)
      rm -f "$selection"
      domain_ok "$selected_sni" && host_ok "$target" && port_ok "$target_port" || fail "Reality 向导返回无效，请更新整套脚本。"
      tcp_endpoint "$selected_sni"; SNI_NAME=$selected_sni
      [ "$ROUTE" = none ] || ROUTE=reality
      dest="$(uri_host "$target"):$target_port" ;;
    2) reality_endpoint; dest= ;;
    *) fail "选择无效。" ;;
  esac
  ask_host
  if [ -z "$dest" ]; then
    read -r -p "Reality 握手目标 [${SNI_NAME}:443]: " dest
    dest=${dest:-$SNI_NAME:443}
  fi
  [[ "$dest" =~ ^([A-Za-z0-9.-]+):([0-9]{1,5})$ ]] || fail "握手目标格式应为 域名:端口。"
  target=${BASH_REMATCH[1]}; target_port=${BASH_REMATCH[2]}
  host_ok "$target" && port_ok "$target_port" || fail "握手目标无效。"
  if [ "$target" = "$HOST" ] && [ "$target_port" = "$(public_port)" ]; then fail "Reality 握手目标不能指向自身入口。"; fi
  if [ -x "$SNI" ]; then
    "$SNI" check-mihomo-reality "$(public_port)" "$target" "$target_port" 9>&-
    "$SNI" check-mihomo-reality "$PORT" "$target" "$target_port" 9>&-
  fi
  # 提前探测 TLS 1.3，避免创建一个无法握手的节点。
  if ! timeout 12 openssl s_client -connect "$dest" -servername "$SNI_NAME" -tls1_3 </dev/null 2>/dev/null | grep -Eq 'TLSv1.3|TLS_AES_'; then
    fail "握手目标未通过 TLS 1.3 探测，请更换目标。"
  fi
  pair=$("$BIN" generate reality-keypair)
  pri=$(printf '%s\n' "$pair" | awk '/PrivateKey:/ {print $2}')
  pub=$(printf '%s\n' "$pair" | awk '/PublicKey:/ {print $2}')
  [ -n "$pri" ] && [ -n "$pub" ] || fail "无法生成 Reality 密钥。"
  sid=$(rand_text 8); node_documents; node_vless
  json_edit "$LC" --arg dest "$dest" --arg pri "$pri" --arg sid "$sid" --arg sni "$SNI_NAME" \
    '.listeners[0].users[0].flow="xtls-rprx-vision" |
     .listeners[0]."reality-config"={dest:$dest,"private-key":$pri,"short-id":[$sid],"server-names":[$sni]}'
  json_edit "$CC" --arg pub "$pub" --arg sid "$sid" --arg sni "$SNI_NAME" \
    '.proxies[0] += {network:"tcp",tls:true,servername:$sni,"client-fingerprint":"firefox",flow:"xtls-rprx-vision",
      "reality-opts":{"public-key":$pub,"short-id":$sid}}'
  finish_node vless-reality
}
add_anytls() {
  check_ready; new_name; tcp_endpoint; tls_address; get_cert "$TLS_NAME"
  local pass; pass=$(rand_text 24); node_documents
  json_edit "$LC" --arg pass "$pass" '.listeners[0] += {type:"anytls",users:{default:$pass}}'
  json_edit "$CC" --arg pass "$pass" '.proxies[0] += {type:"anytls",password:$pass}'
  node_tls; finish_node anytls
}
xhttp_domain_guide() {
  say "XHTTP 使用 Mihomo 原生入站，无需额外 Xray。默认 TLS + HTTP/2。"
  say "上下行域名必须回源到同一个 Mihomo 入站；共享 443 时使用不同于 Emby 的完整域名。"
  say "stream-one 不支持独立下行；CDN 通用方案默认 packet-up。"
}
add_xhttp() {
  check_ready; require_xhttp_core; new_name; xhttp_domain_guide
  local scene mode path server_host down_host confirm
  read -r -p "连接方式 [1 直连 / 2 CDN，默认 2]: " scene
  case "${scene:-2}" in 1) CDN=false ;; 2) CDN=true; cdn_guide ;; *) fail "连接方式无效。" ;; esac
  tcp_endpoint; tls_address
  domain_ok "$TLS_NAME" || fail "XHTTP TLS 节点请使用域名。"
  mode=auto; [ "$CDN" != true ] || mode=packet-up
  read -r -p "XHTTP 模式 [auto/stream-one/stream-up/packet-up，默认 $mode]: " scene
  mode=${scene:-$mode}
  case "$mode" in auto|stream-one|stream-up|packet-up) ;; *) fail "模式无效。" ;; esac
  if [ "$CDN" = true ] && [ "$mode" != packet-up ]; then
    say "stream-up/stream-one 要求 CDN 支持流式上传及相应的 HTTP/2/gRPC 回源。"
  fi
  path=$(rand_path)
  read -r -p "XHTTP 路径 [默认 $path]: " scene
  path=${scene:-$path}
  [[ "$path" =~ ^/[A-Za-z0-9/_-]*$ ]] || fail "路径须以 / 开头，只能包含字母、数字、/、_ 和 -。"
  read -r -p "独立下行域名（可选，留空共用主域名）: " EXTRA_SNI
  EXTRA_SNI=${EXTRA_SNI,,}
  server_host=$TLS_NAME; down_host=
  if [ -n "$EXTRA_SNI" ]; then
    [ "$mode" != stream-one ] || fail "stream-one 不能使用独立下行，请选择 stream-up 或 packet-up。"
    domain_ok "$EXTRA_SNI" || fail "下行域名无效。"
    [ "$EXTRA_SNI" != "${TLS_NAME,,}" ] || fail "下行域名必须与主域名不同。"
    [ "$ROUTE" = none ] || sni check-sni-free "$EXTRA_SNI"
    server_host=
    down_host=$EXTRA_SNI
    read -r -p "下行连接地址（可填 CDN 优选 IP）[$EXTRA_SNI]: " scene
    down_host=$(normalize_host "${scene:-$EXTRA_SNI}")
    host_ok "$down_host" || fail "下行连接地址无效。"
  fi
  say "入口：$HOST:$(public_port) → $BIND:$PORT；SNI/Host：$TLS_NAME；模式：$mode；路径：$path"
  [ -z "$EXTRA_SNI" ] || say "下行：$down_host:$(public_port)；SNI/Host：$EXTRA_SNI；与上行共用同一监听器。"
  read -r -p "确认创建？[Y/n]: " confirm
  [[ "$confirm" != n && "$confirm" != N ]] || return 0
  if [ -n "$EXTRA_SNI" ]; then get_cert "$TLS_NAME" "$EXTRA_SNI"; else get_cert "$TLS_NAME"; fi
  node_documents; node_vless; node_tls
  # 服务端 auto 接受全部合法模式；分离下行 GET 使用独立 Host，因此不固定服务端 Host。
  json_edit "$LC" --arg path "$path" --arg host "$server_host" \
    '.listeners[0]."xhttp-config"={path:$path,host:$host,mode:"auto"}'
  json_edit "$CC" --arg path "$path" --arg host "$TLS_NAME" --arg mode "$mode" \
    '.proxies[0] += {network:"xhttp",alpn:["h2"],"xhttp-opts":{path:$path,host:$host,mode:$mode}}'
  if [ -n "$EXTRA_SNI" ]; then
    json_edit "$CC" --arg path "$path" --arg host "$EXTRA_SNI" --arg server "$down_host" --argjson port "$(public_port)" \
      '.proxies[0]."xhttp-opts"."download-settings"={path:$path,host:$host,server:$server,port:$port,tls:true,alpn:["h2"],servername:$host,"client-fingerprint":"chrome"}'
  fi
  finish_node vless-xhttp
}
add_tls_transport() {
  local type=$1 pass path answer
  check_ready; new_name
  read -r -p "是否使用 CDN？[y/N]: " answer
  [[ ! "$answer" =~ ^[Yy]$ ]] || { CDN=true; cdn_guide; }
  tcp_endpoint; tls_address; get_cert "$TLS_NAME"; node_documents
  if [ "$type" = trojan-ws ]; then
    pass=$(rand_text 24)
    json_edit "$LC" --arg pass "$pass" '.listeners[0] += {type:"trojan",users:[{username:"default",password:$pass}]}'
    json_edit "$CC" --arg pass "$pass" '.proxies[0] += {type:"trojan",password:$pass}'
  else node_vless; fi
  node_tls
  path=$(rand_path)
  if [ "$type" = vless-grpc ]; then
    path=${path#/}
    json_edit "$LC" --arg path "$path" '.listeners[0]."grpc-service-name"=$path'
    json_edit "$CC" --arg path "$path" '.proxies[0] += {network:"grpc",alpn:["h2"],"grpc-opts":{"grpc-service-name":$path}}'
    [ "$CDN" != true ] || say "请在 CDN 开启 gRPC，并启用 HTTP/2 回源。"
  else
    json_edit "$LC" --arg path "$path" '.listeners[0]."ws-path"=$path'
    json_edit "$CC" --arg path "$path" --arg host "$TLS_NAME" \
      '.proxies[0] += {network:"ws","ws-opts":{path:$path,headers:{Host:$host}}}'
  fi
  finish_node "$type"
}
add_plain() {
  local type=$1 pass method choice
  check_ready; new_name
  local proto=tcp
  [ "$type" = vless-tcp ] || proto=both
  ask_port "$proto"; check_port "$proto" "$PORT"; ask_host
  BIND=$(default_bind); node_documents
  case "$type" in
    vless-tcp)
      node_vless
      json_edit "$LC" '.listeners[0]."allow-insecure"=true'
      json_edit "$CC" '.proxies[0] += {network:"tcp",tls:false}' ;;
    shadowsocks)
      say "[1] aes-256-gcm  [2] chacha20-ietf-poly1305  [3] 2022-blake3-aes-128-gcm  [4] 2022-blake3-aes-256-gcm  [5] SS2022 AES-256 + Padding"
      read -r -p "加密方式 [1]: " choice
      pass=$(rand_text 24)
      case "${choice:-1}" in
        1) method=aes-256-gcm ;; 2) method=chacha20-ietf-poly1305 ;;
        3) method=2022-blake3-aes-128-gcm; pass=$(openssl rand -base64 16) ;;
        4|5) method=2022-blake3-aes-256-gcm; pass=$(openssl rand -base64 32) ;;
        *) fail "加密方式无效。" ;;
      esac
      json_edit "$LC" --arg method "$method" --arg pass "$pass" '.listeners[0] += {type:"shadowsocks",cipher:$method,password:$pass,udp:true}'
      json_edit "$CC" --arg method "$method" --arg pass "$pass" '.proxies[0] += {type:"ss",cipher:$method,password:$pass}'
      if [ "${choice:-1}" = 5 ]; then
        json_edit "$LC" '.listeners[0]."mux-option"={padding:true}'
        json_edit "$CC" '.proxies[0].smux={enabled:true,protocol:"h2mux",padding:true}'
        say "已开启 Multiplex + Padding；客户端请导入完整 YAML，普通 SS 链接不携带 smux 参数。"
      fi ;;
    socks)
      pass=$(rand_text 20)
      json_edit "$LC" --arg pass "$pass" '.listeners[0] += {type:"socks",users:[{username:"default",password:$pass}],udp:true}'
      json_edit "$CC" --arg pass "$pass" '.proxies[0] += {type:"socks5",username:"default",password:$pass}' ;;
  esac
  finish_node "$type"
}
add_quic() {
  local type=$1 pass id obfs answer
  check_ready; new_name
  # TCP 443 的 HAProxy 不占用 UDP 443，允许 HY2/TUIC 在 UDP 443 独立监听。
  ask_port udp; check_port udp "$PORT"; ask_host
  TLS_NAME=$HOST; get_cert "$TLS_NAME"; BIND=$(default_bind); node_documents
  pass=$(rand_text 24)
  if [ "$type" = hysteria2 ]; then
    json_edit "$LC" --arg pass "$pass" '.listeners[0] += {type:"hysteria2",users:{default:$pass}}'
    json_edit "$CC" --arg pass "$pass" '.proxies[0] += {type:"hysteria2",password:$pass}'
    read -r -p "启用 Salamander 混淆？[y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      obfs=$(rand_text 24)
      json_edit "$LC" --arg pass "$obfs" '.listeners[0] += {obfs:"salamander","obfs-password":$pass}'
      json_edit "$CC" --arg pass "$obfs" '.proxies[0] += {obfs:"salamander","obfs-password":$pass}'
    fi
    ask_udp_hop
    if [ "$UDP_HOP" != null ]; then
      json_edit "$CC" --argjson hop "$UDP_HOP" '.proxies[0].ports="\($hop.start)-\($hop.end)"'
    fi
  else
    id=$(uuid)
    json_edit "$LC" --arg id "$id" --arg pass "$pass" '.listeners[0] += {type:"tuic",users:{($id):$pass},"congestion-controller":"bbr",alpn:["h3"]}'
    json_edit "$CC" --arg id "$id" --arg pass "$pass" '.proxies[0] += {type:"tuic",uuid:$id,password:$pass,"congestion-controller":"bbr","udp-relay-mode":"native",alpn:["h3"]}'
  fi
  node_tls; finish_node "$type"
}

list_nodes() {
  init
  sync_argo_domains
  local mode=${1:-full}
  if ! jq -e '.nodes | length > 0' "$META" >/dev/null; then say "当前没有 Mihomo 节点。"; return 0; fi
  if command -v column >/dev/null 2>&1; then
    jq -r '.nodes[] | [.name,.protocol,(.public_port|tostring),.sni] | @tsv' "$META" | column -t -s $'\t'
  else
    jq -r '.nodes[] | [.name,.protocol,(.public_port|tostring),.sni] | @tsv' "$META"
  fi
  if [ "$mode" = full ]; then
    say ""
    say "分享链接："
    jq -r '.nodes[] | "  \(.name):\n  \(.link)\n"' "$META"
  fi
}
export_nodes() {
  init
  sync_argo_domains
  local out=$1
  [ -n "$out" ] || out=/root/mihomo-nodes.txt
  [ ! -L "$out" ] || fail "导出路径不能是符号链接。"
  local resolved
  resolved=$(readlink -m -- "$out")
  case "$resolved" in "$ROOT"|"$ROOT"/*|"$BIN"|/usr/local/bin/mh) fail "不能覆盖管理器文件，请选择其他导出位置。" ;; esac
  case "$out" in
    *.yaml|*.yml) atomic_install "$CLIENTS" "$out" 600 ;;
    *) local stage; stage=$(mktemp "$MH_TMP/export.XXXXXX")
       jq -r '.nodes[].link' "$META" >"$stage"
       atomic_install "$stage" "$out" 600; rm -f "$stage" ;;
  esac
  chmod 600 "$out"
  say "链接已导出：$out"
  say "Mihomo YAML：$CLIENTS"
  if yq -e '.proxies[]|select(.smux.enabled==true)' "$CLIENTS" >/dev/null 2>&1; then
    say "含 Multiplex/Padding 节点，请导出 .yaml；普通 SS 链接不能保存 smux 参数。"
  fi
  if jq -e '.nodes[] | select((.extra_sni // "") != "")' "$META" >/dev/null; then
    say "XHTTP 分离下行请优先导出 .yaml 文件；链接 extra 扩展需要客户端支持。"
  fi
}
delete_node() {
  check_ready
  local asked route route_tag extra backend_port relay_proxy nc nl nm oldcfg oldclients oldmeta route_status
  local cert_path cert_primary cert_flag_present cert_managed expected_cert cleanup_candidate=false cleanup_output cleanup_status yes
  if ! jq -e '.nodes | length > 0' "$META" >/dev/null; then
    say "当前没有 Mihomo 节点。"
    return 0
  fi
  if [ -n "${1:-}" ]; then asked=$1
  else select_node || return 0; asked=$SELECTED_NAME; fi
  jq -e --arg name "$asked" '.nodes[]|select(.name==$name)' "$META" >/dev/null || fail "节点不存在。"
  route=$(jq -r --arg n "$asked" '.nodes[]|select(.name==$n)|.route // "none"' "$META")
  route_tag=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.route_tag // .name)' "$META")
  extra=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.extra_sni // "")' "$META")
  backend_port=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.backend_port // .public_port)' "$META")
  relay_proxy=$(jq -r --arg n "$asked" '[.relays[] | select(.listener==$n) | .proxy][0] // ""' "$META")
  cert_flag_present=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | has("cert_managed")' "$META")
  cert_managed=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.cert_managed // false)' "$META")
  cert_path=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.cert_path // "")' "$META")
  cert_primary=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.cert_domains[0] // .sni // "")' "$META")
  if [ -z "$cert_path" ]; then
    cert_path=$(MH_YQ_NAME="$asked" yq eval -r '.listeners[] | select(.name==strenv(MH_YQ_NAME)) | .certificate // ""' "$CFG")
  fi
  if [ -n "$cert_primary" ]; then
    cert_primary=${cert_primary,,}
    expected_cert="/etc/nginx/certs/${cert_primary}/cert"
    if [ "$cert_managed" = true ] || { [ "$cert_flag_present" = false ] && [ "$cert_path" = "$expected_cert" ]; }; then
      cleanup_candidate=true
    fi
  fi
  say ""
  [ -n "$relay_proxy" ] && say "将同步删除出站映射：$asked → $relay_proxy"
  [ "$route" != none ] && say "将同步删除共享 443 的 SNI 路由。"
  if [ "$cleanup_candidate" = true ]; then
    say "将尝试删除自动签发证书及其续期记录：$cert_primary"
    say "若证书仍被其他节点、Emby 或 sing-box 配置引用，将自动保留。"
  elif [ -n "$cert_path" ]; then
    say "检测到手工/非本脚本证书，将保留证书文件：$cert_path"
  fi
  yes=${2:-}
  [ "$yes" = yes ] || read -r -p "确认删除 $asked？输入 yes: " yes
  [ "$yes" = yes ] || return 0
  nc=$(mktemp "$MH_TMP/config.XXXXXX"); nl=$(mktemp "$MH_TMP/clients.XXXXXX"); nm=$(mktemp "$MH_TMP/meta.XXXXXX")
  oldcfg=$(mktemp "$MH_TMP/old-config.XXXXXX"); oldclients=$(mktemp "$MH_TMP/old-clients.XXXXXX"); oldmeta=$(mktemp "$MH_TMP/old-meta.XXXXXX")
  cp "$CFG" "$oldcfg"; cp "$CLIENTS" "$oldclients"; cp "$META" "$oldmeta"
  MH_YQ_NAME="$asked" yq eval 'del(.listeners[] | select(.name == strenv(MH_YQ_NAME)))' "$CFG" >"$nc"
  if [ -n "$relay_proxy" ]; then
    MH_YQ_PROXY="$relay_proxy" yq -i 'del(.proxies[] | select(.name == strenv(MH_YQ_PROXY)))' "$nc"
  fi
  MH_YQ_NAME="$asked" yq eval 'del(.proxies[] | select(.name == strenv(MH_YQ_NAME)))' "$CLIENTS" >"$nl"
  jq --arg n "$asked" 'del(.nodes[] | select(.name==$n)) | .relays |= map(select(.listener != $n))' "$META" >"$nm"
  if ! apply_state "$nc" "$nl" "$nm"; then fail "删除状态提交失败，原节点已保留。"; fi
  if unregister_routes "$route" "$route_tag" "$extra" "$backend_port"; then
    :
  else
    route_status=$?
    if apply_state "$oldcfg" "$oldclients" "$oldmeta"; then
      [ "$route_status" = 2 ] && fail "SNI 路由删除失败，节点配置已恢复，但下行路由自动恢复失败；请运行 sb sni-router status 检查。"
      fail "SNI 路由删除失败，已恢复节点配置。"
    fi
    fail "SNI 路由删除失败，节点配置恢复也失败；备份仍在 $oldcfg、$oldclients、$oldmeta。"
  fi
  local argo_service
  argo_service=$(jq -r --arg name "$asked" '.nodes[]|select(.name==$name)|.argo_service//""' "$oldmeta")
  if [ -n "$argo_service" ] && ! remove_argo_service "$argo_service"; then
    apply_state "$oldcfg" "$oldclients" "$oldmeta" || fail "Argo 清理及节点恢复失败。"
    fail "Argo 清理未完成，节点记录已恢复，请检查 $argo_service。"
  fi
  say "已删除：$asked"
  [ -z "$relay_proxy" ] || say "关联出站映射已删除：$relay_proxy"
  [ "$route" = none ] || say "关联 SNI 路由已删除。"
  rm -f "$nc" "$nl" "$nm" "$oldcfg" "$oldclients" "$oldmeta"
  if [[ "$route_tag" =~ ^mh:([a-f0-9]{16})$ ]] && [ "$cert_path" = "$ROOT/certs/${BASH_REMATCH[1]}.crt" ]; then
    local cert_id=${BASH_REMATCH[1]}
    if ! yq -o=json '.' "$CFG" | jq -e --arg cert "$cert_path" '..|strings|select(.==$cert)' >/dev/null; then
      rm -f -- "$ROOT/certs/$cert_id.crt" "$ROOT/certs/$cert_id.key"
    fi
  fi
  if [ "$cleanup_candidate" = true ]; then
    if cleanup_output=$("$SNI" remove-mihomo-certificate "$cert_primary" "$cert_path" 9>&-); then
      cleanup_status=$(printf '%s\n' "$cleanup_output" | sed -n 's/^MH_CERT_CLEANUP=//p' | tail -n 1)
      case "$cleanup_status" in
        deleted) say "关联域名证书、ACME 续期记录和验证配置已删除：$cert_primary" ;;
        shared) say "关联证书仍被其他配置共用，已安全保留：$cert_primary" ;;
        unmanaged) say "关联证书不属于 Mihomo 自动签发资源，已保留：$cert_primary" ;;
        *) say "注意：节点已删除，但证书清理组件没有返回可识别状态，请人工检查：$cert_primary" >&2 ;;
      esac
    else
      say "注意：节点及已关联转发资源已删除，但关联证书清理失败，请人工检查：$cert_primary" >&2
    fi
  fi
}
url_decode() {
  local value=$1 output= character hex
  while [ -n "$value" ]; do
    if [[ "$value" == %* ]]; then
      [ "${#value}" -ge 3 ] || fail "分享链接包含无效的百分号编码。"
      hex=${value:1:2}
      [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] || fail "分享链接包含无效的百分号编码。"
      [ "$hex" != 00 ] || fail "分享链接不能包含 NUL 字节。"
      printf -v character '%b' "\\x$hex"
      output+=$character
      value=${value:3}
    else
      output+=${value:0:1}
      value=${value:1}
    fi
  done
  printf '%s' "$output"
}
query_value() {
  local query=$1 wanted=$2 item key value
  local -a items
  IFS='&' read -r -a items <<<"$query"
  for item in "${items[@]}"; do
    key=${item%%=*}
    if [ "$key" = "$wanted" ]; then
      value=
      [[ "$item" == *=* ]] && value=${item#*=}
      url_decode "$value"
      return 0
    fi
  done
  return 0
}
parse_uri() {
  local link=$1 body authority hostport
  body=${link#*://}
  body=${body%%#*}
  URI_QUERY=
  if [[ "$body" == *"?"* ]]; then URI_QUERY=${body#*\?}; body=${body%%\?*}; fi
  authority=${body%%/*}
  [[ "$authority" == *@* ]] || fail "分享链接缺少认证信息。"
  URI_RAW_USER=${authority%@*}
  URI_USER=$(url_decode "$URI_RAW_USER")
  hostport=${authority##*@}
  if [[ "$hostport" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
    URI_HOST=${BASH_REMATCH[1]}; URI_PORT=${BASH_REMATCH[3]}
  elif [[ "$hostport" =~ ^([^:]+)(:([0-9]+))?$ ]]; then
    URI_HOST=${BASH_REMATCH[1]}; URI_PORT=${BASH_REMATCH[3]}
  else
    fail "分享链接服务器地址格式无效。"
  fi
  [ -n "$URI_PORT" ] || URI_PORT=443
  port_ok "$URI_PORT" || fail "分享链接端口无效。"
  URI_PORT=$((10#$URI_PORT))
  host_ok "$URI_HOST" || fail "分享链接地址无效。"
}
build_vless_outbound() {
  local link=$1 out=$2 sec network servername path host_header service mode pbk sid flow fp alpn insecure tls encryption
  parse_uri "$link"
  [[ "$URI_USER" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || fail "VLESS UUID 格式无效。"
  sec=$(query_value "$URI_QUERY" security); network=$(query_value "$URI_QUERY" type); servername=$(query_value "$URI_QUERY" sni)
  path=$(query_value "$URI_QUERY" path); host_header=$(query_value "$URI_QUERY" host); service=$(query_value "$URI_QUERY" serviceName)
  mode=$(query_value "$URI_QUERY" mode); pbk=$(query_value "$URI_QUERY" pbk); sid=$(query_value "$URI_QUERY" sid)
  flow=$(query_value "$URI_QUERY" flow); fp=$(query_value "$URI_QUERY" fp); alpn=$(query_value "$URI_QUERY" alpn); insecure=$(query_value "$URI_QUERY" insecure)
  [ -n "$network" ] || network=tcp
  case "$network" in tcp|ws|grpc|xhttp) ;; *) fail "不支持的 VLESS 传输层：$network；请导入完整 YAML。" ;; esac
  encryption=$(query_value "$URI_QUERY" encryption)
  [[ -z "$encryption" || "$encryption" = none ]] || fail "VLESS Encryption 扩展请导入完整 YAML。"
  [ -z "$flow" ] || [ "$network" = tcp ] || fail "Vision flow 只用于 TCP，不能与 WS/gRPC/XHTTP 混用。"
  [ -n "$servername" ] || servername=$URI_HOST
  case "$sec" in
    tls|reality) tls=true ;;
    ""|none) tls=false ;;
    *) fail "不支持的 VLESS security 参数：$sec" ;;
  esac
  printf 'proxies: []\n' >"$out"
  MH_YQ_NAME="$pname" MH_YQ_HOST="$URI_HOST" MH_YQ_PORT="$URI_PORT" MH_YQ_ID="$URI_USER" MH_YQ_NETWORK="$network" MH_YQ_SNI="$servername" MH_YQ_TLS="$tls" yq eval -i \
    '.proxies += [{"name":strenv(MH_YQ_NAME),"type":"vless","server":strenv(MH_YQ_HOST),"port":(strenv(MH_YQ_PORT)|tonumber),"uuid":strenv(MH_YQ_ID),"network":strenv(MH_YQ_NETWORK),"tls":(strenv(MH_YQ_TLS)=="true"),"servername":strenv(MH_YQ_SNI)}]' "$out"
  [ -n "$flow" ] && MH_YQ_VALUE="$flow" yq eval -i '.proxies[0].flow=strenv(MH_YQ_VALUE)' "$out"
  [ -n "$fp" ] && MH_YQ_VALUE="$fp" yq eval -i '.proxies[0].client-fingerprint=strenv(MH_YQ_VALUE)' "$out"
  [ -n "$alpn" ] && MH_YQ_VALUE="$alpn" yq eval -i '.proxies[0].alpn=(strenv(MH_YQ_VALUE) | split(","))' "$out"
  [ -n "$insecure" ] || insecure=$(query_value "$URI_QUERY" allowInsecure)
  [[ "$insecure" =~ ^(1|true)$ ]] && yq eval -i '.proxies[0].skip-cert-verify=true' "$out"
  if [ "$network" = ws ]; then
    [ -n "$path" ] || path=/
    MH_YQ_VALUE="$path" yq eval -i '.proxies[0].ws-opts.path=strenv(MH_YQ_VALUE)' "$out"
    [ -n "$host_header" ] && MH_YQ_VALUE="$host_header" yq eval -i '.proxies[0].ws-opts.headers.Host=strenv(MH_YQ_VALUE)' "$out"
  elif [ "$network" = grpc ]; then
    MH_YQ_VALUE="$service" yq eval -i '.proxies[0].grpc-opts.grpc-service-name=strenv(MH_YQ_VALUE)' "$out"
  elif [ "$network" = xhttp ]; then
    [ -n "$path" ] || path=/; [ -n "$host_header" ] || host_header=$servername; [ -n "$mode" ] || mode=auto
    case "$mode" in auto|stream-one|stream-up|packet-up) ;; *) fail "XHTTP 模式无效。" ;; esac
    [ -n "$alpn" ] || yq -i '.proxies[0].alpn=["h2"]' "$out"
    MH_YQ_PATH="$path" MH_YQ_HOST="$host_header" MH_YQ_MODE="$mode" yq eval -i \
      '.proxies[0].xhttp-opts={"path":strenv(MH_YQ_PATH),"host":strenv(MH_YQ_HOST),"mode":strenv(MH_YQ_MODE)}' "$out"
    import_xhttp_extra "$out" "$(query_value "$URI_QUERY" extra)" "$mode"
  fi
  if [ "$sec" = reality ]; then
    [ -n "$pbk" ] || fail "Reality 链接缺少 pbk 公钥。"
    [ -n "$fp" ] || fp=firefox
    MH_YQ_KEY="$pbk" MH_YQ_SID="$sid" MH_YQ_FP="$fp" yq eval -i \
      '.proxies[0].client-fingerprint=strenv(MH_YQ_FP) | .proxies[0].reality-opts={"public-key":strenv(MH_YQ_KEY),"short-id":strenv(MH_YQ_SID)}' "$out"
  fi
  return 0
}
build_trojan_outbound() {
  local link=$1 out=$2 network servername path host_header service fp alpn insecure
  parse_uri "$link"
  [ -n "$URI_USER" ] || fail "Trojan 密码不能为空。"
  network=$(query_value "$URI_QUERY" type); servername=$(query_value "$URI_QUERY" sni); path=$(query_value "$URI_QUERY" path)
  host_header=$(query_value "$URI_QUERY" host); service=$(query_value "$URI_QUERY" serviceName); fp=$(query_value "$URI_QUERY" fp)
  alpn=$(query_value "$URI_QUERY" alpn); insecure=$(query_value "$URI_QUERY" insecure)
  [ -n "$network" ] || network=tcp; [ -n "$servername" ] || servername=$URI_HOST
  case "$network" in tcp|ws|grpc) ;; *) fail "Trojan 不支持此传输层：$network。" ;; esac
  printf 'proxies: []\n' >"$out"
  MH_YQ_NAME="$pname" MH_YQ_HOST="$URI_HOST" MH_YQ_PORT="$URI_PORT" MH_YQ_PASS="$URI_USER" MH_YQ_NETWORK="$network" MH_YQ_SNI="$servername" yq eval -i \
    '.proxies += [{"name":strenv(MH_YQ_NAME),"type":"trojan","server":strenv(MH_YQ_HOST),"port":(strenv(MH_YQ_PORT)|tonumber),"password":strenv(MH_YQ_PASS),"network":strenv(MH_YQ_NETWORK),"sni":strenv(MH_YQ_SNI)}]' "$out"
  [ -n "$fp" ] && MH_YQ_VALUE="$fp" yq eval -i '.proxies[0].client-fingerprint=strenv(MH_YQ_VALUE)' "$out"
  [ -n "$alpn" ] && MH_YQ_VALUE="$alpn" yq eval -i '.proxies[0].alpn=(strenv(MH_YQ_VALUE) | split(","))' "$out"
  [ -n "$insecure" ] || insecure=$(query_value "$URI_QUERY" allowInsecure)
  [[ "$insecure" =~ ^(1|true)$ ]] && yq eval -i '.proxies[0].skip-cert-verify=true' "$out"
  if [ "$network" = ws ]; then
    [ -n "$path" ] || path=/
    MH_YQ_VALUE="$path" yq eval -i '.proxies[0].ws-opts.path=strenv(MH_YQ_VALUE)' "$out"
    [ -n "$host_header" ] && MH_YQ_VALUE="$host_header" yq eval -i '.proxies[0].ws-opts.headers.Host=strenv(MH_YQ_VALUE)' "$out"
  elif [ "$network" = grpc ]; then
    MH_YQ_VALUE="$service" yq eval -i '.proxies[0].grpc-opts.grpc-service-name=strenv(MH_YQ_VALUE)' "$out"
  fi
  return 0
}
build_anytls_outbound() {
  local link=$1 out=$2 servername fp alpn insecure
  parse_uri "$link"
  case "$(query_value "$URI_QUERY" security)" in ""|tls) ;; *) fail "AnyTLS 的非 TLS 扩展请使用完整 YAML 导入，不能静默丢弃。" ;; esac
  [ -n "$URI_USER" ] || fail "AnyTLS 密码不能为空。"
  servername=$(query_value "$URI_QUERY" sni); fp=$(query_value "$URI_QUERY" fp); alpn=$(query_value "$URI_QUERY" alpn); insecure=$(query_value "$URI_QUERY" insecure)
  [ -n "$servername" ] || servername=$URI_HOST
  printf 'proxies: []\n' >"$out"
  MH_YQ_NAME="$pname" MH_YQ_HOST="$URI_HOST" MH_YQ_PORT="$URI_PORT" MH_YQ_PASS="$URI_USER" MH_YQ_SNI="$servername" yq eval -i \
    '.proxies += [{"name":strenv(MH_YQ_NAME),"type":"anytls","server":strenv(MH_YQ_HOST),"port":(strenv(MH_YQ_PORT)|tonumber),"password":strenv(MH_YQ_PASS),"tls":true,"sni":strenv(MH_YQ_SNI)}]' "$out"
  [ -n "$fp" ] && MH_YQ_VALUE="$fp" yq eval -i '.proxies[0].client-fingerprint=strenv(MH_YQ_VALUE)' "$out"
  [ -n "$alpn" ] && MH_YQ_VALUE="$alpn" yq eval -i '.proxies[0].alpn=(strenv(MH_YQ_VALUE) | split(","))' "$out"
  [ -n "$insecure" ] || insecure=$(query_value "$URI_QUERY" allowInsecure)
  [[ "$insecure" =~ ^(1|true)$ ]] && yq eval -i '.proxies[0].skip-cert-verify=true' "$out"
  return 0
}
require_xhttp_core() {
  local version
  version=$("$BIN" -v | sed -n 's/.*v\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' | head -n1)
  [ -n "$version" ] && [ "$(printf '%s\n' 1.19.30 "$version" | sort -V | head -n1)" = 1.19.30 ] ||
    fail "XHTTP 请先更新到已验证的 Mihomo v1.19.30 或更高稳定版（主菜单 15）。"
}
import_xhttp_extra() {
  local out=$1 extra=$2 mode=$3 converted
  [ -n "$extra" ] || return 0
  # Xray 的驼峰字段不能原样塞入 Mihomo。只转换明确支持的字段，其余拒绝静默丢失。
  converted=$(printf '%s' "$extra" | jq -ce '
    if type != "object" then error("extra 必须是对象") else . end |
    if (keys-["downloadSettings","noGRPCHeader","xPaddingBytes","scMaxEachPostBytes","scMinPostsIntervalMs"])|length>0
    then error("extra 含尚未支持的扩展，请导入 Mihomo YAML") else . end |
    {"no-grpc-header":.noGRPCHeader,"x-padding-bytes":.xPaddingBytes,
     "sc-max-each-post-bytes":.scMaxEachPostBytes,"sc-min-posts-interval-ms":.scMinPostsIntervalMs} as $base |
    if .downloadSettings then .downloadSettings as $d |
      if ($d|keys-["address","port","network","security","tlsSettings","xhttpSettings"]|length)>0 or
        ($d.network//"xhttp")!="xhttp" or ($d.security//"tls")!="tls" or
        ($d.tlsSettings|keys-["serverName","alpn","fingerprint","allowInsecure"]|length)>0 or
        ($d.xhttpSettings|keys-["path","host"]|length)>0
      then error("不支持此下行扩展，请导入完整 Mihomo YAML") else . end |
      $base + {"download-settings":{server:$d.address,port:$d.port,tls:true,
        servername:$d.tlsSettings.serverName,alpn:($d.tlsSettings.alpn//["h2"]),
        "client-fingerprint":($d.tlsSettings.fingerprint//"chrome"),
        "skip-cert-verify":($d.tlsSettings.allowInsecure//false),
        path:$d.xhttpSettings.path,host:$d.xhttpSettings.host}|with_entries(select(.value!=null))}
    else $base end | with_entries(select(.value!=null))') || fail "XHTTP extra 解析失败。"
  if [ "$mode" = stream-one ] && jq -e 'has("download-settings")' <<<"$converted" >/dev/null; then
    fail "stream-one 不能使用独立下行。"
  fi
  MH_EXTRA="$converted" yq -i '.proxies[0].xhttp-opts *= (strenv(MH_EXTRA)|from_json)' "$out"
}
decode_base64() {
  local value=$1
  [[ "$value" =~ ^[A-Za-z0-9_+/=-]+$ ]] || return 1
  value=$(printf '%s' "$value" | tr -- '-_' '+/')
  while ((${#value} % 4)); do value+='='; done
  printf '%s' "$value" | base64 -d
}
build_other_outbound() {
  local link=$1 out=$2 scheme=${1%%://*} sni pass id method body q obfs alpn insecure
  if [ "$scheme" = vmess ]; then
    body=$(decode_base64 "${link#vmess://}") || fail "VMess Base64 无效。"
    printf '%s' "$body" | jq -e 'type=="object" and (.add|type)=="string" and (.id|type)=="string"' >/dev/null || fail "VMess JSON 无效。"
    printf '%s' "$body" | jq --arg name "$pname" '{proxies:[{name:$name,type:"vmess",server:.add,port:(.port|tonumber),uuid:.id,
      alterId:((.aid//0)|tonumber),cipher:(.scy//"auto"),udp:true,tls:(.tls=="tls"),servername:([.sni,.host,.add]|map(select(.!=null and .!=""))|.[0]),
      network:(.net//"tcp")} +
      (if .net=="ws" then {"ws-opts":{path:(.path//"/"),headers:{Host:(.host//.add)}}}
       elif .net=="grpc" then {"grpc-opts":{"grpc-service-name":(.path//"")}}
       elif (.net//"tcp")=="tcp" then {} else error("VMess 传输层请使用 YAML 导入") end)]}' >"$out"
    return 0
  fi
  if [ "$scheme" = ss ]; then
    body=${link#ss://}; body=${body%%#*}
    if [[ "$body" != *@* ]]; then
      body=$(decode_base64 "$body") || fail "SS Base64 无效。"
      link="ss://$body"
    fi
  fi
  parse_uri "$link"
  sni=$(query_value "$URI_QUERY" sni); sni=${sni:-$URI_HOST}
  alpn=$(query_value "$URI_QUERY" alpn)
  insecure=$(query_value "$URI_QUERY" insecure)
  [ -n "$insecure" ] || insecure=$(query_value "$URI_QUERY" allowInsecure)
  jq -n --arg name "$pname" --arg host "$URI_HOST" --argjson port "$URI_PORT" --arg sni "$sni" \
    --arg alpn "$alpn" --arg insecure "$insecure" \
    '{proxies:[{name:$name,server:$host,port:$port,udp:true,sni:$sni,"skip-cert-verify":($insecure=="1" or $insecure=="true")}+
      (if $alpn!="" then {alpn:($alpn|split(","))} else {} end)]}' >"$out"
  case "$scheme" in
    ss)
      [ -z "$(query_value "$URI_QUERY" plugin)" ] || fail "带插件的 SS 请使用 YAML 导入，避免丢失插件设置。"
      body=$URI_USER
      [[ "$body" == *:* ]] || body=$(decode_base64 "$body") || fail "SS 认证信息无效。"
      [[ "$body" == *:* ]] || fail "SS 缺少加密方式或密码。"
      method=${body%%:*}; pass=${body#*:}
      json_edit "$out" --arg method "$method" --arg pass "$pass" \
        '.proxies[0] += {type:"ss",cipher:$method,password:$pass} | del(.proxies[0].sni,.proxies[0]."skip-cert-verify")' ;;
    socks|socks5|tuic)
      [[ "$URI_RAW_USER" == *:* ]] || fail "$scheme 缺少用户名/UUID 或密码。"
      id=$(url_decode "${URI_RAW_USER%%:*}"); pass=$(url_decode "${URI_RAW_USER#*:}")
      if [ "$scheme" = tuic ]; then
        q=$(query_value "$URI_QUERY" congestion_control); q=${q:-bbr}
        json_edit "$out" --arg id "$id" --arg pass "$pass" --arg cc "$q" \
          '.proxies[0] += {type:"tuic",uuid:$id,password:$pass,"congestion-controller":$cc}'
        q=$(query_value "$URI_QUERY" udp_relay_mode)
        [ -z "$q" ] || json_edit "$out" --arg mode "$q" '.proxies[0]."udp-relay-mode"=$mode'
      else
        json_edit "$out" --arg id "$id" --arg pass "$pass" \
          '.proxies[0] += {type:"socks5",username:$id,password:$pass} | del(.proxies[0].sni,.proxies[0]."skip-cert-verify")'
      fi ;;
    hy2|hysteria2)
      json_edit "$out" --arg pass "$URI_USER" '.proxies[0] += {type:"hysteria2",password:$pass}'
      obfs=$(query_value "$URI_QUERY" obfs)
      if [ -n "$obfs" ]; then
        pass=$(query_value "$URI_QUERY" obfs-password)
        json_edit "$out" --arg obfs "$obfs" --arg pass "$pass" '.proxies[0] += {obfs:$obfs,"obfs-password":$pass}'
      fi
      q=$(query_value "$URI_QUERY" mport)
      [ -z "$q" ] || json_edit "$out" --arg ports "$q" '.proxies[0].ports=$ports' ;;
    *) fail "不支持的分享链接协议：$scheme。" ;;
  esac
}
build_outbound() {
  local link=$1 out=$2 count choice file
  case "$link" in
    vless://*) build_vless_outbound "$link" "$out" ;;
    trojan://*) build_trojan_outbound "$link" "$out" ;;
    anytls://*) build_anytls_outbound "$link" "$out" ;;
    vmess://*|ss://*|socks://*|socks5://*|tuic://*|hy2://*|hysteria2://*) build_other_outbound "$link" "$out" ;;
    file:*)
      file=${link#file:}; [ -r "$file" ] || fail "无法读取 YAML 文件。"
      yq -o=json '.' "$file" | jq 'if type=="array" then {proxies:.} elif has("proxies") then {proxies:.proxies} else {proxies:[.]} end' >"$out"
      count=$(jq '.proxies|length' "$out"); [ "$count" -gt 0 ] || fail "YAML 没有节点。"
      choice=1
      if [ "$count" -gt 1 ]; then
        jq -r '.proxies|to_entries[]|"[\(.key+1)] \(.value.name) (\(.value.type))"' "$out"
        read -r -p "选择导入序号: " choice
        [[ "$choice" =~ ^[0-9]{1,6}$ ]] && ((10#$choice>=1 && 10#$choice<=count)) || fail "序号无效。"
      fi
      json_edit "$out" --argjson index "$((10#$choice-1))" --arg name "$pname" '{proxies:[.proxies[$index]|.name=$name]}' ;;
    *) fail "支持 VLESS/VMess/Trojan/AnyTLS/SS/SOCKS5/HY2/TUIC 链接，或 file:/绝对路径.yaml。" ;;
  esac
  MH_YQ_NAME="$pname" yq -i '.proxies[0].name=strenv(MH_YQ_NAME) | .proxies[0].udp=true' "$out"
  yq -o=json '.' "$out" | jq -e '.proxies[0] | (.server|type)=="string" and (.server|length)>0 and
    (.port|type)=="number" and .port>=1 and .port<=65535 and (."dialer-proxy"//"")==""' >/dev/null ||
    fail "出站地址/端口无效，或引用了未导入的 dialer-proxy。"
  "$BIN" -t -d "$ROOT" -f "$out" || fail "导入节点未通过 Mihomo 校验。"
}

list_relays() {
  init
  if ! jq -e '.relays | length > 0' "$META" >/dev/null; then
    say "当前没有入站 → 出站映射。"
    return 0
  fi
  say "当前入站 → 出站映射："
  if command -v column >/dev/null 2>&1; then
    jq -r '.relays[] | [.listener,.proxy] | @tsv' "$META" | column -t -s $'\t'
  else
    jq -r '.relays[] | "\(.listener) -> \(.proxy)"' "$META"
  fi
}
relay_add() {
  check_ready
  local listener link pname nc nm in cl existing_proxy
  say "选择一个已搭建的 Mihomo 入站，并为它指定一个外部出站节点。"
  say "设置后，该入站收到的流量会直接交给该出站，不经过全局 rules。"
  say "可粘贴分享链接或输入 file:/绝对路径.yaml。"
  select_node || return 0
  listener=$SELECTED_NAME
  if ! MH_YQ_NAME="$listener" yq eval -e '.listeners[]? | select(.name==strenv(MH_YQ_NAME))' "$CFG" >/dev/null 2>&1; then fail "入口不存在。"; fi
  if jq -e --arg n "$listener" '.relays[] | select(.listener==$n)' "$META" >/dev/null; then fail "该入口已有出站映射，请先删除原映射。"; fi
  existing_proxy=$(MH_YQ_NAME="$listener" yq eval -r '.listeners[] | select(.name==strenv(MH_YQ_NAME)) | .proxy // ""' "$CFG")
  [ -z "$existing_proxy" ] || fail "该入口已有 proxy=$existing_proxy，但元数据未登记；请先人工核对配置。"
  read -r -s -p "对应的外部出站分享链接（输入不回显）: " link
  printf '\n'
  while :; do
    pname=relay-$(rand_text 8)
    if ! MH_YQ_NAME="$pname" yq eval -e '.proxies[]? | select(.name==strenv(MH_YQ_NAME))' "$CFG" >/dev/null 2>&1; then break; fi
  done
  in=$(mktemp "$MH_TMP/relay.XXXXXX")
  build_outbound "$link" "$in"
  nc=$(mktemp "$MH_TMP/config.XXXXXX"); nm=$(mktemp "$MH_TMP/meta.XXXXXX"); cl=$(mktemp "$MH_TMP/clients.XXXXXX")
  cp "$CLIENTS" "$cl"
  yq eval-all 'select(fileIndex == 0) *+ {"proxies": (select(fileIndex == 1).proxies)}' "$CFG" "$in" >"$nc"
  MH_YQ_NAME="$listener" MH_YQ_PROXY="$pname" yq eval '(.listeners[] | select(.name==strenv(MH_YQ_NAME))).proxy = strenv(MH_YQ_PROXY)' "$nc" >"$nc.next"; mv "$nc.next" "$nc"
  jq --arg l "$listener" --arg p "$pname" --arg u "$link" '.relays += [{listener:$l,proxy:$p,link:$u}]' "$META" >"$nm"
  if ! apply_state "$nc" "$cl" "$nm"; then fail "中转配置提交失败。"; fi
  rm -f "$in" "$nc" "$cl" "$nm"
  say "出站映射已启用：$listener → $pname"
}
relay_remove() {
  check_ready
  local listener proxy nc nm cl
  if command -v column >/dev/null 2>&1; then
    jq -r '.relays[] | [.listener,.proxy] | @tsv' "$META" | column -t -s $'\t'
  else
    jq -r '.relays[] | [.listener,.proxy] | @tsv' "$META"
  fi
  select_node || return 0
  listener=$SELECTED_NAME
  proxy=$(jq -r --arg n "$listener" '[.relays[] | select(.listener==$n) | .proxy][0] // empty' "$META")
  [ -n "$proxy" ] && [ "$proxy" != null ] || fail "该入口没有出站映射。"
  [ "$(MH_YQ_NAME="$listener" yq eval -r '.listeners[] | select(.name==strenv(MH_YQ_NAME)) | .proxy // ""' "$CFG")" = "$proxy" ] ||
    fail "入口 proxy 与元数据不一致，拒绝自动删除。"
  nc=$(mktemp "$MH_TMP/config.XXXXXX"); nm=$(mktemp "$MH_TMP/meta.XXXXXX"); cl=$(mktemp "$MH_TMP/clients.XXXXXX")
  cp "$CLIENTS" "$cl"
  MH_YQ_NAME="$listener" MH_YQ_PROXY="$proxy" yq eval 'del((.listeners[] | select(.name==strenv(MH_YQ_NAME))).proxy) | del(.proxies[] | select(.name==strenv(MH_YQ_PROXY)))' "$CFG" >"$nc"
  jq --arg n "$listener" 'del(.relays[] | select(.listener==$n))' "$META" >"$nm"
  if ! apply_state "$nc" "$cl" "$nm"; then fail "删除出站映射失败，原状态已保留。"; fi
  rm -f "$nc" "$cl" "$nm"
  say "已删除出站映射：$listener"
}
relay_menu() {
  local choice
  while :; do
    printf '\n╔══════════════════════════════════════════╗\n'
    printf '║          Mihomo 入站 → 出站映射          ║\n'
    printf '╚══════════════════════════════════════════╝\n\n'
    printf '    [1] 新增指定入站 → 出站映射\n'
    printf '    [2] 查看现有映射\n'
    printf '    [3] 删除映射（保留入站节点）\n'
    printf '    [4] TCP/UDP 端口转发\n'
    printf '    [5] 查看/删除端口转发\n'
    printf '    [0] 返回主菜单\n\n'
    read -r -p "  请输入选项 [0-5]: " choice || return 0
    case "$choice" in
      1) run_action relay_add; pause_return ;;
      2) run_action list_relays; pause_return ;;
      3) run_action relay_remove; pause_return ;;
      4) run_action forward_add; pause_return ;;
      5) run_action forward_remove; pause_return ;;
      0) return 0 ;;
      *) say "无效选择。" ;;
    esac
  done
}
install_core() {
  root_only
  [ ! -L "$BIN" ] || fail "$BIN 是符号链接，拒绝替换。"
  [ ! -e "$BIN" ] || [ -f "$BIN" ] || fail "$BIN 不是普通文件，拒绝替换。"
  install_base_deps
  install_yq
  check_runtime_deps
  init
  lock_state
  local arch asset url digest tmp got had_bin=0
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l|armv7) arch=armv7 ;; *) fail "不支持的架构：$(uname -m)" ;; esac
  tmp=$(mktemp -d)
  fetch -o "$tmp/release.json" "$API"
  asset=$(jq -r --arg a "$arch" '
    if $a == "amd64" then
      ([.assets[] | select(.name | test("^mihomo-linux-amd64-v1-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$"))][0].name //
       [.assets[] | select(.name | test("^mihomo-linux-amd64-compatible-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$"))][0].name //
       [.assets[] | select(.name | test("^mihomo-linux-amd64-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$"))][0].name)
    else
      [.assets[] | select(.name | test("^mihomo-linux-" + $a + "-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$"))][0].name
    end // empty' "$tmp/release.json")
  [ -n "$asset" ] || { rm -rf "$tmp"; fail "官方最新版本没有 $arch 的 Linux 包。"; }
  url=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' "$tmp/release.json")
  digest=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' "$tmp/release.json" | sed 's/^sha256://')
  [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || { rm -rf "$tmp"; fail "官方发行资产缺少 SHA-256 digest，拒绝安装未校验文件。"; }
  [[ "$url" == https://github.com/MetaCubeX/mihomo/releases/download/* ]] || { rm -rf "$tmp"; fail "官方发行资产 URL 格式无效。"; }
  fetch -o "$tmp/m.gz" "$url"
  got=$(sha256sum "$tmp/m.gz" | awk '{print $1}')
  [ "${got,,}" = "${digest,,}" ] || { rm -rf "$tmp"; fail "下载 SHA-256 校验失败。"; }
  gzip -dc "$tmp/m.gz" >"$tmp/mihomo"
  chmod 755 "$tmp/mihomo"
  "$tmp/mihomo" -v >/dev/null
  if [ -f "$CFG" ] && ! "$tmp/mihomo" -t -f "$CFG" >/dev/null; then rm -rf "$tmp"; fail "新核心不兼容现有配置，未替换旧核心。"; fi
  if [ -f "$CLIENTS" ] && ! "$tmp/mihomo" -t -f "$CLIENTS" >/dev/null; then rm -rf "$tmp"; fail "新核心不兼容客户端配置，未替换旧核心。"; fi
  if [ -f "$BIN" ]; then cp -p "$BIN" "$tmp/mihomo.old"; had_bin=1; fi
  atomic_install "$tmp/mihomo" "$BIN" 755 || { rm -rf "$tmp"; fail "安装 Mihomo 核心失败。"; }
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active "$SERVICE" >/dev/null 2>&1; then
    if ! reload_service; then
      if [ "$had_bin" = 1 ] && atomic_install "$tmp/mihomo.old" "$BIN" 755 && reload_service; then
        rm -rf "$tmp"
        fail "新核心启动失败，已恢复旧核心。"
      fi
      if [ "$had_bin" = 0 ] && rm -f "$BIN"; then
        rm -rf "$tmp"
        fail "新核心启动失败，安装前没有旧核心，已移除失败版本。"
      fi
      fail "新核心启动失败，自动恢复也失败；恢复材料保留在 $tmp，请人工检查 $BIN。"
    fi
  elif command -v rc-service >/dev/null 2>&1 && rc-service "$SERVICE" status >/dev/null 2>&1; then
    if ! reload_service; then
      if [ "$had_bin" = 1 ] && atomic_install "$tmp/mihomo.old" "$BIN" 755 && reload_service; then
        rm -rf "$tmp"
        fail "新核心启动失败，已恢复旧核心。"
      fi
      if [ "$had_bin" = 0 ] && rm -f "$BIN"; then
        rm -rf "$tmp"
        fail "新核心启动失败，安装前没有旧核心，已移除失败版本。"
      fi
      fail "新核心启动失败，自动恢复也失败；恢复材料保留在 $tmp，请人工检查 $BIN。"
    fi
  fi
  rm -rf "$tmp"
  local version_text
  version_text=$("$BIN" -v)
  say "已安装：${version_text%%$'\n'*}"
}
install_service() {
  root_only; init; lock_state; check_runtime_deps
  [ -x "$BIN" ] || fail "mihomo 核心不存在。"
  "$BIN" -t -f "$CFG" >/dev/null || fail "现有配置无效，未改动服务文件。"
  local unit target backup mode rollback_ok had_target=0
  unit=$(mktemp "$MH_TMP/service.XXXXXX")
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    target=/etc/systemd/system/mihomo.service
    [ ! -L "$target" ] || { rm -f "$unit"; fail "$target 是符号链接，拒绝覆盖。"; }
    if [ -e "$target" ] && ! grep -Fqx '# MH_MANAGER_MANAGED_SERVICE=1' "$target" &&
       ! grep -Fqx "ExecStart=$BIN -d $ROOT -f $CFG" "$target"; then
      rm -f "$unit"; fail "$target 不属于 mh 管理器，拒绝覆盖。"
    fi
    cat >"$unit" <<EOF
# MH_MANAGER_MANAGED_SERVICE=1
[Unit]
Description=Mihomo Server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN -d $ROOT -f $CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    backup=$(mktemp "$MH_TMP/service-backup.XXXXXX")
    if [ -e "$target" ]; then cp -p "$target" "$backup"; had_target=1; fi
    mode=644
    atomic_install "$unit" "$target" "$mode" || { rm -f "$unit" "$backup"; fail "写入 systemd 服务文件失败。"; }
  elif command -v rc-service >/dev/null 2>&1; then
    target=/etc/init.d/mihomo
    [ ! -L "$target" ] || { rm -f "$unit"; fail "$target 是符号链接，拒绝覆盖。"; }
    if [ -e "$target" ] && ! grep -Fqx '# MH_MANAGER_MANAGED_SERVICE=1' "$target"; then
      if ! grep -Fqx "command=\"$BIN\"" "$target" ||
         ! grep -Fqx "command_args=\"-d $ROOT -f $CFG\"" "$target"; then
        rm -f "$unit"; fail "$target 不属于 mh 管理器，拒绝覆盖。"
      fi
    fi
    cat >"$unit" <<EOF
#!/sbin/openrc-run
# MH_MANAGER_MANAGED_SERVICE=1
name="mihomo"
command="$BIN"
command_args="-d $ROOT -f $CFG"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="$ROOT/mihomo.log"
error_log="$ROOT/mihomo.log"
EOF
    backup=$(mktemp "$MH_TMP/service-backup.XXXXXX")
    if [ -e "$target" ]; then cp -p "$target" "$backup"; had_target=1; fi
    mode=755
    atomic_install "$unit" "$target" "$mode" || { rm -f "$unit" "$backup"; fail "写入 OpenRC 服务文件失败。"; }
  else fail "仅支持 systemd 或 OpenRC。"; fi
  rm -f "$unit"
  if ! reload_service; then
    rollback_ok=1
    if [ "$had_target" = 1 ]; then
      atomic_install "$backup" "$target" "$mode" || rollback_ok=0
      if [ "$rollback_ok" = 1 ] && ! reload_service; then rollback_ok=0; fi
    else
      rm -f "$target" || rollback_ok=0
      if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || rollback_ok=0; fi
    fi
    if [ "$rollback_ok" = 1 ]; then
      rm -f "$backup"
      fail "服务安装失败，已恢复原服务文件。"
    fi
    fail "服务安装和自动恢复均失败；原服务文件备份保留在 $backup。"
  fi
  rm -f "$backup"
}
install_nft() {
  command -v nft >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then apt-get update; apt-get install -y nftables
  elif command -v dnf >/dev/null 2>&1; then dnf install -y nftables
  elif command -v yum >/dev/null 2>&1; then yum install -y nftables
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache nftables
  else fail "请安装 nftables 后启用 HY2 端口跳跃。"; fi
}
ask_udp_hop() {
  local range start end occupied ranges
  read -r -p "HY2 跳跃端口范围（如 20000-30000；留空禁用）: " range
  [ -n "$range" ] || return 0
  [[ "$range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || fail "请输入 起始端口-结束端口。"
  start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
  port_ok "$start" && port_ok "$end" || fail "跳跃端口范围无效。"
  start=$((10#$start)); end=$((10#$end))
  [ "$start" -lt "$end" ] || fail "起始端口须小于结束端口。"
  occupied=$(ss -H -lnu | awk -v a="$start" -v b="$end" '{n=split($4,p,":"); if(p[n]>=a && p[n]<=b) print p[n]}')
  [ -z "$occupied" ] || fail "跳跃范围包含正在使用的 UDP 端口：$occupied"
  if yq -o=json '.' "$CFG" | jq -e --argjson a "$start" --argjson b "$end" \
    '.listeners[]|select(.type=="hysteria2" or .type=="tuic" or .udp==true or (.type=="tunnel" and (.network|index("udp"))!=null))|
      select(.port >= $a and .port <= $b)' >/dev/null; then fail "跳跃范围与已有入站冲突。"; fi
  if jq -e --argjson a "$start" --argjson b "$end" '.nodes[]|select(.udp_hop!=null)|select(.udp_hop.start<=$b and .udp_hop.end>=$a)' "$META" >/dev/null; then
    fail "跳跃范围与已有 Mihomo 跳跃规则冲突。"
  fi
  install_nft
  # 同时检查本机其他脚本的 NAT 重定向范围，防止抢占 sing-box 的跳跃端口。
  ranges=$(nft list ruleset | awk '/udp dport/ && /redirect/ {for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}')
  while IFS= read -r occupied; do
    if [[ "$occupied" =~ ^([0-9]+)(-([0-9]+))?$ ]]; then
      if ((BASH_REMATCH[1] <= end && ${BASH_REMATCH[3]:-${BASH_REMATCH[1]}} >= start)); then fail "跳跃范围与系统已有 UDP redirect 规则重叠：$occupied"; fi
    fi
  done <<<"$ranges"
  UDP_HOP=$(jq -nc --argjson start "$start" --argjson end "$end" '{start:$start,end:$end}')
  say "使用独立 nftables 表 mh_port_hops，将 UDP $start-$end 重定向到 $PORT；请在安全组放行整个范围。"
}
ensure_managed_command() {
  local source
  source=$(readlink -f "${BASH_SOURCE[0]}")
  [ ! -L /usr/local/bin/mh ] || return 1
  [ ! -e /usr/local/bin/mh ] || grep -Fqx '# MH_MANAGER_MANAGED_COMMAND=1' /usr/local/bin/mh || return 1
  if [ "$source" != /usr/local/bin/mh ]; then atomic_install "$source" /usr/local/bin/mh 755 || return 1; fi
}
ensure_hop_service() {
  local file
  ensure_managed_command || return 1
  if [ -d /run/systemd/system ]; then
    file=/etc/systemd/system/mihomo-port-hops.service
    [ ! -L "$file" ] || return 1
    [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_HOPS=1' "$file" || return 1
    cat >"$file" <<'EOF' || return 1
# MH_MANAGER_HOPS=1
[Unit]
Description=Mihomo UDP port hopping
After=network-pre.target nftables.service
Before=mihomo.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/mh restore-hops
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$file"
    systemctl daemon-reload && systemctl enable mihomo-port-hops.service >/dev/null
  elif command -v rc-service >/dev/null 2>&1; then
    file=/etc/init.d/mihomo-port-hops
    [ ! -L "$file" ] || return 1
    [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_HOPS=1' "$file" || return 1
    cat >"$file" <<'EOF' || return 1
#!/sbin/openrc-run
# MH_MANAGER_HOPS=1
description="Mihomo UDP port hopping"
depend() { need net; after nftables; before mihomo; }
start() { /usr/local/bin/mh restore-hops; }
EOF
    chmod 755 "$file"
    rc-update add mihomo-port-hops default
  else return 1; fi
}
apply_udp_hops() {
  local meta=$1 restore=${2:-0} count existing=0 tmp marker="$ROOT/.port-hops"
  jq -e 'all(.nodes[]|select(.udp_hop!=null); .protocol=="hysteria2" and
    ([.udp_hop.start,.udp_hop.end,.backend_port]|all(.[];type=="number" and .==floor and .>=1 and .<=65535)) and
    .udp_hop.start<.udp_hop.end)' "$meta" >/dev/null || return 1
  count=$(jq '[.nodes[]|select(.udp_hop!=null)]|length' "$meta") || return 1
  if ! command -v nft >/dev/null 2>&1; then [ "$count" = 0 ]; return $?; fi
  if nft list table inet mh_port_hops >/dev/null 2>&1; then existing=1; fi
  [ "$count" != 0 ] || [ "$existing" != 0 ] || return 0
  [ ! -L "$marker" ] || return 1
  if [ "$existing" = 1 ] && ! grep -Fqx '# MH_MANAGER_HOPS=1' "$marker" 2>/dev/null; then
    say "错误：mh_port_hops 表不属于本管理器。" >&2; return 1
  fi
  if [ "$count" != 0 ] && [ "$restore" != 1 ]; then ensure_hop_service || return 1; fi
  tmp=$(mktemp "$MH_TMP/hops.XXXXXX") || return 1
  if [ "$existing" = 1 ]; then printf 'delete table inet mh_port_hops\n' >"$tmp"; fi
  if [ "$count" != 0 ]; then
    {
      printf 'table inet mh_port_hops {\n chain prerouting {\n type nat hook prerouting priority -100; policy accept;\n'
      jq -r '.nodes[]|select(.udp_hop!=null)|"udp dport \(.udp_hop.start)-\(.udp_hop.end) redirect to :\(.backend_port)"' "$meta"
      printf '}\n}\n'
    } >>"$tmp"
  fi
  printf '# MH_MANAGER_HOPS=1\n' >"$marker" || { rm -f "$tmp"; return 1; }
  if ! nft -c -f "$tmp" || ! nft -f "$tmp"; then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
}

install_cloudflared() {
  local target="$ROOT/cloudflared" arch tmp url digest
  [ ! -L "$target" ] || fail "cloudflared 文件是符号链接。"
  [ ! -x "$target" ] || return 0
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l|armv7) arch=arm ;; *) fail "不支持此架构。" ;; esac
  tmp=$(mktemp -d "$MH_TMP/cloudflared.XXXXXX")
  fetch -o "$tmp/release.json" https://api.github.com/repos/cloudflare/cloudflared/releases/latest
  url=$(jq -r --arg n "cloudflared-linux-$arch" '.assets[]|select(.name==$n)|.browser_download_url' "$tmp/release.json")
  digest=$(jq -r --arg n "cloudflared-linux-$arch" '.assets[]|select(.name==$n)|.digest//""' "$tmp/release.json")
  [[ "$url" == https://github.com/cloudflare/cloudflared/releases/download/* ]] && [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "cloudflared 官方下载信息无效。"
  fetch -o "$tmp/cloudflared" "$url"
  [ "$(sha256sum "$tmp/cloudflared"|awk '{print $1}')" = "${digest#sha256:}" ] || fail "cloudflared 校验失败。"
  atomic_install "$tmp/cloudflared" "$target" 755
  rm -rf "$tmp"
}
argo_service_action() {
  local action=$1 name=$2
  [[ "$name" =~ ^mh-argo-[a-f0-9]{16}$ ]] || fail "隧道服务名无效。"
  if [ -d /run/systemd/system ]; then systemctl "$action" "$name"
  else rc-service "$name" "$action" 9>&-; fi
}
argo_log_path() {
  if [ -d "$ROOT/$1.logs" ]; then printf '%s/%s.logs/cloudflared.log' "$ROOT" "$1"
  else printf '%s/%s.log' "$ROOT" "$1"; fi
}
remove_argo_service() {
  local name=$1 file
  [ -n "$name" ] || return 0
  [[ "$name" =~ ^mh-argo-[a-f0-9]{16}$ ]] || return 1
  for file in "/etc/systemd/system/$name.service" "/etc/init.d/$name"; do
    [ ! -L "$file" ] || return 1
    [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_ARGO=1' "$file" || return 1
  done
  if [ -d /run/systemd/system ]; then
    systemctl disable --now "$name" || return 1
    rm -f "/etc/systemd/system/$name.service"; systemctl daemon-reload
  else
    rc-service "$name" stop || return 1
    rc-update del "$name" default || return 1
    rm -f "/etc/init.d/$name"
  fi
  rm -f "$ROOT/$name.token" "$ROOT/$name.log"
  rm -rf -- "$ROOT/$name.logs"
}
add_argo() {
  check_ready; new_name
  local kind token domain service file args log attempt tmp
  say "[1] 临时隧道（重启后域名可能变化）  [2] 固定隧道（使用 Cloudflare Tunnel Token）"
  read -r -p "选择 [1]: " kind; kind=${kind:-1}
  case "$kind" in 1|2) ;; *) fail "隧道类型无效。" ;; esac
  ask_port tcp; check_port tcp "$PORT"; BIND=127.0.0.1
  service="mh-argo-$NODE_ID"
  install -d -m 700 "$ROOT/$service.logs"
  log=$(argo_log_path "$service")
  install_cloudflared
  if [ "$kind" = 2 ]; then
    read -r -p "固定隧道的公网域名: " domain; domain=${domain,,}
    domain_ok "$domain" || fail "域名无效。"
    say "请在 Cloudflare Tunnel 的 Public Hostname 中将 $domain 指向 http://127.0.0.1:$PORT。"
    read -r -s -p "Tunnel Token（不回显）: " token; printf '\n'
    [[ "$token" =~ ^[A-Za-z0-9_=+/-]+$ ]] || fail "Token 格式无效。"
    printf '%s' "$token" >"$ROOT/$service.token"; chmod 600 "$ROOT/$service.token"
    args="tunnel --config /dev/null --no-autoupdate --log-directory $ROOT/$service.logs run --token-file $ROOT/$service.token"
  else
    args="tunnel --config /dev/null --no-autoupdate --log-directory $ROOT/$service.logs --url http://127.0.0.1:$PORT"
  fi
  if [ -d /run/systemd/system ]; then
    file="/etc/systemd/system/$service.service"
    [ ! -e "$file" ] && [ ! -L "$file" ] || fail "隧道服务已存在。"
    printf '# MH_MANAGER_ARGO=1\n[Unit]\nDescription=Mihomo Argo tunnel\nAfter=network-online.target\n[Service]\nExecStart=%s/cloudflared %s\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\n' "$ROOT" "$args" >"$file"
    chmod 644 "$file"; systemctl daemon-reload; systemctl enable --now "$service"
  elif command -v rc-service >/dev/null 2>&1; then
    file="/etc/init.d/$service"
    [ ! -e "$file" ] && [ ! -L "$file" ] || fail "隧道服务已存在。"
    printf '#!/sbin/openrc-run\n# MH_MANAGER_ARGO=1\ncommand="%s/cloudflared"\ncommand_args="%s"\nsupervisor=supervise-daemon\nrespawn_delay=5\n' "$ROOT" "$args" >"$file"
    chmod 755 "$file"; rc-update add "$service" default; rc-service "$service" start 9>&-
  else fail "Argo 需要 systemd / OpenRC。"; fi
  # 后续节点提交失败时回收刚创建的隧道；已提交节点保留服务供修复。
  trap 'if ! jq -e --arg n "$NAME" '\''.nodes[]|select(.name==$n)'\'' "$META" >/dev/null; then remove_argo_service "$service" || true; fi' EXIT
  if [ "$kind" = 1 ]; then
    say "等待临时隧道域名（最多 45 秒）..."
    domain=
    for ((attempt=0; attempt<45; attempt++)); do
      domain=$(sed -n 's/.*https:\/\/\([a-z0-9-]*\.trycloudflare\.com\).*/\1/p' "$log" 2>/dev/null | head -n1) || true
      [ -z "$domain" ] || break
      sleep 1
    done
    domain_ok "$domain" || fail "无法取得临时域名，请查看 $log。"
  fi
  HOST=$domain; node_documents; node_vless
  local path; path=$(rand_path)
  json_edit "$LC" --arg path "$path" '.listeners[0] += {"allow-insecure":true,"ws-path":$path}'
  json_edit "$CC" --arg path "$path" --arg host "$domain" \
    '.proxies[0] += {port:443,tls:true,servername:$host,network:"ws","ws-opts":{path:$path,headers:{Host:$host}}}'
  local link; link=$(jq '.proxies[0]' "$CC" | client_link)
  ARGO_SERVICE=$service; ARGO_KIND=$kind
  commit_node vless-argo "$link" 443
  trap - EXIT
  ensure_argo_watchdog || say "隧道已建立，但域名自动同步任务安装失败，请通过 Argo 菜单手动同步。"
  say "隧道已交给系统服务守护。临时隧道重启后请在 Argo 菜单同步域名并重新导入链接。"
}
argo_menu() {
  local choice name service kind domain log nc nl nm link
  say "[1] 添加 VLESS WS 隧道  [2] 查看隧道  [3] 重启并同步域名  [4] 查看日志  [5] 同步当前域名  [0] 返回"
  read -r -p "选择: " choice
  case "$choice" in
    0) return 0 ;;
    1) add_argo; return 0 ;;
    2) jq -r '.nodes[]|select(.argo_service!=null)|"\(.name)  \(.argo_service)\n\(.link)"' "$META"; return 0 ;;
    3|4|5) ;;
    *) fail "选项无效。" ;;
  esac
  select_node || return 0; name=$SELECTED_NAME
  service=$(jq -r --arg name "$name" '.nodes[]|select(.name==$name)|.argo_service//""' "$META")
  [ -n "$service" ] || fail "该节点不是 Argo 隧道。"
  log=$(argo_log_path "$service")
  if [ "$choice" = 4 ]; then tail -n 100 -f "$log"; return 0; fi
  kind=$(jq -r --arg name "$name" '.nodes[]|select(.name==$name)|.argo_kind' "$META")
  if [ "$choice" = 3 ]; then
    : >"$log"
    argo_service_action restart "$service"
  fi
  [ "$kind" = 1 ] || { say "固定隧道已重启。"; return 0; }
  local attempt
  for ((attempt=0; attempt<45; attempt++)); do
    domain=$(sed -n 's/.*https:\/\/\([a-z0-9-]*\.trycloudflare\.com\).*/\1/p' "$log" | tail -n1)
    [ -z "$domain" ] || break
    sleep 1
  done
  domain_ok "$domain" || fail "尚未取得新域名，请稍后重试。"
  nl=$(mktemp "$MH_TMP/argo-clients.XXXXXX"); nm=$(mktemp "$MH_TMP/argo-meta.XXXXXX")
  MH_YQ_NAME="$name" MH_DOMAIN="$domain" yq \
    '(.proxies[]|select(.name==strenv(MH_YQ_NAME))) |= (.server=strenv(MH_DOMAIN)|.servername=strenv(MH_DOMAIN)|.ws-opts.headers.Host=strenv(MH_DOMAIN))' "$CLIENTS" >"$nl"
  link=$(MH_YQ_NAME="$name" yq -o=json '.proxies[]|select(.name==strenv(MH_YQ_NAME))' "$nl" | client_link)
  jq --arg name "$name" --arg link "$link" '(.nodes[]|select(.name==$name)).link=$link' "$META" >"$nm"
  apply_state "$CFG" "$nl" "$nm" no || fail "同步失败。"
  rm -f "$nl" "$nm"; say "$link"
}

ensure_argo_watchdog() {
  local file
  ensure_managed_command || return 1
  if [ -d /run/systemd/system ]; then
    for file in /etc/systemd/system/mihomo-argo-sync.service /etc/systemd/system/mihomo-argo-sync.timer; do
      [ ! -L "$file" ] || return 1
      [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_ARGO_SYNC=1' "$file" || return 1
    done
    cat >/etc/systemd/system/mihomo-argo-sync.service <<'EOF' || return 1
# MH_MANAGER_ARGO_SYNC=1
[Unit]
Description=Update Mihomo temporary tunnel domains
[Service]
Type=oneshot
ExecStart=/usr/local/bin/mh argo-sync
EOF
    cat >/etc/systemd/system/mihomo-argo-sync.timer <<'EOF' || return 1
# MH_MANAGER_ARGO_SYNC=1
[Unit]
Description=Synchronize Mihomo temporary tunnel domains
[Timer]
OnBootSec=60
OnUnitActiveSec=60
[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/mihomo-argo-sync.service /etc/systemd/system/mihomo-argo-sync.timer || return 1
    systemctl daemon-reload && systemctl enable --now mihomo-argo-sync.timer >/dev/null
  elif command -v rc-service >/dev/null 2>&1; then
    for file in /etc/init.d/mihomo-argo-sync "$ROOT/argo-sync-loop.sh"; do
      [ ! -L "$file" ] || return 1
      [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_ARGO_SYNC=1' "$file" || return 1
    done
    cat >"$ROOT/argo-sync-loop.sh" <<'EOF' || return 1
#!/usr/bin/env bash
# MH_MANAGER_ARGO_SYNC=1
while :; do /usr/local/bin/mh argo-sync; sleep 60; done
EOF
    printf '#!/sbin/openrc-run\n# MH_MANAGER_ARGO_SYNC=1\ncommand="/bin/bash"\ncommand_args="%s/argo-sync-loop.sh"\nsupervisor="supervise-daemon"\nrespawn_delay=5\n' "$ROOT" >/etc/init.d/mihomo-argo-sync || return 1
    chmod 700 "$ROOT/argo-sync-loop.sh" && chmod 755 /etc/init.d/mihomo-argo-sync || return 1
    rc-update add mihomo-argo-sync default && rc-service mihomo-argo-sync restart 9>&-
  else return 1; fi
}
sync_argo_domains() {
  local nl nm name service domain current link log changed=0
  jq -e '.nodes[]|select(.argo_kind=="1")' "$META" >/dev/null || return 0
  [ -x "$BIN" ] || command -v "$BIN" >/dev/null 2>&1 || return 0
  nl=$(mktemp "$MH_TMP/argo-sync-clients.XXXXXX"); nm=$(mktemp "$MH_TMP/argo-sync-meta.XXXXXX")
  cp "$CLIENTS" "$nl"; cp "$META" "$nm"
  while IFS=$'\t' read -r name service; do
    [[ "$service" =~ ^mh-argo-[a-f0-9]{16}$ ]] || continue
    log=$(argo_log_path "$service")
    [ -f "$log" ] || continue
    domain=$(sed -n 's/.*https:\/\/\([a-z0-9-]*\.trycloudflare\.com\).*/\1/p' "$log" | tail -n1)
    domain_ok "$domain" || continue
    current=$(MH_YQ_NAME="$name" yq -r '.proxies[]|select(.name==strenv(MH_YQ_NAME))|.server' "$nl")
    [ "$current" != "$domain" ] || continue
    MH_YQ_NAME="$name" MH_DOMAIN="$domain" yq -i \
      '(.proxies[]|select(.name==strenv(MH_YQ_NAME))) |= (.server=strenv(MH_DOMAIN)|.servername=strenv(MH_DOMAIN)|.ws-opts.headers.Host=strenv(MH_DOMAIN))' "$nl"
    link=$(MH_YQ_NAME="$name" yq -o=json '.proxies[]|select(.name==strenv(MH_YQ_NAME))' "$nl" | client_link)
    jq --arg name "$name" --arg link "$link" '(.nodes[]|select(.name==$name)).link=$link' "$nm" >"$nm.next"
    mv "$nm.next" "$nm"; changed=1
  done < <(jq -r '.nodes[]|select(.argo_kind=="1")|[.name,.argo_service]|@tsv' "$META")
  if [ "$changed" = 1 ]; then apply_state "$CFG" "$nl" "$nm" no || fail "Argo 域名同步失败。"; fi
  rm -f "$nl" "$nm"
}

select_node() {
  local choice count
  count=$(jq '.nodes|length' "$META")
  [ "$count" -gt 0 ] || { say "当前没有节点。"; return 1; }
  jq -r '.nodes|to_entries[]|"[\(.key+1)] \(.value.name)  \(.value.protocol)  公网:\(.value.public_port)  后端:\(.value.backend_port)"' "$META"
  say "[0] 返回"
  read -r -p "节点序号: " choice || return 1
  [ "$choice" != 0 ] || return 1
  [[ "$choice" =~ ^[0-9]{1,6}$ ]] && ((10#$choice>=1 && 10#$choice<=count)) || fail "序号无效。"
  SELECTED_NAME=$(jq -r --argjson i "$((10#$choice-1))" '.nodes[$i].name' "$META")
}
modify_port() {
  check_ready; select_node || return 0
  local node protocol oldroute oldport oldbackend oldcfg oldclients oldmeta client link preferred attempts
  NAME=$SELECTED_NAME
  node=$(jq -c --arg name "$NAME" '.nodes[]|select(.name==$name)' "$META")
  protocol=$(jq -r .protocol <<<"$node")
  [ "$(jq -r '.argo_service//""' <<<"$node")" = "" ] || fail "Argo 的公网入口固定为 443；后端由隧道管理，不单独修改。"
  oldroute=$(jq -r '.route//"none"' <<<"$node")
  oldport=$(jq -r .public_port <<<"$node"); oldbackend=$(jq -r .backend_port <<<"$node")
  ROUTE_TAG=$(jq -r '.route_tag//.name' <<<"$node")
  SNI_NAME=$(jq -r '.sni//""' <<<"$node")
  EXTRA_SNI=$(jq -r '.extra_sni//""' <<<"$node")
  local proto=tcp
  case "$protocol" in hysteria2|tuic) proto=udp ;; shadowsocks|socks|socks5) proto=both ;; esac
  ask_port "$proto" "$oldport"
  [ "$PORT" != "$oldport" ] || { say "端口未改变。"; return 0; }
  local newpublic=$PORT
  ROUTE=none; BIND=$(default_bind)
  client=$(MH_YQ_NAME="$NAME" yq -o=json '.proxies[]|select(.name==strenv(MH_YQ_NAME))' "$CLIENTS")
  if [ "$PORT" = 443 ] && [[ "$protocol" =~ ^(vless-reality|vless-xhttp|vless-ws|vless-grpc|trojan-ws|anytls)$ ]]; then
    ROUTE=tls; [ "$protocol" != vless-reality ] || ROUTE=reality
    SNI_NAME=$(jq -r '.servername//.sni//""' <<<"$client")
    domain_ok "$SNI_NAME" || fail "共享 443 需要有效 SNI 域名。"
    [ "$(sni api-version)" = 1 ] || fail "SNI API 不兼容，请更新整套脚本。"
    sni prepare; sni check-sni-free "$SNI_NAME"
    [ -z "$EXTRA_SNI" ] || sni check-sni-free "$EXTRA_SNI"
    preferred=2543
    for ((attempts=0; attempts<100; attempts++)); do
      PORT=$(sni allocate-backend "$preferred")
      if ! config_port_used tcp "$PORT"; then break; fi
      preferred=$((PORT+1)); PORT=
    done
    [ -n "$PORT" ] || fail "无法分配后端端口。"
    BIND=127.0.0.1
  else check_port "$proto" "$PORT"; fi
  begin_files
  MH_YQ_NAME="$NAME" MH_PORT="$PORT" MH_BIND="$BIND" yq \
    '(.listeners[]|select(.name==strenv(MH_YQ_NAME))) |= (.port=(strenv(MH_PORT)|tonumber)|.listen=strenv(MH_BIND))' "$CFG" >"$NC"
  MH_YQ_NAME="$NAME" MH_PORT="$newpublic" yq \
    '(.proxies[]|select(.name==strenv(MH_YQ_NAME))).port=(strenv(MH_PORT)|tonumber)' "$CLIENTS" >"$CL"
  if [ -n "$EXTRA_SNI" ]; then
    MH_YQ_NAME="$NAME" MH_PORT="$newpublic" yq -i \
      '(.proxies[]|select(.name==strenv(MH_YQ_NAME))).xhttp-opts.download-settings.port=(strenv(MH_PORT)|tonumber)' "$CL"
  fi
  link=$(MH_YQ_NAME="$NAME" yq -o=json '.proxies[]|select(.name==strenv(MH_YQ_NAME))' "$CL" | client_link)
  jq --arg name "$NAME" --arg route "$ROUTE" --arg sni "$SNI_NAME" --arg link "$link" --argjson public "$newpublic" --argjson backend "$PORT" \
    '(.nodes[]|select(.name==$name)) += {route:$route,sni:$sni,link:$link,public_port:$public,backend_port:$backend}' "$META" >"$NM"
  oldcfg=$(mktemp "$MH_TMP/port-config.XXXXXX"); oldclients=$(mktemp "$MH_TMP/port-clients.XXXXXX"); oldmeta=$(mktemp "$MH_TMP/port-meta.XXXXXX")
  cp "$CFG" "$oldcfg"; cp "$CLIENTS" "$oldclients"; cp "$META" "$oldmeta"
  apply_state "$NC" "$CL" "$NM" || fail "端口修改失败。"
  local route_status=0
  if [ "$ROUTE" != none ]; then register_routes || route_status=$?
  elif [ "$oldroute" != none ]; then unregister_routes "$oldroute" "$ROUTE_TAG" "$EXTRA_SNI" "$oldbackend" || route_status=$?; fi
  if [ "$route_status" != 0 ]; then
    apply_state "$oldcfg" "$oldclients" "$oldmeta" || fail "恢复失败，请保留 $oldcfg、$oldclients、$oldmeta。"
    [ "$route_status" != 2 ] || say "SNI 路由恢复不完整，请执行 sb sni-router status 检查。"
    fail "SNI 更新失败，已恢复旧节点配置。"
  fi
  rm -f "$LC" "$CC" "$NC" "$CL" "$NM" "$oldcfg" "$oldclients" "$oldmeta"
  say "公网端口已更新为 $newpublic，后端为 $BIND:$PORT。请重新导入："
  say "$link"
}
service_action() {
  local action=$1
  [ -x "$BIN" ] || fail "尚未安装 Mihomo。"
  if [ "$action" = restart ] || [ "$action" = start ]; then
    check_ready; validate_state "$CFG" "$CLIENTS" "$META" || fail "配置检查失败。"
    prepare_runtime_env
    [ ! -d /run/systemd/system ] || systemctl daemon-reload
  fi
  if [ -d /run/systemd/system ]; then
    if [ "$action" = logs ]; then journalctl -u "$SERVICE" -n 100 -f
    else systemctl "$action" "$SERVICE" --no-pager; fi
  elif command -v rc-service >/dev/null 2>&1; then
    if [ "$action" = logs ]; then tail -n 100 -f "$ROOT/mihomo.log"
    else rc-service "$SERVICE" "$action" 9>&-; fi
  else fail "仅支持 systemd / OpenRC。"; fi
  case "$action" in start|restart) wait_listeners ;; esac
}
dns_menu() {
  check_ready
  local choice servers nc
  yq '.dns // {}' "$CFG"
  say "[1] 系统 DNS  [2] 自定义 DNS（UDP/TLS/HTTPS，空格分隔）  [0] 返回"
  read -r -p "选择: " choice
  nc=$(mktemp "$MH_TMP/dns.XXXXXX")
  case "$choice" in
    1) yq 'del(.dns)' "$CFG" >"$nc" ;;
    2)
      read -r -p "DNS 地址 [https://1.1.1.1/dns-query https://8.8.8.8/dns-query]: " servers
      servers=${servers:-https://1.1.1.1/dns-query https://8.8.8.8/dns-query}
      MH_DNS="$servers" yq '.dns={"enable":true,"ipv6":true,"enhanced-mode":"redir-host",
        "default-nameserver":["1.1.1.1","8.8.8.8"],"nameserver":(strenv(MH_DNS)|split(" ")|map(select(.!="")))}' "$CFG" >"$nc" ;;
    *) rm -f "$nc"; return 0 ;;
  esac
  apply_state "$nc" "$CLIENTS" "$META" || fail "DNS 设置未生效。"
  rm -f "$nc"; say "DNS 设置已应用。"
}
schedule_menu() {
  local choice time hour minute service=/etc/systemd/system/mihomo-restart.service timer=/etc/systemd/system/mihomo-restart.timer
  say "[1] 设置每日重启  [2] 查看  [3] 取消  [0] 返回"
  read -r -p "选择: " choice
  case "$choice" in
    0) return 0 ;;
    2)
      if [ -d /run/systemd/system ]; then systemctl list-timers mihomo-restart.timer --no-pager
      elif [ -f /etc/init.d/mihomo-restart ]; then rc-service mihomo-restart status
      else say "未设置。"; fi
      return 0 ;;
    1|3) ;;
    *) fail "选项无效。" ;;
  esac
  if [ -d /run/systemd/system ]; then
    local file
    for file in "$service" "$timer"; do
      [ ! -L "$file" ] || fail "定时文件为符号链接。"
      [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_TIMER=1' "$file" || fail "定时文件不属于 mh。"
    done
    if [ "$choice" = 3 ]; then
      systemctl disable --now mihomo-restart.timer 2>/dev/null || true
      rm -f "$service" "$timer"; systemctl daemon-reload; return 0
    fi
  else
    command -v rc-service >/dev/null 2>&1 || fail "需要 systemd / OpenRC。"
    for file in /etc/init.d/mihomo-restart "$ROOT/restart-timer.sh"; do
      [ ! -L "$file" ] || fail "定时文件为符号链接。"
      [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_TIMER=1' "$file" || fail "定时文件不属于 mh。"
    done
    if [ "$choice" = 3 ]; then
      rc-service mihomo-restart stop 2>/dev/null || true
      rc-update del mihomo-restart default 2>/dev/null || true
      rm -f /etc/init.d/mihomo-restart "$ROOT/restart-timer.sh"; return 0
    fi
  fi
  read -r -p "服务器时区每日重启时间 [04:30]: " time; time=${time:-04:30}
  [[ "$time" =~ ^([0-1]?[0-9]|2[0-3]):([0-5][0-9])$ ]] || fail "时间格式无效。"
  hour=$((10#${BASH_REMATCH[1]})); minute=$((10#${BASH_REMATCH[2]}))
  printf -v time '%02d:%02d' "$hour" "$minute"
  if [ -d /run/systemd/system ]; then
    printf '# MH_MANAGER_TIMER=1\n[Unit]\nDescription=Mihomo scheduled restart\n[Service]\nType=oneshot\nExecStart=%s restart mihomo\n' "$(command -v systemctl)" >"$service"
    printf '# MH_MANAGER_TIMER=1\n[Unit]\nDescription=Mihomo daily restart\n[Timer]\nOnCalendar=*-*-* %s:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' "$time" >"$timer"
    chmod 644 "$service" "$timer"
    systemctl daemon-reload; systemctl enable --now mihomo-restart.timer; systemctl restart mihomo-restart.timer
  else
    cat >"$ROOT/restart-timer.sh" <<'EOF'
#!/usr/bin/env bash
# MH_MANAGER_TIMER=1
target=$1
last_day=
while :; do
  today=$(date +%F)
  if [ "$(date +%H:%M)" = "$target" ] && [ "$last_day" != "$today" ]; then
    rc-service mihomo restart
    last_day=$today
  fi
  sleep 20
done
EOF
    printf '#!/sbin/openrc-run\n# MH_MANAGER_TIMER=1\ncommand="/bin/bash"\ncommand_args="%s/restart-timer.sh %s"\nsupervisor="supervise-daemon"\nrespawn_delay=5\n' "$ROOT" "$time" >/etc/init.d/mihomo-restart
    chmod 700 "$ROOT/restart-timer.sh"; chmod 755 /etc/init.d/mihomo-restart
    rc-update add mihomo-restart default
    rc-service mihomo-restart restart 9>&-
  fi
  say "已设置每天 $time（服务器时区）重启。"
}
sync_time() {
  if command -v timedatectl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    timedatectl set-ntp true; timedatectl status
  elif command -v chronyc >/dev/null 2>&1; then chronyc makestep
  elif command -v ntpd >/dev/null 2>&1; then ntpd -q -p pool.ntp.org
  else fail "系统没有可用 NTP 客户端，请安装 chrony。"; fi
}
forward_add() {
  check_ready
  local protocol target target_port name listener nc nm
  say "端口转发透传 TCP/UDP 数据，不解析落地协议。HY2/TUIC 请选择 UDP。"
  read -r -p "网络 [tcp/udp/both，默认 both]: " protocol; protocol=${protocol:-both}
  case "$protocol" in tcp|udp|both) ;; *) fail "网络无效。" ;; esac
  ask_port "$protocol"; check_port "$protocol" "$PORT"
  read -r -p "目标域名/IP: " target; target=$(normalize_host "$target"); host_ok "$target" || fail "目标地址无效。"
  read -r -p "目标端口: " target_port; port_ok "$target_port" || fail "目标端口无效。"
  if [[ "$target" = 127.0.0.1 || "$target" = ::1 || "$target" = localhost ]] && [ "$PORT" = "$target_port" ]; then fail "不能转发到自身监听端口。"; fi
  name=mh-forward-$(rand_text 12)
  listener=$(jq -n --arg name "$name" --arg bind "$(default_bind)" --argjson port "$PORT" --arg target "$(uri_host "$target"):$((10#$target_port))" --arg net "$protocol" \
    '{name:$name,type:"tunnel",listen:$bind,port:$port,network:(if $net=="both" then ["tcp","udp"] else [$net] end),target:$target,proxy:"DIRECT"}')
  nc=$(mktemp "$MH_TMP/forward.XXXXXX"); nm=$(mktemp "$MH_TMP/forward-meta.XXXXXX")
  MH_LISTENER="$listener" yq '.listeners += [(strenv(MH_LISTENER)|from_json)]' "$CFG" >"$nc"
  jq --argjson listener "$listener" '.forwards=(.forwards//[])+[$listener]' "$META" >"$nm"
  apply_state "$nc" "$CLIENTS" "$nm" || fail "端口转发创建失败。"
  rm -f "$nc" "$nm"; say "已建立 $protocol :$PORT → $target:$target_port。"
}
forward_remove() {
  check_ready
  local count choice name nc nm
  count=$(jq '(.forwards//[])|length' "$META")
  [ "$count" -gt 0 ] || { say "没有端口转发。"; return 0; }
  jq -r '.forwards|to_entries[]|"[\(.key+1)] \(.value.network|join("/")) :\(.value.port) → \(.value.target)"' "$META"
  read -r -p "输入要删除的序号，0 返回: " choice
  [ "$choice" != 0 ] || return 0
  [[ "$choice" =~ ^[0-9]{1,6}$ ]] && ((10#$choice>=1 && 10#$choice<=count)) || fail "序号无效。"
  name=$(jq -r --argjson index "$((10#$choice-1))" '.forwards[$index].name' "$META")
  nc=$(mktemp "$MH_TMP/forward.XXXXXX"); nm=$(mktemp "$MH_TMP/forward-meta.XXXXXX")
  MH_YQ_NAME="$name" yq 'del(.listeners[]|select(.name==strenv(MH_YQ_NAME)))' "$CFG" >"$nc"
  jq --arg name "$name" 'del(.forwards[]|select(.name==$name))' "$META" >"$nm"
  apply_state "$nc" "$CLIENTS" "$nm" || fail "删除转发失败。"
  rm -f "$nc" "$nm"; say "端口转发已删除。"
}
run_action() {
  # 不把业务函数放进 if/||；Bash 会因此关闭函数内部的 errexit。
  # 子进程继承父菜单的文件锁，失败只结束本次操作，不退出菜单。
  set +e
  ( set -Ee; "$@" )
  local status=$?
  set -e
  [ "$status" = 0 ] || say "本次操作未完成（状态 $status），已返回菜单。"
  return 0
}

pause_return() {
  local prompt=${1:-按任意键返回...}
  printf '\n'
  if [ -t 0 ]; then read -r -n 1 -s -p "$prompt" || true; fi
  printf '\n'
}
ensure_core_for_add() {
  local answer
  if [ -x "$BIN" ]; then
    if [ -d /run/systemd/system ] && [ ! -f /etc/systemd/system/mihomo.service ]; then install_service
    elif command -v rc-service >/dev/null 2>&1 && [ ! -f /etc/init.d/mihomo ]; then install_service; fi
    return 0
  fi
  say "尚未检测到 Mihomo 内核。添加节点前需要先安装最新稳定版内核和系统服务。"
  read -r -p "是否现在自动安装？[Y/n]: " answer
  if [[ "$answer" = n || "$answer" = N ]]; then
    say "已取消安装，返回 Mihomo 主菜单。"
    return 1
  fi
  install_core
  install_service
  [ -x "$BIN" ] || fail "Mihomo 内核安装后仍不可用。"
  say "Mihomo 最新稳定版内核和服务已就绪，继续进入添加节点。"
}
batch_nodes() {
  local choices=${1:-} choice
  [ -n "$choices" ] || read -r -p "协议编号（逗号或空格分隔，如 1,6,8）: " choices
  choices=${choices//,/ }
  local -a ids
  read -r -a ids <<<"$choices"
  [ "${#ids[@]}" -gt 0 ] || return 0
  for choice in "${ids[@]}"; do
    case "$choice" in 1|5|6|7|8|9|10) ;; *) fail "批量支持 1、5–10；CDN/WS/gRPC/XHTTP 请使用单节点向导。" ;; esac
  done
  say "将按顺序打开各协议向导，每个节点独立校验并提交；单个失败会保留已完成节点。"
  for choice in "${ids[@]}"; do run_action add_by_id "$choice"; done
}
add_by_id() {
  case "$1" in
    1) add_reality ;; 2) add_tls_transport vless-ws ;; 3) add_tls_transport trojan-ws ;;
    4) add_tls_transport vless-grpc ;; 5) add_anytls ;; 6) add_quic hysteria2 ;;
    7) add_quic tuic ;; 8) add_plain shadowsocks ;; 9) add_plain vless-tcp ;;
    10) add_plain socks ;; 11) batch_nodes ;; 12) add_xhttp ;;
    0) return 0 ;; *) fail "协议编号无效。" ;;
  esac
}
add_node_menu() {
  local choice
  say ""
  say "════════════ Mihomo 添加节点 ════════════"
  say "[1] VLESS (Vision + Reality)"
  say "[2] VLESS (WebSocket + TLS)"
  say "[3] Trojan (WebSocket + TLS)"
  say "[4] VLESS (gRPC + TLS)"
  say "[5] AnyTLS"
  say "[6] Hysteria2             [7] TUIC v5"
  say "[8] Shadowsocks           [9] VLESS TCP"
  say "[10] SOCKS5              [11] 批量创建"
  say "[12] VLESS (XHTTP + TLS / CDN / 上下行分离)"
  say "[0] 返回"
  read -r -p "选择协议 [0-12]: " choice || return 0
  if [[ "$choice" == *','* || "$choice" == *' '* ]]; then batch_nodes "$choice"
  else add_by_id "$choice"; fi
}
update_scripts() {
  if [ "${PROXYALL_MANAGED:-0}" = 1 ]; then
    say "请返回 proxyall 主菜单选择 [4] 检查脚本更新；统一入口持有更新锁。"
  elif [ -x /usr/local/bin/proxyall ]; then
    /usr/local/bin/proxyall --update 9>&-
    say "更新后请退出当前 mh 菜单再重新进入。"
  else fail "请使用同仓库的 proxyall --install 安装整套脚本。"; fi
}
uninstall_mihomo() {
  check_ready
  local answer name file argo
  say "将删除 Mihomo 节点、专属 SNI 路由、Argo 隧道、转发、服务和核心。"
  say "仍被 Emby/sing-box 引用的证书由共享证书组件保留。"
  read -r -p "输入 UNINSTALL 确认: " answer
  [ "$answer" = UNINSTALL ] || return 0
  [ "$ROOT" = /usr/local/etc/mihomo ] && [ "$BIN" = /usr/local/bin/mihomo ] || fail "卸载目录校验失败。"
  grep -Fqx "$MARKER" "$STATE_MARKER" || fail "目录所有权标记无效。"
  for file in /etc/systemd/system/mihomo.service /etc/init.d/mihomo; do
    [ ! -L "$file" ] || fail "服务文件是符号链接。"
    [ ! -e "$file" ] || grep -Fqx '# MH_MANAGER_MANAGED_SERVICE=1' "$file" || fail "请先通过安装/更新迁移旧服务文件。"
  done
  local backup; backup=$(mktemp -d /root/mihomo-uninstall.XXXXXX)
  cp -a "$ROOT/." "$backup/"
  say "卸载前的节点与配置备份：$backup"
  while IFS= read -r name; do delete_node "$name" yes; done < <(jq -r '.nodes[].name' "$META")
  if [ -d /run/systemd/system ]; then
    systemctl disable --now mihomo
    if grep -Fqx '# MH_MANAGER_ARGO_SYNC=1' /etc/systemd/system/mihomo-argo-sync.timer 2>/dev/null; then
      systemctl disable --now mihomo-argo-sync.timer
      rm -f /etc/systemd/system/mihomo-argo-sync.timer /etc/systemd/system/mihomo-argo-sync.service
    fi
    if grep -Fqx '# MH_MANAGER_HOPS=1' /etc/systemd/system/mihomo-port-hops.service 2>/dev/null; then
      systemctl disable --now mihomo-port-hops.service
      rm -f /etc/systemd/system/mihomo-port-hops.service
    fi
    if grep -Fqx '# MH_MANAGER_TIMER=1' /etc/systemd/system/mihomo-restart.timer 2>/dev/null; then
      systemctl disable --now mihomo-restart.timer
      rm -f /etc/systemd/system/mihomo-restart.timer /etc/systemd/system/mihomo-restart.service
    fi
    rm -f /etc/systemd/system/mihomo.service
    if grep -Fqx '# MH_MANAGER_PATHS=1' /etc/systemd/system/mihomo.service.d/20-mh-paths.conf 2>/dev/null; then
      rm -f /etc/systemd/system/mihomo.service.d/20-mh-paths.conf
      rmdir /etc/systemd/system/mihomo.service.d 2>/dev/null || true
    fi
    systemctl daemon-reload
  else
    rc-service mihomo stop; rc-update del mihomo default
    rm -f /etc/init.d/mihomo
    if grep -Fqx '# MH_MANAGER_ARGO_SYNC=1' /etc/init.d/mihomo-argo-sync 2>/dev/null; then
      rc-service mihomo-argo-sync stop; rc-update del mihomo-argo-sync default
      rm -f /etc/init.d/mihomo-argo-sync
    fi
    if grep -Fqx '# MH_MANAGER_HOPS=1' /etc/init.d/mihomo-port-hops 2>/dev/null; then
      rc-service mihomo-port-hops stop; rc-update del mihomo-port-hops default
      rm -f /etc/init.d/mihomo-port-hops
    fi
    if grep -Fqx '# MH_MANAGER_TIMER=1' /etc/init.d/mihomo-restart 2>/dev/null; then
      rc-service mihomo-restart stop; rc-update del mihomo-restart default
      rm -f /etc/init.d/mihomo-restart
    fi
  fi
  rm -f "$BIN"
  rm -rf -- "$ROOT"
  if grep -Fqx '# MH_MANAGER_MANAGED_COMMAND=1' /usr/local/bin/mh 2>/dev/null && [ ! -L /usr/local/bin/mh ]; then rm -f /usr/local/bin/mh; fi
  say "Mihomo 已卸载；配置备份：$backup。"
}
menu() {
  local choice out version status
  while :; do
    version=未安装; status=未安装
    if [ -x "$BIN" ]; then
      version=$("$BIN" -v); version=${version%%$'\n'*}; status=已停止
      if [ -d /run/systemd/system ]; then
        if systemctl is-active --quiet "$SERVICE"; then status=运行中; fi
      elif command -v rc-service >/dev/null 2>&1; then
        if rc-service "$SERVICE" status >/dev/null 2>&1; then status=运行中; fi
      fi
    fi
    printf '\n════════════ Mihomo 管理 v%s ════════════\n' "$MH_VERSION"
    say "$version | $status"
    say "【节点管理】"
    say "[1] 添加节点              [2] Argo 隧道节点"
    say "[3] 查看节点链接          [4] 删除节点"
    say "[5] 修改节点端口"
    say "【服务控制】"
    say "[6] 启动/重启服务         [7] 停止服务"
    say "[8] 查看运行状态          [9] 实时日志"
    say "[10] 定时重启             [11] 同步系统时间"
    say "【配置与更新】"
    say "[12] 检查配置/SNI         [13] 更新配套脚本"
    say "[14] DNS 设置"
    say "【核心管理】"
    say "[15] 安装/更新 Mihomo     [16] 卸载 Mihomo"
    say "【进阶功能】"
    say "[17] 落地/中转/第三方节点导入/端口转发"
    say "[18] 导出链接或 YAML"
    say "[0] 返回 proxyall / 退出"
    read -r -p "请选择 [0-18]: " choice || return 0
    case "$choice" in
      1) run_action add_with_core ;;
      2) run_action argo_with_core ;;
      3) run_action list_nodes ;;
      4) run_action delete_node ;;
      5) run_action modify_port ;;
      6) run_action service_action restart ;;
      7) run_action service_action stop ;;
      8) run_action service_action status ;;
      9) run_action service_action logs ;;
      10) run_action schedule_menu ;;
      11) run_action sync_time ;;
      12) run_action check_config ;;
      13) run_action update_scripts ;;
      14) run_action dns_menu ;;
      15) run_action install_all ;;
      16) run_action uninstall_mihomo; [ -d "$ROOT" ] || return 0 ;;
      17) run_action relay_menu ;;
      18) read -r -p "导出文件（.yaml 完整配置；默认 /root/mihomo-nodes.txt）: " out; run_action export_nodes "$out" ;;
      0) return 0 ;;
      *) say "无效选择。" ;;
    esac
    pause_return
  done
}
add_with_core() { ensure_core_for_add; add_node_menu; }
argo_with_core() { ensure_core_for_add; argo_menu; }
install_all() { install_core; install_service; }
check_config() {
  check_ready
  validate_state "$CFG" "$CLIENTS" "$META" || fail "配置不一致。"
  if jq -e '.nodes[]|select(.route!="none")' "$META" >/dev/null; then sni check; fi
  say "服务端、客户端及节点元数据检查通过。"
}
help_text() {
  say "mh v$MH_VERSION：Mihomo VPS 节点管理"
  say "用法：mh [menu|install|list|export [文件]|check|start|restart|stop|status|logs|uninstall|--version]"
  say "菜单编号与 sb 对齐；添加节点 [12] 为 XHTTP。export .yaml 保留完整客户端参数。"
}
main() {
  case "${1:-}" in --version) say "$MH_VERSION"; return 0 ;; -h|--help) help_text; return 0 ;; esac
  root_only
  [ "$(uname -s)" = Linux ] || fail "此脚本用于 Linux VPS。"
  if [ "${1:-}" = argo-sync ]; then
    grep -Fqx "$MARKER" "$STATE_MARKER" 2>/dev/null && [ -d "$MH_TMP" ] || return 0
    exec 9>"$ROOT/manager.lock"
    flock -n 9 || return 0
    MH_LOCKED=1
    sync_argo_domains
    return $?
  fi
  if [ "${1:-}" = restore-hops ]; then
    grep -Fqx "$MARKER" "$STATE_MARKER" || fail "Mihomo 管理状态无效。"
    need jq; need nft
    install -d -m 700 "$MH_TMP"
    lock_state
    apply_udp_hops "$META" 1
    return $?
  fi
  case "${1:-}" in
    install) install_all; return 0 ;;
    ""|menu|list|export|check|start|restart|stop|status|logs|uninstall) ;;
    *) help_text; return 2 ;;
  esac
  install_base_deps; install_yq; check_runtime_deps; init; lock_state
  case "${1:-}" in
    ""|menu) menu ;;
    list) list_nodes ;;
    export) export_nodes "${2:-}" ;;
    check) check_config ;;
    uninstall) uninstall_mihomo ;;
    *) service_action "$1" ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
