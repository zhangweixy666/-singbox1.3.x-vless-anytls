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
  case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; armv7l) ARCH=armv7;; *) red "不支持架构: $(uname -m)"; exit 1;; esac
}
packages(){
  if [ "$PM" = apk ]; then apk update; apk add --no-cache curl ca-certificates tar gzip openssl socat iproute2 procps coreutils; update-ca-certificates >/dev/null 2>&1 || true
  else apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar gzip openssl socat iproute2 procps
  fi
}
install_binary(){
  install -m 755 "$0" "$SCRIPT" 2>/dev/null || true
  arch_detect
  if [ "$MUSL" = 1 ]; then suffix="-musl"; else suffix=; fi
  url="https://github.com/SagerNet/sing-box/releases/download/v$VERSION/sing-box-$VERSION-linux-$ARCH$suffix.tar.gz"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT INT TERM
  curl -fL "$url" -o "$tmp/sb.tgz"; tar -xzf "$tmp/sb.tgz" -C "$tmp"
  file=$(find "$tmp" -type f -name sing-box | head -n1); [ -n "$file" ] || { red '未找到 sing-box 二进制'; exit 1; }
  install -m 755 "$file" "$BIN"; ln -sf "$SCRIPT" "$PREFIX/singbox"; ln -sf "$SCRIPT" "$PREFIX/sb"
  trap - EXIT INT TERM; rm -rf "$tmp"; "$BIN" version
}
ensure_binary(){ [ -x "$BIN" ] || install_binary; }

uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16; }
password(){ openssl rand -base64 24 | tr -d '\n'; }
shortid(){ openssl rand -hex 8; }
escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
path_norm(){ case "$1" in /*) printf '%s' "$1";; *) printf '/%s' "$1";; esac; }
port_check(){ case "$1" in ''|*[!0-9]*) red "端口无效: $1"; return 1;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { red "端口范围无效: $1"; return 1; }; }

defaults(){
  ANYTLS=1; ANYTLS_PORT=8443; ANYTLS_NAME=user; ANYTLS_PASSWORD=""
  TUIC=1; TUIC_PORT=8444; TUIC_UUID=""; TUIC_PASSWORD=""
  HY2=1; HY2_PORT=8445; HY2_PASSWORD=""
  VLESS_WS=1; VLESS_WS_PORT=8080; VLESS_WS_UUID=""; VLESS_WS_PATH=/ws
  REALITY=1; REALITY_PORT=8446; REALITY_UUID=""; REALITY_SNI=www.microsoft.com; REALITY_SHORT_ID=""
  SERVER=""; DOMAIN=""; NODE=sing-box-node; CERT_MODE=none
}
load(){
  defaults; [ -f "$PARAMS" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do case "$l" in ''|'#'*) continue;; esac; k=${l%%=*}; v=${l#*=}; case "$k" in ANYTLS|ANYTLS_PORT|ANYTLS_NAME|ANYTLS_PASSWORD|TUIC|TUIC_PORT|TUIC_UUID|TUIC_PASSWORD|HY2|HY2_PORT|HY2_PASSWORD|VLESS_WS|VLESS_WS_PORT|VLESS_WS_UUID|VLESS_WS_PATH|REALITY|REALITY_PORT|REALITY_UUID|REALITY_SNI|REALITY_SHORT_ID|SERVER|DOMAIN|NODE|CERT_MODE) eval "$k=\"$v\"";; esac; done < "$PARAMS"
}
save(){ umask 077; mkdir -p "$CFG_DIR"; cat > "$PARAMS" <<EOF
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
chmod 600 "$PARAMS"; }

cert_self(){
  mkdir -p "$CERT_DIR"; openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$KEY" -out "$CERT" -subj "/CN=${DOMAIN:-sing-box}" >/dev/null 2>&1; chmod 600 "$KEY"; chmod 644 "$CERT"; CERT_MODE=self; green "自签证书已生成: $CERT"
}
cert_acme(){
  [ -x "$ACME" ] || { curl https://get.acme.sh | sh; }
  "$ACME" --set-default-ca --server letsencrypt
  printf '证书域名: '; IFS= read -r DOMAIN; [ -n "$DOMAIN" ] || { red '域名不能为空'; return 1; }
  printf '申请方式 1=standalone 2=DNS插件 [默认1]: '; IFS= read -r mode || mode=1; mode=${mode:-1}
  mkdir -p "$CERT_DIR"
  if [ "$mode" = 1 ]; then "$ACME" --issue --standalone -d "$DOMAIN"; else printf 'DNS插件名（例如 dns_你的DNS服务商）: '; IFS= read -r plugin; [ -n "$plugin" ]; "$ACME" --issue --dns "$plugin" -d "$DOMAIN"; fi
  "$ACME" --install-cert -d "$DOMAIN" --key-file "$KEY" --fullchain-file "$CERT" --reloadcmd "$SCRIPT restart >/dev/null 2>&1 || true"
  chmod 600 "$KEY"; chmod 644 "$CERT"; CERT_MODE=acme; save; cron_enable; green "证书已部署: $CERT"
}
cron_enable(){ if [ "$INIT" = openrc ]; then rc-service crond start >/dev/null 2>&1 || true; rc-update add crond default >/dev/null 2>&1 || true; fi; }
cert_exists(){ [ -s "$CERT" ] && [ -s "$KEY" ]; }
cert_info(){
  line; if cert_exists; then openssl x509 -in "$CERT" -noout -subject -issuer -serial -dates 2>/dev/null || true; printf '证书: %s\n私钥: %s\n模式: %s\n' "$CERT" "$KEY" "$CERT_MODE"; else yellow '当前没有证书'; fi
}
cert_delete(){
  cert_info; printf '确认删除证书和私钥? [y/N]: '; IFS= read -r a; case "$a" in y|Y) rm -f "$CERT" "$KEY"; CERT_MODE=none; save; green '证书已删除';; *) yellow '已取消';; esac
}

reality_keys(){
  [ "$REALITY" = 1 ] || return 0; ensure_binary; mkdir -p "$REALITY_DIR"
  if [ ! -s "$REALITY_DIR/private.key" ] || [ ! -s "$REALITY_DIR/public.key" ]; then
    out=$("$BIN" generate reality-keypair); printf '%s\n' "$out" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n1 > "$REALITY_DIR/private.key"; printf '%s\n' "$out" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n1 > "$REALITY_DIR/public.key"; chmod 600 "$REALITY_DIR"/*
  fi
  [ -n "$REALITY_SHORT_ID" ] || REALITY_SHORT_ID=$(shortid)
}

ask(){ printf '%s' "$1"; IFS= read -r a || a=; [ -n "$a" ] && printf '%s' "$a" || printf '%s' "$2"; }
configure(){
  load; ensure_binary; SERVER=$(ask '服务器IP/域名: ' "$(hostname -i | awk '{print $1}')"); NODE=$(ask "节点名称 [$NODE]: " "$NODE"); DOMAIN=$(ask '证书域名/SNI（VLESS WS可留空）: ' "$DOMAIN")
  ANYTLS=$(ask '启用 AnyTLS [Y/n]: ' y); case "$ANYTLS" in y|Y) ANYTLS=1;; *) ANYTLS=0;; esac
  TUIC=$(ask '启用 TUIC [Y/n]: ' y); case "$TUIC" in y|Y) TUIC=1;; *) TUIC=0;; esac
  HY2=$(ask '启用 Hysteria2 [Y/n]: ' y); case "$HY2" in y|Y) HY2=1;; *) HY2=0;; esac
  VLESS_WS=$(ask '启用 VLESS+WS（无TLS）[Y/n]: ' y); case "$VLESS_WS" in y|Y) VLESS_WS=1;; *) VLESS_WS=0;; esac
  REALITY=$(ask '启用 VLESS+Reality [Y/n]: ' y); case "$REALITY" in y|Y) REALITY=1;; *) REALITY=0;; esac
  if [ "$ANYTLS" = 1 ]; then ANYTLS_PORT=$(ask "AnyTLS端口 [$ANYTLS_PORT]: " "$ANYTLS_PORT"); ANYTLS_PASSWORD=$(ask 'AnyTLS密码（留空自动生成）: ' "${ANYTLS_PASSWORD:-$(password)}"); fi
  if [ "$TUIC" = 1 ]; then TUIC_PORT=$(ask "TUIC端口 [$TUIC_PORT]: " "$TUIC_PORT"); TUIC_UUID=$(ask 'TUIC UUID（留空自动生成）: ' "${TUIC_UUID:-$(uuid)}"); TUIC_PASSWORD=$(ask 'TUIC密码（留空自动生成）: ' "${TUIC_PASSWORD:-$(password)}"); fi
  if [ "$HY2" = 1 ]; then HY2_PORT=$(ask "HY2端口 [$HY2_PORT]: " "$HY2_PORT"); HY2_PASSWORD=$(ask 'HY2密码（留空自动生成）: ' "${HY2_PASSWORD:-$(password)}"); fi
  if [ "$VLESS_WS" = 1 ]; then VLESS_WS_PORT=$(ask "VLESS WS端口 [$VLESS_WS_PORT]: " "$VLESS_WS_PORT"); VLESS_WS_UUID=$(ask 'VLESS WS UUID（留空自动生成）: ' "${VLESS_WS_UUID:-$(uuid)}"); VLESS_WS_PATH=$(path_norm "$(ask "WS路径 [$VLESS_WS_PATH]: " "$VLESS_WS_PATH")"); fi
  if [ "$REALITY" = 1 ]; then REALITY_PORT=$(ask "Reality端口 [$REALITY_PORT]: " "$REALITY_PORT"); REALITY_UUID=$(ask 'Reality UUID（留空自动生成）: ' "${REALITY_UUID:-$(uuid)}"); REALITY_SNI=$(ask "Reality SNI [$REALITY_SNI]: " "$REALITY_SNI"); reality_keys; fi
  for p in "$ANYTLS_PORT" "$TUIC_PORT" "$HY2_PORT" "$VLESS_WS_PORT" "$REALITY_PORT"; do port_check "$p"; done
  if [ "$ANYTLS" = 1 ] || [ "$TUIC" = 1 ] || [ "$HY2" = 1 ]; then cert_exists || { yellow 'HY2/TUIC/AnyTLS需要证书'; cert_menu; cert_exists || { red '未配置证书，取消生成'; return 1; }; }; fi
  generate_config; service_create; service_restart; save; links
}

add(){ [ "$written" = 0 ] || printf ',\n' >> "$TMP"; cat >> "$TMP"; written=1; }
generate_config(){
  TMP="$CFG.tmp.$$"; mkdir -p "$CFG_DIR" "$LOG_DIR"; written=0
  cat > "$TMP" <<EOF
{
  "log": {"disabled": false, "level": "info", "timestamp": true, "output": "$LOG"},
  "inbounds": [
EOF
  if [ "$ANYTLS" = 1 ]; then add <<EOF
    {"type":"anytls","tag":"anytls-in","listen":"::","listen_port":$ANYTLS_PORT,"users":[{"name":"$(escape "$ANYTLS_NAME")","password":"$(escape "$ANYTLS_PASSWORD")"}],"padding_scheme":[],"tls":{"enabled":true,"server_name":"$(escape "$DOMAIN")","certificate_path":"$CERT","key_path":"$KEY"}}
EOF
  fi
  if [ "$TUIC" = 1 ]; then add <<EOF
    {"type":"tuic","tag":"tuic-in","listen":"::","listen_port":$TUIC_PORT,"users":[{"uuid":"$TUIC_UUID","password":"$(escape "$TUIC_PASSWORD")"}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":"$(escape "$DOMAIN")","certificate_path":"$CERT","key_path":"$KEY"}}
EOF
  fi
  if [ "$HY2" = 1 ]; then add <<EOF
    {"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":$HY2_PORT,"users":[{"password":"$(escape "$HY2_PASSWORD")"}],"tls":{"enabled":true,"server_name":"$(escape "$DOMAIN")","certificate_path":"$CERT","key_path":"$KEY"}}
EOF
  fi
  if [ "$VLESS_WS" = 1 ]; then add <<EOF
    {"type":"vless","tag":"vless-ws-in","listen":"::","listen_port":$VLESS_WS_PORT,"users":[{"uuid":"$VLESS_WS_UUID"}],"transport":{"type":"ws","path":"$(escape "$VLESS_WS_PATH")","early_data_header_name":"Sec-WebSocket-Protocol"}}
EOF
  fi
  if [ "$REALITY" = 1 ]; then add <<EOF
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
  "$BIN" check -c "$TMP"; mv "$TMP" "$CFG"; chmod 600 "$CFG"; green '配置校验通过并已重建'
}

service_create(){
  if [ "$INIT" = openrc ]; then cat > "$SERVICE_FILE" <<EOF
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
    chmod 755 "$SERVICE_FILE"; rc-update add sing-box default >/dev/null 2>&1 || true
  else cat > /etc/systemd/system/sing-box.service <<EOF
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
    systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1 || true; fi
}
service_restart(){ if [ "$INIT" = openrc ]; then rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start; else systemctl restart sing-box; fi; green 'sing-box 已重启'; }
service_stop(){ if [ "$INIT" = openrc ]; then rc-service sing-box stop >/dev/null 2>&1 || true; else systemctl stop sing-box >/dev/null 2>&1 || true; fi; }

links(){
  load; host=$SERVER; printf '\n节点链接:\n'
  [ "$ANYTLS" = 1 ] && printf 'AnyTLS password=%s\nanytls://%s@%s:%s/?sni=%s#%s-anytls\n' "$ANYTLS_PASSWORD" "$ANYTLS_PASSWORD" "$host" "$ANYTLS_PORT" "$DOMAIN" "$NODE"
  [ "$TUIC" = 1 ] && printf 'tuic://%s:%s@%s:%s?sni=%s&congestion_control=bbr#%s-tuic\n' "$TUIC_UUID" "$TUIC_PASSWORD" "$host" "$TUIC_PORT" "$DOMAIN" "$NODE"
  [ "$HY2" = 1 ] && printf 'hysteria2://%s@%s:%s/?sni=%s#%s-hy2\n' "$HY2_PASSWORD" "$host" "$HY2_PORT" "$DOMAIN" "$NODE"
  [ "$VLESS_WS" = 1 ] && printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&path=%s#%s-vless-ws\n' "$VLESS_WS_UUID" "$host" "$VLESS_WS_PORT" "$VLESS_WS_PATH" "$NODE"
  [ "$REALITY" = 1 ] && [ -s "$REALITY_DIR/public.key" ] && printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s-reality\n' "$REALITY_UUID" "$host" "$REALITY_PORT" "$REALITY_SNI" "$(cat "$REALITY_DIR/public.key")" "$REALITY_SHORT_ID" "$NODE"
}

cert_menu(){
  while :; do line; printf '证书管理\n1) 查看证书\n2) 自签证书\n3) 申请ACME证书\n4) 续期ACME证书\n5) 删除证书\n0) 返回\n选择: '; IFS= read -r c || return; case "$c" in 1) cert_info;; 2) cert_self; save;; 3) cert_acme;; 4) [ -x "$ACME" ] && "$ACME" --cron --home /root/.acme.sh || yellow '尚未安装acme.sh';; 5) cert_delete;; 0) return;; esac; done
}
menu(){ while :; do line; printf 'sing-box $VERSION 一体化管理器\n1) 安装/更新依赖和sing-box\n2) 重建节点配置\n3) 证书管理\n4) 查看节点链接\n5) 重启服务\n6) 查看日志\n0) 退出\n选择: '; IFS= read -r c || exit; case "$c" in 1) packages; install_binary; ln -sf "$SCRIPT" "$PREFIX/singbox"; ln -sf "$SCRIPT" "$PREFIX/sb";; 2) configure;; 3) cert_menu;; 4) links;; 5) load; service_restart;; 6) tail -n 100 "$LOG" 2>/dev/null || true;; 0) exit 0;; esac; done; }
main(){ root_check; os_detect; load; case "${1:-}" in install) packages; install_binary; service_create;; configure|rebuild) configure;; cert) cert_menu;; links) links;; restart) service_restart;; logs) tail -n 100 "$LOG" 2>/dev/null || true;; *) menu;; esac; }
main "$@"