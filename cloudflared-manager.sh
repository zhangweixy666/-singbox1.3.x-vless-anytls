#!/bin/sh
# Cloudflare Tunnel manager for Alpine/OpenRC and Debian/systemd.
# State and token files are parsed as data; no eval/source of user-controlled files.
set -eu
umask 077

VERSION=1.1.0
CLOUDFLARED_VERSION=2026.8.2
CF_DIR=/root/.cloudflared
CF_CONFIG=$CF_DIR/config.yml
CF_ENV=/etc/cloudflared-manager.env
CF_API_ENV=/etc/cloudflared-manager.api
CF_LOG_DIR=/var/log/cloudflared
CF_LOG=$CF_LOG_DIR/tunnel.log
CF_BIN=/usr/local/bin/cloudflared
CF_SUPERVISOR=/usr/local/sbin/cloudflared-supervisor.sh
CF_PIDFILE=/run/cloudflared-supervisor.pid
CF_OPENRC=/etc/init.d/cloudflared
CF_SYSTEMD=/etc/systemd/system/cloudflared.service
SINGBOX_CONFIG=/etc/sing-box/config.json
SINGBOX_BIN=/usr/local/bin/sing-box

green(){ printf '\033[32m[成功]\033[0m %s\n' "$*"; }
cyan(){ printf '\033[36m[信息]\033[0m %s\n' "$*"; }
yellow(){ printf '\033[33m[警告]\033[0m %s\n' "$*"; }
red(){ printf '\033[31m[错误]\033[0m %s\n' "$*"; }

root_check(){ [ "$(id -u)" = 0 ] || { red '请使用 root 运行'; exit 1; }; }

detect_os(){
  if [ -f /etc/alpine-release ]; then
    OS=alpine; PM=apk; INIT=openrc
  elif [ -f /etc/debian_version ]; then
    OS=debian; PM=apt-get; INIT=systemd
  else
    OS=unknown; PM=; INIT=manual
  fi
}

set_cf_value(){
  case "$1" in
    CF_TUNNEL_ID) CF_TUNNEL_ID=$2;;
    CF_TUNNEL_NAME) CF_TUNNEL_NAME=$2;;
    CF_CREDENTIALS) CF_CREDENTIALS=$2;;
    CF_ZONE) CF_ZONE=$2;;
    CF_HOSTNAME) CF_HOSTNAME=$2;;
    CF_SERVICE_PORT) CF_SERVICE_PORT=$2;;
    CF_SERVICE_PATH) CF_SERVICE_PATH=$2;;
    CF_PROTOCOL) CF_PROTOCOL=$2;;
    CF_ENABLED) CF_ENABLED=$2;;
  esac
}

defaults(){
  CF_TUNNEL_ID=
  CF_TUNNEL_NAME=
  CF_CREDENTIALS=
  CF_ZONE=
  CF_HOSTNAME=
  CF_SERVICE_PORT=20008
  CF_SERVICE_PATH=/ws
  CF_PROTOCOL=auto
  CF_ENABLED=0
}

load_env(){
  defaults
  [ -r "$CF_ENV" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      ''|\#*) continue;;
      CF_TUNNEL_ID|CF_TUNNEL_NAME|CF_CREDENTIALS|CF_ZONE|CF_HOSTNAME|CF_SERVICE_PORT|CF_SERVICE_PATH|CF_PROTOCOL|CF_ENABLED)
        set_cf_value "$key" "$value";;
    esac
  done < "$CF_ENV"
}

save_env(){
  mkdir -p "$(dirname "$CF_ENV")"
  cat > "$CF_ENV" <<EOF
CF_TUNNEL_ID=$CF_TUNNEL_ID
CF_TUNNEL_NAME=$CF_TUNNEL_NAME
CF_CREDENTIALS=$CF_CREDENTIALS
CF_ZONE=$CF_ZONE
CF_HOSTNAME=$CF_HOSTNAME
CF_SERVICE_PORT=$CF_SERVICE_PORT
CF_SERVICE_PATH=$CF_SERVICE_PATH
CF_PROTOCOL=$CF_PROTOCOL
CF_ENABLED=$CF_ENABLED
EOF
  chmod 600 "$CF_ENV"
}

read_secret(){
  prompt=$1
  printf '%s' "$prompt" >&2
  old_stty=$(stty -g 2>/dev/null || true)
  stty -echo 2>/dev/null || true
  IFS= read -r secret || secret=
  [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null || true
  printf '\n' >&2
  printf '%s' "$secret"
}

ask(){
  var=$1
  prompt=$2
  default=${3:-}
  printf '%s' "$prompt"
  IFS= read -r answer || answer=
  [ -n "$answer" ] || answer=$default
  set_cf_value "$var" "$answer"
}

valid_id(){
  case "$1" in
    ????????-????-????-????-????????????) return 0;;
    *) return 1;;
  esac
}

valid_port(){
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

valid_host(){
  case "$1" in ''|*[!A-Za-z0-9.-]*) return 1;; esac
  return 0
}

valid_path(){
  case "$1" in
    /[A-Za-z0-9._~/-]*) return 0;;
    *) return 1;;
  esac
}

require_bin(){
  if [ -x "$CF_BIN" ]; then return 0; fi
  found=$(command -v cloudflared 2>/dev/null || true)
  [ -n "$found" ] && CF_BIN=$found
  [ -x "$CF_BIN" ] || {
    red "找不到 cloudflared，请先安装: $0 install"
    return 1
  }
}

install_cloudflared(){
  if [ "$PM" = apk ]; then
    apk add --no-cache curl ca-certificates python3 procps iproute2 bind-tools >/dev/null
  elif [ "$PM" = apt-get ]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates python3 procps iproute2 dnsutils >/dev/null
  fi

  case "$(uname -m)" in
    x86_64) asset=amd64;;
    aarch64|arm64) asset=arm64;;
    armv7l) asset=arm;;
    *) red "不支持架构: $(uname -m)"; return 1;;
  esac

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$asset" \
    -o "$tmp/cloudflared"
  chmod 755 "$tmp/cloudflared"
  installed_version=$("$tmp/cloudflared" version | awk 'NR == 1 { print $3; exit }')
  [ "$installed_version" = "$CLOUDFLARED_VERSION" ] || {
    red "cloudflared 版本校验失败: 期望 $CLOUDFLARED_VERSION，实际 ${installed_version:-未知}"
    return 1
  }
  install -m 755 "$tmp/cloudflared" "$CF_BIN"
  trap - EXIT INT TERM
  rm -rf "$tmp"
  "$CF_BIN" version
  green "cloudflared 已安装: $CF_BIN"
}

load_api(){
  CF_API_TOKEN=
  [ -r "$CF_API_ENV" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [ "$key" = CF_API_TOKEN ] && CF_API_TOKEN=$value
  done < "$CF_API_ENV"
}

ask_api(){
  load_api
  if [ -z "${CF_API_TOKEN:-}" ]; then
    CF_API_TOKEN=$(read_secret '请输入 Cloudflare API Token（不可回显）: ')
    [ -n "$CF_API_TOKEN" ] || return 1
    mkdir -p "$(dirname "$CF_API_ENV")"
    printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" > "$CF_API_ENV"
    chmod 600 "$CF_API_ENV"
  fi
  export CF_API_TOKEN
}

list_tunnels(){
  require_bin || return 1
  "$CF_BIN" tunnel list
}

create_tunnel(){
  require_bin || return 1
  load_env
  ask CF_TUNNEL_NAME 'Tunnel 名称 [singbox-tunnel]: ' "${CF_TUNNEL_NAME:-singbox-tunnel}"
  case "$CF_TUNNEL_NAME" in ''|*[!A-Za-z0-9._-]*) red '名称格式无效'; return 1;; esac
  output=$("$CF_BIN" tunnel create "$CF_TUNNEL_NAME" 2>&1) || {
    printf '%s\n' "$output"; return 1;
  }
  printf '%s\n' "$output"
  CF_TUNNEL_ID=$(printf '%s\n' "$output" | sed -n 's/.*id[[:space:]]\+\([0-9a-f-]\{36\}\).*/\1/p' | head -n 1)
  valid_id "$CF_TUNNEL_ID" || {
    printf '请手动输入 Tunnel ID: '
    IFS= read -r CF_TUNNEL_ID || CF_TUNNEL_ID=
  }
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 格式无效'; return 1; }
  CF_CREDENTIALS=$CF_DIR/$CF_TUNNEL_ID.json
  save_env
  green "Tunnel 已创建: $CF_TUNNEL_ID"
}

select_tunnel(){
  require_bin || return 1
  load_env
  list_tunnels || return 1
  ask CF_TUNNEL_ID "Tunnel ID [${CF_TUNNEL_ID:-}]: " "$CF_TUNNEL_ID"
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 格式无效'; return 1; }
  CF_CREDENTIALS=$CF_DIR/$CF_TUNNEL_ID.json
  [ -f "$CF_CREDENTIALS" ] || yellow "本地凭据不存在: $CF_CREDENTIALS"
  save_env
}

configure_ingress(){
  require_bin || return 1
  load_env
  valid_id "$CF_TUNNEL_ID" || { red '请先创建或选择 Tunnel'; return 1; }

  ask CF_ZONE 'Cloudflare Zone: ' "$CF_ZONE"
  valid_host "$CF_ZONE" || { red 'Zone 格式无效'; return 1; }

  ask CF_HOSTNAME "公网域名 [cf-test.$CF_ZONE]: " "${CF_HOSTNAME:-cf-test.$CF_ZONE}"
  valid_host "$CF_HOSTNAME" || { red '域名格式无效'; return 1; }
  case "$CF_HOSTNAME" in *."$CF_ZONE") ;; *) red '域名不属于当前 Zone'; return 1;; esac

  ask CF_SERVICE_PORT "本地回源端口 [$CF_SERVICE_PORT]: " "$CF_SERVICE_PORT"
  valid_port "$CF_SERVICE_PORT" || { red '端口无效'; return 1; }

  ask CF_SERVICE_PATH "WS 路径 [$CF_SERVICE_PATH]: " "$CF_SERVICE_PATH"
  valid_path "$CF_SERVICE_PATH" || { red 'WS 路径无效'; return 1; }

  ask CF_PROTOCOL 'Tunnel 协议 auto/quic/http2 [auto]: ' "$CF_PROTOCOL"
  case "$CF_PROTOCOL" in auto|quic|http2) ;; *) red '协议无效'; return 1;; esac

  mkdir -p "$CF_DIR"
  tmp="$CF_CONFIG.tmp.$$"
  cat > "$tmp" <<EOF
tunnel: $CF_TUNNEL_ID
credentials-file: $CF_CREDENTIALS
protocol: $CF_PROTOCOL
ingress:
  - hostname: $CF_HOSTNAME
    service: http://127.0.0.1:$CF_SERVICE_PORT
  - service: http_status:404
EOF
  mv "$tmp" "$CF_CONFIG"
  chmod 600 "$CF_CONFIG"

  "$CF_BIN" --config "$CF_CONFIG" tunnel ingress validate
  CF_ENABLED=1
  save_env
  green "Ingress 配置有效: $CF_CONFIG"
}

validate_ingress(){
  require_bin || return 1
  load_env
  [ -f "$CF_CONFIG" ] || { red "配置不存在: $CF_CONFIG"; return 1; }
  "$CF_BIN" --config "$CF_CONFIG" tunnel ingress validate
}

load_dns_zone_id(){
  ask_api || return 1
  curl --fail --silent --show-error \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H 'Content-Type: application/json' \
    "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE&status=active" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("result") else "")'
}

route_add(){
  require_bin || return 1
  load_env
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 无效，请先创建或选择 Tunnel'; return 1; }
  [ -n "$CF_ZONE" ] || { red '未配置 Zone，请先运行 configure 配置域名'; return 1; }
  [ -n "$CF_HOSTNAME" ] || { red '未配置域名，请先运行 configure 配置域名'; return 1; }
  case "$CF_HOSTNAME" in *."$CF_ZONE") ;; *) red '域名不属于当前 Zone'; return 1;; esac
  "$CF_BIN" tunnel route dns --overwrite-dns "$CF_TUNNEL_ID" "$CF_HOSTNAME"
  green "DNS 路由已添加: $CF_HOSTNAME"
}

route_delete(){
  load_env
  [ -n "$CF_ZONE" ] && [ -n "$CF_HOSTNAME" ] || {
    red '请先配置 Zone 和域名'; return 1;
  }
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 无效'; return 1; }
  zone_id=$(load_dns_zone_id) || return 1
  [ -n "$zone_id" ] || { red '找不到 Zone ID'; return 1; }

  target=$(printf '%s.cfargotunnel.com' "$CF_TUNNEL_ID")
  records=$(
    curl --fail --silent --show-error \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=CNAME&name=$CF_HOSTNAME" |
    TARGET="$target" python3 -c '
import json, os, sys
target = os.environ["TARGET"].rstrip(".").lower()
for record in json.load(sys.stdin).get("result", []):
    content = str(record.get("content", "")).rstrip(".").lower()
    if content == target:
        print(record["id"])
'
  )

  [ -n "$records" ] || { yellow '没有找到指向当前 Tunnel 的 CNAME，未删除任何记录'; return 0; }
  for record_id in $records; do
    curl --fail --silent --show-error -X DELETE \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" >/dev/null
  done
  green "已删除当前 Tunnel 的 DNS 记录: $CF_HOSTNAME"
}

service_mode(){
  if command -v rc-service >/dev/null 2>&1; then printf '%s\n' openrc
  elif command -v systemctl >/dev/null 2>&1; then printf '%s\n' systemd
  else printf '%s\n' manual
  fi
}

write_supervisor(){
  mkdir -p "$CF_LOG_DIR" "$(dirname "$CF_SUPERVISOR")"
  cat > "$CF_SUPERVISOR" <<'EOF_SUPERVISOR'
#!/bin/sh
set -eu
bin=$1
config=$2
tunnel=$3
log=$4
pidfile=$5
protocol=$6
mkdir -p "$(dirname "$log")" "$(dirname "$pidfile")"
echo "$$" > "$pidfile"
child=
cleanup(){
  [ -z "$child" ] || kill "$child" 2>/dev/null || true
  rm -f "$pidfile"
  exit 0
}
trap cleanup INT TERM HUP
while :; do
  printf '%s starting tunnel %s\n' "$(date '+%F %T')" "$tunnel" >> "$log"
  if [ "$protocol" = auto ]; then
    "$bin" --config "$config" tunnel run "$tunnel" >> "$log" 2>&1 &
  else
    "$bin" --config "$config" --protocol "$protocol" tunnel run "$tunnel" >> "$log" 2>&1 &
  fi
  child=$!
  wait "$child" || true
  child=
  sleep 3
done
EOF_SUPERVISOR
  chmod 755 "$CF_SUPERVISOR"
}

write_openrc(){
  cat > "$CF_OPENRC" <<EOF
#!/sbin/openrc-run
name="cloudflared"
description="Cloudflare Tunnel"
command="$CF_SUPERVISOR"
command_args="$CF_BIN $CF_CONFIG $CF_TUNNEL_ID $CF_LOG $CF_PIDFILE $CF_PROTOCOL"
command_background="yes"
pidfile="$CF_PIDFILE"
output_log="$CF_LOG"
error_log="$CF_LOG"
depend() { need net; after firewall; }
EOF
  chmod 755 "$CF_OPENRC"
  rc-update add cloudflared default >/dev/null 2>&1 || true
}

write_systemd(){
  mkdir -p "$(dirname "$CF_SYSTEMD")"
  cat > "$CF_SYSTEMD" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$CF_SUPERVISOR $CF_BIN $CF_CONFIG $CF_TUNNEL_ID $CF_LOG $CF_PIDFILE $CF_PROTOCOL
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable cloudflared >/dev/null 2>&1 || true
}

start_tunnel(){
  require_bin || return 1
  load_env
  [ "$CF_ENABLED" = 1 ] || { red '请先完成 Ingress 配置'; return 1; }
  [ -f "$CF_CONFIG" ] || { red 'Tunnel 配置不存在'; return 1; }
  [ -f "$CF_CREDENTIALS" ] || { red "Tunnel 凭据不存在: $CF_CREDENTIALS"; return 1; }
  validate_ingress || return 1
  write_supervisor

  case "$(service_mode)" in
    openrc)
      write_openrc
      rc-service cloudflared restart >/dev/null 2>&1 ||
        rc-service cloudflared start >/dev/null 2>&1 ||
        { red 'cloudflared 启动失败'; return 1; }
      rc-service cloudflared status >/dev/null 2>&1 || { red 'cloudflared 状态异常'; return 1; }
      ;;
    systemd)
      write_systemd
      systemctl restart cloudflared || { red 'cloudflared 重启失败'; return 1; }
      systemctl is-active --quiet cloudflared || { red 'cloudflared 未运行'; return 1; }
      ;;
    manual)
      "$CF_SUPERVISOR" "$CF_BIN" "$CF_CONFIG" "$CF_TUNNEL_ID" "$CF_LOG" "$CF_PIDFILE" "$CF_PROTOCOL" >/dev/null 2>&1 &
      ;;
  esac
  green "Tunnel 已启动，模式: $(service_mode)"
}

stop_tunnel(){
  case "$(service_mode)" in
    openrc) rc-service cloudflared stop >/dev/null 2>&1 || true;;
    systemd) systemctl stop cloudflared >/dev/null 2>&1 || true;;
  esac
  if [ -s "$CF_PIDFILE" ]; then
    pid=$(cat "$CF_PIDFILE" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true;; esac
  fi
  rm -f "$CF_PIDFILE"
  green 'Tunnel 已停止'
}

status_tunnel(){
  load_env
  printf 'OS=%s INIT=%s VERSION=%s\n' "$OS" "$INIT" "$VERSION"
  printf 'Tunnel=%s\nHost=%s\nOrigin=127.0.0.1:%s%s\nProtocol=%s\nEnabled=%s\n' \
    "$CF_TUNNEL_ID" "$CF_HOSTNAME" "$CF_SERVICE_PORT" "$CF_SERVICE_PATH" "$CF_PROTOCOL" "$CF_ENABLED"
  if [ -f "$CF_CONFIG" ]; then
    "$CF_BIN" --config "$CF_CONFIG" tunnel ingress validate 2>&1 || true
  fi
  pgrep -af 'cloudflared|cloudflared-supervisor' 2>/dev/null || yellow '没有 cloudflared 进程'
  [ -f "$CF_LOG" ] && tail -n 20 "$CF_LOG"
}

websocket_probe(){
  label=$1
  url=$2
  key=$(openssl rand -base64 16 | tr -d '\r\n') || {
    red "$label: 无法生成 WebSocket 探测密钥"
    return 1
  }
  headers=$(mktemp)
  if curl --silent --show-error --http1.1 \
      --connect-timeout 5 --max-time 15 \
      -D "$headers" -o /dev/null \
      -H 'Connection: Upgrade' \
      -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' \
      -H "Sec-WebSocket-Key: $key" \
      "$url"; then
    curl_rc=0
  else
    curl_rc=$?
  fi
  status=$(awk 'NR == 1 { print $2; exit }' "$headers")
  if [ "$status" = 101 ]; then
    rm -f "$headers"
    if [ "$curl_rc" -eq 28 ]; then
      yellow "$label: WebSocket 已升级 (HTTP 101，连接保持开放)"
    else
      green "$label: WebSocket 握手成功 (HTTP 101)"
    fi
    return 0
  fi
  if [ "$curl_rc" -ne 0 ]; then
    rm -f "$headers"
    red "$label: 请求失败 (curl $curl_rc)"
    return 1
  fi
  red "$label: WebSocket 握手失败 (HTTP ${status:-unknown})"
  sed -n '1,8p' "$headers"
  rm -f "$headers"
  return 1
}

check_origin(){
  load_env
  valid_port "$CF_SERVICE_PORT" || return 1
  if ! ss -lntp 2>/dev/null | grep -Eq ":$CF_SERVICE_PORT([[:space:]]|$)"; then
    red "本地回源端口未监听: $CF_SERVICE_PORT"
    return 1
  fi
  websocket_probe '本地回源' "http://127.0.0.1:$CF_SERVICE_PORT$CF_SERVICE_PATH"
}

check_public(){
  load_env
  [ -n "$CF_HOSTNAME" ] || { red '未配置域名'; return 1; }
  websocket_probe '公网链路' "https://$CF_HOSTNAME$CF_SERVICE_PATH"
}

delete_tunnel(){
  require_bin || return 1
  load_env
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 无效'; return 1; }
  printf '确认删除 Tunnel %s？输入 DELETE-TUNNEL: ' "$CF_TUNNEL_ID"
  IFS= read -r answer || answer=
  [ "$answer" = DELETE-TUNNEL ] || { yellow '已取消'; return 1; }
  stop_tunnel
  "$CF_BIN" tunnel cleanup "$CF_TUNNEL_ID" >/dev/null 2>&1 || true
  "$CF_BIN" tunnel delete "$CF_TUNNEL_ID"
  rm -f "$CF_CREDENTIALS" "$CF_CONFIG"
  CF_ENABLED=0
  save_env
  green 'Tunnel 已删除'
}

commands(){
  printf '%s\n' \
    "$0 guided" "$0 login" "$0 install" "$0 list" "$0 create" "$0 select" \
    "$0 configure" "$0 validate" "$0 dns-add" "$0 dns-delete" \
    "$0 start" "$0 stop" "$0 restart" "$0 status" "$0 info" "$0 origin" \
    "$0 public" "$0 links" "$0 delete" "$0 logs" "$0 commands"
}

interactive_menu(){
  while :; do
    printf '\n%s\n' '===== Cloudflare Tunnel 管理菜单 ====='
    printf '%s\n' \
      ' 1) 安装/更新 cloudflared' \
      ' 2) Cloudflare 登录' \
      ' 3) 列出 Tunnel' \
      ' 4) 创建 Tunnel' \
      ' 5) 选择 Tunnel' \
      ' 6) 配置 Ingress' \
      ' 7) 校验 Ingress' \
      ' 8) 添加 DNS 路由' \
      ' 9) 删除 DNS 路由' \
      '10) 启动 Tunnel' \
      '11) 停止 Tunnel' \
      '12) 重启 Tunnel' \
      '13) 查看 Tunnel 状态' \
      '14) 检查本地回源' \
      '15) 检查公网链路' \
      '16) 删除当前 Tunnel' \
      '17) 查看最近日志' \
      '18) 查看命令帮助' \
      ' 0) 退出'
    printf '%s' '请选择 [0-18]: '
    if ! IFS= read -r choice; then
      printf '\n'
      return 0
    fi

    case "$choice" in
      1) install_cloudflared;;
      2) login_cf;;
      3) list_tunnels;;
      4) create_tunnel;;
      5) select_tunnel;;
      6) configure_ingress;;
      7) validate_ingress;;
      8) route_add;;
      9) route_delete;;
      10) start_tunnel;;
      11) stop_tunnel;;
      12) stop_tunnel; sleep 1; start_tunnel;;
      13) status_tunnel;;
      14) check_origin;;
      15) check_public;;
      16) delete_tunnel;;
      17) [ -f "$CF_LOG" ] && tail -n 100 "$CF_LOG" || yellow '日志文件不存在';;
      18) commands;;
      0|q|Q)
        printf '%s\n' '已退出 Cloudflare Tunnel 管理菜单'
        return 0
        ;;
      *)
        red '无效选项，请输入 0-18'
        continue
        ;;
    esac

    printf '\n%s' '按 Enter 返回菜单，Ctrl-D 退出: '
    if ! IFS= read -r pause; then
      printf '\n'
      return 0
    fi
  done
}

info(){
  load_env
  printf '%s\n' '===== Cloudflare Tunnel 详细信息 ====='
  printf '脚本版本: %s\ncloudflared: %s\n' "$VERSION" "$CLOUDFLARED_VERSION"
  printf '系统: %s / init=%s\n' "$OS" "$INIT"
  printf 'Tunnel 名称: %s\nTunnel ID: %s\n' "$CF_TUNNEL_NAME" "$CF_TUNNEL_ID"
  printf 'Zone: %s\n域名: %s\n' "$CF_ZONE" "$CF_HOSTNAME"
  printf '回源: 127.0.0.1:%s%s\n协议: %s\n已启用: %s\n' \
    "$CF_SERVICE_PORT" "$CF_SERVICE_PATH" "$CF_PROTOCOL" "$CF_ENABLED"
  printf '配置文件: %s [%s]\n' "$CF_CONFIG" \
    "$([ -f "$CF_CONFIG" ] && printf '存在' || printf '缺失')"
  printf '凭据文件: %s [%s]\n' "$CF_CREDENTIALS" \
    "$([ -f "$CF_CREDENTIALS" ] && printf '存在' || printf '缺失')"
  printf '服务: '
  case "$(service_mode)" in
    openrc) rc-service cloudflared status 2>&1 || true;;
    systemd) systemctl is-active cloudflared 2>&1 || true;;
    *) printf 'manual\n';;
  esac
  if [ -f "$CF_CONFIG" ]; then
    printf '%s\n' 'Ingress 校验:'
    "$CF_BIN" --config "$CF_CONFIG" tunnel ingress validate 2>&1 || true
  fi
}

guided(){
  require_bin || return 1
  load_env
  printf '%s\n' '===== Cloudflare Tunnel 一键流程 ====='

  if [ -s "$CF_DIR/cert.pem" ]; then
    green '已检测到 Cloudflare 授权证书，跳过登录'
  else
    login_cf || return 1
  fi

  load_env
  if valid_id "$CF_TUNNEL_ID" && [ -s "$CF_CREDENTIALS" ]; then
    printf '检测到现有 Tunnel [%s]，是否复用？[Y/n]: ' "$CF_TUNNEL_NAME"
    IFS= read -r reuse || reuse=
    case "$reuse" in
      n|N) create_tunnel || return 1;;
      *) green '复用现有 Tunnel';;
    esac
  else
    printf '%s\n' '未检测到可用 Tunnel'
    printf '输入 1 创建新 Tunnel，输入 2 选择已有 Tunnel [1]: '
    IFS= read -r action || action=1
    case "$action" in
      2) select_tunnel || return 1;;
      *) create_tunnel || return 1;;
    esac
  fi

  load_env
  if [ -f "$CF_CONFIG" ] && [ -n "$CF_ZONE" ] && [ -n "$CF_HOSTNAME" ]; then
    printf '检测到现有 Ingress 配置，是否保留？[Y/n]: '
    keep_config=
    IFS= read -r keep_config || keep_config=
    case "$keep_config" in
      n|N) configure_ingress || return 1;;
      *) green '保留现有 Ingress 配置';;
    esac
  else
    configure_ingress || return 1
  fi

  validate_ingress || return 1
  route_add || return 1
  start_tunnel || return 1
  check_origin || return 1
  check_public || return 1
  info
  green 'Cloudflare Tunnel 一键流程完成'
}

login_cf(){
  require_bin || return 1
  mkdir -p "$CF_DIR"
  chmod 700 "$CF_DIR"
  rm -f "$CF_DIR/cert.pem"
  "$CF_BIN" login
  [ -s "$CF_DIR/cert.pem" ] || { red '未生成 cert.pem'; return 1; }
  chmod 600 "$CF_DIR/cert.pem"
  green 'Cloudflare 授权成功'
}

main(){
  root_check
  detect_os
  load_env
  case "${1:-menu}" in
    install) install_cloudflared;;
    login) login_cf;;
    list) list_tunnels;;
    create) create_tunnel;;
    select) select_tunnel;;
    configure) configure_ingress;;
    validate) validate_ingress;;
    dns-add) route_add;;
    dns-delete) route_delete;;
    start) start_tunnel;;
    stop) stop_tunnel;;
    restart) stop_tunnel; sleep 1; start_tunnel;;
    status) status_tunnel;;
    origin) check_origin;;
    public) check_public;;
    links) status_tunnel;;
    delete) delete_tunnel;;
    logs) [ -f "$CF_LOG" ] && tail -n 100 "$CF_LOG" || true;;
    commands) commands;;
    menu)
      interactive_menu
      ;;
    guided) guided;;
    info) info;;
    *) red "未知命令: $1"; commands; return 2;;
  esac
}

main "$@"