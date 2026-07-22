#!/bin/sh
set -eu

VERSION="1.13.14"
PREFIX=/usr/local/bin
BIN="$PREFIX/sing-box"
SCRIPT="$PREFIX/singbox-manager.sh"
CFG_DIR=/etc/sing-box
CFG="$CFG_DIR/config.json"
PARAMS="$CFG_DIR/params.env"
CERT_DIR="$CFG_DIR/certs"
CERT="$CERT_DIR/fullchain.pem"
KEY="$CERT_DIR/key.pem"
REALITY_DIR="$CFG_DIR/reality"
LOG_DIR=/var/log/sing-box
LOG="$LOG_DIR/sing-box.log"
SERVICE=sing-box
SERVICE_FILE="/etc/init.d/$SERVICE"
ACME="/root/.acme.sh/acme.sh"
CF_ENV="/root/.config/singbox/cloudflare.env"

red(){ printf '\033[31m%s\033[0m\n' "$1"; }
green(){ printf '\033[32m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }
line(){ printf '%s\n' '------------------------------------------------------------'; }

root_check(){ [ "$(id -u)" = 0 ] || { red '请使用 root 运行'; exit 1; }; }
os_detect(){
  if [ -f /etc/alpine-release ]; then OS=alpine; PM=apk; INIT=openrc; MUSL=1
  elif [ -f /etc/debian_version ]; then OS=debian; PM=apt; INIT=systemd; MUSL=0
  else red '仅支持 Alpine、Debian、Ubuntu'; exit 1; fi
  green "系统: $OS / $(uname -m)"
}
arch_detect(){
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l) ARCH=armv7 ;;
    *) red "不支持架构: $(uname -m)"; exit 1 ;;
  esac
}
packages(){
  if [ "$PM" = apk ]; then
    apk update
    apk add --no-cache curl ca-certificates tar gzip openssl socat iproute2 procps coreutils python3
    update-ca-certificates >/dev/null 2>&1 || true
  else
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar gzip openssl socat iproute2 procps python3
  fi
}
install_binary(){
  install -m 755 "$0" "$SCRIPT" 2>/dev/null || true
  arch_detect
  if [ "$MUSL" = 1 ]; then suffix=-musl; else suffix=; fi
  url="https://github.com/SagerNet/sing-box/releases/download/v$VERSION/sing-box-$VERSION-linux-$ARCH$suffix.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  curl -fL "$url" -o "$tmp/sb.tgz"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  file=$(find "$tmp" -type f -name sing-box | head -n1)
  [ -n "$file" ] || { red '未找到 sing-box 二进制'; exit 1; }
  install -m 755 "$file" "$BIN"
  ln -sf "$SCRIPT" "$PREFIX/singbox"
  ln -sf "$SCRIPT" "$PREFIX/sb"
  trap - EXIT INT TERM
  rm -rf "$tmp"
  "$BIN" version
}
ensure_binary(){ [ -x "$BIN" ] || install_binary; }

uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16; }
password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }
shortid(){ openssl rand -hex 8; }
path_norm(){ case "$1" in /*) printf '%s' "$1";; *) printf '/%s' "$1";; esac; }
port_check(){
  case "$1" in ''|*[!0-9]*) red "端口无效: $1"; return 1;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { red "端口范围无效: $1"; return 1; }
}

ensure_randoms(){
  [ -n "$ANYTLS_PASSWORD" ] || ANYTLS_PASSWORD=$(password)
  [ -n "$TUIC_UUID" ] || TUIC_UUID=$(uuid)
  [ -n "$TUIC_PASSWORD" ] || TUIC_PASSWORD=$(password)
  [ -n "$HY2_PASSWORD" ] || HY2_PASSWORD=$(password)
  [ -n "$VLESS_WS_UUID" ] || VLESS_WS_UUID=$(uuid)
  [ -n "$VMESS_WS_UUID" ] || VMESS_WS_UUID=$(uuid)
  [ -n "$REALITY_UUID" ] || REALITY_UUID=$(uuid)
  [ -n "$REALITY_SHORT_ID" ] || REALITY_SHORT_ID=$(shortid)
}
reset_protocol_defaults(){
  case "${1:-}" in
    anytls) ANYTLS_PASSWORD=$(password) ;;
    tuic) TUIC_UUID=$(uuid); TUIC_PASSWORD=$(password) ;;
    hy2) HY2_PASSWORD=$(password) ;;
    vless_ws) VLESS_WS_UUID=$(uuid) ;;
    vmess_ws) VMESS_WS_UUID=$(uuid) ;;
    reality) REALITY_UUID=$(uuid); REALITY_SHORT_ID=$(shortid) ;;
  esac
}

defaults(){
  ANYTLS=0; ANYTLS_PORT=18443; ANYTLS_NAME=user; ANYTLS_PASSWORD=
  TUIC=0; TUIC_PORT=18444; TUIC_UUID=; TUIC_PASSWORD=
  HY2=0; HY2_PORT=18445; HY2_PASSWORD=
  VLESS_WS=0; VLESS_WS_PORT=20008; VLESS_WS_UUID=; VLESS_WS_PATH=/ws
  VMESS_WS=0; VMESS_WS_PORT=20009; VMESS_WS_UUID=; VMESS_WS_PATH=/vmess
  REALITY=0; REALITY_PORT=18446; REALITY_UUID=; REALITY_SNI=www.apple.com; REALITY_SHORT_ID=
  SERVER=; DOMAIN=; NODE=sing-box-node; CERT_MODE=none
}
load(){
  defaults
  [ -f "$PARAMS" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in ''|'#'*) continue;; esac
    k=${l%%=*}; v=${l#*=}
    case "$k" in
      ANYTLS|ANYTLS_PORT|ANYTLS_NAME|ANYTLS_PASSWORD|TUIC|TUIC_PORT|TUIC_UUID|TUIC_PASSWORD|HY2|HY2_PORT|HY2_PASSWORD|VLESS_WS|VLESS_WS_PORT|VLESS_WS_UUID|VLESS_WS_PATH|VMESS_WS|VMESS_WS_PORT|VMESS_WS_UUID|VMESS_WS_PATH|REALITY|REALITY_PORT|REALITY_UUID|REALITY_SNI|REALITY_SHORT_ID|SERVER|DOMAIN|NODE|CERT_MODE)
        eval "$k=\"$v\"" ;;
    esac
  done < "$PARAMS"
}
save(){
  umask 077
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

cert_self(){
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$KEY" -out "$CERT" -subj "/CN=${DOMAIN:-sing-box}" >/dev/null 2>&1
  chmod 600 "$KEY"; chmod 644 "$CERT"
  CERT_MODE=self
  green "自签证书已生成: $CERT"
}
load_cf_token(){ if [ -r "$CF_ENV" ]; then . "$CF_ENV"; fi; return 0; }
save_cf_token(){
  mkdir -p "$(dirname "$CF_ENV")"
  umask 077
  printf '%s\n' "export CF_Token=\"$CF_Token\"" > "$CF_ENV"
  chmod 600 "$CF_ENV"
}
cert_acme(){
  [ -x "$ACME" ] || { curl https://get.acme.sh | sh; }
  load_cf_token
  if [ -n "${CF_Token:-}" ]; then
    printf '检测到已保存 Cloudflare API Token，是否重新输入？[y/N]: '
    IFS= read -r replace_token || replace_token=n
    case "$replace_token" in
      y|Y) printf '请输入 Cloudflare API Token: '; IFS= read -r CF_Token; [ -n "$CF_Token" ] || { red 'API Token 不能为空'; return 1; }; save_cf_token ;;
      *) green "将使用已保存 Token: $CF_ENV" ;;
    esac
  else
    printf '请输入 Cloudflare API Token: '; IFS= read -r CF_Token
    [ -n "$CF_Token" ] || { red 'API Token 不能为空'; return 1; }
    save_cf_token
  fi
  export CF_Token
  "$ACME" --set-default-ca --server letsencrypt
  printf '证书域名: '; IFS= read -r DOMAIN
  [ -n "$DOMAIN" ] || { red '域名不能为空'; return 1; }
  mkdir -p "$CERT_DIR"
  "$ACME" --issue --dns dns_cf -d "$DOMAIN"
  "$ACME" --install-cert -d "$DOMAIN" --key-file "$KEY" --fullchain-file "$CERT" --reloadcmd "$SCRIPT restart >/dev/null 2>&1 || true"
  chmod 600 "$KEY"; chmod 644 "$CERT"
  CERT_MODE=acme
  save
  cron_enable
  green "证书已部署: $CERT"
}
cron_enable(){
  if [ "$INIT" = openrc ]; then rc-service crond start >/dev/null 2>&1 || true; rc-update add crond default >/dev/null 2>&1 || true; fi
}
cert_exists(){ [ -s "$CERT" ] && [ -s "$KEY" ]; }
cert_info(){
  line
  if cert_exists; then openssl x509 -in "$CERT" -noout -subject -issuer -serial -dates 2>/dev/null || true; printf '证书: %s\n私钥: %s\n模式: %s\n' "$CERT" "$KEY" "$CERT_MODE"; else yellow '当前没有证书'; fi
}
cert_delete(){ cert_info; printf '确认删除证书和私钥? [y/N]: '; IFS= read -r a; case "$a" in y|Y) rm -f "$CERT" "$KEY"; CERT_MODE=none; save; green '证书已删除' ;; *) yellow '已取消' ;; esac; }
require_cert(){ if ! cert_exists; then yellow '该节点需要证书，请先申请或生成证书'; cert_menu; cert_exists || { red '未配置证书'; return 1; }; fi; }

reality_keys(){
  ensure_binary
  mkdir -p "$REALITY_DIR"
  if [ ! -s "$REALITY_DIR/private.key" ] || [ ! -s "$REALITY_DIR/public.key" ]; then
    out=$("$BIN" generate reality-keypair)
    printf '%s\n' "$out" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n1 > "$REALITY_DIR/private.key"
    printf '%s\n' "$out" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n1 > "$REALITY_DIR/public.key"
    chmod 600 "$REALITY_DIR"/*
  fi
  [ -n "$REALITY_SHORT_ID" ] || REALITY_SHORT_ID=$(shortid)
}

ask_set(){ _var="$1"; _prompt="$2"; _default="$3"; printf '%s' "$_prompt"; IFS= read -r _ans || _ans=; if [ -n "$_ans" ]; then eval "$_var=\"\$_ans\""; else eval "$_var=\"\$_default\""; fi; }
ensure_common(){
  load
  ensure_binary
  if [ -z "$SERVER" ]; then _def=$(hostname -i 2>/dev/null | awk '{print $1}'); [ -n "$_def" ] || _def=YOUR_SERVER_IP; ask_set SERVER "服务器IP/域名 [$_def]: " "$_def"; fi
  [ -n "$NODE" ] || NODE=sing-box-node
}

apply_config(){ ensure_randoms; generate_config || return 1; service_create; service_restart; save; }

status_nodes(){
  load
  line
  printf '当前节点状态:\n'
  printf '服务器: %s | 域名/SNI: %s | 节点名: %s\n' "${SERVER:-未设置}" "${DOMAIN:-未设置}" "$NODE"
  [ "$ANYTLS" = 1 ] && printf 'AnyTLS        : 开启  端口 %s\n' "$ANYTLS_PORT" || printf 'AnyTLS        : 关闭\n'
  [ "$TUIC" = 1 ] && printf 'TUIC          : 开启  端口 %s\n' "$TUIC_PORT" || printf 'TUIC          : 关闭\n'
  [ "$HY2" = 1 ] && printf 'Hysteria2     : 开启  端口 %s\n' "$HY2_PORT" || printf 'Hysteria2     : 关闭\n'
  [ "$VLESS_WS" = 1 ] && printf 'VLESS+WS      : 开启  端口 %s  path %s\n' "$VLESS_WS_PORT" "$VLESS_WS_PATH" || printf 'VLESS+WS      : 关闭\n'
  [ "$VMESS_WS" = 1 ] && printf 'VMess+WS      : 开启  端口 %s  path %s\n' "$VMESS_WS_PORT" "$VMESS_WS_PATH" || printf 'VMess+WS      : 关闭\n'
  [ "$REALITY" = 1 ] && printf 'VLESS+Reality : 开启  端口 %s  sni %s\n' "$REALITY_PORT" "$REALITY_SNI" || printf 'VLESS+Reality : 关闭\n'
}

set_common(){
  load
  _def_server="${SERVER:-$(hostname -i 2>/dev/null | awk '{print $1}')}"; [ -n "$_def_server" ] || _def_server=YOUR_SERVER_IP
  ask_set SERVER "服务器IP/域名 [$_def_server]: " "$_def_server"
  ask_set NODE "节点名称 [$NODE]: " "$NODE"
  ask_set DOMAIN "证书域名/SNI [$DOMAIN]: " "$DOMAIN"
  save
  green '公共参数已保存'
}

cfg_anytls(){ ensure_common || return 1; require_cert || return 1; reset_protocol_defaults anytls; ask_set ANYTLS_PORT "AnyTLS端口 [$ANYTLS_PORT]: " "$ANYTLS_PORT"; port_check "$ANYTLS_PORT" || return 1; ask_set ANYTLS_NAME "AnyTLS用户名 [$ANYTLS_NAME]: " "$ANYTLS_NAME"; ask_set ANYTLS_PASSWORD "AnyTLS密码（留空使用随机默认值） [$ANYTLS_PASSWORD]: " "$ANYTLS_PASSWORD"; ANYTLS=1; apply_config || return 1; show_one_link anytls; }
cfg_tuic(){ ensure_common || return 1; require_cert || return 1; reset_protocol_defaults tuic; ask_set TUIC_PORT "TUIC端口 [$TUIC_PORT]: " "$TUIC_PORT"; port_check "$TUIC_PORT" || return 1; ask_set TUIC_UUID "TUIC UUID（留空使用随机默认值） [$TUIC_UUID]: " "$TUIC_UUID"; ask_set TUIC_PASSWORD "TUIC密码（留空使用随机默认值） [$TUIC_PASSWORD]: " "$TUIC_PASSWORD"; TUIC=1; apply_config || return 1; show_one_link tuic; }
cfg_hy2(){ ensure_common || return 1; require_cert || return 1; reset_protocol_defaults hy2; ask_set HY2_PORT "Hysteria2端口 [$HY2_PORT]: " "$HY2_PORT"; port_check "$HY2_PORT" || return 1; ask_set HY2_PASSWORD "Hysteria2密码（留空使用随机默认值） [$HY2_PASSWORD]: " "$HY2_PASSWORD"; HY2=1; apply_config || return 1; show_one_link hy2; }
cfg_vless_ws(){ ensure_common || return 1; reset_protocol_defaults vless_ws; ask_set VLESS_WS_PORT "VLESS WS端口 [$VLESS_WS_PORT]: " "$VLESS_WS_PORT"; port_check "$VLESS_WS_PORT" || return 1; ask_set VLESS_WS_UUID "VLESS WS UUID（留空使用随机默认值） [$VLESS_WS_UUID]: " "$VLESS_WS_UUID"; ask_set VLESS_WS_PATH "WS路径 [$VLESS_WS_PATH]: " "$VLESS_WS_PATH"; VLESS_WS_PATH=$(path_norm "$VLESS_WS_PATH"); VLESS_WS=1; apply_config || return 1; show_one_link vless_ws; }
cfg_vmess_ws(){ ensure_common || return 1; reset_protocol_defaults vmess_ws; ask_set VMESS_WS_PORT "VMess WS端口 [$VMESS_WS_PORT]: " "$VMESS_WS_PORT"; port_check "$VMESS_WS_PORT" || return 1; ask_set VMESS_WS_UUID "VMess WS UUID（留空使用随机默认值） [$VMESS_WS_UUID]: " "$VMESS_WS_UUID"; ask_set VMESS_WS_PATH "VMess WS路径 [$VMESS_WS_PATH]: " "$VMESS_WS_PATH"; VMESS_WS_PATH=$(path_norm "$VMESS_WS_PATH"); VMESS_WS=1; apply_config || return 1; show_one_link vmess_ws; }
cfg_reality(){ ensure_common || return 1; reset_protocol_defaults reality; ask_set REALITY_PORT "Reality端口 [$REALITY_PORT]: " "$REALITY_PORT"; port_check "$REALITY_PORT" || return 1; ask_set REALITY_UUID "Reality UUID（留空使用随机默认值） [$REALITY_UUID]: " "$REALITY_UUID"; ask_set REALITY_SNI "Reality SNI [$REALITY_SNI]: " "$REALITY_SNI"; reality_keys; REALITY=1; apply_config || return 1; show_one_link reality; }

regen_random_current(){
  load
  [ "$ANYTLS" = 1 ] && ANYTLS_PASSWORD=$(password)
  [ "$TUIC" = 1 ] && TUIC_UUID=$(uuid) && TUIC_PASSWORD=$(password)
  [ "$HY2" = 1 ] && HY2_PASSWORD=$(password)
  [ "$VLESS_WS" = 1 ] && VLESS_WS_UUID=$(uuid)
  [ "$VMESS_WS" = 1 ] && VMESS_WS_UUID=$(uuid)
  if [ "$REALITY" = 1 ]; then REALITY_UUID=$(uuid); REALITY_SHORT_ID=$(shortid); fi
  reality_keys
  apply_config
  green '已为当前启用协议重置随机参数'
  links
}

disable_node(){
  load
  status_nodes
  printf '关闭哪个节点?\n1) AnyTLS\n2) TUIC\n3) Hysteria2\n4) VLESS+WS\n5) VMess+WS\n6) VLESS+Reality\n0) 返回\n选择: '
  IFS= read -r c || return
  case "$c" in
    1) ANYTLS=0 ;;
    2) TUIC=0 ;;
    3) HY2=0 ;;
    4) VLESS_WS=0 ;;
    5) VMESS_WS=0 ;;
    6) REALITY=0 ;;
    0) return ;;
    *) yellow '无效选项'; return ;;
  esac
  if [ "$ANYTLS$TUIC$HY2$VLESS_WS$VMESS_WS$REALITY" = 000000 ]; then
    yellow '已关闭全部节点，停止服务'
    save
    if [ "$INIT" = openrc ]; then rc-service sing-box stop >/dev/null 2>&1 || true; else systemctl stop sing-box >/dev/null 2>&1 || true; fi
    rm -f "$CFG"
    green '全部节点已关闭'
    return
  fi
  apply_config
  green '节点已关闭并应用'
}

generate_config(){
  TMP="$CFG.tmp.$$"
  mkdir -p "$CFG_DIR" "$LOG_DIR"
  [ "$ANYTLS$TUIC$HY2$VLESS_WS$VMESS_WS$REALITY" != 000000 ] || { red '没有启用节点'; return 1; }
  python3 - "$TMP" <<PY
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
config = {
    "log": {"level": "info", "timestamp": True, "output": "$LOG"},
    "inbounds": [],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {"final": "direct"},
}
if "$VLESS_WS" == "1":
    config["inbounds"].append({
        "type": "vless", "tag": "ws-in", "listen": "::", "listen_port": int("$VLESS_WS_PORT"),
        "users": [{"uuid": "$VLESS_WS_UUID"}],
        "transport": {"type": "ws", "path": "$VLESS_WS_PATH", "early_data_header_name": "Sec-WebSocket-Protocol"},
    })
if "$VMESS_WS" == "1":
    config["inbounds"].append({
        "type": "vmess", "tag": "vmess-in", "listen": "::", "listen_port": int("$VMESS_WS_PORT"),
        "users": [{"name": "user", "uuid": "$VMESS_WS_UUID", "alterId": 0}],
        "transport": {"type": "ws", "path": "$VMESS_WS_PATH", "early_data_header_name": "Sec-WebSocket-Protocol"},
    })
if "$REALITY" == "1":
    private_key = pathlib.Path("$REALITY_DIR/private.key").read_text().strip()
    config["inbounds"].append({
        "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": int("$REALITY_PORT"),
        "users": [{"uuid": "$REALITY_UUID", "flow": "xtls-rprx-vision"}],
        "tls": {"enabled": True, "server_name": "$REALITY_SNI", "reality": {"enabled": True, "handshake": {"server": "$REALITY_SNI", "server_port": 443}, "private_key": private_key, "short_id": ["$REALITY_SHORT_ID"]}},
    })
if "$ANYTLS" == "1":
    config["inbounds"].append({
        "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": int("$ANYTLS_PORT"),
        "users": [{"name": "$ANYTLS_NAME", "password": "$ANYTLS_PASSWORD"}],
        "tls": {"enabled": True, "certificate_path": "$CERT", "key_path": "$KEY"},
    })
if "$HY2" == "1":
    config["inbounds"].append({
        "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": int("$HY2_PORT"),
        "obfs": {"type": "salamander", "password": "$HY2_PASSWORD"},
        "users": [{"name": "user", "password": "$HY2_PASSWORD"}],
        "tls": {"enabled": True, "alpn": ["h3"], "certificate_path": "$CERT", "key_path": "$KEY"},
    })
if "$TUIC" == "1":
    config["inbounds"].append({
        "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": int("$TUIC_PORT"),
        "users": [{"name": "user", "uuid": "$TUIC_UUID", "password": "$TUIC_PASSWORD"}],
        "congestion_control": "bbr", "auth_timeout": "3s", "zero_rtt_handshake": False, "heartbeat": "10s",
        "tls": {"enabled": True, "alpn": ["h3"], "certificate_path": "$CERT", "key_path": "$KEY"},
    })
out.write_text(json.dumps(config, ensure_ascii=True, indent=2) + chr(10))
PY
  "$BIN" check -c "$TMP"
  mv "$TMP" "$CFG"
  chmod 600 "$CFG"
  green '配置校验通过并已应用'
}

service_create(){
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
start_pre(){ $BIN check -c $CFG; }
depend(){ need net; after firewall; }
EOF
    chmod 755 "$SERVICE_FILE"
    rc-update add sing-box default >/dev/null 2>&1 || true
  else
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network-online.target
[Service]
ExecStart=$BIN run -c $CFG
ExecStartPre=$BIN check -c $CFG
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
  fi
}
service_restart(){ if [ ! -f "$CFG" ]; then yellow '配置不存在'; return 1; fi; if [ "$INIT" = openrc ]; then rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start; else systemctl restart sing-box; fi; green 'sing-box 已重启'; }

manual_one(){
  load
  host=${SERVER:-YOUR_SERVER_IP}
  case "$1" in
    anytls) [ "$ANYTLS" = 1 ] || return 0; printf 'AnyTLS 手填参数\n地址: %s\n端口: %s\n密码: %s\nSNI: %s\n' "$host" "$ANYTLS_PORT" "$ANYTLS_PASSWORD" "$DOMAIN" ;;
    tuic) [ "$TUIC" = 1 ] || return 0; printf 'TUIC 手填参数\n地址: %s\n端口: %s\nUUID: %s\n密码: %s\nSNI: %s\nALPN: h3\n拥塞控制: bbr\n认证超时: 3s\nZero RTT: false\n心跳: 10s\n' "$host" "$TUIC_PORT" "$TUIC_UUID" "$TUIC_PASSWORD" "$DOMAIN" ;;
    hy2) [ "$HY2" = 1 ] || return 0; printf 'Hysteria2 手填参数\n地址: %s\n端口: %s\n密码: %s\n混淆: salamander\n混淆密码: %s\nALPN: h3\n' "$host" "$HY2_PORT" "$HY2_PASSWORD" "$HY2_PASSWORD" ;;
    vless_ws) [ "$VLESS_WS" = 1 ] || return 0; printf 'VLESS+WS 手填参数\n地址: %s\n端口: %s\nUUID: %s\n传输: ws\n路径: %s\nTLS: false\n' "$host" "$VLESS_WS_PORT" "$VLESS_WS_UUID" "$VLESS_WS_PATH" ;;
    vmess_ws) [ "$VMESS_WS" = 1 ] || return 0; printf 'VMess+WS 手填参数\n地址: %s\n端口: %s\nUUID: %s\nalterId: 0\n传输: ws\n路径: %s\nTLS: false\n' "$host" "$VMESS_WS_PORT" "$VMESS_WS_UUID" "$VMESS_WS_PATH" ;;
    reality) [ "$REALITY" = 1 ] || return 0; printf 'Reality 手填参数\n地址: %s\n端口: %s\nUUID: %s\nSNI: %s\nPublicKey: %s\nShortID: %s\nFlow: xtls-rprx-vision\n' "$host" "$REALITY_PORT" "$REALITY_UUID" "$REALITY_SNI" "$(cat "$REALITY_DIR/public.key")" "$REALITY_SHORT_ID" ;;
  esac
}
show_one_link(){
  load
  host=${SERVER:-YOUR_SERVER_IP}
  printf '\n节点链接:\n'
  case "$1" in
    anytls) [ "$ANYTLS" = 1 ] && printf 'anytls://%s@%s:%s/?sni=%s#%s-anytls\n' "$ANYTLS_PASSWORD" "$host" "$ANYTLS_PORT" "$DOMAIN" "$NODE" && manual_one anytls ;;
    tuic) [ "$TUIC" = 1 ] && printf 'tuic://%s:%s@%s:%s?sni=%s&congestion_control=bbr#%s-tuic\n' "$TUIC_UUID" "$TUIC_PASSWORD" "$host" "$TUIC_PORT" "$DOMAIN" "$NODE" && manual_one tuic ;;
    hy2) [ "$HY2" = 1 ] && printf 'hysteria2://%s@%s:%s/?sni=%s#%s-hy2\n' "$HY2_PASSWORD" "$host" "$HY2_PORT" "$DOMAIN" "$NODE" && manual_one hy2 ;;
    vless_ws) [ "$VLESS_WS" = 1 ] && printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&path=%s#%s-vless-ws\n' "$VLESS_WS_UUID" "$host" "$VLESS_WS_PORT" "$(printf '%s' "$VLESS_WS_PATH" | sed 's#/#%2F#g')" "$NODE" && manual_one vless_ws ;;
    vmess_ws) [ "$VMESS_WS" = 1 ] && printf 'vmess://%s@%s:%s?type=ws&path=%s&security=none&alterId=0#%s-vmess-ws\n' "$VMESS_WS_UUID" "$host" "$VMESS_WS_PORT" "$(printf '%s' "$VMESS_WS_PATH" | sed 's#/#%2F#g')" "$NODE" && manual_one vmess_ws ;;
    reality) [ "$REALITY" = 1 ] && [ -s "$REALITY_DIR/public.key" ] && printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s-reality\n' "$REALITY_UUID" "$host" "$REALITY_PORT" "$REALITY_SNI" "$(cat "$REALITY_DIR/public.key")" "$REALITY_SHORT_ID" "$NODE" && manual_one reality ;;
  esac
}
links(){
  load
  host=${SERVER:-YOUR_SERVER_IP}
  printf '\n已启用节点链接:\n'
  [ "$ANYTLS" = 1 ] && printf 'anytls://%s@%s:%s/?sni=%s#%s-anytls\n' "$ANYTLS_PASSWORD" "$host" "$ANYTLS_PORT" "$DOMAIN" "$NODE"
  [ "$TUIC" = 1 ] && printf 'tuic://%s:%s@%s:%s?sni=%s&congestion_control=bbr#%s-tuic\n' "$TUIC_UUID" "$TUIC_PASSWORD" "$host" "$TUIC_PORT" "$DOMAIN" "$NODE"
  [ "$HY2" = 1 ] && printf 'hysteria2://%s@%s:%s/?sni=%s#%s-hy2\n' "$HY2_PASSWORD" "$host" "$HY2_PORT" "$DOMAIN" "$NODE"
  [ "$VLESS_WS" = 1 ] && printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&path=%s#%s-vless-ws\n' "$VLESS_WS_UUID" "$host" "$VLESS_WS_PORT" "$(printf '%s' "$VLESS_WS_PATH" | sed 's#/#%2F#g')" "$NODE"
  [ "$VMESS_WS" = 1 ] && printf 'vmess://%s@%s:%s?type=ws&path=%s&security=none&alterId=0#%s-vmess-ws\n' "$VMESS_WS_UUID" "$host" "$VMESS_WS_PORT" "$(printf '%s' "$VMESS_WS_PATH" | sed 's#/#%2F#g')" "$NODE"
  [ "$REALITY" = 1 ] && [ -s "$REALITY_DIR/public.key" ] && printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s-reality\n' "$REALITY_UUID" "$host" "$REALITY_PORT" "$REALITY_SNI" "$(cat "$REALITY_DIR/public.key")" "$REALITY_SHORT_ID" "$NODE"
  if [ "$ANYTLS$TUIC$HY2$VLESS_WS$VMESS_WS$REALITY" = 000000 ]; then yellow '当前没有启用任何节点'; fi
  printf '\n手填参数:\n'
  [ "$ANYTLS" = 1 ] && manual_one anytls && printf '\n'
  [ "$TUIC" = 1 ] && manual_one tuic && printf '\n'
  [ "$HY2" = 1 ] && manual_one hy2 && printf '\n'
  [ "$VLESS_WS" = 1 ] && manual_one vless_ws && printf '\n'
  [ "$VMESS_WS" = 1 ] && manual_one vmess_ws && printf '\n'
  [ "$REALITY" = 1 ] && manual_one reality
}

node_menu(){
  while :; do
    status_nodes
    line
    printf '节点管理（单独配置）\n'
    printf '1) 设置服务器/节点名/域名\n'
    printf '2) 配置 AnyTLS\n'
    printf '3) 配置 TUIC\n'
    printf '4) 配置 Hysteria2\n'
    printf '5) 配置 VLESS+WS（无TLS）\n'
    printf '6) 配置 VMess+WS（无TLS）\n'
    printf '7) 配置 VLESS+Reality\n'
    printf '8) 关闭指定节点\n'
    printf '9) 查看节点链接\n'
    printf '10) 应用现有参数并重启\n'
    printf '11) 重置当前节点随机参数\n'
    printf '0) 返回\n'
    printf '选择: '
    IFS= read -r c || return
    case "$c" in
      1) set_common ;;
      2) cfg_anytls ;;
      3) cfg_tuic ;;
      4) cfg_hy2 ;;
      5) cfg_vless_ws ;;
      6) cfg_vmess_ws ;;
      7) cfg_reality ;;
      8) disable_node ;;
      9) links ;;
      10) load; apply_config; links ;;
      11) regen_random_current ;;
      0) return ;;
      *) yellow '无效选项' ;;
    esac
  done
}
cert_menu(){ while :; do line; printf '证书管理\n1) 查看证书\n2) 自签证书\n3) 申请Cloudflare ACME证书\n4) 续期ACME证书\n5) 删除证书\n0) 返回\n选择: '; IFS= read -r c || return; case "$c" in 1) cert_info ;; 2) cert_self; save ;; 3) cert_acme ;; 4) [ -x "$ACME" ] && "$ACME" --cron --home /root/.acme.sh || yellow '尚未安装acme.sh' ;; 5) cert_delete ;; 0) return ;; esac; done; }
menu(){ while :; do line; printf 'sing-box %s 一体化管理器\n' "$VERSION"; printf '1) 安装/更新依赖和sing-box\n2) 节点管理（单独配置）\n3) 证书管理\n4) 查看节点链接\n5) 重启服务\n6) 查看日志\n0) 退出\n选择: '; IFS= read -r c || exit; case "$c" in 1) packages; install_binary; ln -sf "$SCRIPT" "$PREFIX/singbox"; ln -sf "$SCRIPT" "$PREFIX/sb" ;; 2) node_menu ;; 3) cert_menu ;; 4) links ;; 5) load; service_restart ;; 6) tail -n 100 "$LOG" 2>/dev/null || true ;; 0) exit 0 ;; *) yellow '无效选项' ;; esac; done; }
main(){ root_check; os_detect; load; case "${1:-}" in install) packages; install_binary; service_create ;; nodes|node) node_menu ;; anytls) cfg_anytls ;; tuic) cfg_tuic ;; hy2) cfg_hy2 ;; vless-ws|vless_ws) cfg_vless_ws ;; vmess-ws|vmess_ws|vmess) cfg_vmess_ws ;; reality) cfg_reality ;; cert) cert_menu ;; links) links ;; restart) service_restart ;; logs) tail -n 100 "$LOG" 2>/dev/null || true ;; status) status_nodes ;; regen|regen-random) regen_random_current ;; *) menu ;; esac; }
main "$@"
