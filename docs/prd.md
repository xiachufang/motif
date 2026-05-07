# Motif — Remote Dev Agent 产品功能文档 (v1)

## 1. Context

用户需要一个 C/S 架构的远程开发 agent，能够把"打开一个目录、看文件、改文件、看 diff、跑命令"这套日常开发动作从执行机器（本机或远端服务器）解耦出来，让多个轻量客户端同时连入并看到完全一致的会话状态。

类比定位：

- 像 **code-server**：把开发后端跑在远程，本地只做接入。
- 像 **tmux attach**：多个客户端 attach 到同一个会话时看到的是**完全镜像**——同一份文件树视图、同一组终端、同一份 diff。
- **不**像 Claude Code / Cursor：本期不集成任何 LLM，纯远程开发后端。

v1 目标场景是个人单用户：用户在云上跑 server，从 MacBook、远程办公电脑、平板浏览器（后续版本）都能 attach 到同一个会话继续工作。

---

## 2. Vision & Non-goals

### Vision

提供一个最小但完整的远程开发后端：把"工作目录 + 终端 + git diff"这三件事抽象成一个长生命周期的 **Session**，通过明确的 JSON-RPC 协议暴露给任意 client。一个 Session 在 server 上常驻，client 是无状态薄壳，可随时断开重连。

### v1 In-scope

- 文件树浏览 / 文件读取
- 文件编辑：client 拉到本地用 `$EDITOR` 改完推回
- Git diff（工作区 vs HEAD/index）
- 多会话 PTY（server 内置类 tmux 的会话管理）
- 多 client 完全镜像 attach
- TUI client（reference 实现）
- 单用户 token 认证 + WebSocket over TLS

### v1 Non-goals（明确不做）

- ❌ 内置 LLM / AI agent 协同
- ❌ Web client、原生 GUI client（协议预留，v1 不实现）
- ❌ 多用户、权限模型、配额、审计
- ❌ TUI 内置编辑器、语法高亮、LSP
- ❌ 任意两个 git ref 间 diff、会话快照 diff
- ❌ 文件实时变更推送（didChange 流）—— v1 用按需刷新
- ❌ 沙箱化命令执行 —— 默认信任 server 用户
- ❌ 大文件 / 二进制传输优化（v1 主线不做；M5 后做独立 M6 走 blob 通道，详见 [`blob-transfer.md`](./blob-transfer.md)）

---

## 3. Architecture

```
┌─────────────────┐      WebSocket + TLS       ┌──────────────────────────────┐
│  TUI client A   │ ─────────────────────────► │                              │
└─────────────────┘                            │      motif server            │
┌─────────────────┐                            │  ┌────────────────────────┐  │
│  TUI client B   │ ─────────────────────────► │  │  Session (long-lived)  │  │
└─────────────────┘     JSON-RPC 2.0           │  │  - workdir             │  │
                                               │  │  - PTY pool (N shells) │  │
                       attach / detach         │  │  - file ops            │  │
                                               │  │  - git ops             │  │
                                               │  │  - subscriber list     │  │
                                               │  └────────────────────────┘  │
                                               │  ┌────────────────────────┐  │
                                               │  │  Session 2, 3, ...     │  │
                                               │  └────────────────────────┘  │
                                               └──────────────────────────────┘
                                                        │
                                                ┌───────┴────────┐
                                                │  本地文件系统   │
                                                │  + git + shell  │
                                                └────────────────┘
```

### 关键概念

- **Server**: 一个守护进程，管理 0..N 个 Session。可在本地（`localhost`）或远程跑。
- **Session**: 一个长生命周期对象，绑定一个工作目录，持有自己的 PTY 池和订阅者列表。client 关闭后 Session 不销毁。
- **Client**: 短生命周期，连入即"attach"到某 Session 成为 subscriber，断开即"detach"。Session 为每个事件向所有当前 subscriber 广播。
- **Mirror 语义**: Session 是状态权威；所有 client 通过订阅同一组 server 推送事件来保证视图一致。client 不持有冲突状态。

### 独立二进制

按 Unix 惯例（参考 `sshd`/`ssh`、`dockerd`/`docker`），server 与 client 各为独立可执行文件。所有 client 二进制采用 `motif-<role>` 命名一致；server 沿用 daemon 后缀 `-d`：

```
# 服务端（核心，部署到远端或本地后台）
motifd      --listen :7777  --token-file ~/.motif/token  [--cert … --key …]

# 客户端 —— TUI（开发者机器上装这个）
motif-tui   attach   wss://host:7777/  --session work
motif-tui   list     wss://host:7777/                    # 列出所有 session
motif-tui   new      wss://host:7777/  --workdir ~/repo  --name work
motif-tui   destroy  wss://host:7777/  --name work

# v1.5 新增 —— Web 桥接（浏览器接入；不动核心 motifd）
motif-web   --listen :8080  --motifd-url wss://host:7777/  ...
```

拆分的好处：

- **依赖不混杂**：`motifd` 不携带 `ratatui`/`crossterm`/`vte` 等 TUI 依赖；`motif-tui` 不携带 `axum`/server 端 PTY 管理逻辑；`motif-web` 不携带服务端的 PTY/git 实现。
- **部署模型清晰**：核心服务端常以 daemon/systemd 方式跑 `motifd`，开发者只装 `motif-tui`，浏览器用户只用 `motif-web` 桥接。
- **二进制更小**：client 端可 strip 到非常小的体积，方便分发到资源受限环境（容器、SSH 跳板机）。
- **Native GUI 未来直连 motifd**：协议平级，与 `motif-tui` 同款连接，不经 `motif-web`。

---

## 4. 核心功能详述

### 4.1 Session 管理（多 client mirror）

**生命周期**

- 由 client 调用 `session.create(workdir, name)` 创建；server 在 workdir 上启动一个 Session 实例。
- Client 调用 `session.attach(name)` 加入订阅者列表。一次连接只能 attach 一个 Session（简化 v1）。
- Client 断开（网络中断或主动 detach）时只从订阅者列表里移除，Session 继续存活。
- `session.destroy(name)` 显式销毁；server 终止所有 PTY、释放资源。

**广播事件**（server → 所有 subscriber）

| 事件 | 触发 | Payload |
|---|---|---|
| `tree.changed` | 文件创建/删除/重命名（v1 由变更操作主动发出，无 fs watcher） | `{paths: [...]}` |
| `pty.output` | 任一 PTY 有新输出 | `{ptyId, dataB64, seq}` |
| `pty.resize` | 任一 client 改变了某 PTY 的尺寸 | `{ptyId, cols, rows}` |
| `pty.created` / `pty.exited` | PTY 池变化 | `{ptyId, ...}` |
| `git.changed` | diff 状态变化（写入文件、git 命令后） | `{}` |
| `client.joined` / `client.left` | subscriber 变化（用于显示"另有 2 人在连"） | `{clientId, since}` |

**Mirror 一致性**

- 所有事件携带递增 `seq`，client 重连时带上最后已知 seq，server 补发缺失片段（PTY 输出有限缓冲，默认每 PTY 1MB ring buffer）。
- 终端尺寸：所有 attach 同一 PTY 的 client 必须协商出最小 (cols, rows)；server 取最小公约数发给底层 PTY，避免显示截断。

### 4.2 文件树

**RPC**

- `fs.tree(path, depth=1)` → `{entries: [{name, type, size, mtime}, ...]}`
- `fs.stat(path)` → `{type, size, mtime, gitStatus}`

**行为**

- 路径强制约束在 Session workdir 之下；任何 `..` 或绝对路径转义直接拒绝（403）。
- `.gitignore` 默认隐藏，可通过参数 `showHidden=true` 显示。
- 默认按目录在前、字母序排列，与多数 IDE 行为一致。
- 文件树**不主动 watch**；client 在已知触发点（写文件、跑 git 命令、PTY 退出）后调用 `fs.tree` 刷新。降低 v1 复杂度。

### 4.3 文件查看

- `fs.read(path, encoding="utf-8", maxBytes=10_000_000)` → `{content, sha256, truncated, mime}`
- 文本/小文件：内联 base64 走主通道，10MB 上限不变。
- 二进制大文件：通过**独立数据通道**传输，详见 [`blob-transfer.md`](./blob-transfer.md)；client 调 `fs.openBlob` 拿到 `transfer_id` 后开新 WS 拉取，避免挤占主通道。
- `mime` 字段由 server 用 `mime_guess` + magic bytes 推断，给 client 做渲染决策（图片预览、语法高亮等）。

### 4.4 文件编辑（`$EDITOR` 模式）

这是 v1 编辑模型的核心简化：**server 不内置编辑器，client 不实现编辑器**。

**流程**

1. Client 调用 `fs.read(path)` 拿到文件内容和 `sha256`。
2. Client 写入本地临时文件，记下原始 sha256。
3. Client 在本地终端启动 `$EDITOR <tmpfile>`（继承当前 client 终端）。
4. 用户编辑、保存、退出编辑器。
5. Client 计算新内容的 sha256，调用 `fs.write(path, content, expectedSha256=<原始>)`。
6. Server 校验文件当前 sha256 与 `expectedSha256` 一致后才写入；不一致返回 `Conflict`，让 client 决定是否覆盖（带 `force=true` 重试）。
7. Server 写入成功后广播 `tree.changed` 和 `git.changed`。

**理由**

- 用户已经有 `vim`/`nvim`/`hx`/`code -w` 的肌肉记忆，强制 client 内嵌编辑器只会复刻一份糟糕的体验。
- 代价是多 client 不能"实时同光标"看同一个文件。这是 v1 明确的取舍——大多数协作场景里实际需要的是"我改完你看 diff"，而不是真正的同步打字。

### 4.5 Git Diff（v1 仅工作区 vs HEAD/index）

**RPC**

- `git.status()` → `{branch, ahead, behind, files: [{path, staged, unstaged, status}]}`
- `git.diff(path?, staged=false)` → `{patch}` （unified diff，调用 `git diff [--staged] [--] path`）
- `git.diffSummary(staged=false)` → `{files: [{path, additions, deletions}]}`

**行为**

- 仅当 workdir 是 git 仓库时启用；否则返回 `NotAGitRepo`。
- 不实现：任意两 ref 间 diff、跨 commit、blame、log。这些 v1 让用户在 PTY 里直接 `git log`/`git diff`。
- 写文件后 server 主动广播 `git.changed`，client 更新 diff 视图。

### 4.6 多会话 PTY（tmux-内置化）

**RPC**

- `pty.create(cols, rows, cmd?, env?, cwd?)` → `{ptyId}`（cmd 默认为用户登录 shell）
- `pty.list()` → `{ptys: [{id, cmd, cwd, alive, createdAt}]}`
- `pty.write(ptyId, dataB64)` —— 任一 client 输入即广播给所有 subscriber
- `pty.resize(ptyId, cols, rows)` —— 见 4.1 的最小公约数策略
- `pty.kill(ptyId)`

**行为**

- 每个 PTY 独立 ring buffer（默认 1MB），attach 时回放最近内容让新加入的 client 看到上下文。
- 输入广播：A client 在 PTY 里敲键，B client 立刻看到字符回显——这是"完全镜像"的核心体现。
- v1 只暴露 PTY 列表给 client；client 自己决定如何在 UI 中布局（标签页、分屏由 TUI client 决定）。Server 不管布局。

### 4.7 认证

- Server 启动时生成或读取 `--token-file` 中的 bearer token。
- 客户端在 WebSocket 握手 `Authorization: Bearer <token>` 校验；失败立即关闭连接。
- TLS 由用户提供证书（`--cert`/`--key`）；省略时 server 拒绝监听非 loopback 地址（防呆）。
- v1 不做 token 轮换、不做 refresh token、不做多 token。

---

## 5. 协议（JSON-RPC 2.0 over WebSocket）

**单一长连接**承载所有方法调用和服务端推送：

- 客户端 → 服务端：`request` / `notification`
- 服务端 → 客户端：`response` + `notification`（用于 4.1 的事件广播）

**示例**

```json
// client → server
{"jsonrpc":"2.0","id":1,"method":"session.attach","params":{"name":"work"}}

// server → client
{"jsonrpc":"2.0","id":1,"result":{"sessionId":"abc","ptys":[...],"lastSeq":42}}

// server → client (推送事件)
{"jsonrpc":"2.0","method":"pty.output","params":{"ptyId":"sh-1","dataB64":"...","seq":43}}
```

**完整方法表**（含 4.x 中已展开的）

| 方法 | 类型 | 章节 |
|---|---|---|
| `session.list` / `create` / `attach` / `detach` / `destroy` | request | 4.1 |
| `fs.tree` / `stat` / `read` / `write` / `mkdir` / `remove` / `rename` | request | 4.2-4.4 |
| `fs.openBlob` / `commitBlob` / `cancelBlob` (M6 起) | request | [`blob-transfer.md`](./blob-transfer.md) §3 |
| `git.status` / `diff` / `diffSummary` | request | 4.5 |
| `pty.create` / `list` / `write` / `resize` / `kill` | request | 4.6 |
| `pty.list_blocks` / `get_block_output` (v2 shell integration) | request | [`shell-integration.md`](./shell-integration.md) §7.3 |
| `tree.changed` / `pty.*` / `git.changed` / `client.*` | notification (server→client) | 4.1 |
| `pty.shell_bootstrapped` / `command_started` / `command_finished` / `shell_context` (v2 shell integration) | notification (server→client) | [`shell-integration.md`](./shell-integration.md) §7.1 |

> v2（shell integration）还会给现有的 `pty.output` 事件增加可选字段 `block_id`，向后兼容老 client。

错误用 JSON-RPC 标准错误对象 + 自定义 code（`-32001` 起）：`PathEscape`、`FileTooLarge`、`Conflict`、`NotAGitRepo`、`PtyNotFound`、`AuthRequired`；v2 起追加 `BlockNotFound`（详见 [`shell-integration.md`](./shell-integration.md) §7.4）。

---

## 6. TUI Client UX

参考布局（默认 80×24 也能用，全屏更舒服）：

```
┌─ motif @ work (3 clients) ─────────────────────────────────────┐
│ ── files ────────┬── main ──────────────────────────────────── │
│ src/             │ [tab1: src/foo.go] [tab2: pty:sh-1*] [+]    │
│   foo.go     M   │                                              │
│   bar.go         │ (当前 tab 内容：文件预览 / diff / PTY 镜像)   │
│ go.mod           │                                              │
│ ...              │                                              │
│                  │                                              │
│ ── git ──────────┤                                              │
│ M src/foo.go     │                                              │
│ ?? new.txt       │                                              │
└──────────────────┴──────────────────────────────────────────────┘
 e:edit  d:diff  t:new-pty  Ctrl-b:detach  ?:help
```

**关键交互**

- `e`：拉文件到本地 tmp，启动 `$EDITOR`，保存后推回（4.4）。编辑期间 TUI client 让出终端给编辑器；编辑器退出后回到 TUI。
- `d`：在右侧打开 diff 视图（unified patch，简单着色）。
- `t`：创建新 PTY tab；进入后键盘事件全部 forward 给 server。
- `Ctrl-b d`：detach（致敬 tmux），Session 在 server 上继续。
- 状态栏显示当前 attach 数（`3 clients`），让用户知道有别的 client 在线。

**实现策略**

- 不内嵌编辑器、不做 LSP，复杂度大幅降低。
- PTY mirror 直接把 server 推送的 ANSI 字节流喂给本地终端模拟（用现有库，例如 Go 的 `vt10x` 或 Rust 的 `vte`）。
- 事件循环：单线程 select 在 WebSocket recv、本地键盘、定时器 tick 之间。

---

## 7. 安全模型（v1 单用户假设）

| 项 | v1 策略 |
|---|---|
| 认证 | 单 bearer token |
| 传输加密 | 强制 TLS（除非监听 loopback） |
| 路径越界 | server 端规范化 + workdir 前缀检查 |
| 命令执行 | 不沙箱化；server 进程权限 = 用户能执行的所有命令。文档明确标注"server 应以你信任的身份运行" |
| Token 泄漏 | 提示用户用文件权限 0600；不内置轮换 |
| 资源限额 | PTY 数量软上限（默认 32），文件读取 10MB 上限 |

### 7.1 连通性（client → motifd 的接入路径）

`motifd` 本身只是个 WS 监听器，**任何**能让 client 看到 motifd 端口的网络拓扑都可用。motif client（`motif-tui` / `motif-web`）默认提供两条"开箱即用"的接入路径，外加直连：

| 路径 | 适合 | 详细文档 |
|---|---|---|
| **直连**（`wss://host:port/`） | 局域网、公网 VPS（配 TLS 证书）、SSH 已开好的隧道 | 本文档 §3、§4.7 |
| **Tailscale 嵌入** | 个人多设备、跨区域、NAT 穿透；client 二进制即 tailnet 节点，无需装 daemon | [`tailscale.md`](./tailscale.md) |
| **SSH 隧道** | 只有 SSH 可用的内网、跳板机 / bastion；client 自动 spawn `ssh -L`，复用 ssh_config / agent | [`ssh-tunnel.md`](./ssh-tunnel.md) |

接入路径的选择由 client 端决定，server 不感知。`motif-tui` / `motif-web` 用 `--via direct|tailnet|ssh://...` 显式指定，未指定时按 host 形态启发式判断（详见各文档 §7 / §3）。

设计原则（与 §3 "motifd 只做协议核心" 一致）：

- **motifd 不内置任何隧道 / VPN / 反代逻辑**。需要更复杂部署的用户用现成工具（Tailscale daemon、Cloudflare Tunnel、nginx 反代）即可。
- **client 端可选集成**。Tailscale / SSH 都用 cargo feature 控制，关掉后回到纯 Rust 二进制 + 直连。

---

## 8. 并发与冲突

- **文件写入冲突**：4.4 的 `expectedSha256` 乐观锁。两个 client 同时 edit 同一文件，后写者会被拒绝并提示。
- **PTY 输入交错**：所有 client 输入并入同一字节流，与 tmux/screen 行为一致。这是"完全镜像"的固有特性，不视为 bug。
- **session.create 同名**：返回 `AlreadyExists`，让用户改名或显式 destroy。

---

## 9. 实现选型

- **语言**：**Rust**（已确认）。单二进制、无 GC、PTY/异步 IO 生态成熟。
- **核心 crate**：
  - 异步运行时：`tokio`
  - WebSocket：`tokio-tungstenite`（server 用 `axum` 起 HTTP 升级到 WS，方便 v1.5 Web client 复用同一端口提供静态资源）
  - PTY：`portable-pty`（跨平台，macOS/Linux 一致）
  - JSON-RPC：手写薄层（`serde_json` + `tokio::sync::mpsc` 路由），不引重型 RPC 框架
  - TLS：`rustls` + `tokio-rustls`
  - 终端模拟（TUI client 内回放 PTY 字节）：`vte`
  - TUI 框架：`ratatui` + `crossterm`
  - Git：直接 fork `git` 命令，不引 `git2`（避免 libgit2 链接复杂度，v1 diff/status 用 CLI 完全够）
- **Workspace 布局**（单 cargo workspace；v1 共 3 个 crate，每个除 `motif-proto` 外都是 lib + bin；v1.5 再加 1 个 lib+bin + 顶层 `web/`）：
  ```
  motif/
    Cargo.toml                # workspace
    crates/
      motif-proto/            # (lib)         JSON-RPC 类型、事件定义（所有 crate 共享）
      motif-server/           # (lib + bin)   核心服务端逻辑 + main.rs；产物 `motifd`
      motif-tui/              # (lib + bin)   TUI 客户端 + WS client + 命令实现；产物 `motif-tui`
      # —— 以下 v1.5 新增 ——
      motif-web/              # (lib + bin)   浏览器桥接：HTTP/WS server + WS client；产物 `motif-web`
    web/                      # (前端项目)    v1.5 新增；Vite + Solid，被 motif-web 嵌入
    tests/                    # 跨 crate 集成测试
    docs/
  ```
  - 每个非 proto crate 自己负责 `src/lib.rs`（库代码）+ `src/main.rs`（薄入口）。`Cargo.toml` 用 `[[bin]] name = "..."` 显式指定二进制名。
  - `motifd` **只**讲 motif WS+JSON-RPC 协议，不挂 HTTP 静态资源、不知道浏览器存在。
  - `motif-web` 是"既是 motifd 的 client 又是浏览器的 backend"的桥接二进制，详见 [`web-client.md`](./web-client.md)。
  - Native GUI client（未来）和 TUI 一样直连 `motifd`，**不**经过 `motif-web`。
  - 二进制依赖图完全不重叠：`motifd` 不拉 `ratatui`/`crossterm`/`vte`/HTTP 静态资源；`motif-tui` 不拉 `axum`/`portable-pty`；`motif-web` 不拉 `portable-pty`/git 等核心逻辑。
- **配置**：`~/.motif/config.toml`（client 端记 server 列表 + token 路径）。
- **日志**：`tracing` + `tracing-subscriber`，默认写 `~/.motif/logs/server.log`（JSON 行）。
- **测试**：
  - 协议层：`motif-proto` 自带类型 round-trip 测试。
  - 集成测试：`motif-server` 起在内存 listener 上，`motif-tui` 用脚本驱动跑端到端。
  - PTY：`expect`-风格的 Rust crate（如 `expectrl`）做命令行回归。

---

## 10. Milestones

| 阶段 | 范围 | 验收 |
|---|---|---|
| **M1: 协议骨架** | JSON-RPC 框架、auth、`session.create/attach/detach/list` | 两个 CLI 能 attach 同一 session 并互相看到 `client.joined` 事件 |
| **M2: PTY 镜像** | `pty.*` 全套 + ring buffer 重放 + 输入广播 | 两个 attach 的 client 在同一 PTY 里互相看到对方的输入和输出，断线重连后能补回最近 1MB |
| **M3: 文件操作** | `fs.tree/stat/read/write` + path 越界保护 + sha256 乐观锁 | 一个 client 改文件，另一个 client 收到 `tree.changed` 后刷新看到新内容 |
| **M4: Git diff** | `git.status/diff/diffSummary` + 写文件触发 `git.changed` | 改文件后 diff 视图自动更新 |
| **M5: TUI client** | 完整 UX（4 个面板 + 编辑流程 + detach 快捷键） | 端到端可用：从空目录 `motifd` 起，到本地 `motif-tui attach` 完成一次"看代码 → 跑测试 → 改文件 → 看 diff" |

每个里程碑结束做一次端到端 demo，用 `localhost` 和远端 VM 各跑一次，验证延迟和断线场景。

### M5 之后的并行模块（不阻塞 v1.5 Web client）

M1–M5 跑通后，下面三个模块**互相独立**，可并行推进；都不影响 motifd 的核心协议表面：

| 模块 | 范围 | 详细文档 |
|---|---|---|
| **M6: 连通性** | `motif-tailscale` crate（libtailscale FFI）+ `--via ssh://` SSH 隧道封装 | [`tailscale.md`](./tailscale.md) §9、[`ssh-tunnel.md`](./ssh-tunnel.md) §8 |
| **M7: Blob 通道** | `fs.openBlob/commitBlob`、motifd `/blob/:tid` WS、TUI 图片查看 + 上传 | [`blob-transfer.md`](./blob-transfer.md) §9 |
| **M8: Web client (v1.5)** | `motif-web` 桥接二进制 + `web/` 前端 | [`web-client.md`](./web-client.md) §9 |

依赖关系：M8 (Web client) 想要图片预览 / 上传完整能用就必须等 M7 落地；其它都可独立推进。建议次序 **M6 → M7 → M8**（连通性 → blob → Web），因为 Web 的最佳体验需要前两者支撑。

---

## 11. 路线图（v1 之后）

### v1.5 — Web client（已确认作为 v1 之后下一步）

> **详细规划见 [`web-client.md`](./web-client.md)。** 以下仅列要点，避免本文档与 v1.5 文档漂移。

- **核心 `motifd` 不变**。新增独立桥接二进制 `motif-web`：既是浏览器的 HTTP/WS backend，又是 `motifd` 的一个普通 motif client。Web 与 native GUI 在架构上完全平级，都是 motifd 的 client。
- 浏览器 ↔ `motif-web` 走 WS + JSON-RPC；`motif-web` ↔ `motifd` 走 WS + JSON-RPC（带 Bearer header）。**协议同源、不分叉**。
- 协议层无需新增任何方法。`auth.login` 这种浏览器友好的第一条消息只发生在 **浏览器 ↔ `motif-web`** 之间，由桥接做翻译；`motifd` 端继续用 v1 的 HTTP-header Bearer，TUI 不动。
- TS 协议类型由 `motif-proto` 经 `ts-rs` 派生生成，编译期保证一致。
- 前端栈：Vite + Solid + Tailwind + xterm.js + diff2html + Shiki，构建产物经 `rust-embed` 嵌入 `motif-web` 二进制；分发就是 `motifd` + `motif-web` 两个文件（用户可只跑前者）。
- v1.5 不做浏览器内编辑、不做协同编辑、不做多用户。仍保持"看 + 跑命令"为主。
- 这一阶段反向验证 v1 协议是否真的 client-agnostic。任何要新加的 RPC/事件都要回 `motif-proto` 同步升级 server / TUI / Web 三处。

### v2 — Shell integration & Block 流（草案，详见 shell-integration.md）

> **详细规划见 [`shell-integration.md`](./shell-integration.md)。** 以下仅列要点，避免漂移。

- **核心 `motifd` 内部加工**，不改变 client 接入方式。新增 `motif-server` 内的 `shell/` 模块：spawn PTY 时注入 bootstrap 脚本（bash/zsh/fish 各一份，`include_str!` 编入二进制），server 端 OSC scanner 把 PTY 流里的钩子拆成结构化 *block*（命令文本 + 输出 + 退出码 + cwd + git/venv/node 等上下文）。
- 协议层新增的 RPC / notification / 错误码已在 §5 列出，全部为新增（不修改老方法），向后兼容；`pty.output` 仅追加可选字段 `block_id`。
- 复用 OSC 133（FinalTerm 标准）+ motif 私有号段 `7770-7779`（最终值实现期定）。
- 现有 1.5s pid polling cwd 跟踪（`pty.cwd_changed`）保留；shell hook 主动发 OSC 7 时 server 即时触发同一事件，pid polling 退为 fallback（覆盖未 bootstrap 的 shell，含 SSH 远端）。
- TUI 受益：M-SI-1 之后命令边界提示 / 退出码着色，M-SI-2 之后跳上下条 block。Web 端在协议之上叠加只读 block 卡片 UI，输入仍走 xterm raw passthrough。
- **不做**：GUI 行编辑器、editor lock、Tab 补全 / Ctrl-R 历史搜索 RPC、in-band generator、协同 buffer 镜像、shell 语法 parser（多行用 bracketed paste 兜底）、AI 钩子、Windows ConPTY 网格 reset。

### 不做（明确放弃，至少在可见路线图内）

- ❌ **真正的协同编辑**（OT/CRDT、`fs.didChange` 流）。`$EDITOR` 模式 + sha256 乐观锁是终态，不升级为实时同步。
- ❌ 多用户、团队 ACL、审计日志。

### 仍开放（无承诺，未来可能做）

- 原生 GUI client（macOS/Windows）：协议已就绪，纯工程量问题。
- AI agent 作为一种特殊 client：订阅 PTY 输出 + 文件变更，通过 `fs.write` 落盘 patch。架构上天然契合，但本项目 v1 明确不做。

---

## 12. 已确认决定

- ✅ 项目名：**motif**
- ✅ 实现语言：**Rust**（详见第 9 节 crate 选型）
- ✅ v1 之后路线：**v1.5 做 Web client**；**不做**真正的协同编辑

---

## 13. M1 实现脚手架（cargo workspace）

### 13.1 顶层 `Cargo.toml`

```toml
[workspace]
members  = ["crates/*"]
resolver = "2"

[workspace.package]
edition      = "2021"
rust-version = "1.78"
version      = "0.1.0"
license      = "MIT OR Apache-2.0"

[workspace.dependencies]
# 异步 / IO
tokio              = { version = "1",   features = ["full"] }
tokio-tungstenite  = { version = "0.21", features = ["rustls-tls-webpki-roots"] }
axum               = { version = "0.7", features = ["ws"] }
tokio-rustls       = "0.26"
rustls             = "0.23"
rustls-pemfile     = "2"

# 序列化 / 协议
serde              = { version = "1", features = ["derive"] }
serde_json         = "1"
bytes              = "1"
base64             = "0.22"

# PTY / 终端
portable-pty       = "0.8"
vte                = "0.13"
ratatui            = "0.26"
crossterm          = "0.27"

# 工具
clap               = { version = "4", features = ["derive"] }
sha2               = "0.10"
hex                = "0.4"
ulid               = { version = "1", features = ["serde"] }
thiserror          = "1"
anyhow             = "1"

# 日志 / 测试
tracing            = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
expectrl           = "0.7"
```

### 13.2 目录结构

```
motif/
├─ Cargo.toml                          # workspace
├─ rust-toolchain.toml                 # 锁 Rust 版本
├─ docs/
│  ├─ prd.md                           # 本文档
│  └─ web-client.md                    # v1.5 规划
├─ crates/
│  ├─ motif-proto/                     # (lib) 协议类型，所有 crate 的依赖
│  │  ├─ Cargo.toml
│  │  └─ src/
│  │     ├─ lib.rs                     # pub mod common, error, session, fs, git, pty, event
│  │     ├─ common.rs                  # SessionId / ClientId / PtyId / Seq / Sha256 类型别名
│  │     ├─ error.rs                   # ErrorCode 枚举 + RpcError
│  │     ├─ session.rs                 # SessionInfo / Create|Attach Params/Result
│  │     ├─ fs.rs                      # TreeEntry / Read|Write Params/Result 等
│  │     ├─ git.rs                     # GitStatus / DiffParams / DiffResult
│  │     ├─ pty.rs                     # PtyInfo / PtyCreateParams 等
│  │     └─ event.rs                   # Event 推送事件枚举
│  ├─ motif-server/                    # (lib + bin) 核心服务端；二进制名 `motifd`
│  │  ├─ Cargo.toml                    # [lib] + [[bin]] name = "motifd"
│  │  └─ src/
│  │     ├─ lib.rs                     # pub async fn serve(cfg: ServerConfig) -> Result<()>
│  │     ├─ main.rs                    # 薄入口：clap 解析 → motif_server::serve(cfg).await
│  │     ├─ config.rs                  # ServerConfig (listen, token_file, cert/key)
│  │     ├─ auth.rs                    # Bearer token 校验中间件
│  │     ├─ ws.rs                      # axum 路由 + WS 升级
│  │     ├─ rpc.rs                     # JSON-RPC 派发器: Request -> handler
│  │     ├─ session/
│  │     │  ├─ mod.rs                  # Session 主结构（持有 PTY 池 + 订阅者）
│  │     │  ├─ manager.rs              # SessionManager: DashMap<Name, Arc<Session>>
│  │     │  └─ broadcast.rs            # 事件总线 + seq 计数 + 重连补发
│  │     ├─ fs.rs                      # tree/stat/read/write/mkdir/remove/rename
│  │     ├─ git.rs                     # status/diff/diffSummary（fork git CLI）
│  │     └─ pty/
│  │        ├─ mod.rs                  # Pty 包装 + 1MB ring buffer + 输入广播
│  │        └─ pool.rs                 # PtyPool（每 Session 一个）
│  └─ motif-tui/                       # (lib + bin) TUI 客户端；二进制名 `motif-tui`
│     ├─ Cargo.toml                    # [lib] + [[bin]] name = "motif-tui"
│     └─ src/
│        ├─ lib.rs                     # pub async fn run_attach/cmd_list/cmd_new/cmd_destroy
│        ├─ main.rs                    # 薄入口：clap → 调用对应 lib 函数
│        ├─ client.rs                  # WS 连接 + JSON-RPC 收发（list/new 也用这个）
│        ├─ state.rs                   # TUI 应用状态（镜像 server 事件）
│        ├─ editor.rs                  # 调起 $EDITOR 的让屏/回收屏流程
│        ├─ input.rs                   # 键盘事件 -> 命令
│        └─ ui/
│           ├─ mod.rs                  # ratatui 主循环
│           ├─ files.rs                # 文件树面板
│           ├─ tabs.rs                 # tab 容器
│           ├─ pty_view.rs             # vte 解析 + 渲染
│           └─ diff_view.rs            # unified diff 渲染
└─ tests/                              # 跨 crate 集成测试（in-memory listener）
```

> v1.5 在 `crates/` 下新增 `motif-web/`（lib + bin，二进制 `motif-web`）+ 顶层 `web/` 前端项目；**核心 `motifd` 不动**——Web 只是 motifd 的另一种 client，与 native GUI 平级。详见 [`web-client.md`](./web-client.md)。

### 13.3 二进制入口骨架（`clap` derive）

每个 crate 的 `src/main.rs` 是薄入口，只做参数解析然后调用同 crate 的 `lib.rs` 里的函数。库代码同时也可被 `tests/` 直接 `use` 做集成测试。

#### `motif-server` crate —— 二进制 `motifd`

```rust
// crates/motif-server/src/main.rs
use clap::Parser;

#[derive(Parser)]
#[command(name = "motifd", version, about = "motif remote dev agent — server")]
struct Args {
    /// 监听地址；非 loopback 时必须指定 --cert/--key
    #[arg(long, default_value = "127.0.0.1:7777")]
    listen: std::net::SocketAddr,

    /// Bearer token 文件（建议权限 0600）
    #[arg(long)]
    token_file: std::path::PathBuf,

    #[arg(long)] cert: Option<std::path::PathBuf>,
    #[arg(long)] key:  Option<std::path::PathBuf>,

    /// 日志级别（trace|debug|info|warn|error）
    #[arg(long, env = "MOTIFD_LOG", default_value = "info")]
    log: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    motif_server::init_tracing(&args.log)?;
    let cfg = motif_server::ServerConfig::from_args(&args)?;
    motif_server::serve(cfg).await   // ← 同 crate 的 lib
}
```

#### `motif-tui` crate —— 二进制 `motif-tui`

```rust
// crates/motif-tui/src/main.rs
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "motif-tui", version, about = "motif remote dev agent — TUI client")]
struct Cli { #[command(subcommand)] cmd: Cmd }

#[derive(Subcommand)]
enum Cmd {
    /// attach 到一个 session（进入 TUI）
    Attach {
        url: String,                                 // wss://host:port/
        #[arg(long)] session: String,
        #[arg(long, env = "MOTIF_TOKEN_FILE")] token_file: Option<std::path::PathBuf>,
    },
    /// 列出 server 上的 session
    List {
        url: String,
        #[arg(long, env = "MOTIF_TOKEN_FILE")] token_file: Option<std::path::PathBuf>,
    },
    /// 创建新 session
    New {
        url: String,
        #[arg(long)] name: String,
        #[arg(long)] workdir: std::path::PathBuf,
        #[arg(long, env = "MOTIF_TOKEN_FILE")] token_file: Option<std::path::PathBuf>,
    },
    /// 销毁 session
    Destroy {
        url: String,
        #[arg(long)] name: String,
        #[arg(long, env = "MOTIF_TOKEN_FILE")] token_file: Option<std::path::PathBuf>,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match Cli::parse().cmd {
        Cmd::Attach  { url, session, token_file } => motif_tui::run_attach(url, session, token_file).await,
        Cmd::List    { url, token_file }          => motif_tui::cmd_list(url, token_file).await,
        Cmd::New     { url, name, workdir, token_file } => motif_tui::cmd_new(url, name, workdir, token_file).await,
        Cmd::Destroy { url, name, token_file }    => motif_tui::cmd_destroy(url, name, token_file).await,
    }
}
```

#### Cargo 依赖

```toml
# crates/motif-server/Cargo.toml
[package]
name = "motif-server"
version.workspace = true
edition.workspace = true

# lib 默认从 src/lib.rs 推断，无需显式声明 [lib]

[[bin]]
name = "motifd"          # ★ 二进制名
path = "src/main.rs"

[dependencies]
motif-proto        = { path = "../motif-proto" }
tokio              = { workspace = true }
axum               = { workspace = true }
tokio-tungstenite  = { workspace = true }
tokio-rustls       = { workspace = true }
rustls             = { workspace = true }
rustls-pemfile     = { workspace = true }
portable-pty       = { workspace = true }
serde              = { workspace = true }
serde_json         = { workspace = true }
clap               = { workspace = true }
sha2               = { workspace = true }
ulid               = { workspace = true }
anyhow             = { workspace = true }
thiserror          = { workspace = true }
tracing            = { workspace = true }
tracing-subscriber = { workspace = true }
bytes              = { workspace = true }
base64             = { workspace = true }
```

```toml
# crates/motif-tui/Cargo.toml
[package]
name = "motif-tui"
version.workspace = true
edition.workspace = true

[[bin]]
name = "motif-tui"       # ★ 二进制名
path = "src/main.rs"

[dependencies]
motif-proto        = { path = "../motif-proto" }
tokio              = { workspace = true }
tokio-tungstenite  = { workspace = true }
ratatui            = { workspace = true }
crossterm          = { workspace = true }
vte                = { workspace = true }
serde              = { workspace = true }
serde_json         = { workspace = true }
clap               = { workspace = true }
anyhow             = { workspace = true }
tracing            = { workspace = true }
tracing-subscriber = { workspace = true }
base64             = { workspace = true }
```

注意 `motif-server` 的依赖图里**没有** `ratatui`/`crossterm`/`vte`；`motif-tui` 的依赖图里**没有** `axum`/`portable-pty`。这是 crate 划分驱动的实际隔离，与 lib+bin 是否同 crate 无关。

---

## 14. `motif-proto` 类型详定义（Rust）

> 本节是 server/client 共享的协议层 ground truth。任何修改都要同步反映到第 5 节的 JSON-RPC 方法表。

### 14.1 `common.rs`

```rust
pub type SessionId = String;       // ULID
pub type ClientId  = String;       // ULID
pub type PtyId     = String;       // "sh-1", "sh-2"...
pub type Seq       = u64;
pub type Sha256Hex = String;       // 小写 hex
pub type UnixMs    = u64;
```

### 14.2 `error.rs`

```rust
#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
#[repr(i32)]
pub enum ErrorCode {
    AuthRequired     = -32001,
    PathEscape       = -32002,
    FileTooLarge     = -32003,
    Conflict         = -32004,    // sha256 不匹配
    NotAGitRepo      = -32005,
    PtyNotFound      = -32006,
    SessionNotFound  = -32007,
    AlreadyExists    = -32008,
    NotAttached      = -32009,
    PtyLimitReached  = -32010,
}

#[derive(Debug, thiserror::Error, serde::Serialize, serde::Deserialize)]
#[error("{message}")]
pub struct RpcError {
    pub code:    ErrorCode,
    pub message: String,
    pub data:    Option<serde_json::Value>,
}
```

### 14.3 `session.rs`

```rust
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct SessionInfo {
    pub id:           SessionId,
    pub name:         String,
    pub workdir:      PathBuf,
    pub created_at:   UnixMs,
    pub client_count: u32,
}

#[derive(Serialize, Deserialize)]
pub struct CreateParams { pub name: String, pub workdir: PathBuf }

#[derive(Serialize, Deserialize)]
pub struct AttachParams {
    pub name:     String,
    pub last_seq: Option<Seq>,    // 重连时带，server 会补发
}

#[derive(Serialize, Deserialize)]
pub struct AttachResult {
    pub session:  SessionInfo,
    pub ptys:     Vec<crate::pty::PtyInfo>,
    pub clients:  Vec<ClientInfo>,
    pub last_seq: Seq,            // 当前最新 seq，client 后续基于它判断
}

#[derive(Serialize, Deserialize)]
pub struct ClientInfo { pub id: ClientId, pub since: UnixMs }

#[derive(Serialize, Deserialize)]
pub struct ListResult { pub sessions: Vec<SessionInfo> }
```

### 14.4 `fs.rs`

```rust
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "lowercase")]
pub enum FileType { File, Dir, Symlink }

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct TreeEntry {
    pub name:       String,
    #[serde(rename = "type")]
    pub kind:       FileType,
    pub size:       u64,
    pub mtime:      UnixMs,
    pub git_status: Option<crate::git::GitFileStatus>,
}

#[derive(Serialize, Deserialize)]
pub struct TreeParams {
    pub path:        String,
    #[serde(default = "one")] pub depth: u32,
    #[serde(default)]         pub show_hidden: bool,
}
fn one() -> u32 { 1 }

#[derive(Serialize, Deserialize)]
pub struct TreeResult { pub path: String, pub entries: Vec<TreeEntry> }

#[derive(Serialize, Deserialize)]
pub struct ReadParams {
    pub path:      String,
    #[serde(default = "ten_mb")] pub max_bytes: u64,
}
fn ten_mb() -> u64 { 10_000_000 }

#[derive(Serialize, Deserialize)]
pub struct ReadResult {
    pub content_b64: String,       // 始终 base64，不论文本/二进制
    pub sha256:      Sha256Hex,
    pub truncated:   bool,
    pub binary:      bool,         // 启发式：检测到 NUL 或非 UTF-8
}

#[derive(Serialize, Deserialize)]
pub struct WriteParams {
    pub path:             String,
    pub content_b64:      String,
    pub expected_sha256:  Option<Sha256Hex>,   // 乐观锁
    #[serde(default)] pub force: bool,         // expected_sha256 不匹配时是否强写
}

#[derive(Serialize, Deserialize)]
pub struct WriteResult { pub sha256: Sha256Hex }
```

### 14.5 `git.rs`

```rust
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "lowercase")]
pub enum GitFileStatus {
    Unmodified, Modified, Added, Deleted, Renamed, Copied, Untracked, Ignored, Conflicted,
}

#[derive(Serialize, Deserialize)]
pub struct GitStatus {
    pub branch: Option<String>,
    pub ahead:  u32,
    pub behind: u32,
    pub files:  Vec<GitFile>,
}

#[derive(Serialize, Deserialize)]
pub struct GitFile {
    pub path:     String,
    pub staged:   GitFileStatus,
    pub unstaged: GitFileStatus,
}

#[derive(Serialize, Deserialize)]
pub struct DiffParams {
    pub path:   Option<String>,
    #[serde(default)] pub staged: bool,
}

#[derive(Serialize, Deserialize)]
pub struct DiffResult { pub patch: String }      // unified diff 原文

#[derive(Serialize, Deserialize)]
pub struct DiffSummary {
    pub files: Vec<DiffSummaryFile>,
}
#[derive(Serialize, Deserialize)]
pub struct DiffSummaryFile { pub path: String, pub additions: u32, pub deletions: u32 }
```

### 14.6 `pty.rs`

```rust
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PtyInfo {
    pub id:         PtyId,
    pub cmd:        String,
    pub cwd:        PathBuf,
    pub cols:       u16,
    pub rows:       u16,
    pub alive:      bool,
    pub created_at: UnixMs,
}

#[derive(Serialize, Deserialize)]
pub struct PtyCreateParams {
    pub cmd:  Option<String>,                  // 默认 $SHELL
    pub cwd:  Option<PathBuf>,
    #[serde(default)] pub env: Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Serialize, Deserialize)]
pub struct PtyWriteParams { pub pty_id: PtyId, pub data_b64: String }

#[derive(Serialize, Deserialize)]
pub struct PtyResizeParams { pub pty_id: PtyId, pub cols: u16, pub rows: u16 }

#[derive(Serialize, Deserialize)]
pub struct PtyKillParams { pub pty_id: PtyId }

#[derive(Serialize, Deserialize)]
pub struct PtyListResult { pub ptys: Vec<PtyInfo> }
```

### 14.7 `event.rs`（server → client 推送）

```rust
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(tag = "method", content = "params", rename_all = "snake_case")]
pub enum Event {
    #[serde(rename = "tree.changed")]
    TreeChanged   { paths: Vec<String>, seq: Seq },

    #[serde(rename = "pty.output")]
    PtyOutput     { pty_id: PtyId, data_b64: String, seq: Seq },

    #[serde(rename = "pty.resize")]
    PtyResize     { pty_id: PtyId, cols: u16, rows: u16, seq: Seq },

    #[serde(rename = "pty.created")]
    PtyCreated    { info: PtyInfo, seq: Seq },

    #[serde(rename = "pty.exited")]
    PtyExited     { pty_id: PtyId, exit_code: Option<i32>, seq: Seq },

    #[serde(rename = "git.changed")]
    GitChanged    { seq: Seq },

    #[serde(rename = "client.joined")]
    ClientJoined  { client_id: ClientId, since: UnixMs, seq: Seq },

    #[serde(rename = "client.left")]
    ClientLeft    { client_id: ClientId, seq: Seq },
}
```

### 14.8 JSON-RPC 信封

```rust
#[derive(Serialize, Deserialize)]
pub struct Request<P> {
    pub jsonrpc: &'static str,        // 永远是 "2.0"
    pub id:      u64,
    pub method:  String,
    pub params:  P,
}

#[derive(Serialize, Deserialize)]
#[serde(untagged)]
pub enum Response<R> {
    Ok    { jsonrpc: String, id: u64, result: R },
    Err   { jsonrpc: String, id: u64, error: RpcError },
}
```

`Event` 直接序列化为 JSON-RPC notification（无 `id` 字段），借助 `#[serde(tag = "method")]` 自然产出 `{"jsonrpc":"2.0","method":"pty.output","params":{...}}`。

---

## 15. M1 验收用的端到端剧本

> 写在文档里，避免实现到一半范围漂移。M1 的 PR 必须能跑通这一套。

```bash
# Terminal 1 —— 启动 server（守护进程二进制）
$ motifd --listen 127.0.0.1:7777 --token-file /tmp/motif.token
INFO listening on 127.0.0.1:7777

# Terminal 2 —— 客户端二进制操作
$ export MOTIF_TOKEN_FILE=/tmp/motif.token

$ motif-tui new wss://127.0.0.1:7777/ --name work --workdir ~/some-repo
session created: work (id=01H...)

$ motif-tui list wss://127.0.0.1:7777/
NAME  ID         CLIENTS  CREATED
work  01H...     0        2026-05-06T10:21:00Z

# Terminal 3
$ motif-tui attach wss://127.0.0.1:7777/ --session work
[client A attached]

# Terminal 4
$ motif-tui attach wss://127.0.0.1:7777/ --session work
[client B attached]
[notification: client.joined  id=...A]   # B 收到 A 已在线的事件
```

预期：A 看到 `client.joined` 事件包含 B 的 ClientId，状态栏显示 `2 clients`；任一边 Ctrl-C / 网络中断后，另一边应在 1 秒内收到 `client.left`。
