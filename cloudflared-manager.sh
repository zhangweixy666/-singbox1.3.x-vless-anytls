#!/bin/sh
# Cloudflare Tunnel manager for Alpine/OpenRC and Debian/systemd.
# State files are parsed as data; user-controlled files are never sourced or eval'ed.
set -eu
umask 077

VERSION=1.2.0
CLOUDFLARED_VERSION=2026.10.1
CLOUDFLARED_SHA256_386=9f5794f4e0bf2a4be8b3a3b8cc97720f60b3686089e07cebfd90aa9826b31749
CLOUDFLARED_SHA256_AMD64=3bfc539f45d2620c71debb7a86be0efa737ed5ccbad9eb85c787116900e5c586
CLOUDFLARED_SHA256_ARM=598445dbe19d789d2901c57bb9df5b070cc2c4f817c48b0ae2702a93d15a468e
CLOUDFLARED_SHA256_ARM64=2c65dfabf616c40efc7545d107d7a57ad5e21377e2964b7e88af19a238074a46
CLOUDFLARED_SHA256_ARMHF=c047e24af9ed956b55d514e3a0e2d8020e9c6d0629c4731c8ec08bd79a29a050

CF_DIR=${CF_DIR:-/root/.cloudflared}
CF_CONFIG=${CF_CONFIG:-$CF_DIR/config.yml}
CF_ENV=${CF_ENV:-/etc/cloudflared-manager.env}
CF_API_ENV=${CF_API_ENV:-/etc/cloudflared-manager.api}
CF_LOG_DIR=${CF_LOG_DIR:-/var/log/cloudflared}
CF_LOG=${CF_LOG:-$CF_LOG_DIR/tunnel.log}
CF_BIN=${CF_BIN:-/usr/local/bin/cloudflared}
CF_SUPERVISOR=${CF_SUPERVISOR:-/usr/local/sbin/cloudflared-supervisor.sh}
CF_PIDFILE=${CF_PIDFILE:-/run/cloudflared.pid}
CF_LEGACY_PIDFILE=${CF_LEGACY_PIDFILE:-/run/cloudflared-supervisor.pid}
CF_LOGROTATE=${CF_LOGROTATE:-/etc/logrotate.d/cloudflared}
CF_SERVICE_MODE=${CF_SERVICE_MODE:-auto}
CF_OPENRC=${CF_OPENRC:-/etc/init.d/cloudflared}
CF_SYSTEMD=${CF_SYSTEMD:-/etc/systemd/system/cloudflared.service}

# Output helpers
green(){ printf '\033[32m[成功]\033[0m %s\n' "$*"; }
cyan(){ printf '\033[36m[信息]\033[0m %s\n' "$*"; }
yellow(){ printf '\033[33m[警告]\033[0m %s\n' "$*"; }
red(){ printf '\033[31m[错误]\033[0m %s\n' "$*"; }

root_check(){
  [ "$(id -u)" = 0 ] || { red '请使用 root 运行'; exit 1; }
}

detect_os(){
  if [ -f /etc/alpine-release ]; then
    OS=alpine; PM=apk; INIT=openrc
  elif [ -f /etc/debian_version ]; then
    OS=debian; PM=apt-get; INIT=systemd
  else
    OS=unknown; PM=; INIT=manual
  fi
}

read_line(){
  if [ -t 0 ] || [ -t 1 ]; then
    if IFS= read -r "$@" </dev/tty 2>/dev/null; then
      return 0
    fi
  fi
  IFS= read -r "$@"
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
  CF_API_TOKEN=
}

load_env(){
  defaults
  [ -r "$CF_ENV" ] || return 0
  while IFS='=' read -r key rest || [ -n "$key" ]; do
    case "$key" in
      ''|\#*) continue;;
      CF_TUNNEL_ID|CF_TUNNEL_NAME|CF_CREDENTIALS|CF_ZONE|CF_HOSTNAME|CF_SERVICE_PORT|CF_SERVICE_PATH|CF_PROTOCOL|CF_ENABLED)
        value=${rest#*=}
        set_cf_value "$key" "$value";;
    esac
  done < "$CF_ENV"
}

save_env(){
  mkdir -p "$(dirname "$CF_ENV")"
  tmp="$CF_ENV.tmp.$$"
  cat > "$tmp" <<EOF
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
  chmod 600 "$tmp"
  mv -f "$tmp" "$CF_ENV"
}

read_secret(){
  prompt=$1
  printf '%s' "$prompt" >&2
  old_stty=$(stty -g 2>/dev/null || true)
  stty -echo 2>/dev/null || true
  read_line secret || secret=
  [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null || true
  printf '\n' >&2
  printf '%s' "$secret"
}

ask(){
  var=$1
  prompt=$2
  default=${3:-}
  printf '%s' "$prompt"
  read_line answer || answer=
  [ -n "$answer" ] || answer=$default
  set_cf_value "$var" "$answer"
}

valid_id(){
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

valid_port(){
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

valid_dns_name(){
  [ -n "$1" ] || return 1
  case "$1" in *[!A-Za-z0-9.-]*) return 1;; esac
  printf '%s\n' "$1" | awk '
    {
      if (length($0) > 253) exit 1
      n = split($0, a, ".")
      if (n < 2) exit 1
      for (i = 1; i <= n; i++) {
        if (length(a[i]) < 1 || length(a[i]) > 63) exit 1
        if (a[i] !~ /^[A-Za-z0-9-]+$/ || a[i] ~ /^-/ || a[i] ~ /-$/) exit 1
      }
      ok = 1
    }
    END { if (ok) exit 0; exit 1 }
  '
}

host_in_zone(){
  case "$1" in
    "$2"|*."$2") return 0;;
    *) return 1;;
  esac
}

valid_path(){
  case "$1" in
    ''|*[!A-Za-z0-9._~/-]*|*\ *|*\.\.*|*//*) return 1;;
  esac
  case "$1" in
    /|/[A-Za-z0-9._~/-]*) return 0;;
    *) return 1;;
  esac
}

valid_tunnel_name(){
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1;;
  esac
}

require_bin(){
  if [ -x "$CF_BIN" ]; then return 0; fi
  found=$(command -v cloudflared 2>/dev/null || true)
  [ -n "$found" ] && CF_BIN=$found
  [ -x "$CF_BIN" ] || {
    red "找不到 cloudflared，请先运行: $0 install"
    return 1
  }
}

arch_info(){
  case "$(uname -m)" in
    x86_64|amd64) CF_ASSET=amd64; CF_EXPECTED_SHA=$CLOUDFLARED_SHA256_AMD64;;
    i386|i686|386) CF_ASSET=386; CF_EXPECTED_SHA=$CLOUDFLARED_SHA256_386;;
    aarch64|arm64) CF_ASSET=arm64; CF_EXPECTED_SHA=$CLOUDFLARED_SHA256_ARM64;;
    armv7l|armv7) CF_ASSET=arm; CF_EXPECTED_SHA=$CLOUDFLARED_SHA256_ARM;;
    armhf) CF_ASSET=armhf; CF_EXPECTED_SHA=$CLOUDFLARED_SHA256_ARMHF;;
    *) red "不支持架构: $(uname -m)"; return 1;;
  esac
}

install_dependencies(){
  if [ "$PM" = apk ]; then
    if ! apk add --no-cache curl ca-certificates python3 procps iproute2 bind-tools coreutils openssl logrotate >/dev/null; then
      red 'Alpine 依赖安装失败，请检查 apk 源和网络'
      return 1
    fi
  elif [ "$PM" = apt-get ]; then
    if ! apt-get update -qq || ! DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates python3 procps iproute2 dnsutils coreutils openssl logrotate >/dev/null; then
      red 'Debian/Ubuntu 依赖安装失败，请检查 apt 源和网络'
      return 1
    fi
  else
    for dep in curl python3 sha256sum openssl; do
      command -v "$dep" >/dev/null 2>&1 || { red "缺少依赖: $dep"; return 1; }
    done
  fi
}

binary_version(){
  "$CF_BIN" version 2>&1 | sed -n '1s/.*version[[:space:]]\+\([^[:space:]]*\).*/\1/p'
}

binary_is_fixed(){
  [ -x "$CF_BIN" ] || return 1
  arch_info || return 1
  actual=$(binary_version 2>/dev/null || true)
  [ "$actual" = "$CLOUDFLARED_VERSION" ] || return 1
  actual_sha=$(sha256sum "$CF_BIN" 2>/dev/null | awk '{print $1}') || return 1
  [ "$actual_sha" = "$CF_EXPECTED_SHA" ]
}

install_cloudflared(){
  install_dependencies || return 1
  arch_info || return 1
  mkdir -p "$(dirname "$CF_BIN")"
  tmp=$(mktemp -d)
  url="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$CF_ASSET"
  if ! curl --fail --silent --show-error --location --connect-timeout 5 --max-time 120 --proto '=https' --tlsv1.2 "$url" -o "$tmp/cloudflared"; then
    rm -rf "$tmp"
    red "cloudflared 下载失败: $url"
    return 1
  fi
  if ! actual_sha=$(sha256sum "$tmp/cloudflared" | awk '{print $1}'); then
    rm -rf "$tmp"
    red '无法计算 cloudflared SHA-256'
    return 1
  fi
  if [ "$actual_sha" != "$CF_EXPECTED_SHA" ]; then
    rm -rf "$tmp"
    red "cloudflared SHA-256 校验失败: 期望 $CF_EXPECTED_SHA，实际 $actual_sha"
    return 1
  fi
  chmod 755 "$tmp/cloudflared"
  installed_version=$("$tmp/cloudflared" version 2>&1 | sed -n '1s/.*version[[:space:]]\+\([^[:space:]]*\).*/\1/p')
  if [ "$installed_version" != "$CLOUDFLARED_VERSION" ]; then
    rm -rf "$tmp"
    red "cloudflared 版本校验失败: 期望 $CLOUDFLARED_VERSION，实际 ${installed_version:-未知}"
    return 1
  fi
  target="$CF_BIN.tmp.$$"
  install -m 755 "$tmp/cloudflared" "$target"
  mv -f "$target" "$CF_BIN"
  rm -rf "$tmp"
  green "cloudflared 已固定为 $CLOUDFLARED_VERSION，SHA-256 校验通过"
}

ensure_cloudflared(){
  if binary_is_fixed; then return 0; fi
  if [ -x "$CF_BIN" ]; then
    yellow "检测到 cloudflared 版本 $(binary_version 2>/dev/null || printf '未知')，将安装固定版本 $CLOUDFLARED_VERSION"
  else
    cyan "首次运行，自动安装固定版本 cloudflared $CLOUDFLARED_VERSION"
  fi
  install_cloudflared
}

cert_is_valid(){
  [ -s "$CF_DIR/cert.pem" ] || return 1
  python3 - "$CF_DIR/cert.pem" <<'PY'
import base64, json, sys
try:
    pem = open(sys.argv[1], encoding='utf-8').read()
    body = pem.split('-----BEGIN ARGO TUNNEL TOKEN-----', 1)[1]
    body = body.split('-----END ARGO TUNNEL TOKEN-----', 1)[0]
    body = ''.join(body.split())
    body += '=' * (-len(body) % 4)
    data = json.loads(base64.urlsafe_b64decode(body))
    if not data.get('accountID') or not data.get('apiToken'):
        raise ValueError('missing token fields')
except Exception:
    sys.exit(1)
sys.exit(0)
PY
}

backup_cert(){
  [ -f "$CF_DIR/cert.pem" ] || return 0
  backup="$CF_DIR/cert.pem.bak.$(date +%s).$$"
  cp -p "$CF_DIR/cert.pem" "$backup" 2>/dev/null || true
}

restore_latest_cert(){
  old=$(find "$CF_DIR" -maxdepth 1 -type f -name 'cert.pem.bak.*' -print 2>/dev/null | sort -r | head -n 1 || true)
  [ -n "$old" ] || return 1
  cp -p "$old" "$CF_DIR/cert.pem" 2>/dev/null || return 1
  chmod 600 "$CF_DIR/cert.pem"
}

login_cf(){
  require_bin || return 1
  mkdir -p "$CF_DIR"
  chmod 700 "$CF_DIR"
  if cert_is_valid; then
    green '已存在有效的 Cloudflare 授权证书，跳过重新登录'
    return 0
  fi
  if [ -f "$CF_DIR/cert.pem" ]; then
    yellow '现有 cert.pem 无法验证，将先备份后重新授权'
    backup_cert
  fi
  rm -f "$CF_DIR/cert.pem"
  yellow '请在浏览器中完成 Cloudflare 授权'
  if ! "$CF_BIN" --no-autoupdate login; then
    red 'cloudflared login 失败或未完成'
    restore_latest_cert && green '已恢复原证书' || true
    return 1
  fi
  if ! cert_is_valid; then
    red 'cloudflared login 未生成有效的 cert.pem'
    restore_latest_cert && green '已恢复原证书' || true
    return 1
  fi
  chmod 600 "$CF_DIR/cert.pem"
  green 'Cloudflare 授权成功'
}

list_tunnels(){
  require_bin || return 1
  "$CF_BIN" --no-autoupdate tunnel list
}

create_tunnel(){
  require_bin || return 1
  load_env
  ask CF_TUNNEL_NAME 'Tunnel 名称 [singbox-tunnel]: ' "singbox-tunnel"
  valid_tunnel_name "$CF_TUNNEL_NAME" || { red 'Tunnel 名称格式无效，只能使用字母、数字、点、下划线和短横线'; return 1; }
  if ! output=$("$CF_BIN" --no-autoupdate tunnel create "$CF_TUNNEL_NAME" 2>&1); then
    printf '%s\n' "$output"
    return 1
  fi
  printf '%s\n' "$output"
  CF_TUNNEL_ID=$(printf '%s\n' "$output" | sed -n 's/.*\([0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}\).*/\1/p' | head -n 1)
  if ! valid_id "$CF_TUNNEL_ID"; then
    printf '请手动输入 Tunnel ID: '
    read_line CF_TUNNEL_ID || CF_TUNNEL_ID=
  fi
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 格式无效'; return 1; }
  CF_CREDENTIALS=$CF_DIR/$CF_TUNNEL_ID.json
  if [ ! -s "$CF_CREDENTIALS" ]; then
    red "Tunnel 已创建，但本地凭据不存在: $CF_CREDENTIALS"
    yellow '请检查 cloudflared 输出后再选择该 Tunnel，避免写入不完整状态'
    return 1
  fi
  chmod 400 "$CF_CREDENTIALS" 2>/dev/null || true
  # 新 Tunnel 不能复用旧 Tunnel 的 Ingress 和域名状态。
  CF_ZONE=
  CF_HOSTNAME=
  CF_ENABLED=0
  save_env
  green "Tunnel 已创建: $CF_TUNNEL_ID"
}

select_tunnel(){
  require_bin || return 1
  load_env
  if ! output=$("$CF_BIN" --no-autoupdate tunnel list 2>&1); then
    printf '%s\n' "$output"
    return 1
  fi
  printf '%s\n' "$output"
  tmp=$(mktemp)
  printf '%s\n' "$output" | awk '
    $1 ~ /^[0-9A-Fa-f-]+$/ && length($1) == 36 { printf "%d %s %s\n", ++n, $1, $2 }
  ' > "$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    red '未找到可选择的 Tunnel'
    return 1
  fi
  printf '%s\n' '请选择 Tunnel（输入序号或直接粘贴 ID）：'
  awk '{ printf "  %d) %s (%s)\n", $1, $3, $2 }' "$tmp"
  printf '选择 [%s]: ' "${CF_TUNNEL_ID:-}"
  read_line choice || choice=
  choice=$(printf '%s' "$choice" | tr -d ' ')
  if [ -z "$choice" ] && valid_id "${CF_TUNNEL_ID:-}"; then
    choice=$CF_TUNNEL_ID
  fi
  if printf '%s' "$choice" | grep -Eq '^[0-9]+$' && [ "$choice" -ge 1 ] 2>/dev/null; then
    selected_id=$(awk -v n="$choice" '$1 == n { print $2; exit }' "$tmp")
    selected_name=$(awk -v n="$choice" '$1 == n { print $3; exit }' "$tmp")
    [ -n "$selected_id" ] || { rm -f "$tmp"; red '序号无效'; return 1; }
    CF_TUNNEL_ID=$selected_id
    CF_TUNNEL_NAME=$selected_name
  else
    CF_TUNNEL_ID=$choice
    selected_name=$(awk -v id="$CF_TUNNEL_ID" '$2 == id { print $3; exit }' "$tmp")
    [ -n "$selected_name" ] && CF_TUNNEL_NAME=$selected_name
  fi
  rm -f "$tmp"
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 格式无效'; return 1; }
  CF_CREDENTIALS=$CF_DIR/$CF_TUNNEL_ID.json
  if [ ! -s "$CF_CREDENTIALS" ]; then
    red "本机没有该 Tunnel 的 JSON 凭据: $CF_CREDENTIALS"
    yellow '请在创建该 Tunnel 的机器上导出 JSON，或在本机重新创建 Tunnel'
    return 1
  fi
  chmod 400 "$CF_CREDENTIALS" 2>/dev/null || true
  CF_ZONE=
  CF_HOSTNAME=
  CF_ENABLED=0
  save_env
  green "已选择 Tunnel: $CF_TUNNEL_ID ($CF_TUNNEL_NAME)"
}

credential_matches_tunnel(){
  [ -s "$CF_CREDENTIALS" ] || return 1
  python3 - "$CF_CREDENTIALS" "$CF_TUNNEL_ID" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
    tunnel_id = data.get('TunnelID') or data.get('tunnel_id') or data.get('tunnelID')
    sys.exit(0 if str(tunnel_id).lower() == sys.argv[2].lower() else 1)
except Exception:
    sys.exit(1)
PY
}

config_matches_state(){
  load_env
  valid_id "$CF_TUNNEL_ID" || return 1
  [ -f "$CF_CONFIG" ] || return 1
  case "$CF_CREDENTIALS" in "$CF_DIR"/*.json) ;; *) return 1;; esac
  cfg_tunnel=$(sed -n 's/^tunnel:[[:space:]]*//p' "$CF_CONFIG" | head -n 1)
  cfg_credentials=$(sed -n 's/^credentials-file:[[:space:]]*//p' "$CF_CONFIG" | head -n 1)
  [ "$cfg_tunnel" = "$CF_TUNNEL_ID" ] || return 1
  [ "$cfg_credentials" = "$CF_CREDENTIALS" ] || return 1
  credential_matches_tunnel
}

state_ready(){
  config_matches_state || return 1
  [ "$CF_ENABLED" = 1 ] || return 1
}

write_config(){
  path=$1
  cat > "$path" <<EOF
tunnel: $CF_TUNNEL_ID
credentials-file: $CF_CREDENTIALS
protocol: $CF_PROTOCOL
ingress:
  - hostname: $CF_HOSTNAME
    service: http://127.0.0.1:$CF_SERVICE_PORT
  - service: http_status:404
EOF
  chmod 600 "$path"
}

configure_ingress(){
  require_bin || return 1
  load_env
  valid_id "$CF_TUNNEL_ID" || { red '请先创建或选择 Tunnel'; return 1; }
  credential_matches_tunnel || { red 'Tunnel JSON 凭据不存在、损坏或与当前 Tunnel ID 不匹配'; return 1; }

  ask CF_ZONE 'Cloudflare Zone: ' "$CF_ZONE"
  CF_ZONE=$(printf '%s' "$CF_ZONE" | tr '[:upper:]' '[:lower:]')
  valid_dns_name "$CF_ZONE" || { red 'Zone 格式无效'; return 1; }

  ask CF_HOSTNAME "公网域名 [$CF_ZONE]: " "${CF_HOSTNAME:-cf-test.$CF_ZONE}"
  CF_HOSTNAME=$(printf '%s' "$CF_HOSTNAME" | tr '[:upper:]' '[:lower:]')
  valid_dns_name "$CF_HOSTNAME" || { red '公网域名格式无效'; return 1; }
  host_in_zone "$CF_HOSTNAME" "$CF_ZONE" || { red '公网域名不属于当前 Zone'; return 1; }

  ask CF_SERVICE_PORT "本地回源端口 [$CF_SERVICE_PORT]: " "$CF_SERVICE_PORT"
  valid_port "$CF_SERVICE_PORT" || { red '端口无效'; return 1; }

  ask CF_SERVICE_PATH "WS 路径 [$CF_SERVICE_PATH]: " "$CF_SERVICE_PATH"
  valid_path "$CF_SERVICE_PATH" || { red 'WS 路径无效'; return 1; }

  ask CF_PROTOCOL 'Tunnel 协议 auto/quic/http2 [auto]: ' "$CF_PROTOCOL"
  case "$CF_PROTOCOL" in auto|quic|http2) ;; *) red '协议无效'; return 1;; esac

  mkdir -p "$CF_DIR"
  tmp="$CF_CONFIG.tmp.$$"
  backup="$CF_CONFIG.rollback.$$"
  write_config "$tmp"
  if ! "$CF_BIN" --no-autoupdate --config "$tmp" tunnel ingress validate; then
    rm -f "$tmp"
    red 'Ingress 校验失败，原配置保持不变'
    return 1
  fi
  had_old=0
  if [ -f "$CF_CONFIG" ]; then
    cp -p "$CF_CONFIG" "$backup"
    had_old=1
  fi
  mv -f "$tmp" "$CF_CONFIG"
  CF_ENABLED=1
  if ! save_env; then
    if [ "$had_old" = 1 ]; then mv -f "$backup" "$CF_CONFIG"; else rm -f "$CF_CONFIG"; fi
    red '状态文件保存失败，已回滚 Ingress 配置'
    return 1
  fi
  rm -f "$backup"
  green "Ingress 配置有效并已原子替换: $CF_CONFIG"
}

validate_ingress(){
  require_bin || return 1
  [ -f "$CF_CONFIG" ] || { red "配置不存在: $CF_CONFIG"; return 1; }
  "$CF_BIN" --no-autoupdate --config "$CF_CONFIG" tunnel ingress validate
}

load_api(){
  CF_API_TOKEN=
  [ -r "$CF_API_ENV" ] || return 0
  while IFS='=' read -r key rest || [ -n "$key" ]; do
    case "$key" in
      CF_API_TOKEN) CF_API_TOKEN=${rest#*=};;
    esac
  done < "$CF_API_ENV"
}

ask_api(){
  load_api
  if [ -z "${CF_API_TOKEN:-}" ]; then
    CF_API_TOKEN=$(read_secret '请输入 Cloudflare API Token（不可回显）: ')
    [ -n "$CF_API_TOKEN" ] || return 1
    mkdir -p "$(dirname "$CF_API_ENV")"
    tmp="$CF_API_ENV.tmp.$$"
    printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CF_API_ENV"
  fi
  export CF_API_TOKEN
}

extract_api_token_from_cert(){
  [ -s "$CF_DIR/cert.pem" ] || return 1
  api_token=$(python3 - "$CF_DIR/cert.pem" <<'PY'
import base64, json, sys
try:
    pem = open(sys.argv[1], encoding='utf-8').read()
    body = pem.split('-----BEGIN ARGO TUNNEL TOKEN-----', 1)[1]
    body = body.split('-----END ARGO TUNNEL TOKEN-----', 1)[0]
    body = ''.join(body.split())
    body += '=' * (-len(body) % 4)
    data = json.loads(base64.urlsafe_b64decode(body))
    print(data.get('apiToken', ''))
except Exception:
    print('')
PY
)
  [ -n "$api_token" ] || return 1
  CF_API_TOKEN=$api_token
  export CF_API_TOKEN
}

ensure_api_token(){
  load_api
  if [ -z "${CF_API_TOKEN:-}" ]; then
    extract_api_token_from_cert || ask_api || return 1
  fi
  [ -n "$CF_API_TOKEN" ] || return 1
  export CF_API_TOKEN
}

load_dns_zone_id(){
  ensure_api_token || { red '无法获取 Cloudflare API Token'; return 1; }
  response=$(mktemp)
  if ! curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H 'Content-Type: application/json' \
      --get --data-urlencode "name=$CF_ZONE" --data-urlencode 'status=active' \
      'https://api.cloudflare.com/client/v4/zones' -o "$response"; then
    rm -f "$response"
    red 'Cloudflare Zone API 请求失败'
    return 1
  fi
  if ! zone_id=$(python3 - "$response" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
    if not data.get('success', False) or not data.get('result'):
        raise ValueError('zone not found')
    print(data['result'][0]['id'])
except Exception:
    sys.exit(1)
PY
  ); then
    rm -f "$response"
    red 'Cloudflare Zone API 返回无效或找不到 Zone'
    return 1
  fi
  rm -f "$response"
  printf '%s\n' "$zone_id"
}

route_add(){
  require_bin || return 1
  load_env
  state_ready || { red '当前 Tunnel、凭据和 config.yml 不一致，请先完成 configure'; return 1; }
  host_in_zone "$CF_HOSTNAME" "$CF_ZONE" || { red '域名不属于当前 Zone'; return 1; }
  if ! "$CF_BIN" --no-autoupdate tunnel route dns --overwrite-dns "$CF_TUNNEL_ID" "$CF_HOSTNAME"; then
    red 'DNS 路由创建失败'
    return 1
  fi
  green "DNS 路由已添加: $CF_HOSTNAME"
}

route_delete(){
  load_env
  [ -n "$CF_ZONE" ] && [ -n "$CF_HOSTNAME" ] || { red '请先配置 Zone 和域名'; return 1; }
  valid_dns_name "$CF_ZONE" || { red 'Zone 格式无效'; return 1; }
  valid_dns_name "$CF_HOSTNAME" || { red '域名格式无效'; return 1; }
  host_in_zone "$CF_HOSTNAME" "$CF_ZONE" || { red '域名不属于当前 Zone'; return 1; }
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 无效'; return 1; }
  ensure_api_token || { red '无法获取 Cloudflare API Token'; return 1; }
  zone_id=$(load_dns_zone_id) || return 1
  target=$(printf '%s.cfargotunnel.com' "$CF_TUNNEL_ID")
  response=$(mktemp)
  if ! curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      --get --data-urlencode 'type=CNAME' --data-urlencode "name=$CF_HOSTNAME" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" -o "$response"; then
    rm -f "$response"
    red 'Cloudflare DNS 查询失败'
    return 1
  fi
  if ! records=$(TARGET="$target" python3 - "$response" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
    if not data.get('success', False):
        raise ValueError('API failure')
    target = os.environ['TARGET'].rstrip('.').lower()
    for record in data.get('result', []):
        content = str(record.get('content', '')).rstrip('.').lower()
        if record.get('type') == 'CNAME' and content == target:
            print(record['id'])
except Exception:
    sys.exit(1)
PY
  ); then
    rm -f "$response"
    red 'Cloudflare DNS 查询返回无效'
    return 1
  fi
  rm -f "$response"
  [ -n "$records" ] || { yellow '没有找到指向当前 Tunnel 的 CNAME，未删除任何记录'; return 0; }
  for record_id in $records; do
    response=$(mktemp)
    if ! curl --fail --silent --show-error --connect-timeout 5 --max-time 30 -X DELETE \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" -o "$response"; then
      rm -f "$response"
      red "删除 DNS 记录失败: $record_id"
      return 1
    fi
    if ! python3 - "$response" <<'PY'
import json, sys
try:
    sys.exit(0 if json.load(open(sys.argv[1], encoding='utf-8')).get('success', False) else 1)
except Exception:
    sys.exit(1)
PY
    then
      rm -f "$response"
      red "Cloudflare 未确认删除 DNS 记录: $record_id"
      return 1
    fi
    rm -f "$response"
  done
  green "已删除当前 Tunnel 的 DNS 记录: $CF_HOSTNAME"
}

service_mode(){
  case "$CF_SERVICE_MODE" in
    openrc|systemd|manual) printf '%s\n' "$CF_SERVICE_MODE";;
    *)
      if command -v rc-service >/dev/null 2>&1; then printf '%s\n' openrc
      elif command -v systemctl >/dev/null 2>&1; then printf '%s\n' systemd
      else printf '%s\n' manual
      fi
      ;;
  esac
}

write_logrotate(){
  [ -d "$(dirname "$CF_LOGROTATE")" ] || return 0
  cat > "$CF_LOGROTATE" <<EOF
$CF_LOG {
  daily
  rotate 7
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
  create 640 root root
}
EOF
  chmod 644 "$CF_LOGROTATE"
}

write_manual_supervisor(){
  mkdir -p "$CF_LOG_DIR" "$(dirname "$CF_SUPERVISOR")"
  cat > "$CF_SUPERVISOR" <<'EOF_SUPERVISOR'
#!/bin/sh
set -eu
bin=$1
config=$2
tunnel=$3
log=$4
pidfile=$5
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
  "$bin" --config "$config" --no-autoupdate tunnel run "$tunnel" >> "$log" 2>&1 &
  child=$!
  wait "$child" || true
  child=
  sleep 3
done
EOF_SUPERVISOR
  chmod 755 "$CF_SUPERVISOR"
}

write_openrc(){
  mkdir -p "$CF_LOG_DIR" "$(dirname "$CF_OPENRC")"
  cat > "$CF_OPENRC" <<EOF
#!/sbin/openrc-run
name="cloudflared"
description="Cloudflare Tunnel"
command="$CF_BIN"
command_args="--no-autoupdate --config $CF_CONFIG tunnel run $CF_TUNNEL_ID"
command_background="yes"
pidfile="$CF_PIDFILE"
output_log="$CF_LOG"
error_log="$CF_LOG"
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0
start_pre() {
  mkdir -p "$CF_LOG_DIR"
  "$CF_BIN" --no-autoupdate --config "$CF_CONFIG" tunnel ingress validate
}
depend() { need net; after firewall; }
EOF
  chmod 755 "$CF_OPENRC"
  rc-update add cloudflared default >/dev/null 2>&1 || true
}

write_systemd(){
  mkdir -p "$CF_LOG_DIR" "$(dirname "$CF_SYSTEMD")"
  cat > "$CF_SYSTEMD" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$CF_BIN --no-autoupdate --config $CF_CONFIG --logfile $CF_LOG tunnel run $CF_TUNNEL_ID
ExecStartPre=$CF_BIN --no-autoupdate --config $CF_CONFIG tunnel ingress validate
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$CF_LOG_DIR
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable cloudflared >/dev/null 2>&1 || true
}

pidfile_is_ours(){
  file=$1
  [ -r "$file" ] || return 1
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  [ -d "/proc/$pid" ] || return 1
  cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  case "$cmd" in
    *cloudflared*"$CF_TUNNEL_ID"*) printf '%s\n' "$pid"; return 0;;
    *) return 1;;
  esac
}

stop_pidfile(){
  file=$1
  pid=$(pidfile_is_ours "$file" || true)
  [ -n "$pid" ] || { rm -f "$file"; return 0; }
  kill "$pid" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  rm -f "$file"
}

find_tunnel_process(){
  for proc in /proc/[0-9]*; do
    pid=${proc#/proc/}
    [ "$pid" = "$$" ] && continue
    [ -r "$proc/cmdline" ] || continue
    cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *"$CF_BIN"*"tunnel run"*"$CF_TUNNEL_ID"*) printf '%s %s\n' "$pid" "$cmd"; return 0;;
    esac
  done
  return 1
}

stop_service_only(){
  case "$(service_mode)" in
    openrc) rc-service cloudflared stop >/dev/null 2>&1 || true;;
    systemd) systemctl stop cloudflared >/dev/null 2>&1 || true;;
  esac
  stop_pidfile "$CF_PIDFILE"
  stop_pidfile "$CF_LEGACY_PIDFILE"
  valid_id "${CF_TUNNEL_ID:-}" || return 0
  if find_tunnel_process >/dev/null 2>&1; then
    orphan=$(find_tunnel_process | awk '{print $1; exit}')
    case "$orphan" in
      ''|*[!0-9]*) ;;
      *) kill "$orphan" 2>/dev/null || true;;
    esac
  fi
}

wait_for_tunnel_process(){
  i=0
  while [ "$i" -lt 20 ]; do
    if find_tunnel_process >/dev/null 2>&1; then return 0; fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

start_tunnel(){
  ensure_cloudflared || return 1
  load_env
  [ "$CF_ENABLED" = 1 ] || { red '请先完成 Ingress 配置'; return 1; }
  [ -f "$CF_CONFIG" ] || { red "Tunnel 配置不存在: $CF_CONFIG"; return 1; }
  state_ready || { red 'Tunnel、凭据、config.yml 或状态文件不一致，请重新执行 configure'; return 1; }
  validate_ingress || return 1
  mkdir -p "$CF_LOG_DIR"
  write_logrotate
  stop_service_only

  case "$(service_mode)" in
    openrc)
      write_openrc
      if ! rc-service cloudflared start >/dev/null 2>&1; then
        red 'OpenRC 启动 cloudflared 失败'
        return 1
      fi
      ;;
    systemd)
      write_systemd
      if ! systemctl start cloudflared; then
        red 'systemd 启动 cloudflared 失败'
        return 1
      fi
      ;;
    manual)
      write_manual_supervisor
      "$CF_SUPERVISOR" "$CF_BIN" "$CF_CONFIG" "$CF_TUNNEL_ID" "$CF_LOG" "$CF_PIDFILE" >/dev/null 2>&1 &
      ;;
  esac

  if ! wait_for_tunnel_process; then
    red 'cloudflared 服务已启动但 Tunnel 子进程未运行'
    tail -n 30 "$CF_LOG" 2>/dev/null || true
    return 1
  fi
  green "Tunnel 已启动，模式: $(service_mode)，cloudflared=$CLOUDFLARED_VERSION（自动更新已关闭）"
}

stop_tunnel(){
  load_env
  stop_service_only
  green 'Tunnel 已停止'
}

status_tunnel(){
  load_env
  printf 'OS=%s INIT=%s MANAGER=%s TARGET_CLOUDFLARED=%s\n' "$OS" "$INIT" "$VERSION" "$CLOUDFLARED_VERSION"
  printf 'Tunnel=%s\nHost=%s\nOrigin=127.0.0.1:%s%s\nProtocol=%s\nEnabled=%s\n' \
    "$CF_TUNNEL_ID" "$CF_HOSTNAME" "$CF_SERVICE_PORT" "$CF_SERVICE_PATH" "$CF_PROTOCOL" "$CF_ENABLED"
  if [ -x "$CF_BIN" ]; then
    printf 'Actual cloudflared: '; binary_version || printf 'unknown\n'
    if binary_is_fixed; then green '二进制完整性: 固定版本和 SHA-256 通过'; else yellow '二进制完整性: 版本或 SHA-256 未通过'; fi
  else
    yellow 'cloudflared binary missing'
  fi
  if [ -f "$CF_CONFIG" ]; then
    "$CF_BIN" --no-autoupdate --config "$CF_CONFIG" tunnel ingress validate 2>&1 || true
  fi
  if state_ready 2>/dev/null; then
    if find_tunnel_process; then :; else yellow '没有匹配当前 Tunnel ID 的 cloudflared 子进程'; fi
  else
    yellow '当前状态文件、配置和凭据未形成一致可运行状态'
  fi
  case "$(service_mode)" in
    openrc) rc-service cloudflared status 2>&1 || true;;
    systemd) systemctl is-active cloudflared 2>&1 || true;;
  esac
  [ -f "$CF_LOG" ] && tail -n 20 "$CF_LOG"
}

websocket_probe(){
  label=$1
  url=$2
  key=$(openssl rand -base64 16 | tr -d '\r\n') || { red "$label: 无法生成 WebSocket 探测密钥"; return 1; }
  headers=$(mktemp)
  if curl --silent --show-error --http1.1 --connect-timeout 3 --max-time 4 \
      -D "$headers" -o /dev/null \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $key" \
      "$url" 2>/dev/null; then
    curl_rc=0
  else
    curl_rc=$?
  fi
  status=$(awk 'NR == 1 { print $2; exit }' "$headers" 2>/dev/null)
  if [ "$status" = 101 ]; then
    rm -f "$headers"
    if [ "$curl_rc" -eq 28 ]; then yellow "$label: WebSocket 已升级 (HTTP 101，连接保持开放)"; else green "$label: WebSocket 握手成功 (HTTP 101)"; fi
    return 0
  fi
  if [ "$curl_rc" -ne 0 ]; then
    rm -f "$headers"
    red "$label: 请求失败 (curl $curl_rc)"
    return 1
  fi
  red "$label: WebSocket 握手失败 (HTTP ${status:-unknown})"
  sed -n '1,8p' "$headers" 2>/dev/null || true
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
  valid_dns_name "$CF_HOSTNAME" || { red '未配置有效公网域名'; return 1; }
  websocket_probe '公网链路' "https://$CF_HOSTNAME$CF_SERVICE_PATH"
}

delete_tunnel(){
  require_bin || return 1
  load_env
  valid_id "$CF_TUNNEL_ID" || { red 'Tunnel ID 无效'; return 1; }
  printf '确认删除 Tunnel %s？输入 DELETE-TUNNEL: ' "$CF_TUNNEL_ID"
  read_line answer || answer=
  [ "$answer" = DELETE-TUNNEL ] || { yellow '已取消'; return 1; }
  stop_service_only
  "$CF_BIN" --no-autoupdate tunnel cleanup "$CF_TUNNEL_ID" >/dev/null 2>&1 || true
  if ! "$CF_BIN" --no-autoupdate tunnel delete "$CF_TUNNEL_ID"; then
    red 'Cloudflare Tunnel 删除失败，本地配置和凭据保留'
    return 1
  fi
  rm -f "$CF_CREDENTIALS" "$CF_CONFIG"
  CF_TUNNEL_ID=
  CF_TUNNEL_NAME=
  CF_CREDENTIALS=
  CF_ZONE=
  CF_HOSTNAME=
  CF_ENABLED=0
  save_env
  green 'Tunnel 已删除，本地状态已清空'
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
      ' 1) 安装/校验固定版本 cloudflared' \
      ' 2) Cloudflare 登录' \
      ' 3) 列出 Tunnel' \
      ' 4) 创建 Tunnel' \
      ' 5) 选择已有 Tunnel' \
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
    if ! read_line choice; then printf '\n'; return 0; fi
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
      0|q|Q) printf '%s\n' '���退出 Cloudflare Tunnel 管理菜单'; return 0;;
      *) red '无效选项，请输入 0-18'; continue;;
    esac
    printf '\n%s' '按 Enter 返回菜单，Ctrl-D 退出: '
    if ! read_line pause; then printf '\n'; return 0; fi
  done
}

info(){
  load_env
  printf '%s\n' '===== Cloudflare Tunnel 详细信息 ====='
  printf '管理器版本: %s\n目标 cloudflared: %s\n' "$VERSION" "$CLOUDFLARED_VERSION"
  if [ -x "$CF_BIN" ]; then printf '实际 cloudflared: '; binary_version || printf 'unknown\n'; else printf '实际 cloudflared: 缺失\n'; fi
  printf '系统: %s / init=%s\n' "$OS" "$INIT"
  printf 'Tunnel 名称: %s\nTunnel ID: %s\n' "$CF_TUNNEL_NAME" "$CF_TUNNEL_ID"
  printf 'Zone: %s\n域名: %s\n' "$CF_ZONE" "$CF_HOSTNAME"
  printf '回源: 127.0.0.1:%s%s\n协议: %s\n已启用: %s\n' "$CF_SERVICE_PORT" "$CF_SERVICE_PATH" "$CF_PROTOCOL" "$CF_ENABLED"
  printf '配置文件: %s [%s]\n' "$CF_CONFIG" "$([ -f "$CF_CONFIG" ] && printf '存在' || printf '缺失')"
  printf '凭据文件: %s [%s]\n' "$CF_CREDENTIALS" "$([ -f "$CF_CREDENTIALS" ] && printf '存在' || printf '缺失')"
  if state_ready 2>/dev/null; then green '状态一致性: 通过'; else yellow '状态一致性: 未通过'; fi
  case "$(service_mode)" in
    openrc) printf '服务: '; rc-service cloudflared status 2>&1 || true;;
    systemd) printf '服务: '; systemctl is-active cloudflared 2>&1 || true;;
    *) printf '服务: manual\n';;
  esac
  [ -f "$CF_CONFIG" ] && { printf '%s\n' 'Ingress 校验:'; validate_ingress 2>&1 || true; }
}


guided(){
  ensure_cloudflared || return 1
  load_env
  printf '%s\n' '===== Cloudflare Tunnel 一键流程 ====='

  if cert_is_valid; then
    green '已检测到有效 Cloudflare 授权证书，跳过登录'
  else
    login_cf || return 1
  fi

  load_env
  if valid_id "$CF_TUNNEL_ID" && [ -s "$CF_CREDENTIALS" ] && credential_matches_tunnel; then
    printf '检测到现有 Tunnel [%s]，是否复用？[Y/n]: ' "$CF_TUNNEL_NAME"
    read_line reuse || reuse=
    case "$reuse" in
      n|N)
        printf '输入 1 创建新 Tunnel，输入 2 选择已有 Tunnel [1]: '
        read_line act2 || act2=1
        case "$act2" in 2) select_tunnel || return 1;; *) create_tunnel || return 1;; esac;;
      *) green '复用现有 Tunnel';;
    esac
  else
    printf '%s\n' '未检测到可用 Tunnel'
    printf '输入 1 创建新 Tunnel，输入 2 选择已有 Tunnel [1]: '
    read_line action || action=1
    case "$action" in 2) select_tunnel || return 1;; *) create_tunnel || return 1;; esac
  fi

  load_env
  if [ -f "$CF_CONFIG" ] && config_matches_state && [ -n "$CF_ZONE" ] && [ -n "$CF_HOSTNAME" ]; then
    printf '检测到与当前 Tunnel 匹配的 Ingress 配置，是否保留？[Y/n]: '
    read_line keep_config || keep_config=
    case "$keep_config" in n|N) configure_ingress || return 1;; *) green '保留现有 Ingress 配置';; esac
  else
    [ -f "$CF_CONFIG" ] && yellow '现有 Ingress 与当前 Tunnel 不匹配，将重新生成'
    configure_ingress || return 1
  fi

  validate_ingress || return 1
  origin_ready=0
  if check_origin; then
    origin_ready=1
  else
    yellow "本地回源 127.0.0.1:$CF_SERVICE_PORT$CF_SERVICE_PATH 当前未通过检查"
    yellow '仍会完成 Tunnel 和 DNS 部署；请先启动 sing-box，再运行 origin/public 复查链路'
  fi
  route_add || return 1
  start_tunnel || return 1
  if [ "$origin_ready" = 1 ]; then
    check_public || return 1
  else
    yellow '由于本地回源尚未就绪，已跳过公网 WebSocket 检查'
  fi
  info
  green 'Cloudflare Tunnel 一键流程完成'
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
    menu) interactive_menu;;
    guided) guided;;
    info) info;;
    *) red "未知命令: $1"; commands; return 2;;
  esac
}

main "$@"