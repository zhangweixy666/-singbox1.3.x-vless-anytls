#!/bin/sh

set -eu

SINGBOX_VERSION="1.13.14"
SINGBOX_TAG="v${SINGBOX_VERSION}"

INSTALL_DIR="/usr/local/bin"
BIN_FILE="${INSTALL_DIR}/sing-box"

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

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

CF_DIR="/etc/cloudflared"
CF_CONFIG_FILE="${CF_DIR}/config.yml"
CF_LOG_FILE="/var/log/cloudflared.log"

SERVICE_NAME="sing-box"
OPENRC_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

CF_SERVICE_NAME="cloudflared"
CF_OPENRC_START_FILE="/etc/local.d/cloudflared.start"
CF_OPENRC_STOP_FILE="/etc/local.d/cloudflared.stop"
CF_SYSTEMD_SERVICE_FILE="/etc/systemd/system/${CF_SERVICE_NAME}.service"

IPV6_SYSCTL_FILE="/etc/sysctl.d/99-disable-ipv6.conf"

DEFAULT_DIRECT_WS_PATH="/ws"
DEFAULT_TUNNEL_WS_PATH="/wst"

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
        x86_64)
            SINGBOX_ARCH="amd64"
            CF_ARCH="amd64"
            ;;
        aarch64)
            SINGBOX_ARCH="arm64"
            CF_ARCH="arm64"
            ;;
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
    ENABLE_VLESS_DIRECT="${ENABLE_VLESS_DIRECT:-0}"
    ENABLE_VLESS_TUNNEL="${ENABLE_VLESS_TUNNEL:-0}"

    VLESS_DIRECT_PORT="${VLESS_DIRECT_PORT:-}"
    VLESS_DIRECT_PATH="${VLESS_DIRECT_PATH:-$DEFAULT_DIRECT_WS_PATH}"
    VLESS_DIRECT_UUID="${VLESS_DIRECT_UUID:-}"
    VLESS_DIRECT_HOST="${VLESS_DIRECT_HOST:-}"

    VLESS_TUNNEL_PORT="${VLESS_TUNNEL_PORT:-}"
    VLESS_TUNNEL_PATH="${VLESS_TUNNEL_PATH:-$DEFAULT_TUNNEL_WS_PATH}"
    VLESS_TUNNEL_UUID="${VLESS_TUNNEL_UUID:-}"

    CF_BASE_DOMAIN="${CF_BASE_DOMAIN:-}"
    CF_SUBDOMAIN="${CF_SUBDOMAIN:-}"
    CF_FULL_DOMAIN="${CF_FULL_DOMAIN:-}"
    CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-singbox}"
    CF_TUNNEL_ID="${CF_TUNNEL_ID:-}"

    ENABLE_ANYTLS="${ENABLE_ANYTLS:-0}"
    ANYTLS_PORT="${ANYTLS_PORT:-}"
    ANYTLS_NAME="${ANYTLS_NAME:-user}"
    ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"

    SERVER_ADDR="${SERVER_ADDR:-}"
    NODE_NAME="${NODE_NAME:-sing-box-node}"
}

is_allowed_param_key() {
    case "$1" in
        ENABLE_VLESS_DIRECT|ENABLE_VLESS_TUNNEL|VLESS_DIRECT_PORT|VLESS_DIRECT_PATH|VLESS_DIRECT_UUID|VLESS_DIRECT_HOST|VLESS_TUNNEL_PORT|VLESS_TUNNEL_PATH|VLESS_TUNNEL_UUID|CF_BASE_DOMAIN|CF_SUBDOMAIN|CF_FULL_DOMAIN|CF_TUNNEL_NAME|CF_TUNNEL_ID|ENABLE_ANYTLS|ANYTLS_PORT|ANYTLS_NAME|ANYTLS_PASSWORD|SERVER_ADDR|NODE_NAME)
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
        ENABLE_VLESS_DIRECT) ENABLE_VLESS_DIRECT="$KEY_VALUE" ;;
        ENABLE_VLESS_TUNNEL) ENABLE_VLESS_TUNNEL="$KEY_VALUE" ;;
        VLESS_DIRECT_PORT) VLESS_DIRECT_PORT="$KEY_VALUE" ;;
        VLESS_DIRECT_PATH) VLESS_DIRECT_PATH="$KEY_VALUE" ;;
        VLESS_DIRECT_UUID) VLESS_DIRECT_UUID="$KEY_VALUE" ;;
        VLESS_DIRECT_HOST) VLESS_DIRECT_HOST="$KEY_VALUE" ;;
        VLESS_TUNNEL_PORT) VLESS_TUNNEL_PORT="$KEY_VALUE" ;;
        VLESS_TUNNEL_PATH) VLESS_TUNNEL_PATH="$KEY_VALUE" ;;
        VLESS_TUNNEL_UUID) VLESS_TUNNEL_UUID="$KEY_VALUE" ;;
        CF_BASE_DOMAIN) CF_BASE_DOMAIN="$KEY_VALUE" ;;
        CF_SUBDOMAIN) CF_SUBDOMAIN="$KEY_VALUE" ;;
        CF_FULL_DOMAIN) CF_FULL_DOMAIN="$KEY_VALUE" ;;
        CF_TUNNEL_NAME) CF_TUNNEL_NAME="$KEY_VALUE" ;;
        CF_TUNNEL_ID) CF_TUNNEL_ID="$KEY_VALUE" ;;
        ENABLE_ANYTLS) ENABLE_ANYTLS="$KEY_VALUE" ;;
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
ENABLE_VLESS_DIRECT=${ENABLE_VLESS_DIRECT}
ENABLE_VLESS_TUNNEL=${ENABLE_VLESS_TUNNEL}
VLESS_DIRECT_PORT=${VLESS_DIRECT_PORT}
VLESS_DIRECT_PATH=${VLESS_DIRECT_PATH}
VLESS_DIRECT_UUID=${VLESS_DIRECT_UUID}
VLESS_DIRECT_HOST=${VLESS_DIRECT_HOST}
VLESS_TUNNEL_PORT=${VLESS_TUNNEL_PORT}
VLESS_TUNNEL_PATH=${VLESS_TUNNEL_PATH}
VLESS_TUNNEL_UUID=${VLESS_TUNNEL_UUID}
CF_BASE_DOMAIN=${CF_BASE_DOMAIN}
CF_SUBDOMAIN=${CF_SUBDOMAIN}
CF_FULL_DOMAIN=${CF_FULL_DOMAIN}
CF_TUNNEL_NAME=${CF_TUNNEL_NAME}
CF_TUNNEL_ID=${CF_TUNNEL_ID}
ENABLE_ANYTLS=${ENABLE_ANYTLS}
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

stop_cloudflared_silent() {
    case "$INIT_SYSTEM" in
        openrc)
            pkill -f "${CLOUDFLARED_BIN} tunnel --config ${CF_CONFIG_FILE} run" >/dev/null 2>&1 || true
            ;;
        systemd)
            command -v systemctl >/dev/null 2>&1 && systemctl stop "$CF_SERVICE_NAME" >/dev/null 2>&1 || true
            ;;
    esac
}

json_escape() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/	/\\t/g' \
        -e 's/\r/\\r/g' \
        -e ':a;N;$!ba;s/\n/\\n/g'
}

urlencode_path() {
    printf '%s' "$1" | sed 's#/#%2F#g'
}

normalize_path() {
    INPUT_PATH="$1"
    case "$INPUT_PATH" in
        /*) printf '%s\n' "$INPUT_PATH" ;;
        *) printf '/%s\n' "$INPUT_PATH" ;;
    esac
}

compose_tunnel_domain() {
    if [ -n "${CF_SUBDOMAIN}" ] && [ -n "${CF_BASE_DOMAIN}" ]; then
        CF_FULL_DOMAIN="${CF_SUBDOMAIN}.${CF_BASE_DOMAIN}"
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

download_cloudflared() {
    detect_arch

    case "$CF_ARCH" in
        amd64)
            CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        arm64)
            CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            red "不支持的 cloudflared 架构"
            exit 1
            ;;
    esac

    line
    green "正在下载 cloudflared..."
    blue "$CF_URL"

    TMP_FILE="$(mktemp)"
    curl -fL "$CF_URL" -o "$TMP_FILE"
    install -m 755 "$TMP_FILE" "$CLOUDFLARED_BIN"
    rm -f "$TMP_FILE"

    green "cloudflared 已安装: ${CLOUDFLARED_BIN}"
    "$CLOUDFLARED_BIN" --version
}

ensure_cloudflared_installed() {
    [ -x "$CLOUDFLARED_BIN" ] || download_cloudflared
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

prompt_base_domain() {
    printf "请输入 Cloudflare 基础域名（例如 ctvctv.ggff.net）: "
    if ! IFS= read -r INPUT_BASE_DOMAIN; then
        return 1
    fi
    [ -n "$INPUT_BASE_DOMAIN" ] || { red "基础域名不能为空"; return 1; }
    CF_BASE_DOMAIN="$INPUT_BASE_DOMAIN"
    return 0
}

prompt_tunnel_domain() {
    printf "请输入 Cloudflare 基础域名（例如 ctvctv.ggff.net）: "
    if ! IFS= read -r INPUT_BASE_DOMAIN; then
        return 1
    fi
    [ -n "$INPUT_BASE_DOMAIN" ] || { red "基础域名不能为空"; return 1; }
    CF_BASE_DOMAIN="$INPUT_BASE_DOMAIN"

    printf "请输入 Tunnel 域名前缀或完整域名: "
    if ! IFS= read -r INPUT_DOMAIN; then
        return 1
    fi
    [ -n "$INPUT_DOMAIN" ] || { red "域名不能为空"; return 1; }

    case "$INPUT_DOMAIN" in
        *.*)
            CF_FULL_DOMAIN="$INPUT_DOMAIN"
            CF_SUBDOMAIN="${INPUT_DOMAIN%%.*}"
            ;;
        *)
            CF_SUBDOMAIN="$INPUT_DOMAIN"
            CF_FULL_DOMAIN="${CF_SUBDOMAIN}.${CF_BASE_DOMAIN}"
            ;;
    esac

    [ -n "$CF_FULL_DOMAIN" ] || { red "拼接完整域名失败"; return 1; }
    return 0
}

prompt_vless_direct() {
    line
    blue "配置 VLESS 直连"
    line

    printf "请输入 VLESS 直连端口: "
    if ! IFS= read -r INPUT_PORT; then
        return 1
    fi
    [ -n "$INPUT_PORT" ] || { red "端口不能为空"; return 1; }
    VLESS_DIRECT_PORT="$INPUT_PORT"
    check_port_number "$VLESS_DIRECT_PORT"

    printf "请输入 VLESS 直连 WS Path [默认: %s]: " "$DEFAULT_DIRECT_WS_PATH"
    if ! IFS= read -r INPUT_PATH; then
        return 1
    fi
    INPUT_PATH="${INPUT_PATH:-$DEFAULT_DIRECT_WS_PATH}"
    VLESS_DIRECT_PATH="$(normalize_path "$INPUT_PATH")"

    printf "请输入 VLESS 直连 UUID，留空自动生成: "
    if ! IFS= read -r INPUT_UUID; then
        return 1
    fi
    if [ -n "$INPUT_UUID" ]; then
        VLESS_DIRECT_UUID="$INPUT_UUID"
    else
        VLESS_DIRECT_UUID="$(generate_uuid)"
    fi

    printf "请输入 VLESS 直连 WebSocket Host，留空则不设置: "
    if ! IFS= read -r INPUT_HOST; then
        return 1
    fi
    VLESS_DIRECT_HOST="$INPUT_HOST"

    ENABLE_VLESS_DIRECT=1
    return 0
}

prompt_vless_tunnel() {
    line
    blue "配置 VLESS Tunnel"
    line

    printf "请输入 VLESS Tunnel 本地端口: "
    if ! IFS= read -r INPUT_PORT; then
        return 1
    fi
    [ -n "$INPUT_PORT" ] || { red "端口不能为空"; return 1; }
    VLESS_TUNNEL_PORT="$INPUT_PORT"
    check_port_number "$VLESS_TUNNEL_PORT"

    printf "请输入 VLESS Tunnel WS Path [默认: %s]: " "$DEFAULT_TUNNEL_WS_PATH"
    if ! IFS= read -r INPUT_PATH; then
        return 1
    fi
    INPUT_PATH="${INPUT_PATH:-$DEFAULT_TUNNEL_WS_PATH}"
    VLESS_TUNNEL_PATH="$(normalize_path "$INPUT_PATH")"

    printf "请输入 VLESS Tunnel UUID，留空自动生成: "
    if ! IFS= read -r INPUT_UUID; then
        return 1
    fi
    if [ -n "$INPUT_UUID" ]; then
        VLESS_TUNNEL_UUID="$INPUT_UUID"
    else
        VLESS_TUNNEL_UUID="$(generate_uuid)"
    fi

    printf "请输入 Tunnel 名称 [默认: singbox]: "
    if ! IFS= read -r INPUT_TUNNEL_NAME; then
        return 1
    fi
    CF_TUNNEL_NAME="${INPUT_TUNNEL_NAME:-singbox}"

    if ! prompt_tunnel_domain; then
        return 1
    fi

    ENABLE_VLESS_TUNNEL=1
    return 0
}

prompt_anytls() {
    line
    blue "配置 AnyTLS"
    line

    printf "请输入 AnyTLS 端口: "
    if ! IFS= read -r INPUT_PORT; then
        return 1
    fi
    [ -n "$INPUT_PORT" ] || { red "端口不能为空"; return 1; }
    ANYTLS_PORT="$INPUT_PORT"
    check_port_number "$ANYTLS_PORT"

    printf "请输入 AnyTLS 用户名 [默认: user]: "
    if ! IFS= read -r INPUT_NAME; then
        return 1
    fi
    ANYTLS_NAME="${INPUT_NAME:-user}"

    printf "请输入 AnyTLS 密码，留空自动生成: "
    if ! IFS= read -r INPUT_PASSWORD; then
        return 1
    fi
    if [ -n "$INPUT_PASSWORD" ]; then
        ANYTLS_PASSWORD="$INPUT_PASSWORD"
    else
        ANYTLS_PASSWORD="$(generate_password)"
    fi

    ENABLE_ANYTLS=1
    return 0
}

write_cloudflared_config() {
    if [ -z "${CF_TUNNEL_ID}" ] || [ -z "${CF_FULL_DOMAIN}" ] || [ -z "${VLESS_TUNNEL_PORT}" ]; then
        red "Cloudflare Tunnel 参数不完整"
        return 1
    fi

    mkdir -p "$CF_DIR"

    cat > "$CF_CONFIG_FILE" <<EOF_CF
tunnel: ${CF_TUNNEL_ID}
credentials-file: /root/.cloudflared/${CF_TUNNEL_ID}.json

ingress:
  - hostname: ${CF_FULL_DOMAIN}
    service: http://127.0.0.1:${VLESS_TUNNEL_PORT}
  - service: http_status:404
EOF_CF

    green "cloudflared 配置已生成: ${CF_CONFIG_FILE}"
}

cloudflared_login() {
    ensure_cloudflared_installed
    line
    green "请按提示登录 Cloudflare..."
    "$CLOUDFLARED_BIN" tunnel login
}

ensure_cloudflare_login() {
    if [ ! -f /root/.cloudflared/cert.pem ]; then
        yellow "未检测到 Cloudflare 登录凭据，开始登录..."
        cloudflared_login
    fi
}

create_or_use_tunnel() {
    ensure_cloudflared_installed
    ensure_cloudflare_login

    if [ -z "${CF_TUNNEL_NAME}" ]; then
        CF_TUNNEL_NAME="singbox"
    fi

    line
    green "检查 Tunnel: ${CF_TUNNEL_NAME}"

    EXISTING_ID="$($CLOUDFLARED_BIN tunnel list 2>/dev/null | awk -v name="$CF_TUNNEL_NAME" 'NR>1 && $2==name {print $1; exit}' || true)"

    if [ -n "$EXISTING_ID" ]; then
        CF_TUNNEL_ID="$EXISTING_ID"
        green "复用已有 Tunnel ID: ${CF_TUNNEL_ID}"
        return 0
    fi

    CREATE_OUTPUT="$($CLOUDFLARED_BIN tunnel create "$CF_TUNNEL_NAME" 2>&1 || true)"
    printf '%s\n' "$CREATE_OUTPUT"

    CF_TUNNEL_ID="$(printf '%s\n' "$CREATE_OUTPUT" | sed -n 's/.*with id \([0-9a-f-][0-9a-f-]*\).*/\1/p' | head -n 1)"

    if [ -n "$CF_TUNNEL_ID" ]; then
        green "Tunnel 创建完成: ${CF_TUNNEL_ID}"
        return 0
    fi

    if printf '%s\n' "$CREATE_OUTPUT" | grep -qi 'tunnel with name already exists'; then
        EXISTING_ID="$($CLOUDFLARED_BIN tunnel list 2>/dev/null | awk -v name="$CF_TUNNEL_NAME" 'NR>1 && $2==name {print $1; exit}' || true)"
        if [ -n "$EXISTING_ID" ]; then
            CF_TUNNEL_ID="$EXISTING_ID"
            green "发现已存在同名 Tunnel，复用 ID: ${CF_TUNNEL_ID}"
            return 0
        fi
    fi

    red "未能创建或解析 Tunnel ID"
    return 1
}

route_tunnel_dns() {
    if [ -z "${CF_TUNNEL_NAME}" ] || [ -z "${CF_FULL_DOMAIN}" ]; then
        red "Tunnel 名称或域名为空"
        return 1
    fi

    line
    green "绑定 DNS: ${CF_FULL_DOMAIN}"

    ROUTE_OUTPUT="$($CLOUDFLARED_BIN tunnel route dns --overwrite-dns "$CF_TUNNEL_NAME" "$CF_FULL_DOMAIN" 2>&1 || true)"
    printf '%s\n' "$ROUTE_OUTPUT"

    if printf '%s\n' "$ROUTE_OUTPUT" | grep -qi 'already configured to route to your tunnel'; then
        EXISTING_TUNNEL_ID="$(printf '%s\n' "$ROUTE_OUTPUT" | sed -n 's/.*tunnelID=\([0-9a-f-][0-9a-f-]*\).*/\1/p' | head -n 1)"
        yellow "该域名已经绑定到其他 Tunnel"
        [ -n "$EXISTING_TUNNEL_ID" ] && yellow "已绑定 Tunnel ID: ${EXISTING_TUNNEL_ID}"
        yellow "当前正在配置的 Tunnel 名称: ${CF_TUNNEL_NAME}"
        $CLOUDFLARED_BIN tunnel list || true
        return 1
    fi

    if printf '%s\n' "$ROUTE_OUTPUT" | grep -qi 'failed\|error'; then
        yellow "DNS 绑定失败，下面显示当前 Tunnel 列表供排查："
        $CLOUDFLARED_BIN tunnel list || true
        return 1
    fi

    green "DNS 绑定完成"
    return 0
}

configure_cloudflare_tunnel() {
    load_params
    ensure_cloudflared_installed

    if [ "${ENABLE_VLESS_TUNNEL}" != "1" ]; then
        yellow "请先创建 VLESS Tunnel 节点"
        return 1
    fi

    CF_BASE_DOMAIN=""
    CF_SUBDOMAIN=""
    CF_FULL_DOMAIN=""
    CF_TUNNEL_ID=""

    if ! prompt_base_domain; then
        return 1
    fi

    if ! prompt_tunnel_domain; then
        return 1
    fi

    printf "请输入 Tunnel 名称 [当前: %s, 默认: singbox]: " "${CF_TUNNEL_NAME}"
    if ! IFS= read -r INPUT_TUNNEL_NAME; then
        return 1
    fi
    if [ -n "$INPUT_TUNNEL_NAME" ]; then
        CF_TUNNEL_NAME="$INPUT_TUNNEL_NAME"
    elif [ -z "$CF_TUNNEL_NAME" ]; then
        CF_TUNNEL_NAME="singbox"
    fi

    create_or_use_tunnel || return 1
    route_tunnel_dns || return 1
    write_cloudflared_config || return 1

    save_params
    create_cloudflared_service
    start_or_restart_cloudflared
    green "Cloudflare Tunnel 配置完成"
}

create_vless_tunnel_node() {
    ensure_singbox_installed
    ensure_cloudflared_installed
    load_params

    if ! prompt_node_name; then
        yellow "已返回菜单"
        return 1
    fi

    CF_BASE_DOMAIN=""
    CF_SUBDOMAIN=""
    CF_FULL_DOMAIN=""
    CF_TUNNEL_ID=""

    if ! prompt_vless_tunnel; then
        yellow "已返回菜单"
        return 1
    fi

    if [ "${ENABLE_VLESS_DIRECT}" = "1" ] && [ "$VLESS_TUNNEL_PORT" = "$VLESS_DIRECT_PORT" ]; then
        red "Tunnel VLESS 端口和直连 VLESS 端口不能相同"
        return 1
    fi
    if [ "${ENABLE_ANYTLS}" = "1" ] && [ "$VLESS_TUNNEL_PORT" = "$ANYTLS_PORT" ]; then
        red "Tunnel VLESS 端口和 AnyTLS 端口不能相同"
        return 1
    fi

    if ! check_port_available_for_singbox "$VLESS_TUNNEL_PORT"; then
        return 1
    fi

    line
    green "正在生成 sing-box 配置..."
    apply_generated_config || return 1

    line
    green "正在重新配置 Cloudflare Tunnel..."
    create_or_use_tunnel || return 1
    route_tunnel_dns || return 1
    write_cloudflared_config || return 1

    save_params
    create_service
    create_cloudflared_service
    start_or_restart_service
    start_or_restart_cloudflared
    show_info
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

    if [ "${ENABLE_VLESS_DIRECT}" = "1" ]; then
        DIRECT_UUID_ESCAPED="$(json_escape "$VLESS_DIRECT_UUID")"
        DIRECT_PATH_ESCAPED="$(json_escape "$VLESS_DIRECT_PATH")"
        cat >> "$TARGET_CONFIG_FILE" <<EOF_CONF
    {
      "type": "vless",
      "tag": "vless-direct-in",
      "listen": "::",
      "listen_port": ${VLESS_DIRECT_PORT},
      "users": [
        {
          "uuid": "${DIRECT_UUID_ESCAPED}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${DIRECT_PATH_ESCAPED}",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
EOF_CONF
        wrote_anything=1
    fi

    if [ "${ENABLE_VLESS_TUNNEL}" = "1" ]; then
        TUNNEL_UUID_ESCAPED="$(json_escape "$VLESS_TUNNEL_UUID")"
        TUNNEL_PATH_ESCAPED="$(json_escape "$VLESS_TUNNEL_PATH")"
        if [ "$wrote_anything" = "1" ]; then
            printf ',\n' >> "$TARGET_CONFIG_FILE"
        fi
        cat >> "$TARGET_CONFIG_FILE" <<EOF_CONF
    {
      "type": "vless",
      "tag": "vless-tunnel-in",
      "listen": "127.0.0.1",
      "listen_port": ${VLESS_TUNNEL_PORT},
      "users": [
        {
          "uuid": "${TUNNEL_UUID_ESCAPED}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${TUNNEL_PATH_ESCAPED}",
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

create_cloudflared_openrc_service() {
    mkdir -p /etc/local.d
    touch "$CF_LOG_FILE"

    cat > "$CF_OPENRC_START_FILE" <<EOF_CFSTART
#!/bin/sh
pkill -f "${CLOUDFLARED_BIN} tunnel --config ${CF_CONFIG_FILE} run" >/dev/null 2>&1 || true
nohup ${CLOUDFLARED_BIN} tunnel --config ${CF_CONFIG_FILE} run >>${CF_LOG_FILE} 2>&1 &
EOF_CFSTART

    cat > "$CF_OPENRC_STOP_FILE" <<EOF_CFSTOP
#!/bin/sh
pkill -f "${CLOUDFLARED_BIN} tunnel --config ${CF_CONFIG_FILE} run" >/dev/null 2>&1 || true
EOF_CFSTOP

    chmod +x "$CF_OPENRC_START_FILE" "$CF_OPENRC_STOP_FILE"
    rc-update add local default >/dev/null 2>&1 || true
    green "OpenRC cloudflared 启动脚本已创建"
}

create_cloudflared_systemd_service() {
    cat > "$CF_SYSTEMD_SERVICE_FILE" <<EOF_CFSVC
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CF_CONFIG_FILE} run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_CFSVC

    systemctl daemon-reload
    systemctl enable "$CF_SERVICE_NAME" >/dev/null 2>&1 || true
    green "systemd cloudflared 服务已创建"
}

create_cloudflared_service() {
    case "$INIT_SYSTEM" in
        openrc) create_cloudflared_openrc_service ;;
        systemd) create_cloudflared_systemd_service ;;
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

start_or_restart_cloudflared() {
    if [ ! -f "$CF_CONFIG_FILE" ]; then
        yellow "cloudflared 配置文件不存在: ${CF_CONFIG_FILE}"
        return 1
    fi

    line
    green "正在启动 / 重启 cloudflared..."

    : > "$CF_LOG_FILE"

    case "$INIT_SYSTEM" in
        openrc)
            "$CF_OPENRC_STOP_FILE" >/dev/null 2>&1 || true
            "$CF_OPENRC_START_FILE" >/dev/null 2>&1 || true
            ;;
        systemd)
            systemctl restart "$CF_SERVICE_NAME"
            ;;
    esac

    sleep 1
    green "cloudflared 已启动"
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

restart_cloudflared_service() {
    line
    green "重启 cloudflared..."

    if [ ! -f "$CF_CONFIG_FILE" ]; then
        yellow "cloudflared 配置文件不存在"
        return 1
    fi

    : > "$CF_LOG_FILE"

    case "$INIT_SYSTEM" in
        openrc)
            "$CF_OPENRC_STOP_FILE" >/dev/null 2>&1 || true
            "$CF_OPENRC_START_FILE" >/dev/null 2>&1 || true
            ;;
        systemd)
            systemctl restart "$CF_SERVICE_NAME"
            ;;
    esac
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

show_cloudflared_logs() {
    line
    green "查看 cloudflared 日志"
    line

    case "$INIT_SYSTEM" in
        systemd)
            journalctl -u "$CF_SERVICE_NAME" -n 50 --no-pager || true
            ;;
        openrc)
            if [ -f "$CF_LOG_FILE" ]; then
                tail -n 50 "$CF_LOG_FILE" || true
            else
                yellow "日志文件不存在: ${CF_LOG_FILE}"
            fi
            ;;
    esac
}

generate_vless_direct_link() {
    ENCODED_PATH="$(urlencode_path "$VLESS_DIRECT_PATH")"

    case "$SERVER_ADDR" in
        *:*)
            HOST_PART="[${SERVER_ADDR}]"
            ;;
        *)
            HOST_PART="${SERVER_ADDR}"
            ;;
    esac

    if [ -n "$VLESS_DIRECT_HOST" ]; then
        VLESS_DIRECT_LINK="vless://${VLESS_DIRECT_UUID}@${HOST_PART}:${VLESS_DIRECT_PORT}?type=ws&security=none&path=${ENCODED_PATH}&host=${VLESS_DIRECT_HOST}#${NODE_NAME}-direct"
    else
        VLESS_DIRECT_LINK="vless://${VLESS_DIRECT_UUID}@${HOST_PART}:${VLESS_DIRECT_PORT}?type=ws&security=none&path=${ENCODED_PATH}#${NODE_NAME}-direct"
    fi
}

generate_vless_tunnel_link() {
    compose_tunnel_domain
    ENCODED_PATH="$(urlencode_path "$VLESS_TUNNEL_PATH")"
    VLESS_TUNNEL_LINK="vless://${VLESS_TUNNEL_UUID}@${CF_FULL_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CF_FULL_DOMAIN}&path=${ENCODED_PATH}&sni=${CF_FULL_DOMAIN}#${NODE_NAME}-tunnel"
}

show_info() {
    load_params
    compose_tunnel_domain

    line
    green "当前节点信息"
    line
    printf "节点名称: %s\n" "$NODE_NAME"
    printf "服务器地址: %s\n" "$SERVER_ADDR"
    line

    if [ "${ENABLE_VLESS_DIRECT}" = "1" ]; then
        generate_vless_direct_link
        blue "VLESS 直连:"
        printf "端口: %s\n" "$VLESS_DIRECT_PORT"
        printf "UUID: %s\n" "$VLESS_DIRECT_UUID"
        printf "WS Path: %s\n" "$VLESS_DIRECT_PATH"
        printf "WS Host: %s\n" "${VLESS_DIRECT_HOST:-无}"
        printf "分享链接:\n%s\n" "$VLESS_DIRECT_LINK"
    else
        yellow "VLESS 直连: 未启用"
    fi

    line

    if [ "${ENABLE_VLESS_TUNNEL}" = "1" ]; then
        blue "VLESS Tunnel:"
        printf "本地端口: %s\n" "$VLESS_TUNNEL_PORT"
        printf "UUID: %s\n" "$VLESS_TUNNEL_UUID"
        printf "WS Path: %s\n" "$VLESS_TUNNEL_PATH"
        printf "基础域名: %s\n" "${CF_BASE_DOMAIN:-未设置}"
        printf "前缀: %s\n" "${CF_SUBDOMAIN:-未设置}"
        printf "完整域名: %s\n" "${CF_FULL_DOMAIN:-未设置}"
        printf "Tunnel 名称: %s\n" "${CF_TUNNEL_NAME:-未设置}"
        printf "Tunnel ID: %s\n" "${CF_TUNNEL_ID:-未设置}"
        if [ -n "$CF_FULL_DOMAIN" ]; then
            generate_vless_tunnel_link
            printf "分享链接:\n%s\n" "$VLESS_TUNNEL_LINK"
        fi
    else
        yellow "VLESS Tunnel: 未启用"
    fi

    line

    if [ "${ENABLE_ANYTLS}" = "1" ]; then
        blue "AnyTLS:"
        printf "端口: %s\n" "$ANYTLS_PORT"
        printf "用户名: %s\n" "$ANYTLS_NAME"
        printf "密码: %s\n" "$ANYTLS_PASSWORD"
    else
        yellow "AnyTLS: 未启用"
    fi
}

show_runtime_status() {
    line
    green "运行状态"
    line
    [ -x "$BIN_FILE" ] && "$BIN_FILE" version || true
    [ -x "$CLOUDFLARED_BIN" ] && "$CLOUDFLARED_BIN" --version || true
    line

    case "$INIT_SYSTEM" in
        openrc)
            rc-service "$SERVICE_NAME" status || true
            ;;
        systemd)
            systemctl status "$SERVICE_NAME" --no-pager || true
            ;;
    esac

    line
    pgrep -a sing-box || yellow "未发现 sing-box 进程"
    pgrep -a cloudflared || yellow "未发现 cloudflared 进程"
    line
    ss -lntup 2>/dev/null | grep -E 'sing-box|cloudflared' || yellow "未发现相关监听信息"
}

create_vless_direct_node() {
    ensure_singbox_installed
    load_params

    if ! prompt_server_addr; then
        yellow "已返回菜单"
        return 1
    fi
    if ! prompt_node_name; then
        yellow "已返回菜单"
        return 1
    fi
    if ! prompt_vless_direct; then
        yellow "已返回菜单"
        return 1
    fi

    if [ "${ENABLE_VLESS_TUNNEL}" = "1" ] && [ "$VLESS_DIRECT_PORT" = "$VLESS_TUNNEL_PORT" ]; then
        red "直连 VLESS 端口和 Tunnel VLESS 端口不能相同"
        return 1
    fi
    if [ "${ENABLE_ANYTLS}" = "1" ] && [ "$VLESS_DIRECT_PORT" = "$ANYTLS_PORT" ]; then
        red "直连 VLESS 端口和 AnyTLS 端口不能相同"
        return 1
    fi

    if ! check_port_available_for_singbox "$VLESS_DIRECT_PORT"; then
        return 1
    fi

    line
    green "正在生成配置..."
    apply_generated_config || return 1

    save_params
    create_service
    start_or_restart_service
    show_info
}

configure_cloudflare_tunnel() {
    load_params
    ensure_cloudflared_installed

    if [ "${ENABLE_VLESS_TUNNEL}" != "1" ]; then
        yellow "请先创建 VLESS Tunnel 节点"
        return 1
    fi

    CF_BASE_DOMAIN=""
    CF_SUBDOMAIN=""
    CF_FULL_DOMAIN=""
    CF_TUNNEL_ID=""

    if ! prompt_base_domain; then
        return 1
    fi

    if ! prompt_tunnel_domain; then
        return 1
    fi

    printf "请输入 Tunnel 名称 [当前: %s, 默认: singbox]: " "${CF_TUNNEL_NAME}"
    if ! IFS= read -r INPUT_TUNNEL_NAME; then
        return 1
    fi
    if [ -n "$INPUT_TUNNEL_NAME" ]; then
        CF_TUNNEL_NAME="$INPUT_TUNNEL_NAME"
    elif [ -z "$CF_TUNNEL_NAME" ]; then
        CF_TUNNEL_NAME="singbox"
    fi

    create_or_use_tunnel || return 1
    route_tunnel_dns || return 1
    write_cloudflared_config || return 1

    save_params
    create_cloudflared_service
    start_or_restart_cloudflared
    green "Cloudflare Tunnel 配置完成"
}

create_vless_tunnel_node() {
    ensure_singbox_installed
    ensure_cloudflared_installed
    load_params

    if ! prompt_node_name; then
        yellow "已返回菜单"
        return 1
    fi

    CF_BASE_DOMAIN=""
    CF_SUBDOMAIN=""
    CF_FULL_DOMAIN=""
    CF_TUNNEL_ID=""

    if ! prompt_vless_tunnel; then
        yellow "已返回菜单"
        return 1
    fi

    if [ "${ENABLE_VLESS_DIRECT}" = "1" ] && [ "$VLESS_TUNNEL_PORT" = "$VLESS_DIRECT_PORT" ]; then
        red "Tunnel VLESS 端口和直连 VLESS 端口不能相同"
        return 1
    fi
    if [ "${ENABLE_ANYTLS}" = "1" ] && [ "$VLESS_TUNNEL_PORT" = "$ANYTLS_PORT" ]; then
        red "Tunnel VLESS 端口和 AnyTLS 端口不能相同"
        return 1
    fi

    if ! check_port_available_for_singbox "$VLESS_TUNNEL_PORT"; then
        return 1
    fi

    line
    green "正在生成 sing-box 配置..."
    apply_generated_config || return 1

    line
    green "正在重新配置 Cloudflare Tunnel..."
    create_or_use_tunnel || return 1
    route_tunnel_dns || return 1
    write_cloudflared_config || return 1

    save_params
    create_service
    create_cloudflared_service
    start_or_restart_service
    start_or_restart_cloudflared
    show_info
}

create_anytls_node() {
    ensure_singbox_installed
    load_params

    if ! prompt_server_addr; then
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

    if [ "${ENABLE_VLESS_DIRECT}" = "1" ] && [ "$ANYTLS_PORT" = "$VLESS_DIRECT_PORT" ]; then
        red "AnyTLS 端口和直连 VLESS 端口不能相同"
        return 1
    fi
    if [ "${ENABLE_VLESS_TUNNEL}" = "1" ] && [ "$ANYTLS_PORT" = "$VLESS_TUNNEL_PORT" ]; then
        red "AnyTLS 端口和 Tunnel VLESS 端口不能相同"
        return 1
    fi

    if ! check_port_available_for_singbox "$ANYTLS_PORT"; then
        return 1
    fi

    line
    green "正在生成配置..."
    apply_generated_config || return 1

    save_params
    create_service
    start_or_restart_service
    show_info
}

delete_vless_direct() {
    load_params
    if [ "$ENABLE_VLESS_DIRECT" != "1" ]; then
        yellow "VLESS 直连未启用"
        return
    fi

    if confirm_action "确认删除 VLESS 直连节点？[y/N]: "; then
        ENABLE_VLESS_DIRECT=0
        VLESS_DIRECT_PORT=""
        VLESS_DIRECT_PATH="$DEFAULT_DIRECT_WS_PATH"
        VLESS_DIRECT_UUID=""
        VLESS_DIRECT_HOST=""

        save_params

        if apply_generated_config; then
            create_service
            start_or_restart_service
        else
            rm -f "$CONFIG_FILE"
            stop_service_silent
        fi
        green "VLESS 直连已删除"
    else
        yellow "已取消"
    fi
}

delete_vless_tunnel() {
    load_params
    if [ "$ENABLE_VLESS_TUNNEL" != "1" ]; then
        yellow "VLESS Tunnel 未启用"
        return
    fi

    if confirm_action "确认删除 VLESS Tunnel 节点？[y/N]: "; then
        ENABLE_VLESS_TUNNEL=0
        VLESS_TUNNEL_PORT=""
        VLESS_TUNNEL_PATH="$DEFAULT_TUNNEL_WS_PATH"
        VLESS_TUNNEL_UUID=""
        CF_SUBDOMAIN=""
        CF_FULL_DOMAIN=""
        CF_TUNNEL_NAME="singbox"
        CF_TUNNEL_ID=""

        save_params

        if apply_generated_config; then
            create_service
            start_or_restart_service
        else
            rm -f "$CONFIG_FILE"
            stop_service_silent
        fi

        rm -f "$CF_CONFIG_FILE"
        stop_cloudflared_silent
        green "VLESS Tunnel 已删除"
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
        ENABLE_ANYTLS=0
        ANYTLS_PORT=""
        ANYTLS_NAME="user"
        ANYTLS_PASSWORD=""
        rm -f "$CERT_FILE" "$KEY_FILE"

        save_params

        if apply_generated_config; then
            create_service
            start_or_restart_service
        else
            rm -f "$CONFIG_FILE"
            stop_service_silent
        fi
        green "AnyTLS 已删除"
    else
        yellow "已取消"
    fi
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

install_cloudflared_only() {
    install_dependencies
    download_cloudflared
    green "cloudflared 安装完成"
}

uninstall_all() {
    if confirm_action "确认卸载 sing-box 与 cloudflared 相关配置？[y/N]: "; then
        stop_service_silent
        stop_cloudflared_silent

        case "$INIT_SYSTEM" in
            openrc)
                rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
                rc-update del local default >/dev/null 2>&1 || true
                rm -f "$OPENRC_SERVICE_FILE" "$CF_OPENRC_START_FILE" "$CF_OPENRC_STOP_FILE"
                ;;
            systemd)
                systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
                systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
                systemctl stop "$CF_SERVICE_NAME" >/dev/null 2>&1 || true
                systemctl disable "$CF_SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f "$SYSTEMD_SERVICE_FILE" "$CF_SYSTEMD_SERVICE_FILE"
                systemctl daemon-reload >/dev/null 2>&1 || true
                ;;
        esac

        rm -f "$BIN_FILE" "$CLOUDFLARED_BIN"
        [ -d "$CONFIG_DIR" ] && rm -rf "$CONFIG_DIR"
        [ -d "$CF_DIR" ] && rm -rf "$CF_DIR"
        [ -d "$LOG_DIR" ] && rm -rf "$LOG_DIR"
        rm -f "$CF_LOG_FILE"
        [ -f "$CLI_LINK_PATH" ] && rm -f "$CLI_LINK_PATH"
        green "已卸载"
    else
        yellow "已取消"
    fi
}

exit_with_hint() {
    green "已退出，后续可直接输入 ${CLI_NAME} 打开菜单"
    exit 0
}

clear_cloudflare_domain_cache() {
    CF_BASE_DOMAIN=""
    CF_SUBDOMAIN=""
    CF_FULL_DOMAIN=""
    CF_TUNNEL_ID=""
    save_params
    green "Cloudflare 域名缓存已清空"
}

rebind_cloudflare_tunnel_domain() {
    load_params
    ensure_cloudflared_installed

    if [ -z "$CF_TUNNEL_NAME" ]; then
        yellow "Tunnel 名称为空"
        return 1
    fi

    CF_BASE_DOMAIN=""
    CF_SUBDOMAIN=""
    CF_FULL_DOMAIN=""
    CF_TUNNEL_ID=""

    if ! prompt_base_domain; then
        return 1
    fi

    if ! prompt_tunnel_domain; then
        return 1
    fi

    create_or_use_tunnel || return 1
    route_tunnel_dns || return 1
    write_cloudflared_config || return 1

    save_params
    create_cloudflared_service
    start_or_restart_cloudflared
    green "Cloudflare Tunnel 域名已重新绑定"
}

cloudflare_relogin_and_pick_zone() {
    ensure_cloudflared_installed

    line
    yellow "即将重新登录 Cloudflare"
    if confirm_action "是否删除旧 Cloudflare 登录凭据并重新登录？[y/N]: "; then
        rm -f /root/.cloudflared/cert.pem
        rm -f /root/.cloudflared/*.json 2>/dev/null || true
        CF_TUNNEL_ID=""
        CF_BASE_DOMAIN=""
        CF_SUBDOMAIN=""
        CF_FULL_DOMAIN=""
        save_params
        cloudflared_login
        green "请重新在浏览器里选择 Cloudflare 上托管的域名"
    else
        yellow "已取消"
        return 1
    fi
}



cloudflare_full_rebuild() {
    ensure_cloudflared_installed

    line
    yellow "将执行 Cloudflare 全量重建"
    if ! confirm_action "确认继续？[y/N]: "; then
        yellow "已取消"
        return 1
    fi

    stop_cloudflared_silent

    CF_BASE_DOMAIN=""
    CF_SUBDOMAIN=""
    CF_FULL_DOMAIN=""
    CF_TUNNEL_ID=""

    if ! prompt_base_domain; then
        return 1
    fi

    if ! prompt_tunnel_domain; then
        return 1
    fi

    printf "请输入 Tunnel 名称 [默认: sgb]: "
    if ! IFS= read -r INPUT_TUNNEL_NAME; then
        return 1
    fi
    CF_TUNNEL_NAME="${INPUT_TUNNEL_NAME:-sgb}"

    OLD_ID="$($CLOUDFLARED_BIN tunnel list 2>/dev/null | awk -v name="$CF_TUNNEL_NAME" 'NR>1 && $2==name {print $1; exit}' || true)"
    if [ -n "$OLD_ID" ]; then
        yellow "发现旧 Tunnel: ${CF_TUNNEL_NAME} (${OLD_ID})，尝试删除"
        $CLOUDFLARED_BIN tunnel delete "$CF_TUNNEL_NAME" >/dev/null 2>&1 || true
    fi

    rm -f "$CF_CONFIG_FILE" 2>/dev/null || true
    rm -f /root/.cloudflared/*.json 2>/dev/null || true
    rm -f /root/.cloudflared/cert.pem 2>/dev/null || true

    cloudflared_login || return 1

    create_or_use_tunnel || return 1

    ROUTE_OUTPUT="$($CLOUDFLARED_BIN tunnel route dns --overwrite-dns "$CF_TUNNEL_NAME" "$CF_FULL_DOMAIN" 2>&1 || true)"
    printf '%s\n' "$ROUTE_OUTPUT"

    if printf '%s\n' "$ROUTE_OUTPUT" | grep -qi 'failed\|error'; then
        yellow "DNS 绑定失败，当前 tunnel 列表如下："
        $CLOUDFLARED_BIN tunnel list || true
        return 1
    fi

    write_cloudflared_config || return 1
    save_params
    create_cloudflared_service
    start_or_restart_cloudflared

    green "Cloudflare 全量重建完成"
}

show_cloudflare_tunnel_info() {
    load_params
    compose_tunnel_domain

    line
    green "Cloudflare Tunnel 信息"
    line
    printf "Tunnel 名称: %s\n" "${CF_TUNNEL_NAME:-未设置}"
    printf "Tunnel ID: %s\n" "${CF_TUNNEL_ID:-未设置}"
    printf "基础域名: %s\n" "${CF_BASE_DOMAIN:-未设置}"
    printf "前缀: %s\n" "${CF_SUBDOMAIN:-未设置}"
    printf "完整域名: %s\n" "${CF_FULL_DOMAIN:-未设置}"
    line

    if [ -x "$CLOUDFLARED_BIN" ]; then
        green "cloudflared tunnel list"
        "$CLOUDFLARED_BIN" tunnel list || true
    else
        yellow "未安装 cloudflared"
    fi

    line

    if [ -f "$CF_CONFIG_FILE" ]; then
        green "当前 cloudflared 配置文件"
        cat "$CF_CONFIG_FILE"
    else
        yellow "cloudflared 配置文件不存在: ${CF_CONFIG_FILE}"
    fi
}

menu() {
    while true; do
        line
        blue "sing-box 中文管理菜单"
        line
        printf "1. 安装 / 更新 sing-box\n"
        printf "2. 安装 / 更新 cloudflared\n"
        printf "3. 新建 / 重配 VLESS 直连\n"
        printf "4. 新建 / 重配 VLESS Tunnel\n"
        printf "5. 新建 / 重配 AnyTLS\n"
        printf "6. 配置 Cloudflare Tunnel\n"
        printf "7. 删除 VLESS 直连\n"
        printf "8. 删除 VLESS Tunnel\n"
        printf "9. 删除 AnyTLS\n"
        printf "10. 查看节点信息\n"
        printf "11. 查看运行状态\n"
        printf "12. 重启 sing-box\n"
        printf "13. 重启 cloudflared\n"
        printf "14. 查看 sing-box 日志\n"
        printf "15. 查看 cloudflared 日志\n"
        printf "16. 安装 singbox 命令入口\n"
        printf "17. 禁用 IPv6\n"
        printf "18. 恢复 IPv6\n"
        printf "19. 卸载全部\n"
        printf "20. 查看 Cloudflare Tunnel 信息\n"
        printf "21. Cloudflare 全量重建\n"
        printf "0. 退出\n"
        line
        printf "请选择: "
        if ! IFS= read -r CHOICE; then
            yellow "输入失败，返回菜单"
            continue
        fi

        case "$CHOICE" in
            1) install_only ;;
            2) install_cloudflared_only ;;
            3) create_vless_direct_node ;;
            4) create_vless_tunnel_node ;;
            5) create_anytls_node ;;
            6) configure_cloudflare_tunnel ;;
            7) delete_vless_direct ;;
            8) delete_vless_tunnel ;;
            9) delete_anytls ;;
            10) show_info ;;
            11) show_runtime_status ;;
            12) restart_singbox_service ;;
            13) restart_cloudflared_service ;;
            14) show_service_logs ;;
            15) show_cloudflared_logs ;;
            16) install_cli_command ;;
            17) disable_ipv6_persistent ;;
            18) enable_ipv6_persistent ;;
            19) uninstall_all ;;
            20) show_cloudflare_tunnel_info ;;
            21) cloudflare_full_rebuild ;;
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


