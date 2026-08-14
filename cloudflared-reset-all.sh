#!/bin/sh
# cloudflared-reset-all.sh
# 删除当前 Cloudflare 账号下全部 Tunnel，并清理本机 Tunnel 状态。
# 不删除 sing-box 配置、节点参数或证书。
#
# 交互执行：
#   sh cloudflared-reset-all.sh
#
# 无确认执行：
#   sh cloudflared-reset-all.sh --yes

set -u

CF_BIN="${CF_BIN:-/usr/local/bin/cloudflared}"
CF_DIR="${HOME:-/root}/.cloudflared"
CF_ENV="/etc/cloudflared-manager.env"
CF_API_ENV="/etc/cloudflared-manager.api"
CF_OPENRC="/etc/init.d/cloudflared"
CF_SYSTEMD="/etc/systemd/system/cloudflared.service"
CF_SUPERVISOR="/usr/local/sbin/cloudflared-supervisor.sh"
CF_PIDFILE="/run/cloudflared-supervisor.pid"
CF_DIRECT_PIDFILE="/run/cloudflared-direct.pid"

red() { printf '\033[31m[错误]\033[0m %s\n' "$*"; }
yellow() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
green() { printf '\033[32m[成功]\033[0m %s\n' "$*"; }

root_check() {
    [ "$(id -u)" = 0 ] || {
        red "请使用 root 运行"
        exit 1
    }
}

find_cloudflared() {
    if [ -x "$CF_BIN" ]; then
        return 0
    fi
    CF_BIN="$(command -v cloudflared 2>/dev/null || true)"
    [ -x "$CF_BIN" ] || {
        red "找不到 cloudflared"
        exit 1
    }
}

confirm_reset() {
    if [ "${1:-}" = "--yes" ]; then
        return 0
    fi

    printf '%s\n' \
        "危险操作：这会删除当前 Cloudflare 账号下的全部 Tunnel。" \
        "同时停止本机 cloudflared，并清理本机 Tunnel 配置、凭据和服务文件。" \
        "不会删除 sing-box 配置、节点参数或证书。" \
        ""
    printf '请输入 DELETE-ALL-TUNNELS 确认：'
    IFS= read -r answer || answer=
    [ "$answer" = "DELETE-ALL-TUNNELS" ] || {
        yellow "确认字符串不匹配，已取消"
        exit 1
    }
}

stop_local_services() {
    if command -v rc-service >/dev/null 2>&1; then
        rc-service cloudflared stop >/dev/null 2>&1 || true
        rc-update del cloudflared default >/dev/null 2>&1 || true
        rc-service cloudflared zap >/dev/null 2>&1 || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop cloudflared >/dev/null 2>&1 || true
        systemctl disable cloudflared >/dev/null 2>&1 || true
    fi

    for pidfile in "$CF_PIDFILE" "$CF_DIRECT_PIDFILE"; do
        if [ -s "$pidfile" ]; then
            pid="$(cat "$pidfile" 2>/dev/null || true)"
            case "$pid" in
                ''|*[!0-9]*) ;;
                *) kill "$pid" >/dev/null 2>&1 || true ;;
            esac
        fi
        rm -f "$pidfile"
    done

    pkill -x cloudflared >/dev/null 2>&1 || true
    pkill -f "$CF_SUPERVISOR" >/dev/null 2>&1 || true
}

list_ids() {
    "$CF_BIN" tunnel list --output json 2>/dev/null |
        python3 -c '
import json, sys
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

delete_all_tunnels() {
    ids="$(list_ids 2>/dev/null || true)"

    if [ -z "$ids" ]; then
        yellow "未读取到 Tunnel 列表，未执行远端删除"
        return 1
    fi

    failed=0
    count=0
    old_ifs=$IFS
    IFS='
'
    for tunnel_id in $ids; do
        IFS=$old_ifs
        case "$tunnel_id" in
            ????????-????-????-????-????????????) ;;
            *) continue ;;
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
        IFS='
'
    done
    IFS=$old_ifs

    printf '共处理 %s 个 Tunnel\n' "$count"
    [ "$failed" = 0 ]
}

clean_local_state() {
    rm -f \
        "$CF_ENV" \
        "$CF_API_ENV" \
        "$CF_OPENRC" \
        "$CF_SYSTEMD" \
        "$CF_SUPERVISOR" \
        "$CF_PIDFILE" \
        "$CF_DIRECT_PIDFILE"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 删除 Tunnel 配置、Tunnel JSON 凭据和日志；保留 cert.pem 以便后续继续授权。
    rm -f "$CF_DIR/config.yml" "$CF_DIR"/*.json
    rm -rf /var/log/cloudflared
}

main() {
    root_check
    find_cloudflared
    confirm_reset "${1:-}"
    stop_local_services

    if delete_all_tunnels; then
        clean_local_state
        green "全部 Cloudflare Tunnel 已删除，本机 Tunnel 状态已清理"
        green "Cloudflare 授权证书 cert.pem 已保留"
        exit 0
    fi

    yellow "远端 Tunnel 未全部删除，因此保留本机状态文件，便于重试"
    exit 1
}

main "$@"