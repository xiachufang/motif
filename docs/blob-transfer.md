# Motif — Blob 传输（独立通道）

> 大文件 / 二进制内容（图片、PDF、归档、模型权重等）通过**独立 WS 连接**传输，不挤占主 JSON-RPC 通道。motif-tui 与 motif-web 都支持上传 / 下载。
>
> 阅读前提：[`prd.md`](./prd.md) §4（核心功能）、§5（JSON-RPC 协议）、§14（`motif-proto` 类型）、[`web-client.md`](./web-client.md) §3（桥接架构）。

---

## 1. Context

v1 的 `fs.read` / `fs.write` 把整个文件用 base64 塞进 JSON-RPC response，缺点：

- **挤占主通道**：一个 50MB 的图片在主 WS 上传 ≈ 67MB 的 JSON 文本，期间所有 PTY 输出和事件全部排队。
- **base64 33% 开销**：纯浪费。
- **硬上限 10MB**：截图、设计稿、PDF 经常超出。
- **没 MIME**：client 只能猜扩展名，"看图"体验差。

解法：**control / data 双通道**。

- 主通道（`/ws` JSON-RPC）：协议指令、PTY mirror、文件树、git 等小消息，与 v1 完全一致
- 数据通道（`/blob/<transfer_id>`）：每次大文件传输开一条**新 WS**，全程二进制帧，传完即关

---

## 2. Architecture

```
                                          ┌──────────────────────────────────────┐
   motif-tui                               │  motifd                              │
   ┌──────────┐    ① fs.openBlob (RPC)     │   axum                               │
   │ control  │ ──────────────────────────►│    ├─ GET  /ws       (主通道)        │
   │  WS      │ ◄──────────────────────────│    └─ GET  /blob/<id> (数据通道)      │
   └──────────┘    transfer_id 返回         │                                      │
                                            │   主通道与数据通道**互不感知**       │
   ┌──────────┐    ② 新 WS 连接             │   transfer_id 是唯一关联             │
   │ data WS  │ ──────────────────────────►│                                      │
   │  binary  │ ◄══════════════════════════│   binary frames                       │
   │  frames  │                            │                                      │
   └──────────┘    ③ 传完 close             │                                      │
                                            │   ④ 自动落盘 / 等 commit             │
                                            └──────────────────────────────────────┘

   Browser                                  motif-web
   ┌──────────┐  GET /blob/<id>             ┌──────────────────────────────────┐
   │ <img src>│ ──────────────────────────► │ HTTP server                       │
   │          │ ◄──────────────────────────│   ├─ GET /blob/<id>                │
   └──────────┘  Content-Type/-Length       │   │  └─ 内部 WS 拉 motifd          │
                 标准 HTTP 流式响应          │   │       /blob/<id> 后转发        │
                                            │   └─ /ws (主通道桥接)              │
                                            └──────────────────────────────────┘
```

**关键设计**

- TUI / native GUI 直接用 motifd 的 `/blob/<id>` WS。
- 浏览器通过 motif-web 暴露的 **HTTP** `GET /blob/<id>` 拉取，浏览器侧用原生 `<img src>` / `<video>` 即可——不需要前端写 WS-to-blob 解析逻辑。
- motif-web 内部把这个 HTTP 请求翻译成对 motifd 的 `/blob/<id>` WS 拉取并流式转发。
- motifd 的协议表面增加一个 axum 路由（仍只是 WS 升级），不引入"真正的 HTTP 文件服务"。

---

## 3. 协议变更

### 3.1 `motif-proto` 新增

```rust
// motif-proto::fs

#[derive(Serialize, Deserialize)]
pub struct OpenBlobParams {
    pub path:            String,
    pub mode:            BlobMode,                    // Read | Write
    pub expected_sha256: Option<Sha256Hex>,           // write 模式可选乐观锁
    pub total_size:      Option<u64>,                 // write 模式可选；服务端用于预校验和限额
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug)]
#[serde(rename_all = "lowercase")]
pub enum BlobMode { Read, Write }

#[derive(Serialize, Deserialize)]
pub struct OpenBlobResult {
    pub transfer_id:  String,         // ULID
    pub blob_path:    String,         // "/blob/<transfer_id>"，client 拼到 motifd 基址后用
    pub expires_at:   UnixMs,         // 默认 now + 5 min
    // 仅 Read 模式填充：
    pub size:         Option<u64>,
    pub mime:         Option<String>,
    pub sha256:       Option<Sha256Hex>,
}

#[derive(Serialize, Deserialize)]
pub struct CommitBlobParams { pub transfer_id: String }

#[derive(Serialize, Deserialize)]
pub struct CommitBlobResult { pub sha256: Sha256Hex }

#[derive(Serialize, Deserialize)]
pub struct CancelBlobParams { pub transfer_id: String }
```

### 3.2 主通道新增方法

| 方法 | 章节 |
|---|---|
| `fs.openBlob` | 3.1 |
| `fs.commitBlob` | 写模式收尾，3.4 |
| `fs.cancelBlob` | 客户端主动放弃；可选，3.5 |

### 3.3 顺带补的 MIME 字段

老的 `fs.read` `ReadResult` 增加：

```rust
pub struct ReadResult {
    pub content_b64: String,
    pub sha256:      Sha256Hex,
    pub truncated:   bool,
    pub binary:      bool,
    pub mime:        Option<String>,   // ★ 新增；server 端用 mime_guess + magic bytes 推断
}
```

旧 client 忽略该字段即可，向后兼容。

### 3.4 写流程（client → server）

```
1. client → main WS:  fs.openBlob(path, mode=write, expected_sha256?, total_size?)
2. main WS  → client: { transfer_id, blob_path, expires_at }
3. client opens NEW WS: <motifd_origin>/blob/<transfer_id>
   - HTTP 升级阶段带 Authorization: Bearer <token>（同主通道）
4. client 在新 WS 上发送二进制帧（每帧任意大小，可流式）
5. client close 该 WS
6. server 收到 close → tmp 文件已写完 → 等 fs.commitBlob
7. client → main WS:  fs.commitBlob(transfer_id)
8. server 校验 sha256 与 expected_sha256（若提供），原子 rename 到 path
9. server → main WS:  { sha256 }；广播 tree.changed + git.changed
```

中途断开（任一端）：server 删 tmp 文件，transfer_id 失效。

### 3.5 读流程（server → client）

```
1. client → main WS:  fs.openBlob(path, mode=read)
2. main WS  → client: { transfer_id, blob_path, size, mime, sha256, expires_at }
3. client opens NEW WS: <motifd_origin>/blob/<transfer_id>
4. server 立即开始流式发二进制帧（按 1MB 块或 OS read 自然块大小）
5. 文件读完 → server close WS
6. client 收齐字节，可比对 sha256
```

中途取消：client close WS 即可。可选 `fs.cancelBlob(transfer_id)` 显式释放。

---

## 4. motifd 实现

### 4.1 axum 路由

```rust
// crates/motif-server/src/ws.rs（节选）

let app = Router::new()
    .route("/ws",            get(ws_main_upgrade))
    .route("/blob/:tid",     get(blob_ws_upgrade));
```

`blob_ws_upgrade`：

1. 校验 Bearer header
2. 在 `BlobRegistry` 查 `tid`：不存在或过期 → 关闭码 4404 (`BlobNotFound`)
3. 校验 token 对应的 client_id 是否就是当初 `fs.openBlob` 的发起方（防止串号）
4. 升级 WS，按 mode 执行 §3.4 / §3.5 流程
5. 完成 / 失败 → 从 `BlobRegistry` 移除

### 4.2 BlobRegistry

每个 Session 内部一个：

```rust
struct BlobRegistry {
    transfers: DashMap<TransferId, BlobTransfer>,
}

struct BlobTransfer {
    id:           TransferId,
    client_id:    ClientId,             // 谁发起的
    session_id:   SessionId,
    path:         PathBuf,              // 落盘绝对路径
    mode:         BlobMode,
    created_at:   Instant,
    expires_at:   Instant,
    state:        TransferState,        // Pending | Streaming | Awaiting Commit | Completed | Failed
    expected_sha: Option<Sha256Hex>,    // write 模式
    total_size:   Option<u64>,
    tmp_file:     Option<PathBuf>,      // write 模式临时文件
}
```

后台 task 每 30s 扫一次，回收过期 transfer 和它的 tmp 文件。

### 4.3 限额（写进 §7 安全模型）

- 单个 blob 上限：默认 **200 MB**，`--max-blob-size` 调整（最高 2 GB）
- 每 Session 并发活跃 transfer：**4** 个
- transfer_id TTL：默认 **5 分钟**（开通后未 attach 数据通道）；attach 后无限直到完成或断
- tmp 目录：`<workdir>/.motif/blobs/`，启动时清理残留
- 写完 commit 前的 tmp 文件不可见（原子 rename 才进文件树）

新增错误码：

```rust
BlobNotFound       = -32011,
BlobExpired        = -32012,
BlobLimitReached   = -32013,
BlobTooLarge       = -32014,
BlobChecksumMismatch = -32015,
```

### 4.4 client_id 绑定

`fs.openBlob` 的 result 里**不返回 token**（client 用既有 Bearer）。但要防"另一个客户端拿到 transfer_id 来串号"：

- `BlobTransfer` 记录 `client_id`
- `/blob/<id>` 升级时校验 token 解析出的 client_id 必须等于 transfer 的 owner
- 跨 client 串号 → `BlobNotFound`（不暴露存在性）

---

## 5. TUI 客户端

### 5.1 图片查看

文件树 / tab 中点开一个图片文件：

1. 调 `fs.openBlob(path, mode=read)`
2. 拿到 `{ transfer_id, blob_path, size, mime }`
3. 起新 WS 拉数据，存到内存或 `/tmp` 文件
4. 渲染：检测终端能力（按优先级）：
   - kitty graphics protocol（`KITTY_WINDOW_ID` 或 `terminfo:Tc` + 探测）
   - iTerm2 inline image（`TERM_PROGRAM=iTerm.app`）
   - sixel（terminfo `Smulx`/sixel 检测）
   - 都没有：占位 `[image: 1024×768 png, 250 KB]` + `o` 调系统默认 viewer（`open` / `xdg-open` 写本地 tmp）
5. 关闭 tab → tmp 文件清理

依赖 crate：`viuer` 或 `ratatui-image` 选一个，能盖三种主流终端协议。

### 5.2 上传

`u` 键打开输入框，选本地路径或目标路径：

1. 计算本地文件 sha256（可选，用于事后比对）
2. 调 `fs.openBlob(path, mode=write, total_size, expected_sha256?)`
3. 起新 WS，按 1MB 块流式发送（`tokio::io::copy_buf`）
4. close WS → `fs.commitBlob(transfer_id)`
5. 收到 `{ sha256 }` 后刷新文件树

进度条：本地知道 `total_size`，发送字节自计数即可。

### 5.3 下载（保存到本地）

类似 5.1 的读流程，最后步骤是写到本地路径而非渲染。命令 `motif-tui pull <remote-path> <local-path>`（或 TUI 内的 `:save` 命令）。

---

## 6. motif-web 实现

### 6.1 HTTP 代理路由

```rust
// crates/motif-web/src/http.rs（节选）

let app = Router::new()
    .route("/",          ServeEmbed::new())
    .route("/assets/*",  ServeEmbed::new())
    .route("/ws",        get(browser_ws_upgrade))
    .route("/blob/:tid", get(blob_get).put(blob_put));
```

### 6.2 GET /blob/:tid（浏览器下载）

1. 校验浏览器侧 token（同主通道，从 cookie/Authorization/query 取，决于浏览器侧鉴权策略）
2. 用 motif-web 自己的 `motifd-token` 起一条到 motifd `/blob/<tid>` 的 WS
3. 设置响应头：`Content-Type: <mime>`、`Content-Length: <size>`、`Cache-Control: no-store`（避免浏览器缓存 transfer_id 一次性数据）
4. 把 motifd 来的二进制帧逐帧 write 到 HTTP body
5. motifd close → motif-web close HTTP body

> mime 和 size 来自浏览器先调用 `fs.openBlob` 时 motif-web 自动透传给前端的 result。前端 `<img>` 拼接 URL 时已经有这些信息。

### 6.3 PUT /blob/:tid（浏览器上传）

1. 校验浏览器侧 token
2. 起到 motifd 的 `/blob/<tid>` WS
3. 把 HTTP body 的 chunk 流逐块用 binary frame 转发给 motifd
4. HTTP body 结束 → motif-web close 上游 WS
5. 返回 `200 {}`；前端拿到后调主通道 `fs.commitBlob`

### 6.4 浏览器前端

```ts
// 看图
async function openImage(path: string) {
  const r = await rpc("fs.openBlob", { path, mode: "read" });
  // r.blob_path = "/blob/01HX..."；浏览器同源拼 motif-web URL
  return { src: r.blob_path, mime: r.mime, size: r.size };
}

// 上传
async function uploadFile(path: string, file: File) {
  const r = await rpc("fs.openBlob", {
    path, mode: "write",
    total_size: file.size,
    expected_sha256: null,
  });
  await fetch(r.blob_path, {
    method: "PUT",
    headers: { "Content-Type": file.type },
    body: file,
  });
  await rpc("fs.commitBlob", { transfer_id: r.transfer_id });
}
```

`<img src={blob_path}>` 直接渲染。Solid 用普通 effect 处理。

---

## 7. 安全 & 限额

- transfer_id 是单向能力 token：**只有发起的 client_id 能用**，5 分钟内有效，过期回收
- 路径越界保护与 §4.2 文件树相同：blob 路径强制在 session workdir 之下
- 写完 commit 才进文件树，commit 前看不见、广播也不发出
- 单 session 并发限：4 个活跃 transfer。第 5 个 `fs.openBlob` 返回 `BlobLimitReached`
- 单 blob 上限：默认 200MB，`--max-blob-size` 调
- 总磁盘水位：tmp 目录使用率 > 80% 时拒绝新的 write transfer，返回 `Full`（具体错误码 §4.3 决定）

**TLS / 鉴权**与主通道完全一致；blob 通道继承同样的 Bearer 校验和 TLS 强制。

---

## 8. 资源清单（落实给 M1+）

| 改动点 | 位置 |
|---|---|
| `OpenBlobParams` / `OpenBlobResult` / `CommitBlob*` / `CancelBlob*` | `motif-proto::fs` |
| `mime` 字段 | `motif-proto::fs::ReadResult` |
| 新增错误码 (`-32011`～`-32015`) | `motif-proto::error::ErrorCode` |
| `/blob/:tid` axum 路由 | `motif-server::ws` |
| `BlobRegistry` + 后台清理 task | `motif-server::session` |
| TUI image rendering | `motif-tui::ui::*` 新增 `image_view.rs` |
| `motif-tui pull` / `:save` 命令 | `motif-tui::main` + lib |
| HTTP `GET/PUT /blob/:tid` 代理 | `motif-web::http` |
| 浏览器侧 `fs.openBlob` + `<img>` 渲染 | `web/src/store/blob.ts` 等 |

---

## 9. Milestones

放在 v1 主线之后作为独立 M6（不要塞进 M1–M5，避免 v1 主线膨胀）：

| 阶段 | 范围 | 验收 |
|---|---|---|
| **M6.1: 协议骨架 + motifd /blob/:tid** | 主通道新方法、`BlobRegistry`、读模式 WS | TUI 端能 `fs.openBlob` 后从 `/blob/<id>` 收到一段已知文件的二进制流 |
| **M6.2: 写模式 + commit + tmp 原子化** | write 流程、`fs.commitBlob`、过期回收 | TUI 上传一张本地 PNG，server 端原子化落盘并广播 `tree.changed` |
| **M6.3: TUI 图片查看** | viuer / ratatui-image 集成、kitty/iTerm2/sixel 检测 | 在 kitty 里点开 PNG 直接看到，回退路径写 tmp + xdg-open |
| **M6.4: motif-web HTTP 代理** | GET/PUT /blob、浏览器 `<img>` 渲染、上传 UI | Web 上看到同一 PNG；拖拽上传后回到 TUI 看见 |

---

## 10. 开放问题

- [ ] **TUI 上传的并发**：v1.5 上传走前台阻塞还是后台 task？倾向后台（不卡 TUI）。
- [ ] **MIME 信任策略**：`fs.openBlob(write)` 是否允许 client 提供 MIME 提示？倾向不允许，server 自行用 `mime_guess` + magic bytes 推断（避免 client 撒谎引入风险）。
- [ ] **Range / 续传**：v1.5 不做。如果未来需要，扩展 `fs.openBlob` 加 `offset`，motif-web 把 HTTP `Range` 头翻译进去；不破坏现有协议。
- [ ] **HTTP/2 多路复用**：motif-web 接浏览器侧默认 HTTP/1.1 keep-alive；要不要要求 H2？v1.5 默认 HTTP/1.1，axum 自动处理就行。
- [ ] **commit 默认是否 auto**：close WS 后默认 5 秒未 commit 就自动 commit（写模式）？或者必须显式 commit？倾向**显式**（保留 `expected_sha256` 二次校验时机），但 motif-web 的 PUT handler 内部代为调 commit，浏览器前端不需要看到这一步。
