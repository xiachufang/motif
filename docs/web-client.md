# Motif — Web Client（当前实现）

> 本文档描述 motif Web 前端的**当前实现**形态。它已经从早期规划的"独立 `motif-web` 桥接二进制 + `motifd` 不变"演进为更简单的方案：Web SPA 直接由 `motifd` 进程同源 serve，浏览器走与 `motif-tui` 完全相同的协议端点。
>
> 阅读前提：已熟悉 [`prd.md`](./prd.md) §3（架构）、§4（核心功能），以及 [`rpc.md`](./rpc.md)（协议与端点）。

---

## 1. Context

Web 端最初是为了反向验证 v1 协议是否真的"client-agnostic"——浏览器对 WebSocket header、二进制数据的限制会暴露协议中不够通用的地方。除此之外它也兼做"瘦客户端"角色：手机 / 平板 / 浏览器内随时 attach 上一个远端 session 看进展，不需要装本地二进制。

实际落地比早期规划简单一档。原计划是新增独立的 `motif-web` 桥接进程，在浏览器和 `motifd` 之间做帧透明转发 + 鉴权翻译，让 `motifd` 对浏览器完全无感。后来发现：

- 浏览器特殊化的"翻译"实际上只剩一件事——`WebSocket` API 设不了自定义 header，于是用 `?token=<value>` query 参数走同一个 token 校验函数。这一点完全可以放进 `motifd` 自己的 axum router 里，不值得拆进程（见 `crates/motif-server/src/auth.rs:41` 的 `verify_header_or_query`）。
- `motifd` 已经在 axum 上提供 HTTP `/rpc/*` + WS `/events` + WS `/pty/<id>`，多挂两条静态资源路由 (`/`、`/assets/*`) 是零成本的事，`rust-embed` 把 `web/dist` 编译期塞进二进制，部署仍然是单文件。
- 不存在多 motifd 聚合的现实需求（v1 仍是单用户单实例），原本支撑"独立 bridge"的部署拓扑论据失效。

所以现在的产物是：**`motifd` 一个二进制，既是协议服务器又是 Web SPA 宿主**。`web/` 顶层目录是独立的前端项目，构建后被嵌入到 `motifd`。

---

## 2. Architecture

```
   Browser                                       motifd 二进制
   ┌──────────────────────────┐                  ┌────────────────────────────┐
   │ React SPA (web/dist)     │  ── HTTP ────►   │ GET /                       │
   │  - xterm.js              │  ── HTTP ────►   │ GET /assets/*  (rust-embed) │
   │  - diff2html             │                  │ ─────────────────────────── │
   │  - highlight.js          │  ── HTTP POST ►  │ /rpc/<method>  (Bearer hdr) │
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
- **没有 `motif-web` crate / 二进制**。早期文档里的桥接进程、"鉴权翻译层"、多 region motif-web 部署、`auth.login` 首消息握手等设计都已作废。

---

## 3. Source Layout

### 前端（顶层 `web/`，非 cargo crate）

```
web/
├─ package.json          React 19 + Vite 8 + TypeScript（见 web/package.json）
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

栈选型与早期规划的差异：
- 框架：**React 19**（不是 Solid，见 `web/package.json:19`）。
- 状态：**zustand**（不是 Solid store / Redux）。
- 高亮：**highlight.js**（不是 Shiki）。
- 终端：xterm.js（一致）。
- Diff：diff2html（一致）。
- 构建：Vite（一致）。

### 服务端（`crates/motif-server`）

```
crates/motif-server/
├─ build.rs              拷贝 ../../web/dist → static/，供 rust-embed 嵌入
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
pnpm --dir web build      # 在 web/ 下跑 tsc -b && vite build，产出 web/dist/
cargo build -p motif-server
  └─ build.rs
       1. 清空 crates/motif-server/static/
       2. 拷贝 web/dist/* → static/
       3. 若 web/dist 不存在，写一个占位 index.html，提示"先 pnpm build"
  └─ rust-embed 编译期把 static/ 嵌入 motifd 二进制
```

要点：

- **前端构建不会被 cargo 自动触发**。开发者要么手动 `pnpm --dir web build`，要么用 Vite dev server（见下面 4.1）。`build.rs` 只在 `web/dist` 已存在时拷贝，否则塞占位页面，不阻断 `cargo build`。
- 构建产物文件名固定（`assets/[name].js` 等，见 `web/vite.config.ts:33`）。motifd 给静态资源回 `Cache-Control: no-store`（`crates/motif-server/src/embed.rs:28`），所以不依赖 hash 文件名做 cache busting。
- `static/` 是 build.rs 生成物，gitignore；`web/dist/` 同理。
- `cargo:rerun-if-changed` 监听 `web/dist`、`web/index.html`、`web/src`（见 `build.rs:7-9`），所以前端重新构建后 `cargo build` 会重跑 build.rs 重打 static。

### 4.1 开发模式

跑 `pnpm --dir web dev` 起 Vite dev server（端口 5173），它把 `/rpc`、`/events`、`/pty` 反代到 `http://127.0.0.1:7777` 上的 motifd（见 `web/vite.config.ts:41`）。浏览器开 `http://localhost:5173` 即可热更新调前端，不需要重编 motifd。

要把 motifd 指到别处，设 `VITE_MOTIFD=http://host:port`（同样在 `vite.config.ts`）。

---

## 5. Transport

浏览器走的 RPC + 事件 + PTY 端点与 motif-tui 完全相同；详细协议见 [`rpc.md`](./rpc.md)。这里只列浏览器侧的几个差异点。

### 5.1 RPC

`POST /rpc/<method>`，body 是 JSON params。请求头需要：

```
Authorization: Bearer <token>
Content-Type: application/json
X-Motif-Session: <sid>      ← attach 之后所有请求都带上，server 回的 X-Motif-Session 提供
```

实现见 `web/src/ws/client.ts:178`（`httpCallRaw`）。

### 5.2 Events

`GET /events?session=<sid>&since=<seq>&token=<value>`，Upgrade 到 WS。客户端断线 → 指数退避重连（`web/src/ws/client.ts:238`，500ms 起，封顶 15s），重连成功后 Workspace 层用记到的 `last_seq` 重发 `session.attach` 做 replay。

### 5.3 PTY 字节流

每个 PTY 一条独立 WS：`GET /pty/<id>?session=<sid>&since=<seq>&primary=0|1&token=<value>`。和 `motif-tui` 一致地走 binary frames。浏览器侧 base64 包一层给老代码消费（`web/src/ws/client.ts:285`），同时把 shell-integration OSC 流单独解出来生成结构化通知。

### 5.4 鉴权：`?token=<value>` 的存在理由

`new WebSocket(url)` 在浏览器里没法设 `Authorization` header，所以 motifd 在 `/events` 和 `/pty/<id>` 的握手处接受 `?token=...` query 参数，走和 Bearer header 同一个 token 比较函数（`crates/motif-server/src/auth.rs:41`）。HTTP `/rpc/*` 继续要 Bearer header——浏览器在 fetch 里能设 header，没必要 query。

Token 怎么到浏览器：**没有任何 cookie 或一次性令牌机制**。用户在登录页 `web/src/pages/Login.tsx:88` 手动粘贴 motifd 配置的 token 字符串，按"remember on this device"勾选与否分别存到 `localStorage` / `sessionStorage`（key `motif.token`）。下次访问 `web/src/pages/Login.tsx:49` 的 effect 自动取出尝试重连。

> 注：iOS Native 容器有一条特殊路径——`window.motifNative.isNative === true` 时（`web/src/pages/Login.tsx:5`）跳过 token 表单，由本地代理在 WS 升级时注入 Authorization。这是 native 壳的事情，浏览器场景与它无关。

---

## 6. v1.5 Web 不在范围内的事

按当前实现的口径再校对一遍：

- ❌ **浏览器内编辑文件**。"看"优先；点开文件只有只读预览（FilePreviewTab），无保存按钮。
- ❌ **协同编辑**。任何 OT / CRDT 路线一概不做，与 v1 主线保持一致。
- ❌ **PWA / 离线 / push 通知**。响应式做到能用即可。
- ❌ **浏览器内启动 `$EDITOR`**。浏览器没有可继承的本地终端。
- ❌ **浏览器侧分屏 / 终端复用**。多 PTY tab 切换够用，分屏交给 TUI / iOS。
- ❌ **多用户 / SSO / 分享链接**。沿用单用户模型。
- ❌ **独立的 `motif-web` 桥接二进制**。曾在规划，已作废。
- ❌ **`/blob/<id>` 二进制传输端点**。早期文档中提到过，已删除，不再有这种东西。
- ❌ **legacy `/ws` 单一升级端点**。已被 `/rpc` + `/events` + `/pty/<id>` 拆分取代。

---

## 7. 与其它文档的关系

- [`prd.md`](./prd.md) §3 / §4：整体架构与功能基线。
- [`rpc.md`](./rpc.md)：HTTP `/rpc/*` 方法清单与 WS 事件 schema——浏览器和 TUI 共用。
- [`shell-integration.md`](./shell-integration.md)：shell-integration OSC 标记。前端 `web/src/shellIntegration.ts` 在浏览器侧重新实现了与 TUI 同语义的 block 状态机。
