<div align="center">

<h1>🧊 sing-box 1.13.14 + Cloudflare Tunnel</h1>

<p><b>VPS 通用 sing-box 节点配置与 Cloudflare Tunnel 一键管理</b></p>

<p>六种协议 · 自动证书 · Tunnel 全流程 · OpenRC / systemd 双兼容</p>

[![sing-box](https://img.shields.io/badge/sing--box-1.13.14-2ea44f?style=for-the-badge)](https://github.com/SagerNet/sing-box)
[![cloudflared](https://img.shields.io/badge/cloudflared-2026.10.1-f38020?style=for-the-badge)](https://github.com/cloudflare/cloudflared)
[![Platform](https://img.shields.io/badge/platform-Alpine%20%7C%20Debian%20%7C%20Ubuntu%20%7C%20LXC-0078d7?style=for-the-badge)](#-系统要求)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=for-the-badge)](LICENSE)

<p><b>不用买域名 · 不用自己签证书 · 不用手写 JSON</b></p>

[🚀 快速开始](#-快速开始)　·　[🧩 三个脚本](#-三个脚本)　·　[🔌 支持协议](#-支持协议)　·　[🌐 Tunnel 工作方式](#-cloudflare-tunnel-工作方式)　·　[❓ 常见问题](#-常见问题)

</div>

---

## 🎯 这个项目解决什么

在 VPS 上折腾 sing-box，通常卡在这几步：

| 卡点 | 这个项目怎么办 |
|:---|:---|
| 六种协议的 JSON 各写一遍，参数记不住 | 交互菜单逐项配置，自动生成并 `sing-box check` 校验 |
| 自签证书客户端不认，ACME 又要配 DNS API | 两种证书都支持，Cloudflare DNS API 自动签发续期 |
| 想让节点走 Cloudflare 的 443，但 Tunnel 配置太绕 | `cloudflared-manager.sh guided` 一条命令走完全流程 |
| 改坏了 Tunnel 配置，隧道直接起不来 | Ingress 写入前临时文件 + 校验 + 原子替换，失败保留原配置 |
| 重启后服务没了 | OpenRC / systemd 自动注册，cloudflared 崩溃 3 秒自动拉起 |
| cloudflared 偷偷自动更新，版本漂移 | 固定 `2026.10.1` + 官方 SHA-256 校验 + 关闭自动更新 |

> 💡 **三个脚本各司其职**：`singbox-manager.sh` 管节点，`cloudflared-manager.sh` 管隧道，`cloudflared-reset-all.sh` 负责推倒重来。

---

## 🚀 快速开始

### 1. 安装 sing-box 管理器

```sh
wget -qO /root/singbox-manager.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/singbox-manager.sh
```

```sh
chmod +x /root/singbox-manager.sh
```

```sh
sh /root/singbox-manager.sh
```

### 2. 安装 Cloudflare Tunnel 管理器

```sh
wget -qO /usr/local/bin/cloudflared-manager.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/cloudflared-manager.sh && test -s /usr/local/bin/cloudflared-manager.sh
```

```sh
chmod +x /usr/local/bin/cloudflared-manager.sh
```

### 3. 一条命令走完 Tunnel 全流程

```sh
/usr/local/bin/cloudflared-manager.sh guided
```

`guided` 会自动完成：检查并安装固定版 cloudflared → Cloudflare 授权 → 创建/选择 Tunnel → 配置域名与回源 → 校验并原子替换 config.yml → 添加 DNS CNAME → 注册开机自启 → 启动 → 检查进程与回源 → 检查公网 WebSocket 链路。

> ✅ 从零开始也能直接跑 `guided`，不需要先手动执行 `install`。

---

## 📖 目录

- [🎯 这个项目解决什么](#-这个项目解决什么)
- [🚀 快速开始](#-快速开始)
- [🧩 三个脚本](#-三个脚本)
- [🔌 支持协议](#-支持协议)
- [🧰 sing-box 管理](#-sing-box-管理)
- [🌐 Cloudflare Tunnel 工作方式](#-cloudflare-tunnel-工作方式)
- [🖥 Tunnel 菜单](#-tunnel-菜单)
- [🔧 常用命令](#-常用命令)
- [📁 主要文件与目录](#-主要文件与目录)
- [🧹 从头开始：重新登录](#-从头开始重新登录)
- [🧩 系统要求](#-系统要求)
- [🔍 常用排障](#-常用排障)
- [❓ 常见问题](#-常见问题)
- [⚠️ 注意事项](#-注意事项)
- [📄 许可](#-许可)

---

## 🧩 三个脚本

| 脚本 | 职责 | 装到哪 |
|:---|:---|:---|
| `singbox-manager.sh` | 安装/更新 sing-box，配置六种协议，证书管理，生成分享链接 | `/root/singbox-manager.sh` 或 `/usr/local/bin/` |
| `cloudflared-manager.sh` | 安装固定版 cloudflared，Tunnel 登录/创建/选择/删除，Ingress、DNS 路由、自启、状态检查 | `/usr/local/bin/cloudflared-manager.sh` |
| `cloudflared-reset-all.sh` | 删除本机旧 `cert.pem` 并重新登录，**不动云端 Tunnel 与 DNS** | `/tmp/`（一次性使用） |

> ⚠️ `cloudflared-reset-all.sh` 只做本地重置。它**不会**删除、停止或修改 Cloudflare 账号内已有的 Tunnel，也不会删除 DNS 记录。

---

## 🔌 支持协议

| 协议 | 传输 | 需要域名 | 需要证书 | 说明 |
|:---|:---|:---:|:---:|:---|
| **AnyTLS** | TCP + TLS | 可选 | ✅ | 抗主动探测，需 TLS 证书 |
| **TUIC** | QUIC / UDP | 可选 | ✅ | 低延迟，UDP 线路要好 |
| **Hysteria2** | QUIC / UDP | 可选 | ✅ | 弱网表现强，支持 obfs |
| **VLESS + Reality** | TCP | ❌ | ❌ | 免域名免证书，借牌大站 |
| **VLESS + WebSocket** | WS | ✅ | 可选 | 可套 Cloudflare Tunnel |
| **VMess + WebSocket** | WS | ✅ | 可选 | 兼容性最好 |

**证书管理**：

- **自签证书** —— 本地生成，客户端需关闭证书校验或手动信任
- **Cloudflare DNS API ACME** —— 自动签发 + 自动续期，需要域名托管在 Cloudflare

菜单里还可一键**重置当前节点的随机参数**（UUID / 密码 / 路径等），旧链接会失效，以新输出为准。

---

## 🧰 sing-box 管理

### 打开完整菜单

```sh
singbox-manager
```

```text
1) 设置服务器/节点名/域名
2) 配置 AnyTLS
3) 配置 TUIC
4) 配置 Hysteria2
5) 配置 VLESS + WebSocket
6) 配置 VMess + WebSocket
7) 配置 VLESS + Reality
...
11) 重置当前节点随机参数
```

### 快捷配置单协议

```sh
singbox-manager vless-ws
```

### 检查与重启

```sh
sing-box check -c /etc/sing-box/config.json
```

```sh
singbox-status
```

```sh
singbox-restart
```

> 📌 填写节点地址时**必须用公网 IP 或域名**。`127.0.0.1` / `127.0.1.1` / `localhost` 只能本机访问，外部客户端连不上 —— 脚本会自动检测并避免生成回环地址链接。

---

## 🌐 Cloudflare Tunnel 工作方式

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

- 公网只暴露 **HTTPS 443**，VPS 无需开放入站端口，也不需要公网 IP
- 本地回源端口按实际监听配置，路径需与 sing-box 的 WS 路径一致
- Tunnel 协议支持 `auto` / `quic` / `http2`；UDP 不稳时选 `http2` 走 TCP

**示例配置**

```text
公网域名：cf-test.example.com
公网端口：443
WS 路径：/ws
本地回源：http://127.0.0.1:20008
```

**固定版本信息**

```text
cloudflared: 2026.10.1
Linux amd64 SHA-256: 3bfc539f45d2620c71debb7a86be0efa737ed5ccbad9eb85c787116900e5c586
Linux arm64 SHA-256: 2c65dfabf616c40efc7545d107d7a57ad5e21377e2964b7e88af19a238074a46
自动更新: 已关闭
```

---

## 🖥 Tunnel 菜单

```sh
/usr/local/bin/cloudflared-manager.sh
```

```text
  1) 安装/校验固定版本 cloudflared
  2) Cloudflare 登录授权
  3) 列出 Tunnel
  4) 创建 Tunnel
  5) 选择已有 Tunnel
  6) 配置 Zone/域名/回源端口/WS路径
  7) 校验 Ingress 配置
  8) 添加或覆盖 DNS 路由
  9) 删除 DNS 路由（API Token）
 10) 启动 Tunnel
 11) 停止 Tunnel
 12) 重启 Tunnel
 13) 查看 Tunnel 状态/连接/日志
 14) 检查本地回源
 15) 检查公网链路
 16) 删除当前 Tunnel
 17) 查看最近日志
 18) 查看命令帮助
  0) 退出
```

---

## 🔧 常用命令

| 命令 | 作用 |
|:---|:---|
| `cloudflared-manager.sh status` | Tunnel 状态 |
| `cloudflared-manager.sh restart` | 重启 Tunnel |
| `cloudflared-manager.sh origin` | 检查本地回源 |
| `cloudflared-manager.sh public` | 检查公网链路 |
| `cloudflared-manager.sh links` | 输出客户端参数 |
| `cloudflared-manager.sh info` | 查看 Tunnel 详细信息 |
| `cloudflared-manager.sh logs` | 查看 Tunnel 日志 |
| `cloudflared-manager.sh dns-add` | 添加或覆盖 DNS 路由 |
| `cloudflared-manager.sh dns-delete` | 删除 DNS 路由 |
| `cloudflared-manager.sh guided` | 一键完整部署 |

> 💡 `dns-delete` 优先读取 `/etc/cloudflared-manager.api` 中的 API Token；未配置时会自动从 `/root/.cloudflared/cert.pem`（ARGO TUNNEL TOKEN）中提取 `apiToken`，无需手动输入。

---

## 📁 主要文件与目录

| 路径 | 作用 |
|:---|:---|
| `/usr/local/bin/singbox-manager.sh` | sing-box 管理脚本 |
| `/usr/local/bin/cloudflared-manager.sh` | Tunnel 管理脚本 |
| `/usr/local/sbin/cloudflared-supervisor.sh` | Tunnel 自动重启监督脚本 |
| `/root/.cloudflared/config.yml` | cloudflared Tunnel 配置 |
| `/root/.cloudflared/cert.pem` | Cloudflare 授权证书 |
| `/root/.cloudflared/<TUNNEL_ID>.json` | Tunnel 凭据 |
| `/etc/cloudflared-manager.env` | Tunnel 管理器状态 |
| `/etc/cloudflared-manager.api` | Cloudflare API Token 文件 |
| `/var/log/cloudflared/tunnel.log` | Tunnel 日志 |
| `/etc/sing-box/config.json` | sing-box 配置 |
| `/etc/sing-box/params.env` | sing-box 节点参数 |

---

## 🧹 从头开始：重新登录

需要重新登录并创建新的 Tunnel 时：

```sh
wget -qO /tmp/cloudflared-reset-all.sh https://raw.githubusercontent.com/zhangweixy666/-singbox1.3.x-vless-anytls/main/cloudflared-reset-all.sh
```

```sh
chmod +x /tmp/cloudflared-reset-all.sh
```

```sh
/tmp/cloudflared-reset-all.sh
```

交互确认需输入 `RESET-LOCAL-CLOUDFLARED`。跳过确认：

```sh
/tmp/cloudflared-reset-all.sh --yes
```

**它会做什么**

- ✅ 删除本机旧的 `cert.pem`，重新执行 `cloudflared login`
- ✅ 保留 Cloudflare 账号内已有的 Tunnel 和 DNS 记录
- ✅ 保留本机已有 Tunnel JSON 凭据
- ✅ 保留 sing-box 配置、节点参数和证书

**它不会做什么**

- ❌ 不删除云端 Tunnel
- ❌ 不停止正在运行的 Tunnel
- ❌ 不删除 DNS 记录

> 📌 旧 CNAME 记录会继续保留（如 `cf-test.example.com CNAME <旧UUID>.cfargotunnel.com`）。要彻底清理 DNS，需单独执行 `cloudflared-manager.sh dns-delete`。

---

## 🧩 系统要求

| 项目 | 要求 |
|:---|:---|
| 系统 | Alpine Linux、Debian / Ubuntu，以及常见 LXC / 容器环境 |
| init | OpenRC（Alpine）或 systemd（Debian/Ubuntu） |
| 权限 | root |
| 架构 | x86_64 / aarch64 / armv7 / i386（cloudflared 按架构匹配 SHA-256） |
| 依赖 | `wget` 或 `curl`、`tar`、`jq`（部分功能）、`openssl`（自签证书） |

---

## 🔍 常用排障

**看进程**

```sh
pgrep -af cloudflared
```

**看服务状态**

```sh
rc-service cloudflared status
```

```sh
systemctl status cloudflared
```

**看日志**

```sh
tail -n 100 /var/log/cloudflared/tunnel.log
```

**检查本地回源**

```sh
curl -i http://127.0.0.1:20008/ws
```

**检查公网链路**

```sh
curl -ki https://your-hostname.example.com/ws
```

> 📌 对 WebSocket 路径发普通 HTTP 请求返回 `400` **不一定**是故障。只要请求已到达 sing-box 的 WS 监听，`400` 通常说明「公网 → 本地回源」这一段是通的。

**校验 Tunnel 配置**

```sh
/usr/local/bin/cloudflared --config /root/.cloudflared/config.yml tunnel ingress validate
```

**查 DNS CNAME**

```sh
dig +short CNAME your-hostname.example.com
```

---

## ❓ 常见问题

<details>
<summary><b>没有公网 IP 的机器能玩吗？</b></summary>

能，这正是 Cloudflare Tunnel 的用途。cloudflared 主动向 Cloudflare 建立出站连接，公网流量经 Cloudflare 边缘回源到本机 `127.0.0.1`。NAT 机器、家宽、容器都能用。

但注意：**Reality / TUIC / Hysteria2 这类直连协议仍然需要能入站的 UDP/TCP 端口**，它们不能走 Tunnel。

</details>

<details>
<summary><b>为什么 cloudflared 要固定版本，不让它自动更新？</b></summary>

因为「自动更新」在生产环境是个不稳定源：更新可能改变 CLI 参数、改变连接行为，甚至中途失败留下半新半旧的二进制。

本项目固定 `2026.10.1`，安装时按架构校验官方 SHA-256，运行时关闭自动更新。升级方式很明确：改脚本里的版本号与 SHA-256，重新执行 `install`。

</details>

<details>
<summary><b>Ingress 配置改错了，会不会把正在用的隧道搞挂？</b></summary>

不会。写入流程是：**临时生成 → `tunnel ingress validate` 校验 → 原子替换**。校验失败时原配置分毫不动。

</details>

<details>
<summary><b>`guided` 跑完提示「本地回源未监听」，是失败了吗？</b></summary>

不是失败。如果此时 sing-box 还没启动或还没配置对应节点，脚本会**完成 Tunnel 部署**并提示稍后复查回源，而不是把「本地端口没监听」误判成 Cloudflare 安装失败。

配好 sing-box 后再执行：

```sh
/usr/local/bin/cloudflared-manager.sh origin
```

</details>

<details>
<summary><b>`400 Bad Request` 是不是 Tunnel 坏了？</b></summary>

大概率不是。用 `curl` 直接请求 WebSocket 路径本来就会得到 `400`（缺少 Upgrade 头）。判断标准是**请求有没有到达 sing-box**，而不是状态码是不是 200。

真正的故障通常是：本地端口没监听、WS 路径不匹配、或者 sing-box 没启动。

</details>

<details>
<summary><b>UDP/QUIC 不稳定，Tunnel 老是断？</b></summary>

把 Tunnel 协议从 `auto` / `quic` 改成 `http2`，走 TCP 连 Cloudflare。代价是延迟略高，但稳定性明显提升。

</details>

<details>
<summary><b>自签证书客户端不认怎么办？</b></summary>

两条路：

1. 客户端关闭证书校验（仅测试用，不建议生产）
2. 用 Cloudflare DNS API 的 ACME 证书，自动签发且受信任 —— 需要域名托管在 Cloudflare

</details>

<details>
<summary><b>`cloudflared-reset-all.sh` 会删掉我账号里的 Tunnel 吗？</b></summary>

不会。它只删除**本机**的 `cert.pem` 并重新登录。云端 Tunnel、DNS 记录、Zone 全部保留。

同理，它也不会删本机的 Tunnel JSON 凭据、sing-box 配置、节点参数和证书。

</details>

---

## ⚠ 注意事项

- 所有脚本需要 **root** 权限
- Cloudflare 登录授权需要在**浏览器**中完成
- DNS 路由创建要求域名已托管在目标 Cloudflare Zone
- 删除 DNS 记录需要具有 **Zone DNS 编辑权限**的 API Token
- **不要**把 Tunnel JSON 凭据、`cert.pem` 或 API Token 提交到 GitHub
- Cloudflare Tunnel **不替代** sing-box 本地监听，必须先确认本地端口与 WS 路径正确
- 重置节点随机参数后，客户端旧链接会失效，请以脚本输出的新链接为准
- 生产环境操作前建议创建 VPS / LXC 快照
- 请只在自己拥有或获授权管理的服务器和 Cloudflare Zone 上使用

---

## 📄 许可

GPL-3.0

> ⚠️ **免责声明**：本项目仅供技术学习与研究使用。请遵守所在地法律法规及 Cloudflare 服务条款。

## 🔗 相关项目

- [dns-setup](https://github.com/zhangweixy666/dns-setup) —— VPS DNS 自动配置
- [suoha-plus](https://github.com/zhangweixy666/suoha-plus) —— Xray 多模式节点一键管理
- [warp-](https://github.com/zhangweixy666/warp-) —— Alpine WARP + ShadowQuic + sing-box

<div align="center">

**[⬆ 回到顶部](#-sing-box-11314--cloudflare-tunnel)**

Made with 🧊 by [zhangweixy666](https://github.com/zhangweixy666)

</div>