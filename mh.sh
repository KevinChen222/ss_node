#!/usr/bin/env bash
# MH_MANAGER_MANAGED_COMMAND=1
# Mihomo server-side node manager used by proxyall.
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
uuid() { cat /proc/sys/kernel/random/uuid; }
uri_host() {
  if [[ "$1" == *:* ]] && [[ "$1" != \[*\] ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}
normalize_host() {
  if [[ "$1" =~ ^\[([^]]+)\]$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf '%s' "$1"; fi
}
url_encode() { printf '%s' "$1" | jq -sRr @uri; }

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
  for command_name in jq yq gzip sha256sum install mktemp shuf base64 od ss flock; do
    need "$command_name"
  done
  check_yq
}
install_base_deps() {
  local command_name missing=0
  for command_name in curl jq gzip sha256sum install mktemp shuf base64 od ss flock; do
    command -v "$command_name" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" = 0 ] && return 0
  say "正在安装 Mihomo 管理依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates jq gzip coreutils util-linux iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates jq gzip coreutils util-linux iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates jq gzip coreutils util-linux iproute
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates jq gzip coreutils util-linux iproute2
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
  init
  lock_state
  check_runtime_deps
  [ -x "$BIN" ] || fail "请先安装 mihomo 核心。"
}
check_port() {
  local proto=$1 port=$2
  if config_port_used "$proto" "$port"; then fail "Mihomo 配置已使用 $proto 端口：$port"; fi
  if [ "$proto" = tcp ]; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"; then fail "TCP 端口已占用：$port"; fi
  else
    if ss -lnu 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"; then fail "UDP 端口已占用：$port"; fi
  fi
  return 0
}
config_port_used() {
  local proto=$1 port=$2
  MH_YQ_PORT="$port" yq eval -e '.listeners[]? | select(.port == (strenv(MH_YQ_PORT) | tonumber))' "$CFG" >/dev/null 2>&1
}
reload_service() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE" >/dev/null || return 1
    if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
      systemctl restart "$SERVICE"
    else
      systemctl start "$SERVICE"
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add "$SERVICE" default >/dev/null 2>&1 || return 1
    if rc-service "$SERVICE" status >/dev/null 2>&1; then
      rc-service "$SERVICE" restart
    else
      rc-service "$SERVICE" start
    fi
  else
    say "错误：仅支持 systemd 或 OpenRC。" >&2
    return 1
  fi
}
apply_state() {
  local newcfg=$1 newclients=$2 newmeta=$3 backup rollback_ok=1
  if ! "$BIN" -t -f "$newcfg" >/dev/null || ! "$BIN" -t -f "$newclients" >/dev/null; then
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
     ! reload_service; then
    atomic_install "$backup/config.yaml" "$CFG" 600 || rollback_ok=0
    atomic_install "$backup/clients.yaml" "$CLIENTS" 600 || rollback_ok=0
    atomic_install "$backup/nodes.json" "$META" 600 || rollback_ok=0
    if [ "$rollback_ok" = 1 ] && ! reload_service; then rollback_ok=0; fi
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
  IFS= read -r -p "节点名称: " NAME
  [ -n "$NAME" ] || fail "名称不能为空。"
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
  local asked preferred attempts
  read -r -p "监听端口（留空随机；443 可按 SNI 共用）: " asked
  [ -n "$asked" ] || asked=$(rand_port)
  [[ "$asked" =~ ^[0-9]+$ ]] && [ "$asked" -le 65535 ] && [ "$asked" -ge 1 ] || fail "端口无效。"
  BIND=0.0.0.0; PORT=$asked; ROUTE=none; SNI_NAME=; EXTRA_SNI=
  if [ "$asked" = 443 ]; then
    [ "$(sni api-version)" = 1 ] || fail "当前 sb 的 SNI 路由 API 不兼容，请先用 proxyall 更新整套脚本。"
    sni prepare
    read -r -p "分流域名/SNI: " SNI_NAME
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
    domain_ok "$SNI_NAME" || fail "域名无效。"
  else
    ROUTE=reality
  fi
}
get_cert() {
  local choice output domain automatic=1
  [ "$#" -ge 1 ] || fail "未提供证书域名。"
  for domain in "$@"; do domain_ok "$domain" || automatic=0; done
  if [ "$automatic" = 1 ]; then
    say "证书方式："
    say "  [1] 自动申请/续期 Let's Encrypt（默认）"
    say "  [2] 使用已有证书"
    read -r -p "请选择 [1-2]: " choice
    [ -n "$choice" ] || choice=1
  else
    say "服务器地址包含 IP 或无效域名，无法自动申请公网证书，请使用已有证书。"
    choice=2
  fi
  case "$choice" in
    1)
      [ -x "$SNI" ] || fail "未找到证书管理组件 $SNI；请先安装或更新 proxyall。"
      output=$("$SNI" issue-mihomo-certificate "$@" 9>&-) || fail "证书申请失败；请确认域名解析正确、TCP 80 可访问，且 CDN 未拦截 ACME challenge。"
      CERT=$(printf '%s\n' "$output" | sed -n 's/^MH_CERT_PATH=//p' | tail -n 1)
      KEY=$(printf '%s\n' "$output" | sed -n 's/^MH_KEY_PATH=//p' | tail -n 1)
      [ -r "$CERT" ] && [ -r "$KEY" ] || fail "证书已签发，但返回的证书路径无效。"
      say "证书已就绪，并已配置自动续期：$CERT"
      ;;
    2)
      read -r -p "证书路径（须覆盖全部节点域名）: " CERT
      read -r -p "私钥路径: " KEY
      [ -r "$CERT" ] && [ -r "$KEY" ] || fail "证书或私钥不可读。"
      ;;
    *) fail "证书方式无效。" ;;
  esac
}
direct_domain() {
  HOST=$SNI_NAME
  if [ -z "$HOST" ]; then
    read -r -p "服务器域名/IP（用于客户端导出）: " HOST
    [ -n "$HOST" ] || fail "地址不能为空。"
  fi
  HOST=$(normalize_host "$HOST")
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
  local protocol=$1 link=$2 public=$3 route_status
  MH_YQ_NAME="$NAME" yq eval -i '.listeners[0].name = strenv(MH_YQ_NAME)' "$LC"
  MH_YQ_NAME="$NAME" yq eval -i '.proxies[0].name = strenv(MH_YQ_NAME)' "$CC"
  yq eval-all 'select(fileIndex == 0) *+ {"listeners": (select(fileIndex == 1).listeners)}' "$CFG" "$LC" >"$NC"
  yq eval-all 'select(fileIndex == 0) *+ {"proxies": (select(fileIndex == 1).proxies)}' "$CLIENTS" "$CC" >"$CL"
  jq --arg n "$NAME" --arg p "$protocol" --arg l "$link" --arg r "$ROUTE" --arg s "$SNI_NAME" --arg t "$ROUTE_TAG" --arg e "$EXTRA_SNI" --argjson x "$public" --argjson b "$PORT" \
    '.nodes += [{name:$n,protocol:$p,link:$l,route:$r,sni:$s,route_tag:$t,extra_sni:$e,public_port:$x,backend_port:$b}]' "$META" >"$NM"
  if ! "$BIN" -t -f "$NC" >/dev/null || ! "$BIN" -t -f "$CL" >/dev/null; then
    fail "候选服务端或客户端 Mihomo 配置未通过校验。"
  fi
  if register_routes; then
    :
  else
    route_status=$?
    [ "$route_status" = 2 ] && fail "SNI 路由登记失败且自动回收不完整；节点未写入，请运行 sb sni-router status 检查残留路由。"
    fail "SNI 路由登记失败，节点未写入。"
  fi
  if ! apply_state "$NC" "$CL" "$NM"; then
    if unregister_routes "$ROUTE" "$ROUTE_TAG" "$EXTRA_SNI" "$PORT"; then
      fail "节点状态提交失败，已撤销 SNI 路由。"
    fi
    fail "节点状态提交失败，且 SNI 路由回收失败；请运行 sb sni-router status 检查残留路由。"
  fi
  rm -f "$LC" "$CC" "$NC" "$CL" "$NM"
  say "已创建：$NAME"
}
public_port() { if [ "$ROUTE" = none ]; then printf '%s' "$PORT"; else printf 443; fi; }

add_reality() {
  check_ready; new_name; reality_endpoint
  local pair pri pub sid dest pp link link_host
  read -r -p "服务器公网域名/IP（客户端实际连接地址）: " HOST
  [ -n "$HOST" ] || fail "服务器连接地址不能为空。"
  HOST=$(normalize_host "$HOST")
  pair=$("$BIN" generate reality-keypair)
  pri=$(printf '%s\n' "$pair" | awk '/PrivateKey:/ {print $2}')
  pub=$(printf '%s\n' "$pair" | awk '/PublicKey:/ {print $2}')
  [ -n "$pri" ] && [ -n "$pub" ] || fail "无法生成 Reality 密钥。"
  sid=$(rand_text 8)
  read -r -p "伪装目标（例：www.microsoft.com:443）: " dest
  [ -n "$dest" ] || fail "伪装目标不能为空。"
  begin_files
  cat >"$LC" <<EOF
listeners:
  - name: "__MH_NODE_NAME__"
    type: vless
    listen: $BIND
    port: $PORT
    users:
      - username: default
        uuid: "$(uuid)"
        flow: xtls-rprx-vision
    reality-config:
      dest: "$dest"
      private-key: "$pri"
      short-id: ["$sid"]
      server-names: ["$SNI_NAME"]
EOF
  local id
  id=$(yq eval '.listeners[0].users[0].uuid' "$LC"); pp=$(public_port)
  cat >"$CC" <<EOF
proxies:
  - name: "__MH_NODE_NAME__"
    type: vless
    server: "$HOST"
    port: $pp
    uuid: "$id"
    network: tcp
    tls: true
    servername: "$SNI_NAME"
    client-fingerprint: firefox
    flow: xtls-rprx-vision
    reality-opts: {public-key: "$pub", short-id: "$sid"}
EOF
  link_host=$(uri_host "$HOST")
  link="vless://$id@$link_host:$pp?encryption=none&security=reality&sni=$SNI_NAME&fp=firefox&pbk=$pub&sid=$sid&type=tcp&flow=xtls-rprx-vision#$LINK_NAME"
  commit_node vless-reality "$link" "$pp"
}
add_anytls() {
  check_ready; new_name; tcp_endpoint; direct_domain; get_cert "$HOST"
  local pass pp link link_host
  pass=$(rand_text 24); pp=$(public_port); begin_files
  cat >"$LC" <<EOF
listeners:
  - name: "__MH_NODE_NAME__"
    type: anytls
    listen: $BIND
    port: $PORT
    users: {default: "$pass"}
    certificate: "$CERT"
    private-key: "$KEY"
EOF
  cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: anytls, server: "$HOST", port: $pp, password: "$pass", tls: true, sni: "$HOST"}
EOF
  link_host=$(uri_host "$HOST")
  link="anytls://$pass@$link_host:$pp?sni=$HOST#$LINK_NAME"
  commit_node anytls "$link" "$pp"
}
xhttp_domain_guide() {
  cat <<'EOF'

XHTTP 域名要求：
  1. 共享 TCP 443 时，主域名/SNI 必须是一个尚未分配给其他入站的完整域名。
     不能与现有 Emby、Reality 或其他 TLS 节点使用完全相同的域名。
  2. 可以使用同一根域名下的不同子域名，例如 x.example.com 和 down.example.com。
  3. 独立下行域名是可选项，仅在需要上下行分离或单独使用 CDN 时配置。
     它必须与主域名不同，也不能占用其他共享 443 入站正在使用的完整域名。
  4. 使用独立下行域名时，证书必须同时覆盖主域名和下行域名；自动申请会处理这一点。
  5. 自动申请证书要求域名解析正确、TCP 80 可访问；经过 CDN 时不能拦截 ACME challenge。
  6. 如果使用非 443 独立端口，不存在共享 443 的 SNI 唯一性限制。
EOF
}
add_xhttp() {
  check_ready; new_name; xhttp_domain_guide; tcp_endpoint; direct_domain
  local id path mode pp link split server_host link_host confirm route_summary down_summary
  id=$(uuid); path=$(rand_path)
  read -r -p "XHTTP 模式 [auto/stream-one/stream-up/packet-up]（默认 auto）: " mode
  [ -n "$mode" ] || mode=auto
  case "$mode" in auto|stream-one|stream-up|packet-up) ;; *) fail "模式无效。" ;; esac
  server_host=$HOST
  if [ "$ROUTE" = tls ]; then
    read -r -p "是否配置独立下行域名（仅上下行分离/CDN 场景需要）？[y/N]: " split
    if [[ "$split" =~ ^[Yy]$ ]]; then
      read -r -p "独立下行完整域名/SNI（不能与主域名或其他 443 入站相同）: " EXTRA_SNI
      domain_ok "$EXTRA_SNI" || fail "下行域名无效。"
      [ "${EXTRA_SNI,,}" != "${HOST,,}" ] || fail "独立下行域名不能与主域名相同。"
      sni check-sni-free "$EXTRA_SNI" || fail "该下行完整域名不能用于新的共享 443 入站。"
      server_host=
    fi
  fi
  if [ "$ROUTE" = tls ]; then route_summary="共享 TCP 443（由 HAProxy 按 SNI 分流）"; else route_summary="TCP $PORT 独立监听"; fi
  if [ -n "$EXTRA_SNI" ]; then down_summary="$EXTRA_SNI（独立下行/CDN）"; else down_summary="$HOST（上下行共用）"; fi
  say ""
  say "XHTTP 配置摘要："
  say "  入口方式：$route_summary"
  say "  主域名：  $HOST"
  say "  下行域名：$down_summary"
  if [ -n "$EXTRA_SNI" ]; then say "  证书范围：$HOST + $EXTRA_SNI"; else say "  证书范围：$HOST"; fi
  read -r -p "确认以上域名配置并继续？[Y/n]: " confirm
  [[ "$confirm" != n && "$confirm" != N ]] || return 0
  if [ -n "$EXTRA_SNI" ]; then get_cert "$HOST" "$EXTRA_SNI"; else get_cert "$HOST"; fi
  pp=$(public_port); begin_files
  cat >"$LC" <<EOF
listeners:
  - name: "__MH_NODE_NAME__"
    type: vless
    listen: $BIND
    port: $PORT
    users: [{username: default, uuid: "$id"}]
    certificate: "$CERT"
    private-key: "$KEY"
    xhttp-config:
      path: "$path"
      host: "$server_host"
      mode: "$mode"
      no-sse-header: false
      x-padding-bytes: "100-1000"
EOF
  cat >"$CC" <<EOF
proxies:
  - name: "__MH_NODE_NAME__"
    type: vless
    server: "$HOST"
    port: $pp
    uuid: "$id"
    network: xhttp
    tls: true
    servername: "$HOST"
    alpn: [h2]
    xhttp-opts:
      path: "$path"
      host: "$HOST"
      mode: "$mode"
EOF
  if [ -n "$EXTRA_SNI" ]; then
    cat >>"$CC" <<EOF
      download-settings:
        path: "$path"
        host: "$EXTRA_SNI"
        server: "$EXTRA_SNI"
        port: 443
        tls: true
        alpn: [h2]
        servername: "$EXTRA_SNI"
EOF
  fi
  link_host=$(uri_host "$HOST")
  link="vless://$id@$link_host:$pp?encryption=none&security=tls&sni=$HOST&type=xhttp&path=$path&host=$HOST&mode=$mode#$LINK_NAME"
  commit_node vless-xhttp "$link" "$pp"
}
add_tls_transport() {
  check_ready; new_name; tcp_endpoint; direct_domain; get_cert "$HOST"
  local type=$1 id pass path service pp link link_host
  pp=$(public_port); begin_files
  link_host=$(uri_host "$HOST")
  case "$type" in
    vless-ws)
      id=$(uuid); path=$(rand_path)
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: vless, listen: $BIND, port: $PORT, users: [{username: default, uuid: "$id"}], certificate: "$CERT", private-key: "$KEY", ws-path: "$path"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: vless, server: "$HOST", port: $pp, uuid: "$id", network: ws, tls: true, servername: "$HOST", ws-opts: {path: "$path"}}
EOF
      link="vless://$id@$link_host:$pp?encryption=none&security=tls&sni=$HOST&type=ws&path=$path#$LINK_NAME" ;;
    vless-grpc)
      id=$(uuid); service=$(rand_text 12)
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: vless, listen: $BIND, port: $PORT, users: [{username: default, uuid: "$id"}], certificate: "$CERT", private-key: "$KEY", grpc-service-name: "$service"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: vless, server: "$HOST", port: $pp, uuid: "$id", network: grpc, tls: true, servername: "$HOST", grpc-opts: {grpc-service-name: "$service"}}
EOF
      link="vless://$id@$link_host:$pp?encryption=none&security=tls&sni=$HOST&type=grpc&serviceName=$service#$LINK_NAME" ;;
    trojan-ws)
      pass=$(rand_text 24); path=$(rand_path)
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: trojan, listen: $BIND, port: $PORT, users: [{username: default, password: "$pass"}], certificate: "$CERT", private-key: "$KEY", ws-path: "$path"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: trojan, server: "$HOST", port: $pp, password: "$pass", sni: "$HOST", network: ws, ws-opts: {path: "$path"}}
EOF
      link="trojan://$pass@$link_host:$pp?sni=$HOST&type=ws&path=$path#$LINK_NAME" ;;
  esac
  commit_node "$type" "$link" "$pp"
}
add_plain() {
  check_ready; new_name
  local type=$1 asked host id pass method link_host
  read -r -p "监听端口（留空随机，不可使用共享 443）: " asked
  [ -n "$asked" ] || asked=$(rand_port)
  [[ "$asked" =~ ^[0-9]+$ ]] && [ "$asked" -ge 1 ] && [ "$asked" -le 65535 ] && [ "$asked" != 443 ] || fail "端口无效，且该协议不支持 TCP SNI 复用 443。"
  check_port tcp "$asked"
  read -r -p "服务器地址/IP（用于客户端导出）: " host
  [ -n "$host" ] || fail "地址不能为空。"
  host=$(normalize_host "$host")
  BIND=0.0.0.0; PORT=$asked; ROUTE=none; SNI_NAME=$host; EXTRA_SNI=; begin_files
  link_host=$(uri_host "$host")
  case "$type" in
    vless-tcp)
      id=$(uuid)
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: vless, listen: 0.0.0.0, port: $PORT, allow-insecure: true, users: [{username: default, uuid: "$id"}]}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: vless, server: "$host", port: $PORT, uuid: "$id", tls: false}
EOF
      commit_node vless-tcp "vless://$id@$link_host:$PORT?encryption=none&security=none&type=tcp#$LINK_NAME" "$PORT" ;;
    shadowsocks)
      pass=$(rand_text 24); method=aes-256-gcm
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: shadowsocks, listen: 0.0.0.0, port: $PORT, cipher: "$method", password: "$pass"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: ss, server: "$host", port: $PORT, cipher: "$method", password: "$pass"}
EOF
      commit_node shadowsocks "ss://$(printf '%s' "$method:$pass" | base64 -w0 | tr '+/' '-_' | tr -d '=')@$link_host:$PORT#$LINK_NAME" "$PORT" ;;
    socks)
      pass=$(rand_text 20)
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: socks, listen: 0.0.0.0, port: $PORT, users: [{username: default, password: "$pass"}]}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: socks5, server: "$host", port: $PORT, username: default, password: "$pass"}
EOF
      commit_node socks5 "socks5://default:$pass@$link_host:$PORT#$LINK_NAME" "$PORT" ;;
  esac
}
add_quic() {
  check_ready; new_name
  local type=$1 asked host cert key pass id
  read -r -p "UDP 监听端口（留空随机，不能使用共享 443）: " asked
  [ -n "$asked" ] || asked=$(rand_port)
  [[ "$asked" =~ ^[0-9]+$ ]] && [ "$asked" -ge 1 ] && [ "$asked" -le 65535 ] && [ "$asked" != 443 ] || fail "UDP 端口无效，且 HY2/TUIC 不能使用当前 TCP SNI 复用 443。"
  check_port udp "$asked"
  read -r -p "服务器域名: " host; domain_ok "$host" || fail "需要有效域名。"
  get_cert "$host"; pass=$(rand_text 24); BIND=0.0.0.0; PORT=$asked; ROUTE=none; SNI_NAME=$host; EXTRA_SNI=; begin_files
  case "$type" in
    hysteria2)
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: hysteria2, listen: 0.0.0.0, port: $PORT, users: {default: "$pass"}, certificate: "$CERT", private-key: "$KEY"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: hysteria2, server: "$host", port: $PORT, password: "$pass", sni: "$host"}
EOF
      commit_node hysteria2 "hysteria2://$pass@$host:$PORT?sni=$host#$LINK_NAME" "$PORT" ;;
    tuic)
      id=$(uuid)
      cat >"$LC" <<EOF
listeners:
  - {name: "__MH_NODE_NAME__", type: tuic, listen: 0.0.0.0, port: $PORT, users: {"$id": "$pass"}, certificate: "$CERT", private-key: "$KEY", congestion-controller: bbr}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "__MH_NODE_NAME__", type: tuic, server: "$host", port: $PORT, uuid: "$id", password: "$pass", sni: "$host", congestion-controller: bbr}
EOF
      commit_node tuic "tuic://$id:$pass@$host:$PORT?sni=$host&congestion_control=bbr#$LINK_NAME" "$PORT" ;;
  esac
}
list_nodes() {
  init
  if command -v column >/dev/null 2>&1; then
    jq -r '.nodes[] | [.name,.protocol,(.public_port|tostring),.sni] | @tsv' "$META" | column -t -s $'\t'
  else
    jq -r '.nodes[] | [.name,.protocol,(.public_port|tostring),.sni] | @tsv' "$META"
  fi
}
export_nodes() {
  init
  local out=$1
  [ -n "$out" ] || out=/root/mihomo-nodes.txt
  jq -r '.nodes[].link' "$META" >"$out"
  chmod 600 "$out"
  say "链接已导出：$out"
  say "Mihomo YAML：$CLIENTS"
  if jq -e '.nodes[] | select((.extra_sni // "") != "")' "$META" >/dev/null; then
    say "注意：XHTTP 独立下行域名只完整保存在 $CLIENTS，通用分享链接无法表达该扩展。"
  fi
}
delete_node() {
  check_ready
  local asked route route_tag extra backend_port relay_proxy nc nl nm oldcfg oldclients oldmeta route_status
  list_nodes; IFS= read -r -p "要删除的节点名称: " asked
  route=$(jq -r --arg n "$asked" '[.nodes[] | select(.name==$n) | .route][0] // empty' "$META")
  [ -n "$route" ] && [ "$route" != null ] || fail "节点不存在。"
  route_tag=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.route_tag // .name)' "$META")
  extra=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.extra_sni // "")' "$META")
  backend_port=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | (.backend_port // .public_port)' "$META")
  relay_proxy=$(jq -r --arg n "$asked" '[.relays[] | select(.listener==$n) | .proxy][0] // ""' "$META")
  read -r -p "确认删除 $asked？输入 yes: " yes
  [ "$yes" = yes ] || return
  nc=$(mktemp "$MH_TMP/config.XXXXXX"); nl=$(mktemp "$MH_TMP/clients.XXXXXX"); nm=$(mktemp "$MH_TMP/meta.XXXXXX")
  oldcfg=$(mktemp "$MH_TMP/old-config.XXXXXX"); oldclients=$(mktemp "$MH_TMP/old-clients.XXXXXX"); oldmeta=$(mktemp "$MH_TMP/old-meta.XXXXXX")
  cp "$CFG" "$oldcfg"; cp "$CLIENTS" "$oldclients"; cp "$META" "$oldmeta"
  MH_YQ_NAME="$asked" MH_YQ_PROXY="$relay_proxy" yq eval \
    'del(.listeners[] | select(.name == strenv(MH_YQ_NAME))) | if strenv(MH_YQ_PROXY) != "" then del(.proxies[] | select(.name == strenv(MH_YQ_PROXY))) else . end' "$CFG" >"$nc"
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
  rm -f "$nc" "$nl" "$nm" "$oldcfg" "$oldclients" "$oldmeta"
  say "已删除：$asked"
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
  URI_USER=$(url_decode "${authority%@*}")
  hostport=${authority##*@}
  if [[ "$hostport" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
    URI_HOST=${BASH_REMATCH[1]}; URI_PORT=${BASH_REMATCH[3]}
  elif [[ "$hostport" =~ ^([^:]+)(:([0-9]+))?$ ]]; then
    URI_HOST=${BASH_REMATCH[1]}; URI_PORT=${BASH_REMATCH[3]}
  else
    fail "分享链接服务器地址格式无效。"
  fi
  [ -n "$URI_PORT" ] || URI_PORT=443
  [[ "$URI_PORT" =~ ^[0-9]+$ ]] && [ "$URI_PORT" -ge 1 ] && [ "$URI_PORT" -le 65535 ] || fail "分享链接端口无效。"
}
build_vless_outbound() {
  local link=$1 out=$2 sec network servername path host_header service mode pbk sid flow fp alpn insecure tls
  parse_uri "$link"
  [[ "$URI_USER" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || fail "VLESS UUID 格式无效。"
  sec=$(query_value "$URI_QUERY" security); network=$(query_value "$URI_QUERY" type); servername=$(query_value "$URI_QUERY" sni)
  path=$(query_value "$URI_QUERY" path); host_header=$(query_value "$URI_QUERY" host); service=$(query_value "$URI_QUERY" serviceName)
  mode=$(query_value "$URI_QUERY" mode); pbk=$(query_value "$URI_QUERY" pbk); sid=$(query_value "$URI_QUERY" sid)
  flow=$(query_value "$URI_QUERY" flow); fp=$(query_value "$URI_QUERY" fp); alpn=$(query_value "$URI_QUERY" alpn); insecure=$(query_value "$URI_QUERY" insecure)
  [ -n "$network" ] || network=tcp
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
    MH_YQ_PATH="$path" MH_YQ_HOST="$host_header" MH_YQ_MODE="$mode" yq eval -i \
      '.proxies[0].alpn=["h2"] | .proxies[0].xhttp-opts={"path":strenv(MH_YQ_PATH),"host":strenv(MH_YQ_HOST),"mode":strenv(MH_YQ_MODE)}' "$out"
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
  say "支持导入 VLESS、Trojan、AnyTLS 分享链接；本功能不创建端口转发规则。"
  list_nodes; IFS= read -r -p "本机入站节点名称: " listener
  if ! MH_YQ_NAME="$listener" yq eval -e '.listeners[]? | select(.name==strenv(MH_YQ_NAME))' "$CFG" >/dev/null 2>&1; then fail "入口不存在。"; fi
  if jq -e --arg n "$listener" '.relays[] | select(.listener==$n)' "$META" >/dev/null; then fail "该入口已有出站映射，请先删除原映射。"; fi
  existing_proxy=$(MH_YQ_NAME="$listener" yq eval -r '.listeners[] | select(.name==strenv(MH_YQ_NAME)) | .proxy // ""' "$CFG")
  [ -z "$existing_proxy" ] || fail "该入口已有 proxy=$existing_proxy，但元数据未登记；请先人工核对配置。"
  read -r -s -p "对应的外部出站分享链接（输入不回显）: " link
  printf '\n'
  case "$link" in vless://*|trojan://*|anytls://*) ;; *) fail "目前支持导入 VLESS、Trojan、AnyTLS 分享链接。" ;; esac
  while :; do
    pname=relay-$(rand_text 8)
    if ! MH_YQ_NAME="$pname" yq eval -e '.proxies[]? | select(.name==strenv(MH_YQ_NAME))' "$CFG" >/dev/null 2>&1; then break; fi
  done
  in=$(mktemp "$MH_TMP/relay.XXXXXX")
  case "$link" in
    vless://*) build_vless_outbound "$link" "$in" ;;
    trojan://*) build_trojan_outbound "$link" "$in" ;;
    anytls://*) build_anytls_outbound "$link" "$in" ;;
  esac
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
  IFS= read -r -p "要解除中转的入口名称: " listener
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
    printf '    [0] 返回主菜单\n\n'
    read -r -p "  请输入选项 [0-3]: " choice
    case "$choice" in
      1) relay_add ;;
      2) list_relays ;;
      3) relay_remove ;;
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
  if [ -f "$BIN" ]; then cp -p "$BIN" "$tmp/mihomo.old"; had_bin=1; fi
  atomic_install "$tmp/mihomo" "$BIN" 755 || { rm -rf "$tmp"; fail "安装 Mihomo 核心失败。"; }
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active "$SERVICE" >/dev/null 2>&1; then
    if ! systemctl restart "$SERVICE"; then
      if [ "$had_bin" = 1 ] && atomic_install "$tmp/mihomo.old" "$BIN" 755 && systemctl restart "$SERVICE"; then
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
    if ! rc-service "$SERVICE" restart; then
      if [ "$had_bin" = 1 ] && atomic_install "$tmp/mihomo.old" "$BIN" 755 && rc-service "$SERVICE" restart; then
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
command_background=true
pidfile="/run/mihomo.pid"
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
add_node_menu() {
  local choice
  printf '\n╔══════════════════════════════════════════╗\n'
  printf '║            Mihomo 添加节点               ║\n'
  printf '╚══════════════════════════════════════════╝\n\n'
  printf '  【TLS / 可共享 TCP 443】\n'
  printf '    [1] VLESS Reality       [2] VLESS WS + TLS\n'
  printf '    [3] Trojan WS + TLS     [4] VLESS gRPC + TLS\n'
  printf '    [5] AnyTLS + TLS        [6] VLESS XHTTP + TLS/CDN\n\n'
  printf '  【TCP 直连】\n'
  printf '    [7] VLESS TCP           [8] Shadowsocks AES-256-GCM\n'
  printf '    [9] SOCKS5\n\n'
  printf '  【QUIC / UDP 直连】\n'
  printf '    [10] Hysteria2          [11] TUIC v5\n\n'
  printf '  ──────────────────────────────────────────\n'
  printf '    [0] 返回主菜单\n\n'
  read -r -p "  请输入选项 [0-11]: " choice
  case "$choice" in
    1) add_reality ;;
    2) add_tls_transport vless-ws ;;
    3) add_tls_transport trojan-ws ;;
    4) add_tls_transport vless-grpc ;;
    5) add_anytls ;;
    6) add_xhttp ;;
    7) add_plain vless-tcp ;;
    8) add_plain shadowsocks ;;
    9) add_plain socks ;;
    10) add_quic hysteria2 ;;
    11) add_quic tuic ;;
    0) return 0 ;;
    *) say "无效选择。" ;;
  esac
}
menu() {
  while :; do
    printf '\n╔══════════════════════════════════════════╗\n'
    printf '║            Mihomo 节点管理               ║\n'
    printf '╚══════════════════════════════════════════╝\n\n'
    printf '  【节点管理】\n'
    printf '    [1] 添加节点            [2] 查看节点\n'
    printf '    [3] 导出节点            [4] 删除节点\n\n'
    printf '  【出站映射】\n'
    printf '    [5] 管理指定入站 → 出站映射\n\n'
    printf '  【核心管理】\n'
    printf '    [6] 安装/更新 Mihomo 核心和服务\n\n'
    printf '  ──────────────────────────────────────────\n'
    printf '    [0] 退出脚本\n\n'
    read -r -p "  请输入选项 [0-6]: " choice
    case "$choice" in
      1) add_node_menu ;;
      2) list_nodes ;;
      3) read -r -p "导出文件（默认 /root/mihomo-nodes.txt）: " out; export_nodes "$out" ;;
      4) delete_node ;;
      5) relay_menu ;;
      6) install_core; install_service ;;
      0) return ;;
      *) say "无效选择。" ;;
    esac
  done
}
main() {
  case "${1:-}" in
    ""|menu) root_only; install_base_deps; install_yq; check_runtime_deps; init; lock_state; menu ;;
    install) install_core; install_service ;;
    list) root_only; install_base_deps; install_yq; check_runtime_deps; init; lock_state; list_nodes ;;
    export) root_only; install_base_deps; install_yq; check_runtime_deps; init; lock_state; export_nodes "${2:-}" ;;
    *) printf '用法：mh [menu|install|list|export [文件]]\n' >&2; return 2 ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
