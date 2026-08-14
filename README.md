# sing-box 1.13.14 + Cloudflare Tunnel

本分支用于安全加固测试，适用于 Alpine/OpenRC、Debian/Ubuntu 等 Linux VPS。

## 安全使用原则

- 不要使用 `wget | sh` 或 `curl | sh`。
- 生产环境请固定到经过审查的 commit，而不是直接跟随 `main`。
- Tunnel 凭据、Cloudflare API Token、证书私钥不得提交到 GitHub。
- 全量删除 Tunnel 必须显式使用 `--all`，无人值守时再额外使用 `--yes`。

## 安装 sing-box 管理器

```sh
wget -O /root/singbox-manager.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/security-hardening/singbox-manager.sh
sh -n /root/singbox-manager.sh
chmod 700 /root/singbox-manager.sh
sh /root/singbox-manager.sh
```

## 安装 Cloudflare 管理器

```sh
wget -O /usr/local/bin/cloudflared-manager.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/security-hardening/cloudflared-manager.sh
sh -n /usr/local/bin/cloudflared-manager.sh
chmod 700 /usr/local/bin/cloudflared-manager.sh
/usr/local/bin/cloudflared-manager.sh guided
```

Cloudflare 管理器会把 WS 回源绑定到 `127.0.0.1`，由 cloudflared 访问本机服务。

常用命令：

```sh
/usr/local/bin/cloudflared-manager.sh status
/usr/local/bin/cloudflared-manager.sh validate
/usr/local/bin/cloudflared-manager.sh origin
/usr/local/bin/cloudflared-manager.sh public
/usr/local/bin/cloudflared-manager.sh restart
```

## Alpine/OpenRC

```sh
rc-service sing-box restart
rc-service sing-box status
rc-service cloudflared restart
rc-service cloudflared status
```

## 全量重置 Cloudflare Tunnel

该操作会删除当前授权账号下列出的全部 Tunnel，具有不可逆风险。

交互模式：

```sh
sh cloudflared-reset-all.sh --all
```

无人值守模式：

```sh
sh cloudflared-reset-all.sh --all --yes
```

只有在远端 Tunnel 全部删除成功后，脚本才会清理本地 Tunnel 状态文件；失败时会保留本地状态，便于重试。该脚本不会删除 sing-box 配置、节点参数或证书，也不会自动删除 DNS 记录。

## 测试建议

```sh
sh -n singbox-manager.sh
sh -n cloudflared-manager.sh
sh -n cloudflared-reset-all.sh
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
cloudflared --config /root/.cloudflared/config.yml tunnel ingress validate
curl -i http://127.0.0.1:20008/ws
```

对 WebSocket 地址使用普通 HTTP 请求时，返回 `400` 且提示缺少 `Upgrade` 头通常表示本地服务已到达，实际客户端应使用 WebSocket 握手。

## 许可证

GPL-3.0
