#!/bin/sh
# Re-authenticate Cloudflare locally without deleting or stopping existing Tunnels.
set -eu
umask 077

CF_BIN=${CF_BIN:-/usr/local/bin/cloudflared}
CF_DIR=${HOME:-/root}/.cloudflared

red(){ printf '\033[31m[错误]\033[0m %s\n' "$*"; }
yellow(){ printf '\033[33m[警告]\033[0m %s\n' "$*"; }
green(){ printf '\033[32m[成功]\033[0m %s\n' "$*"; }

root_check(){
  [ "$(id -u)" = 0 ] || { red '请使用 root 运行'; exit 1; }
}

find_cloudflared(){
  if [ ! -x "$CF_BIN" ]; then
    found=$(command -v cloudflared 2>/dev/null || true)
    [ -n "$found" ] && CF_BIN=$found
  fi
  [ -x "$CF_BIN" ] || { red '找不到 cloudflared'; exit 1; }
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
    '本操作只会删除 VPS 本机旧的 cert.pem 并重新登录 Cloudflare。' \
    '不会删除、停止或修改 Cloudflare 账号内已有的 Tunnel。' \
    '不会删除本机已有 Tunnel JSON 凭据、config.yml 或服务配置。'
  printf '请输入 RESET-LOCAL-CLOUDFLARED 确认：'
  IFS= read -r answer || answer=
  [ "$answer" = RESET-LOCAL-CLOUDFLARED ] || {
    yellow '确认字符串不匹配，已取消'
    exit 1
  }
}

relogin_cloudflare(){
  mkdir -p "$CF_DIR"
  chmod 700 "$CF_DIR"
  # 先备份旧证书，登录失败时恢复，避免丢失授权导致隧道不可用
  if [ -s "$CF_DIR/cert.pem" ]; then
    cp -a "$CF_DIR/cert.pem" "$CF_DIR/cert.pem.bak.$(date +%s)" 2>/dev/null || true
  fi
  rm -f "$CF_DIR/cert.pem"

  yellow '旧的 Cloudflare cert.pem 已备份并删除，请在浏览器中完成新的授权'
  if "$CF_BIN" login; then
    [ -s "$CF_DIR/cert.pem" ] || {
      red 'cloudflared login 未生成 cert.pem'
      # 恢复备份
      old=$(ls -t "$CF_DIR"/cert.pem.bak.* 2>/dev/null | head -n1 || true)
      [ -n "$old" ] && { cp -a "$old" "$CF_DIR/cert.pem" 2>/dev/null || true; green '已恢复原证书'; }
      return 1
    }
  else
    red 'cloudflared login 失败或未完成'
    # 恢复备份
    old=$(ls -t "$CF_DIR"/cert.pem.bak.* 2>/dev/null | head -n1 || true)
    [ -n "$old" ] && { cp -a "$old" "$CF_DIR/cert.pem" 2>/dev/null || true; green '已恢复原证书'; }
    return 1
  fi
  chmod 600 "$CF_DIR/cert.pem"
  green 'Cloudflare 重新授权成功'
}

main(){
  root_check
  find_cloudflared
  confirm_reset "$@"
  if relogin_cloudflare; then
    green '本机 Cloudflare 授权已重置，已有 Tunnel 未被删除或停止'
    green '现在可以运行 /usr/local/bin/cloudflared-manager.sh guided 创建新的 Tunnel'
    exit 0
  fi
  exit 1
}

main "$@"
