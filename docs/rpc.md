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
| `/pty/{pty_id}` | WS GET | 双向 | PTY 主端 raw bytes：上行 stdin、下行输出 |
| `/`、`/assets/{*p}`、SPA fallback | HTTP GET | — | 内嵌 web UI 静态资源（`crates/motif-server/src/embed.rs`） |

### 1.2 鉴权

所有四类入口都先过 `TokenStore`（`crates/motif-server/src/auth.rs`）。配置了
token 时，`TokenStore` 做常时间 Bearer 比对；token 是 `motifd --token-file`
指向文件的整行字符串，空 token 文件一律拒绝启动。未配置 token 时，
`TokenStore::Disabled` 接受请求。鉴权失败：

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
| `/pty/<id>` | binary 帧 = 原始 stdin 字节，写到 PTY 主端。 | binary 帧 = master 输出原始字节；不包任何 envelope。Replay 也走单个 binary 帧。close code 见 §1.6。 |

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
  个 PTY 维护 2 MB 字节环（`pty.rs::RING_BYTES`）。状态码：
  - `since == total` → 不回放直接进 live。
  - `origin <= since < total` → 把 ring 内 `since..total` 当成一个 binary
    帧推下去，然后进 live。
  - `since < origin` → close `4011`（history truncated），客户端应清本地
    scrollback 并不带 since 重连。
  - `since > total` → close `4012`（stale cursor），同上。
- **Lag 处理**：`/pty/<id>` 转发任务若被 broadcast 丢包（subscriber lagged）
  也会触发 `4011`，让客户端从当前 total 重新对齐。
- **心跳**：`/events` 与 `/pty/<id>` 共用一组节奏（`ws.rs:45-52`）：
  - 服务端每 20s 发一次 `Ping`。
  - 任意类型帧 45s 内未到 → 服务端发 `Close` 主动断连。
  - 心跳 tick 粒度 10s。

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
| `-32006` | `PtyNotFound` | `pty.write/resize/kill` 给了未知 pty_id |
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
`session.list/create/destroy/attach` 外，其他方法都要求 `X-Motif-Session` 头
对应的 entry 已经成功 attach 到一个 motif session（否则返回 `NotAttached`
即 HTTP 409）。

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
    "term_bg":  "<string>"    //   例如 "e6e6/e6e6/e6e6"。提供后服务器代答 OSC 10/11
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
    "last_seq":    <Seq>             // attach 时的事件高水位
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
  "cwd":        "<path>",
  "cols":       <u16>,
  "rows":       <u16>,
  "alive":      <bool>,
  "created_at": <UnixMs>
}
```

#### `pty.list`

- **params**: `{}`
- **result**: `{ "ptys": PtyInfo[] }`

#### `pty.write`

把字节写到 PTY 主端（用户键盘输入）。

- **params**: `{ "pty_id": "<PtyId>", "data_b64": "<base64>" }`
- **result**: `{}`
- **errors**: `PtyNotFound`

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
> 基于 `/pty/<id>` 的原始字节流完成；详见 §6 与 `shell-integration.md`。

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

---

## 6. Block 模型与 PTY 字节流

服务端**不**做 block 解析。`/pty/<id>` 通道吐出来的就是 PTY 主端的原始字节流
（含 OSC 777 / OSC 633 marker），客户端自己消费 marker、划分 block 段、维护
本地 block 索引。

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

`/pty/<id>?since=<bytes>` 给的是单一连续字节流，所以本地 block 状态机只要从
头跑一遍解析就能复刻：客户端只需要在它能控制的 `since` 游标处保证 OSC 解析
状态完整（或干脆放弃增量、用 `since=0` 全量重跑）。close `4011` / `4012`
（§1.6）出现时就当作"scrollback 丢了"，清状态机重连。

---

## 7. 服务器推送事件（Notification）

事件走 `/events` 通道。JSON 模式下每条事件是一个 JSON-RPC notification
（无 `id`）；msgpack 模式（`?bin=1`）下结构相同，只是 codec 不一样。所有事件
`params` 都包含 `seq: <Seq>`，下面省略不写。事件按 method 字符串区分。

类型定义在 `crates/motif-proto/src/event.rs`。共 **11 条** 事件 + 一个
`Unknown` 前向兼容 fallback。shell-integration 派生通知（prompt /
command / cwd / shell context 等）不在这里：客户端从 `/pty/<id>` 字节流
自己解析 OSC（见 §6 与 `shell-integration.md`）。

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

### 7.5 前向兼容

事件 enum 用 `#[serde(other)]` 做 fallback：未知 method 不会让客户端 JSON
解析失败，但 `seq()` 返回 0，不要拿它去对总序。新增事件总是单调追加；不会修
改既有事件的字段含义。可选字段使用 `#[serde(default,
skip_serializing_if = "Option::is_none")]`，旧客户端忽略未知字段，新服务端
容忍缺字段。错误码只能新增，不能复用历史码位。
