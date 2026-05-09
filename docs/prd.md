# Motif — Remote Dev Agent 产品功能文档 (v1)

## 1. Context

用户需要一个 C/S 架构的远程开发 agent，能够把"打开一个目录、看文件、改文件、看 diff、跑命令"这套日常开发动作从执行机器（本机或远端服务器）解耦出来，让多个轻量客户端同时连入并看到完全一致的会话状态。

类比定位：

- 像 **code-server**：把开发后端跑在远程，本地只做接入。
- 像 **tmux attach**：多个客户端 attach 到同一个会话时看到的是**完全镜像**——同一份文件树视图、同一组终端、同一份 diff。
- **不**像 Claude Code / Cursor：本期不集成任何 LLM，纯远程开发后端。

v1 目标场景是个人单用户：用户在云上跑 server，从 MacBook、远程办公电脑、平板浏览器都能 attach 到同一个会话继续工作。

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
- ❌ 多用户、权限模型、配额、审计
- ❌ TUI 内置编辑器、语法高亮、LSP
- ❌ 任意两个 git ref 间 diff、会话快照 diff
- ❌ 文件实时变更推送（didChange 流）—— v1 用按需刷新
- ❌ 沙箱化命令执行 —— 默认信任 server 用户
- ❌ 真正的协同编辑（OT/CRDT）。`$EDITOR` + sha256 乐观锁是终态
- ❌ 大文件 / 二进制传输优化（独立 blob 通道，详见 [`blob-transfer.md`](./blob-transfer.md)）

---

## 3. Architecture

```
┌─────────────────┐      WebSocket + TLS       ┌──────────────────────────────┐
│  TUI client A   │ ─────────────────────────► │                              │
└─────────────────┘                            │      motif server            │
┌─────────────────┐                            │  ┌────────────────────────┐  │
│  TUI client B   │ ─────────────────────────► │  │  Session (long-lived)  │  │
└─────────────────┘     JSON-RPC 2.0           │  │  - workdir             │  │
┌─────────────────┐                            │  │  - PTY pool (N shells) │  │
│  Web (browser)  │ ─► motif-web ─────────────►│  │  - file ops            │  │
└─────────────────┘                            │  │  - git ops             │  │
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
- **Session**: 长生命周期对象，绑定一个工作目录，持有自己的 PTY 池和订阅者列表。client 关闭后 Session 不销毁。
- **Client**: 短生命周期，连入即"attach"到某 Session 成为 subscriber，断开即"detach"。
- **Mirror 语义**: Session 是状态权威；所有 client 通过订阅同一组 server 推送事件来保证视图一致。client 不持有冲突状态。

### 独立二进制

按 Unix 惯例，server 与 client 各为独立可执行文件：

```
# 服务端（核心，部署到远端或本地后台）
motifd      --listen :7777  --token-file ~/.motif/token  [--cert … --key …]

# 客户端 —— TUI
motif-tui   attach   wss://host:7777/  --session work
motif-tui   list     wss://host:7777/
motif-tui   new      wss://host:7777/  --workdir ~/repo  --name work
motif-tui   destroy  wss://host:7777/  --name work

# Web 桥接（浏览器接入；不动核心 motifd）
motif-web   --listen :8080  --motifd-url wss://host:7777/  ...
```

拆分理由：

- **依赖不混杂**：`motifd` 不携带 TUI 依赖；`motif-tui` 不携带 server-side PTY/git 实现；`motif-web` 不携带 server 核心。
- **部署模型清晰**：核心服务端常以 daemon/systemd 跑 `motifd`，开发者只装 `motif-tui`，浏览器用户只用 `motif-web` 桥接。
- **Native GUI 未来直连 motifd**：协议平级，与 `motif-tui` 同款连接，不经 `motif-web`。

---

## 4. 核心功能详述

### 4.1 Session 管理（多 client mirror）

**生命周期**

- 由 client 调用 `session.create(workdir, name)` 创建；server 在 workdir 上启动一个 Session 实例。
- Client 调用 `session.attach(name)` 加入订阅者列表。一次连接只能 attach 一个 Session。
- Client 断开（网络中断或主动 detach）时只从订阅者列表里移除，Session 继续存活。
- `session.destroy(name)` 显式销毁；server 终止所有 PTY、释放资源。

**Mirror 一致性**

- 所有事件携带递增 `seq`；client 重连时带上最后已知 seq，server 补发缺失片段（PTY 输出有限缓冲，默认每 PTY 1MB ring buffer）。
- 终端尺寸：所有 attach 同一 PTY 的 client 协商最小 (cols, rows)；server 取最小公约数发给底层 PTY，避免显示截断。

详细事件清单与 wire 形状见 [`rpc.md`](./rpc.md) §7。

### 4.2 文件树

- 路径强制约束在 Session workdir 之下；任何 `..` 或绝对路径转义直接拒绝。
- `.gitignore` 默认隐藏，可通过参数 `show_hidden=true` 显示。
- 默认按目录在前、字母序排列。
- 文件树**不主动 watch**；client 在已知触发点（写文件、跑 git 命令、PTY 退出）后调用 `fs.tree` 刷新。

### 4.3 文件查看

- 文本/小文件：内联 base64 走主通道（`fs.read`），10MB 上限。
- 二进制大文件：通过**独立数据通道**传输，详见 [`blob-transfer.md`](./blob-transfer.md)。
- `mime` 字段由 server 用 `mime_guess` + magic bytes 推断，给 client 做渲染决策。

### 4.4 文件编辑（`$EDITOR` 模式）

v1 编辑模型的核心简化：**server 不内置编辑器，client 不实现编辑器**。

**流程**

1. Client 调用 `fs.read(path)` 拿到文件内容和 `sha256`。
2. Client 写入本地临时文件，记下原始 sha256。
3. Client 在本地终端启动 `$EDITOR <tmpfile>`。
4. 用户编辑、保存、退出编辑器。
5. Client 调用 `fs.write(path, content, expected_sha256=<原始>)`。
6. Server 校验文件当前 sha256 与 `expected_sha256` 一致后才写入；不一致返回 `Conflict`，让 client 决定是否覆盖（带 `force=true` 重试）。
7. Server 写入成功后广播 `tree.changed` 和 `git.changed`。

**理由**

- 用户已经有 `vim`/`nvim`/`hx`/`code -w` 的肌肉记忆，强制 client 内嵌编辑器只会复刻一份糟糕的体验。
- 代价是多 client 不能"实时同光标"看同一个文件。这是 v1 明确的取舍。

### 4.5 Git Diff（v1 仅工作区 vs HEAD/index）

- 仅当 workdir 是 git 仓库时启用；否则返回 `NotAGitRepo`。
- 不实现：任意两 ref 间 diff、跨 commit、blame、log。这些 v1 让用户在 PTY 里直接 `git log`/`git diff`。
- 写文件后 server 主动广播 `git.changed`，client 更新 diff 视图。

### 4.6 多会话 PTY（tmux-内置化）

- 每个 PTY 独立 ring buffer（默认 1MB），attach 时回放最近内容让新加入的 client 看到上下文。
- 输入广播：A client 在 PTY 里敲键，B client 立刻看到字符回显——这是"完全镜像"的核心体现。
- v1 只暴露 PTY 列表给 client；client 自己决定如何在 UI 中布局。Server 不管布局。

### 4.7 Shell Integration & Block 流

motifd 给每个新 PTY 注入 bootstrap 脚本（bash/zsh/fish），通过 OSC 标记把 shell
会话拆成结构化 *block*：每条命令产出 prompt / command / output 三段字节，附
带 cwd、命令文本、退出码、起止时间。Web/TUI client 在协议之上叠加只读 block UI。

机制详见 [`shell-integration.md`](./shell-integration.md)；wire 形状见
[`rpc.md`](./rpc.md) §6 / §7.4。

### 4.8 认证

- Server 启动时读 `--token-file` 中的 bearer token。
- 客户端在 WebSocket 握手 `Authorization: Bearer <token>` 校验；失败立即关闭连接。
- TLS 由用户提供证书（`--cert`/`--key`）；省略时 server 拒绝监听非 loopback 地址（防呆）。
- 不做 token 轮换、不做 refresh token、不做多 token。

---

## 5. 协议

JSON-RPC 2.0 over WebSocket，单一长连接承载所有方法调用和服务端推送。**完整 wire 协议参考见 [`rpc.md`](./rpc.md)**：

| 章节 | 内容 |
| --- | --- |
| §1 Transport | `/ws` 与 `/blob/<id>` 端点、Bearer 鉴权、帧格式、`seq` 回放 |
| §2 概念模型 | Session / Client / PTY / Block / View |
| §3 公共类型 | `SessionId` / `PtyId` / `BlockId` / `Seq` / `UnixMs` 等 |
| §4 错误码 | JSON-RPC 标准 + motif 特化（`-32001..-32016`、`-32099`） |
| §5 方法 | `session.* / pty.* / view.* / fs.* / git.*` |
| §6 Block 模型 | prompt / command / output 三段字节 + `OutputScope` |
| §7 推送事件 | tree / git / client / pty / view / shell-integration 全套 |

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

- `e`：拉文件到本地 tmp，启动 `$EDITOR`，保存后推回。编辑期间 TUI client 让出终端给编辑器；编辑器退出后回到 TUI。
- `d`：在右侧打开 diff 视图（unified patch，简单着色）。
- `t`：创建新 PTY tab；进入后键盘事件全部 forward 给 server。
- `Ctrl-b d`：detach（致敬 tmux），Session 在 server 上继续。
- 状态栏显示当前 attach 数（`3 clients`），让用户知道有别的 client 在线。

---

## 7. 安全模型（v1 单用户假设）

| 项 | v1 策略 |
|---|---|
| 认证 | 单 bearer token |
| 传输加密 | 强制 TLS（除非监听 loopback） |
| 路径越界 | server 端规范化 + workdir 前缀检查 |
| 命令执行 | 不沙箱化；server 进程权限 = 用户能执行的所有命令。文档明确"server 应以你信任的身份运行" |
| Token 泄漏 | 提示用户用文件权限 0600；不内置轮换 |
| 资源限额 | PTY 数量软上限（默认 32），文件读取 10MB 上限 |

### 7.1 连通性（client → motifd 的接入路径）

`motifd` 本身只是个 WS 监听器。motif client 默认提供两条"开箱即用"的接入路径，外加直连：

| 路径 | 适合 | 详细文档 |
|---|---|---|
| **直连**（`wss://host:port/`） | 局域网、公网 VPS（配 TLS 证书）、SSH 已开好的隧道 | 本文档 §3、§4.8 |
| **Tailscale 嵌入** | 个人多设备、跨区域、NAT 穿透；client 二进制即 tailnet 节点，无需装 daemon | [`tailscale.md`](./tailscale.md) |
| **SSH 隧道** | 只有 SSH 可用的内网、跳板机 / bastion；client 自动 spawn `ssh -L`，复用 ssh_config / agent | [`ssh-tunnel.md`](./ssh-tunnel.md) |

接入路径的选择由 client 端决定，server 不感知。设计原则：

- **motifd 不内置任何隧道 / VPN / 反代逻辑**。需要复杂部署的用户用现成工具（Tailscale daemon、Cloudflare Tunnel、nginx 反代）即可。
- **client 端可选集成**。Tailscale / SSH 都用 cargo feature 控制，关掉后回到纯 Rust 二进制 + 直连。

---

## 8. 并发与冲突

- **文件写入冲突**：4.4 的 `expected_sha256` 乐观锁。两个 client 同时 edit 同一文件，后写者会被拒绝并提示。
- **PTY 输入交错**：所有 client 输入并入同一字节流，与 tmux/screen 行为一致。
- **session.create 同名**：返回 `AlreadyExists`。

---

## 9. 实现选型

- **语言**：**Rust**。单二进制、无 GC、PTY/异步 IO 生态成熟。
- **运行时**：`tokio` + `axum`（HTTP/WS）+ `tokio-tungstenite`（client）+ `tokio-rustls`。
- **PTY**：`portable-pty`（跨平台）。
- **协议**：手写薄 JSON-RPC 层（`serde_json` + `tokio::sync::mpsc` 路由），不引重型 RPC 框架。
- **TUI**：`ratatui` + `crossterm`，`vte` 解析回放 PTY 字节。
- **Web 前端**：Vite + Solid + xterm.js + diff2html + Shiki，构建产物经 `rust-embed` 嵌入 `motif-web`。
- **Git**：fork `git` CLI，不引 `git2`（避免 libgit2 链接复杂度）。
- **Workspace 布局**：单 cargo workspace，4 个核心 crate：

  ```
  motif/
    crates/
      motif-proto/    # 协议类型（server / TUI / web 共享）
      motif-server/   # 核心服务端；产物 motifd
      motif-tui/      # TUI 客户端；产物 motif-tui
      motif-web/      # Web 桥接；产物 motif-web
    web/              # Vite + Solid 前端项目，被 motif-web 嵌入
  ```

  每个非 proto crate 自己负责 `src/lib.rs`（库代码）+ `src/main.rs`（薄入口）。`motifd` **只**讲 motif WS+JSON-RPC 协议，不挂 HTTP 静态资源、不知道浏览器存在；`motif-web` 既是 motifd 的 client 又是浏览器的 backend。

  二进制依赖图完全不重叠：`motifd` 不拉 `ratatui`/`crossterm`/`vte`/HTTP 静态资源；`motif-tui` 不拉 `axum`/`portable-pty`；`motif-web` 不拉 `portable-pty`/git 等核心逻辑。

- **配置**：`~/.motif/config.toml`（client 端记 server 列表 + token 路径）。
- **日志**：`tracing` + `tracing-subscriber`，默认 JSON 行写 `~/.motif/logs/server.log`。

---

## 10. Milestones

| 阶段 | 范围 |
| --- | --- |
| **M1: 协议骨架** | JSON-RPC 框架、auth、`session.*` |
| **M2: PTY 镜像** | `pty.*` 全套 + ring buffer 重放 + 输入广播 |
| **M3: 文件操作** | `fs.*` + path 越界保护 + sha256 乐观锁 |
| **M4: Git diff** | `git.*` + 写文件触发 `git.changed` |
| **M5: TUI client** | 完整 UX（4 个面板 + 编辑流程 + detach 快捷键） |
| **M6: 连通性** | Tailscale 嵌入 + `--via ssh://` 隧道封装 |
| **M7: Blob 通道** | `fs.openBlob/commitBlob` + `/blob/:tid` WS + 图片预览 |
| **M8: Web client** | `motif-web` 桥接 + `web/` 前端 |
| **M9: Shell integration** | OSC 133 / 7770 / 7771 / 7 + bootstrap 脚本 + BlockStore |

每个里程碑结束做一次端到端 demo。详细规划见对应专题文档：[`tailscale.md`](./tailscale.md)、[`ssh-tunnel.md`](./ssh-tunnel.md)、[`blob-transfer.md`](./blob-transfer.md)、[`web-client.md`](./web-client.md)、[`shell-integration.md`](./shell-integration.md)。

---

## 11. 仍开放（无承诺）

- 原生 GUI client（macOS/Windows）：协议已就绪，纯工程量问题。
- AI agent 作为一种特殊 client：订阅 PTY 输出 + 文件变更，通过 `fs.write` 落盘 patch。架构上天然契合，但本项目明确不做。
