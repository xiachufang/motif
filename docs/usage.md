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
  -e MOTIFD_ADVERTISE_HOST=<公网IP或域名> \
  ghcr.io/<owner>/motifd:latest
# 用打印出来的链接配对：
docker logs motifd 2>&1 | grep -o 'motif://pair[^ ]*'
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

### 2.3 准入与加密（无需手动 token）

不再需要手动管理 bearer token。**网络可达的监听（非 loopback `--listen` 或
relay）会自动加密 + 自动鉴权**：

- **加密**：motifd 用持久化的自签证书终止 TLS，客户端按 `pk`（证书哈希）pin。
- **鉴权**：从持久化的 **psk** 派生一个 bearer，客户端从配对链接里的 psk 派生
  同一个 bearer 发送。
- motifd 启动只打印**一个** `motif://pair` 链接/二维码，里面带 `psk` + `pk` +
  可达信息——它就是唯一凭证。把数据目录（`/data` 或 `$XDG_DATA_HOME`）持久化，
  psk 和证书就跨重启稳定，链接的 pin 一直有效。

loopback `--listen`（仅本机）保持明文、无鉴权。`--psk <base64url>` 可固定 psk
（无人值守/固定链接场景），不传则自动生成并持久化。

### 2.4 启动方式

**只在 server 本机访问，或配合 SSH 隧道（明文 loopback）：**

```bash
./target/release/motifd --listen 127.0.0.1:7777
```

外部 client 通过 SSH local forward 进来：

```bash
ssh -N -L 17777:127.0.0.1:7777 user@server.example.com
```

然后浏览器打开 `http://127.0.0.1:17777/`，或在 Motif App 里添加 Direct server
`127.0.0.1:17777`。

**在内网/公网直接访问（自动 TLS + psk 配对）：**

```bash
./target/release/motifd --listen 0.0.0.0:7777 --advertise-host <公网IP或域名>
```

启动打印一个直连形态的 `motif://pair?host=…&port=…&psk=…&pk=…` 链接/二维码；
App 扫码/粘贴即连（`https://` + pin + bearer），**不需要**反向代理/隧道来终止
TLS。`--advertise-host` 给公网/NAT 用；局域网省略则自动带上全部网卡 IP，客户端
探测可达的那个。

**只通过嵌入式 Tailscale 访问：**

```bash
./target/release/motifd --tailscale --tailscale-port 7777
```

tailscale-only 由 tailnet ACL 把门（无 `--listen` 时不用 psk/bearer）。第一次
启动如果没有 `--tailscale-authkey`，日志会打印登录 URL。

**通过 rendezvous relay 配对：**

```bash
./target/release/motifd --rzv-relay relay.example.com:9999
```

启动打印一个 rzv 形态的 `motif://pair` 链接和 QR。App 扫码/粘贴即可通过 relay
连接（端到端 TLS pin + psk bearer）；relay 只转发加密字节。同时再开一个
`--listen 0.0.0.0:7777` 还能让同网段客户端经 `/ping` 自动升级到 LAN 直连。详见
[`rzv-protocol.md`](./rzv-protocol.md)。

### 2.5 Client 怎么连

**浏览器（仅 loopback 明文场景）：**

- 走 SSH 隧道：`http://127.0.0.1:17777/`
- 已有 HTTPS 反代时：`https://motif.example.com/`

浏览器无法 pin 自签证书，所以网络/relay 的加密直连请用 App 扫码配对。Flutter Web
首次从 `motifd` origin 打开时，会自动把当前 host/port 作为一个 server 写入本地
浏览器存储。

**Motif App：**

1. 打开 Client 页。
2. 点 Add Server。
3. 选择连接类型：
   - Pair：扫描/粘贴 `motif://pair` 链接——按内容自动走 relay 或直连，自带加密 +
     psk 鉴权（推荐）。
   - Direct：手动填 host、port（连旧的明文/loopback motifd）。
   - Tailscale：先在 App 里完成 Tailscale 登录，再选择 tailnet peer 或填 hostname。
4. 连接后创建或进入 Session，workdir 使用 server 上的路径。

### 2.6 运维建议

- 用 systemd、supervisor、launchd 或容器托管 `motifd`，保证它重启后仍在线。
- 持久化数据目录（`/data` 或 `$XDG_DATA_HOME`），让 psk + 自签证书跨重启稳定，
  配对链接的 pin 一直有效。
- 网络监听自动加密 + psk 鉴权，无需手动 token 或 TLS 终止层；把 `motif://pair`
  链接当作密钥保管，轮换就清掉数据目录重新生成。
- `127.0.0.1` + SSH forward 仍是最容易审计的明文部署方式。
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
4. **Start server on launch** 默认开启，App 启动后会自动 serve；如不需要可手动关闭。

关闭桌面窗口不会自动停止 server；桌面 App 会留在托盘。选择 Quit Motif 时会尽量
先停止 embedded server。

### 3.3 Listen 模式

桌面 embedded server 有三个 listen 模式：

| 模式 | 监听地址 | 适合 |
| --- | --- | --- |
| Loopback only | `127.0.0.1:<port>` | 默认模式。只给这台电脑自己用，明文、无鉴权 |
| Local network | `0.0.0.0:<port>` | 同一局域网里的手机/平板/电脑直连；自动加密 + psk 配对，扫 Pairing 区的二维码即可 |
| Off | 不开 TCP listener | 只通过 Tailscale 或 relay pairing 访问 |

默认端口是 `7777`。如果端口被占用，在 Server 页的 Listen 区域改成其它端口。

当 embedded server 有 loopback endpoint 时，Motif App 会自动在 Client 页注册一个
`This computer` server。你可以直接从 Client 页进入本机 Session。

### 3.4 认证与加密

不再有单独的 token 设置。**Local network 和 relay pairing 自动加密 + 自动鉴权**：
桌面 App 从持久化的 psk 派生 bearer、用自签证书终止 TLS，并在 **Pairing** 区显示
一个 `motif://pair` 二维码/链接——它就是唯一凭证，无论走 LAN 直连还是 relay 都展示。

Loopback 模式保持明文、无鉴权（只给本机用）。

### 3.5 让其它设备连回这台电脑

**同一局域网直连：**

1. Server 页选择 **Local network**，Start server。
2. 在 **Pairing** 区扫描二维码（或复制链接）。
3. 在手机/平板/另一台电脑的 Motif App 里选 **Pair**，扫码/粘贴即连——自动 `https://`
   + 证书 pin + psk bearer，无需手填 token。

**Tailscale：**

1. Server 页打开 **Enable Tailscale**。
2. Hostname 留空时默认是 `motifd-<host>`；也可以手动设置。
3. 选择官方 Tailscale 或自托管 Headscale。
4. 选择 Browser login，Start 后打开登录 URL；或粘贴 auth key 做 headless 登录。
5. 其它设备在 Motif App 里先连接 Tailscale，再添加 Tailscale server。

如果只想走 tailnet，不想开本地 TCP，把 Listen 设置为 **Off**，同时启用 Tailscale。

**Relay pairing：**

1. Pairing 区打开 **Pair over a relay**。
2. 填 rendezvous relay 地址，例如 `relay.example.com:9999`。
3. Start 或重启 server。
4. Pairing 区会显示 QR 和 pairing link（rzv 形态）。
5. 其它设备在 Motif App 里扫描 QR 或粘贴 link。

这适合手机接入、两端都在 NAT 后、或者不想配置局域网/Tailscale 的场景。前提是你有
可用的 `motif-rendezvous` relay。

**浏览器打开本机 Web UI：**

托盘菜单里的 **Open in Browser** 打开 embedded server 的 Web UI（明文 loopback）。
这个入口只在 server 正在运行且有 loopback endpoint 时出现；LAN/relay 的加密直连请
用 App 扫码（浏览器无法 pin 自签证书）。

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
| Direct TCP | `--listen 0.0.0.0:port` | Local network | 自动加密 + psk 配对，扫码即连；公网用 `--advertise-host` |
| SSH forward | `--listen 127.0.0.1:7777` | 不常用 | 明文 loopback + 已有 SSH 的远端 server |
| Tailscale | `--tailscale` | Enable Tailscale | 适合多设备、NAT 后、移动办公 |
| Rendezvous relay | `--rzv-relay` | Pair over a relay | 适合扫码配对和无直连网络（端到端 TLS pin + psk bearer） |
| Browser same-origin | `motifd` 内嵌 Web UI | Tray Open in Browser | Web client 与 RPC/WS 共用同一个 origin |

## 5. 快速排错

- 打不开 Web UI：先确认 `motifd` 是否在监听，浏览器访问 `/ping` 应返回 Motif server 信息。
- App 显示 `No ping`：host/port 可能不对，或当前网络到不了 server；配对链接里的 pin/psk
  过期（数据目录被清）也会连不上，重新配对即可。
- Tailscale 一直需要登录：打开 Server 页或托盘里的登录 URL，完成授权；headless 环境用 auth key。
- LAN 模式连不上：检查系统防火墙、路由器隔离、端口是否被占用。
- Session 里路径不存在：workdir 是 server 机器上的路径，不是 client 机器上的路径。
- 公网部署：`--listen 0.0.0.0:port` 已自动加密 + psk 鉴权；把 `motif://pair` 链接当密钥保管，
  在防火墙/安全组里开放该端口即可。

相关文档：

- [`web-client.md`](./web-client.md)：`motifd` 内嵌 Web client 的行为。
- [`tailscale.md`](./tailscale.md)：嵌入式 Tailscale / tsnet。
- [`ssh-tunnel.md`](./ssh-tunnel.md)：SSH local forward 连接。
- [`rzv-protocol.md`](./rzv-protocol.md)：rendezvous relay 配对协议。
