# Motif RPC 协议

JSON-RPC 2.0 over WebSocket。本文档是 wire-level 唯一权威；shell-integration OSC
协议见 `shell-integration.md`，blob 通道见 `blob-transfer.md`。

类型权威源是 `crates/motif-proto/src/`；如果文档和代码不一致，以代码为准。

---

## 1. Transport

### 1.1 端点

`motifd` 暴露两个 HTTP/WebSocket 路径：

| 路径 | 方向 | 用途 |
| --- | --- | --- |
| `/ws` | 客户端 ↔ 服务端 | 控制平面：所有 RPC + 服务器推事件 |
| `/blob/<transfer_id>` | 客户端 ↔ 服务端 | 数据平面：单次 blob 上传/下载（见 `blob-transfer.md`） |

升级前必须通过 HTTP `Authorization: Bearer <token>` 头鉴权。token 是 `motifd
--token-file` 指向的文件中的整行字符串；空 token 一律拒绝。鉴权失败返回
HTTP 401，连接不会进入 WS 阶段。

### 1.2 帧格式

每个 WebSocket text 帧是一个 JSON-RPC 2.0 对象，UTF-8 编码：

- **Request**（C→S）：`{ "jsonrpc": "2.0", "id": <num>, "method": "...", "params": {...} }`
- **Response**（S→C）：`{ "jsonrpc": "2.0", "id": <num>, "result": {...} }`
  或 `{ "jsonrpc": "2.0", "id": <num>, "error": { "code": <int>, "message": "...", "data": ... } }`
- **Notification**（S→C，事件推送）：`{ "jsonrpc": "2.0", "method": "...", "params": {...} }`（无 `id`）

`id` 客户端使用单调递增 `u64`；服务器只回显，不解释。字符串 id 入站可以解析，
但服务器不会主动产生。

不支持 batch / 数组形式。一帧一对象。

### 1.3 顺序与回放

服务器对所有 `Notification` 维护一个全局单调递增的 `seq`。客户端在
`session.attach` 里可选传入 `last_seq`：服务器仍持有 `last_seq + 1` 起的事件
就原样回放，已被 ring buffer 淘汰则直接断连让客户端冷起。

每个事件的 `params` 里都带 `seq` 字段（除 `Unknown` fallback 外）。

---

## 2. 概念模型

- **Session**：服务端持久态。一份 workdir、一组 PTY、view tab 列表、事件 ring
  buffer。`session.create` 建出来，`session.destroy` 销毁，**寿命独立于任何
  连接**。类比 tmux session。
- **Client**：瞬时态。一条已通过 `session.attach` 绑定到某个 session 的 WS
  连接。同一 session 可被多 client 同时 attach，状态镜像。`session.detach`
  或断 WS 即解绑。类比 `tmux attach` 进来的终端。
- **PTY**：session 拥有的 shell 进程 + 伪终端对，由 `pty.create` 创建。
- **Block**：一次命令的生命周期（shell-integration OSC 边界划分），分三段字节：prompt /
  command / output。详见 §6。
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
| `BlockId` | `String` | ULID | 一次命令生命周期的标识；用 string 是为了规避 `ts-rs` 跨过 JS `Number` 精度 |
| `Seq` | `u64` | 单调递增 | 事件序号 |
| `UnixMs` | `u64` | unix epoch 毫秒 | 时间戳 |
| `Sha256Hex` | `String` | 64 字符小写 hex | SHA-256 摘要 |

---

## 4. 错误码

JSON-RPC 保留 `-32700..-32000`。motif 在保留区里定义自己的码。

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
| `-32009` | `NotAttached` | 需要 attach 状态的方法在未 attach 连接上调用 |
| `-32010` | `PtyLimitReached` | `pty.create` 超过 session 级 PTY 上限 |
| `-32011` | `BlobNotFound` | `fs.commitBlob/cancelBlob` 给了未知 transfer_id |
| `-32012` | `BlobExpired` | blob 通道已过 TTL |
| `-32013` | `BlobLimitReached` | 超出并发 blob 上限 |
| `-32014` | `BlobTooLarge` | blob 字节数超过声明的 `total_size` |
| `-32015` | `BlobChecksumMismatch` | 提交时 sha256 不一致 |
| `-32016` | `BlockNotFound` | `pty.get_block_output` 给的 block 已被 ring 淘汰或从未存在 |
| `-32099` | `Internal` | 内部分类不下来的错误 |

`error.data` 是可选 `serde_json::Value`，目前未约定结构，仅做诊断用途。

---

## 5. 方法

按命名空间分组。所有方法都是 client → server。除 `session.list/create/destroy`
外，其他方法都要求当前连接已经成功 attach 到一个 session（否则返回 `NotAttached`）。

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

把当前 WS 连接绑定到一个 session。所有事件推送和数据面方法都要求先 attach。
attach 之后服务器会广播 `client.joined` 给同 session 的其他客户端。

- **params**:

  ```jsonc
  {
    "name":     "<string>",
    "last_seq": <Seq>,        // 可选：希望从 last_seq+1 开始回放事件
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

显式离开 session（断 WS 也会触发）。同 session 其他客户端收到 `client.left`。

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

#### `pty.list_blocks`

枚举该 PTY 的已结束 block（按 ULID 时间逆序，新的在前）。供晚到客户端 backfill。

- **params**:

  ```jsonc
  {
    "pty_id": "<PtyId>",
    "before": "<BlockId>",   // 可选：返回 id < before 的 block。null = 最近 limit 个
    "limit":  <u32>
  }
  ```

- **result**: `{ "blocks": BlockSummary[] }`
- **errors**: `PtyNotFound`

`BlockSummary`：

```jsonc
{
  "id":                "<BlockId>",
  "cwd":               "<path>",
  "cmd":               "<string>",      // shell-integration 显式命令文本
  "started_at":        <UnixMs>,
  "finished_at":       <UnixMs> | null,
  "exit_code":         <i32>    | null,
  "prompt_size":       <u64>,
  "prompt_truncated":  <bool>,
  "command_size":      <u64>,
  "command_truncated": <bool>,
  "output_size":       <u64>,
  "output_truncated":  <bool>
}
```

#### `pty.get_block_output`

拿单个已结束 block 的三段原始字节流。三段都含原始 ANSI，由客户端用同一份
xterm 渲染策略复现。

- **params**: `{ "pty_id": "<PtyId>", "block_id": "<BlockId>" }`
- **result**:

  ```jsonc
  {
    "prompt_b64":        "<base64>",
    "prompt_truncated":  <bool>,
    "command_b64":       "<base64>",
    "command_truncated": <bool>,
    "output_b64":        "<base64>",
    "output_truncated":  <bool>
  }
  ```

- **errors**: `PtyNotFound`、`BlockNotFound`

> 单段 block 字节在内存里上限 1 MiB（超出时尾部丢弃，对应 `*_truncated=true`）。
> 整个 PTY 的 block ring 默认 1000 entries / 50 MiB，先到先淘汰。

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

#### `fs.openBlob` / `fs.commitBlob` / `fs.cancelBlob`

控制平面三件套，配合 `/blob/<transfer_id>` 数据面 WebSocket 使用。语义见
`blob-transfer.md`，下面只罗列 wire 形状。

- `fs.openBlob` params:

  ```jsonc
  {
    "path":            "<string>",
    "mode":            "read" | "write",
    "expected_sha256": "<Sha256Hex>" | null,
    "total_size":      <u64> | null
  }
  ```

  result:

  ```jsonc
  {
    "transfer_id": "<string>",
    "blob_path":   "<string>",
    "expires_at":  <UnixMs>,
    "size":        <u64>     | null,
    "mime":        "<string>" | null,
    "sha256":      "<Sha256Hex>" | null
  }
  ```

- `fs.commitBlob` params: `{ "transfer_id": "<string>" }` → result: `{ "sha256": "<Sha256Hex>" }`
- `fs.cancelBlob` params: `{ "transfer_id": "<string>" }` → result: `{}`

errors: `BlobNotFound`、`BlobExpired`、`BlobLimitReached`、`BlobTooLarge`、
`BlobChecksumMismatch`。

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

**每个 prompt cycle 就是一个 block**。block_id 在 `777;A`（prompt 开始）时
分配，从那一刻起所有该 PTY 的 `pty.output` 字节都带这个 id。block 有三个连续
段，由 Motif 私有 OSC 777 边界划分：

| 段 | 区间 | 内容 |
| --- | --- | --- |
| `prompt`  | `777;A..777;B` | shell 渲染的 PS1 |
| `command` | `777;B..777;C` | 用户输入的回显（含 syntax highlight、autosuggest、PS2 续行） |
| `output`  | `777;C..777;D` | 命令的 stdout/stderr |

block 生命周期：

- **777;A** → 分配新 `block_id`，进入 `prompt` 段。`pty.prompt_started` 携带
  这个 id。
- **777;B** → 进入 `command` 段。`pty.prompt_ended` 携带同一 id。
- **777;E** → 暂存显式命令文本。
- **777;C** → 进入 `output` 段，且 block 此刻"承诺要 commit"。
  `pty.command_started` 携带同一 id 加显式命令文本。
- **777;D** → block 完成，commit 进 server 的 BlockStore（`pty.list_blocks` /
  `pty.get_block_output` 可见）。`pty.command_finished` 携带同一 id 和退出码。

如果 prompt cycle 在 `777;C` 之前就被打断（用户 Ctrl-C / 空 Enter / shell 重
绘 prompt），block 会以下面两种方式之一收尾：

| 中断 | 状态转移 | BlockStore | 备注 |
| --- | --- | --- | --- |
| 重绘 prompt：`AtPrompt → 777;A` 或 `Composing → 777;A`（Ctrl-C 取消编辑、空 Enter、fish repaint） | block_id **不变**,prompt 段(及 command 段,如有)重置 | 不入库 | `pty.prompt_started` 用同一 id 触发,标记重绘边界。**不**合成 `CommandStarted` / `CommandFinished`,UI 静默 |
| `Running → 777;A`（命令被 SIGINT 杀掉，shell 跳过 `777;D`） | 旧 id 强制 finalize，`exit_code: null`；新 id 进 AtPrompt | 入库 | `pty.command_finished.exit_code` 为 null 表示非正常结束 |

`OutputScope` 是 `pty.output` 事件里的字符串枚举，标识当前字节属于 block 的
哪一段：

```
"passthrough" | "prompt" | "command" | "output"
```

- `prompt` / `command` / `output` 对应 `777;A..777;B` /
  `777;B..777;C` / `777;C..777;D` 三个区段；这三种 scope 时 `block_id`
  非空，按 (block_id, scope) 路由到对应 block 渲染器。
- `passthrough` 表示字节不属于任何 block —— spawn 后到首次 `777;A` 之间
  的 fish welcome banner / SSH MOTD,`777;D` 到下一次 `777;A` 之间的
  housekeeping(改窗口标题、bracketed paste 模式开关等),以及
  `MOTIF_SHELL_INTEGRATION=0` / 不支持 shell 的纯透明 PTY。`block_id`
  在这些字节上始终是 `null`,客户端按"普通终端流"渲染,不喂任何 BlockTerm
  buffer。

### 6.1 `Block.cmd` vs `command` 段

`BlockSummary.cmd` 来自 `777;E` 显式命令 marker，是 shell 解析后的**逻辑**命令文本
（干净 UTF-8 字符串）；`command` 段是用户**实际看到**的输入回显（含被删了又
重输的过程、ANSI 颜色、PS2 续行符）。两者不冗余：

- 渲染"用户当时看到的输入行" → 用 `command` 段。
- 复制 / 重跑 / 搜索匹配 → 用 `cmd` 字段。

### 6.2 Live 与 backfill 的对齐

每个已 commit 的 block 在 server BlockStore 里以 `prompt + command + output`
三段原始字节的形式存活。晚到 client 用 `pty.list_blocks` 拉元数据 + `pty.
get_block_output` 拉三段字节，按顺序喂同一个 headless xterm 序列化，能复刻出
与"实时观看"完全一致的 HTML 渲染。未 commit 的 block（重绘 / 中途打断）不入
库，只在 live 流里出现。

---

## 7. 服务器推送事件（Notification）

每个事件都是 JSON-RPC notification（无 `id`）。所有事件 `params` 都包含
`seq: <Seq>`，下面省略不写。事件按 method 字符串区分。

### 7.1 文件树 / Git

- `tree.changed` — `{ paths: string[] }`，受影响的（绝对）路径列表，`fs.tree`
  应当 invalidate。
- `git.changed` — `{}`，HEAD/状态变化，客户端重新拉 `git.status`。

### 7.2 客户端

- `client.joined` — `{ client_id, since: UnixMs }`
- `client.left`   — `{ client_id }`

### 7.3 PTY 生命周期与字节流

- `pty.created` — `{ info: PtyInfo }`
- `pty.exited`  — `{ pty_id, exit_code: i32 | null }`
- `pty.resize`  — `{ pty_id, cols: u16, rows: u16 }`
- `pty.cwd_changed` — `{ pty_id, cwd: <path> }`。Linux 走 `/proc/<pid>/cwd`、
  macOS 走 `proc_pidinfo`，约 1.5s 轮询；shell-integration `777;P;Cwd=...`
  可以在 I/O 速度下推同一事件。
- `pty.output`：

  ```jsonc
  {
    "pty_id":   "<PtyId>",
    "data_b64": "<base64>",
    "block_id": "<BlockId>" | null,    // null iff scope == "passthrough"
    "scope":    "passthrough" | "prompt" | "command" | "output"
  }
  ```

  客户端按 `(block_id, scope)` 路由字节：同一个 block 的 prompt+command 段
  通常喂给 prompt 区域渲染器（FloatTerm），output 段喂给该 block_id 对应的
  block 渲染器（BlockTerm）。`scope == "passthrough"`(此时 `block_id` 必为
  `null`)按"普通终端流"渲染,不入任何 block 段缓冲。

### 7.4 Shell-integration（OSC 777）

依赖 motifd 注入 shell 的 bootstrap 脚本。OSC 协议详见 `shell-integration.md`。

- `pty.shell_bootstrapped` — `{ pty_id, shell: ShellKind }`：首条 shell-integration marker 命中
  或 5s 超时（此时 `shell="unknown"`）。
- `pty.prompt_started` — `{ pty_id, block_id }`：`777;A` 命中。新 prompt cycle
  在此分配 `block_id`（fish 等 prompt 重绘时 id **不变**，只是标记一次重绘
  边界）。
- `pty.prompt_ended` — `{ pty_id, block_id }`：仅在 AtPrompt → Composing
  这条边触发。`block_id` 与同 cycle 的 `pty.prompt_started` 一致。
- `pty.command_started`：

  ```jsonc
  {
    "pty_id":     "<PtyId>",
    "block_id":   "<BlockId>",     // 与同 cycle 的 prompt_started 一致
    "text":       "<string>",      // 777;E 显式命令文本(缺失时为 "")
    "cwd":        "<path>",
    "started_at": <UnixMs>
  }
  ```

- `pty.command_finished`：

  ```jsonc
  {
    "pty_id":      "<PtyId>",
    "block_id":    "<BlockId>",
    "exit_code":   <i32> | null,   // null = 强制 finalize（如 SIGINT 后 shell 跳过 777;D）
    "finished_at": <UnixMs>
  }
  ```

  block 此刻进入 BlockStore，`pty.list_blocks` 可见。

- `pty.shell_context` — `{ pty_id, ctx: ShellContext }`。每次 precmd 推一次。

> 同一个 prompt cycle 的事件流是有序的：
> `prompt_started → [prompt_started ×N for redraws] → prompt_ended →
> [prompt_started ×N for repaints] → command_started → command_finished`。
> 中途打断（Ctrl-C / 空 Enter / fish autosuggestion repaint）时服务端只
> 重发 `prompt_started`（同 id）当作重绘边界,不会合成 `command_started` /
> `command_finished`,也不入库（详见 §6 中断表）。

`ShellKind`：`bash | zsh | fish | unknown`。

`ShellContext`（所有字段可选；旧客户端无视未知字段即可）：

```jsonc
{
  "branch": "<string>",
  "head":   "<string>",
  "venv":   "<string>",
  "conda":  "<string>",
  "node":   "<string>"
}
```

### 7.5 Tab / view

- `view.opened`         — `{ view: ViewInfo }`
- `view.closed`         — `{ view_id }`
- `view.active_changed` — `{ view_id: <ViewId> | null }`
- `view.moved`          — `{ order: ViewId[] }`（重排后完整顺序）

### 7.6 前向兼容

事件 enum 用 `#[serde(other)]` 做 fallback：未知 method 不会让客户端 JSON
解析失败，但 `seq()` 返回 0，不要拿它去对总序。新增事件总是单调追加；不会修
改既有事件的字段含义。可选字段使用 `#[serde(default,
skip_serializing_if = "Option::is_none")]`，旧客户端忽略未知字段，新服务端
容忍缺字段。错误码只能新增，不能复用历史码位。
