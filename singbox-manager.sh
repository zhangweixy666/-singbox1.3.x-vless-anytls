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
    apk add --no-cache curl ca-certificates tar gzip openssl socat iproute2 procps coreutils
    update-ca-certificates >/dev/null 2>&1 || true
  else
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar gzip openssl socat iproute2 procps
  fi
}
install_binary(){
  install -m 755 "$0" "$SCRIPT" 2>/dev/null || true
  arch_detect
  if [ "$MUSL" = 1 ]; then suffix="-musl"; else suffix=; fi
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
password(){ openssl rand -base64 24 | tr -d '\n'; }
shortid(){ openssl rand -hex 8; }
escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
path_norm(){ case "$1" in /*) printf '%s' "$1";; *) printf '/%s' "$1";; esac; }
port_check(){
  case "$1" in ''|*[!0-9]*) red "端口无效: $1"; return 1;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { red "端口范围无效: $1"; return 1; }
}

defaults(){
  ANYTLS=0; ANYTLS_PORT=8443; ANYTLS_NAME=user; ANYTLS_PASSWORD=""
  TUIC=0; TUIC_PORT=8444; TUIC_UUID=""; TUIC_PASSWORD=""
  HY2=0; HY2_PORT=8445; HY2_PASSWORD=""
  VLESS_WS=0; VLESS_WS_PORT=20008; VLESS_WS_UUID=""; VLESS_WS_PATH=/ws
  REALITY=0; REALITY_PORT=8446; REALITY_UUID=""; REALITY_SNI=www.microsoft.com; REALITY_SHORT_ID=""
  SERVER=""; DOMAIN=""; NODE=sing-box-node; CERT_MODE=none
}
load(){
  defaults
  [ -f "$PARAMS" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in ''|'#'*) continue;; esac
    k=${l%%=*}; v=${l#*=}
    case "$k" in
      ANYTLS|ANYTLS_PORT|ANYTLS_NAME|ANYTLS_PASSWORD|TUIC|TUIC_PORT|TUIC_UUID|TUIC_PASSWORD|HY2|HY2_PORT|HY2_PASSWORD|VLESS_WS|VLESS_WS_PORT|VLESS_WS_UUID|VLESS_WS_PATH|REALITY|REALITY_PORT|REALITY_UUID|REALITY_SNI|REALITY_SHORT_ID|SERVER|DOMAIN|NODE|CERT_MODE)
        eval "$k=\"$v\""
        ;;
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
      y|Y)
        printf '请输入 Cloudflare API Token: '; IFS= read -r CF_Token
        [ -n "$CF_Token" ] || { red 'API Token 不能为空'; return 1; }
        save_cf_token
        ;;
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
  if [ "$INIT" = openrc ]; then
    rc-service crond start >/dev/null 2>&1 || true
    rc-update add crond default >/dev/null 2>&1 || true
  fi
}
cert_exists(){ [ -s "$CERT" ] && [ -s "$KEY" ]; }
cert_info(){
  line
  if cert_exists; then
    openssl x509 -in "$CERT" -noout -subject -issuer -serial -dates 2>/dev/null || true
    printf '证书: %s\n私钥: %s\n模式: %s\n' "$CERT" "$KEY" "$CERT_MODE"
  else
    yellow '当前没有证书'
  fi
}
cert_delete(){
  cert_info
  printf '确认删除证书和私钥? [y/N]: '; IFS= read -r a
  case "$a" in y|Y) rm -f "$CERT" "$KEY"; CERT_MODE=none; save; green '证书已删除' ;; *) yellow '已取消' ;; esac
}
require_cert(){
  if ! cert_exists; then
    yellow '该节点需要证书，请先申请或生成证书'
    cert_menu
    cert_exists || { red '未配置证书'; return 1; }
  fi
}

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

ask_set(){
  _var="$1"; _prompt="$2"; _default="$3"
  printf '%s' "$_prompt"
  IFS= read -r _ans || _ans=
  if [ -n "$_ans" ]; then eval "$_var=\"\$_ans\""
  else eval "$_var=\"\$_default\""
  fi
}
ensure_common(){
  load
  ensure_binary
  if [ -z "$SERVER" ]; then
    _def="$(hostname -i 2>/dev/null | awk '{print $1}')"
    [ -n "$_def" ] || _def=YOUR_SERVER_IP
    ask_set SERVER "服务器IP/域名 [$_def]: " "$_def"
  fi
  if [ -z "$NODE" ]; then NODE=sing-box-node; fi
}

apply_config(){
  generate_config || return 1
  service_create
  service_restart
  save
}

status_nodes(){
  load
  line
  printf '当前节点状态:\n'
  printf '服务器: %s | 域名/SNI: %s | 节点名: %s\n' "${SERVER:-未设置}" "${DOMAIN:-未设置}" "$NODE"
  [ "$ANYTLS" = 1 ] && printf 'AnyTLS     : 开启  端口 %s\n' "$ANYTLS_PORT" || printf 'AnyTLS     : 关闭\n'
  [ "$TUIC" = 1 ] && printf 'TUIC       : 开启  端口 %s\n' "$TUIC_PORT" || printf 'TUIC       : 关闭\n'
  [ "$HY2" = 1 ] && printf 'Hysteria2  : 开启  端口 %s\n' "$HY2_PORT" || printf 'Hysteria2  : 关闭\n'
  [ "$VLESS_WS" = 1 ] && printf 'VLESS+WS   : 开启  端口 %s  path %s\n' "$VLESS_WS_PORT" "$VLESS_WS_PATH" || printf 'VLESS+WS   : 关闭\n'
  [ "$REALITY" = 1 ] && printf 'VLESS+REALITY: 开启  端口 %s  sni %s\n' "$REALITY_PORT" "$REALITY_SNI" || printf 'VLESS+REALITY: 关闭\n'
}

set_common(){
  load
  _def_server="${SERVER:-$(hostname -i 2>/dev/null | awk '{print $1}')}"
  [ -n "$_def_server" ] || _def_server=YOUR_SERVER_IP
  ask_set SERVER "服务器IP/域名 [$_def_server]: " "$_def_server"
  ask_set NODE "节点名称 [$NODE]: " "$NODE"
  ask_set DOMAIN "证书域名/SNI [$DOMAIN]: " "$DOMAIN"
  save
  green '公共参数已保存'
}

cfg_anytls(){
  ensure_common || return 1
  require_cert || return 1
  ask_set ANYTLS_PORT "AnyTLS端口 [$ANYTLS_PORT]: " "$ANYTLS_PORT"
  port_check "$ANYTLS_PORT" || return 1
  ask_set ANYTLS_NAME "AnyTLS用户名 [$ANYTLS_NAME]: " "$ANYTLS_NAME"
  _def_pw="$ANYTLS_PASSWORD"; [ -n "$_def_pw" ] || _def_pw="$(password)"
  ask_set ANYTLS_PASSWORD "AnyTLS密码（留空自动生成）: " "$_def_pw"
  ANYTLS=1
  apply_config || return 1
  show_one_link anytls
}
cfg_tuic(){
  ensure_common || return 1
  require_cert || return 1
  ask_set TUIC_PORT "TUIC端口 [$TUIC_PORT]: " "$TUIC_PORT"
  port_check "$TUIC_PORT" || return 1
  _def_uuid="$TUIC_UUID"; [ -n "$_def_uuid" ] || _def_uuid="$(uuid)"
  ask_set TUIC_UUID "TUIC UUID（留空自动生成）: " "$_def_uuid"
  _def_pw="$TUIC_PASSWORD"; [ -n "$_def_pw" ] || _def_pw="$(password)"
  ask_set TUIC_PASSWORD "TUIC密码（留空自动生成）: " "$_def_pw"
  TUIC=1
  apply_config || return 1
  show_one_link tuic
}
cfg_hy2(){
  ensure_common || return 1
  require_cert || return 1
  ask_set HY2_PORT "Hysteria2端口 [$HY2_PORT]: " "$HY2_PORT"
  port_check "$HY2_PORT" || return 1
  _def_pw="$HY2_PASSWORD"; [ -n "$_def_pw" ] || _def_pw="$(password)"
  ask_set HY2_PASSWORD "Hysteria2密码（留空自动生成）: " "$_def_pw"
  HY2=1
  apply_config || return 1
  show_one_link hy2
}
cfg_vless_ws(){
  ensure_common || return 1
  ask_set VLESS_WS_PORT "VLESS WS端口 [$VLESS_WS_PORT]: " "$VLESS_WS_PORT"
  port_check "$VLESS_WS_PORT" || return 1
  _def_uuid="$VLESS_WS_UUID"; [ -n "$_def_uuid" ] || _def_uuid="$(uuid)"
  ask_set VLESS_WS_UUID "VLESS WS UUID（留空自动生成）: " "$_def_uuid"
  ask_set VLESS_WS_PATH "WS路径 [$VLESS_WS_PATH]: " "$VLESS_WS_PATH"
  VLESS_WS_PATH="$(path_norm "$VLESS_WS_PATH")"
  VLESS_WS=1
  apply_config || return 1
  show_one_link vless_ws
}
cfg_reality(){
  ensure_common || return 1
  ask_set REALITY_PORT "Reality端口 [$REALITY_PORT]: " "$REALITY_PORT"
  port_check "$REALITY_PORT" || return 1
  _def_uuid="$REALITY_UUID"; [ -n "$_def_uuid" ] || _def_uuid="$(uuid)"
  ask_set REALITY_UUID "Reality UUID（留空自动生成）: " "$_def_uuid"
  ask_set REALITY_SNI "Reality SNI [$REALITY_SNI]: " "$REALITY_SNI"
  reality_keys
  REALITY=1
  apply_config || return 1
  show_one_link reality
}

disable_node(){
  load
  status_nodes
  printf '关闭哪个节点?\n1) AnyTLS\n2) TUIC\n3) Hysteria2\n4) VLESS+WS\n5) VLESS+Reality\n0) 返回\n选择: '
  IFS= read -r c || return
  case "$c" in
    1) ANYTLS=0 ;;
    2) TUIC=0 ;;
    3) HY2=0 ;;
    4) VLESS_WS=0 ;;
    5) REALITY=0 ;;
    0) return ;;
    *) yellow '无效选项'; return ;;
  esac
  if [ "$ANYTLS$TUIC$HY2$VLESS_WS$REALITY" = "00000" ]; then
    yellow '已关闭全部节点，停止服务'
    save
    if [ "$INIT" = openrc ]; then rc-service sing-box stop >/dev/null 2>&1 || true
    else systemctl stop sing-box >/dev/null 2>&1 || true; fi
    rm -f "$CFG"
    green '全部节点已关闭'
    return
  fi
  apply_config
  green '节点已关闭并应用'
}

add(){ [ "$written" = 0 ] || printf ',\n' >> "$TMP"; cat >> "$TMP"; written=1; }
generate_config(){
  TMP="$CFG.tmp.$$"
  mkdir -p "$CFG_DIR" "$LOG_DIR"
  written=0
  cat > "$TMP" <<EOF
{
  "log": {"disabled": false, "level": "info", "timestamp": true, "output": "$LOG"},
  "inbounds": [
EOF
  if [ "$ANYTLS" = 1 ]; then
    add <<EOF
    {"type":"anytls","tag":"anytls-in","listen":"::","listen_port":$ANYTLS_PORT,"users":[{"name":"$(escape "$ANYTLS_NAME")","password":"$(escape "$ANYTLS_PASSWORD")"}],"padding_scheme":[],"tls":{"enabled":true,"server_name":"$(escape "$DOMAIN")","certificate_path":"$CERT","key_path":"$KEY"}}
EOF
  fi
  if [ "$TUIC" = 1 ]; then
    add <<EOF
    {"type":"tuic","tag":"tuic-in","listen":"::","listen_port":$TUIC_PORT,"users":[{"uuid":"$TUIC_UUID","password":"$(escape "$TUIC_PASSWORD")"}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":"$(escape "$DOMAIN")","certificate_path":"$CERT","key_path":"$KEY"}}
EOF
  fi
  if [ "$HY2" = 1 ]; then
    add <<EOF
    {"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":$HY2_PORT,"users":[{"password":"$(escape "$HY2_PASSWORD")"}],"tls":{"enabled":true,"server_name":"$(escape "$DOMAIN")","certificate_path":"$CERT","key_path":"$KEY"}}
EOF
  fi
  if [ "$VLESS_WS" = 1 ]; then
    add <<EOF
    {"type":"vless","tag":"vless-ws-in","listen":"::","listen_port":$VLESS_WS_PORT,"users":[{"uuid":"$VLESS_WS_UUID"}],"transport":{"type":"ws","path":"$(escape "$VLESS_WS_PATH")","early_data_header_name":"Sec-WebSocket-Protocol"}}
EOF
  fi
  if [ "$REALITY" = 1 ]; then
    add <<EOF
    {"type":"vless","tag":"vless-reality-in","listen":"::","listen_port":$REALITY_PORT,"users":[{"uuid":"$REALITY_UUID","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"$(escape "$REALITY_SNI")","reality":{"enabled":true,"handshake":{"server":"$(escape "$REALITY_SNI")","server_port":443},"private_key":"$(cat "$REALITY_DIR/private.key")","short_id":["$REALITY_SHORT_ID"]}}}
EOF
  fi
  [ "$written" = 1 ] || { rm -f "$TMP"; red '没有启用节点'; return 1; }
  cat >> "$TMP" <<EOF
  ],
  "outbounds":[{"type":"direct","tag":"direct"}],
  "route":{"final":"direct"}
}
EOF
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
service_restart(){
  if [ ! -f "$CFG" ]; then yellow '配置不存在'; return 1; fi
  if [ "$INIT" = openrc ]; then
    rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start
  else
    systemctl restart sing-box
  fi
  green 'sing-box 已重启'
}

show_one_link(){
  load
  host=${SERVER:-YOUR_SERVER_IP}
  printf '\n节点链接:\n'
  case "$1" in
    anytls) [ "$ANYTLS" = 1 ] && printf 'anytls://%s@%s:%s/?sni=%s#%s-anytls\n' "$ANYTLS_PASSWORD" "$host" "$ANYTLS_PORT" "$DOMAIN" "$NODE" ;;
    tuic) [ "$TUIC" = 1 ] && printf 'tuic://%s:%s@%s:%s?sni=%s&congestion_control=bbr#%s-tuic\n' "$TUIC_UUID" "$TUIC_PASSWORD" "$host" "$TUIC_PORT" "$DOMAIN" "$NODE" ;;
    hy2) [ "$HY2" = 1 ] && printf 'hysteria2://%s@%s:%s/?sni=%s#%s-hy2\n' "$HY2_PASSWORD" "$host" "$HY2_PORT" "$DOMAIN" "$NODE" ;;
    vless_ws) [ "$VLESS_WS" = 1 ] && printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&path=%s&host=%s#%s-vless-ws\n' "$VLESS_WS_UUID" "$host" "$VLESS_WS_PORT" "$(printf '%s' "$VLESS_WS_PATH" | sed 's#/#%2F#g')" "${DOMAIN:-$host}" "$NODE" ;;
    reality) [ "$REALITY" = 1 ] && [ -s "$REALITY_DIR/public.key" ] && printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s-reality\n' "$REALITY_UUID" "$host" "$REALITY_PORT" "$REALITY_SNI" "$(cat "$REALITY_DIR/public.key")" "$REALITY_SHORT_ID" "$NODE" ;;
  esac
}
links(){
  load
  host=${SERVER:-YOUR_SERVER_IP}
  printf '\n已启用节点链接:\n'
  [ "$ANYTLS" = 1 ] && printf 'anytls://%s@%s:%s/?sni=%s#%s-anytls\n' "$ANYTLS_PASSWORD" "$host" "$ANYTLS_PORT" "$DOMAIN" "$NODE"
  [ "$TUIC" = 1 ] && printf 'tuic://%s:%s@%s:%s?sni=%s&congestion_control=bbr#%s-tuic\n' "$TUIC_UUID" "$TUIC_PASSWORD" "$host" "$TUIC_PORT" "$DOMAIN" "$NODE"
  [ "$HY2" = 1 ] && printf 'hysteria2://%s@%s:%s/?sni=%s#%s-hy2\n' "$HY2_PASSWORD" "$host" "$HY2_PORT" "$DOMAIN" "$NODE"
  [ "$VLESS_WS" = 1 ] && printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&path=%s&host=%s#%s-vless-ws\n' "$VLESS_WS_UUID" "$host" "$VLESS_WS_PORT" "$(printf '%s' "$VLESS_WS_PATH" | sed 's#/#%2F#g')" "${DOMAIN:-$host}" "$NODE"
  [ "$REALITY" = 1 ] && [ -s "$REALITY_DIR/public.key" ] && printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s-reality\n' "$REALITY_UUID" "$host" "$REALITY_PORT" "$REALITY_SNI" "$(cat "$REALITY_DIR/public.key")" "$REALITY_SHORT_ID" "$NODE"
  if [ "$ANYTLS$TUIC$HY2$VLESS_WS$REALITY" = "00000" ]; then yellow '当前没有启用任何节点'; fi
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
    printf '6) 配置 VLESS+Reality\n'
    printf '7) 关闭指定节点\n'
    printf '8) 查看节点链接\n'
    printf '9) 应用现有参数并重启\n'
    printf '0) 返回\n'
    printf '选择: '
    IFS= read -r c || return
    case "$c" in
      1) set_common ;;
      2) cfg_anytls ;;
      3) cfg_tuic ;;
      4) cfg_hy2 ;;
      5) cfg_vless_ws ;;
      6) cfg_reality ;;
      7) disable_node ;;
      8) links ;;
      9) load; apply_config; links ;;
      0) return ;;
      *) yellow '无效选项' ;;
    esac
  done
}

cert_menu(){
  while :; do
    line
    printf '证书管理\n1) 查看证书\n2) 自签证书\n3) 申请Cloudflare ACME证书\n4) 续期ACME证书\n5) 删除证书\n0) 返回\n选择: '
    IFS= read -r c || return
    case "$c" in
      1) cert_info ;;
      2) cert_self; save ;;
      3) cert_acme ;;
      4) [ -x "$ACME" ] && "$ACME" --cron --home /root/.acme.sh || yellow '尚未安装acme.sh' ;;
      5) cert_delete ;;
      0) return ;;
    esac
  done
}

menu(){
  while :; do
    line
    printf 'sing-box %s 一体化管理器\n' "$VERSION"
    printf '1) 安装/更新依赖和sing-box\n'
    printf '2) 节点管理（单独配置）\n'
    printf '3) 证书管理\n'
    printf '4) 查看节点链接\n'
    printf '5) 重启服务\n'
    printf '6) 查看日志\n'
    printf '0) 退出\n'
    printf '选择: '
    IFS= read -r c || exit
    case "$c" in
      1) packages; install_binary; ln -sf "$SCRIPT" "$PREFIX/singbox"; ln -sf "$SCRIPT" "$PREFIX/sb" ;;
      2) node_menu ;;
      3) cert_menu ;;
      4) links ;;
      5) load; service_restart ;;
      6) tail -n 100 "$LOG" 2>/dev/null || true ;;
      0) exit 0 ;;
      *) yellow '无效选项' ;;
    esac
  done
}

main(){
  root_check
  os_detect
  load
  case "${1:-}" in
    install) packages; install_binary; service_create ;;
    nodes|node) node_menu ;;
    anytls) cfg_anytls ;;
    tuic) cfg_tuic ;;
    hy2) cfg_hy2 ;;
    vless-ws|vless_ws) cfg_vless_ws ;;
    reality) cfg_reality ;;
    cert) cert_menu ;;
    links) links ;;
    restart) service_restart ;;
    logs) tail -n 100 "$LOG" 2>/dev/null || true ;;
    status) status_nodes ;;
    *) menu ;;
  esac
}
main "$@"