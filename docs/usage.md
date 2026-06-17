# Motif 使用指南：server 模式与电脑模式

Motif 的核心是 `motifd`：它管理工作目录、PTY 终端、文件操作和 git diff。
区别只在于 `motifd` 跑在哪里：

- **跑在 server 上**：`motifd` 是独立守护进程，部署在 VPS、云主机、开发机或办公室工作站上。手机、浏览器、桌面 App 都只是 client。
- **跑在电脑上**：桌面版 Motif App 内嵌一个 `motifd`，从系统托盘或 App 的 Server 页启动。这台电脑既是 server，也是一个 client。

无论哪种模式，Session 都活在运行 `motifd` 的那台机器上：workdir、shell、
文件读写、git diff 都发生在那里。Client 断开后 Session 不会自动消失。

## 1. 先选模式

| 需求 | 推荐模式 | 原因 |
| --- | --- | --- |
| 云主机 / VPS / 长久在线开发环境 | 跑在 server 上 | 进程可用 systemd / Docker / supervisor 托管，适合 24/7 在线 |
| 公司的远端 Linux 工作站 | 跑在 server 上 | 代码、依赖、shell 都在远端，client 只负责 attach |
| MacBook / Windows / Linux 电脑是主要开发机 | 跑在电脑上 | 不需要单独部署 daemon，打开 Motif 桌面 App 就能 serve 本机 |
| 想用手机或平板临时接入自己的电脑 | 跑在电脑上 | 开启 Tailscale 或 relay pairing 后，移动端扫码/添加 server 即可 |
| 多个设备接同一个长期工作区 | 两者都可以 | 关键是让那台保存工作区的机器持续运行 `motifd` |

## 2. 场景 A：跑在 server 上

### 2.1 适用场景

把 Motif 当成远程开发后端使用：server 上有代码仓库、shell、git、语言工具链。
你从桌面 App、手机 App 或浏览器连接它，进入同一组 Session。

典型形态：

```
server / dev box:
  motifd --listen 127.0.0.1:7777 ...

client:
  Motif App / browser -> attach sessions
```

### 2.2 构建或安装

**Docker 镜像（推荐给自托管部署）：**

CI 会发布正式 `motifd` 镜像到 GHCR，镜像内包含 `motifd` 和内嵌 Flutter Web UI：

```bash
docker run -d --name motifd --restart=unless-stopped \
  -p 7777:7777 \
  -v motifd-data:/data \
  -v "$PWD:/work" \
  -e MOTIFD_TOKEN="$(openssl rand -base64 32)" \
  ghcr.io/<owner>/motifd:latest
```

把 `<owner>` 换成仓库所属 GitHub org/user。更多环境变量、Tailscale/rendezvous
配置和本地构建方式见 [`deploy/motifd/README.md`](../deploy/motifd/README.md)。

**从源码构建：**

如果从源码构建，先构建 Flutter Web，再构建 `motifd`。这样浏览器打开
`motifd` 时能加载完整 Web client。

```bash
cd apps/flutter
flutter pub get
flutter build web --no-wasm-dry-run
cd ../..

cargo build -p motif-server --release
```

如果只想先验证服务端协议，`cargo build -p motif-server --release` 也能成功，
但没有 Flutter Web 产物时 `motifd` 只会内嵌一个提示页。

从源码构建 `motifd` 需要 Zig 0.15.x；默认启用嵌入式 Tailscale 时还需要 Go。
完整构建要求见根目录 [`README.md`](../README.md#build)。

### 2.3 准备 token

只要 `motifd` 会通过 Direct TCP 或 Tailscale 被其它机器访问，就建议启用
bearer token。

```bash
mkdir -p ~/.config/motifd
openssl rand -base64 32 > ~/.config/motifd/token
chmod 600 ~/.config/motifd/token
```

`motifd` 启动时只读取一次 token；轮换 token 后需要重启进程。

注意：当前 `motif://pair` rendezvous 链接不携带 bearer token，App 里的
rendezvous server 也不能单独编辑 token。因此 relay pairing 模式暂时不要和
`--token-file` 混用；用 relay 的端到端 TLS pin 保护连接，或等 pairing payload
支持 token 后再叠加应用层 token。

### 2.4 启动方式

**只在 server 本机访问，或配合 SSH 隧道：**

```bash
./target/release/motifd \
  --listen 127.0.0.1:7777 \
  --token-file ~/.config/motifd/token
```

这是最保守的默认部署。外部 client 通过 SSH local forward 进来：

```bash
ssh -N -L 17777:127.0.0.1:7777 user@server.example.com
```

然后浏览器打开 `http://127.0.0.1:17777/?token=<token>`，或在 Motif App 里添加
Direct server：`127.0.0.1:17777`。

**在内网或反向代理后直接访问：**

```bash
./target/release/motifd \
  --listen 0.0.0.0:7777 \
  --token-file ~/.config/motifd/token
```

`motifd` 自己不终止 TLS。公网暴露时，把它放在 Nginx/Caddy/Cloudflare Tunnel
等 TLS 终止层后面，或只通过 VPN/Tailscale 访问。

**只通过嵌入式 Tailscale 访问：**

```bash
./target/release/motifd \
  --tailscale \
  --tailscale-port 7777 \
  --token-file ~/.config/motifd/token
```

第一次启动如果没有 `--tailscale-authkey`，日志会打印登录 URL。打开后授权，
之后状态会持久化到默认 tsnet state dir。默认 hostname 是
`motifd-<system-hostname>`，也可以用 `--tailscale-hostname` 覆盖。

**通过 rendezvous relay 配对：**

```bash
./target/release/motifd \
  --rzv-relay relay.example.com:9999
```

启动后会打印 `motif://pair` 链接和 QR。其它设备在 Motif App 里选择扫码/粘贴
pairing link，即可通过 relay 连接。relay 只转发加密字节，详细协议见
[`rzv-protocol.md`](./rzv-protocol.md)。

当前 pairing link 不包含 bearer token，所以这个模式不要同时传 `--token-file`。

### 2.5 Client 怎么连

**浏览器：**

- 直接访问：`http://server.example.com:7777/?token=<token>`
- 走 SSH 隧道：`http://127.0.0.1:17777/?token=<token>`
- 已有 HTTPS 反代时：`https://motif.example.com/?token=<token>`

Flutter Web 首次从 `motifd` origin 打开时，会自动把当前 host/port 作为一个
server 写入本地浏览器存储；URL 里的 `token` 会被读入配置后从地址栏移除。

**Motif App：**

1. 打开 Client 页。
2. 点 Add Server。
3. 选择连接类型：
   - Direct：填 host、port、token。
   - Tailscale：先在 App 里完成 Tailscale 登录，再选择 tailnet peer 或填 hostname。
   - Pair：扫描/粘贴 `motif://pair` 链接。
4. 连接后创建或进入 Session，workdir 使用 server 上的路径。

### 2.6 运维建议

- 用 systemd、supervisor、launchd 或容器托管 `motifd`，保证它重启后仍在线。
- Public/LAN TCP listener 一定要配 token；公网还要配 TLS 终止层。
- `127.0.0.1` + SSH forward 是最容易审计的部署方式。
- Tailscale 解决连通性，token 仍然是 Motif 应用层鉴权；共享 tailnet 时建议保留 token。
- Session 的 shell 权限就是启动 `motifd` 的系统用户权限，不要用 root 跑日常开发服务。

## 3. 场景 B：跑在电脑上

### 3.1 适用场景

把 Motif 当成本机开发机的远程入口：你的代码、shell、git 都在这台 Mac/Windows/Linux
电脑上。桌面版 Motif App 内嵌 `motifd`，可以从系统托盘 Start/Stop，也可以在 App
里的 Server 页配置。

典型形态：

```
your computer:
  Motif desktop app
    -> embedded motifd
    -> local sessions and workdirs

phone / tablet / another laptop:
  Motif App / browser -> connect back to this computer
```

Web 和移动端不能运行 embedded server；它们只能作为 client。Flutter 默认入口
`lib/main.dart` 不会编译 embedded server、托盘或 native desktop glue；只有桌面入口
`lib/main_desktop.dart` 会包含这些代码。

### 3.2 启动本机 server

1. 打开 Motif 桌面 App。
2. 切到顶部的 **Server** 页，或从系统托盘打开 **Open Server**。
3. 在 **Server** 区域点 **Start**。
4. 可选：打开 **Start server on launch**，让 App 启动后自动 serve。

关闭桌面窗口不会自动停止 server；桌面 App 会留在托盘。选择 Quit Motif 时会尽量
先停止 embedded server。

### 3.3 Listen 模式

桌面 embedded server 有三个 listen 模式：

| 模式 | 监听地址 | 适合 |
| --- | --- | --- |
| Loopback only | `127.0.0.1:<port>` | 默认模式。只给这台电脑自己用，安全、无需 token |
| Local network | `0.0.0.0:<port>` | 同一局域网里的手机/平板/电脑直连，强烈建议开启 token |
| Off | 不开 TCP listener | 只通过 Tailscale 或 relay pairing 访问 |

默认端口是 `7777`。如果端口被占用，在 Server 页的 Listen 区域改成其它端口。

当 embedded server 有 loopback endpoint 时，Motif App 会自动在 Client 页注册一个
`This computer` server。你可以直接从 Client 页进入本机 Session。

### 3.4 认证

Server 页的 **Authentication** 区域可以开启 token，用于 Loopback、Local network
和 Tailscale 连接：

1. 打开 **Require a token**。
2. 点 **Generate token**，或手动粘贴 token。
3. 保存后 Start server。已经运行时，建议 Stop 再 Start，使配置清晰生效。

Local network 模式虽然允许不带 token 启动，但这意味着同网段能访问端口的人都能
attach 到你的 shell。除非只是临时测试，否则不要这么用。

如果使用 **Enable relay pairing**，当前 pairing link 不携带 bearer token；不要同时
开启 **Require a token**，否则扫码添加的 rendezvous server 无法完成 RPC 鉴权。

### 3.5 让其它设备连回这台电脑

**同一局域网直连：**

1. Server 页选择 **Local network**。
2. 开启 token。
3. Start server。
4. 在手机/平板/另一台电脑的 Motif App 里添加 Direct server，host 填这台电脑的
   LAN IP，port 默认 `7777`，token 填刚才的值。

**Tailscale：**

1. Server 页打开 **Enable Tailscale**。
2. Hostname 留空时默认是 `motifd-<host>`；也可以手动设置。
3. 选择官方 Tailscale 或自托管 Headscale。
4. 选择 Browser login，Start 后打开登录 URL；或粘贴 auth key 做 headless 登录。
5. 其它设备在 Motif App 里先连接 Tailscale，再添加 Tailscale server。

如果只想走 tailnet，不想开本地 TCP，把 Listen 设置为 **Off**，同时启用 Tailscale。

**Relay pairing：**

1. Server 页打开 **Enable relay pairing**。
2. 填 rendezvous relay 地址，例如 `relay.example.com:9999`。
3. Start 或重启 server。
4. 页面会显示 QR 和 pairing link。
5. 其它设备在 Motif App 里扫描 QR 或粘贴 link。

这适合手机接入、两端都在 NAT 后、或者不想配置局域网/Tailscale 的场景。前提是你有
可用的 `motif-rendezvous` relay。

**浏览器打开本机 Web UI：**

托盘菜单里的 **Open in Browser** 会打开 embedded server 的 Web UI，并在 URL 上附带
token。这个入口只在 server 正在运行且有 loopback endpoint 时出现。

### 3.6 本机模式的注意事项

- Embedded server 只在桌面平台可用：macOS、Linux、Windows，并且需要构建产物里包含
  `motif-embed` native library。
- 桌面构建请使用 `-t lib/main_desktop.dart`；Web、iOS、Android 使用默认
  `lib/main.dart`。
- App 的 Client 页和其它设备看到的是同一个本机 `motifd`，所以 Session、PTY 输出、
  文件树和 diff 会保持一致。
- Workdir 是这台电脑上的路径。移动端只是远程操作它，不会把项目复制到手机上。
- 如果电脑睡眠、关机或 App 退出，embedded server 就不可用；需要长久在线时用
  “跑在 server 上”的 daemon 模式。

## 4. 常见连接选择

| 连接方式 | Server 模式 | 电脑模式 | 备注 |
| --- | --- | --- | --- |
| Direct TCP | `--listen host:port` | Local network | 简单，但网络可达面最大，建议 token + TLS/VPN |
| SSH forward | `--listen 127.0.0.1:7777` | 不常用 | 适合已有 SSH 的远端 server |
| Tailscale | `--tailscale` | Enable Tailscale | 适合多设备、NAT 后、移动办公 |
| Rendezvous relay | `--rzv-relay` | Enable relay pairing | 适合扫码配对和无直连网络；当前不要叠加 bearer token |
| Browser same-origin | `motifd` 内嵌 Web UI | Tray Open in Browser | Web client 与 RPC/WS 共用同一个 origin |

## 5. 快速排错

- 打不开 Web UI：先确认 `motifd` 是否在监听，浏览器访问 `/ping` 应返回 Motif server 信息。
- App 显示 `No ping`：host/port/token 可能不对，或当前网络到不了 server。
- Tailscale 一直需要登录：打开 Server 页或托盘里的登录 URL，完成授权；headless 环境用 auth key。
- LAN 模式连不上：检查系统防火墙、路由器隔离、端口是否被占用。
- Session 里路径不存在：workdir 是 server 机器上的路径，不是 client 机器上的路径。
- 从公网访问：不要裸奔 `http://0.0.0.0:7777`；使用 token，并在反向代理/Tunnel/VPN 后访问。

相关文档：

- [`web-client.md`](./web-client.md)：`motifd` 内嵌 Web client 的行为。
- [`tailscale.md`](./tailscale.md)：嵌入式 Tailscale / tsnet。
- [`ssh-tunnel.md`](./ssh-tunnel.md)：SSH local forward 连接。
- [`rzv-protocol.md`](./rzv-protocol.md)：rendezvous relay 配对协议。
