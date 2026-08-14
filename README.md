# sing-box 1.13.14 管理脚本

支持 Debian、Ubuntu、Alpine，以及 LXC 环境。

功能包括：

- AnyTLS
- TUIC
- Hysteria2
- VLESS + WebSocket
- VMess + WebSocket
- VLESS + Reality
- 自签证书与 Cloudflare DNS API ACME 证书
- Cloudflare Tunnel 管理与 OpenRC/systemd 自启监督

## 安装

### Debian / Ubuntu

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/singbox-manager.sh)
```

或：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/singbox-manager.sh)
```

### Alpine

```bash
apk add --no-cache bash curl
bash <(curl -fsSL https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/singbox-manager.sh)
```

## Cloudflare Tunnel

`cloudflared-manager.sh` 提供 Cloudflare Tunnel 的完整管理流程：

```bash
curl -fsSL https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/cloudflared-manager.sh -o /usr/local/bin/cloudflared-manager.sh
chmod +x /usr/local/bin/cloudflared-manager.sh
/usr/local/bin/cloudflared-manager.sh guided
```

常用命令：

```bash
cloudflared-manager.sh status
cloudflared-manager.sh restart
cloudflared-manager.sh origin
cloudflared-manager.sh public
cloudflared-manager.sh links
```

该工具会：

1. 安装或更新 cloudflared；
2. 进行 Cloudflare 授权；
3. 创建或选择 Tunnel；
4. 配置域名、回源端口和 WebSocket 路径；
5. 创建 DNS 路由；
6. 使用 OpenRC 或 systemd 设置开机自启；
7. 通过监督脚本在 cloudflared 退出后自动重启。

Cloudflare Tunnel 对外固定使用 HTTPS 443；本地回源可配置为 sing-box 的 VLESS/WS 或 VMess/WS 监听端口。