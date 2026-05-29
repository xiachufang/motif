# Motif — Web Client

> Web SPA 由 `motifd` 进程同源 serve，浏览器走与 `motif-tui` 完全相同的协议端点。
>
> 阅读前提：已熟悉 [`prd.md`](./prd.md) §3（架构）、§4（核心功能），以及 [`rpc.md`](./rpc.md)（协议与端点）。

---

## 1. Context

Web 端反向验证 v1 协议是否真的"client-agnostic"——浏览器对 WebSocket header、二进制数据的限制会暴露协议中不够通用的地方。同时它兼做"瘦客户端"：手机 / 平板 / 浏览器随时 attach 上一个远端 session 看进展，不装本地二进制。

`motifd` 同时承担协议服务器和 Web SPA 宿主两件事：

- 它已经在 axum 上有 HTTP `/rpc/*` + WS `/events` + WS `/pty/<id>`，再挂两条静态资源路由 (`/`、`/assets/*`) 是零成本的事；`rust-embed` 把 `apps/web/dist` 编译期塞进二进制，部署仍然是单文件。
- 浏览器唯一需要的特殊化是 `WebSocket` API 设不了自定义 header，所以 `/events` 和 `/pty/<id>` 在 token 非空时接受 `?token=<value>` query，走的还是同一个 token 校验函数（`crates/motif-server/src/auth.rs` 的 `verify_header_or_query`）。

`apps/web/` 顶层目录是独立的前端项目，构建后被嵌入到 `motifd`。

---

## 2. Architecture

```
   Browser                                       motifd 二进制
   ┌──────────────────────────┐                  ┌────────────────────────────┐
   │ React SPA (apps/web/dist)     │  ── HTTP ────►   │ GET /                       │
   │  - xterm.js              │  ── HTTP ────►   │ GET /assets/*  (rust-embed) │
   │  - diff2html             │                  │ ─────────────────────────── │
   │  - highlight.js          │  ── HTTP POST ►  │ /rpc/<method>  (optional    │
   │                          │                  │  Bearer hdr)                │
   │  - zustand store         │  ── WS ──────►   │ /events?session=&since=     │
   │                          │  ── WS ──────►   │ /pty/<id>?session=          │
   └──────────────────────────┘                  │ ─────────────────────────── │
                                                 │ SessionManager / PTY / fs / │
                                                 │ git / fswatch  (= TUI 见到的│
                                                 │  完全相同的对象)              │
                                                 └────────────────────────────┘
```

三句话总结：

- **路由都在一个 axum router 里**（`crates/motif-server/src/ws.rs:32`），SPA 路由（`/`、`/assets/*`、SPA fallback）和协议路由（`/rpc/<method>`、`/events`、`/pty/<id>`）平级。
- **`motifd` 看不出浏览器和 TUI 的区别**：两边打到同一组 `SessionManager` / PTY / git 对象，事件广播也走同一条路径。"完全镜像"语义因此天然成立。
- **没有 `motif-web` crate / 二进制**：浏览器特殊化只是非空 token 时的 `?token=` query 一条，纳进 motifd 自己的 router 就够。

---

## 3. Source Layout

### 前端（顶层 `apps/web/`，非 cargo crate）

```
apps/web/
├─ package.json          React 19 + Vite 8 + TypeScript（见 apps/web/package.json）
├─ vite.config.ts        构建配置 + dev proxy 把 /rpc /events /pty 转发到 motifd
├─ index.html
├─ dist/                 pnpm build 产物，被 motif-server build.rs 消费
└─ src/
   ├─ main.tsx           React 入口
   ├─ App.tsx            页面路由 (login / sessions / workspace)
   ├─ ws/client.ts       RpcClient：fetch /rpc + WS /events + WS /pty/<id>
   ├─ proto/             协议类型
   ├─ store/             zustand store（store.ts + 子模块）
   ├─ pages/             Login / Sessions / Workspace
   ├─ panels/            FileTree / GitStatus / TabBar / Topbar / MobileInputDock
   ├─ tabs/              PtyTab / FilePreviewTab / DiffTab
   ├─ hooks/             复用 hooks
   └─ shellIntegration.ts  shell-integration OSC 标记的浏览器侧解析
```

技术栈：
- 框架：**React 19**（见 `apps/web/package.json:19`）。
- 状态：**zustand**。
- 高亮：**highlight.js**。
- 终端：xterm.js。
- Diff：diff2html。
- 构建：Vite。

### 服务端（`crates/motif-server`）

```
crates/motif-server/
├─ build.rs              拷贝 ../../apps/web/dist → static/，供 rust-embed 嵌入
├─ static/               build.rs 生成，gitignore；缺失时回退占位 index.html
└─ src/
   ├─ embed.rs           rust_embed::Assets + serve_index / serve_assets / serve_spa_fallback
   ├─ ws.rs              router() 把 SPA 路由 + 协议路由组装到一起
   ├─ http_rpc.rs        /rpc/<method> 派发
   ├─ events_ws.rs       /events WS 升级
   ├─ pty_ws.rs          /pty/<id> WS 升级
   └─ auth.rs            TokenStore::verify_header_or_query
```

`crates/motif-server/src/embed.rs:7` 把 `static/` 目录通过 `#[derive(RustEmbed)]` 编译期打包到 `motifd` 二进制。`crates/motif-server/src/ws.rs:32` 把以下五条路由挂上去：

```rust
Router::new()
    .route("/",            get(crate::embed::serve_index))
    .route("/assets/{*p}", get(crate::embed::serve_assets))
    .route("/rpc/{method}", axum::routing::post(http_rpc::rpc_dispatch))
    .route("/events",       get(crate::events_ws::events_upgrade))
    .route("/pty/{pty_id}", get(crate::pty_ws::pty_upgrade))
    .fallback(crate::embed::serve_spa_fallback)
```

SPA fallback 保证 React 端的客户端路由（任何未匹配的 GET）都回到 `index.html`。

---

## 4. Build

前端和后端是两套构建链，由 `motif-server/build.rs` 串起来：

```
pnpm --dir apps/web build      # 在 apps/web/ 下跑 tsc -b && vite build，产出 apps/web/dist/
cargo build -p motif-server
  └─ build.rs
       1. 清空 crates/motif-server/static/
       2. 拷贝 apps/web/dist/* → static/
       3. 若 apps/web/dist 不存在，写一个占位 index.html，提示"先 pnpm build"
  └─ rust-embed 编译期把 static/ 嵌入 motifd 二进制
```

要点：

- **前端构建不会被 cargo 自动触发**。开发者要么手动 `pnpm --dir apps/web build`，要么用 Vite dev server（见下面 4.1）。`build.rs` 只在 `apps/web/dist` 已存在时拷贝，否则塞占位页面，不阻断 `cargo build`。
- 构建产物文件名固定（`assets/[name].js` 等，见 `apps/web/vite.config.ts:33`）。motifd 给静态资源回 `Cache-Control: no-store`（`crates/motif-server/src/embed.rs:28`），所以不依赖 hash 文件名做 cache busting。
- `static/` 是 build.rs 生成物，gitignore；`apps/web/dist/` 同理。
- `cargo:rerun-if-changed` 监听 `apps/web/dist`、`apps/web/index.html`、`apps/web/src`（见 `build.rs:7-9`），所以前端重新构建后 `cargo build` 会重跑 build.rs 重打 static。

### 4.1 开发模式

跑 `pnpm --dir apps/web dev` 起 Vite dev server（端口 5173），它把 `/rpc`、`/events`、`/pty` 反代到 `http://127.0.0.1:7777` 上的 motifd（见 `apps/web/vite.config.ts:41`）。浏览器开 `http://localhost:5173` 即可热更新调前端，不需要重编 motifd。

要把 motifd 指到别处，设 `VITE_MOTIFD=http://host:port`（同样在 `vite.config.ts`）。

---

## 5. Transport

浏览器走的 RPC + 事件 + PTY 端点与 motif-tui 完全相同；详细协议见 [`rpc.md`](./rpc.md)。这里只列浏览器侧的几个差异点。

### 5.1 RPC

`POST /rpc/<method>`，body 是 JSON params。请求头：

```
Authorization: Bearer <token>  ← 仅在 token 非空时发送
Content-Type: application/json
X-Motif-Session: <sid>      ← attach 之后所有请求都带上，server 回的 X-Motif-Session 提供
```

实现见 `apps/web/src/ws/client.ts`（`httpCallRaw`）。

### 5.2 Events

`GET /events?session=<sid>&since=<seq>[&token=<value>]`，Upgrade 到 WS。客户端断线 → 指数退避重连（`apps/web/src/ws/client.ts`，500ms 起，封顶 15s），重连成功后 Workspace 层用记到的 `last_seq` 重发 `session.attach` 做 replay。

### 5.3 PTY 字节流

Web 和 iOS 使用同一套 active-tab 模型：浏览器只为当前 active 的 PTY tab 打开
一条 `/pty/<id>` WS，inactive tab 保留 xterm surface 和本地 byte cursor，但不
继续订阅 live 输出。切回某个 PTY tab 时，客户端用
`GET /pty/<id>?session=<sid>&since=<bytes>[&token=<value>]` 重连；
`since` 是 PTY 原始输出的 byte cursor，不是事件 `seq`。`/pty` 不带 primary 标记
(纯传输);primary 由 `view.activate` 认领——窗口获得焦点 / app 转前台时重新
`view.activate` 当前 active view,失焦/后台的客户端不抢 primary。motifd 会先从
server-side ring replay `since..total`，再切到 live，因此 tab 切换期间的输出由
server buffer catch-up 补齐，浏览器本地不再维护另一份 2 MB 历史 buffer。

inactive tab 的滚动和画面来自仍然挂载的 xterm surface（pane 只是 `display:none`），
所以普通 tab 切换不会重刷整段历史，也不会闪烁。只有 server 返回 `4011` /
`4012`（cursor 已不可 replay）时，浏览器才清掉对应 terminal surface 和
shell parser，并按协议 live-only 重连。

输入走当前 active `/pty` WS 的 binary frame，这是唯一写入路径。写入只针对
active PTY（其输出订阅已打开）；在流连接前的极短窗口内到达的输入会被丢弃，
不再 fallback 到 HTTP `pty.write`。浏览器侧仍会把 raw PTY bytes base64 包一层给
旧的 Workspace 分发路径消费（`apps/web/src/ws/client.ts`），同时把 shell-integration
OSC 流单独解析成结构化通知。

### 5.4 鉴权：`?token=<value>` 的存在理由

`new WebSocket(url)` 在浏览器里没法设 `Authorization` header，所以 motifd 在 `/events` 和 `/pty/<id>` 的握手处接受 `?token=...` query 参数，走和 Bearer header 同一个 token 比较函数（`crates/motif-server/src/auth.rs`）。HTTP `/rpc/*` 在 token 非空时继续用 Bearer header；空 token 表示连接到 no-auth motifd，HTTP 和 WS 都不附带 token。

Token 怎么到浏览器：**没有任何 cookie 或一次性令牌机制**，只有两条入口——

1. **登录页手填**：用户在 `apps/web/src/pages/Login.tsx` 填写 motifd 配置的 token 字符串；服务端关闭鉴权则留空。按"remember on this device"勾选与否分别存到 `localStorage` / `sessionStorage`（key `motif.token`，no-auth 模式会存空字符串）。
2. **URL 参数**：用 `…/?token=<value>` 打开页面时，`apps/web/src/store/store.ts` 的 `loadToken()` 优先取该参数，存入 `localStorage` 后用 `history.replaceState` 把它从地址栏抹掉（避免残留在浏览历史 / 书签 / 分享链接里）。menubar 的 "Open Web UI…" / "Open in Browser…"（`apps/menubar/src/tray.rs`，鉴权开启时）就靠这条把本机配置的 token 直接带进去，省掉手填。

两条入口都落到同一个 `motif.token`；下次访问时登录页的 effect 自动取出尝试重连。

> 注：iOS Native 容器有一条特殊路径——`window.motifNative.isNative === true` 时（`apps/web/src/pages/Login.tsx:5`）跳过 token 表单，由本地代理在 WS 升级时注入 Authorization。这是 native 壳的事情，浏览器场景与它无关。

---

## 6. v1.5 Web 不在范围内的事

- ❌ **浏览器内编辑文件**。"看"优先；点开文件只有只读预览（FilePreviewTab），无保存按钮。
- ❌ **协同编辑**。任何 OT / CRDT 路线一概不做，与 v1 主线保持一致。
- ❌ **PWA / 离线 / push 通知**。响应式做到能用即可。
- ❌ **浏览器内启动 `$EDITOR`**。浏览器没有可继承的本地终端。
- ❌ **浏览器侧分屏 / 终端复用**。多 PTY tab 切换够用，分屏交给 TUI / iOS。
- ❌ **多用户 / SSO / 分享链接**。沿用单用户模型。

---

## 7. 与其它文档的关系

- [`prd.md`](./prd.md) §3 / §4：整体架构与功能基线。
- [`rpc.md`](./rpc.md)：HTTP `/rpc/*` 方法清单与 WS 事件 schema——浏览器和 TUI 共用。
- [`shell-integration.md`](./shell-integration.md)：shell-integration OSC 标记。前端 `apps/web/src/shellIntegration.ts` 在浏览器侧重新实现了与 TUI 同语义的 block 状态机。
