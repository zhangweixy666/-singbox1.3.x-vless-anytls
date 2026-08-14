#!/bin/sh
# sing-box manager for Alpine/OpenRC and Debian/systemd.
# Configuration files are parsed as data; user input is never eval'd.
set -eu
umask 077

VERSION=1.13.14
PREFIX=/usr/local/bin
BIN=$PREFIX/sing-box
SCRIPT=$PREFIX/singbox-manager.sh
CFG_DIR=/etc/sing-box
CFG=$CFG_DIR/config.json
PARAMS=$CFG_DIR/params.env
CERT_DIR=$CFG_DIR/certs
CERT=$CERT_DIR/fullchain.pem
KEY=$CERT_DIR/key.pem
REALITY_DIR=$CFG_DIR/reality
LOG_DIR=/var/log/sing-box
LOG=$LOG_DIR/sing-box.log
SERVICE_FILE=/etc/init.d/sing-box
SYSTEMD_FILE=/etc/systemd/system/sing-box.service

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
line(){ printf '%s\n' '------------------------------------------------------------'; }

root_check(){ [ "$(id -u)" = 0 ] || { red '请使用 root 运行'; exit 1; }; }

detect_os(){
  if [ -f /etc/alpine-release ]; then
    OS=alpine; PM=apk; INIT=openrc
  elif [ -f /etc/debian_version ]; then
    OS=debian; PM=apt-get; INIT=systemd
  else
    red '仅支持 Alpine、Debian 或 Ubuntu'; exit 1
  fi
}

install_packages(){
  if [ "$PM" = apk ]; then
    apk add --no-cache curl ca-certificates tar gzip openssl python3 procps iproute2
  else
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar gzip openssl python3 procps iproute2
  fi
}

arch_name(){
  case "$(uname -m)" in
    x86_64) printf '%s\n' amd64;;
    aarch64|arm64) printf '%s\n' arm64;;
    armv7l) printf '%s\n' armv7;;
    *) return 1;;
  esac
}

install_binary(){
  arch=$(arch_name) || { red "不支持架构: $(uname -m)"; return 1; }
  suffix=
  [ "$INIT" = openrc ] && suffix=-musl
  url="https://github.com/SagerNet/sing-box/releases/download/v$VERSION/sing-box-$VERSION-linux-$arch$suffix.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$tmp/sing-box.tgz"
  tar -xzf "$tmp/sing-box.tgz" -C "$tmp"
  file=$(find "$tmp" -type f -name sing-box | head -n 1)
  [ -n "$file" ] || { red '下载包中没有 sing-box 二进制'; return 1; }
  install -m 755 "$file" "$BIN"
  install -m 700 "$0" "$SCRIPT"
  trap - EXIT INT TERM
  rm -rf "$tmp"
  "$BIN" version
}

ensure_binary(){ [ -x "$BIN" ] || install_binary; }
uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16; }
random_password(){ od -An -N24 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-32; }
short_id(){ openssl rand -hex 8; }

defaults(){
  ANYTLS=0; ANYTLS_PORT=18443; ANYTLS_NAME=user; ANYTLS_PASSWORD=
  TUIC=0; TUIC_PORT=18444; TUIC_UUID=; TUIC_PASSWORD=
  HY2=0; HY2_PORT=18445; HY2_PASSWORD=
  VLESS_WS=0; VLESS_WS_PORT=20008; VLESS_WS_UUID=; VLESS_WS_PATH=/ws
  VMESS_WS=0; VMESS_WS_PORT=20009; VMESS_WS_UUID=; VMESS_WS_PATH=/vmess
  REALITY=0; REALITY_PORT=18446; REALITY_UUID=; REALITY_SNI=www.apple.com; REALITY_SHORT_ID=
  SERVER=; DOMAIN=; NODE=sing-box-node; CERT_MODE=none
}

# Explicit allow-list parser: values remain data and are never executed.
set_param(){
  case "$1" in
    ANYTLS) ANYTLS=$2;; ANYTLS_PORT) ANYTLS_PORT=$2;;
    ANYTLS_NAME) ANYTLS_NAME=$2;; ANYTLS_PASSWORD) ANYTLS_PASSWORD=$2;;
    TUIC) TUIC=$2;; TUIC_PORT) TUIC_PORT=$2;; TUIC_UUID) TUIC_UUID=$2;; TUIC_PASSWORD) TUIC_PASSWORD=$2;;
    HY2) HY2=$2;; HY2_PORT) HY2_PORT=$2;; HY2_PASSWORD) HY2_PASSWORD=$2;;
    VLESS_WS) VLESS_WS=$2;; VLESS_WS_PORT) VLESS_WS_PORT=$2;; VLESS_WS_UUID) VLESS_WS_UUID=$2;; VLESS_WS_PATH) VLESS_WS_PATH=$2;;
    VMESS_WS) VMESS_WS=$2;; VMESS_WS_PORT) VMESS_WS_PORT=$2;; VMESS_WS_UUID) VMESS_WS_UUID=$2;; VMESS_WS_PATH) VMESS_WS_PATH=$2;;
    REALITY) REALITY=$2;; REALITY_PORT) REALITY_PORT=$2;; REALITY_UUID) REALITY_UUID=$2;; REALITY_SNI) REALITY_SNI=$2;;
    REALITY_SHORT_ID) REALITY_SHORT_ID=$2;; SERVER) SERVER=$2;; DOMAIN) DOMAIN=$2;;
    NODE) NODE=$2;; CERT_MODE) CERT_MODE=$2;;
  esac
}

load(){
  defaults
  [ -r "$PARAMS" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in ''|\#*) continue;; esac
    set_param "$key" "$value"
  done < "$PARAMS"
}

save(){
  mkdir -p "$CFG_DIR"
  cat > "$PARAMS" <<EOF
ANYTLS=$ANYTLS
ANYTLS_PORT=$ANYTLS_PORT
ANYTLS_NAME=$ANYTLS_NAME
ANYTLS_PASSWORD=$ANYTLS_PASSWORD
TUIC=$TUIC
TUIC_PORT=$TUIC_PORT
TUIC_UUID=$TUIC_UUID
TUIC_PASSWORD=$TUIC_PASSWORD
HY2=$HY2
HY2_PORT=$HY2_PORT
HY2_PASSWORD=$HY2_PASSWORD
VLESS_WS=$VLESS_WS
VLESS_WS_PORT=$VLESS_WS_PORT
VLESS_WS_UUID=$VLESS_WS_UUID
VLESS_WS_PATH=$VLESS_WS_PATH
VMESS_WS=$VMESS_WS
VMESS_WS_PORT=$VMESS_WS_PORT
VMESS_WS_UUID=$VMESS_WS_UUID
VMESS_WS_PATH=$VMESS_WS_PATH
REALITY=$REALITY
REALITY_PORT=$REALITY_PORT
REALITY_UUID=$REALITY_UUID
REALITY_SNI=$REALITY_SNI
REALITY_SHORT_ID=$REALITY_SHORT_ID
SERVER=$SERVER
DOMAIN=$DOMAIN
NODE=$NODE
CERT_MODE=$CERT_MODE
EOF
  chmod 600 "$PARAMS"
}

port_check(){
  case "$1" in ''|*[!0-9]*) red "端口无效: $1"; return 1;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null ||
    { red "端口范围无效: $1"; return 1; }
}

path_norm(){
  case "$1" in /*) path=$1;; *) path=/$1;; esac
  case "$path" in *[!A-Za-z0-9._~/-]*) return 1;; esac
  printf '%s\n' "$path"
}

host_check(){
  case "$1" in ''|*[!A-Za-z0-9.-]*) return 1;; esac
}

asked_value(){
  case "$1" in
    SERVER) SERVER=$2;; NODE) NODE=$2;; DOMAIN) DOMAIN=$2;;
    ANYTLS_PORT) ANYTLS_PORT=$2;; ANYTLS_NAME) ANYTLS_NAME=$2;; ANYTLS_PASSWORD) ANYTLS_PASSWORD=$2;;
    TUIC_PORT) TUIC_PORT=$2;; TUIC_UUID) TUIC_UUID=$2;; TUIC_PASSWORD) TUIC_PASSWORD=$2;;
    HY2_PORT) HY2_PORT=$2;; HY2_PASSWORD) HY2_PASSWORD=$2;;
    VLESS_WS_PORT) VLESS_WS_PORT=$2;; VLESS_WS_UUID) VLESS_WS_UUID=$2;; VLESS_WS_PATH) VLESS_WS_PATH=$2;;
    VMESS_WS_PORT) VMESS_WS_PORT=$2;; VMESS_WS_UUID) VMESS_WS_UUID=$2;; VMESS_WS_PATH) VMESS_WS_PATH=$2;;
    REALITY_PORT) REALITY_PORT=$2;; REALITY_UUID) REALITY_UUID=$2;; REALITY_SNI) REALITY_SNI=$2;;
  esac
}

ask_set(){
  prompt=$2
  default=$3
  printf '%s' "$prompt"
  IFS= read -r answer || answer=
  [ -n "$answer" ] || answer=$default
  asked_value "$1" "$answer"
}

ensure_common(){
  load
  ensure_binary
  if [ -z "$SERVER" ]; then
    SERVER=$(hostname -i 2>/dev/null | awk '{print $1}')
    [ -n "$SERVER" ] || SERVER=YOUR_SERVER_IP
  fi
  [ -n "$NODE" ] || NODE=sing-box-node
}

ensure_randoms(){
  [ -n "$ANYTLS_PASSWORD" ] || ANYTLS_PASSWORD=$(random_password)
  [ -n "$TUIC_UUID" ] || TUIC_UUID=$(uuid)
  [ -n "$TUIC_PASSWORD" ] || TUIC_PASSWORD=$(random_password)
  [ -n "$HY2_PASSWORD" ] || HY2_PASSWORD=$(random_password)
  [ -n "$VLESS_WS_UUID" ] || VLESS_WS_UUID=$(uuid)
  [ -n "$VMESS_WS_UUID" ] || VMESS_WS_UUID=$(uuid)
  [ -n "$REALITY_UUID" ] || REALITY_UUID=$(uuid)
  [ -n "$REALITY_SHORT_ID" ] || REALITY_SHORT_ID=$(short_id)
}

validate_params(){
  port_check "$ANYTLS_PORT"; port_check "$TUIC_PORT"; port_check "$HY2_PORT"
  port_check "$VLESS_WS_PORT"; port_check "$VMESS_WS_PORT"; port_check "$REALITY_PORT"
  path_norm "$VLESS_WS_PATH" >/dev/null
  path_norm "$VMESS_WS_PATH" >/dev/null
  [ -z "$SERVER" ] || host_check "$SERVER"
  [ -z "$DOMAIN" ] || host_check "$DOMAIN"
  host_check "$REALITY_SNI"
}

cert_self(){
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=${DOMAIN:-sing-box}" >/dev/null 2>&1
  chmod 600 "$KEY"; chmod 644 "$CERT"
  CERT_MODE=self
  save
  green "自签证书已生成: $CERT"
}

generate_reality_keys(){
  ensure_binary
  mkdir -p "$REALITY_DIR"
  if [ ! -s "$REALITY_DIR/private.key" ] || [ ! -s "$REALITY_DIR/public.key" ]; then
    output=$("$BIN" generate reality-keypair)
    printf '%s\n' "$output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1 > "$REALITY_DIR/private.key"
    printf '%s\n' "$output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1 > "$REALITY_DIR/public.key"
    chmod 600 "$REALITY_DIR"/*
  fi
}

generate_config(){
  ensure_randoms
  validate_params || { red '参数校验失败'; return 1; }
  [ "$ANYTLS$TUIC$HY2$VLESS_WS$VMESS_WS$REALITY" != 000000 ] ||
    { red '没有启用任何节点'; return 1; }

  mkdir -p "$CFG_DIR" "$LOG_DIR"
  export LOG CERT KEY REALITY_DIR
  export ANYTLS ANYTLS_PORT ANYTLS_NAME ANYTLS_PASSWORD TUIC TUIC_PORT TUIC_UUID TUIC_PASSWORD
  export HY2 HY2_PORT HY2_PASSWORD VLESS_WS VLESS_WS_PORT VLESS_WS_UUID VLESS_WS_PATH
  export VMESS_WS VMESS_WS_PORT VMESS_WS_UUID VMESS_WS_PATH REALITY REALITY_PORT REALITY_UUID REALITY_SNI REALITY_SHORT_ID

  tmp="$CFG.tmp.$$"
  python3 - "$tmp" <<'PY'
import json, os, pathlib, sys

out = pathlib.Path(sys.argv[1])
e = os.environ
cfg = {
    "log": {"level": "info", "timestamp": True, "output": e["LOG"]},
    "inbounds": [],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {"final": "direct"},
}

if e["VLESS_WS"] == "1":
    cfg["inbounds"].append({
        "type": "vless", "tag": "ws-in", "listen": "127.0.0.1",
        "listen_port": int(e["VLESS_WS_PORT"]),
        "users": [{"uuid": e["VLESS_WS_UUID"]}],
        "transport": {"type": "ws", "path": e["VLESS_WS_PATH"],
                      "early_data_header_name": "Sec-WebSocket-Protocol"},
    })

if e["VMESS_WS"] == "1":
    cfg["inbounds"].append({
        "type": "vmess", "tag": "vmess-in", "listen": "127.0.0.1",
        "listen_port": int(e["VMESS_WS_PORT"]),
        "users": [{"name": "user", "uuid": e["VMESS_WS_UUID"], "alterId": 0}],
        "transport": {"type": "ws", "path": e["VMESS_WS_PATH"],
                      "early_data_header_name": "Sec-WebSocket-Protocol"},
    })

if e["REALITY"] == "1":
    private_key = pathlib.Path(e["REALITY_DIR"], "private.key").read_text().strip()
    cfg["inbounds"].append({
        "type": "vless", "tag": "reality-in", "listen": "::",
        "listen_port": int(e["REALITY_PORT"]),
        "users": [{"uuid": e["REALITY_UUID"], "flow": "xtls-rprx-vision"}],
        "tls": {
            "enabled": True, "server_name": e["REALITY_SNI"],
            "reality": {
                "enabled": True,
                "handshake": {"server": e["REALITY_SNI"], "server_port": 443},
                "private_key": private_key,
                "short_id": [e["REALITY_SHORT_ID"]],
            },
        },
    })

if e["ANYTLS"] == "1":
    cfg["inbounds"].append({
        "type": "anytls", "tag": "anytls-in", "listen": "::",
        "listen_port": int(e["ANYTLS_PORT"]),
        "users": [{"name": e["ANYTLS_NAME"], "password": e["ANYTLS_PASSWORD"]}],
        "tls": {"enabled": True, "certificate_path": e["CERT"], "key_path": e["KEY"]},
    })

if e["HY2"] == "1":
    cfg["inbounds"].append({
        "type": "hysteria2", "tag": "hy2-in", "listen": "::",
        "listen_port": int(e["HY2_PORT"]),
        "obfs": {"type": "salamander", "password": e["HY2_PASSWORD"]},
        "users": [{"name": "user", "password": e["HY2_PASSWORD"]}],
        "tls": {"enabled": True, "alpn": ["h3"],
                "certificate_path": e["CERT"], "key_path": e["KEY"]},
    })

if e["TUIC"] == "1":
    cfg["inbounds"].append({
        "type": "tuic", "tag": "tuic-in", "listen": "::",
        "listen_port": int(e["TUIC_PORT"]),
        "users": [{"name": "user", "uuid": e["TUIC_UUID"],
                   "password": e["TUIC_PASSWORD"]}],
        "congestion_control": "bbr", "auth_timeout": "3s",
        "zero_rtt_handshake": False, "heartbeat": "10s",
        "tls": {"enabled": True, "alpn": ["h3"],
                "certificate_path": e["CERT"], "key_path": e["KEY"]},
    })

out.write_text(json.dumps(cfg, ensure_ascii=True, indent=2) + "\n")
PY

  "$BIN" check -c "$tmp"
  mv "$tmp" "$CFG"
  chmod 600 "$CFG"
  green "配置校验通过: $CFG"
}

service_create(){
  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR"

  if [ "$INIT" = openrc ]; then
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="sing-box"
command="$BIN"
command_args="run -c $CFG"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="$LOG"
error_log="$LOG"
start_pre() { "$BIN" check -c "$CFG"; }
depend() { need net; after firewall; }
EOF
    chmod 755 "$SERVICE_FILE"
    rc-update add sing-box default >/dev/null 2>&1 || true
  else
    mkdir -p /etc/systemd/system
    cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN run -c $CFG
ExecStartPre=$BIN check -c $CFG
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
  fi
}

service_restart(){
  [ -f "$CFG" ] || { red '配置不存在'; return 1; }
  if [ "$INIT" = openrc ]; then
    rc-service sing-box restart >/dev/null 2>&1 ||
      rc-service sing-box start >/dev/null 2>&1 ||
      { red 'sing-box 启动失败'; return 1; }
  else
    systemctl restart sing-box || { red 'sing-box 重启失败'; return 1; }
  fi
  green 'sing-box 已重启'
}

apply_config(){
  generate_config || return 1
  service_create
  service_restart
  save
}

set_common(){
  load
  ask_set SERVER "服务器 IP/域名 [${SERVER:-YOUR_SERVER_IP}]: " "${SERVER:-YOUR_SERVER_IP}"
  ask_set NODE "节点名称 [$NODE]: " "$NODE"
  ask_set DOMAIN "证书域名/SNI [$DOMAIN]: " "$DOMAIN"
  save
}

configure_node(){
  protocol=$1
  ensure_common
  case "$protocol" in
    anytls)
      [ -s "$CERT" ] && [ -s "$KEY" ] || { yellow 'AnyTLS 需要证书，请先执行: cert self'; return 1; }
      ask_set ANYTLS_PORT "AnyTLS 端口 [$ANYTLS_PORT]: " "$ANYTLS_PORT"
      ask_set ANYTLS_NAME "AnyTLS 用户名 [$ANYTLS_NAME]: " "$ANYTLS_NAME"
      ask_set ANYTLS_PASSWORD "AnyTLS 密码 [$ANYTLS_PASSWORD]: " "$ANYTLS_PASSWORD"
      ANYTLS=1;;
    tuic)
      [ -s "$CERT" ] && [ -s "$KEY" ] || { yellow 'TUIC 需要证书，请先执行: cert self'; return 1; }
      ask_set TUIC_PORT "TUIC 端口 [$TUIC_PORT]: " "$TUIC_PORT"
      ask_set TUIC_UUID "TUIC UUID [$TUIC_UUID]: " "$TUIC_UUID"
      ask_set TUIC_PASSWORD "TUIC 密码 [$TUIC_PASSWORD]: " "$TUIC_PASSWORD"
      TUIC=1;;
    hy2)
      [ -s "$CERT" ] && [ -s "$KEY" ] || { yellow 'Hysteria2 需要证书，请先执行: cert self'; return 1; }
      ask_set HY2_PORT "Hysteria2 端口 [$HY2_PORT]: " "$HY2_PORT"
      ask_set HY2_PASSWORD "Hysteria2 密码 [$HY2_PASSWORD]: " "$HY2_PASSWORD"
      HY2=1;;
    vless_ws)
      ask_set VLESS_WS_PORT "VLESS WS 端口 [$VLESS_WS_PORT]: " "$VLESS_WS_PORT"
      ask_set VLESS_WS_UUID "VLESS WS UUID [$VLESS_WS_UUID]: " "$VLESS_WS_UUID"
      ask_set VLESS_WS_PATH "VLESS WS 路径 [$VLESS_WS_PATH]: " "$VLESS_WS_PATH"
      VLESS_WS_PATH=$(path_norm "$VLESS_WS_PATH")
      VLESS_WS=1;;
    vmess_ws)
      ask_set VMESS_WS_PORT "VMess WS 端口 [$VMESS_WS_PORT]: " "$VMESS_WS_PORT"
      ask_set VMESS_WS_UUID "VMess WS UUID [$VMESS_WS_UUID]: " "$VMESS_WS_UUID"
      ask_set VMESS_WS_PATH "VMess WS 路径 [$VMESS_WS_PATH]: " "$VMESS_WS_PATH"
      VMESS_WS_PATH=$(path_norm "$VMESS_WS_PATH")
      VMESS_WS=1;;
    reality)
      ask_set REALITY_PORT "Reality 端口 [$REALITY_PORT]: " "$REALITY_PORT"
      ask_set REALITY_UUID "Reality UUID [$REALITY_UUID]: " "$REALITY_UUID"
      ask_set REALITY_SNI "Reality SNI [$REALITY_SNI]: " "$REALITY_SNI"
      generate_reality_keys
      REALITY=1;;
    *) return 2;;
  esac
  apply_config
}

disable_node(){
  load
  case "$1" in
    anytls) ANYTLS=0;; tuic) TUIC=0;; hy2) HY2=0;;
    vless-ws) VLESS_WS=0;; vmess-ws) VMESS_WS=0;; reality) REALITY=0;;
    *) return 2;;
  esac
  if [ "$ANYTLS$TUIC$HY2$VLESS_WS$VMESS_WS$REALITY" = 000000 ]; then
    save
    if [ "$INIT" = openrc ]; then rc-service sing-box stop >/dev/null 2>&1 || true
    else systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    rm -f "$CFG"
  else
    apply_config
  fi
}

links(){
  load
  printf '%s\n' '已启用节点:'
  [ "$VLESS_WS" = 1 ] && printf 'VLESS-WS 127.0.0.1:%s %s %s\n' "$VLESS_WS_PORT" "$VLESS_WS_UUID" "$VLESS_WS_PATH"
  [ "$VMESS_WS" = 1 ] && printf 'VMess-WS 127.0.0.1:%s %s %s\n' "$VMESS_WS_PORT" "$VMESS_WS_UUID" "$VMESS_WS_PATH"
  [ "$REALITY" = 1 ] && printf 'Reality %s:%s %s %s %s\n' "$SERVER" "$REALITY_PORT" "$REALITY_UUID" "$REALITY_SNI" "$REALITY_SHORT_ID"
  [ "$ANYTLS" = 1 ] && printf 'AnyTLS %s:%s %s\n' "$SERVER" "$ANYTLS_PORT" "$ANYTLS_PASSWORD"
  [ "$TUIC" = 1 ] && printf 'TUIC %s:%s %s %s\n' "$SERVER" "$TUIC_PORT" "$TUIC_UUID" "$TUIC_PASSWORD"
  [ "$HY2" = 1 ] && printf 'Hysteria2 %s:%s %s\n' "$SERVER" "$HY2_PORT" "$HY2_PASSWORD"
}

status(){
  load
  line
  printf 'OS=%s INIT=%s VERSION=%s\n' "$OS" "$INIT" "$VERSION"
  printf 'CONFIG=%s\n' "$CFG"
  [ -f "$CFG" ] && "$BIN" check -c "$CFG" || true
  if [ "$INIT" = openrc ]; then rc-service sing-box status 2>&1 || true
  else systemctl --no-pager status sing-box 2>&1 || true
  fi
  ss -lntup 2>/dev/null | grep -E 'sing-box|:20008|:20009|:1844[3-6]' || true
}

cert_command(){
  case "${1:-}" in
    self) load; cert_self;;
    info) [ -s "$CERT" ] && openssl x509 -in "$CERT" -noout -subject -issuer -dates || yellow '没有证书';;
    *) echo "用法: $0 cert {self|info}"; return 2;;
  esac
}

menu(){
  while :; do
    printf '\033c'
    printf 'sing-box %s (%s/OpenRC compatible)\n' "$VERSION" "$OS"
    printf '1) 设置公共参数\n2) 配置 VLESS WS\n3) 配置 VMess WS\n4) 配置 Reality\n5) 配置 AnyTLS\n6) 配置 TUIC\n7) 配置 Hysteria2\n8) 生成自签证书\n9) 查看链接\n10) 重启服务\n11) 查看状态\n0) 退出\n选择: '
    IFS= read -r choice || exit 0
    case "$choice" in
      1) set_common;; 2) configure_node vless_ws;; 3) configure_node vmess_ws;;
      4) configure_node reality;; 5) configure_node anytls;; 6) configure_node tuic;;
      7) configure_node hy2;; 8) cert_command self;; 9) links;; 10) service_restart;;
      11) status;; 0) exit 0;; *) yellow '无效选项';;
    esac
  done
}

main(){
  root_check
  detect_os
  load
  case "${1:-menu}" in
    install) install_packages; install_binary; service_create;;
    nodes) set_common;;
    anytls|tuic|hy2|reality|vless-ws|vmess-ws)
      case "$1" in
        vless-ws) configure_node vless_ws;;
        vmess-ws) configure_node vmess_ws;;
        *) configure_node "$1";;
      esac;;
    cert) shift; cert_command "$@";;
    disable) shift; disable_node "$@";;
    links) links;;
    restart) service_restart;;
    status) status;;
    logs) tail -n 100 "$LOG" 2>/dev/null || true;;
    menu) menu;;
    *) echo "用法: $0 {install|nodes|anytls|tuic|hy2|reality|vless-ws|vmess-ws|cert|disable|links|restart|status|logs}"; return 2;;
  esac
}

main "$@"
