#!/usr/bin/env bash
# MH_MANAGER_MANAGED_COMMAND=1
# Mihomo server-side node manager used by proxyall.
set -Eeuo pipefail

BIN=/usr/local/bin/mihomo
ROOT=/usr/local/etc/mihomo
CFG=$ROOT/config.yaml
CLIENTS=$ROOT/clients.yaml
META=$ROOT/nodes.json
TMP=$ROOT/.tmp
SNI=/usr/local/bin/sb
SERVICE=mihomo
API=https://api.github.com/repos/MetaCubeX/mihomo/releases/latest

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
root_only() { [ "$(id -u)" = 0 ] || fail "请以 root 运行。"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "缺少依赖：$1"; }
domain_ok() { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$1" == *.* ]]; }
rand_port() { shuf -i 20000-50000 -n 1; }
rand_path() { printf '/%s' "$(tr -dc a-z0-9 </dev/urandom | head -c 16)"; }
rand_text() { tr -dc A-Za-z0-9 </dev/urandom | head -c "$1"; }
uuid() { cat /proc/sys/kernel/random/uuid; }

init() {
  install -d -m 700 "$ROOT" "$TMP"
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
}
check_yq() { need yq; yq --version | grep -qi mikefarah || fail "需要 mikefarah/yq v4（可先运行 sb 的安装项）。"; }
check_ready() { root_only; init; check_yq; [ -x "$BIN" ] || fail "请先安装 mihomo 核心。"; }
check_port() {
  local proto=$1 port=$2
  if [ "$proto" = tcp ]; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$" && fail "TCP 端口已占用：$port"
  else
    ss -lnu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$port$" && fail "UDP 端口已占用：$port"
  fi
}
reload_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now "$SERVICE"
    systemctl restart "$SERVICE"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add "$SERVICE" default >/dev/null 2>&1 || true
    rc-service "$SERVICE" restart
  else
    fail "仅支持 systemd 或 OpenRC。"
  fi
}
apply_config() {
  local new=$1 old
  "$BIN" -t -f "$new" >/dev/null || fail "候选 Mihomo 配置未通过校验。"
  old=$(mktemp "$TMP/rollback.XXXXXX")
  cp "$CFG" "$old"
  install -m 600 "$new" "$CFG"
  if ! reload_service; then
    install -m 600 "$old" "$CFG"
    reload_service || true
    fail "服务启动失败，已回滚配置。"
  fi
  rm -f "$old"
}
apply_state() {
  local newcfg=$1 newclients=$2 newmeta=$3
  apply_config "$newcfg"
  install -m 600 "$newclients" "$CLIENTS"
  install -m 600 "$newmeta" "$META"
}
sni() {
  [ -x "$SNI" ] || fail "未找到 SNI 路由组件 $SNI；请先安装 proxyall/sb.sh。"
  "$SNI" sni-router "$@"
}
new_name() {
  read -r -p "节点名称: " NAME
  [ -n "$NAME" ] || fail "名称不能为空。"
  jq -e --arg n "$NAME" '.nodes[] | select(.name==$n)' "$META" >/dev/null && fail "节点名称已存在。"
}
tcp_endpoint() {
  local asked
  read -r -p "监听端口（留空随机；443 可按 SNI 共用）: " asked
  [ -n "$asked" ] || asked=$(rand_port)
  [[ "$asked" =~ ^[0-9]+$ ]] && [ "$asked" -le 65535 ] && [ "$asked" -ge 1 ] || fail "端口无效。"
  BIND=0.0.0.0; PORT=$asked; ROUTE=none; SNI_NAME=
  if [ "$asked" = 443 ]; then
    sni prepare
    read -r -p "分流域名/SNI: " SNI_NAME
    domain_ok "$SNI_NAME" || fail "域名无效。"
    PORT=$(sni allocate-backend 2543)
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
  read -r -p "证书路径（须覆盖节点域名）: " CERT
  read -r -p "私钥路径: " KEY
  [ -r "$CERT" ] && [ -r "$KEY" ] || fail "证书或私钥不可读。"
}
direct_domain() {
  HOST=$SNI_NAME
  if [ -z "$HOST" ]; then
    read -r -p "服务器域名/IP（用于客户端导出）: " HOST
    [ -n "$HOST" ] || fail "地址不能为空。"
  fi
}
begin_files() {
  LC=$(mktemp "$TMP/listener.XXXXXX")
  CC=$(mktemp "$TMP/client.XXXXXX")
  NC=$(mktemp "$TMP/config.XXXXXX")
  CL=$(mktemp "$TMP/clients.XXXXXX")
  NM=$(mktemp "$TMP/meta.XXXXXX")
}
commit_node() {
  local protocol=$1 link=$2 public=$3
  yq eval-all 'select(fileIndex == 0) *+ {"listeners": (select(fileIndex == 1).listeners)}' "$CFG" "$LC" >"$NC"
  yq eval-all 'select(fileIndex == 0) *+ {"proxies": (select(fileIndex == 1).proxies)}' "$CLIENTS" "$CC" >"$CL"
  jq --arg n "$NAME" --arg p "$protocol" --arg l "$link" --arg r "$ROUTE" --arg s "$SNI_NAME" --argjson x "$public" '.nodes += [{name:$n,protocol:$p,link:$l,route:$r,sni:$s,public_port:$x}]' "$META" >"$NM"
  apply_state "$NC" "$CL" "$NM"
  if [ "$ROUTE" = reality ]; then sni register-reality mh "$NAME" "$SNI_NAME" "$PORT"
  elif [ "$ROUTE" = tls ]; then sni register-tls mh "$NAME" "$SNI_NAME" "$PORT"
  fi
  rm -f "$LC" "$CC" "$NC" "$CL" "$NM"
  say "已创建：$NAME"
}
public_port() { if [ "$ROUTE" = none ]; then printf '%s' "$PORT"; else printf 443; fi; }

add_reality() {
  check_ready; new_name; reality_endpoint
  local pair pri pub sid dest pp link
  pair=$("$BIN" generate reality-keypair)
  pri=$(printf '%s\n' "$pair" | awk '/PrivateKey:/ {print $2}')
  pub=$(printf '%s\n' "$pair" | awk '/PublicKey:/ {print $2}')
  [ -n "$pri" ] && [ -n "$pub" ] || fail "无法生成 Reality 密钥。"
  sid=$(tr -dc a-f0-9 </dev/urandom | head -c 8)
  read -r -p "伪装目标（例：www.microsoft.com:443）: " dest
  [ -n "$dest" ] || fail "伪装目标不能为空。"
  begin_files
  cat >"$LC" <<EOF
listeners:
  - name: "$NAME"
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
  - name: "$NAME"
    type: vless
    server: "$SNI_NAME"
    port: $pp
    uuid: "$id"
    network: tcp
    tls: true
    servername: "$SNI_NAME"
    client-fingerprint: firefox
    flow: xtls-rprx-vision
    reality-opts: {public-key: "$pub", short-id: "$sid"}
EOF
  link="vless://$id@$SNI_NAME:$pp?encryption=none&security=reality&sni=$SNI_NAME&fp=firefox&pbk=$pub&sid=$sid&type=tcp&flow=xtls-rprx-vision#$NAME"
  commit_node vless-reality "$link" "$pp"
}
add_anytls() {
  check_ready; new_name; tcp_endpoint; get_cert; direct_domain
  local pass pp link
  pass=$(rand_text 24); pp=$(public_port); begin_files
  cat >"$LC" <<EOF
listeners:
  - name: "$NAME"
    type: anytls
    listen: $BIND
    port: $PORT
    users: {default: "$pass"}
    certificate: "$CERT"
    private-key: "$KEY"
EOF
  cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: anytls, server: "$HOST", port: $pp, password: "$pass", tls: true, sni: "$HOST"}
EOF
  link="anytls://$pass@$HOST:$pp?sni=$HOST#$NAME"
  commit_node anytls "$link" "$pp"
}
add_xhttp() {
  check_ready; new_name; tcp_endpoint; get_cert; direct_domain
  local id path mode pp link
  id=$(uuid); path=$(rand_path)
  read -r -p "XHTTP 模式 [auto/stream-one/stream-up/packet-up]（默认 auto）: " mode
  [ -n "$mode" ] || mode=auto
  case "$mode" in auto|stream-one|stream-up|packet-up) ;; *) fail "模式无效。" ;; esac
  pp=$(public_port); begin_files
  cat >"$LC" <<EOF
listeners:
  - name: "$NAME"
    type: vless
    listen: $BIND
    port: $PORT
    users: [{username: default, uuid: "$id"}]
    certificate: "$CERT"
    private-key: "$KEY"
    xhttp-config:
      path: "$path"
      host: "$HOST"
      mode: "$mode"
      no-sse-header: false
      x-padding-bytes: "100-1000"
EOF
  cat >"$CC" <<EOF
proxies:
  - name: "$NAME"
    type: vless
    server: "$HOST"
    port: $pp
    uuid: "$id"
    network: xhttp
    tls: true
    servername: "$HOST"
    alpn: [h2]
    xhttp-opts: {path: "$path", host: "$HOST", mode: "$mode"}
EOF
  link="vless://$id@$HOST:$pp?encryption=none&security=tls&sni=$HOST&type=xhttp&path=$path&host=$HOST&mode=$mode#$NAME"
  commit_node vless-xhttp "$link" "$pp"
}
add_tls_transport() {
  check_ready; new_name; tcp_endpoint; get_cert; direct_domain
  local type=$1 id pass path service pp link
  pp=$(public_port); begin_files
  case "$type" in
    vless-ws)
      id=$(uuid); path=$(rand_path)
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: vless, listen: $BIND, port: $PORT, users: [{username: default, uuid: "$id"}], certificate: "$CERT", private-key: "$KEY", ws-opts: {path: "$path"}}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: vless, server: "$HOST", port: $pp, uuid: "$id", network: ws, tls: true, servername: "$HOST", ws-opts: {path: "$path"}}
EOF
      link="vless://$id@$HOST:$pp?encryption=none&security=tls&sni=$HOST&type=ws&path=$path#$NAME" ;;
    vless-grpc)
      id=$(uuid); service=$(tr -dc a-z </dev/urandom | head -c 12)
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: vless, listen: $BIND, port: $PORT, users: [{username: default, uuid: "$id"}], certificate: "$CERT", private-key: "$KEY", grpc-opts: {grpc-service-name: "$service"}}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: vless, server: "$HOST", port: $pp, uuid: "$id", network: grpc, tls: true, servername: "$HOST", grpc-opts: {grpc-service-name: "$service"}}
EOF
      link="vless://$id@$HOST:$pp?encryption=none&security=tls&sni=$HOST&type=grpc&serviceName=$service#$NAME" ;;
    trojan-ws)
      pass=$(rand_text 24); path=$(rand_path)
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: trojan, listen: $BIND, port: $PORT, users: [{username: default, password: "$pass"}], certificate: "$CERT", private-key: "$KEY", ws-opts: {path: "$path"}}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: trojan, server: "$HOST", port: $pp, password: "$pass", sni: "$HOST", network: ws, ws-opts: {path: "$path"}}
EOF
      link="trojan://$pass@$HOST:$pp?sni=$HOST&type=ws&path=$path#$NAME" ;;
  esac
  commit_node "$type" "$link" "$pp"
}
add_plain() {
  check_ready; new_name
  local type=$1 asked host id pass method
  read -r -p "监听端口（留空随机，不可使用共享 443）: " asked
  [ -n "$asked" ] || asked=$(rand_port)
  [[ "$asked" =~ ^[0-9]+$ ]] && [ "$asked" != 443 ] || fail "该协议不支持 TCP SNI 复用 443。"
  check_port tcp "$asked"
  read -r -p "服务器地址/IP（用于客户端导出）: " host
  [ -n "$host" ] || fail "地址不能为空。"
  NAME=$NAME; BIND=0.0.0.0; PORT=$asked; ROUTE=none; SNI_NAME=$host; begin_files
  case "$type" in
    vless-tcp)
      id=$(uuid)
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: vless, listen: 0.0.0.0, port: $PORT, users: [{username: default, uuid: "$id"}]}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: vless, server: "$host", port: $PORT, uuid: "$id", tls: false}
EOF
      commit_node vless-tcp "vless://$id@$host:$PORT?encryption=none&security=none&type=tcp#$NAME" "$PORT" ;;
    shadowsocks)
      pass=$(rand_text 24); method=aes-256-gcm
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: shadowsocks, listen: 0.0.0.0, port: $PORT, cipher: "$method", password: "$pass"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: ss, server: "$host", port: $PORT, cipher: "$method", password: "$pass"}
EOF
      commit_node shadowsocks "ss://$(printf '%s' "$method:$pass" | base64 -w0 | tr '+/' '-_' | tr -d '=')@$host:$PORT#$NAME" "$PORT" ;;
    socks)
      pass=$(rand_text 20)
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: socks, listen: 0.0.0.0, port: $PORT, users: [{username: default, password: "$pass"}]}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: socks5, server: "$host", port: $PORT, username: default, password: "$pass"}
EOF
      commit_node socks5 "socks5://default:$pass@$host:$PORT#$NAME" "$PORT" ;;
  esac
}
add_quic() {
  check_ready; new_name
  local type=$1 asked host cert key pass id
  read -r -p "UDP 监听端口（留空随机，不能使用共享 443）: " asked
  [ -n "$asked" ] || asked=$(rand_port)
  [[ "$asked" =~ ^[0-9]+$ ]] && [ "$asked" != 443 ] || fail "HY2/TUIC 不能使用当前 TCP SNI 复用 443。"
  check_port udp "$asked"
  read -r -p "服务器域名: " host; domain_ok "$host" || fail "需要有效域名。"
  get_cert; pass=$(rand_text 24); BIND=0.0.0.0; PORT=$asked; ROUTE=none; SNI_NAME=$host; begin_files
  case "$type" in
    hysteria2)
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: hysteria2, listen: 0.0.0.0, port: $PORT, users: [{username: default, password: "$pass"}], certificate: "$CERT", private-key: "$KEY"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: hysteria2, server: "$host", port: $PORT, password: "$pass", sni: "$host"}
EOF
      commit_node hysteria2 "hysteria2://default:$pass@$host:$PORT?sni=$host#$NAME" "$PORT" ;;
    tuic)
      id=$(uuid)
      cat >"$LC" <<EOF
listeners:
  - {name: "$NAME", type: tuic, listen: 0.0.0.0, port: $PORT, users: [{uuid: "$id", password: "$pass"}], certificate: "$CERT", private-key: "$KEY"}
EOF
      cat >"$CC" <<EOF
proxies:
  - {name: "$NAME", type: tuic, server: "$host", port: $PORT, uuid: "$id", password: "$pass", sni: "$host"}
EOF
      commit_node tuic "tuic://$id:$pass@$host:$PORT?sni=$host&congestion_control=bbr#$NAME" "$PORT" ;;
  esac
}
list_nodes() {
  init
  jq -r '.nodes[] | [.name,.protocol,(.public_port|tostring),.sni] | @tsv' "$META" | column -t -s $'\t' 2>/dev/null || true
}
export_nodes() {
  init
  local out=$1
  [ -n "$out" ] || out=/root/mihomo-nodes.txt
  jq -r '.nodes[].link' "$META" >"$out"
  chmod 600 "$out"
  say "链接已导出：$out"
  say "Mihomo YAML：$CLIENTS"
}
delete_node() {
  check_ready; local asked route nc nl nm
  list_nodes; read -r -p "要删除的节点名称: " asked
  route=$(jq -r --arg n "$asked" '.nodes[] | select(.name==$n) | .route' "$META" | head -n1)
  [ -n "$route" ] && [ "$route" != null ] || fail "节点不存在。"
  read -r -p "确认删除 $asked？输入 yes: " yes
  [ "$yes" = yes ] || return
  if [ "$route" = reality ]; then sni remove-reality "$asked"; fi
  if [ "$route" = tls ]; then sni remove-tls "$asked"; fi
  nc=$(mktemp "$TMP/config.XXXXXX"); nl=$(mktemp "$TMP/clients.XXXXXX"); nm=$(mktemp "$TMP/meta.XXXXXX")
  yq eval --arg n "$asked" 'del(.listeners[] | select(.name == $n))' "$CFG" >"$nc"
  yq eval --arg n "$asked" 'del(.proxies[] | select(.name == $n))' "$CLIENTS" >"$nl"
  jq --arg n "$asked" 'del(.nodes[] | select(.name==$n)) | .relays |= map(select(.listener != $n))' "$META" >"$nm"
  apply_state "$nc" "$nl" "$nm"; say "已删除：$asked"
}
relay_add() {
  check_ready
  local listener link pname nc nm in
  list_nodes; read -r -p "作为入口的本机节点名称: " listener
  yq eval --arg n "$listener" '.listeners[] | select(.name==$n) | .name' "$CFG" | grep -qx "$listener" || fail "入口不存在。"
  read -r -p "外部 VLESS/Trojan/AnyTLS 分享链接: " link
  case "$link" in vless://*|trojan://*|anytls://*) ;; *) fail "目前仅可直接导入 VLESS、Trojan、AnyTLS 分享链接。" ;; esac
  pname=relay-$(tr -dc a-z0-9 </dev/urandom | head -c 8)
  in=$(mktemp "$TMP/relay.XXXXXX")
  if [[ "$link" == vless://* ]]; then
    local body user hp host port query sec typ sn pbk sid flow fp extra
    body=$(printf '%s' "$link" | sed 's#^vless://##;s/#.*//'); user=$(printf '%s' "$body" | cut -d@ -f1); hp=$(printf '%s' "$body" | cut -d@ -f2-)
    host=$(printf '%s' "$hp" | sed 's/[:?].*//'); port=$(printf '%s' "$hp" | sed -n 's/.*:\([0-9][0-9]*\).*/\1/p'); query=$(printf '%s' "$hp" | sed -n 's/.*?\(.*\)/\1/p')
    [ -n "$port" ] || port=443; sec=$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^security=//p' | head -n1); typ=$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^type=//p' | head -n1); sn=$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^sni=//p' | head -n1)
    [ -n "$typ" ] || typ=tcp
    extra=
    if [ "$sec" = reality ]; then
      pbk=$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^pbk=//p' | head -n1); sid=$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^sid=//p' | head -n1); flow=$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^flow=//p' | head -n1); fp=$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^fp=//p' | head -n1)
      [ -n "$pbk" ] || fail "Reality 链接缺少 pbk 公钥。"
      [ -n "$fp" ] || fp=firefox
      extra=", client-fingerprint: \"$fp\", flow: \"$flow\", reality-opts: {public-key: \"$pbk\", short-id: \"$sid\"}"
    fi
    cat >"$in" <<EOF
proxies:
  - {name: "$pname", type: vless, server: "$host", port: $port, uuid: "$user", network: "$typ", tls: $([ "$sec" = none ] && printf false || printf true), servername: "$sn"$extra}
EOF
  elif [[ "$link" == trojan://* ]]; then
    local body pass hp host port
    body=$(printf '%s' "$link" | sed 's#^trojan://##;s/#.*//'); pass=$(printf '%s' "$body" | cut -d@ -f1); hp=$(printf '%s' "$body" | cut -d@ -f2-); host=$(printf '%s' "$hp" | sed 's/[:?].*//'); port=$(printf '%s' "$hp" | sed -n 's/.*:\([0-9][0-9]*\).*/\1/p'); [ -n "$port" ] || port=443
    cat >"$in" <<EOF
proxies:
  - {name: "$pname", type: trojan, server: "$host", port: $port, password: "$pass", sni: "$host"}
EOF
  else
    local body pass hp host port
    body=$(printf '%s' "$link" | sed 's#^anytls://##;s/#.*//'); pass=$(printf '%s' "$body" | cut -d@ -f1); hp=$(printf '%s' "$body" | cut -d@ -f2-); host=$(printf '%s' "$hp" | sed 's/[:?].*//'); port=$(printf '%s' "$hp" | sed -n 's/.*:\([0-9][0-9]*\).*/\1/p'); [ -n "$port" ] || port=443
    cat >"$in" <<EOF
proxies:
  - {name: "$pname", type: anytls, server: "$host", port: $port, password: "$pass", tls: true, sni: "$host"}
EOF
  fi
  nc=$(mktemp "$TMP/config.XXXXXX"); nm=$(mktemp "$TMP/meta.XXXXXX")
  yq eval-all 'select(fileIndex == 0) *+ {"proxies": (select(fileIndex == 1).proxies)}' "$CFG" "$in" >"$nc"
  yq eval --arg n "$listener" --arg p "$pname" '(.listeners[] | select(.name==$n)).proxy = $p' "$nc" >"$nc.next"; mv "$nc.next" "$nc"
  jq --arg l "$listener" --arg p "$pname" --arg u "$link" '.relays += [{listener:$l,proxy:$p,link:$u}]' "$META" >"$nm"
  apply_config "$nc"; install -m 600 "$nm" "$META"
  say "中转已启用：$listener → $pname"
}
relay_remove() {
  check_ready
  local listener proxy nc nm
  jq -r '.relays[] | [.listener,.proxy] | @tsv' "$META" | column -t -s $'\t' || true
  read -r -p "要解除中转的入口名称: " listener
  proxy=$(jq -r --arg n "$listener" '.relays[] | select(.listener==$n) | .proxy' "$META" | head -n1)
  [ -n "$proxy" ] && [ "$proxy" != null ] || fail "该入口没有中转。"
  nc=$(mktemp "$TMP/config.XXXXXX"); nm=$(mktemp "$TMP/meta.XXXXXX")
  yq eval --arg n "$listener" --arg p "$proxy" '(.listeners[] | select(.name==$n)).proxy = null | del(.proxies[] | select(.name==$p))' "$CFG" >"$nc"
  jq --arg n "$listener" 'del(.relays[] | select(.listener==$n))' "$META" >"$nm"
  apply_config "$nc"; install -m 600 "$nm" "$META"
  say "已解除中转：$listener"
}
install_core() {
  root_only; need curl; need jq; need gzip
  local arch asset url digest tmp got
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l|armv7) arch=armv7 ;; *) fail "不支持的架构：$(uname -m)" ;; esac
  asset=$(curl -fsSL "$API" | jq -r --arg a "$arch" '[.assets[] | select(.name | test("^mihomo-linux-" + $a + "-compatible-v1-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$"))][0].name // [.assets[] | select(.name | test("^mihomo-linux-" + $a + "-v1-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$"))][0].name // empty')
  [ -n "$asset" ] || fail "官方最新版本没有 $arch 的 Linux 包。"
  url=$(curl -fsSL "$API" | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url'); digest=$(curl -fsSL "$API" | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' | sed 's/^sha256://')
  tmp=$(mktemp -d); curl -fL --retry 3 -o "$tmp/m.gz" "$url"
  if [ -n "$digest" ]; then got=$(sha256sum "$tmp/m.gz" | awk '{print $1}'); [ "$got" = "$digest" ] || fail "下载 SHA-256 校验失败。"; fi
  gzip -dc "$tmp/m.gz" >"$tmp/mihomo"; chmod 755 "$tmp/mihomo"; "$tmp/mihomo" -v >/dev/null; install -m 755 "$tmp/mihomo" "$BIN"; rm -rf "$tmp"
  say "已安装：$("$BIN" -v | head -n1)"
}
install_service() {
  root_only; init
  if command -v systemctl >/dev/null 2>&1; then
    cat >/etc/systemd/system/mihomo.service <<EOF
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
  elif command -v rc-service >/dev/null 2>&1; then
    cat >/etc/init.d/mihomo <<EOF
#!/sbin/openrc-run
name="mihomo"
command="$BIN"
command_args="-d $ROOT -f $CFG"
command_background=true
pidfile="/run/mihomo.pid"
EOF
    chmod 755 /etc/init.d/mihomo
  else fail "仅支持 systemd 或 OpenRC。"; fi
  "$BIN" -t -f "$CFG" >/dev/null
  reload_service
}
menu() {
  while :; do
    printf '\n=== Mihomo 节点管理 ===\n'
    printf '1) 安装/更新核心和服务\n2) VLESS Reality（TCP/443 可 SNI 共用）\n3) AnyTLS + TLS\n4) VLESS XHTTP + TLS/CDN\n5) VLESS WS + TLS\n6) VLESS gRPC + TLS\n7) Trojan WS + TLS\n8) VLESS TCP\n9) Shadowsocks AES-256-GCM\n10) SOCKS5\n11) Hysteria2\n12) TUIC v5\n13) 查看节点\n14) 导出节点\n15) 设置入口中转\n16) 解除入口中转\n17) 删除节点\n0) 退出\n'
    read -r -p "选择: " choice
    case "$choice" in
      1) install_core; install_service ;; 2) add_reality ;; 3) add_anytls ;; 4) add_xhttp ;;
      5) add_tls_transport vless-ws ;; 6) add_tls_transport vless-grpc ;; 7) add_tls_transport trojan-ws ;;
      8) add_plain vless-tcp ;; 9) add_plain shadowsocks ;; 10) add_plain socks ;;
      11) add_quic hysteria2 ;; 12) add_quic tuic ;; 13) list_nodes ;;
      14) read -r -p "导出文件（默认 /root/mihomo-nodes.txt）: " out; export_nodes "$out" ;;
      15) relay_add ;; 16) relay_remove ;; 17) delete_node ;; 0) return ;; *) say "无效选择。" ;;
    esac
  done
}
case "${1:-}" in
  ""|menu) root_only; init; menu ;;
  install) install_core; install_service ;;
  list) init; list_nodes ;;
  export) init; export_nodes "${2:-}" ;;
  *) printf '用法：mh [menu|install|list|export [文件]]\n' >&2; exit 2 ;;
esac
