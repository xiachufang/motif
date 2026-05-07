# Motif — Web Client 规划文档 (v1.5)

> 本文档是 [`prd.md`](./prd.md) 的延伸。v1 完成核心 server + TUI client 后，v1.5 引入两块新组件：浏览器前端 + 独立的桥接二进制 `motif-web`。**核心 `motifd` 不变**。
>
> 阅读前提：已熟悉 `prd.md` §3（架构）、§4（核心功能）、§5（JSON-RPC 协议）、§14（`motif-proto` 类型定义）。

---

## 1. Context

v1 验证了协议设计在 TUI client 上能跑通"完全镜像"的多 client attach 语义。但 v1 协议设计是否真的"client-agnostic"，必须用一个**形态完全不同的第二种 client** 来反向验证——浏览器是最自然的选择：

- 部署方便：用户起一个 `motif-web` 桥接进程，浏览器即可访问，不需要装 `motif-tui` 客户端二进制。
- 跨平台最广：手机/平板上也能临时 attach 看一眼会话状态。
- 反向施压协议：浏览器对 WebSocket header、二进制数据的限制会暴露 v1 协议中不够通用的地方，越早暴露越好。

v1.5 不是把 TUI 的所有功能 1:1 搬到浏览器，而是**优先做"看"的体验**：实时观察一个远端 session 的进展（PTY 输出、文件变更、git diff），编辑能力可以延后。

### 为什么要有独立的桥接二进制 `motif-web`

把"Web 的 backend"塞到 `motifd` 里看似省事，实际上会污染核心：HTTP server、静态资源、浏览器特有的鉴权约定都和 motif 协议无关。考虑到：

- **Native GUI client（macOS/Windows）也在路线图上**（见 `prd.md` §11），它和 TUI 一样直连 motifd 的 WS+JSON-RPC，不需要 HTTP 静态资源那一套。
- **不同部署拓扑**：可以一个 motifd 配多个 motif-web（不同区域、不同认证策略），或反过来一个 motif-web 接多个 motifd（用户切换）。
- **职责单一**：motifd 只做"远端开发会话的权威"，motif-web 只做"浏览器 ↔ motif 协议的翻译层"。任一侧出问题影响范围都小。

所以 v1.5 的产物是 **`motifd`（核心，不变）** + **`motif-web`（新增桥接二进制）** + **`web/`（前端项目，编译进 motif-web）**。

---

## 2. Goals & Non-goals

### v1.5 In-scope

- **`motif-web` 桥接二进制**：HTTP server 给浏览器、WS client 连 motifd、静态资源嵌入。
- **`web/` 前端项目**：Vite + Solid + xterm.js + diff2html，构建产物经 `rust-embed` 嵌入 `motif-web`。
- **多 PTY 实时镜像**：浏览器看到 motifd 推送的 PTY 输出，渲染与 TUI client 一致。
- **PTY 输入**：键盘输入经桥接 forward 到 motifd，浏览器也能"用"终端。
- **文件树浏览 + 只读预览**：点开文件看内容，配合简单语法高亮。
- **Git diff 查看**：unified diff 可视化（增删行高亮）。
- **多 PTY tab + 多 client 状态显示**：与 TUI 对齐；状态栏显示 TUI/Web/GUI 总数。
- **Token 登录页**：粘贴 token 即可使用，存浏览器 localStorage。

### v1.5 Non-goals（明确不做）

- ❌ **不动核心 motifd**：不在 motifd 加 HTTP server、静态资源、浏览器特化逻辑。
- ❌ 浏览器内编辑文件。"看"优先，编辑等 v2 评估（届时有可能引入 Monaco，也可能彻底跳过、坚持 `$EDITOR` 模式 + 文件下载/上传）。
- ❌ 移动端原生体验（PWA、离线、push）。响应式布局做到能用即可。
- ❌ 多用户登录、SSO、分享链接。延续 v1 的单用户模型。
- ❌ 浏览器内启动 `$EDITOR`：浏览器没有合适的本地终端可继承，强行做也只能开 fake editor。
- ❌ 自带 Web 终端复用 / 分屏：浏览器内的 PTY tab 切换够用，分屏让位给 TUI client。
- ❌ motif-web 做协议变换 / 数据转换：尽量做"近透明"的帧转发，唯一的智能是鉴权翻译（见 §7）。

### 与 v1 的关系

- **不引入新的 RPC 方法**是硬约束。如果实现时发现非新增不可，就回到 `motif-proto` 同时升级 motifd / TUI / Web 三处，避免协议分叉。
- **motifd 协议零变更**：v1 PRD 早期曾考虑把 Bearer header 改成 `auth.login` 第一消息。新方案下**不再需要**——浏览器的特殊鉴权由 motif-web 翻译，motifd 继续用 v1 的 HTTP-header Bearer，TUI / native GUI 都不动。

---

## 3. Architecture

```
                                                          ┌───────────────────────┐
   TUI client (motif-tui)    WS + Bearer header           │  motifd 二进制 (核心)  │
   ─────────────────  ─────────────────────────────────►  │                       │
                                                          │   axum (仅 /ws)       │
   Native GUI (未来)         WS + Bearer header           │   JSON-RPC 派发       │
   ─────────────────  ─────────────────────────────────►  │   Session/PTY/fs/git  │
                                                          │   (与 v1 完全一致)    │
                                                          └──────────▲────────────┘
                                                                     │
                                                       WS + Bearer   │
   Browser                                             header        │
   ┌──────────────────────────┐                                      │
   │ HTML / JS / CSS          │ ◄── HTTP ─────┐                      │
   │   (Solid + xterm.js …)   │               │                      │
   │ /ws                      │ ◄── WS+JSON ──┤                      │
   └──────────────────────────┘               ▼                      │
                                ┌───────────────────────────────┐    │
                                │  motif-web 二进制 (桥接)      │    │
                                │                               │    │
                                │  axum                         │    │
                                │   ├─ GET  /         embed     │    │
                                │   ├─ GET  /assets/* embed     │    │
                                │   └─ GET  /ws       upgrade   │    │
                                │           │                   │    │
                                │           ▼                   │    │
                                │  ┌─────────────────────────┐  │    │
                                │  │ Browser ↔ motifd 桥接    │  │    │
                                │  │  - 鉴权翻译 (浏览器→hdr) │  │────┘
                                │  │  - WS frame 1:1 转发     │  │
                                │  │  - 重连退避              │  │
                                │  └─────────────────────────┘  │
                                └───────────────────────────────┘
```

**三种 client 三条路径，motifd 看不出区别**

| Client | 到 motifd 的路径 | 鉴权方式 |
|---|---|---|
| `motif-tui` | 直连 WS | HTTP-header Bearer（v1 设计） |
| Native GUI（未来） | 直连 WS | HTTP-header Bearer |
| Browser | 经 `motif-web` 桥接 | 浏览器 → motif-web 用 `auth.login` 首消息；motif-web → motifd 用 HTTP-header Bearer |

**关键设计**

- **motifd 完全不感知浏览器**：它只看到 motif-web 是个普通的 motif client。从 motifd 视角，TUI / GUI / motif-web 都是相同形态的 WS 连接。
- **motif-web 是"近透明"桥**：除了首条 `auth.login` 拦截做鉴权翻译，其余 WS frame 在两侧 1:1 转发。每个浏览器连接对应一条独立的 motif-web ↔ motifd 连接（不做多路复用），保证 motifd 端看到的 ClientId 仍然 1 个浏览器 = 1 个 client。
- **静态资源嵌入 motif-web**：前端构建产物 (`web/dist`) 通过 `rust-embed` 编译期打包进 `motif-web` 二进制，部署只多一个二进制不多一个目录。
- **TUI / native GUI 路径零改动**：他们的代码不知道 motif-web 存在；motif-web 是只对浏览器有意义的可选组件。
- **跨 client 镜像仍然成立**：多个浏览器、多个 TUI、多个 GUI 同时 attach 同一 session 时，motifd 把所有事件广播给所有连接（无论是不是经过桥接）。"完全镜像"语义不变。

**部署形态**

- 最简：单机一个 `motifd` + 一个 `motif-web`，本地 lo 接口通信。
- 进阶：内网一个 `motifd`，DMZ 一个 `motif-web` 反向代理对外。
- 多区域：一个核心 `motifd`，多区域各部署 `motif-web`，按地理就近接入；motif-web 之间无状态、可独立重启。

---

## 4. 功能详述

### 4.1 登录 / 会话选择

- 首次访问 `/` 时：localStorage 里没 token → 渲染**登录页**（一个 `<input>` 让用户粘 token + "记住"复选框）。
- 拿到 token 后：调用 `session.list`，渲染会话列表。无 session 时显示"创建新 session"按钮（form：name + workdir）。
- 点击某个 session → 进入主界面 → 自动 `session.attach`。

### 4.2 主界面布局（桌面）

```
┌─ motif @ work · 3 clients ─────────────────────── [logout] [⚙] ──┐
│ ┌─ files ────────┐ ┌─ tabs ─────────────────────────────────────┐ │
│ │ src/           │ │  src/foo.go  │ pty:sh-1*  │ diff  │  +     │ │
│ │   foo.go    M  │ ├────────────────────────────────────────────┤ │
│ │   bar.go       │ │                                            │ │
│ │ go.mod         │ │   (当前 tab：PTY xterm / 只读预览 / diff)   │ │
│ │ ...            │ │                                            │ │
│ ├─ git ──────────┤ │                                            │ │
│ │ M src/foo.go   │ │                                            │ │
│ │ ?? new.txt     │ │                                            │ │
│ └────────────────┘ └────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

布局参考 TUI（`prd.md` §6），但用浏览器原语：左侧固定栏可拖动调宽，tab 区可拖动重排（v1.5 可省略，能切换即可）。

### 4.3 多 PTY 实时镜像

- 每个 PTY 一个 xterm.js 实例。
- 收到 `pty.output` notification → base64 解码 → `term.write(bytes)`。
- 用户键入 → xterm `onData` → 打包成 `pty.write` request 发给 server。
- 终端尺寸：xterm 暴露 `cols/rows`，浏览器尺寸变化时调用 `pty.resize`。Server 端按"最小公约数"策略与其他 client 协商（已在 v1 PRD §4.1 定义）。
- ANSI 兼容：xterm.js 默认覆盖度足够，不需要额外做 vte 解析。

### 4.4 文件树 + 只读预览

- 文件树用按需展开模式：点击目录 → `fs.tree(path, depth=1)` → 展开。避免初始加载就拉整棵树。
- 收到 `tree.changed` notification → 对受影响的目录节点做局部刷新（重新 `fs.tree`）。
- 点击文件 → `fs.read(path)` → 在新 tab 打开，按扩展名做语法高亮（用 [Shiki](https://shiki.matsu.io/)，一次性懒加载语言包）。
- **只读**：不显示保存按钮，不绑定 Ctrl-S。强调"看"。
- 二进制文件：检测 `binary: true` → 显示"二进制文件，X 字节"，给一个"下载"按钮（直接 `data:` URL）。
- >10MB 文件：server 已经会拒绝，前端展示友好错误。

### 4.5 Git diff 视图

- "diff" 是一种特殊 tab：显示 `git.status` 结果 + 当前选中文件的 unified diff。
- 用 [`diff2html`](https://diff2html.xyz/) 渲染（side-by-side 或 inline 视图，提供切换按钮）。
- 收到 `git.changed` notification → 当前 diff tab 自动重发 `git.diff` 拿最新。
- 不点开 diff tab 时不订阅刷新，节省渲染。

### 4.6 多 client 状态显示

- 顶栏显示 `N clients`。
- 点击展开下拉，列出每个 ClientId + since 时间（用 `clients` 字段，由 `attach` result 带来 + `client.joined`/`client.left` 增量维护）。
- 自己的 ClientId 高亮"(this)"。

### 4.7 断线重连

- WebSocket `onclose` → 5 秒退避重试（最多 5 次）。
- 重连成功后用保存的 `last_seq` 发起 `session.attach` → server 补发缺失事件。
- 重连失败超阈值 → 显示"已断开"覆盖层，提供"重试"按钮，不自动跳转登录（避免误清状态）。

---

## 5. 技术选型

### 5.1 前端栈（推荐组合）

| 层 | 选择 | 理由 |
|---|---|---|
| 语言 | **TypeScript** | 协议类型从 `motif-proto` 生成（见 §6），强类型对协议严格性帮助大 |
| 构建工具 | **Vite** | 启动快、产物小、零配置默认就够 v1.5 用 |
| 框架 | **Solid.js** | 无虚拟 DOM、bundle ~7KB、JSX 上手成本低；PTY 流式更新场景下细粒度响应优于 React |
| 终端 | **xterm.js** | 事实标准，覆盖率最高 |
| Diff | **diff2html** | 直接吃 unified diff 文本输出 HTML，与 server `git.diff` 输出对齐 |
| 高亮 | **Shiki** | TextMate 语法、按需加载语言包；比 highlight.js 准 |
| 样式 | **TailwindCSS**（启用 JIT + purge） | 小工程量、最终 CSS bundle 通常 <10KB |
| 状态 | Solid 自带 store | v1.5 状态简单，不引 Redux/Zustand |

**为什么不用 React？** 没有强制反对。但 PTY 高频字节流会让 React 频繁 reconcile，Solid 直接细粒度 update 更省心。如果团队对 React 更熟，可以替换；不影响其它选择。

**为什么不用 Svelte？** Solid 与 Svelte 二选一都成立。Solid 胜在 JSX 调试 + TypeScript 体验。无强偏好的情况下选 Solid。

### 5.2 motif-web 桥接二进制（Rust）

`motif-web` 是一个独立的 Rust 二进制，与 `motifd`、`motif-tui` 平级。它的依赖图严格不含核心服务端逻辑：

| 用途 | crate |
|---|---|
| HTTP / WS server（面向浏览器） | `axum`（含 `ws` feature） |
| WS client（连 motifd） | `tokio-tungstenite`（含 `rustls-tls-webpki-roots`） |
| TLS（双向：server 端给浏览器、client 端给 motifd） | `rustls` + `tokio-rustls` + `rustls-pemfile` |
| 静态资源嵌入 | `rust-embed` |
| 协议类型 | `motif-proto`（v1 既有）—— 用于解析首条 `auth.login` |
| CLI 参数 | `clap` |
| 日志 | `tracing` + `tracing-subscriber` |

**注意**：`motif-web` **不依赖** `motif-server`、`portable-pty`、`vte`、`ratatui`，也不依赖 `motif-tui`。它对 motif 协议的理解只够拦截首条鉴权消息，其余 frame 透明转发。

### 5.3 开发模式

- `motif-web --dev-proxy http://localhost:5173`：把 `/` 和 `/assets/*` 的请求反向代理到本地 Vite dev server，热更新前端不需要重编 Rust。
- `motif-web --motifd-mock`：跑 in-memory 假 motifd，便于前端在没有真实环境时调试 UI（仅 dev 构建启用）。

---

## 6. 仓库结构变更

v1 工作区上**不动 motifd 这条链路**（即 motif-server crate 不变），新增一个 Rust 桥接 crate + 一个前端项目目录：

```
motif/
├─ Cargo.toml                       # workspace
├─ crates/
│  ├─ motif-proto/                  # v1 既有，被 motif-web 也依赖
│  ├─ motif-server/                 # v1 既有 (lib + bin motifd)；★ 不动，无 build.rs/static/
│  ├─ motif-tui/                    # v1 既有 (lib + bin motif-tui)
│  └─ motif-web/                    # ★ 新增 (lib + bin motif-web)：桥接 crate
│     ├─ Cargo.toml                 # [lib] + [[bin]] name = "motif-web"
│     ├─ build.rs                   # 调 pnpm 构建 ../../web/，把 dist/* 拷到 static/
│     ├─ static/                    # rust-embed source；构建期生成，gitignore
│     └─ src/
│        ├─ lib.rs                  # pub fn run(cfg: WebConfig) -> Result<()>；可被集成测试调用
│        ├─ main.rs                 # 薄入口：clap 解析 → motif_web::run(cfg).await
│        ├─ config.rs               # WebConfig (listen, motifd-url, token files, certs)
│        ├─ http.rs                 # axum 路由（/、/assets/*、/ws）
│        ├─ bridge.rs               # 浏览器 WS ↔ motifd WS 转发主循环
│        ├─ auth.rs                 # 拦截首条 auth.login + 翻译为 motifd Bearer header
│        ├─ embed.rs                # rust-embed Assets 定义 + serve handler
│        └─ devproxy.rs             # --dev-proxy 时反代到 Vite dev server（仅 dev feature）
└─ web/                              # ★ 新增：独立的前端项目（非 cargo crate）
   ├─ package.json
   ├─ vite.config.ts
   ├─ tsconfig.json
   ├─ tailwind.config.ts
   ├─ dist/                          # pnpm build 产物（gitignore，被 motif-web build.rs 消费）
   └─ src/
      ├─ main.tsx                    # Solid 入口
      ├─ proto/                      # ★ 由 motif-proto 经 ts-rs 生成的 TS 类型
      │  └─ index.ts
      ├─ ws/
      │  ├─ client.ts                # JSON-RPC over WS（连接到 motif-web /ws）
      │  └─ events.ts                # 事件路由
      ├─ store/
      │  └─ index.ts                 # Solid store: session/ptys/files/git
      ├─ pages/
      │  ├─ Login.tsx
      │  └─ Sessions.tsx             # session 列表 / 创建
      ├─ panels/
      │  ├─ FileTree.tsx
      │  ├─ GitStatus.tsx
      │  ├─ TabBar.tsx
      │  └─ Topbar.tsx
      └─ tabs/
         ├─ PtyTab.tsx
         ├─ FilePreviewTab.tsx
         └─ DiffTab.tsx
```

### 为什么 `web/` 在顶层而不是 `crates/motif-web/web/`

- 保持 `crates/` 树纯 Rust，cargo workspace 扫描时不会撞到无关文件。
- 前端工具链（pnpm/Node）有自己的依赖管理，跟 cargo 解耦更干净。
- `motif-web/build.rs` 走相对路径 `../../web/` 调 pnpm，关系明确不绕。

### TS 协议类型同步

候选三种方案，选一种：

1. **手写并对齐**：简单，但容易飘。不推荐。
2. **`ts-rs` derive**：在 `motif-proto` 给每个类型加 `#[derive(TS)]`，`cargo test --features ts-rs` 时生成 `web/src/proto/*.ts`。**推荐**——零运行期开销，编译期保证一致。
3. **JSON Schema → TS**：用 `schemars` 生成 schema，再用 `json-schema-to-typescript` 转 TS。链路长，过度工程。

走方案 2，并把 `cargo test -p motif-proto --features ts-rs` 加到 CI 必经步骤。

### 构建流水

```
cargo build --release -p motif-web
   └─ motif-web 的 build.rs 执行：
       1. 检查 web/dist 是否最新（mtime 比 web/src/* 新）
       2. 若过期或不存在 → 调 `pnpm install && pnpm build` (cwd=web/)
       3. 把 web/dist/* 拷到 crates/motif-web/static/
   然后正常 cargo 编译 motif-web，rust-embed 把 static/ 嵌入二进制
```

**核心 `motif-server` 完全不参与前端构建**：`cargo build -p motif-server`（产物 `motifd`）不需要 Node/pnpm，CI 跑核心路径时不被前端工具链拖慢。

### Cargo 依赖示例

```toml
# crates/motif-web/Cargo.toml
[package]
name = "motif-web"
version.workspace = true
edition.workspace = true

[[bin]]
name = "motif-web"
path = "src/main.rs"

[dependencies]
motif-proto        = { path = "../motif-proto" }
axum               = { workspace = true }
tokio              = { workspace = true }
tokio-tungstenite  = { workspace = true }
tokio-rustls       = { workspace = true }
rustls             = { workspace = true }
rustls-pemfile     = { workspace = true }
rust-embed         = { version = "8", features = ["axum"] }
serde              = { workspace = true }
serde_json         = { workspace = true }
clap               = { workspace = true }
anyhow             = { workspace = true }
tracing            = { workspace = true }
tracing-subscriber = { workspace = true }

[features]
dev-proxy = []      # 启用 --dev-proxy 反代到 Vite，仅 debug 构建打开
```

构建依赖（首次 `cargo build -p motif-web` 需要本机有）：`pnpm`（或 `npm`）+ `node >= 20`。`build.rs` 里检测不到时给清晰报错。**核心 `cargo build -p motif-server` / `cargo build -p motif-tui` 不受此影响**——没有 Node 也能编 server 和 TUI。

---

## 7. 认证流程

> v1.5 **不改 motifd 协议**。motifd 继续用 v1 PRD §4.7 定义的"WS 握手 `Authorization: Bearer <token>` header"。所有改动都在 motif-web 桥接层完成。

### 7.1 三段式鉴权链路

```
Browser ── auth.login {token} ──►  motif-web  ── WS 握手 Authorization: Bearer ──►  motifd
        ◄── auth response ────                ◄── 握手成功 / 401 ──
        ◄── (后续 frame 透明双向转发) ──►            ◄── (后续 frame 透明转发) ──►
```

每个浏览器连接到 motif-web 时，motif-web 会**新开一条**到 motifd 的 WS 连接，1:1 绑定，连接生命周期同进同退。

### 7.2 浏览器 ↔ motif-web

浏览器侧无法设置自定义 HTTP header，所以采用"WS 建立后首条 JSON-RPC 即 `auth.login`"的浏览器友好方案：

```ts
// web/src/ws/client.ts (示意)
const ws = new WebSocket(`${origin}/ws`);
ws.onopen = () => ws.send(JSON.stringify({
  jsonrpc: "2.0", id: 1, method: "auth.login", params: { token: localStorage["motif.token"] }
}));
// 收到 ok 后再发其它请求
```

motif-web 行为：

- WS 升级成功后启动 5 秒 deadline。
- **必须**收到 `auth.login` 作为第一条消息；否则关闭连接（关闭码 4401 = `AuthRequired`）。
- 校验 token：与 motif-web 启动时配置的 `--browser-token-file` 比对（建议与 motifd 的 token 用同一个值，避免双重维护）。
- 校验通过 → motif-web 才开始握手与 motifd 的 WS 连接（用 `--motifd-token-file` 作为 Bearer header）。
- 与 motifd 握手成功 → 给浏览器回 `auth.login` 的成功 response（`{client_id, server_version}` 由 motif-web 拼装：`client_id` 来自 motifd 的 `session.attach` 结果或 motif-web 自生成，`server_version` 来自 motifd `?version` 探测响应）。
- 之后所有 frame **双向 1:1 透明转发**。motif-web 不解析 JSON-RPC 内容（除非将来加监控/限速）。

### 7.3 motif-web ↔ motifd

motif-web 把自己当作一个**普通 motif client**（与 TUI 相同）：

- 协议：v1 的 WS + JSON-RPC + `Authorization: Bearer` 握手。
- Token 来源：motif-web 启动参数 `--motifd-token-file`。
- TLS：通过 `--motifd-ca` 指定 motifd 自签证书的 CA（生产部署时通常是公网 CA 自动校验）。

### 7.4 motif-web 启动参数

```bash
motif-web \
  --listen :8080 \                                # 浏览器接入端口
  --motifd-url wss://motifd.internal:7777/ \      # 上游 motifd 地址
  --motifd-token-file /etc/motif/motifd.token \   # 本桥到 motifd 的凭证
  --browser-token-file /etc/motif/web.token \     # 浏览器需要提交的凭证（可与 motifd token 同值）
  --motifd-ca   /etc/motif/motifd-ca.pem \        # 上游证书校验（自签时用）
  --bind-cert   /etc/motif/web.cert \             # 浏览器侧 TLS 证书
  --bind-key    /etc/motif/web.key
```

motif-web → motifd 这一跳的连通性方式（与 motif-tui 共享路由层）：

- 默认直连 `--motifd-url`
- 走 Tailscale：加上 `--via tailnet` 和相关 `--ts-*` 参数（详见 [`tailscale.md`](./tailscale.md) §8）
- 走 SSH 隧道：用 `--motifd-via ssh://user@host`（详见 [`ssh-tunnel.md`](./ssh-tunnel.md) §5）

防呆：

- `--listen` 不是 loopback 时强制要求 `--bind-cert`/`--bind-key`，否则启动失败。
- `--motifd-url` 是 `wss://`（非 `ws://`）时强制需要 `--motifd-ca` 或系统信任链可解析。
- `--browser-token-file` 不存在或权限不是 `0600` 时打印 warning（不阻断启动，但日志显眼）。
- `--motifd-via` 与 `--motifd-url` 之间冲突时报错（不允许同时显式指定两套路由）。

### 7.5 浏览器侧 token 存储

- 默认存 localStorage（key `motif.token`）。
- 登录页显示"记住"复选框；不勾选时存 sessionStorage（关闭标签页即清）。
- "退出"按钮：清 storage + 关闭 WS + 跳回登录页。
- TLS 在传输路径上始终强制（见上述防呆）。

---

## 8. 性能与稳定性考量

### 8.1 PTY 输出节流

- 一个跑 `cargo build` 的 PTY 在峰值能产出 MB/s 级字节流。Server → 浏览器走 WS，前端 xterm.js write 是同步操作，可能阻塞主线程。
- 策略：在 WS 接收侧把 `pty.output` 事件按 PTY 维度合并（≤16ms 内的连续 chunk 合并成一个 `term.write`），结合 xterm 自带的 `requestAnimationFrame` 渲染节流。
- 后台标签页（document.hidden）时降低节流频率到 100ms，但**不丢字节**——只是延后渲染。

### 8.2 Bundle size 预算

| 部分 | 预算 | 备注 |
|---|---|---|
| 框架（Solid + 路由） | <20 KB gz | |
| xterm.js 核心 | ~80 KB gz | 不可避免 |
| diff2html | ~30 KB gz | 仅在打开 diff tab 时动态 import |
| Shiki + 默认语言包 | ~50 KB gz 起 | 按需加载，初始包不带 |
| 应用代码 + Tailwind | <30 KB gz | |
| **总初始** | **<150 KB gz** | 目标 |

超出预算时优先把 Shiki 和 diff2html 拆成动态 chunk，初始路由不加载。

### 8.3 重连体验

浏览器 ↔ motif-web 和 motif-web ↔ motifd 是两条独立的 WS，任一条断都需要处理：

- **浏览器 → motif-web 断**：xterm/UI 显示"已断开"，5 秒退避重连最多 5 次。重连成功后浏览器重发 `auth.login` + `session.attach { last_seq }`，motif-web 重新建立到 motifd 的连接。
- **motif-web → motifd 断（浏览器仍在线）**：motif-web 主动 close 浏览器的 WS（关闭码 4503 = `UpstreamUnavailable`），让浏览器走上面那条重连逻辑，避免在 webd 内部维持复杂的"半通"状态。
- 重连时 `last_seq` 之后的事件可能超过 motifd ring buffer（每 PTY 1MB）→ motifd 丢弃旧事件，client 收到一个 `session.resync` 通知，强制刷文件树 + 重新订阅各 PTY。
- v1.5 把 `session.resync` 加入 `motif-proto`（前文说的"不新增方法"硬约束的唯一例外候选；事件级扩展，比新增 RPC 方法侵入小）。

---

## 9. Milestones

| 阶段 | 范围 | 验收 |
|---|---|---|
| **W1: 工程基建** | `crates/motif-web/` Rust 桥接骨架、`web/` Vite + Solid + Tailwind、`build.rs` 调通 pnpm、`ts-rs` 协议同步、轴 `motif-web /` serve hello world | `cargo build -p motif-web` 一键产出含前端的 `motif-web` 二进制；启动 `motifd` + `motif-web` 后浏览器能拿到一个 hello world，`cargo build -p motifd` 仍然不依赖 Node |
| **W2: 鉴权透传 + Session 列表** | 浏览器 ↔ motif-web 的 `auth.login` 拦截、motif-web ↔ motifd 的 Bearer 握手、登录页、session list / create 页 | 浏览器登录后能调通 `session.list` / `session.create`；同一 motifd 上 TUI 和 Web 看到的 session 列表一致 |
| **W3: PTY 镜像 + 输入（透明转发）** | motif-web 的 frame 双向透明转发主循环、xterm.js + 多 tab + `pty.output/write/resize` 的浏览器侧实现 | 浏览器和一个 TUI client 同时 attach 同一 PTY，互相看到对方的击键和输出；motif-web 的 CPU/内存占用稳定 |
| **W4: 文件树 + 只读预览 + Git diff** | 文件树面板、Shiki 高亮、diff2html、`tree.changed`/`git.changed` 增量刷新 | 在 PTY 里改文件、git add，浏览器侧文件树 M 标记和 diff tab 自动更新 |
| **W5: 重连 / 性能 / 移动响应式** | 浏览器 ↔ motif-web 退避重连、motif-web ↔ motifd 断线时主动关闭浏览器 WS、`session.resync`、节流、窄屏布局 | 杀掉 motif-web 进程再启动，浏览器自动恢复；杀掉 motifd 时浏览器收到 `UpstreamUnavailable` 关闭码并友好提示；手机浏览器能看 PTY |

每个里程碑结束做一次**混合 client demo**：一个浏览器 + 一个 TUI 同时 attach，验证完全镜像。W3 之后强烈建议加入"两个浏览器 + 两个 TUI"的四 client 并发场景作为冒烟测试。

---

## 10. 开放问题

仅列出影响 W1 之前需要决策的项，其它细节随实施推进。

- ✅ **桥接二进制名**：已确认 `motif-web`（与 `motif-tui` 保持 `motif-<role>` 一致命名）。
- [ ] **前端框架最终拍板**：Solid（推荐） vs Svelte vs React？
- [ ] **`ts-rs` 还是手写 TS 类型**？推荐 `ts-rs`，需要在 `motif-proto` 加 feature flag。
- [ ] **`browser-token` 是否允许独立于 `motifd-token`**？v1.5 默认建议同值（简化运维）；预留独立配置以便未来加多用户/不同信任域。
- [ ] **motif-web 是否要做请求级速率限制**？v1.5 不做（信任内网部署），v2 视攻击面再评估。

---

## 11. 与 v2/v3 的衔接（无承诺）

- **浏览器内编辑**：v1.5 明确不做。如果未来要做，可能的路径：嵌入 Monaco editor + 引入 `fs.write` 的乐观锁路径（与 TUI 行为一致），不引入 OT/CRDT。"协同编辑"仍是放弃方向。
- **会话分享链接**：v1 是单用户，没有"分享给别人"的语义。如果未来引入多用户，分享链接可作为入口；不在 v1.5 评估。
- **PWA / 离线**：仅在 server 不可达时显示"已断开"，不做真正离线。
- **多 motifd 聚合**：motif-web 当前是 1 ↔ 1 桥接。未来可演进为"用户在登录页选择目标 motifd"的多上游模式（motif-web 维护 motifd 注册表）。架构上是 motif-web 的纯增强，不影响 motifd。
- **Native GUI client**：协议直连 motifd，与 motif-web 无关。届时让新的 GUI crate 直接依赖 `motif-tui` 这个 lib，并通过 cargo feature gate 关闭 ratatui/crossterm/vte 那部分（在 `motif-tui` 加 `default-features = ["tui"]`，GUI 消费方关掉），即可复用 WS client 部分。**不**为了未来需求提前把 WS client 抽成新 crate；真到 native GUI 落地再做。
- **AI agent 作为 client**：若实现，浏览器侧不需要特殊 UI，只是状态栏多一个 "agent" 客户端标识；底层共享同一协议。
