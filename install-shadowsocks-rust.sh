#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Shadowsocks-rust installer for Debian / Ubuntu
# Defaults:
#   - latest stable shadowsocks-rust release
#   - chacha20-ietf-poly1305
#   - TCP + UDP
#   - bind to 0.0.0.0
#
# Optional environment variables:
#   SS_PORT=8388              Preselect port (otherwise prompt; Enter = random)
#   SSRUST_VERSION=v1.24.0    Pin a release tag instead of using latest

readonly SERVICE_NAME="shadowsocks-rust.service"
readonly SERVICE_USER="ssrust"
readonly SERVICE_GROUP="ssrust"
readonly CONFIG_DIR="/etc/shadowsocks-rust"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly BIN_PATH="/usr/local/bin/ssserver"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly REPO="shadowsocks/shadowsocks-rust"
readonly METHOD="chacha20-ietf-poly1305"
readonly RANDOM_PORT_MIN=10000
readonly RANDOM_PORT_MAX=29999

WORKDIR=""

log() {
    printf '[+] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        rm -rf -- "${WORKDIR}"
    fi
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    printf '[ERROR] Installation failed at line %s (exit code %s).\n' "${line_no}" "${exit_code}" >&2
    exit "${exit_code}"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Please run this script as root, for example: sudo bash $0"
}

check_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found. Only Debian and Ubuntu are supported."
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            log "Detected ${PRETTY_NAME:-$ID}."
            ;;
        *)
            die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. This script supports Debian and Ubuntu only."
            ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."
    command -v systemctl >/dev/null 2>&1 || die "systemctl was not found."
    [[ -d /run/systemd/system ]] || die "systemd does not appear to be running as PID 1."
}

install_dependencies() {
    log "Installing required packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        openssl \
        passwd \
        python3-minimal \
        xz-utils
}

map_architecture() {
    local machine
    machine="$(uname -m)"

    case "${machine}" in
        x86_64|amd64)
            TARGET="x86_64-unknown-linux-gnu"
            ;;
        aarch64|arm64)
            TARGET="aarch64-unknown-linux-gnu"
            ;;
        *)
            die "Unsupported CPU architecture: ${machine}. This installer currently supports x86_64/amd64 and aarch64/arm64."
            ;;
    esac

    readonly TARGET
    log "CPU target: ${TARGET}"
}

port_in_use() {
    local port=$1
    [[ -n "$(ss -H -lntu "sport = :${port}" 2>/dev/null)" ]]
}

validate_port() {
    local port=$1
    local port_num

    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    (( ${#port} <= 5 )) || return 1
    port_num=$((10#${port}))
    (( port_num >= 1 && port_num <= 65535 )) || return 1
    return 0
}

choose_random_port() {
    local candidate
    local range=$((RANDOM_PORT_MAX - RANDOM_PORT_MIN + 1))
    local i

    for ((i = 0; i < 200; i++)); do
        candidate=$((RANDOM_PORT_MIN + $(od -An -N4 -tu4 /dev/urandom) % range))
        if ! port_in_use "${candidate}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

prompt_for_port() {
    local input="${SS_PORT:-}"

    if [[ -z "${input}" ]]; then
        if [[ -r /dev/tty ]]; then
            printf '请输入 Shadowsocks 服务端端口（1-65535，直接回车随机选择）：' >/dev/tty
            IFS= read -r input </dev/tty || die "Unable to read the port from the terminal."
        else
            die "No interactive terminal is available. Set SS_PORT explicitly, for example: SS_PORT=8388 bash $0"
        fi
    fi

    if [[ -z "${input}" ]]; then
        PORT="$(choose_random_port)" || die "Unable to find an unused random port."
        log "Randomly selected port: ${PORT}"
    else
        validate_port "${input}" || die "Invalid port: ${input}. Valid range is 1-65535."
        PORT="$((10#${input}))"
        if port_in_use "${PORT}"; then
            die "Port ${PORT} is already in use by a TCP or UDP listener. Choose another port."
        fi
        log "Selected port: ${PORT}"
    fi

    readonly PORT
}

check_existing_installation() {
    if [[ -e "${CONFIG_FILE}" || -e "${UNIT_FILE}" || -e "${BIN_PATH}" ]]; then
        die "An existing shadowsocks-rust installation was detected. For production safety, this installer will not overwrite it."
    fi
}

resolve_version() {
    if [[ -n "${SSRUST_VERSION:-}" ]]; then
        VERSION="${SSRUST_VERSION}"
    else
        local latest_url
        log "Resolving latest stable shadowsocks-rust release..."
        latest_url="$(curl -fsSIL \
            --proto '=https' \
            --proto-redir '=https' \
            --tlsv1.2 \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 15 \
            -o /dev/null \
            -w '%{url_effective}' \
            "https://github.com/${REPO}/releases/latest")"
        VERSION="${latest_url##*/}"
    fi

    [[ "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
        || die "Invalid shadowsocks-rust release tag: ${VERSION}"

    readonly VERSION
    log "Release: ${VERSION}"
}

download_and_verify() {
    local archive_name="shadowsocks-${VERSION}.${TARGET}.tar.xz"
    local archive_url="https://github.com/${REPO}/releases/download/${VERSION}/${archive_name}"
    local checksum_url="${archive_url}.sha256"
    local expected actual

    WORKDIR="$(mktemp -d /tmp/shadowsocks-rust.XXXXXX)"
    ARCHIVE="${WORKDIR}/${archive_name}"
    CHECKSUM_FILE="${ARCHIVE}.sha256"

    log "Downloading official release archive..."
    curl -fL --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 2 --connect-timeout 15 \
        --proto-redir '=https' \
        -o "${ARCHIVE}" "${archive_url}"

    log "Downloading official SHA-256 checksum..."
    curl -fL --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 2 --connect-timeout 15 \
        --proto-redir '=https' \
        -o "${CHECKSUM_FILE}" "${checksum_url}"

    expected="$(awk 'NR==1 {print $1}' "${CHECKSUM_FILE}")"
    actual="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"

    [[ "${expected}" =~ ^[0-9A-Fa-f]{64}$ ]] || die "The downloaded checksum file has an unexpected format."
    [[ "${actual,,}" == "${expected,,}" ]] || die "SHA-256 verification failed. The archive was not installed."

    log "SHA-256 verification passed."

    tar -xJf "${ARCHIVE}" -C "${WORKDIR}"
    SSSERVER_SOURCE="$(find "${WORKDIR}" -type f -name ssserver -print -quit)"
    [[ -n "${SSSERVER_SOURCE}" && -f "${SSSERVER_SOURCE}" ]] || die "ssserver was not found in the official archive."

    chmod 0755 "${SSSERVER_SOURCE}"
    "${SSSERVER_SOURCE}" --version >/dev/null

    readonly ARCHIVE CHECKSUM_FILE SSSERVER_SOURCE
}

create_service_account() {
    if getent passwd "${SERVICE_USER}" >/dev/null 2>&1; then
        return 0
    fi

    if getent group "${SERVICE_GROUP}" >/dev/null 2>&1; then
        useradd --system \
            --gid "${SERVICE_GROUP}" \
            --home-dir /nonexistent \
            --shell /usr/sbin/nologin \
            "${SERVICE_USER}"
    else
        useradd --system \
            --user-group \
            --home-dir /nonexistent \
            --shell /usr/sbin/nologin \
            "${SERVICE_USER}"
    fi
}

generate_password() {
    PASSWORD="$(openssl rand -hex 32)"
    [[ "${PASSWORD}" =~ ^[0-9a-f]{64}$ ]] || die "Password generation failed."
    readonly PASSWORD
}

install_files() {
    local staged_config="${WORKDIR}/config.json"
    local staged_unit="${WORKDIR}/${SERVICE_NAME}"

    cat >"${staged_config}" <<EOF_CONFIG
{
    "server": "0.0.0.0",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "method": "${METHOD}",
    "mode": "tcp_and_udp"
}
EOF_CONFIG

    cat >"${staged_unit}" <<EOF_UNIT
[Unit]
Description=Shadowsocks Rust Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF_UNIT

    # Validate generated JSON before touching /etc.
    python3 -m json.tool "${staged_config}" >/dev/null

    create_service_account

    install -m 0755 -o root -g root "${SSSERVER_SOURCE}" "${BIN_PATH}"
    install -d -m 0750 -o root -g "${SERVICE_GROUP}" "${CONFIG_DIR}"
    install -m 0640 -o root -g "${SERVICE_GROUP}" "${staged_config}" "${CONFIG_FILE}"
    install -m 0644 -o root -g root "${staged_unit}" "${UNIT_FILE}"
}

start_service() {
    log "Loading and starting systemd service..."
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null

    if ! systemctl restart "${SERVICE_NAME}"; then
        warn "Service failed to start. Recent logs:"
        journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
        systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        die "${SERVICE_NAME} failed to start."
    fi

    sleep 1

    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        warn "Service is not active. Recent logs:"
        journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
        systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        die "${SERVICE_NAME} is not active."
    fi

    if ! ss -H -lnt "sport = :${PORT}" | grep -q .; then
        warn "The service is active, but no TCP listener was detected on port ${PORT}."
        journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
        systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        die "TCP listener verification failed."
    fi

    if ! ss -H -lnu "sport = :${PORT}" | grep -q .; then
        warn "The service is active, but no UDP listener was detected on port ${PORT}."
        journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
        systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        die "UDP listener verification failed."
    fi
}

show_summary() {
    local version_output
    version_output="$(${BIN_PATH} --version 2>/dev/null | head -n 1 || true)"

    cat <<EOF_SUMMARY

============================================================
Shadowsocks-rust 安装完成
============================================================
版本:       ${version_output:-${VERSION}}
监听地址:   0.0.0.0
端口:       ${PORT}
密码:       ${PASSWORD}
加密方式:   ${METHOD}
模式:       TCP + UDP
配置文件:   ${CONFIG_FILE}
服务名称:   ${SERVICE_NAME}

常用命令:
  systemctl status ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f

请确认服务器防火墙/云安全组已放行:
  TCP ${PORT}
  UDP ${PORT}
============================================================
EOF_SUMMARY
}

main() {
    require_root
    check_os
    install_dependencies
    map_architecture
    check_existing_installation
    prompt_for_port
    resolve_version
    download_and_verify
    generate_password
    install_files
    start_service
    show_summary
}

main "$@"
