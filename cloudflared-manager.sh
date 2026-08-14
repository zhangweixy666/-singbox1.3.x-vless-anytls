#!/bin/sh
# cloudflared-manager.sh - Cloudflare Tunnel 完整配置工具
# 支持 Alpine/OpenRC、BusyBox inittab、Debian/Ubuntu/systemd

VERSION="1.0.0"
CF_DIR=/root/.cloudflared
CF_CONFIG="$CF_DIR/config.yml"
CF_ENV=/etc/cloudflared-manager.env
CF_API_ENV=/etc/cloudflared-manager.api
CF_LOG_DIR=/var/log/cloudflared
CF_LOG="$CF_LOG_DIR/tunnel.log"
CF_SUPERVISOR=/usr/local/sbin/cloudflared-supervisor.sh
CF_PIDFILE=/run/cloudflared-supervisor.pid
CF_OPENRC=/etc/init.d/cloudflared
CF_SYSTEMD=/etc/systemd/system/cloudflared.service
SINGBOX_CONFIG=/etc/sing-box/config.json
SINGBOX_BIN=/usr/local/bin/sing-box

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok(){ printf "${G}[成功]${N} %s\n" "$*"; }
info(){ printf "${C}[信息]${N} %s\n" "$*"; }
warn(){ printf "${Y}[警告]${N} %s\n" "$*"; }
err(){ printf "${R}[错误]${N} %s\n" "$*"; }
pause(){ printf '\n按回车键返回菜单...'; read _dummy; }
root_check(){ [ "$(id -u)" = 0 ] || { err '请使用 root 运行'; exit 1; }; }
detect_system(){
    if [ -f /etc/alpine-release ]; then OS='Alpine Linux'; INIT=openrc; PM=apk
    elif [ -f /etc/debian_version ]; then OS='Debian/Ubuntu'; INIT=systemd; PM=apt-get
    else OS='其他 Linux'; INIT=unknown; PM=; fi
}
arch_asset(){ case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; armv7l) echo arm;; *) return 1;; esac; }
find_bin(){ [ -x /root/cloudflared-linux ] && { echo /root/cloudflared-linux; return; }; [ -x /usr/local/bin/cloudflared ] && { echo /usr/local/bin/cloudflared; return; }; command -v cloudflared 2>/dev/null || echo /usr/local/bin/cloudflared; }
CF_BIN=$(find_bin)
CF_TUNNEL_ID=; CF_TUNNEL_NAME=; CF_CREDENTIALS=; CF_ZONE=; CF_HOSTNAME=
CF_SERVICE_PORT=20008; CF_SERVICE_PATH=/ws; CF_PROTOCOL=auto; CF_ENABLED=0

load_env(){
    CF_TUNNEL_ID=; CF_TUNNEL_NAME=; CF_CREDENTIALS=; CF_ZONE=; CF_HOSTNAME=
    CF_SERVICE_PORT=20008; CF_SERVICE_PATH=/ws; CF_PROTOCOL=auto; CF_ENABLED=0
    [ -r "$CF_ENV" ] && . "$CF_ENV"
}
save_env(){
    umask 077; mkdir -p "$(dirname "$CF_ENV")"
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
ask(){ _var=$1; _prompt=$2; _default=$3; printf '%s' "$_prompt"; IFS= read -r _ans || _ans=; [ -n "$_ans" ] || _ans=$_default; eval "$_var=\"$_ans\""; }
valid_id(){ case "$1" in ????????-????-????-????-????????????) return 0;; *) return 1;; esac; }
valid_port(){ case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }
valid_host(){ case "$1" in ''|*[!A-Za-z0-9.-]*) return 1;; esac; return 0; }
valid_path(){ case "$1" in /*) return 0;; *) return 1;; esac; }

ensure_deps(){
    if [ "$PM" = apk ]; then apk add --no-cache curl ca-certificates procps iproute2 bind-tools python3 >/dev/null 2>&1 || true
    elif [ "$PM" = apt-get ]; then apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates procps iproute2 dnsutils python3 >/dev/null 2>&1 || true; fi
}
install_cloudflared(){
    ensure_deps; asset=$(arch_asset) || { err "不支持架构: $(uname -m)"; return 1; }
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT INT TERM
    curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$asset" -o "$tmp/cloudflared" || { err 'cloudflared 下载失败'; return 1; }
    install -m 755 "$tmp/cloudflared" /usr/local/bin/cloudflared; CF_BIN=/usr/local/bin/cloudflared
    trap - EXIT INT TERM; rm -rf "$tmp"; "$CF_BIN" version; ok "cloudflared 已安装: $CF_BIN"
}
require_bin(){ CF_BIN=$(find_bin); [ -x "$CF_BIN" ] || install_cloudflared; }
login_cf(){
    require_bin || return 1; mkdir -p "$CF_DIR"; chmod 700 "$CF_DIR"
    info '请复制命令输出的授权链接，在浏览器完成 Cloudflare 授权。'
    "$CF_BIN" tunnel login
    [ -s "$CF_DIR/cert.pem" ] || { err '没有生成 cert.pem，授权未完成'; return 1; }
    chmod 600 "$CF_DIR/cert.pem"; ok "授权成功: $CF_DIR/cert.pem"
}
list_tunnels(){ require_bin || return 1; "$CF_BIN" tunnel list; }
create_tunnel(){
    require_bin || return 1; load_env
    ask CF_TUNNEL_NAME 'Tunnel 名称 [singbox-tunnel]: ' "${CF_TUNNEL_NAME:-singbox-tunnel}"
    case "$CF_TUNNEL_NAME" in ''|*[!A-Za-z0-9._-]*) err '名称只能包含字母、数字、点、下划线、短横线'; return 1;; esac
    out=$("$CF_BIN" tunnel create "$CF_TUNNEL_NAME" 2>&1) || { printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out"
    CF_TUNNEL_ID=$(printf '%s\n' "$out" | sed -n 's/.*id[[:space:]]\+\([0-9a-f-]\{36\}\).*/\1/p' | head -1)
    valid_id "$CF_TUNNEL_ID" || ask CF_TUNNEL_ID '请复制 Tunnel ID: ' ''
    valid_id "$CF_TUNNEL_ID" || { err 'Tunnel ID 格式无效'; return 1; }
    CF_CREDENTIALS="$CF_DIR/$CF_TUNNEL_ID.json"; save_env; ok "Tunnel 已创建: $CF_TUNNEL_ID"
}
select_tunnel(){
    load_env; list_tunnels || true
    ask CF_TUNNEL_ID "Tunnel ID [${CF_TUNNEL_ID:-}]: " "$CF_TUNNEL_ID"
    valid_id "$CF_TUNNEL_ID" || { err 'Tunnel ID 格式无效'; return 1; }
    CF_CREDENTIALS="$CF_DIR/$CF_TUNNEL_ID.json"; [ -f "$CF_CREDENTIALS" ] || warn "凭证不存在: $CF_CREDENTIALS"; save_env
}
configure_ingress(){
    require_bin || return 1; load_env
    valid_id "$CF_TUNNEL_ID" || { err '请先创建或选择 Tunnel'; return 1; }
    ask CF_ZONE 'Cloudflare Zone，例如 ouyyy.qzz.io: ' "$CF_ZONE"
    valid_host "$CF_ZONE" || { err 'Zone 格式无效'; return 1; }
    ask CF_HOSTNAME "公网域名 [${CF_HOSTNAME:-cf-test.$CF_ZONE}]: " "${CF_HOSTNAME:-cf-test.$CF_ZONE}"
    valid_host "$CF_HOSTNAME" || { err '域名格式无效'; return 1; }
    case "$CF_HOSTNAME" in *.$CF_ZONE) ;; *) err "域名必须属于 Zone: $CF_ZONE"; return 1;; esac
    ask CF_SERVICE_PORT "本地回源端口 [$CF_SERVICE_PORT]: " "$CF_SERVICE_PORT"
    valid_port "$CF_SERVICE_PORT" || { err '端口无效'; return 1; }
    ask CF_SERVICE_PATH "WS 路径 [$CF_SERVICE_PATH]: " "$CF_SERVICE_PATH"
    valid_path "$CF_SERVICE_PATH" || { err 'WS 路径必须以 / 开头'; return 1; }
    ask CF_PROTOCOL 'Tunnel 协议 auto/quic/http2 [auto]: ' "$CF_PROTOCOL"
    case "$CF_PROTOCOL" in auto|quic|http2) ;; *) err '协议只能是 auto、quic 或 http2'; return 1;; esac
    mkdir -p "$CF_DIR"; tmp="$CF_CONFIG.tmp.$$"
    cat > "$tmp" <<EOF
tunnel: $CF_TUNNEL_ID
credentials-file: $CF_CREDENTIALS
ingress:
  - hostname: $CF_HOSTNAME
    service: http://127.0.0.1:$CF_SERVICE_PORT
  - service: http_status:404
EOF
    mv "$tmp" "$CF_CONFIG"; chmod 600 "$CF_CONFIG"
    "$CF_BIN" --config "$CF_CONFIG" tunnel ingress validate || return 1
    CF_ENABLED=1; save_env; ok "Ingress 已保存: $CF_CONFIG"
}
validate_ingress(){
    require_bin || return 1; load_env; [ -f "$CF_CONFIG" ] || { err "配置不存在: $CF_CONFIG"; return 1; }
    "$CF_BIN" --config "$CF_CONFIG" tunnel ingress validate || return 1
    [ -n "$CF_HOSTNAME" ] && "$CF_BIN" --config "$CF_CONFIG" tunnel ingress rule "https://$CF_HOSTNAME$CF_SERVICE_PATH"
}
route_add(){
    require_bin || return 1; load_env
    valid_id "$CF_TUNNEL_ID" || { err '未配置 Tunnel ID'; return 1; }
    case "$CF_HOSTNAME" in *.$CF_ZONE) ;; *) err '域名不属于当前 Zone'; return 1;; esac
    "$CF_BIN" tunnel route dns --overwrite-dns "$CF_TUNNEL_ID" "$CF_HOSTNAME" && ok "DNS 路由已添加: $CF_HOSTNAME"
}
load_api(){ [ -r "$CF_API_ENV" ] && . "$CF_API_ENV"; }
ask_api(){
    load_api
    [ -n "${CF_API_TOKEN:-}" ] || { printf '请输入 Cloudflare API Token（输入不可回显）: '; IFS= read -r CF_API_TOKEN; [ -n "$CF_API_TOKEN" ] || return 1; umask 077; printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" > "$CF_API_ENV"; chmod 600 "$CF_API_ENV"; }
    export CF_API_TOKEN
}
zone_id(){
    ask_api || return 1; curl -fsS -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE&status=active" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("result") else "")'
}
route_delete(){
    load_env; [ -n "$CF_ZONE" ] && [ -n "$CF_HOSTNAME" ] || { err '请先配置 Zone 和域名'; return 1; }
    zid=$(zone_id) || { err '需要 API Token 才能删除 DNS 记录'; return 1; }; [ -n "$zid" ] || { err '找不到 Zone ID，请检查 Zone 和 Token'; return 1; }
    records=$(curl -fsS -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=CNAME&name=$CF_HOSTNAME" | python3 -c 'import json,sys; print(" ".join(x["id"] for x in json.load(sys.stdin).get("result",[])))')
    [ -n "$records" ] || { warn '没有找到该 CNAME 记录'; return 0; }
    for rid in $records; do curl -fsS -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rid" >/dev/null || return 1; done
    ok "DNS 路由已删除: $CF_HOSTNAME"
}
write_supervisor(){
    mkdir -p "$CF_LOG_DIR" "$(dirname "$CF_SUPERVISOR")"
    cat > "$CF_SUPERVISOR" <<'EOF'
#!/bin/sh
BIN=$1; CONFIG=$2; TUNNEL=$3; LOG=$4; PIDFILE=$5; PROTOCOL=$6
mkdir -p "$(dirname "$LOG")" "$(dirname "$PIDFILE")"
if [ -f "$PIDFILE" ]; then old=$(cat "$PIDFILE" 2>/dev/null); [ -n "$old" ] && kill -0 "$old" 2>/dev/null && exit 0; rm -f "$PIDFILE"; fi
echo $$ > "$PIDFILE"; child=
stop_all(){ [ -n "$child" ] && kill "$child" 2>/dev/null || true; rm -f "$PIDFILE"; exit 0; }
trap stop_all INT TERM HUP
while :; do
  printf '%s starting tunnel %s\n' "$(date '+%F %T')" "$TUNNEL" >> "$LOG"
  if [ "$PROTOCOL" = auto ]; then "$BIN" --config "$CONFIG" tunnel run "$TUNNEL" >> "$LOG" 2>&1 &
  else "$BIN" --config "$CONFIG" --protocol "$PROTOCOL" tunnel run "$TUNNEL" >> "$LOG" 2>&1 & fi
  child=$!; wait "$child"; code=$?; child=
  printf '%s cloudflared exited code=%s; restart after 3 seconds\n' "$(date '+%F %T')" "$code" >> "$LOG"
  sleep 3
done
EOF
    chmod 755 "$CF_SUPERVISOR"
}
service_mode(){ command -v rc-service >/dev/null 2>&1 && { echo openrc; return; }; [ -d /run/systemd/system ] && { echo systemd; return; }; [ -f /etc/inittab ] && { echo inittab; return; }; echo manual; }
write_openrc(){
    cat > "$CF_OPENRC" <<EOF
#!/sbin/openrc-run
name="cloudflared"
description="Cloudflare Tunnel supervisor"
command="$CF_SUPERVISOR"
command_args="$CF_BIN $CF_CONFIG $CF_TUNNEL_ID $CF_LOG $CF_PIDFILE $CF_PROTOCOL"
command_background="yes"
pidfile="$CF_PIDFILE"
output_log="$CF_LOG"
error_log="$CF_LOG"
depend(){ need net; after firewall; }
EOF
    chmod 755 "$CF_OPENRC"; rc-update add cloudflared default >/dev/null 2>&1 || true
}
write_systemd(){
    mkdir -p /etc/systemd/system
    cat > "$CF_SYSTEMD" <<EOF
[Unit]
Description=Cloudflare Tunnel supervisor
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$CF_SUPERVISOR $CF_BIN $CF_CONFIG $CF_TUNNEL_ID $CF_LOG $CF_PIDFILE $CF_PROTOCOL
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable cloudflared >/dev/null 2>&1 || true
}
start_tunnel(){
    require_bin || return 1; load_env
    [ "$CF_ENABLED" = 1 ] || { err '请先完成 Tunnel 配置'; return 1; }
    [ -f "$CF_CONFIG" ] || { err '配置文件不存在'; return 1; }; [ -f "$CF_CREDENTIALS" ] || { err "凭证不存在: $CF_CREDENTIALS"; return 1; }
    write_supervisor
    case "$(service_mode)" in openrc) write_openrc; rc-service cloudflared restart >/dev/null 2>&1 || rc-service cloudflared start;; systemd) write_systemd; systemctl restart cloudflared;; inittab) echo "::respawn:$CF_SUPERVISOR $CF_BIN $CF_CONFIG $CF_TUNNEL_ID $CF_LOG $CF_PIDFILE $CF_PROTOCOL" >> /etc/inittab; init q;; manual) "$CF_SUPERVISOR" "$CF_BIN" "$CF_CONFIG" "$CF_TUNNEL_ID" "$CF_LOG" "$CF_PIDFILE" "$CF_PROTOCOL" >/dev/null 2>&1 &;; esac
    ok "Tunnel 已启动，自启方式: $(service_mode)，崩溃后 3 秒重启"
}
stop_tunnel(){
    case "$(service_mode)" in openrc) rc-service cloudflared stop >/dev/null 2>&1 || true;; systemd) systemctl stop cloudflared >/dev/null 2>&1 || true;; inittab) sed -i "\|$CF_SUPERVISOR|d" /etc/inittab 2>/dev/null || true; init q >/dev/null 2>&1 || true;; esac
    [ -f "$CF_PIDFILE" ] && kill "$(cat "$CF_PIDFILE")" 2>/dev/null || true
    pkill -f "$CF_SUPERVISOR" 2>/dev/null || true; ok 'Tunnel 已停止'
}
restart_tunnel(){ stop_tunnel; sleep 1; start_tunnel; }
status_tunnel(){
    load_env; printf '\n========== Cloudflare Tunnel 状态 ==========\n'; printf '系统：%s（%s）\n启用：%s\n二进制：%s\nTunnel ID：%s\nZone：%s\n域名：%s\n回源：127.0.0.1:%s\n路径：%s\n协议：%s\n' "$OS" "$INIT" "$CF_ENABLED" "$CF_BIN" "$CF_TUNNEL_ID" "$CF_ZONE" "$CF_HOSTNAME" "$CF_SERVICE_PORT" "$CF_SERVICE_PATH" "$CF_PROTOCOL"
    pgrep -af 'cloudflared|cloudflared-supervisor' 2>/dev/null || warn '没有 cloudflared 进程'
    [ -f "$CF_CONFIG" ] && "$CF_BIN" --config "$CF_CONFIG" tunnel ingress rule "https://$CF_HOSTNAME$CF_SERVICE_PATH" 2>&1 || true
    [ -f "$CF_LOG" ] && tail -n 20 "$CF_LOG"
}
info_tunnel(){ require_bin || return 1; load_env; valid_id "$CF_TUNNEL_ID" || { err '未配置 Tunnel ID'; return 1; }; "$CF_BIN" tunnel info "$CF_TUNNEL_ID"; }
check_dns(){ load_env; [ -n "$CF_HOSTNAME" ] || { err '未配置域名'; return 1; }; dig +short CNAME "$CF_HOSTNAME" 2>/dev/null || nslookup "$CF_HOSTNAME" 2>/dev/null; }
check_origin(){ load_env; valid_port "$CF_SERVICE_PORT" || return 1; ss -lntp 2>/dev/null | grep -E ":$CF_SERVICE_PORT([[:space:]]|$)" || warn "端口 $CF_SERVICE_PORT 未监听"; curl -sv --connect-timeout 5 "http://127.0.0.1:$CF_SERVICE_PORT$CF_SERVICE_PATH" 2>&1 | head -n 20; }
check_public(){ load_env; [ -n "$CF_HOSTNAME" ] || { err '未配置域名'; return 1; }; curl -vk --connect-timeout 10 "https://$CF_HOSTNAME$CF_SERVICE_PATH" 2>&1 | head -n 30; }
edit_tunnel_config(){ load_env; mkdir -p "$CF_DIR"; ${EDITOR:-vi} "$CF_CONFIG"; validate_ingress; }
edit_json(){
    [ -f "$SINGBOX_CONFIG" ] || { err "不存在: $SINGBOX_CONFIG"; return 1; }
    cp -p "$SINGBOX_CONFIG" "$SINGBOX_CONFIG.bak.$(date +%Y%m%d-%H%M%S)"; ${EDITOR:-vi} "$SINGBOX_CONFIG"
    [ -x "$SINGBOX_BIN" ] && "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" || true
    if command -v rc-service >/dev/null 2>&1; then rc-service sing-box restart >/dev/null 2>&1 || true; fi
    ok 'sing-box JSON 已检查并尝试重启'
}
links(){
    load_env; [ "$CF_ENABLED" = 1 ] || { warn '请先配置 Tunnel'; return 0; }
    printf '\nCloudflare 公网参数:\n地址: %s\n端口: 443\nTLS: 开启\nSNI: %s\nWS 路径: %s\n' "$CF_HOSTNAME" "$CF_HOSTNAME" "$CF_SERVICE_PATH"
    [ -r /etc/sing-box/params.env ] && grep -E '^(VLESS_WS_UUID|VMESS_WS_UUID|VLESS_WS_PATH|VMESS_WS_PATH)=' /etc/sing-box/params.env
    warn '以上端口固定为 443；回源端口可在菜单中按每台 VPS 单独配置。'
}
commands(){
    printf '\n========== 常用命令 ==========\n'
    printf '%s\n' \
        "$0 guided" "$0 login" "$0 list" "$0 create" "$0 select" \
        "$0 configure" "$0 dns-add" "$0 dns-delete" "$0 validate" \
        "$0 start" "$0 stop" "$0 restart" "$0 status" "$0 info" \
        "$0 origin" "$0 public" "$0 links" "$0 json" "$0 logs"
    printf '\n原生 cloudflared:\n'
    printf '%s\n' \
        "$CF_BIN tunnel list" \
        "$CF_BIN tunnel info ID" \
        "$CF_BIN tunnel route dns ID HOSTNAME" \
        "$CF_BIN --config $CF_CONFIG tunnel run ID" \
        "tail -f $CF_LOG" \
        "dig HOSTNAME CNAME +short"
}
guided(){
    require_bin || return 1; load_env; [ -s "$CF_DIR/cert.pem" ] || login_cf || return 1
    printf '创建新的 Tunnel? [Y/n]: '; read a; case "$a" in n|N) select_tunnel;; *) create_tunnel;; esac || return 1
    configure_ingress || return 1; printf '添加 DNS 路由? [Y/n]: '; read a; case "$a" in n|N) ;; *) route_add;; esac || return 1
    start_tunnel || return 1; check_origin; check_dns; status_tunnel; links
}
menu(){
    while :; do
        load_env
        printf '\033c'; printf '========================================\n'; printf '       Cloudflare Tunnel 工具 v%s\n' "$VERSION"; printf '========================================\n'; printf '系统：%s（%s）\nTunnel：%s\n域名：%s\n回源：127.0.0.1:%s\n\n' "$OS" "$INIT" "${CF_TUNNEL_ID:-未配置}" "${CF_HOSTNAME:-未配置}" "$CF_SERVICE_PORT"
        printf '  1) 一键完整流程（登录/创建/配置/DNS/自启/验证）\n  2) Cloudflare 登录授权\n  3) 安装或更新 cloudflared\n  4) 查看 Tunnel 列表\n  5) 创建 Tunnel\n  6) 选择已有 Tunnel\n  7) 配置 Zone/域名/回源端口/WS路径\n  8) 编辑 Tunnel config.yml\n  9) 添加或覆盖 DNS 路由\n 10) 删除 DNS 路由（API Token）\n 11) 校验配置和规则\n 12) 启动并设置自启\n 13) 停止 Tunnel\n 14) 重启 Tunnel\n 15) 查看状态/连接/日志\n 16) 查看 Tunnel 详细信息\n 17) 检查本地回源\n 18) 检查公网链路\n 19) 输出客户端参数\n 20) 编辑并校验 sing-box JSON\n 21) 常用命令\n 22) 删除 Tunnel\n  0) 退出\n\n请选择 [0-22]：'; read c
        case "$c" in 1) guided; pause;; 2) login_cf; pause;; 3) install_cloudflared; pause;; 4) list_tunnels; pause;; 5) create_tunnel; pause;; 6) select_tunnel; pause;; 7) configure_ingress; pause;; 8) edit_tunnel_config; pause;; 9) route_add; pause;; 10) route_delete; pause;; 11) validate_ingress; pause;; 12) start_tunnel; pause;; 13) stop_tunnel; pause;; 14) restart_tunnel; pause;; 15) status_tunnel; pause;; 16) info_tunnel; pause;; 17) check_origin; pause;; 18) check_public; pause;; 19) links; pause;; 20) edit_json; pause;; 21) commands; pause;; 22) delete_tunnel; pause;; 0) return;; *) warn '无效选项'; sleep 1;; esac
    done
}
delete_tunnel(){ require_bin || return 1; load_env; valid_id "$CF_TUNNEL_ID" || { err '未配置有效 Tunnel'; return 1; }; printf '确认删除 Tunnel %s？[y/N] ' "$CF_TUNNEL_ID"; read a; case "$a" in y|Y) stop_tunnel; "$CF_BIN" tunnel cleanup "$CF_TUNNEL_ID" >/dev/null 2>&1 || true; "$CF_BIN" tunnel delete "$CF_TUNNEL_ID"; rm -f "$CF_CREDENTIALS" "$CF_CONFIG"; CF_ENABLED=0; save_env; ok 'Tunnel 已删除';; *) warn '已取消';; esac; }
root_check; detect_system; load_env
case "${1:-menu}" in guided) guided;; login) login_cf;; install) install_cloudflared;; list) list_tunnels;; create) create_tunnel;; select) select_tunnel;; configure) configure_ingress;; dns-add) route_add;; dns-delete) route_delete;; validate) validate_ingress;; start) start_tunnel;; stop) stop_tunnel;; restart) restart_tunnel;; status) status_tunnel;; info) info_tunnel;; origin) check_origin;; public) check_public;; links) links;; json) edit_json;; commands) commands;; delete) delete_tunnel;; menu) menu;; *) commands; exit 2;; esac