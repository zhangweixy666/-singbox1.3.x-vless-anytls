# sing-box 1.13.14 + Cloudflare Tunnel

VPS 通用 sing-box 节点配置与 Cloudflare Tunnel 管理工具。

适用于 Alpine、Debian/Ubuntu 等 Linux VPS，以及常见的 LXC/容器环境。

README 的命令按“一个代码块一个命令”排列，便于直接复制执行。

## ✨ 项目简介

本项目包含两个相互配合的工具：

- `singbox-manager.sh`：配置和管理 sing-box 节点。
- `cloudflared-manager.sh`：配置和管理 Cloudflare Tunnel、DNS 路由、本地回源和开机自启。
- `cloudflared-reset-all.sh`：从头开始时，一键删除当前账号下的全部 Cloudflare Tunnel，并清理 VPS 本地 Tunnel 状态。

项目重点解决以下问题：

- 在 VPS 上快速部署 sing-box。
- 管理 AnyTLS、TUIC、Hysteria2、VLESS/WS、VMess/WS 和 VLESS/Reality。
- 使用 Cloudflare Tunnel 将公网 HTTPS 443 转发到本地 WebSocket 服务。
- 支持 Alpine/OpenRC 和 Debian/Ubuntu/systemd。
- 支持 cloudflared 崩溃后自动重启。
- 支持 Tunnel 创建、选择、Ingress 配置、DNS 路由和状态检查。
- 支持删除全部 Tunnel 后重新开始。
- 已验证 Cloudflare Tunnel 公网 HTTPS 到本地 WebSocket 的完整链路。
- 服务生成时自动创建 sing-box 日志目录，避免日志路径不存在导致服务启动失败。

## 🧩 功能概览

| 工具/功能 | 说明 |
|------|------|
| sing-box 管理器 | 安装、更新、配置和重启 sing-box |
| 支持协议 | AnyTLS、TUIC、Hysteria2、VLESS+WS、VMess+WS、VLESS+Reality |
| 证书管理 | 自签证书和 Cloudflare DNS API ACME 证书 |
| Tunnel 管理 | 登录、创建、选择、查看和删除 Cloudflare Tunnel |
| Ingress 配置 | 配置公网域名、本地回源端口和 WebSocket 路径 |
| DNS 路由 | 创建或覆盖 hostname 到 Tunnel 的 CNAME 路由 |
| 服务自启 | 支持 OpenRC、systemd，以及部分手动启动环境 |
| 崩溃恢复 | cloudflared 退出后自动等待 3 秒重新启动 |
| 链路检查 | 检查本地回源、DNS、Tunnel 状态和公网 HTTPS |
| 全量重置 | 删除当前账号下全部 Tunnel 并清理本机 Tunnel 状态 |
| 中文界面 | 菜单、状态、错误提示和使用说明均为中文 |

## ⚡ 快速开始

### 1. 安装 sing-box 管理器

下载脚本：

```sh
wget -qO /root/singbox-manager.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/singbox-manager.sh
```

赋予执行权限：

```sh
chmod +x /root/singbox-manager.sh
```

启动菜单：

```sh
sh /root/singbox-manager.sh
```

也可以直接使用在线脚本：

```sh
wget -qO- https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/singbox-manager.sh | sh
```

### 2. 安装 Cloudflare Tunnel 管理器

下载脚本：

```sh
wget -qO /usr/local/bin/cloudflared-manager.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/cloudflared-manager.sh
```

赋予执行权限：

```sh
chmod +x /usr/local/bin/cloudflared-manager.sh
```

启动一键流程：

```sh
/usr/local/bin/cloudflared-manager.sh guided
```

一键流程包括：

```text
Cloudflare 授权
    ↓
安装或检查 cloudflared
    ↓
创建或选择 Tunnel
    ↓
配置 Zone、域名、本地端口和 WS 路径
    ↓
生成 config.yml
    ↓
添加 DNS CNAME 路由
    ↓
配置 OpenRC/systemd 自启
    ↓
启动 Tunnel
    ↓
检查本地回源、DNS 和公网链路
```

## 🌐 Cloudflare Tunnel 工作方式

典型链路如下：

```text
客户端
  ↓ HTTPS 443
Cloudflare hostname
  ↓ CNAME
Cloudflare Tunnel
  ↓ 加密连接
VPS 上的 cloudflared
  ↓ HTTP
127.0.0.1:20008/ws
  ↓
sing-box VLESS/WS 或 VMess/WS
```

Cloudflare Tunnel 对外使用 HTTPS 443，本地回源端口可以按 VPS 实际监听端口配置。

例如：

```text
公网域名：cf-test.example.com
公网端口：443
WS 路径：/ws
本地回源：http://127.0.0.1:20008
```

Tunnel 协议支持：

```text
auto
quic
http2
```

如果 VPS 的 UDP/QUIC 网络不稳定，可以在配置中选择 `http2`，通过 TCP 连接 Cloudflare。

## 🖥️ Cloudflare Tunnel 菜单

启动菜单：

```sh
/usr/local/bin/cloudflared-manager.sh
```

主要功能：

```text
  1) 一键完整流程（登录/创建/配置/DNS/自启/验证）
  2) Cloudflare 登录授权
  3) 安装或更新 cloudflared
  4) 查看 Tunnel 列表
  5) 创建 Tunnel
  6) 选择已有 Tunnel
  7) 配置 Zone/域名/回源端口/WS路径
  8) 编辑 Tunnel config.yml
  9) 添加或覆盖 DNS 路由
 10) 删除 DNS 路由（API Token）
 11) 校验配置和规则
 12) 启动并设置自启
 13) 停止 Tunnel
 14) 重启 Tunnel
 15) 查看状态/连接/日志
 16) 查看 Tunnel 详细信息
 17) 检查本地回源
 18) 检查公网链路
 19) 输出客户端参数
 20) 编辑并校验 sing-box JSON
 21) 常用命令
 22) 删除 Tunnel
  0) 退出
```

## 🔧 常用命令

查看 Tunnel 状态：

```sh
/usr/local/bin/cloudflared-manager.sh status
```

重启 Tunnel：

```sh
/usr/local/bin/cloudflared-manager.sh restart
```

检查本地回源：

```sh
/usr/local/bin/cloudflared-manager.sh origin
```

检查公网链路：

```sh
/usr/local/bin/cloudflared-manager.sh public
```

输出客户端参数：

```sh
/usr/local/bin/cloudflared-manager.sh links
```

查看 Tunnel 详细信息：

```sh
/usr/local/bin/cloudflared-manager.sh info
```

查看 Tunnel 日志：

```sh
/usr/local/bin/cloudflared-manager.sh logs
```

添加或覆盖 DNS 路由：

```sh
/usr/local/bin/cloudflared-manager.sh dns-add
```

删除 DNS 路由：

```sh
/usr/local/bin/cloudflared-manager.sh dns-delete
```

`dns-delete` 需要具有对应 Zone DNS 编辑权限的 Cloudflare API Token。

## 🧹 从头开始：删除全部 Cloudflare Tunnel

如果需要重新注册、重新创建 Tunnel，可以使用全量重置脚本。

下载脚本：

```sh
wget -qO /tmp/cloudflared-reset-all.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/cloudflared-reset-all.sh
```

赋予执行权限：

```sh
chmod +x /tmp/cloudflared-reset-all.sh
```

交互确认后执行：

```sh
/tmp/cloudflared-reset-all.sh
```

脚本会要求输入：

```text
DELETE-ALL-TUNNELS
```

确认后执行以下操作：

- 停止本机 cloudflared 服务；
- 停止 cloudflared 和 Tunnel 监督进程；
- 删除当前 Cloudflare 账号下列出的全部 Tunnel；
- 删除本机 Tunnel JSON 凭据；
- 删除本机 `config.yml`；
- 删除 OpenRC/systemd 服务文件；
- 删除监督脚本、PID 文件和 Tunnel 日志；
- 保留 Cloudflare 授权证书 `cert.pem`；
- 保留 sing-box 配置、节点参数和证书。

也可以跳过交互确认：

```sh
/tmp/cloudflared-reset-all.sh --yes
```

### ⚠️ 全量删除的重要说明

`cloudflared-reset-all.sh` 只负责删除 Tunnel 和本机 Tunnel 状态，**不会自动删除 Cloudflare DNS 记录**。

因此，删除全部 Tunnel 后，之前的 CNAME 记录可能仍然存在，例如：

```text
cf-test.example.com CNAME <旧 Tunnel UUID>.cfargotunnel.com
```

如果要彻底清理 DNS，需要单独执行：

```sh
/usr/local/bin/cloudflared-manager.sh dns-delete
```

或者使用 Cloudflare API 删除对应 Zone 下的 DNS 记录。

删除 Tunnel 是不可逆操作。DNS 记录、Zone、sing-box 配置、节点参数和证书不会由重置脚本自动恢复。

## 📁 主要文件和目录

| 路径 | 作用 |
|------|------|
| `/usr/local/bin/singbox-manager.sh` | sing-box 管理脚本 |
| `/usr/local/bin/cloudflared-manager.sh` | Cloudflare Tunnel 管理脚本 |
| `/usr/local/sbin/cloudflared-supervisor.sh` | Tunnel 自动重启监督脚本 |
| `/root/.cloudflared/config.yml` | cloudflared Tunnel 配置 |
| `/root/.cloudflared/cert.pem` | Cloudflare 授权证书 |
| `/root/.cloudflared/<TUNNEL_ID>.json` | Tunnel 凭据 |
| `/etc/cloudflared-manager.env` | Tunnel 管理器状态 |
| `/etc/cloudflared-manager.api` | Cloudflare API Token 文件 |
| `/var/log/cloudflared/tunnel.log` | Tunnel 日志 |
| `/etc/sing-box/config.json` | sing-box 配置 |
| `/etc/sing-box/params.env` | sing-box 节点参数 |

## 🔍 常用排障

查看 cloudflared 进程：

```sh
pgrep -af cloudflared
```

查看 OpenRC 状态：

```sh
rc-service cloudflared status
```

查看 systemd 状态：

```sh
systemctl status cloudflared
```

查看 Tunnel 日志：

```sh
tail -n 100 /var/log/cloudflared/tunnel.log
```

检查本地 WS 回源：

```sh
curl -i http://127.0.0.1:20008/ws
```

检查公网 HTTPS 回源：

```sh
curl -ki https://your-hostname.example.com/ws
```

对 WebSocket 路径使用普通 HTTP 请求时，返回 `400` 不一定代表 Tunnel 故障。只要请求已经到达 sing-box WS 监听，`400` 通常说明公网到本地回源链路已经打通。

检查 Tunnel 配置：

```sh
/usr/local/bin/cloudflared --config /root/.cloudflared/config.yml tunnel ingress validate
```

查看 DNS CNAME：

```sh
dig +short CNAME your-hostname.example.com
```

## ⚠️ 注意事项

- 所有脚本需要 root 权限。
- Cloudflare 登录授权需要在浏览器中完成。
- DNS 路由创建需要域名已经托管在目标 Cloudflare Zone。
- 删除 DNS 记录需要具有 Zone DNS 编辑权限的 API Token。
- `cloudflared-reset-all.sh --yes` 会删除当前账号下全部 Tunnel，请确认当前授权账号无其他重要 Tunnel。
- 删除 Tunnel 不会自动删除 DNS 记录。
- 不要把 Tunnel JSON 凭据、`cert.pem` 或 API Token 提交到 GitHub。
- Cloudflare Tunnel 不会替代 sing-box 本地监听，必须先确认本地端口和 WS 路径正确。
- 如果 QUIC/UDP 不稳定，可以将 Tunnel 协议改为 `http2`。
- 生产环境操作前建议创建 VPS/LXC 快照。
- 请只在自己拥有或获授权管理的服务器和 Cloudflare Zone 上使用。

## 📄 License

GPL-3.0

## 🔗 相关链接

- 本项目：https://github.com/zhangweixy666/-singbox1.3.x-vless-anytls
- Cloudflare Tunnel 管理器：https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/cloudflared-manager.sh
- Tunnel 全量重置脚本：https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/cloudflared-reset-all.sh
- DNS 参考项目：https://github.com/zhangweixy666/dns-setup