# Motif — Tailscale 集成

> 本文档描述 motif-tui / motif-client 以及 motifd 本身如何通过嵌入 [`libtailscale`](https://github.com/tailscale/libtailscale) 直接成为 tailnet 节点，不依赖系统 Tailscale daemon。
>
> 协议核心代码（session / pty / git / fs / rpc）不感知 Tailscale；tsnet 集成被收敛到 `motif-tailscale` + `motif-net::Listener` 这一层。motifd 通过 `--tailscale*` 一组 flag 启用嵌入式 tsnet listener（见 `crates/motif-server/src/main.rs` 与 `crates/motif-server/src/config.rs::TailscaleListenConfig`）；客户端通过 `--via tailscale://...` 启用嵌入式 tsnet dial（见 `crates/motif-client/src/transport/mod.rs::connect_v2_tailscale`）。
>
> 阅读前提：已熟悉 [`prd.md`](./prd.md) §3（架构）。

---

## 1. Context

部署 motifd 的机器（MacBook、家里的小主机、办公室工作站）通常在 NAT 后面。让 client 能从任意地方接入而不依赖端口转发或 ngrok-style 隧道，常见方案是 mesh VPN，Tailscale 是用户基数最大的一家。

但用户在 client 端机器（笔记本、容器、CI runner）上**也要装一遍 Tailscale daemon** 才能加入 tailnet——这是 motif 的 v1 推荐做法（见 [`prd.md`](./prd.md) §7 部署示例），但每台 client 的初始化成本仍然存在。

`libtailscale` 是 Tailscale 官方的 C 封装，把 Go 实现的 `tsnet` 包装成 C-ABI，链接进 motif 二进制后该二进制本身就是 tailnet 上的一个节点：

- 用户机器**不需要装 Tailscale daemon**
- `motif-tui --via tailscale://my-mac` 在任意机器上即开即用（前提是该 motif-tui 用 `--features tailscale-bundled` 构建）
- motifd 也可以自己加入 tailnet（`motifd --tailscale --tailscale-port 7777 ...`），让所有 client 通过 tailnet 反向接入私网中的 motifd；浏览器则连 motifd 内嵌的 Web UI（`crates/motif-server/src/embed.rs`）

---

## 2. 范围与边界

### In-scope

- `motif-tailscale` crate：libtailscale 的 Rust safe wrapper（`bundled` feature 链接真实 libtailscale；不开则编译期 stub，运行时调用返回 `TsError::Unimplemented`）
- `motif-net` 把 tsnet 收敛进统一的 `Listener` / `dial` 接口（feature 透传：`tailscale` = 引入 motif-tailscale 的 stub；`tailscale-bundled` = bundled）
- `motif-client` / `motif-tui`：feature `tailscale` 引入 stub、`tailscale-bundled` 引入真实 tsnet；`--via tailscale://hostname[:port]` 走嵌入式 tsnet dial；`motif-tui list-servers --prefix motifd-` 列出 tailnet 上 motifd 节点（要求 `tailscale-bundled`）
- `motif-server`（motifd 二进制）：通过 `--tailscale` / `--tailscale-hostname` / `--tailscale-port` / `--tailscale-authkey` / `--tailscale-control-url` / `--tailscale-ephemeral` / `--tailscale-state-dir` 启用嵌入式 tsnet listener；可与 `--listen` 共存或单独使用
- `bundled` 需要 build 时有 Go 1.20+；`prebuilt`（从 release 下载预编译产物）是 v2 计划，暂未实现（见 `crates/motif-tailscale/Cargo.toml`）
- 不带 tailscale feature 时整个 crate 可以编译，二进制完全去掉 libtailscale 依赖

### 明确 Non-goals

- ❌ 协议核心（rpc / session / pty / git / fs / events）不感知 Tailscale。motifd 的核心仍然只是 axum + WS/HTTP，监听层抽象在 `motif-net::Listener` 后面——开启 `--tailscale` 只是多绑一个 tsnet listener，不改协议。
- ❌ Tailscale 替换 motif 自己的 Bearer token。两套机制并存，Tailscale 给 connectivity，Bearer 给应用层鉴权（见 `crates/motif-server/src/auth.rs`）；不做"以 Tailscale 身份替代 token"。
- ❌ 不维护自己的 fork。直接 vendor libtailscale 上游 release tag，跟随升级。
- ❌ Tailscale Funnel（公网暴露）/ Serve（HTTPS 反代）等高级功能不集成；只用最核心的 tsnet 节点能力。

---

## 3. 架构

两侧都能嵌入 tsnet，互不依赖系统 Tailscale daemon：

```
   ┌──────────────────────────────────┐         ┌──────────────────────────────────┐
   │  motif-tui 二进制                 │         │  motifd 二进制                    │
   │  (with --features tailscale-     │         │  (--tailscale --tailscale-port    │
   │   bundled)                       │         │   7777 ...)                      │
   │  ┌────────────────────────────┐  │         │  ┌────────────────────────────┐  │
   │  │ Rust 业务代码 (motif-tui   │  │         │  │ axum + 协议核心 (rpc/     │  │
   │  │  / motif-client)           │  │         │  │  session/pty/git/fs)      │  │
   │  │  ↓ via motif-net::dial     │  │         │  │  ↑ axum::serve(listener) │  │
   │  │ motif-tailscale::TsServer  │  │         │  │ motif-net::Listener      │  │
   │  │  ↓ FFI                     │  │         │  │  ↑ accept tsnet          │  │
   │  │ libtailscale.a (静态链接)  │  │         │  │ motif-tailscale::TsServer│  │
   │  │  ├─ Go runtime             │  │         │  │  ↓ FFI                   │  │
   │  │  └─ tsnet                  │  │         │  │ libtailscale.a            │  │
   │  └─────────────┬──────────────┘  │         │  └─────────────┬─────────────┘  │
   │   state: ~/.cache/motif/tsnet   │         │   state: $XDG_DATA_HOME/motifd/ │
   │   hostname: motif-client         │         │             tsnet                │
   └─────────────────┼────────────────┘         │   hostname: motifd-<host>        │
                     │                          └─────────────────┼────────────────┘
                     │       tailnet (WireGuard, E2E 加密)        │
                     └─────────────────────────────────────────────┘
```

**关键**：

- libtailscale 把 Go runtime + tsnet 编成一个 C archive，Rust 端通过 FFI 调用。运行时这是单一进程（Go runtime 寄生在宿主 Rust 进程内），**不是** sidecar 模式。
- motifd 既可以只绑 TCP（`--listen 127.0.0.1:7777`），也可以只绑 tsnet（`--tailscale`），还可以两者都绑——`ServerConfig::validate` 只要求至少有一个。`crates/motif-net/src/listener.rs` 内部把两路 accept 合并到统一的 `Listener`。
- 客户端拿到的连接：tsnet 给 dial 出来的是普通的 `TsStream`，实现了 `AsyncRead + AsyncWrite`，对上层 HTTP / WS 代码透明。
- 浏览器侧：浏览器自身不会嵌 tsnet。如果想让浏览器经 tailnet 访问 motifd，方案是 motifd 自己加入 tailnet 后浏览器直接 `http://motifd-<host>:7777/`（client 机器需要装 Tailscale 或在 tailnet 里）；或者结合 ssh forward（见 [`ssh-tunnel.md`](./ssh-tunnel.md)）。

---

## 4. `motif-tailscale` crate

### 4.1 文件结构

```
crates/motif-tailscale/
├─ Cargo.toml                  # 依赖 libtailscale = "0.2"（来自 crates.io）
└─ src/
   ├─ lib.rs                   # 公共 API；按 feature 把 bundled / stub 切给上层
   ├─ bundled.rs               # 真实实现：包裹 libtailscale-sys（TsServer / TsListener / TsStream / LocalClient）
   └─ stub.rs                  # feature 关闭时的占位：所有方法返回 TsError::Unimplemented
```

libtailscale 的 C 构建过程由上游 `libtailscale` / `libtailscale-sys` crate 自己的 build.rs 完成；本 crate 不维护 `vendor/` 或 `build.rs`。

### 4.2 Features

```toml
# crates/motif-tailscale/Cargo.toml
[features]
default  = []
bundled  = ["dep:libtailscale", ...]   # 链接真实 libtailscale（要求构建机有 Go 1.20+）
prebuilt = []                          # v2 计划，暂未实现
```

下游构建是分层透传的：`motif-net` → `motif-client` → `motif-tui` 各自暴露 `tailscale` 与 `tailscale-bundled` 两个 feature。motifd（`motif-server`）目前**硬启用** `motif-net/tailscale-bundled`（见 `crates/motif-server/Cargo.toml`），所以 `motifd` 二进制开箱即支持 `--tailscale`，构建机需要 Go。

```toml
# crates/motif-tui/Cargo.toml（节选）
[features]
default            = []
tailscale          = ["motif-client/tailscale"]
tailscale-bundled  = ["tailscale", "motif-client/tailscale-bundled"]
```

```toml
# crates/motif-client/Cargo.toml（节选）
[features]
default            = []
tailscale          = ["motif-net/tailscale"]
tailscale-bundled  = ["tailscale", "motif-net/tailscale-bundled"]
```

用户构建路径：

| 命令 | 行为 |
|---|---|
| `cargo build -p motif-tui` | 默认不带 Tailscale，纯 Rust，无 Go 依赖；`list-servers` / `--via tailscale://` 运行时报错 |
| `cargo build -p motif-tui --features tailscale-bundled` | 真实嵌入 tsnet —— 需要本机 Go 1.20+ |
| `cargo build -p motif-tui --features tailscale` | 编进 stub，类型一致但运行时返回 `TsError::Unimplemented`（CI / 不需要 tsnet 的发行版本用） |
| `cargo build -p motif-server` | 已经包含真实 tsnet（motif-net 这条依赖上写死了 `tailscale-bundled`）；`--tailscale` 即开即用 |

### 4.3 安全封装设计

实际暴露的最小有用集合（见 `crates/motif-tailscale/src/bundled.rs`）：

```rust
pub struct TsServer { /* 内部持 libtailscale handle */ }

impl TsServer {
    pub fn new(opts: TsOptions) -> Result<Self, TsError>;
    pub async fn up(&mut self) -> Result<(), TsError>;              // 阻塞直到加入 tailnet 完成
    pub async fn dial_tcp(&self, addr: &str) -> Result<TsStream, TsError>;
    pub async fn listen(self: &Arc<Self>, port: u16) -> Result<TsListener, TsError>;
    pub async fn list_peers(&self) -> Result<Vec<TsPeer>, TsError>;  // LocalAPI 拿 netmap
    pub async fn backend_status(&self) -> Result<TsBackendStatus, TsError>;
    pub fn spawn_status_watcher(self: Arc<Self>) -> tokio::task::JoinHandle<()>;
}

pub struct TsListener { /* accept() -> (TsStream, SocketAddr) */ }
pub struct TsStream   { /* impls tokio AsyncRead + AsyncWrite */ }

pub struct TsOptions {
    pub hostname:     String,         // 出现在 tailnet 上的设备名
    pub state_dir:    PathBuf,        // 持久化 auth + machine key
    pub authkey:      Option<String>, // 首次登录用，后续从 state 恢复
    pub control_url:  Option<String>, // 自托管 Headscale 时用
    pub ephemeral:    bool,           // true = 退出即从 tailnet 移除
}
```

`TsListener` 与 `TsStream` 实现 tokio 的 IO trait，可以**透明**接入 axum / `tokio-tungstenite`、HTTP 客户端等代码——上层不用关心走的是 TCP 还是 tsnet。`motif-net::Listener` / `motif-net::dial` 就是这种透明 dispatch。

---

## 5. 构建依赖

### 5.1 Bundled（启用 `tailscale-bundled` feature）

链路完全交给上游 `libtailscale = "0.2"` / `libtailscale-sys` crate 的 build.rs 处理：

- 上游 build.rs 调本机 `go` 把 tsnet 编成 c-archive，需要 Go 1.20+
- 链接库 / 平台框架（macOS `CoreFoundation` + `Security`；Linux `pthread` + `dl`）由上游 build.rs 通过 `cargo:rustc-link-*` 自动输出
- 本 crate 不维护自己的 `vendor/` 或 `build.rs`

### 5.2 Prebuilt

v2 计划，未实现。`crates/motif-tailscale/Cargo.toml::features` 里仍留有 `prebuilt` 名字作为占位，但没有任何下载/校验逻辑。

### 5.3 完全 opt-out

```bash
cargo build -p motif-tui                       # 不带 Tailscale，二进制小很多
cargo build -p motif-tui --features tailscale  # 编进 stub：调用会 Err，但类型一致
```

motif-tailscale 整个 crate 不被引入（或只引入 stub 路径）。失去的能力：

- `motif-tui list-servers` 子命令报"requires --features tailscale-bundled"并退出（见 `crates/motif-tui/src/lib.rs::cmd_list_servers` 的 cfg 分支）
- `--via tailscale://...` 走不通
- 用户可手动跑系统 Tailscale daemon 实现连通性，或用 `--via ssh://...` 走 SSH 隧道

---

## 6. Auth & State

### 6.1 首次运行

两条路径，按优先级：

1. **预置 authkey**：服务端走 `--tailscale-authkey <key>`；客户端走环境变量 `MOTIF_TS_AUTHKEY`（见 `motif-client/src/transport/mod.rs::default_client_ts_options`）。适合脚本、CI、容器化。
2. **交互式 OAuth**：未提供 key 时，`TsServer::up()` 让 libtailscale 在 stderr 打印
   ```
   To authenticate, visit:
       https://login.tailscale.com/a/abc123def456
   ```
   用户在浏览器完成登录，状态自动写到 state dir，后续启动免登录。motifd 启动时还会额外 WARN 一条提示，避免日志噪声中错过登录 URL（见 `crates/motif-server/src/lib.rs::serve`）。

### 6.2 State 目录

每个二进制独立 state（不共享）：

| 二进制 | 默认路径 | 覆盖方式 |
|---|---|---|
| `motifd` | `$XDG_DATA_HOME/motifd/tsnet`（缺省 `~/.local/share/motifd/tsnet`） | `--tailscale-state-dir` |
| `motif-tui` / `motif-client` | `~/.cache/motif/tsnet` | 环境变量 `MOTIF_TS_STATE_DIR` |

实际路径解析见 `crates/motif-server/src/main.rs::default_ts_state_dir` 与 `crates/motif-client/src/transport/mod.rs::default_state_dir`。

### 6.3 重新认证

- 删除 state 目录 → 下次启动重新走 OAuth / authkey
- 客户端推荐 `MOTIF_TS_EPHEMERAL=1`（或 motifd 加 `--tailscale-ephemeral`）让短生命周期场景退出即从 tailnet 移除——但客户端默认是 `ephemeral=false`（见 `default_client_ts_options` 的注释，与 tsnet 1.94 的 Loopback 行为有兼容性顾虑）
- 当前没有专门的 `logout` 子命令；按需用文件系统操作清 state

---

## 7. `motif-tui` 集成

### 7.1 子命令

```bash
# 列出 tailnet 上的 motifd 节点（按 hostname 前缀过滤）
$ motif-tui list-servers --prefix motifd-
HOSTNAME                                 TAILNET IP         ONLINE  OS
motifd-laptop                            100.64.1.2         yes     macOS
motifd-workstation                       100.64.1.5         yes     linux
```

实现见 `crates/motif-tui/src/lib.rs::cmd_list_servers`：起一个临时 tsnet client 节点（用 `default_client_ts_options`），调 `TsServer::list_peers()` 拿 netmap，按 hostname 前缀过滤后打表。要求构建时打开 `tailscale-bundled`。

目前没有 `hosts` / `whoami` / `logout` 子命令——`list-servers` 覆盖了"发现 motifd 节点"这一最常用诉求；身份调试可以临时用 `tailscale status` / 直接看 state dir。

### 7.2 attach 走向

`motif-tui` 顶层有一个统一的 `--via` flag（见 `crates/motif-tui/src/main.rs::Cli`），目前只识别三个 scheme：

| `--via` 值 | 行为 |
|---|---|
| 不传 / `direct` | 对 `--host` 解析出的 host:port 做 TCP connect（不传 `--host` 时默认 `ws://127.0.0.1:7777`） |
| `ssh://[user@]host[:port]` | 起 SSH 子进程 local-forward，连接目标被换成 `127.0.0.1:<本地端口>`，见 [`ssh-tunnel.md`](./ssh-tunnel.md) |
| `tailscale://hostname[:port]` | 起嵌入式 tsnet 节点，用 `TsServer::dial_tcp` 直接连 tailnet 上的 `hostname:port`（默认 7777） |

`tailscale://` 与 `ssh://` 都让 `--host` 失效（连接目标由 `--via` 决定）。例：

```bash
$ motif-tui --via tailscale://motifd-laptop
$ motif-tui --via tailscale://motifd-laptop:7777
```

`motif-cast --via tailscale://...` 同理。

> 启发式自动 fallback（基于 host 形态、ssh_config 命中等）是计划中的能力，**当前未实现** —— 没传 `--via` 就是直连，`--host` 必须指向 motifd 实际监听的地址。

---

## 8. `motifd` 集成（嵌入式 tsnet listener）

### 8.1 启动参数

```bash
motifd \
  --listen 127.0.0.1:7777 \                           # 可选：本地仍然能直连
  --tailscale \                                       # 启用嵌入式 tsnet listener
  --tailscale-hostname motifd-laptop \                # 默认 motifd-<system-hostname>
  --tailscale-port 7777 \                             # tailnet 上的监听端口
  --tailscale-authkey "$(cat /etc/motif/ts.authkey)" \# 首次 / 无人值守用，缺省时启动会打印 OAuth URL
  --tailscale-state-dir /var/lib/motifd/tsnet \       # 默认 $XDG_DATA_HOME/motifd/tsnet
  --tailscale-control-url https://hs.example.com \    # Headscale 自托管时填
  --tailscale-ephemeral \                             # 退出即从 tailnet 移除
  --token-file /etc/motif/motifd.token
```

`--listen` 与 `--tailscale` 可独立开关，至少有一个；`ServerConfig::validate` 兜底校验（见 `crates/motif-server/src/config.rs`）。两边都开时 `motif-net::Listener` 并行 accept，业务层共享一套 axum router。

### 8.2 仅暴露 tailnet 的部署

不要 TCP 暴露时：

```bash
motifd --tailscale --tailscale-port 7777 --token-file /etc/motif/motifd.token
```

可以无 token 启动（loopback / tailnet-only 是 ServerConfig::validate 允许的"private surface"），但会 WARN 一条提示——生产环境强烈建议保留 token。

### 8.3 客户端到 motifd 的连接

- 命令行：`motif-tui ... --via tailscale://motifd-laptop --session work`（详见 §7.2）
- 浏览器：直接访问 `http://motifd-laptop:7777/`（前提是浏览器所在机器在 tailnet 内，比如开了 Tailscale 客户端或在嵌入式 tsnet 桥的局域网里）；motifd 自带 Web UI 与 RPC 在同端口同源
- iOS app / native client：调用 `TsServer::dial_tcp("motifd-laptop:7777")`，复用同一套 tsnet wrapper

---

## 9. 命名 & 设备生命周期

- motifd 默认 hostname：`motifd-<sanitized-system-hostname>`，DNS-safe 小写化（见 `crates/motif-server/src/main.rs::default_ts_hostname`），可被 `--tailscale-hostname` 覆盖
- motif-tui / motif-client 默认 hostname：`motif-client`（**固定字符串**，所以多个客户端机器会复用同一个 tailnet device entry，便于 ACL；可用 `MOTIF_TS_HOSTNAME` 覆盖让不同机器各占一个 device）
- 默认 `ephemeral=false`：motifd 一直在 tailnet 上挂着便于查找；客户端这边也默认 false（与 tsnet 1.94 的 Loopback 兼容性顾虑相关，详见 `default_client_ts_options` 注释）。CI / 容器场景显式开 ephemeral
- Tailscale 控制台建议给这些设备打 tag：`tag:motif-server` 与 `tag:motif-client`，便于写 ACL（见 §11）

---

## 10. 二进制体积

数量级预估（macOS arm64、release 构建）：

| 配置 | motif-tui | motifd |
|---|---|---|
| 含 bundled tailscale | ~25 MB | ~30 MB（Web UI 静态资源也内嵌） |
| 默认（无 tailscale，stub 也不编） | ~5 MB | motifd 当前硬启用 tailscale-bundled，没有这个档位 |

`strip` 后 motif-tui 通常能压到 ~18 MB（Go runtime 是不太能 strip 掉的部分）。对开发工具来说可接受。具体数字会随依赖升级浮动；以上是数量级参考，不是 CI 保证。

---

## 11. Tailscale ACL 建议

在 Tailscale 控制台写 ACL（参考，按需调整）：

```jsonc
{
  "tagOwners": {
    "tag:motif-server": ["fei@example.com"],   // motifd 节点
    "tag:motif-client": ["fei@example.com"]    // 嵌入式 tsnet 的客户端
  },

  "acls": [
    // 客户端可以连 motifd 的 7777
    {
      "action": "accept",
      "src":    ["tag:motif-client"],
      "dst":    ["tag:motif-server:7777"]
    }
    // 浏览器场景：用 User 直接访问（"src": ["fei@example.com"]）或挂个 tag 也行
  ]
}
```

加这层 ACL 是 motif Bearer token 之外的一道**网络层**防线：即使 token 泄漏，攻击者也得在 tailnet 上有一台被授权的设备才能尝试连。

---

## 12. 开放问题

- [ ] **OAuth 交互体验**：libtailscale 输出 URL 的 callback 是 stderr，TUI 模式下需要切出 ratatui 全屏才能让用户看清楚。是否要先弹出"按 Enter 在浏览器中登录"提示？motifd 这边已经加了启动期 WARN（`crates/motif-server/src/lib.rs::serve`），TUI 侧未做。
- [x] **Headscale 兼容**：已暴露 `--tailscale-control-url`（motifd）与 `MOTIF_TS_CONTROL_URL`（客户端）。
- [ ] **prebuilt 资产签名**：v2 计划，未启动。
- [ ] **`ephemeral` 默认值**：当前 motifd / 客户端都默认 false。客户端默认 false 是因为 tsnet 1.94 + ephemeral 在 Loopback() 路径上有兼容性 bug（见 `default_client_ts_options` 注释）；等 tsnet 修了再考虑给客户端默认 true。

---

## 13. 与已有文档的关系

- [`prd.md`](./prd.md) §7（部署示例）：motifd 既能纯 TCP 部署，也能通过 `--tailscale` 把自己挂上 tailnet；两者并存常用。
- [`ssh-tunnel.md`](./ssh-tunnel.md)：和 tsnet 并列的客户端反向接入路径，浏览器走 SSH local-forward 时尤其常用。
- [`web-client.md`](./web-client.md) — 浏览器经 tsnet 直连 motifd 时的接入面向；Web UI 已内嵌在 motifd 进程。
- 本文档是 motif-tailscale crate + motifd `--tailscale*` flag 的事实标准；任何 Tailscale 相关行为变更优先更新这里。
