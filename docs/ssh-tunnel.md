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

SSH 本身就是个能透传 TCP 的隧道工具（`-L` 端口转发），motif-tui / motif-web 可以**完全无侵入**地走 SSH local forward 到达 motifd。本文档把这条路径明确成 client 的官方支持模式之一。

---

## 2. 两种使用模式

### 2.1 手工模式（零代码）

任何 motif client 已经原生支持。用户自行起 SSH 隧道：

```bash
# 在 client 机器
$ ssh -N -L 17777:127.0.0.1:7777 user@server.example.com
# (此 SSH 进程保持前台，转发本地 17777 → server 上 motifd)

# 另开一个终端
$ motif-tui attach wss://127.0.0.1:17777/ --session work
```

motifd 完全不知道连接是从哪条物理路径来的，只看到 `127.0.0.1` 上的 WS 连接。

**适合**：临时调试、SSH 配置已经特别复杂（多级 ProxyJump）、或不想给 motif-tui 增加 SSH 编排责任。

### 2.2 内建模式（推荐）

`motif-tui` / `motif-web` 自带"开 SSH 隧道并把它跑成子进程"的封装，**不**重写 SSH 协议——直接调用系统 `ssh` 二进制，完整复用用户的 `~/.ssh/config`、ssh-agent、known_hosts、ProxyJump 等设置：

```bash
$ motif-tui attach --via ssh://user@server.example.com --session work
[ssh tunnel established: 127.0.0.1:54321 ↔ server.example.com:7777]
[client A attached]
```

子进程生命周期与 motif-tui 进程绑定：motif-tui 退出时 SSH 自动被 kill。

---

## 3. `--via ssh://` 详细行为

### 3.1 URL 形式

```
ssh://[user@]host[:ssh-port][/?remote_port=N]
```

- `user`：可省，默认与系统 `ssh` 同源（取 `~/.ssh/config` 或 `$USER`）
- `host`：可以是 ssh_config 中的 Host alias（推荐），或 IP/域名
- `ssh-port`：SSH 端口，默认 22（也可放 ssh_config）
- `remote_port`：motifd 在远端机器上的监听端口，默认 7777，可被 `--ssh-remote-port` 覆盖

例：

```bash
$ motif-tui attach --via ssh://prod-jumpbox --session work
$ motif-tui attach --via ssh://fei@10.0.0.5:2222 --ssh-remote-port 17777 --session work
```

### 3.2 spawn 流程

`motif-tui` 调用 `ssh` 子进程的等价命令：

```bash
ssh -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o BatchMode=no \                       # 允许交互式询问 passphrase / 2FA
    -L <random-local-port>:127.0.0.1:<remote_port> \
    [-p <ssh-port>] [user@]host
```

随后流程：

1. 启动子进程后等待 100~500ms 让端口 ready（带超时上限 10s）
2. 持续探测 `127.0.0.1:<random-local-port>` 是否可连接
3. 端口可用 → 把 motif WS URL 替换为 `wss://127.0.0.1:<random-local-port>/`，正常走 [`rpc.md`](./rpc.md) §1 的协议握手
4. motif-tui 退出（正常 / Ctrl-C / panic）→ `Drop` 触发 `kill(child, SIGTERM)`，SSH 子进程清理

### 3.3 端口选择

默认让 OS 在 49152–65535 范围内挑空闲端口（`bind(127.0.0.1:0)` → 取 OS 分配再立即 close 让 ssh 接管），避免硬编码冲突。可被 `--ssh-local-port <N>` 覆盖（用于 firewall / 调试场景需要固定端口的情况）。

### 3.4 失败处理

| 失败点 | 行为 |
|---|---|
| `ssh` 二进制找不到 | 报错指向"装 OpenSSH 或换用 `--via` 的其他模式" |
| SSH 握手失败 / 认证失败 | SSH 子进程的 stderr 直接转发到 motif-tui stderr，让用户看清楚原因（密钥错误、host key 不匹配等） |
| `ExitOnForwardFailure` 触发 | motif-tui 立即报错并退出，不会假装连接成功 |
| 隧道建立后中途断开 | motif-tui 收到 WS read error，触发它的标准重连逻辑（[`prd.md`](./prd.md) §4.1）；同时 detect SSH 子进程已退出 → 重新 spawn 隧道再 WS 重连 |

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

## 5. `motif-web` 的 SSH 模式

motif-web 的桥接路径同样可以走 SSH：

```bash
motif-web \
  --listen :8080 \
  --motifd-via ssh://user@motifd-host \
  --motifd-token-file /etc/motif/motifd.token \
  --browser-token-file /etc/motif/web.token
```

实现等同于 motif-tui 内建模式：起一个长期运行的 SSH 子进程做 local forward，`motifd-url` 内部展开为 `wss://127.0.0.1:<random-port>/`。

注意事项：

- 长生命周期场景建议在 SSH 命令里加 `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`（默认值），断线由 motif-web 监控并重启 SSH 子进程
- SSH 认证最好用 key 而非交互式（运维场景下没人会去敲 passphrase）
- 推荐配合 `restrict` shell 或 `command="..."` 限制 ssh 用户只允许 forward，最小化暴露面

---

## 6. 与 Tailscale 的对比

| 维度 | SSH 隧道 | Tailscale 嵌入 |
|---|---|---|
| 服务器准备 | 已有 SSH 即可（一条 sshd） | 安装系统 Tailscale daemon |
| 客户端准备 | 已有 OpenSSH（macOS/Linux 默认带） | bundled feature 默认开 → 需要 Go；prebuilt 拉文件 |
| 二进制大小影响 | **零**（不引入新依赖） | +20 MB |
| 网络穿透 | 依赖 SSH 服务可达（公网或同网） | NAT 穿透 + DERP relay |
| 多设备访问 | 每个客户端各连各的 SSH | 统一 tailnet 视图，互访方便 |
| 身份模型 | OS 层（SSH 用户 + key） | 控制台 OAuth / auth key |
| 适用场景 | 跳板机 / VPS / 临时调试 / 受限网络 | 个人多设备、移动办公、跨区域 |

两者**并行存在**、**不互斥**：用户可以根据每次连接选择 `--via ssh://` 或 `--via tailnet`。motif-tui 的"启发式默认"也会综合考虑（host 像 ssh_config alias 时倾向 ssh，像 MagicDNS 时倾向 tailnet；二者都不像就走 direct）。

---

## 7. 启发式路由（汇总）

`motif-tui attach <target>` 在没有 `--via` 时按以下顺序判断：

1. 完整 URL（`wss://...`、`ws://...`）→ 直接连
2. host 形如 ssh_config 中存在的 alias（探测 `~/.ssh/config` 里的 Host 段）→ ssh 模式
3. host 含 `.ts.net` 后缀或不含点 → Tailscale 模式（仅当 `tailscale` feature 启用且已 up）
4. 其它 → direct 模式
5. 启发式失败 fallback：先 ssh（如果 host 在 ssh_config 中）→ tailnet → direct，每步带提示

显式指定永远胜过启发式：`--via direct|tailnet|ssh://...` 是最终 source of truth。

---

## 8. 实现要点（落到 motif-tui / motif-web）

放在 `motif-tui` lib（不需要新 crate）：

```rust
// crates/motif-tui/src/transport/ssh.rs
pub struct SshTunnel {
    child:        tokio::process::Child,
    local_addr:   SocketAddr,
    remote_host:  String,
    remote_port:  u16,
}

impl SshTunnel {
    pub async fn open(target: &SshTarget, remote_port: u16) -> Result<Self>;
    pub fn local_url(&self) -> String { format!("ws://{}/", self.local_addr) }
}

impl Drop for SshTunnel {
    fn drop(&mut self) {
        // SIGTERM child, wait briefly, SIGKILL if still alive
        let _ = self.child.start_kill();
    }
}
```

依赖：`tokio::process`、`tokio::net::TcpStream`（用于探测端口）；不引新外部 crate。

---

## 9. 开放问题

- [ ] **是否要在 `--via ssh://` 后面允许 `ssh -J` 风格的多级跳板**？倾向**不**显式做，让用户在 ssh_config 里写 `ProxyJump`，motif-tui 调 `ssh <alias>` 自动继承。
- [ ] **Windows 兼容**：默认 SSH client 是 OpenSSH for Windows（Win10+ 自带）。需要在文档里明确不支持 PuTTY 的 plink；要支持的话需要额外适配命令行格式。倾向 v1.5 只测试 OpenSSH，PuTTY 不做。
- [ ] **断线重连时是否复用同一隧道**：当前设计是断了重起 SSH 子进程；可以做"先尝试同隧道 WS 重连，再 fallback 重起隧道"减少 SSH 握手开销。v1.5 简单做即可，不重连优化。

---

## 10. 与已有文档的关系

- [`prd.md`](./prd.md) §7 "连通性" 段落统一指向本文档与 [`tailscale.md`](./tailscale.md)。
- [`web-client.md`](./web-client.md) 的 motif-web `--motifd-via` 参数选择列表（direct / tailnet / ssh）会引用本文档作为 ssh 选项的事实标准。
