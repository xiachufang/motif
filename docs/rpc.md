# Motif RPC 协议

JSON-RPC 2.0 形状的 HTTP + WebSocket 三通道协议。本文档是 wire-level 唯一权威；
shell-integration OSC 协议见 `shell-integration.md`。

类型权威源是 `crates/motif-proto/src/`；如果文档和代码不一致，以代码为准。

---

## 1. Transport

### 1.1 端点

`motifd` 把控制面、结构化事件流、PTY 字节流拆成三条独立通道。所有路由集中在
`crates/motif-server/src/ws.rs::router`：

| 路径 | 方法 | 方向 | 用途 |
| --- | --- | --- | --- |
| `/rpc/{method}` | HTTP POST | 客户端 → 服务端 | 所有 JSON-RPC 方法的请求 / 响应 |
| `/events` | WS GET | 服务端 → 客户端 | 结构化事件推送（JSON-RPC Notification 或 msgpack） |
| `/pty/{pty_id}` | WS GET | 双向 | PTY 主端字节流：上行 stdin 始终 raw；下行默认 raw，客户端可 opt-in framed zlib |
| `/`、`/assets/{*p}`、SPA fallback | HTTP GET | — | 内嵌 web UI 静态资源（`crates/motif-server/src/embed.rs`） |

### 1.2 鉴权

所有四类入口都先过 `TokenStore`（`crates/motif-server/src/auth.rs`）。配置了
token 时，`TokenStore` 做常时间 Bearer 比对。现在网络监听的 bearer 由配对 psk
派生（`rzv::derive_bearer`，写进 `motif://pair` 链接），客户端从 psk 派生同一个
bearer 发送；loopback/embed/tailscale-only 无 psk 时 `TokenStore::Disabled` 接受
请求。鉴权失败：

- `/rpc/*`：HTTP 401，body 是 `missing or invalid Bearer token`。
- `/events`、`/pty/<id>`：同样 HTTP 401，连接不会升级到 WS。

`Authorization: Bearer <token>` 是默认通道。浏览器 WS 构造器没法附加自定义
头，所以 `/events` 和 `/pty/<id>` 在 token 非空时额外接受 `?token=<value>`
查询字符串（`auth.rs::verify_header_or_query`）。`/rpc/*` **不**支持
query-string token。

### 1.3 Session 绑定

控制面的 session 绑定状态（哪个 motif session、当前 client_id、待回放游标）
存在 `ConnRegistry`（`crates/motif-server/src/conn_registry.rs`）里，按服务
端分配的不透明 `session_id` 索引：

1. 客户端调 `POST /rpc/session.attach`，请求体只装参数。服务端返回 200，并在
   响应头 `X-Motif-Session: <session_id>` 里下发一个新铸的 id
   （`http_rpc.rs:42-130`）。
2. 后续所有需要会话上下文的 `/rpc/*` 请求都要把这个 id 在请求头
   `X-Motif-Session` 里回带；找不到对应 entry → `NotAttached` (HTTP 409)。
3. `/events?session=<sid>` 和 `/pty/<id>?session=<sid>` 用 query string 传同
   一个 `session_id`，必须对应一个**已 attach** 的 entry，否则返回 409。
4. `POST /rpc/session.detach` 总是清掉 registry entry，连同 entry 内的 motif
   session 绑定。WS 通道掉线只清各自的订阅，不动 registry。

### 1.4 帧格式

| 通道 | 入站 | 出站 |
| --- | --- | --- |
| `/rpc/<method>` | HTTP body = `params` JSON 对象（或空 → `null`）。JSON-RPC 信封由服务端合成 `{ jsonrpc, id: 0, method, params }`（`http_rpc.rs:62-81`）。 | 成功：`200 OK`，body 是裸 `result` JSON。失败：HTTP 4xx/5xx，body 是 JSON-RPC `error` 对象 `{ code, message, data? }`（`http_rpc.rs:319+`）。 |
| `/events` | 客户端 WS 帧一律忽略，仅用作存活信号。 | text 帧：JSON-RPC Notification `{ jsonrpc, method, params }`（无 `id`）。`?bin=1` 时改发 binary 帧，载荷是 msgpack 直接编码的 `Event` 枚举（adjacent-tagged，仍是 `{method, params}` 结构，参见 `ws.rs::encode_event`）。 |
| `/pty/<id>` | binary 帧 = 原始 stdin 字节，写到 PTY 主端。 | 默认 binary 帧 = master 输出原始字节；不包任何 envelope。客户端可带 `pty_frame=v1&pty_compress=zlib` opt-in framed mode；若第一帧 Text meta 确认，后续每个服务端 → 客户端 Binary frame 都以 1 字节 flags 开头（bit0=zlib 压缩，bits1-7 保留为 0），payload 解码后才是 PTY bytes。Replay/live 同一规则，close code 见 §1.6。 |

不存在 batch / 数组形式：一次请求对应一个对象。`id` 字段在 HTTP 路径上由服务端
固定填 0，客户端不关心（HTTP 用 socket 自然对齐请求-响应）。

### 1.5 错误响应（HTTP）

`/rpc/*` 把内部 `RpcError` 映射到 HTTP 状态码（`http_rpc.rs:319+`）：

| ErrorCode | HTTP | 说明 |
| --- | --- | --- |
| `-32600` Invalid Request | 400 | |
| `-32601` Method Not Found | 404 | |
| `-32602` Invalid Params | 400 | |
| `-32700` Parse Error | 400 | |
| `AuthRequired` | 401 | 一般已被握手期 401 拦截，到这里属兜底 |
| `PathEscape` | 403 | |
| `SessionNotFound` | 404 | |
| `PtyNotFound` | 404 | |
| `NotAttached` | 409 | 包括 `X-Motif-Session` 缺失或失效 |
| `AlreadyExists` | 409 | |
| `FileTooLarge` | 413 | |
| 其他（含 `Conflict`、`NotAGitRepo`、`PtyLimitReached`、`BlockNotFound`、`Internal`） | 500 | 当前未单独映射；body 仍是 JSON-RPC error 对象，业务码以 `code` 字段为准 |

### 1.6 顺序、回放、心跳

- **事件序号**：服务端为每条 `Event` 分配单调递增 `seq`，存在 session 级
  ring buffer。容量 4096 条（`session/mod.rs:21`，常量 `RING_CAPACITY`）。
- **事件回放**：客户端连 `/events` 时带 `?since=<seq>`，服务端用
  `replay_since(after)`（`session/mod.rs:170`）把所有 `seq > since` 的事件按
  原顺序原样发出，再切换到 live 订阅。`since=0` 等价"把 ring 里有的全给我"。
  ring 已经覆盖了 since 之后的窗口时不再回退连接 — 客户端拿到的就是当前残
  存的快照，仍按总顺序追加，应做幂等处理。
- **PTY 回放**：`/pty/<id>?since=<bytes>` 走的是字节游标，不是事件 seq。每
  个 PTY 维护 2 MB 字节环（`pty.rs::RING_BYTES`）和一份 headless VT 状态。
  `since` 可省略：
  - `since == total` → 不回放直接进 live。
  - `origin <= since < total` → 默认推送 ring 内 raw delta `[since,total)`；若
    delta 很大且当前 VT snapshot 更小，则改推送 snapshot。Replay 按 64 KiB 左右
    拆成多个 Binary frame。
  - **省略 `since`**、`since < origin`、`since > total` → 不关闭连接；服务端推送
    当前 screen + scrollback 的 VT snapshot，然后进 live。
  - Replay slice 与 live receiver 在同一个 emulator 线程里原子取得，因此 replay
    和 live 边界不漏字节、不重复字节。
- **Meta 帧**：每个（非关闭）`/pty/<id>` 连接的**第一帧**是一个 WebSocket
  **Text** 帧。legacy mode 是 `{"since":<offset>}`；framed mode 是
  `{"since":<offset>,"pty_frame":"v1","pty_compress":"zlib"}`。`offset` 是
  紧随其后的 replay 第一个**解码后 PTY byte**的绝对字节偏移；snapshot 是合成
  PTY bytes，服务端选择 `offset = total - snapshot.len()`，让客户端按解码后
  byte 数累加后正好落到 live 起点 `total`。其余数据帧一律是 Binary，客户端按
  帧类型区分。
- **Framed PTY output**：只有客户端同时请求 `pty_frame=v1&pty_compress=zlib`
  且 meta 确认时启用。每个服务端 → 客户端 Binary frame：
  ```text
  u8 flags      bit0=compressed(zlib), bits1-7 reserved=0
  bytes payload raw PTY bytes or zlib-compressed PTY bytes
  ```
  `flags & 1 == 0` 时 payload 直接喂终端；`flags & 1 == 1` 时先 zlib decode。
  客户端 cursor 按**解码后**喂给 terminal/parser 的 PTY byte 数推进，不按 wire
  payload 长度推进。空 frame、保留 bit 非 0、zlib 解码失败都是协议错误。客户端
  → 服务端 stdin Binary frame 始终是 raw bytes，没有 1 字节 header。
- **4011/4012 恢复**：冷连接、截断 cursor、过新的 cursor 当前都走 snapshot
  fallback，不再用 4011/4012 关闭；`4011` 仍用于 live subscriber lagged。客户端
  仍应兼容 `4011` / `4012`，收到后清空本地 terminal/parser 增量状态，**不带
  `since`** 重连，再通过 meta 帧重新得到精确 cursor。
- **Lag 处理**：`/pty/<id>` 转发任务若被 broadcast 丢包（subscriber lagged）
  也会触发 `4011`，让客户端从当前 total 重新对齐。
- **心跳**：`/events` 与 `/pty/<id>` 共用一组节奏（`ws.rs:45-52`）：
  - 服务端每 20s 发一次 `Ping`。
  - 任意类型帧 45s 内未到 → 服务端发 `Close` 主动断连。
  - 心跳 tick 粒度 10s。

---

### 1.7 Client 接入流程

推荐客户端把 `session` 状态、结构化事件和 PTY bytes 分开处理：

1. **准备 transport**：直连、SSH、Tailscale、WSL 都只负责得到一个可访问 motifd
   的 `host:port`。SSH 和 WSL 可以先 bootstrap 目标环境中的 motifd；WSL 随后走
   localhost，SSH 则建立 local forward。Tailscale 客户端在首次连接前应先确认 tsnet 已
   `.running`，并可用一次短 TCP dial 或 `/ping` 预热到目标 peer 的路径，避免
   冷启动时首个 URLSession / WS 探测抢跑失败。
2. **探测服务**：可先 `GET /ping`。它不需要鉴权，用于确认目标确实是 motifd
   以及版本号。探测失败但属于 transient 网络错误时，客户端应在同一次连接流程
   内短延迟重试一次，再向用户显示失败。
3. **列出或创建 session**：未进入工作区前可调用 `session.list` /
   `session.create`。这些方法不要求 `X-Motif-Session`。
4. **attach**：调用 `POST /rpc/session.attach`，可带上本地保存的 `last_seq`
   作为重连提示。成功后必须保存响应头 `X-Motif-Session`，并用响应体里的
   `ptys`、`views`、`active_view`、`clients` 作为当前 UI 快照。
5. **打开 `/events`**：`GET /events?session=<sid>&since=<seq>`。最简单的
   做法是使用 `session.attach` 返回的 `last_seq`，因为 attach 响应已经给了
   当前快照；之后所有 `seq > last_seq` 的事件从 WS 进入。若客户端选择用更早
   的本地 `last_seq` 做事件级回放，也要对 attach 快照已覆盖的事件做幂等处理。
6. **按 PTY 订阅 bytes**：每个 PTY 保存一个本地 byte cursor 和 shell parser
   状态，按需打开 `GET /pty/<id>?session=<sid>&since=<cursor>`。新客户端推荐
   同时带 `pty_frame=v1&pty_compress=zlib`；只有 meta 确认后才按 framed zlib
   解码，否则按 legacy raw stream 处理。`/pty` 是纯传输,
   不再认领 primary——primary 由 `view.open` / `view.activate` 决定:谁的 active
   view 是该 PTY 且在前台/焦点(客户端转前台/获得焦点时重新 `view.activate` 当前
   view),谁就是 primary。打开一条 `/pty` 流**不**认领 primary,所以同一 session
   的多条 `/pty/<id>` 流可以并存(服务端每个 PTY 用 broadcast 扇出,见 §1.6)。
   客户端有两种订阅策略:
   - **单活跃(省电/省流量)**:只有当前 active terminal tab 打开 `/pty`,切到非
     终端 tab 或另一个 PTY 时关闭旧 `/pty` WS,但保留本地 terminal surface、
     cursor 和 parser 状态;切回时按 §7 catch-up。
   - **后台常连**:为多个/全部 PTY 同时保持 `/pty` 流,让非活跃 tab 的 surface
     在后台继续推进(off-screen 不渲染,但 VT 状态实时更新),切回即最新。
   iOS client 用「Keep background tabs live」设置在两者间切换,**默认后台常连**。
7. **server buffer catch-up**：重新激活某 PTY 时，用保存的 cursor 连接同一个
   `/pty` endpoint。服务端会回放 raw delta 或 VT snapshot，再切到 live。客户端
   把 replay 和 live 都喂给同一个 terminal surface；若启用了 framed mode，先按
   每帧 flags 解码，再按解码后的 PTY byte 数推进 cursor。
8. **输入与 resize**：PTY 的 stdin 走 `/pty` binary frame，这是唯一写入路径。
   写入只针对 active PTY（其 `/pty` WS 已打开）；在流连接前的极短窗口内到达的输入
   会被丢弃，而不是另起一条 HTTP 调用。终端尺寸变化继续走 `pty.resize`。
9. **4011 / 4012**：当前服务端对冷/截断/过新 cursor 会直接返回 VT snapshot；
   `4011` 主要表示 live subscriber lagged。客户端收到 `/pty` close `4011` 或
   `4012` 时，仍应丢弃该 PTY 的 terminal surface / shell parser 增量状态，然后
   不带 `since` 重新连接，用 snapshot 重新对齐。

这套流程让 server 成为历史 bytes 的唯一缓存点。客户端只保留展示需要的 terminal
surface、byte cursor 和 shell parser 状态。inactive tab 是否占用 live 订阅由订阅
策略决定(见步骤 6):单活跃模式下不占用、切回时用 `/pty/<id>?since=<cursor>` 补
齐;后台常连模式下保持订阅、随时最新。

---

## 2. 概念模型

- **Session**：服务端持久态。一份 workdir、一组 PTY、view tab 列表、事件 ring
  buffer。`session.create` 建出来，`session.destroy` 销毁，**寿命独立于任何
  连接**。类比 tmux session。
- **Client**：瞬时态。一个 `ConnRegistry` entry：拥有一个 `session_id` 句
  柄、一个 `client_id`、可选的"已 attach 到的 motif session 名"。同一 motif
  session 可被多 client 同时 attach，状态镜像。`session.detach` 或对应
  `session_id` 被清理即解绑。类比 `tmux attach` 进来的终端。
- **PTY**：session 拥有的 shell 进程 + 伪终端对，由 `pty.create` 创建。
- **Block**：一次命令的生命周期（shell-integration OSC 边界划分），分三段
  字节：prompt / command / output。服务端**不**追踪 block 状态，只透传 PTY
  字节；客户端解析 OSC 自行划分。类型在 `motif-proto/src/pty.rs` 仍保留供
  客户端使用，但**没有任何 RPC 暴露它们**。详见 §6 与 `shell-integration.md`。
- **View**：一个 tab 抽象，可以是 PTY、文件预览、diff 或图像。session 维护
  有序 view 列表 + 单一 active id，所有 client 镜像。

---

## 3. 公共类型

| 名字 | Rust 别名 | 形状 | 说明 |
| --- | --- | --- | --- |
| `SessionId` | `String` | ULID（26 字符 Crockford base32） | 会话标识 |
| `ClientId` | `String` | ULID | 已 attach 客户端标识 |
| `PtyId` | `String` | 形如 `"sh-1"` | 服务器分配的 PTY 标识 |
| `ViewId` | `String` | ULID | tab/view 标识 |
| `BlockId` | `String` | ULID | 一次命令生命周期的客户端本地标识（服务端不分配，仅作为客户端之间共享 schema 的字段类型） |
| `Seq` | `u64` | 单调递增 | 事件序号 |
| `UnixMs` | `u64` | unix epoch 毫秒 | 时间戳 |
| `Sha256Hex` | `String` | 64 字符小写 hex | SHA-256 摘要 |

---

## 4. 错误码

JSON-RPC 保留 `-32700..-32000`。motif 在保留区里定义自己的码
（`crates/motif-proto/src/error.rs`）。

| Code | 名字 | 触发 |
| --- | --- | --- |
| `-32700` | parse error | 帧不是合法 JSON |
| `-32600` | invalid request | JSON 合法但不是合法 JSON-RPC 帧 |
| `-32601` | method not found | 方法名未注册 |
| `-32602` | invalid params | 参数解析失败 |
| `-32603` | internal | 兜底内部错误（区别于 `Internal = -32099`） |
| `-32001` | `AuthRequired` | 当前连接未通过鉴权（rare：握手期已拦截） |
| `-32002` | `PathEscape` | `fs.*` 路径越出 session workdir |
| `-32003` | `FileTooLarge` | `fs.read` 超出 `max_bytes` |
| `-32004` | `Conflict` | `fs.write` 检查 `expected_sha256` 不匹配 |
| `-32005` | `NotAGitRepo` | `git.*` 在非仓库里调用 |
| `-32006` | `PtyNotFound` | `pty.resize/kill` 给了未知 pty_id |
| `-32007` | `SessionNotFound` | `session.attach/destroy` 找不到会话 |
| `-32008` | `AlreadyExists` | `session.create` 重名 |
| `-32009` | `NotAttached` | 需要 attach 状态的方法在未 attach 的 conn 上调用（含 `X-Motif-Session` 缺失 / 过期） |
| `-32010` | `PtyLimitReached` | `pty.create` 超过 session 级 PTY 上限 |
| `-32016` | `BlockNotFound` | 保留码位；当前没有 RPC 触发它（block 解析在客户端） |
| `-32099` | `Internal` | 内部分类不下来的错误 |

`error.data` 是可选 `serde_json::Value`，目前未约定结构，仅做诊断用途。

---

## 5. 方法

按命名空间分组。所有方法都是 client → server，走 `POST /rpc/<method>`。除
`session.list/create/destroy/attach` 与 `device.*`（全局，无需 attach）外，
其他方法都要求 `X-Motif-Session` 头对应的 entry 已经成功 attach 到一个 motif
session（否则返回 `NotAttached` 即 HTTP 409）。

dispatch 表见 `crates/motif-server/src/rpc.rs`：`dispatch_mut` 处理
`session.attach`/`session.detach`，其他全部进 `dispatch_concurrent`。

### 5.1 `session.*`

#### `session.list`

列出 motifd 上已存在的所有 session。

- **params**: `{}`
- **result**: `{ "sessions": SessionInfo[] }`

`SessionInfo`：

```jsonc
{
  "id":           "<SessionId>",
  "name":         "<string>",
  "workdir":      "<absolute path>",
  "created_at":   <UnixMs>,
  "client_count": <u32>
}
```

#### `session.create`

新建 session。

- **params**: `{ "name": "<string>", "workdir": "<path>" }`
- **result**: `{ "session": SessionInfo }`
- **errors**: `AlreadyExists`

#### `session.attach`

把当前 conn 绑定到一个 session。所有 `/events`、`/pty/<id>` 通道、以及 `pty.*`
/ `view.*` / `fs.*` / `git.*` 方法都要求先 attach。attach 之后服务器会广播
`client.joined` 给同 session 的其他客户端。

请求头：可选 `X-Motif-Session`。若带且对应的 entry 仍存活，会复用同一
`client_id`（重连场景）；否则服务端铸新 entry。

响应头：`X-Motif-Session: <session_id>`，客户端必须保存并在后续所有 `/rpc/*`
请求里回带，同时作为 `/events?session=` / `/pty/<id>?session=` 的 query。

- **params**:

  ```jsonc
  {
    "name":     "<string>",
    "last_seq": <Seq>,        // 可选：希望从 last_seq+1 开始回放事件；实际回放由 /events?since= 触发
    "term_fg":  "<string>",   // 可选：客户端终端 OSC 10/11 颜色（rgb 部分），
    "term_bg":  "<string>",   //   例如 "e6e6/e6e6/e6e6"。提供后服务器代答 OSC 10/11
    "theme":    "light"|"dark" // 可选：本端 resolved 主题。聚焦/前台的驱动客户端
                               //   的取值成为 session 级主题，广播给所有客户端
  }
  ```

- **result**:

  ```jsonc
  {
    "session":     SessionInfo,
    "client_id":   "<ClientId>",
    "clients":     ClientInfo[],     // 当前已 attach 的其他客户端
    "ptys":        PtyInfo[],
    "views":       ViewInfo[],
    "active_view": "<ViewId>" | null,
    "last_seq":    <Seq>,            // attach 时的事件高水位
    "theme":       "light"|"dark"    // 可选：session 当前生效主题，客户端据此渲染整个 UI
  }
  ```

- **errors**: `SessionNotFound`

`ClientInfo`：`{ "id": "<ClientId>", "since": <UnixMs> }`

#### `session.detach`

显式离开 session 并清除 registry entry。同 motif session 的其他客户端收到
`client.left`。无论成功失败，对应 `session_id` 在 registry 中都会被移除
（`http_rpc.rs:262-310`），后续若再用同一 id 请求会拿到 `NotAttached`。

- **params**: `{}`
- **result**: `{}`

#### `session.destroy`

销毁一个 session（杀掉所有 PTY、断开所有 attach 客户端）。

- **params**: `{ "name": "<string>" }`
- **result**: `{}`
- **errors**: `SessionNotFound`

---

### 5.2 `pty.*`

#### `pty.create`

创建 PTY；服务器分配 `id` 并广播 `pty.created`。

- **params**:

  ```jsonc
  {
    "cmd":  "<string>" | null,         // null → 默认 shell
    "cwd":  "<path>"   | null,         // null → session.workdir
    "env":  [["KEY", "VAL"], ...],
    "cols": <u16>,
    "rows": <u16>
  }
  ```

- **result**: `{ "info": PtyInfo }`
- **errors**: `PtyLimitReached`

`PtyInfo`：

```jsonc
{
  "id":         "<PtyId>",
  "cmd":        "<string>",
  "cwd":        "<path>",          // 服务端从 shell-integration OSC 7 追踪的 live cwd
                                   // （seed=spawn cwd），冷连接据此恢复 cd 后的目录
  "cols":       <u16>,
  "rows":       <u16>,
  "alive":      <bool>,
  "created_at": <UnixMs>,
  "running_command": "<string>" | null  // 服务端从 shell-integration OSC 标记追踪的
                                         // 当前执行命令；prompt 处或无 shell 集成时为 null。
                                         // 冷连接据此恢复正在跑的命令
}
```

#### `pty.list`

- **params**: `{}`
- **result**: `{ "ptys": PtyInfo[] }`

> PTY 输入（用户键盘）不是 RPC：直接发 `/pty/<id>` 的 binary frame（见 §3 步骤 8）。

#### `pty.resize`

调整 PTY 视口大小；服务器广播 `pty.resize` 事件。

- **params**: `{ "pty_id": "<PtyId>", "cols": <u16>, "rows": <u16> }`
- **result**: `{}`
- **errors**: `PtyNotFound`

#### `pty.kill`

发 SIGHUP（最终触发 `pty.exited`）。

- **params**: `{ "pty_id": "<PtyId>" }`
- **result**: `{}`
- **errors**: `PtyNotFound`

> 服务端不暴露 block 枚举 / 回放 RPC。block 的划分、缓存、回放由客户端
> 基于 `/pty/<id>` 解码后的 PTY 字节流完成；详见 §6 与 `shell-integration.md`。

---

### 5.3 `view.*`

Tab 抽象：session 维护一个有序 view 列表 + 单一 active view id。所有客户端镜像
同样状态。

`ViewSpec`（由 `kind` 标签判别）：

```jsonc
{ "kind": "pty",     "pty_id": "<PtyId>" }
{ "kind": "preview", "path":   "<string>" }
{ "kind": "diff",    "staged": <bool>, "path": "<string>" | null }
{ "kind": "image",   "path":   "<string>" }
```

`ViewInfo`：`{ "id": "<ViewId>", "spec": ViewSpec, "created_at": <UnixMs> }`

#### `view.open`

- **params**:

  ```jsonc
  {
    "spec":     ViewSpec,
    "activate": <bool>    // 默认 true：立即把它设为 active
  }
  ```

- **result**: `{ "view": ViewInfo }`
- **events**: `view.opened`，必要时 `view.active_changed`

#### `view.close`

- **params**: `{ "view_id": "<ViewId>" }`
- **result**: `{}`
- **events**: `view.closed`

#### `view.activate`

- **params**: `{ "view_id": "<ViewId>" | null }`（null = 没有 active view）
- **result**: `{}`
- **events**: `view.active_changed`

#### `view.move`

把单个 view 重排到 `to_index`，越界自动 clamp。

- **params**: `{ "view_id": "<ViewId>", "to_index": <usize> }`
- **result**: `{}`
- **events**: `view.moved`（载荷是 reorder 后完整顺序）

---

### 5.4 `fs.*`

所有 `fs.*` 路径相对 session.workdir；越出 workdir 返回 `PathEscape`。

#### `fs.tree`

- **params**:

  ```jsonc
  {
    "path":        "<string>",
    "depth":       <u32>,         // 默认 1
    "show_hidden": <bool>         // 默认 false
  }
  ```

- **result**: `{ "path": "<string>", "entries": TreeEntry[] }`

`TreeEntry`：

```jsonc
{
  "name":       "<string>",
  "type":       "file" | "dir" | "symlink",
  "size":       <u64>,
  "mtime":      <UnixMs>,
  "git_status": GitFileStatus | null
}
```

#### `fs.stat`

- **params**: `{ "path": "<string>" }`
- **result**: `{ "type": FileType, "size": <u64>, "mtime": <UnixMs>, "git_status": ... | null }`

#### `fs.read`

- **params**: `{ "path": "<string>", "max_bytes": <u64> }`（默认 10_000_000）
- **result**:

  ```jsonc
  {
    "content_b64": "<base64>",
    "sha256":      "<Sha256Hex>",
    "truncated":   <bool>,
    "binary":      <bool>,
    "mime":        "<string>" | null
  }
  ```

- **errors**: `FileTooLarge`

#### `fs.write`

- **params**:

  ```jsonc
  {
    "path":            "<string>",
    "content_b64":     "<base64>",
    "expected_sha256": "<Sha256Hex>" | null,   // 乐观锁
    "force":           <bool>                  // 默认 false：忽略 expected_sha256
  }
  ```

- **result**: `{ "sha256": "<Sha256Hex>" }`
- **errors**: `Conflict`

#### `fs.mkdir`

- **params**: `{ "path": "<string>" }` → **result**: `{}`

#### `fs.remove`

- **params**: `{ "path": "<string>" }` → **result**: `{}`

#### `fs.rename`

- **params**: `{ "from": "<string>", "to": "<string>" }` → **result**: `{}`

#### `fs.watch`

- **params**: `{}` → **result**: `{}`

订阅当前 attached session 的 `tree.changed` / `git.changed` 推送。两个事件
**默认不订阅** — 不调用 `fs.watch` 的客户端永远收不到。订阅是按 client 粒
度的（同 session 多个 client 各自决定）；调用幂等。

服务端在 session 内有人订阅时才会启动 OS 文件系统 watcher
（`crates/motif-server/src/fswatch.rs`）。最后一个订阅者 `fs.unwatch` 或
detach 时 watcher 自动销毁，零订阅期间 session 不为 fswatch 付任何 CPU。

注意：`fs.watch` 只影响**未来**的事件。已经在 ring 里的历史 `tree.changed` /
`git.changed` 仍受 client 当时是否订阅决定 — 想让重连后 replay 拿到这些，
先 `fs.watch` 再开 `/events` WS。

#### `fs.unwatch`

- **params**: `{}` → **result**: `{}`

取消当前 client 的 `tree.changed` / `git.changed` 订阅；幂等。若是 session
内最后一个订阅者，服务端关掉文件 watcher。

---

### 5.5 `git.*`

`cwd` 字段可选，默认用 session.workdir；客户端在文件树跟着活跃 PTY cwd 漂移
出 workdir 时传它。

`GitFileStatus` 枚举：`unmodified | modified | added | deleted | renamed | copied | untracked | ignored | conflicted`。

#### `git.status`

- **params**: `{ "cwd": "<path>" | null }`
- **result**:

  ```jsonc
  {
    "branch": "<string>" | null,
    "ahead":  <u32>,
    "behind": <u32>,
    "files":  [
      { "path": "<string>", "staged": GitFileStatus, "unstaged": GitFileStatus },
      ...
    ]
  }
  ```

- **errors**: `NotAGitRepo`

#### `git.diff`

- **params**: `{ "path": "<string>" | null, "staged": <bool>, "cwd": "<path>" | null }`
- **result**: `{ "patch": "<string>" }`（unified diff 文本）
- **errors**: `NotAGitRepo`

#### `git.diffSummary`

- **params**: 同 `git.diff`
- **result**: `{ "files": [{ "path": "<string>", "additions": <u32>, "deletions": <u32> }, ...] }`

### 5.6 `device.*`

推送通知的设备注册（**全局方法，无需 attach**）。类型定义在
`crates/motif-proto/src/device.rs`，处理在 `rpc.rs::handle_device_*`，存储在
`devices.rs::DeviceStore`（**纯内存**，不持久化——客户端每次连上都重新注册）。

端到端加密：`enc_key` 是设备本地生成的 32 字节 AES-256-GCM 密钥的 base64，
**只在客户端与本 motifd 之间共享**（走已鉴权的 RPC 通道）。motifd 用它加密
通知内容后交给 push relay，relay 只见密文（见 `relay.rs`、`motif-push-relay`）。

#### `device.register`

- **params**:
  ```jsonc
  {
    "device_token": "<hex>",          // APNs token，小写 hex
    "platform": "ios",
    "environment": "sandbox"|"production",  // 可选，relay 据此选 APNs host
    "enc_key": "<base64>",            // 32 字节 AES-256-GCM 密钥
    "app_version": "<string>",        // 可选
    "muted_sessions": ["<name>", ...] // 可选，见下
  }
  ```
- **result**: `{ "instance_id": "<string>" }` —— 本 motifd 进程的稳定 id，客户端
  持久化 `instance_id → server` 映射，使被点开的通知能路由回正确的服务器。
- 按 `device_token` upsert。`muted_sessions` 给出时是**权威全集**（客户端每次连接
  重放，以便 motifd 重启后恢复内存态）；缺省则保留既有静音集。

#### `device.unregister`

- **params**: `{ "device_token": "<hex>" }`
- **result**: `{}`
- 移除该 token（登出 / 移除服务器时调用），motifd 不再向其推送。

#### `device.set_session_muted`

- **params**: `{ "device_token": "<hex>", "session": "<name>", "muted": <bool>}`
- **result**: `{}`
- **按 (设备, 会话) 粒度**静音后台推送：`muted=true` 时该设备不再收到该会话的
  APNs 推送（`relay::push_to_all` 跳过静音了该会话的设备）。device 级开关仍是
  register/unregister；这是更细的、每会话的 opt-out。
- 客户端本地保存静音集为准，并在每次连接经 `device.register` 的 `muted_sessions`
  重放（内存态）。**live/前台 banner 的静音由客户端本地完成**（web 无后台推送，
  整套每会话静音都是客户端本地行为）。

---

## 6. Block 模型与 PTY 字节流

服务端**不**做 block 解析。`/pty/<id>` 通道语义上吐出来的是 PTY 主端字节流
（含 OSC 777 / OSC 633 marker；framed zlib 只改变 wire 传输形态），客户端自己
消费 marker、划分 block 段、维护本地 block 索引。

**为什么类型还留在 proto 里？** `crates/motif-proto/src/pty.rs` 仍导出
`BlockId`、`BlockSummary`、`OutputScope`、`ShellKind`、`ShellContext`、
`ListBlocksParams`、`ListBlocksResult`、`GetBlockOutputParams`、
`GetBlockOutputResult`。它们是客户端之间（以及客户端与未来服务端实现之间）
对"一个 block 长什么样"的共识 schema —— 例如客户端把 block summary 推给同
端 web view 时用同一份序列化。**当前没有任何 RPC 方法暴露这些类型**。

OSC 协议、各段语义和中断边界（重绘 / SIGINT 等）参见
[`shell-integration.md`](shell-integration.md)。下面只点几个 wire 层仍可见
的事实，方便对照：

| 段 | 区间 | 内容 |
| --- | --- | --- |
| `prompt`  | `777;A..777;B` | shell 渲染的 PS1 |
| `command` | `777;B..777;C` | 用户输入的回显（含 syntax highlight、autosuggest、PS2 续行） |
| `output`  | `777;C..777;D` | 命令的 stdout/stderr |
| `passthrough` | 以上之外 | bootstrap 前的 welcome / MOTD、`777;D` 后的 housekeeping、`MOTIF_SHELL_INTEGRATION=0` 的纯透传 PTY |

### 6.1 客户端职责

- 订阅 `/pty/<id>`，把字节同时喂给：
  - 本地 PTY 渲染器（xterm / Ghostty 等），保持终端实时画面。
  - OSC 解析器，识别 `777;A/B/C/D/E/P` 等 marker，更新本地 block 状态机。
- 维护本地 block 索引：`BlockId` 由客户端在看到首个 `777;A` 时分配（ULID
  本地生成即可，跨客户端不要求一致）。
- 中断 / 重绘的语义和 `shell-integration.md` 一致：服务端不参与，全部由
  客户端解释字节流。
- 想跨客户端共享 block 视图时（例如 web UI 把 block list 推给桌面伴侣），
  使用 §6 开头的 schema 自行串行化；不要假设服务端会代为持久化。

### 6.2 字节回放对齐

`/pty/<id>?since=<bytes>` 在语义上给的是单一连续 PTY 字节流；启用 framed zlib
时，客户端先把每个 Binary frame 解成 PTY bytes，再喂给 terminal / OSC parser。
本地 block 状态机只要从头跑一遍解析就能复刻：客户端只需要在它能控制的 `since`
游标处保证 OSC 解析状态完整。冷/截断/过新的 cursor 会由服务端返回 VT snapshot
重新对齐；`4011`（live lag）或兼容旧服务端的 `4012` 出现时，清状态机并不带
`since` 重连。

---

## 7. 服务器推送事件（Notification）

事件走 `/events` 通道。JSON 模式下每条事件是一个 JSON-RPC notification
（无 `id`）；msgpack 模式（`?bin=1`）下结构相同，只是 codec 不一样。所有事件
`params` 都包含 `seq: <Seq>`，下面省略不写。事件按 method 字符串区分。

类型定义在 `crates/motif-proto/src/event.rs`。共 **13 条** 事件,客户端按 method
字符串严格匹配——**未知 method 视为协议错误**(不再保留 Unknown fallback)。
shell-integration 派生通知（prompt / command / cwd / shell context 等）不在这里:
客户端从 `/pty/<id>` 字节流自己解析 OSC（见 §6 与 `shell-integration.md`）。

### 7.1 文件树 / Git

> **默认不投递**：这两条事件需要客户端先调 `fs.watch` 才会收到（详见
> §5.4）。session 内没人订阅时服务端连文件 watcher 都不起，事件本身也不会
> 进 ring。订阅状态按 client 粒度，detach 时自动清理。

- `tree.changed` — `{ paths: string[] }`，受影响的（相对 workdir 的）路径列
  表，`fs.tree` 应当 invalidate。
- `git.changed` — `{}`，HEAD/状态变化，客户端重新拉 `git.status`。

### 7.2 客户端

- `client.joined` — `{ client_id, since: UnixMs }`
- `client.left`   — `{ client_id }`

### 7.3 PTY 生命周期

- `pty.created` — `{ info: PtyInfo }`
- `pty.exited`  — `{ pty_id, exit_code: i32 | null }`
- `pty.resize`  — `{ pty_id, cols: u16, rows: u16 }`

PTY 输出字节、cwd 变化、shell-integration 事件**都不在这里**；订阅
`/pty/<id>` 自行处理。

### 7.4 Tab / view

- `view.opened`         — `{ view: ViewInfo }`
- `view.closed`         — `{ view_id }`
- `view.active_changed` — `{ view_id: <ViewId> | null }`
- `view.moved`          — `{ order: ViewId[] }`（重排后完整顺序）

### 7.5 Session 外观

- `session.theme_changed` — `{ theme: "light"|"dark" }`。session 级主题由聚焦/前台
  的「驱动」客户端经 `session.attach` 或 `session.set_palette` 的 `theme` 字段设定，
  变化时广播；所有客户端据此渲染整个 UI，使共享 session 外观一致、且 PTY 输出
  颜色与渲染背景匹配。`session.set_palette` 的 `term_fg`/`term_bg` 仍用于代答 shell
  的 OSC 10/11（`theme` 给客户端渲染，`term_*` 给 shell 探测，见 `shell-integration.md`）。

### 7.6 通知（notification）

- `notification` — `{ title, body, session_id?: string, kind }`。源自 Claude Code
  钩子（`Notification` / `Stop`），经本地 unix socket（0600，`hook_ingress.rs`）进入，
  广播给该会话所有 attach 的客户端做**前台/应用内 banner**（"live" 通道）。
  - `kind`: `"needs_input"`（Claude 需要输入/批准）或 `"finished"`（一轮结束）。
  - `title`: 有会话名时即**会话名**（多个 Claude 并行时用于区分）；否则回退到通用
    标题。
  - `body`: `Notification` 用 Claude Code 给的 `message`；`Stop` 用钩子自带的
    `last_assistant_message`（折成一行、截断 ~140 字），即 Claude 本轮最后说的话。
- 这是 live 通道。后台投递（iOS APNs）由 push relay 带外加密下发（见 §5.6、`relay.rs`），
  **不**经 `/events`。web 无后台推送，仅有此 live 通道 + 浏览器桌面通知。
- 每会话静音（§5.6 `device.set_session_muted`）：后台推送在服务端按 (设备,会话) 过滤；
  live banner 由客户端本地按会话静音抑制。
