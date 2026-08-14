#!/bin/sh
# Delete every Tunnel in the current Cloudflare account.
# This destructive operation requires --all; unattended mode additionally requires --yes.
set -eu
umask 077

CF_BIN=${CF_BIN:-/usr/local/bin/cloudflared}
CF_DIR=${HOME:-/root}/.cloudflared
CF_ENV=/etc/cloudflared-manager.env
CF_API_ENV=/etc/cloudflared-manager.api
CF_OPENRC=/etc/init.d/cloudflared
CF_SYSTEMD=/etc/systemd/system/cloudflared.service
CF_SUPERVISOR=/usr/local/sbin/cloudflared-supervisor.sh
CF_PIDFILE=/run/cloudflared-supervisor.pid

red(){ printf '\033[31m[错误]\033[0m %s\n' "$*"; }
yellow(){ printf '\033[33m[警告]\033[0m %s\n' "$*"; }
green(){ printf '\033[32m[成功]\033[0m %s\n' "$*"; }

root_check(){ [ "$(id -u)" = 0 ] || { red '请使用 root 运行'; exit 1; }; }

find_cloudflared(){
  if [ ! -x "$CF_BIN" ]; then
    found=$(command -v cloudflared 2>/dev/null || true)
    [ -n "$found" ] && CF_BIN=$found
  fi
  [ -x "$CF_BIN" ] || { red '找不到 cloudflared'; exit 1; }
}

confirm_reset(){
  all=0
  yes=0
  for arg in "$@"; do
    case "$arg" in
      --all) all=1;;
      --yes) yes=1;;
      *) red "未知参数: $arg"; exit 2;;
    esac
  done

  [ "$all" = 1 ] || {
    red "这是删除当前账号全部 Tunnel 的破坏性操作"
    red "如确认执行，请使用: $0 --all"
    exit 2
  }

  [ "$yes" = 1 ] && return 0

  printf '%s\n' \
    '危险操作：这会删除当前 Cloudflare 账号下的全部 Tunnel。' \
    '同时停止本机 cloudflared，并清理本机 Tunnel 配置、凭据和服务文件。' \
    '不会删除 sing-box 配置、节点参数或证书。'
  printf '请输入 DELETE-ALL-TUNNELS 确认：'
  IFS= read -r answer || answer=
  [ "$answer" = DELETE-ALL-TUNNELS ] || {
    yellow '确认字符串不匹配，已取消'
    exit 1
  }
}

stop_local_services(){
  if command -v rc-service >/dev/null 2>&1; then
    rc-service cloudflared stop >/dev/null 2>&1 || true
    rc-update del cloudflared default >/dev/null 2>&1 || true
    rc-service cloudflared zap >/dev/null 2>&1 || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop cloudflared >/dev/null 2>&1 || true
    systemctl disable cloudflared >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if [ -s "$CF_PIDFILE" ]; then
    pid=$(cat "$CF_PIDFILE" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true;; esac
  fi
  rm -f "$CF_PIDFILE"

  # Only match the exact executable name, not arbitrary command lines.
  pkill -x cloudflared >/dev/null 2>&1 || true
}

list_ids(){
  "$CF_BIN" tunnel list --output json 2>/dev/null |
    python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if isinstance(data, list):
    items = data
elif isinstance(data, dict):
    items = data.get("result") or data.get("tunnels") or []
else:
    items = []

for item in items:
    if isinstance(item, dict) and item.get("id"):
        print(item["id"])
'
}

delete_all_tunnels(){
  ids_file=$(mktemp)
  trap 'rm -f "$ids_file"' EXIT INT TERM

  if ! list_ids > "$ids_file"; then
    rm -f "$ids_file"
    yellow '读取 Tunnel 列表失败，未执行远端删除'
    return 1
  fi

  failed=0
  count=0
  while IFS= read -r tunnel_id; do
    [ -n "$tunnel_id" ] || continue
    case "$tunnel_id" in
      ????????-????-????-????-????????????) ;;
      *) yellow "忽略无效 Tunnel ID: $tunnel_id"; continue;;
    esac

    count=$((count + 1))
    printf '删除 Tunnel %s ...\n' "$tunnel_id"
    "$CF_BIN" tunnel cleanup "$tunnel_id" >/dev/null 2>&1 || true
    if "$CF_BIN" tunnel delete "$tunnel_id" >/dev/null 2>&1; then
      green "已删除 $tunnel_id"
    else
      red "删除失败 $tunnel_id"
      failed=1
    fi
  done < "$ids_file"

  rm -f "$ids_file"
  trap - EXIT INT TERM
  printf '共处理 %s 个 Tunnel\n' "$count"
  [ "$failed" = 0 ]
}

clean_local_state(){
  rm -f \
    "$CF_ENV" \
    "$CF_API_ENV" \
    "$CF_OPENRC" \
    "$CF_SYSTEMD" \
    "$CF_SUPERVISOR" \
    "$CF_PIDFILE"

  rm -f "$CF_DIR/config.yml" "$CF_DIR"/*.json
  rm -rf /var/log/cloudflared

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

main(){
  root_check
  find_cloudflared
  confirm_reset "$@"
  stop_local_services

  if delete_all_tunnels; then
    clean_local_state
    green '全部 Cloudflare Tunnel 已删除，本机 Tunnel 状态已清理'
    green 'Cloudflare cert.pem 已保留'
    exit 0
  fi

  yellow '远端 Tunnel 未全部删除，本机状态文件已保留，便于重试'
  exit 1
}

main "$@"
