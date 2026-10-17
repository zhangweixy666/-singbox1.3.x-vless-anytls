#!/bin/sh
# Re-authenticate Cloudflare locally without deleting or stopping existing Tunnels.
set -eu
umask 077

VERSION=1.1.0
CLOUDFLARED_VERSION=2026.10.1
CLOUDFLARED_SHA256_386=9f5794f4e0bf2a4be8b3a3b8cc97720f60b3686089e07cebfd90aa9826b31749
CLOUDFLARED_SHA256_AMD64=3bfc539f45d2620c71debb7a86be0efa737ed5ccbad9eb85c787116900e5c586
CLOUDFLARED_SHA256_ARM=598445dbe19d789d2901c57bb9df5b070cc2c4f817c48b0ae2702a93d15a468e
CLOUDFLARED_SHA256_ARM64=2c65dfabf616c40efc7545d107d7a57ad5e21377e2964b7e88af19a238074a46
CLOUDFLARED_SHA256_ARMHF=c047e24af9ed956b55d514e3a0e2d8020e9c6d0629c4731c8ec08bd79a29a050

CF_BIN=${CF_BIN:-/usr/local/bin/cloudflared}
CF_DIR=${CF_DIR:-${HOME:-/root}/.cloudflared}

red(){ printf '\033[31m[错误]\033[0m %s\n' "$*"; }
yellow(){ printf '\033[33m[警告]\033[0m %s\n' "$*"; }
green(){ printf '\033[32m[成功]\033[0m %s\n' "$*"; }
cyan(){ printf '\033[36m[信息]\033[0m %s\n' "$*"; }

root_check(){
  [ "$(id -u)" = 0 ] || { red '请使用 root 运行'; exit 1; }
}

read_line(){
  if [ -t 0 ] || [ -t 1 ]; then
    if IFS= read -r "$@" </dev/tty 2>/dev/null; then return 0; fi
  fi
  IFS= read -r "$@"
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
  if [ -f /etc/alpine-release ]; then
    apk add --no-cache curl ca-certificates coreutils python3 >/dev/null || {
      red 'Alpine 依赖安装失败'; return 1;
    }
  elif [ -f /etc/debian_version ]; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates coreutils python3 >/dev/null || {
      red 'Debian/Ubuntu 依赖安装失败'; return 1;
    }
  else
    for dep in curl python3 sha256sum; do
      command -v "$dep" >/dev/null 2>&1 || { red "缺少依赖: $dep"; return 1; }
    done
  fi
}

binary_version(){
  "$CF_BIN" version 2>&1 | sed -n '1s/.*version[[:space:]]\+\([^[:space:]]*\).*/\1/p'
}

install_fixed_binary(){
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
  actual_sha=$(sha256sum "$tmp/cloudflared" | awk '{print $1}')
  if [ "$actual_sha" != "$CF_EXPECTED_SHA" ]; then
    rm -rf "$tmp"
    red "cloudflared SHA-256 校验失败: 期望 $CF_EXPECTED_SHA，实际 $actual_sha"
    return 1
  fi
  chmod 755 "$tmp/cloudflared"
  actual_version=$("$tmp/cloudflared" version 2>&1 | sed -n '1s/.*version[[:space:]]\+\([^[:space:]]*\).*/\1/p')
  if [ "$actual_version" != "$CLOUDFLARED_VERSION" ]; then
    rm -rf "$tmp"
    red "cloudflared 版本校验失败: 期望 $CLOUDFLARED_VERSION，实际 ${actual_version:-未知}"
    return 1
  fi
  target="$CF_BIN.tmp.$$"
  install -m 755 "$tmp/cloudflared" "$target"
  mv -f "$target" "$CF_BIN"
  rm -rf "$tmp"
  green "cloudflared 已固定为 $CLOUDFLARED_VERSION"
}

ensure_fixed_binary(){
  arch_info || return 1
  if [ -x "$CF_BIN" ]; then
    actual_version=$(binary_version 2>/dev/null || true)
    actual_sha=$(sha256sum "$CF_BIN" 2>/dev/null | awk '{print $1}' || true)
    if [ "$actual_version" = "$CLOUDFLARED_VERSION" ] && [ "$actual_sha" = "$CF_EXPECTED_SHA" ]; then
      return 0
    fi
    yellow "当前 cloudflared 不是固定版本，将安装 $CLOUDFLARED_VERSION"
  else
    cyan "未找到 cloudflared，将安装固定版本 $CLOUDFLARED_VERSION"
  fi
  install_fixed_binary
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

confirm_reset(){
  yes=0
  for arg in "$@"; do
    case "$arg" in
      --yes) yes=1;;
      *) red "未知参数: $arg"; exit 2;;
    esac
  done
  [ "$yes" = 1 ] && return 0
  printf '%s\n' \
    '本操作只会重新生成本机 Cloudflare cert.pem。' \
    '不会删除、停止或修改 Cloudflare 账号内已有的 Tunnel。' \
    '不会删除本机 Tunnel JSON、config.yml 或服务配置。'
  printf '请输入 RESET-LOCAL-CLOUDFLARED 确认：'
  read_line answer || answer=
  [ "$answer" = RESET-LOCAL-CLOUDFLARED ] || {
    yellow '确认字符串不匹配，已取消'
    exit 1
  }
}

relogin_cloudflare(){
  mkdir -p "$CF_DIR"
  chmod 700 "$CF_DIR"
  backup_cert
  rm -f "$CF_DIR/cert.pem"
  yellow '旧 cert.pem 已备份，请在浏览器中完成 Cloudflare 授权'
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
  green 'Cloudflare 重新授权成功'
}

main(){
  root_check
  confirm_reset "$@"
  ensure_fixed_binary || exit 1
  if relogin_cloudflare; then
    green "本机 Cloudflare 授权已重置，Tunnel 未被删除或停止（cloudflared=$CLOUDFLARED_VERSION）"
    green '现在可以运行 /usr/local/bin/cloudflared-manager.sh guided'
    exit 0
  fi
  exit 1
}

main "$@"
