#!/bin/sh

set -eu

SINGBOX_VERSION="1.13.14"
SINGBOX_TAG="v${SINGBOX_VERSION}"

INSTALL_DIR="/usr/local/bin"
BIN_FILE="${INSTALL_DIR}/sing-box"

CLI_NAME="singbox"
CLI_LINK_PATH="/usr/local/bin/${CLI_NAME}"
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/singbox-manager.sh}"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PARAMS_FILE="${CONFIG_DIR}/params.env"

CERT_DIR="${CONFIG_DIR}/certs"
CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/key.pem"

LOG_DIR="/var/log/sing-box"
LOG_FILE="${LOG_DIR}/sing-box.log"

SERVICE_NAME="sing-box"
OPENRC_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

IPV6_SYSCTL_FILE="/etc/sysctl.d/99-disable-ipv6.conf"
DEFAULT_WS_PATH="/ws"

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
blue() { printf '\033[34m%s\033[0m\n' "$1"; }
line() { printf '%s\n' "------------------------------------------------------------"; }

check_root() {
    if [ "$(id -u)" != "0" ]; then
        red "请使用 root 运行"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        INIT_SYSTEM="openrc"
        PACKAGE_MANAGER="apk"
    elif [ -f /etc/debian_version ]; then
        if grep -qi ubuntu /etc/os-release 2>/dev/null; then
            OS="ubuntu"
        else
            OS="debian"
        fi
        INIT_SYSTEM="systemd"
        PACKAGE_MANAGER="apt"
    else
        red "不支持的系统，仅支持 Alpine / Debian / Ubuntu"
        exit 1
    fi
    green "系统: ${OS}"
    green "服务管理器: ${INIT_SYSTEM}"
}

detect_arch() {
    CPU_ARCH="$(uname -m)"
    case "$CPU_ARCH" in
        x86_64) SINGBOX_ARCH="amd64" ;;
        aarch64) SINGBOX_ARCH="arm64" ;;
        *)
            red "不支持的 CPU 架构: ${CPU_ARCH}"
            exit 1
            ;;
    esac
    green "CPU: ${CPU_ARCH}"
}

install_dependencies() {
    line
    green "正在更新依赖..."
    case "$PACKAGE_MANAGER" in
        apk)
            apk update
            apk add --no-cache curl wget nano ca-certificates tar gzip openssl openrc iproute2 procps coreutils
            update-ca-certificates >/dev/null 2>&1 || true
            ;;
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget nano ca-certificates tar gzip openssl iproute2 procps coreutils
            update-ca-certificates >/dev/null 2>&1 || true
            ;;
    esac
    green "依赖安装完成"
}

set_default_params() {
    ENABLE_VLESS="${ENABLE_VLESS:-0}"
    ENABLE_ANYTLS="${ENABLE_ANYTLS:-0}"
    VLESS_PORT="${VLESS_PORT:-}"
    WS_PATH="${WS_PATH:-$DEFAULT_WS_PATH}"
    UUID="${UUID:-}"
    WS_HOST="${WS_HOST:-}"
    ANYTLS_PORT="${ANYTLS_PORT:-}"
    ANYTLS_NAME="${ANYTLS_NAME:-user}"
    ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"
    SERVER_ADDR="${SERVER_ADDR:-}"
    NODE_NAME="${NODE_NAME:-sing-box-node}"
}

is_allowed_param_key() {
    case "$1" in
        ENABLE_VLESS|ENABLE_ANYTLS|VLESS_PORT|WS_PATH|UUID|WS_HOST|ANYTLS_PORT|ANYTLS_NAME|ANYTLS_PASSWORD|SERVER_ADDR|NODE_NAME)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

set_param_value() {
    KEY_NAME="$1"
    KEY_VALUE="$2"

    case "$KEY_NAME" in
        ENABLE_VLESS) ENABLE_VLESS="$KEY_VALUE" ;;
        ENABLE_ANYTLS) ENABLE_ANYTLS="$KEY_VALUE" ;;
        VLESS_PORT) VLESS_PORT="$KEY_VALUE" ;;
        WS_PATH) WS_PATH="$KEY_VALUE" ;;
        UUID) UUID="$KEY_VALUE" ;;
        WS_HOST) WS_HOST="$KEY_VALUE" ;;
        ANYTLS_PORT) ANYTLS_PORT="$KEY_VALUE" ;;
        ANYTLS_NAME) ANYTLS_NAME="$KEY_VALUE" ;;
        ANYTLS_PASSWORD) ANYTLS_PASSWORD="$KEY_VALUE" ;;
        SERVER_ADDR) SERVER_ADDR="$KEY_VALUE" ;;
        NODE_NAME) NODE_NAME="$KEY_VALUE" ;;
    esac
}

load_params() {
    set_default_params

    if [ -f "$PARAMS_FILE" ]; then
        while IFS= read -r PARAM_LINE || [ -n "$PARAM_LINE" ]; do
            case "$PARAM_LINE" in
                ''|'#'*)
                    continue
                    ;;
            esac

            PARAM_KEY=${PARAM_LINE%%=*}
            PARAM_VALUE=${PARAM_LINE#*=}

            if [ "$PARAM_KEY" = "$PARAM_LINE" ]; then
                continue
            fi

            if is_allowed_param_key "$PARAM_KEY"; then
                set_param_value "$PARAM_KEY" "$PARAM_VALUE"
            fi
        done < "$PARAMS_FILE"
    fi
}

save_params() {
    mkdir -p "$CONFIG_DIR"
    cat > "$PARAMS_FILE" <<EOF_PARAMS
ENABLE_VLESS=${ENABLE_VLESS}
ENABLE_ANYTLS=${ENABLE_ANYTLS}
VLESS_PORT=${VLESS_PORT}
WS_PATH=${WS_PATH}
UUID=${UUID}
WS_HOST=${WS_HOST}
ANYTLS_PORT=${ANYTLS_PORT}
ANYTLS_NAME=${ANYTLS_NAME}
ANYTLS_PASSWORD=${ANYTLS_PASSWORD}
SERVER_ADDR=${SERVER_ADDR}
NODE_NAME=${NODE_NAME}
EOF_PARAMS
    chmod 600 "$PARAMS_FILE"
}

generate_uuid() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
    fi
}

generate_password() {
    openssl rand -base64 24 | tr -d '\n'
}

detect_public_ip() {
    curl -4fsSL https://api.ipify.org 2>/dev/null || \
    curl -4fsSL https://ifconfig.me 2>/dev/null || \
    echo ""
}

confirm_action() {
    PROMPT_TEXT="$1"
    printf '%s' "$PROMPT_TEXT"
    if ! IFS= read -r INPUT_CONFIRM; then
        return 1
    fi

    case "$INPUT_CONFIRM" in
        y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

check_port_number() {
    PORT_TO_CHECK="$1"
    case "$PORT_TO_CHECK" in
        ''|*[!0-9]*)
            red "端口不是有效数字: ${PORT_TO_CHECK}"
            exit 1
            ;;
    esac
    if [ "$PORT_TO_CHECK" -lt 1 ] || [ "$PORT_TO_CHECK" -gt 65535 ]; then
        red "端口范围无效: ${PORT_TO_CHECK}"
        exit 1
    fi
}

check_port_available_for_singbox() {
    PORT_TO_CHECK="$1"
    check_port_number "$PORT_TO_CHECK"

    PORT_INFO="$(ss -lntup 2>/dev/null | grep -E "[:.]${PORT_TO_CHECK}[[:space:]]" || true)"

    if [ -z "$PORT_INFO" ]; then
        green "端口 ${PORT_TO_CHECK} 可用"
        return 0
    fi

    if printf '%s\n' "$PORT_INFO" | grep -q 'sing-box'; then
        yellow "端口 ${PORT_TO_CHECK} 当前由 sing-box 占用，允许用于重配"
        return 0
    fi

    red "端口 ${PORT_TO_CHECK} 已被其他进程占用"
    printf '%s\n' "$PORT_INFO"
    return 1
}

stop_service_silent() {
    case "$INIT_SYSTEM" in
        openrc)
            [ -x "$OPENRC_SERVICE_FILE" ] && rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
            ;;
        systemd)
            command -v systemctl >/dev/null 2>&1 && systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            ;;
    esac
}

download_singbox() {
    detect_arch

    if [ "$OS" = "alpine" ]; then
        DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_TAG}/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}-musl.tar.gz"
    else
        DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_TAG}/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}.tar.gz"
    fi

    line
    green "正在下载 sing-box..."
    blue "$DOWNLOAD_URL"

    TMP_DIR="$(mktemp -d)"
    ARCHIVE="${TMP_DIR}/sing-box.tar.gz"

    curl -fL "$DOWNLOAD_URL" -o "$ARCHIVE"
    tar -xzf "$ARCHIVE" -C "$TMP_DIR"

    BIN_PATH="$(find "$TMP_DIR" -type f -name sing-box | head -n 1)"
    if [ -z "$BIN_PATH" ]; then
        rm -rf "$TMP_DIR"
        red "未找到 sing-box 文件"
        exit 1
    fi

    install -m 755 "$BIN_PATH" "$BIN_FILE"
    rm -rf "$TMP_DIR"

    green "sing-box 已安装: ${BIN_FILE}"
    "$BIN_FILE" version
}

ensure_singbox_installed() {
    [ -x "$BIN_FILE" ] || download_singbox
}

generate_self_signed_cert() {
    line
    green "正在生成自签证书..."
    mkdir -p "$CERT_DIR"
    rm -f "$CERT_FILE" "$KEY_FILE"

    openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 3650 \
        -nodes \
        -subj "/CN=sing-box-self-signed" >/dev/null 2>&1

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    green "证书生成完成"
}

ensure_cert_exists() {
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        generate_self_signed_cert
    fi
}

prompt_server_addr() {
    printf "请输入服务器 IP（留空自动获取公网 IP）: "
    if ! IFS= read -r INPUT_SERVER_ADDR; then
        return 1
    fi

    if [ -n "$INPUT_SERVER_ADDR" ]; then
        SERVER_ADDR="$INPUT_SERVER_ADDR"
    else
        SERVER_ADDR="$(detect_public_ip)"
    fi

    [ -n "$SERVER_ADDR" ] || SERVER_ADDR="YOUR_SERVER_IP"
    return 0
}

prompt_node_name() {
    printf "请输入节点名称 [默认: sing-box-node]: "
    if ! IFS= read -r INPUT_NODE_NAME; then
        return 1
    fi

    NODE_NAME="${INPUT_NODE_NAME:-sing-box-node}"
    NODE_NAME="$(printf '%s' "$NODE_NAME" | sed 's/[[:space:]]/-/g')"
    return 0
}

prompt_vless() {
    line
    blue "配置 VLESS + WS"
    line

    printf "请输入 VLESS 端口: "
    if ! IFS= read -r INPUT_VLESS_PORT; then
        return 1
    fi
    [ -n "$INPUT_VLESS_PORT" ] || { red "端口不能为空"; return 1; }
    VLESS_PORT="$INPUT_VLESS_PORT"
    check_port_number "$VLESS_PORT"

    printf "请输入 WS Path [默认: %s]: " "$DEFAULT_WS_PATH"
    if ! IFS= read -r INPUT_WS_PATH; then
        return 1
    fi
    WS_PATH="${INPUT_WS_PATH:-$DEFAULT_WS_PATH}"
    case "$WS_PATH" in
        /*) ;;
        *) WS_PATH="/${WS_PATH}" ;;
    esac

    printf "请输入 UUID，留空自动生成: "
    if ! IFS= read -r INPUT_UUID; then
        return 1
    fi
    if [ -n "$INPUT_UUID" ]; then
        UUID="$INPUT_UUID"
    else
        UUID="$(generate_uuid)"
    fi

    printf "请输入 WebSocket Host，留空则不设置: "
    if ! IFS= read -r INPUT_WS_HOST; then
        return 1
    fi
    WS_HOST="$INPUT_WS_HOST"

    ENABLE_VLESS=1
    return 0
}

prompt_anytls() {
    line
    blue "配置 AnyTLS"
    line

    printf "请输入 AnyTLS 端口: "
    if ! IFS= read -r INPUT_ANYTLS_PORT; then
        return 1
    fi
    [ -n "$INPUT_ANYTLS_PORT" ] || { red "端口不能为空"; return 1; }
    ANYTLS_PORT="$INPUT_ANYTLS_PORT"
    check_port_number "$ANYTLS_PORT"

    printf "请输入 AnyTLS 用户名 [默认: user]: "
    if ! IFS= read -r INPUT_ANYTLS_NAME; then
        return 1
    fi
    ANYTLS_NAME="${INPUT_ANYTLS_NAME:-user}"

    printf "请输入 AnyTLS 密码，留空自动生成: "
    if ! IFS= read -r INPUT_ANYTLS_PASSWORD; then
        return 1
    fi
    if [ -n "$INPUT_ANYTLS_PASSWORD" ]; then
        ANYTLS_PASSWORD="$INPUT_ANYTLS_PASSWORD"
    else
        ANYTLS_PASSWORD="$(generate_password)"
    fi

    ENABLE_ANYTLS=1
    return 0
}

json_escape() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/	/\\t/g' \
        -e 's/\r/\\r/g' \
        -e ':a;N;$!ba;s/\n/\\n/g'
}

generate_config_to_file() {
    TARGET_CONFIG_FILE="$1"

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"

    cat > "$TARGET_CONFIG_FILE" <<EOF_CONF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true,
    "output": "$(json_escape "$LOG_FILE")"
  },
  "inbounds": [
EOF_CONF

    wrote_anything=0

    if [ "${ENABLE_VLESS}" = "1" ]; then
        UUID_ESCAPED="$(json_escape "$UUID")"
        WS_PATH_ESCAPED="$(json_escape "$WS_PATH")"
        cat >> "$TARGET_CONFIG_FILE" <<EOF_CONF
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${UUID_ESCAPED}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH_ESCAPED}",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
EOF_CONF
        wrote_anything=1
    fi

    if [ "${ENABLE_ANYTLS}" = "1" ]; then
        ensure_cert_exists
        ANYTLS_NAME_ESCAPED="$(json_escape "$ANYTLS_NAME")"
        ANYTLS_PASSWORD_ESCAPED="$(json_escape "$ANYTLS_PASSWORD")"
        CERT_FILE_ESCAPED="$(json_escape "$CERT_FILE")"
        KEY_FILE_ESCAPED="$(json_escape "$KEY_FILE")"

        if [ "$wrote_anything" = "1" ]; then
            printf ',\n' >> "$TARGET_CONFIG_FILE"
        fi
        cat >> "$TARGET_CONFIG_FILE" <<EOF_CONF
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        {
          "name": "${ANYTLS_NAME_ESCAPED}",
          "password": "${ANYTLS_PASSWORD_ESCAPED}"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_FILE_ESCAPED}",
        "key_path": "${KEY_FILE_ESCAPED}"
      }
    }
EOF_CONF
        wrote_anything=1
    fi

    if [ "$wrote_anything" = "0" ]; then
        rm -f "$TARGET_CONFIG_FILE"
        yellow "当前未启用任何节点，未生成配置"
        return 1
    fi

    cat >> "$TARGET_CONFIG_FILE" <<EOF_CONF

  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF_CONF

    chmod 600 "$TARGET_CONFIG_FILE"

    if [ -x "$BIN_FILE" ]; then
        if ! "$BIN_FILE" check -c "$TARGET_CONFIG_FILE"; then
            red "配置校验失败，已取消应用"
            rm -f "$TARGET_CONFIG_FILE"
            return 1
        fi
    fi

    green "配置校验通过"
    return 0
}

apply_generated_config() {
    TMP_CONFIG_FILE="${CONFIG_FILE}.tmp.$$"

    if ! generate_config_to_file "$TMP_CONFIG_FILE"; then
        return 1
    fi

    mv "$TMP_CONFIG_FILE" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    green "配置已生成: ${CONFIG_FILE}"
    return 0
}

create_openrc_service() {
    mkdir -p "$LOG_DIR"

    cat > "$OPENRC_SERVICE_FILE" <<EOF_SERVICE
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"

command="${BIN_FILE}"
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

start_pre() {
    if [ ! -x "${BIN_FILE}" ]; then
        eerror "sing-box 二进制不存在: ${BIN_FILE}"
        return 1
    fi

    if [ ! -f "${CONFIG_FILE}" ]; then
        eerror "配置文件不存在: ${CONFIG_FILE}"
        return 1
    fi

    ${BIN_FILE} check -c ${CONFIG_FILE}
}

depend() {
    need net
    after firewall
}
EOF_SERVICE
    chmod +x "$OPENRC_SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    green "OpenRC 服务已创建"
}

create_systemd_service() {
    mkdir -p "$LOG_DIR"

    cat > "$SYSTEMD_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'test -x "${BIN_FILE}"'
ExecStartPre=/bin/sh -c 'test -f "${CONFIG_FILE}"'
ExecStartPre=${BIN_FILE} check -c ${CONFIG_FILE}
ExecStart=${BIN_FILE} run -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    green "systemd 服务已创建"
}

create_service() {
    case "$INIT_SYSTEM" in
        openrc) create_openrc_service ;;
        systemd) create_systemd_service ;;
    esac
}

stop_service_if_no_config() {
    if [ -f "$CONFIG_FILE" ]; then
        return 0
    fi

    line
    yellow "未生成有效配置，停止 sing-box 服务"
    stop_service_silent
    return 0
}

start_or_restart_service() {
    if [ ! -f "$CONFIG_FILE" ]; then
        stop_service_if_no_config
        return 0
    fi

    line
    green "正在启动 / 重启 sing-box..."

    mkdir -p "$LOG_DIR"
    : > "$LOG_FILE"

    case "$INIT_SYSTEM" in
        openrc)
            rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
            ;;
        systemd)
            systemctl restart "$SERVICE_NAME"
            ;;
    esac
    sleep 1
    green "完成"
}

urlencode_path() {
    printf '%s' "$1" | sed 's#/#%2F#g'
}

generate_vless_link() {
    ENCODED_PATH="$(urlencode_path "$WS_PATH")"
    [ -n "$NODE_NAME" ] || NODE_NAME="sing-box-node"

    case "$SERVER_ADDR" in
        *:*)
            HOST_PART="[${SERVER_ADDR}]"
            ;;
        *)
            HOST_PART="${SERVER_ADDR}"
            ;;
    esac

    if [ -n "$WS_HOST" ]; then
        VLESS_LINK="vless://${UUID}@${HOST_PART}:${VLESS_PORT}?type=ws&security=none&path=${ENCODED_PATH}&host=${WS_HOST}#${NODE_NAME}"
    else
        VLESS_LINK="vless://${UUID}@${HOST_PART}:${VLESS_PORT}?type=ws&security=none&path=${ENCODED_PATH}#${NODE_NAME}"
    fi
}

show_info() {
    load_params
    line
    green "当前节点信息"
    line
    printf "节点名称: %s\n" "$NODE_NAME"
    printf "服务器地址: %s\n" "$SERVER_ADDR"
    printf "监听: IPv4 + IPv6\n"
    line

    if [ "${ENABLE_VLESS}" = "1" ]; then
        generate_vless_link
        blue "VLESS + WS:"
        printf "端口: %s\n" "$VLESS_PORT"
        printf "UUID: %s\n" "$UUID"
        printf "WS Path: %s\n" "$WS_PATH"
        printf "WS Host: %s\n" "${WS_HOST:-无}"
        printf "分享链接:\n%s\n" "$VLESS_LINK"
    else
        yellow "VLESS + WS: 未启用"
    fi

    line

    if [ "${ENABLE_ANYTLS}" = "1" ]; then
        blue "AnyTLS:"
        printf "端口: %s\n" "$ANYTLS_PORT"
        printf "用户名: %s\n" "$ANYTLS_NAME"
        printf "密码: %s\n" "$ANYTLS_PASSWORD"
        printf "SNI: 留空\n"
        printf "证书: 自签证书\n"
    else
        yellow "AnyTLS: 未启用"
    fi
}

show_service_autostart_status() {
    line
    green "服务自启 / 自动重启状态"
    line

    case "$INIT_SYSTEM" in
        openrc)
            if rc-update show default 2>/dev/null | grep -Eq "(^|[[:space:]])${SERVICE_NAME}([[:space:]]|$)"; then
                printf "开机自启: 已启用\n"
            else
                printf "开机自启: 未启用或无法确认\n"
            fi
            printf "自动重启: OpenRC 当前未额外启用守护重启\n"
            ;;
        systemd)
            if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
                printf "开机自启: 已启用\n"
            else
                printf "开机自启: 未启用\n"
            fi
            printf "自动重启策略: Restart=always, RestartSec=5\n"
            ;;
    esac
}

show_runtime_status() {
    line
    green "运行状态"
    line
    [ -x "$BIN_FILE" ] && "$BIN_FILE" version || true
    line
    case "$INIT_SYSTEM" in
        openrc) rc-service "$SERVICE_NAME" status || true ;;
        systemd) systemctl status "$SERVICE_NAME" --no-pager || true ;;
    esac
    line
    pgrep -a sing-box || yellow "未发现 sing-box 进程"
    line
    ss -lntup 2>/dev/null | grep 'sing-box' || yellow "未发现 sing-box 监听信息"
    show_service_autostart_status
}

show_service_logs() {
    line
    green "查看 sing-box 日志"
    line

    case "$INIT_SYSTEM" in
        systemd)
            journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
            ;;
        openrc)
            if [ -f "$LOG_FILE" ]; then
                tail -n 50 "$LOG_FILE" || true
            else
                yellow "日志文件不存在: ${LOG_FILE}"
            fi
            ;;
    esac
}

rebuild_service_files() {
    line
    green "正在重建服务文件..."
    create_service
    start_or_restart_service
    green "服务文件已重建"
}

restart_singbox_service() {
    line
    green "重启 sing-box..."

    if [ ! -f "$CONFIG_FILE" ]; then
        yellow "配置文件不存在，已停止服务"
        stop_service_silent
        return 0
    fi

    if [ -x "$BIN_FILE" ]; then
        if ! "$BIN_FILE" check -c "$CONFIG_FILE"; then
            red "配置校验失败，取消重启"
            return 1
        fi
    fi

    mkdir -p "$LOG_DIR"
    : > "$LOG_FILE"

    case "$INIT_SYSTEM" in
        openrc) rc-service "$SERVICE_NAME" restart ;;
        systemd) systemctl restart "$SERVICE_NAME" ;;
    esac
}

disable_ipv6_persistent() {
    line
    if confirm_action "确认禁用 IPv6？[y/N]: "; then
        mkdir -p /etc/sysctl.d
        cat > "$IPV6_SYSCTL_FILE" <<EOF_IPV6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF_IPV6
        sysctl -p "$IPV6_SYSCTL_FILE" >/dev/null 2>&1 || true
        case "$INIT_SYSTEM" in
            openrc)
                rc-update add sysctl boot >/dev/null 2>&1 || true
                rc-service sysctl restart >/dev/null 2>&1 || true
                ;;
            systemd)
                systemctl restart systemd-sysctl >/dev/null 2>&1 || true
                ;;
        esac
        green "IPv6 已禁用"
    else
        yellow "已取消"
    fi
}

enable_ipv6_persistent() {
    line
    if confirm_action "确认恢复 IPv6？[y/N]: "; then
        rm -f "$IPV6_SYSCTL_FILE"
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
        case "$INIT_SYSTEM" in
            openrc)
                rc-update add sysctl boot >/dev/null 2>&1 || true
                rc-service sysctl restart >/dev/null 2>&1 || true
                ;;
            systemd)
                systemctl restart systemd-sysctl >/dev/null 2>&1 || true
                ;;
        esac
        green "IPv6 已恢复"
    else
        yellow "已取消"
    fi
}

prompt_server_or_auto() {
    printf "服务器 IP 选择：1) 手动输入  2) 自动获取公网 IP [默认: 2]: "
    if ! IFS= read -r IP_CHOICE; then
        return 1
    fi

    case "$IP_CHOICE" in
        1)
            prompt_server_addr || return 1
            ;;
        *)
            SERVER_ADDR="$(detect_public_ip)"
            [ -n "$SERVER_ADDR" ] || SERVER_ADDR="YOUR_SERVER_IP"
            green "已自动获取公网 IP: ${SERVER_ADDR}"
            ;;
    esac

    return 0
}

create_vless_node() {
    ensure_singbox_installed
    load_params

    if ! prompt_server_or_auto; then
        yellow "已返回菜单"
        return 1
    fi
    if ! prompt_node_name; then
        yellow "已返回菜单"
        return 1
    fi
    if ! prompt_vless; then
        yellow "已返回菜单"
        return 1
    fi

    if [ "${ENABLE_ANYTLS}" = "1" ] && [ -n "${ANYTLS_PORT}" ] && [ "$VLESS_PORT" = "$ANYTLS_PORT" ]; then
        red "VLESS 端口和 AnyTLS 端口不能相同"
        return 1
    fi

    if ! check_port_available_for_singbox "$VLESS_PORT"; then
        return 1
    fi

    line
    green "正在生成配置..."
    if ! apply_generated_config; then
        return 1
    fi

    save_params
    create_service
    start_or_restart_service
    show_info
}

create_anytls_node() {
    ensure_singbox_installed
    load_params

    if ! prompt_server_or_auto; then
        yellow "已返回菜单"
        return 1
    fi
    if ! prompt_node_name; then
        yellow "已返回菜单"
        return 1
    fi
    if ! prompt_anytls; then
        yellow "已返回菜单"
        return 1
    fi

    if [ "${ENABLE_VLESS}" = "1" ] && [ -n "${VLESS_PORT}" ] && [ "$VLESS_PORT" = "$ANYTLS_PORT" ]; then
        red "VLESS 端口和 AnyTLS 端口不能相同"
        return 1
    fi

    if ! check_port_available_for_singbox "$ANYTLS_PORT"; then
        return 1
    fi

    line
    green "正在生成配置..."
    if ! apply_generated_config; then
        return 1
    fi

    save_params
    create_service
    start_or_restart_service
    show_info
}

reconfigure_vless() { create_vless_node; }
reconfigure_anytls() { create_anytls_node; }

delete_vless() {
    load_params
    if [ "$ENABLE_VLESS" != "1" ]; then
        yellow "VLESS + WS 未启用"
        return
    fi

    if confirm_action "确认删除 VLESS + WS 节点？[y/N]: "; then
        stop_service_silent
        ENABLE_VLESS=0
        VLESS_PORT=""
        WS_PATH="$DEFAULT_WS_PATH"
        UUID=""
        WS_HOST=""
        save_params

        if [ "${ENABLE_ANYTLS}" = "1" ]; then
            line
            green "正在生成配置..."
            if ! apply_generated_config; then
                red "删除后配置生成失败，请检查参数"
                return 1
            fi
            create_service
            start_or_restart_service
        else
            rm -f "$CONFIG_FILE"
            create_service
            start_or_restart_service
        fi

        green "VLESS + WS 已删除"
    else
        yellow "已取消"
    fi
}

delete_anytls() {
    load_params
    if [ "$ENABLE_ANYTLS" != "1" ]; then
        yellow "AnyTLS 未启用"
        return
    fi

    if confirm_action "确认删除 AnyTLS 节点？[y/N]: "; then
        stop_service_silent
        ENABLE_ANYTLS=0
        ANYTLS_PORT=""
        ANYTLS_NAME="user"
        ANYTLS_PASSWORD=""
        rm -f "$CERT_FILE" "$KEY_FILE"
        save_params

        if [ "${ENABLE_VLESS}" = "1" ]; then
            line
            green "正在生成配置..."
            if ! apply_generated_config; then
                red "删除后配置生成失败，请检查参数"
                return 1
            fi
            create_service
            start_or_restart_service
        else
            rm -f "$CONFIG_FILE"
            create_service
            start_or_restart_service
        fi

        green "AnyTLS 已删除"
    else
        yellow "已取消"
    fi
}

uninstall_all() {
    if confirm_action "确认卸载 sing-box？[y/N]: "; then
        case "$INIT_SYSTEM" in
            openrc)
                rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
                rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
                rm -f "$OPENRC_SERVICE_FILE"
                ;;
            systemd)
                systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
                systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f "$SYSTEMD_SERVICE_FILE"
                systemctl daemon-reload >/dev/null 2>&1 || true
                ;;
        esac
        rm -f "$BIN_FILE"
        [ -d "$CONFIG_DIR" ] && rm -rf "$CONFIG_DIR"
        [ -d "$LOG_DIR" ] && rm -rf "$LOG_DIR"
        [ -f "$CLI_LINK_PATH" ] && rm -f "$CLI_LINK_PATH"
        green "已卸载"
    else
        yellow "已取消"
    fi
}

install_cli_command() {
    line
    green "正在安装命令入口..."

    if ! curl -fL "$REPO_RAW_URL" -o "$CLI_LINK_PATH"; then
        red "下载脚本失败，请检查 REPO_RAW_URL"
        return 1
    fi

    chmod 755 "$CLI_LINK_PATH"

    green "命令已安装: ${CLI_LINK_PATH}"
    green "以后可直接输入: ${CLI_NAME}"
}

install_only() {
    install_dependencies
    download_singbox
    create_service

    if [ -f "$CONFIG_FILE" ]; then
        start_or_restart_service
    else
        yellow "当前未配置任何节点，已完成安装，但不会启动 sing-box"
    fi

    install_cli_command || true
}

exit_with_hint() {
    green "已退出，后续可直接输入 ${CLI_NAME} 打开菜单"
    exit 0
}

menu() {
    while true; do
        line
        blue "sing-box 中文管理菜单"
        line
        printf "1. 安装 / 更新 sing-box\n"
        printf "2. 新建 VLESS + WS\n"
        printf "3. 新建 AnyTLS\n"
        printf "4. 重配 VLESS + WS\n"
        printf "5. 重配 AnyTLS\n"
        printf "6. 删除 VLESS + WS\n"
        printf "7. 删除 AnyTLS\n"
        printf "8. 查看节点信息\n"
        printf "9. 查看运行状态\n"
        printf "10. 重启 sing-box\n"
        printf "11. 查看 sing-box 日志\n"
        printf "12. 重建服务文件\n"
        printf "13. 安装 singbox 命令入口\n"
        printf "14. 禁用 IPv6\n"
        printf "15. 恢复 IPv6\n"
        printf "16. 卸载 sing-box\n"
        printf "0. 退出\n"
        line
        printf "请选择: "
        if ! IFS= read -r CHOICE; then
            yellow "输入失败，返回菜单"
            continue
        fi

        case "$CHOICE" in
            1) install_only ;;
            2) create_vless_node ;;
            3) create_anytls_node ;;
            4) reconfigure_vless ;;
            5) reconfigure_anytls ;;
            6) delete_vless ;;
            7) delete_anytls ;;
            8) show_info ;;
            9) show_runtime_status ;;
            10) restart_singbox_service ;;
            11) show_service_logs ;;
            12) rebuild_service_files ;;
            13) install_cli_command ;;
            14) disable_ipv6_persistent ;;
            15) enable_ipv6_persistent ;;
            16) uninstall_all ;;
            0) exit_with_hint ;;
            *) red "无效选择" ;;
        esac
    done
}

main() {
    check_root
    detect_os
    detect_arch
    load_params
    menu
}

main "$@"
