#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_PATH="${CONFIG_DIR}/config.json"
readonly RESULT_PATH="/root/sing-box-reality.txt"
readonly INSTALLER_URL="https://sing-box.app/install.sh"

TEMP_DIR=""
CONFIG_BACKUP=""
PREEXISTING_CONFIG=0
WAS_ACTIVE=0
INPUT_FD=0

info() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

trap cleanup EXIT

read_value() {
  local prompt="$1"
  local default_value="${2-}"
  local value

  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$prompt" "$default_value" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r -u "$INPUT_FD" value
  printf '%s' "${value:-$default_value}"
}

confirm() {
  local prompt="$1"
  local default_answer="${2:-n}"
  local suffix='[y/N]'
  local answer

  if [[ "$default_answer" == "y" ]]; then
    suffix='[Y/n]'
  fi
  printf '%s %s: ' "$prompt" "$suffix" >&2
  IFS= read -r -u "$INPUT_FD" answer
  answer="${answer:-$default_answer}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

is_ipv4() {
  local value="$1"
  local part
  local -a parts

  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a parts <<<"$value"
  for part in "${parts[@]}"; do
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
}

is_hostname() {
  local value="$1"
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_port_free() {
  local port="$1"
  ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

find_free_port() {
  local port
  local attempt

  for ((attempt = 0; attempt < 100; attempt++)); do
    port="$(shuf -i 10000-60000 -n 1)"
    if [[ "$port" != "80" && "$port" != "443" ]] && is_port_free "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

install_dependencies() {
  local openssl_help

  info '安装基础依赖（curl、openssl、jq、iproute、coreutils）...'
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl openssl jq iproute2 coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl openssl jq iproute coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl openssl jq iproute coreutils
  else
    die '不支持当前包管理器。请使用 Debian/Ubuntu 或 RHEL 系 Linux。'
  fi

  openssl_help="$(openssl s_client -help 2>&1 || true)"
  grep -q -- '-tls1_3' <<<"$openssl_help" || \
    die '当前 OpenSSL 不支持 TLS 1.3，无法可靠检测 REALITY 目标。'
}

install_sing_box() {
  local installer="${TEMP_DIR}/sing-box-install.sh"

  if command -v sing-box >/dev/null 2>&1 && systemctl cat sing-box.service >/dev/null 2>&1; then
    info "检测到已安装的 $(sing-box version | head -n 1)，直接复用。"
    return 0
  fi

  info '从 sing-box 官方安装源安装最新稳定版...'
  curl -fsSL --retry 3 --connect-timeout 10 "$INSTALLER_URL" -o "$installer"
  bash "$installer"

  command -v sing-box >/dev/null 2>&1 || die 'sing-box 安装完成后仍找不到可执行文件。'
  systemctl cat sing-box.service >/dev/null 2>&1 || die '未找到 sing-box 的 systemd 服务。'
}

detect_public_ipv4() {
  local address=''

  address="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if ! is_ipv4 "$address"; then
    address="$(curl -4 -fsS --max-time 6 https://ifconfig.me/ip 2>/dev/null || true)"
  fi
  if is_ipv4 "$address"; then
    printf '%s' "$address"
  fi
}

measure_reality_target() {
  local host="$1"
  local output
  local start_ms
  local end_ms

  start_ms="$(date +%s%3N)"
  if ! output="$(timeout 5 openssl s_client -4 \
    -connect "${host}:443" \
    -servername "$host" \
    -tls1_3 \
    -curves X25519 \
    -alpn h2 \
    -verify_hostname "$host" \
    -verify_return_error </dev/null 2>&1)"; then
    return 1
  fi

  grep -q 'TLSv1.3' <<<"$output" || return 1
  grep -q 'ALPN protocol: h2' <<<"$output" || return 1
  end_ms="$(date +%s%3N)"
  printf '%s' "$((end_ms - start_ms))"
}

choose_manual_target() {
  local candidate
  local latency

  while true; do
    candidate="$(read_value '请输入 REALITY 目标域名（不要带 https:// 或 :443）' 'www.amd.com')"
    if ! is_hostname "$candidate"; then
      warn '域名格式不正确。'
      continue
    fi

    info "检测 ${candidate}:443 ..."
    if latency="$(measure_reality_target "$candidate")"; then
      TARGET_HOST="$candidate"
      TARGET_LATENCY="$latency"
      return 0
    fi
    warn '该目标未同时通过 TLS 1.3、X25519、h2 和证书校验，请换一个域名。'
  done
}

choose_reality_target() {
  local choice
  local candidate
  local latency
  local best_line
  local results_file="${TEMP_DIR}/target-results.txt"
  local -a candidates=(
    'www.amd.com'
    'www.microsoft.com'
    'www.apple.com'
    'www.nvidia.com'
    'www.intel.com'
    'www.samsung.com'
    'www.sony.com'
    'www.xbox.com'
    'www.ibm.com'
    'www.oracle.com'
  )

  printf '\nREALITY 目标选择：\n'
  printf '  1) 自动检测并选择延迟最低的目标（推荐）\n'
  printf '  2) 手动输入目标（默认 www.amd.com）\n'
  choice="$(read_value '请选择' '1')"

  if [[ "$choice" == '2' ]]; then
    choose_manual_target
    return 0
  fi
  [[ "$choice" == '1' ]] || die '无效选择。'

  : >"$results_file"
  info '开始检测候选目标；每个目标最长等待 5 秒...'
  for candidate in "${candidates[@]}"; do
    printf '    %-24s ' "$candidate"
    if latency="$(measure_reality_target "$candidate")"; then
      printf '通过，%s ms\n' "$latency"
      printf '%s %s\n' "$latency" "$candidate" >>"$results_file"
    else
      printf '不通过\n'
    fi
  done

  if [[ ! -s "$results_file" ]]; then
    warn '自动候选列表中没有可用目标，改为手动输入。'
    choose_manual_target
    return 0
  fi

  best_line="$(sort -n "$results_file" | head -n 1)"
  TARGET_LATENCY="${best_line%% *}"
  TARGET_HOST="${best_line#* }"
}

collect_inputs() {
  local detected_ipv4
  local default_port
  local port_input
  local resolved_addresses

  detected_ipv4="$(detect_public_ipv4)"
  while true; do
    SERVER_ADDRESS="$(read_value '客户端连接地址（VPS 公网 IPv4 或直连域名）' "$detected_ipv4")"
    if is_ipv4 "$SERVER_ADDRESS" || is_hostname "$SERVER_ADDRESS"; then
      break
    fi
    warn '请输入有效的公网 IPv4 或域名。'
  done

  if is_hostname "$SERVER_ADDRESS" && [[ -n "$detected_ipv4" ]]; then
    resolved_addresses="$(getent ahostsv4 "$SERVER_ADDRESS" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if ! grep -Fxq "$detected_ipv4" <<<"$resolved_addresses"; then
      warn "${SERVER_ADDRESS} 当前未解析到本机公网 IPv4 ${detected_ipv4}。"
      warn '若使用 Cloudflare，请关闭代理（灰云）；否则 RAW/TCP 节点通常无法连接。'
      confirm '仍然继续使用这个连接地址吗？' 'n' || die '已取消。请先修正 DNS 后重试。'
    fi
  fi

  NODE_NAME="$(read_value '节点名称（仅作客户端备注）' 'sing-box-reality')"
  default_port="$(find_free_port)" || die '无法找到空闲端口。'
  while true; do
    port_input="$(read_value 'sing-box 入站端口（不会占用 Nginx 的 80/443）' "$default_port")"
    if [[ ! "$port_input" =~ ^[0-9]+$ ]] || ((10#$port_input < 1 || 10#$port_input > 65535)); then
      warn '端口必须是 1 到 65535 的整数。'
      continue
    fi
    LISTEN_PORT="$((10#$port_input))"
    if [[ "$LISTEN_PORT" == '80' || "$LISTEN_PORT" == '443' ]]; then
      warn '为避免与 Nginx 冲突，请不要使用 80 或 443。'
      continue
    fi
    if ! is_port_free "$LISTEN_PORT"; then
      warn "端口 ${LISTEN_PORT} 已被占用。"
      continue
    fi
    break
  done

  choose_reality_target
  info "选定 REALITY 目标：${TARGET_HOST}:443（检测延迟 ${TARGET_LATENCY} ms）"
}

generate_credentials() {
  local key_pair

  UUID="$(sing-box generate uuid)"
  SHORT_ID="$(sing-box generate rand --hex 8)"
  key_pair="$(sing-box generate reality-keypair)"
  PRIVATE_KEY="$(awk '/PrivateKey/ {print $NF}' <<<"$key_pair" | tr -d '"')"
  PUBLIC_KEY="$(awk '/PublicKey/ {print $NF}' <<<"$key_pair" | tr -d '"')"

  [[ -n "$UUID" && -n "$SHORT_ID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || \
    die '生成 UUID、Short ID 或 REALITY 密钥失败。'
}

write_candidate_config() {
  local candidate_config="$1"

  jq -n \
    --arg node_name "$NODE_NAME" \
    --arg uuid "$UUID" \
    --arg target "$TARGET_HOST" \
    --arg private_key "$PRIVATE_KEY" \
    --arg short_id "$SHORT_ID" \
    --argjson listen_port "$LISTEN_PORT" \
    '{
      log: {
        level: "info",
        timestamp: true
      },
      inbounds: [
        {
          type: "vless",
          tag: "vless-reality-in",
          listen: "0.0.0.0",
          listen_port: $listen_port,
          users: [
            {
              name: $node_name,
              uuid: $uuid,
              flow: "xtls-rprx-vision"
            }
          ],
          tls: {
            enabled: true,
            server_name: $target,
            reality: {
              enabled: true,
              handshake: {
                server: $target,
                server_port: 443
              },
              private_key: $private_key,
              short_id: [$short_id]
            }
          }
        }
      ],
      outbounds: [
        {
          type: "direct",
          tag: "direct"
        }
      ]
    }' >"$candidate_config"

  sing-box check -c "$candidate_config"
}

restore_previous_config() {
  warn '新配置启动失败，正在恢复原配置...'
  if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
    cp -a -- "$CONFIG_BACKUP" "$CONFIG_PATH"
  else
    rm -f -- "$CONFIG_PATH"
  fi

  if ((WAS_ACTIVE)); then
    systemctl restart sing-box.service >/dev/null 2>&1 || true
  else
    systemctl stop sing-box.service >/dev/null 2>&1 || true
  fi
}

install_config_and_start() {
  local candidate_config="${TEMP_DIR}/config.json"
  local timestamp

  write_candidate_config "$candidate_config"
  install -d -m 0755 "$CONFIG_DIR"

  if [[ -e "$CONFIG_PATH" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    CONFIG_BACKUP="${CONFIG_PATH}.bak.${timestamp}"
    cp -a -- "$CONFIG_PATH" "$CONFIG_BACKUP"
    info "原配置已备份到 ${CONFIG_BACKUP}"
  fi

  install -m 0640 "$candidate_config" "$CONFIG_PATH"
  if getent group sing-box >/dev/null 2>&1; then
    chown root:sing-box "$CONFIG_PATH"
  else
    chown root:root "$CONFIG_PATH"
    chmod 0600 "$CONFIG_PATH"
  fi

  if ! sing-box check -C "$CONFIG_DIR"; then
    restore_previous_config
    die '写入后的完整配置检查失败。'
  fi

  systemctl daemon-reload
  systemctl enable sing-box.service >/dev/null
  if ! systemctl restart sing-box.service; then
    journalctl -u sing-box.service --output cat -n 30 --no-pager >&2 || true
    restore_previous_config
    die 'sing-box 服务启动失败。'
  fi

  sleep 1
  if ! systemctl is-active --quiet sing-box.service; then
    journalctl -u sing-box.service --output cat -n 30 --no-pager >&2 || true
    restore_previous_config
    die 'sing-box 服务未保持运行。'
  fi
  if is_port_free "$LISTEN_PORT"; then
    die "服务已运行，但端口 ${LISTEN_PORT} 未监听。"
  fi
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if confirm "检测到 UFW 已启用，放行 ${LISTEN_PORT}/tcp 吗？" 'y'; then
      ufw allow "${LISTEN_PORT}/tcp" comment 'sing-box Reality'
    else
      warn "请稍后手动执行：ufw allow ${LISTEN_PORT}/tcp"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld.service; then
    if confirm "检测到 firewalld 已启用，放行 ${LISTEN_PORT}/tcp 吗？" 'y'; then
      firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp"
      firewall-cmd --reload
    else
      warn "请稍后手动放行 TCP 端口 ${LISTEN_PORT}。"
    fi
  fi
}

save_and_print_result() {
  local encoded_name
  local vless_link
  local timestamp

  encoded_name="$(jq -rn --arg value "$NODE_NAME" '$value | @uri')"
  vless_link="vless://${UUID}@${SERVER_ADDRESS}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${TARGET_HOST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${encoded_name}"

  if [[ -e "$RESULT_PATH" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$RESULT_PATH" "${RESULT_PATH}.bak.${timestamp}"
  fi

  {
    printf '名称: %s\n' "$NODE_NAME"
    printf '协议: VLESS + RAW/TCP + REALITY + xtls-rprx-vision\n'
    printf '连接地址: %s\n' "$SERVER_ADDRESS"
    printf '入站端口: %s\n' "$LISTEN_PORT"
    printf 'UUID: %s\n' "$UUID"
    printf 'SNI/目标: %s:443\n' "$TARGET_HOST"
    printf 'Public Key: %s\n' "$PUBLIC_KEY"
    printf 'Short ID: %s\n' "$SHORT_ID"
    printf 'Fingerprint: chrome\n'
    printf '链接: %s\n' "$vless_link"
  } >"$RESULT_PATH"
  chmod 0600 "$RESULT_PATH"

  printf '\n========== 安装完成 ==========\n'
  printf 'sing-box: %s\n' "$(sing-box version | head -n 1)"
  printf '配置文件: %s\n' "$CONFIG_PATH"
  printf '节点信息: %s（权限 600）\n' "$RESULT_PATH"
  printf '服务状态: active\n'
  printf '监听端口: %s/tcp\n' "$LISTEN_PORT"
  printf '\nVLESS 分享链接：\n%s\n' "$vless_link"
  printf '\n常用检查命令：\n'
  printf '  sing-box check -C %s\n' "$CONFIG_DIR"
  printf '  systemctl status sing-box --no-pager\n'
  printf '  journalctl -u sing-box --output cat -e\n'
  printf '  ss -lntp | grep :%s\n' "$LISTEN_PORT"
  printf '\n若 VPS 厂商有安全组/云防火墙，还需在那里放行 TCP %s。\n' "$LISTEN_PORT"
}

main() {
  [[ $EUID -eq 0 ]] || die '请使用 root 用户运行此脚本。'
  [[ "$(uname -s)" == 'Linux' ]] || die '此脚本仅支持 Linux。'
  command -v systemctl >/dev/null 2>&1 || die '此脚本要求使用 systemd。'

  if [[ -r /dev/tty ]]; then
    exec 3</dev/tty
    INPUT_FD=3
  elif [[ -t 0 ]]; then
    INPUT_FD=0
  else
    die '此脚本需要交互式终端。'
  fi

  TEMP_DIR="$(mktemp -d)"
  if [[ -e "$CONFIG_PATH" ]]; then
    PREEXISTING_CONFIG=1
  fi
  if systemctl is-active --quiet sing-box.service 2>/dev/null; then
    WAS_ACTIVE=1
  fi

  printf '此脚本只安装 sing-box，不安装 S-UI/3x-ui，也不会修改 Nginx。\n'
  printf '将创建一个 VLESS + RAW/TCP + REALITY + xtls-rprx-vision 入站。\n\n'

  if ((PREEXISTING_CONFIG)); then
    warn "检测到已有配置 ${CONFIG_PATH}。"
    confirm '是否备份并替换为单节点配置？' 'n' || die '已取消，未修改现有配置。'
  fi

  install_dependencies
  install_sing_box
  collect_inputs
  generate_credentials
  install_config_and_start
  configure_firewall
  save_and_print_result
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
