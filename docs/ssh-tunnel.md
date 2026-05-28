# Motif — SSH 隧道连接（Client 侧）

> 客户端通过 SSH local forward 到达远端 motifd 的方案。与 [`tailscale.md`](./tailscale.md) 并列，是 client 反向接入私网的另一条路径。
>
> 阅读前提：[`prd.md`](./prd.md) §3、§7。

---

## 1. Context

许多场景下用户已有 SSH 接入：

- 公司跳板机 / bastion，进得去内网 SSH 但其它端口都不通
- 家里 VPS 仅暴露 SSH，不愿额外开端口
- 临时调试别人的机器：你有 SSH 凭据，但对方没装 Tailscale 也不让你装

SSH 本身就是个能透传 TCP 的隧道工具（`-L` 端口转发），motif-tui（以及通过它复用代码的 motif-client）可以**完全无侵入**地走 SSH local forward 到达 motifd；浏览器侧则直接连本地转发出来的端口、走 motifd 内嵌的 Web UI（见 `crates/motif-server/src/embed.rs`）。本文档把这条路径明确成 client 的官方支持模式之一。

---

## 2. 两种使用模式

### 2.1 手工模式（零代码）

任何 motif client 已经原生支持。用户自行起 SSH 隧道：

```bash
# 在 client 机器
$ ssh -N -L 17777:127.0.0.1:7777 user@server.example.com
# (此 SSH 进程保持前台，转发本地 17777 → server 上 motifd)

# 另开一个终端 —— picker 自动探测 127.0.0.1，所以显式指定本地转发口即可
$ motif-tui --host 127.0.0.1:17777

# 或者直接用浏览器打开 motifd 内嵌的 Web UI：
$ open http://127.0.0.1:17777/
```

motifd 完全不知道连接是从哪条物理路径来的，只看到 `127.0.0.1` 上的 HTTP / WS 连接。

**适合**：临时调试、SSH 配置已经特别复杂（多级 ProxyJump）、或不想给 motif-tui 增加 SSH 编排责任。

### 2.2 内建模式（推荐）

`motif-tui`（实现在 `motif-client` 中，见 `crates/motif-client/src/transport/ssh.rs`）自带"开 SSH 隧道并把它跑成子进程"的封装，**不**重写 SSH 协议——直接调用系统 `ssh` 二进制，完整复用用户的 `~/.ssh/config`、ssh-agent、known_hosts、ProxyJump 等设置：

```bash
$ motif-tui --via ssh://user@server.example.com
[ssh tunnel established: 127.0.0.1:54321 ↔ server.example.com:7777]
[motif picker — select a session and press Enter to attach]
```

`--via` 是 `motif-tui` 顶层的全局 flag（见 `crates/motif-tui/src/main.rs::Cli`）。motif-tui 启动后直接进 picker，所以指定 `--via` 一次即可对全部 session 管理 + attach 生效。子进程生命周期与 motif-tui 进程绑定：motif-tui 退出时 `SshTunnel::Drop` 触发 SIGTERM，SSH 自动被 kill。

`motif-cast` 的 `--via` 同样是顶层 flag，启动时打开一次 SSH 隧道、cast 结束随进程退出。

---

## 3. `--via ssh://` 详细行为

### 3.1 URL 形式

```
ssh://[user@]host[:ssh-port]
```

实际解析见 `crates/motif-client/src/transport/ssh.rs::parse_target`：从右往左按最后一个 `:` 拆分，前段（含 `user@`）整体作为 ssh 的 target 参数，后段（如能解析成 u16）作为 SSH 端口。

- `user`：可省，默认与系统 `ssh` 同源（取 `~/.ssh/config` 或 `$USER`）
- `host`：可以是 ssh_config 中的 Host alias（推荐），或 IP/域名
- `ssh-port`：SSH 端口，默认 22（也可放 ssh_config）
- 远端 motifd 端口：默认 7777，可被顶层 `--ssh-remote-port <N>` 覆盖（参考 `crates/motif-tui/src/main.rs::Cli`）

例：

```bash
$ motif-tui --via ssh://prod-jumpbox
$ motif-tui --via ssh://fei@10.0.0.5:2222 --ssh-remote-port 17777
```

> 注：`--via ssh://...` 启用时 motif-tui 内部把连接 URL 替换为 `127.0.0.1:<本地转发端口>`；顶层 `--host` 与 `--via` 互斥地决定目标，`--via` 启用时 `--host` 被忽略。

### 3.2 spawn 流程

`motif-tui` 调用 `ssh` 子进程的等价命令（实际见 `crates/motif-client/src/transport/ssh.rs::SshTunnel::open`）：

```bash
ssh -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -L <random-local-port>:127.0.0.1:<remote_port> \
    [-p <ssh-port>] [user@]host
```

随后流程：

1. 启动子进程后每 50ms 轮询 `127.0.0.1:<random-local-port>`，最长等 15s（`READY_TIMEOUT`）
2. 端口可用 → 把 motif 连接 URL 替换为 `127.0.0.1:<random-local-port>`，正常走 motifd 的 HTTP `/rpc/<method>`、WS `/events`、WS `/pty/<id>`（协议见 [`rpc.md`](./rpc.md)）
3. 如果 ssh 子进程提前退出（认证失败、`ExitOnForwardFailure` 触发等），stderr 直接回显给用户
4. motif-tui 退出（正常 / Ctrl-C / panic）→ `Drop` 触发 `start_kill()`（`kill_on_drop(true)` 兜底），SSH 子进程清理

### 3.3 端口选择

默认让 OS 挑空闲端口（`bind(127.0.0.1:0)` → 取 OS 分配再立即 `drop` 让 ssh 接管，见 `pick_local_port`），避免硬编码冲突。当前不暴露固定本地端口的 flag；若有需要再加。

### 3.4 失败处理

| 失败点 | 行为 |
|---|---|
| `ssh` 二进制找不到 | 报错指向"装 OpenSSH 或换用 `--via` 的其他模式" |
| SSH 握手失败 / 认证失败 | SSH 子进程的 stderr 直接转发到 motif-tui stderr，让用户看清楚原因（密钥错误、host key 不匹配等） |
| `ExitOnForwardFailure` 触发 | motif-tui 立即报错并退出，不会假装连接成功 |
| 隧道建立后中途断开 | motif-tui 的 HTTP / WS 调用收到 connection reset / I/O error，触发它的标准重连逻辑（[`prd.md`](./prd.md) §4.1）；同时 detect SSH 子进程已退出 → 重新 spawn 隧道再连 |

---

## 4. 认证

**完全委托给系统 `ssh`**：

- 公钥 / 密码 / passphrase / FIDO2 / kerberos：随用户 `ssh` 平时怎么配就怎么用
- ssh-agent：自动用上
- 多因素认证：`BatchMode=no` 允许 SSH 交互式询问，TUI 模式下需要让 ratatui 让屏（与 `$EDITOR` 启动逻辑共用）
- known_hosts / host key checking：默认走 `~/.ssh/known_hosts`，第一次连接会询问，与裸 SSH 行为一致

motif-tui **不**保存任何 SSH 凭据。这意味着：

- 已经配好 SSH 的用户零额外配置
- 没配的用户先解决 `ssh user@host` 能登上去，再用 `--via ssh://` 才会顺

这是有意的范围切割，与 `motif-tui` 直接 `$EDITOR` 而不内嵌编辑器同款思路。

---

## 5. 浏览器侧的 SSH 模式

Web UI 内嵌在 motifd（见 `crates/motif-server/src/embed.rs` + `motif-server/src/ws.rs::router` 上的 `/` 与 `/assets/*p` 路由）。浏览器走 SSH 的姿势就是经典的 `ssh -L`：

```bash
# 在 client 机器上保留一个长期 forward
$ ssh -N \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L 8080:127.0.0.1:7777 \
    user@motifd-host
```

然后浏览器打开 `http://127.0.0.1:8080/`，加载到的就是 motifd 自己 serve 的 SPA，所有 RPC / events / PTY 流量复用同一个 forward。

注意事项：

- 长生命周期场景建议进程化管理这条 SSH（systemd user unit / launchd / `autossh`），断了重起即可
- SSH 认证最好用 key 而非交互式（运维场景下没人会去敲 passphrase）
- 推荐配合 `restrict` shell 或 `command="..."` 限制 ssh 用户只允许 forward，最小化暴露面
- 如果 motifd 启用了 token，浏览器用 `Authorization: Bearer <token>` 调 `/rpc/*`，WS 路径用 `?token=<v>` 查询参数 fallback（见 `crates/motif-server/src/auth.rs::verify_header_or_query`）；no-auth motifd 可以在 Web 登录页留空 token

---

## 6. 与 Tailscale 的对比

| 维度 | SSH 隧道 | Tailscale 嵌入 |
|---|---|---|
| 服务器准备 | 已有 SSH 即可（一条 sshd） | motifd 加 `--tailscale` 起嵌入式 tsnet listener（构建时 motif-server 已自带 tailscale-bundled），或者机器跑系统 Tailscale daemon |
| 客户端准备 | 已有 OpenSSH（macOS/Linux 默认带） | motif-tui 需要用 `--features tailscale-bundled` 构建（需要本机 Go） |
| 二进制大小影响 | **零**（不引入新依赖） | +20 MB 量级 |
| 网络穿透 | 依赖 SSH 服务可达（公网或同网） | NAT 穿透 + DERP relay |
| 多设备访问 | 每个客户端各连各的 SSH | 统一 tailnet 视图，互访方便 |
| 身份模型 | OS 层（SSH 用户 + key） | 控制台 OAuth / auth key |
| 适用场景 | 跳板机 / VPS / 临时调试 / 受限网络 | 个人多设备、移动办公、跨区域 |

两者**并行存在**、**不互斥**：用户可以根据每次连接选择 `--via ssh://...` 或 `--via tailscale://...`（详见 [`tailscale.md`](./tailscale.md) §7.2）。

---

## 7. 路由决策（现状）

实际逻辑见 `crates/motif-client/src/transport/mod.rs::connect_v2`：

1. 传了 `--via direct` 或不传 `--via` → 直接对 URL 里的 host:port 做 TCP connect
2. `--via ssh://...` → 起 SSH local-forward 子进程（本文档主题）
3. `--via tailscale://...` → 起嵌入式 tsnet 节点（要求 `tailscale-bundled`，见 [`tailscale.md`](./tailscale.md)）
4. 其它 scheme → 报错 "unsupported --via scheme"

**当前没有基于 host 形态的启发式自动 fallback**：没传 `--via` 就直连，host 是 ssh_config alias 也不会自动起 ssh 隧道。如果以后要做，会在这里更新规范。

---

## 8. 实现要点

实际落到 `motif-client`（被 `motif-tui` 复用），见 `crates/motif-client/src/transport/ssh.rs`：

```rust
// crates/motif-client/src/transport/ssh.rs
pub struct SshTunnel {
    child:      tokio::process::Child,
    local_port: u16,
}

impl SshTunnel {
    pub async fn open(target: &str, remote_port: u16) -> anyhow::Result<Self>;
    pub fn local_ws_url(&self) -> String { format!("ws://127.0.0.1:{}/", self.local_port) }
    pub fn local_port(&self) -> u16 { self.local_port }
}

impl Drop for SshTunnel {
    fn drop(&mut self) {
        // tokio Command 用 kill_on_drop(true) 兜底，这里再显式 start_kill
        let _ = self.child.start_kill();
    }
}
```

调用方在 `crates/motif-client/src/transport/mod.rs::connect_v2_ssh` 里把 `local_port` 拼成 `127.0.0.1:<port>`，作为 HTTP/WS 的目标 authority，原 URL 的 host 被丢弃。依赖：`tokio::process`、`std::net::TcpStream`（端口探测）、`which`（探测系统 ssh）。

---

## 9. 开放问题

- [ ] **是否要在 `--via ssh://` 后面允许 `ssh -J` 风格的多级跳板**？倾向**不**显式做，让用户在 ssh_config 里写 `ProxyJump`，motif-tui 调 `ssh <alias>` 自动继承。
- [ ] **Windows 兼容**：默认 SSH client 是 OpenSSH for Windows（Win10+ 自带）。需要在文档里明确不支持 PuTTY 的 plink；要支持的话需要额外适配命令行格式。倾向 v1.5 只测试 OpenSSH，PuTTY 不做。
- [ ] **断线重连时是否复用同一隧道**：当前设计是断了重起 SSH 子进程；可以做"先尝试同隧道 WS 重连，再 fallback 重起隧道"减少 SSH 握手开销。v1.5 简单做即可，不重连优化。

---

## 10. 与已有文档的关系

- [`prd.md`](./prd.md) §7 "连通性" 段落统一指向本文档与 [`tailscale.md`](./tailscale.md)。
- [`web-client.md`](./web-client.md) — Web UI 现已内嵌在 motifd 进程，浏览器走 SSH 的方案见本文档 §5。
