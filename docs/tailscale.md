# Motif — Tailscale 集成（Client 侧）

> 本文档描述 motif-tui 与 motif-web 如何通过嵌入 [`libtailscale`](https://github.com/tailscale/libtailscale) 让 client 二进制本身成为 tailnet 节点，不依赖系统 Tailscale daemon。
>
> **核心 motifd 不集成 Tailscale**——它仍只是 WS 监听器，绑哪个接口都行；MacBook 等需要被外部访问时由系统 Tailscale daemon 暴露。
>
> 阅读前提：已熟悉 [`prd.md`](./prd.md) §3（架构）、[`web-client.md`](./web-client.md) §3（桥接）。

---

## 1. Context

部署 motifd 的机器（MacBook、家里的小主机、办公室工作站）通常在 NAT 后面。让 client 能从任意地方接入而不依赖端口转发或 ngrok-style 隧道，常见方案是 mesh VPN，Tailscale 是用户基数最大的一家。

但用户在 client 端机器（笔记本、容器、CI runner）上**也要装一遍 Tailscale daemon** 才能加入 tailnet——这是 motif 的 v1 推荐做法（见 [`prd.md`](./prd.md) §7 部署示例），但每台 client 的初始化成本仍然存在。

`libtailscale` 是 Tailscale 官方的 C 封装，把 Go 实现的 `tsnet` 包装成 C-ABI，链接进 client 二进制后该二进制本身就是 tailnet 上的一个节点：

- 用户机器**不需要装 Tailscale daemon**
- `motif-tui attach my-mac` 在任意机器上即开即用
- motif-web 部署在任何能联网的地方都能反向接入私网中的 motifd

---

## 2. 范围与边界

### In-scope（v1.5）

- 新增 `motif-tailscale` crate：libtailscale 的 Rust safe wrapper
- `motif-tui` 默认依赖该 crate（feature `tailscale` 默认开），新增 `hosts` / `whoami` / `logout` 子命令；`attach` 自动支持 tailnet 短主机名
- `motif-web` 默认依赖该 crate；启动时可加入 tailnet，监听 tailnet 接口或全部接口
- 双轨构建：`bundled`（默认，本地用 Go 编 libtailscale）+ `prebuilt`（从 release 下载预编译产物，无需 Go 工具链）
- `--no-default-features` 可完全去掉 Tailscale 依赖，回到纯净 Rust 二进制

### 明确 Non-goals

- ❌ **server 端**（`motifd`）不集成。motifd 永远是普通 WS 监听器；MacBook 上想被远程访问就装系统 Tailscale daemon。这是与 [`prd.md`](./prd.md) §3 "motifd 只做协议核心" 一致的取舍。
- ❌ Tailscale 替换 motif 自己的 Bearer token。两套机制并存，Tailscale 给 connectivity，Bearer 给应用层鉴权。v1.5 不做"以 Tailscale 身份替代 token"的逻辑。
- ❌ 不维护自己的 fork。直接 vendor libtailscale 上游 release tag，跟随升级。
- ❌ Tailscale Funnel（公网暴露）/ Serve（HTTPS 反代）等 Tailscale 高级功能 v1.5 不集成；只用最核心的 tsnet 节点能力。

---

## 3. 架构

```
   ┌──────────────────────────────────┐         ┌─────────────────────┐
   │  motif-tui 二进制                │         │  motifd (核心)      │
   │  ┌────────────────────────────┐  │         │  在 MacBook 上      │
   │  │ Rust 业务代码              │  │         │  绑 100.x.y.z:7777  │
   │  │  ↓ uses                    │  │         │  (系统 tailscaled   │
   │  │ motif-tailscale (lib)      │  │         │   提供接口)         │
   │  │  ↓ FFI                     │  │         └──────────▲──────────┘
   │  │ libtailscale.a (静态链接)  │  │                    │
   │  │  ├─ Go runtime             │  │   tailnet         │
   │  │  └─ tsnet                  │  │  WireGuard       │
   │  │     ↓ 加入 tailnet         │  │   端到端加密       │
   │  └────────────────────────────┘  ├────────────────────┘
   │                                  │
   │  state: ~/.config/motif/         │
   │           tui/tailscale/         │
   └──────────────────────────────────┘
```

**关键**：

- libtailscale 把 Go runtime + tsnet 编成一个 C archive，Rust 端通过 FFI 调用。运行时这是单一进程（Go runtime 寄生在 Rust 进程内），**不是** sidecar 模式。
- motifd 看到的连接：从 tailnet IP 来的普通 TCP；它不知道对端是嵌入式 tsnet 还是系统 daemon。
- motif-web 同款集成：bridge → motifd 这一跳可以走 tailnet，浏览器 → motif-web 这一跳仍是普通 HTTP/WS（与浏览器侧 Tailscale 无关）。

---

## 4. `motif-tailscale` crate

### 4.1 文件结构

```
crates/motif-tailscale/
├─ Cargo.toml
├─ build.rs                    # 编译 / 下载 libtailscale，输出 cargo:rustc-link-lib
├─ vendor/
│  └─ libtailscale/            # git submodule 指向 tailscale/libtailscale
├─ wrapper.h                   # 给 bindgen 的 C 头入口
└─ src/
   ├─ lib.rs                   # pub use safe::* 等
   ├─ ffi.rs                   # bindgen 生成或手写的 extern "C"
   ├─ safe.rs                  # 安全 Rust API：Server/Listener/Stream/LocalClient
   ├─ state.rs                 # state 目录约定 + 初始化
   └─ error.rs                 # TsError 转换
```

### 4.2 Features

```toml
# crates/motif-tailscale/Cargo.toml
[features]
default = ["bundled"]
bundled  = []                  # build.rs 调 Go 本地编译 libtailscale
prebuilt = []                  # build.rs 从 GitHub release 下载预编译产物
```

`bundled` 与 `prebuilt` 互斥。同时启用时 `bundled` 优先（避免对网络的依赖）。下游 `motif-tui` 和 `motif-web` 透传：

```toml
# crates/motif-tui/Cargo.toml（节选）
[features]
default          = ["tailscale"]
tailscale        = ["dep:motif-tailscale"]
tailscale-prebuilt = ["tailscale", "motif-tailscale/prebuilt"]
```

用户构建路径：

| 命令 | 行为 |
|---|---|
| `cargo build -p motif-tui` | 默认走 bundled —— 需要本机 Go 1.21+ |
| `cargo build -p motif-tui --no-default-features` | 完全不带 Tailscale，纯 Rust，无 Go 依赖 |
| `cargo build -p motif-tui --no-default-features --features tailscale-prebuilt` | 启用 Tailscale 但下载 prebuilt，无需 Go |

### 4.3 安全封装设计

C API 类型由 libtailscale 头文件给出，最小有用集合：

```rust
// motif-tailscale::safe（示意）
pub struct TsServer { /* 内部持 *mut tailscale_server_t */ }

impl TsServer {
    pub fn new(opts: TsOptions) -> Result<Self, TsError>;
    pub fn up(&self) -> Result<(), TsError>;          // 阻塞直到加入 tailnet 完成
    pub fn down(self) -> Result<(), TsError>;
    pub fn listen(&self, network: &str, addr: &str) -> Result<TsListener, TsError>;
    pub fn dial(&self, network: &str, addr: &str) -> Result<TsStream, TsError>;
    pub fn local_client(&self) -> TsLocalClient;       // 取 status/whois 等
}

pub struct TsListener { /* implements tokio::net::TcpListener-like trait */ }
pub struct TsStream   { /* implements tokio::io::AsyncRead+Write */ }
pub struct TsLocalClient { /* status() -> Vec<TsPeer>, whois() -> TsIdentity */ }

pub struct TsOptions {
    pub hostname:     String,                 // 出现在 tailnet 上的设备名
    pub state_dir:    PathBuf,                // 持久化 auth + machine key
    pub authkey:      Option<String>,         // 首次登录用，后续从 state 恢复
    pub control_url:  Option<String>,         // 自托管 Headscale 时用
    pub ephemeral:    bool,                   // true = 退出即从 tailnet 移除
}
```

`TsListener` 与 `TsStream` 实现 tokio 的 IO trait，可以**透明**接入 `tokio-tungstenite::accept`/`connect` —— 上层 WS / JSON-RPC 代码不用改。

---

## 5. 构建依赖

### 5.1 Bundled（默认）

`build.rs` 步骤：

1. 检查 `vendor/libtailscale/` submodule 是否初始化；未初始化时报错并提示 `git submodule update --init`
2. 探测 `go version`，要求 ≥ 1.21；缺失时给清晰报错并指向 prebuilt feature
3. 在 `OUT_DIR` 下执行：
   ```
   go build -buildmode=c-archive -o $OUT_DIR/libtailscale.a ./...
   ```
4. 用 `bindgen` 从 `wrapper.h` 生成 `bindings.rs`
5. 输出 cargo 指令：`cargo:rustc-link-lib=static=tailscale` + 平台对应的系统库（`-framework CoreFoundation -framework Security` on macOS，`-lpthread -ldl` on Linux 等）

### 5.2 Prebuilt

`build.rs` 步骤：

1. 读取 `vendor/libtailscale/VERSION`（与 bundled 同 tag）
2. 拼装下载 URL：`https://github.com/tailscale/libtailscale/releases/download/<tag>/libtailscale-<target>.tar.gz`
3. 校验 sha256（checksums 文件随 crate 一起 vendor）
4. 解压到 `OUT_DIR`，链接同上
5. 失败回退：日志提示，但**不**自动切到 bundled（避免静默地依赖 Go 工具链）

### 5.3 完全 opt-out

```bash
cargo build -p motif-tui --no-default-features
```

motif-tailscale 整个 crate 不被引入，二进制大小回到 5 MB 量级。失去的能力：

- `motif-tui hosts` / `whoami` / `logout` 子命令报"未编译 Tailscale 支持"并退出
- `attach` 不支持短主机名，只能传完整 URL
- 用户可手动跑系统 Tailscale daemon 实现连通性，与 v1 行为一致

---

## 6. Auth & State

### 6.1 首次运行

两条路径，按优先级：

1. **`--ts-authkey <key>`** 或环境变量 `TS_AUTHKEY`：直接用预生成的 auth key（[Tailscale 控制台 Keys 页](https://login.tailscale.com/admin/settings/keys)）。适合脚本、CI、容器化场景。
2. **交互式 OAuth**：未提供 key 时，`TsServer::up()` 内部会打印
   ```
   To authenticate, visit:
       https://login.tailscale.com/a/abc123def456
   Waiting for authentication...
   ```
   用户在浏览器完成登录后回到 CLI，状态自动保存。

### 6.2 State 目录

每个二进制独立 state（不共享），按平台 XDG 约定：

| Binary | macOS | Linux | Windows |
|---|---|---|---|
| `motif-tui` | `~/Library/Application Support/motif/tui/tailscale` | `~/.config/motif/tui/tailscale` | `%APPDATA%\motif\tui\tailscale` |
| `motif-web` | `~/Library/Application Support/motif/web/tailscale`（开发用） | `/var/lib/motif-web/tailscale`（生产） | `%APPDATA%\motif\web\tailscale` |

可通过 `--ts-state-dir` 覆盖。motif-web 的生产部署建议显式指定，便于 systemd 管理权限。

### 6.3 退出与重新认证

- `motif-tui logout`：调用 `TsServer::down()` + 清空 state 目录。下次运行会重新 OAuth。
- `motif-tui logout --keep-device`：清本地 state 但**不**主动从 tailnet 摘除。device 在 Tailscale 控制台仍可见，需手动删除或等 ephemeral key 过期。
- 推荐做法：CI / 临时容器使用 `--ts-ephemeral`，进程退出自动从 tailnet 移除。

---

## 7. `motif-tui` 集成

### 7.1 新增子命令

```bash
# 列出 tailnet 上可达的设备（按是否监听 motif 端口过滤）
$ motif-tui hosts
HOSTNAME              IP           OS       MOTIFD
my-mac                100.64.1.2   macOS    yes (7777)
work-desktop          100.64.1.5   linux    yes (7777)
laptop-personal       100.64.1.9   linux    no
ipad                  100.64.1.12  iOS      no

# 显示当前身份
$ motif-tui whoami
Tailnet:  example.com
User:     fei@example.com
Device:   motif-tui-myhost (100.64.2.7)
Ephemeral: no

# 清登录
$ motif-tui logout [--keep-device]
```

`hosts` 的 motifd 探测做法：对 tailnet 内每个 peer 起一次 5 秒超时的 TCP connect，并发跑（默认并发度 32）；可以加 `--port 7777` 改默认端口。

### 7.2 attach 路由决策

`motif-tui attach <target> --session <name>`，`<target>` 解析顺序：

1. 完整 URL（`wss://...` 或 `ws://...`）→ 直接用，不走 tailnet
2. `--via tailnet` 显式指定 → 强制走 tsnet dial
3. `--via direct` 显式指定 → 强制走系统 TCP stack
4. 默认启发式：
   - 包含 `.` 且非 MagicDNS 后缀（如 `.ts.net`、`.tailxxx.ts.net`）→ direct
   - 不含 `.` 或以 MagicDNS 后缀结尾 → tailnet
5. 上述都未命中时，先尝试 tailnet（成本低），失败再 fallback 到 direct（带提示）

例：

```bash
$ motif-tui attach my-mac --session work
# host="my-mac"，无点 → tsnet dial → 解析 my-mac.tailxxx.ts.net:7777 → connect

$ motif-tui attach my-mac.tailxxx.ts.net --session work
# host 含 .ts.net → tsnet dial

$ motif-tui attach 192.168.1.50:7777 --session work
# 含 . 不带 ts.net 后缀 → direct

$ motif-tui attach wss://my-mac:7777/ --session work
# 完整 URL → 直接 connect（自动判断是否走 tsnet 由 host 部分决定）
```

---

## 8. `motif-web` 集成

### 8.1 配置参数

```bash
motif-web \
  --listen :8080 \                                  # 浏览器接入端口（仍用系统 TCP 栈监听）
  --motifd-url wss://my-mac:7777/ \                 # 上游可以是 tailnet 短主机名
  --motifd-token-file /etc/motif/motifd.token \
  --browser-token-file /etc/motif/web.token \
  --ts-authkey-file /etc/motif/ts.authkey \         # 加入 tailnet 的凭证（生产从文件读，避免暴露在 ps）
  --ts-hostname motif-web-prod \                    # 在 tailnet 上的设备名
  --ts-state-dir /var/lib/motif-web/tailscale \
  --ts-ephemeral=false                              # 生产环境保留设备，便于 ACL 跟踪
```

也可以反过来，让 motif-web **监听 tailnet 接口**（让浏览器从 tailnet 内访问，而不是公网）：

```bash
motif-web --ts-listen :8080  ...
```

`--ts-listen` 与 `--listen` 互斥；启用前者时 `axum` 接管的是 `TsListener`（tsnet 提供的 listener），浏览器请求只能从 tailnet 内来。这是给"全部走 tailnet、不暴露公网端口"场景用的。

### 8.2 motifd 上游路由

motif-web → motifd 的连接走 `motif-tailscale` 的 dial（与 motif-tui §7.2 同一套启发式）。motifd-url 是 tailnet 短主机名时自动走 tsnet。这意味着 motif-web 可以部署在和 motifd 完全不同的网络（甚至不同区域），只要它们在同一 tailnet 内即可。

---

## 9. 命名 & 设备生命周期

- 默认 hostname：`motif-tui-<system-hostname>` / `motif-web-<system-hostname>`，可被 `--ts-hostname` 覆盖
- 推荐**不**默认开 `--ts-ephemeral`：开发者机器的 motif-tui device 应稳定，便于做 ACL；CI / 短生命周期容器场景再加 `--ts-ephemeral`
- Tailscale 控制台建议给这些设备打 tag：`tag:motif-tui` 与 `tag:motif-web`，便于写 ACL（见 §11）

---

## 10. 二进制体积

实测预估（macOS arm64、release 构建）：

| 配置 | motif-tui | motif-web |
|---|---|---|
| 默认（含 bundled tailscale） | ~25 MB | ~28 MB |
| 仅 prebuilt（同上） | ~25 MB | ~28 MB |
| `--no-default-features` | ~5 MB | ~7 MB |

`strip` 后 motif-tui 通常能压到 ~18 MB（Go runtime 是不太能 strip 掉的部分）。对开发工具来说可接受。

---

## 11. Tailscale ACL 建议

在 Tailscale 控制台写 ACL（参考，按需调整）：

```jsonc
{
  "tagOwners": {
    "tag:motif-server":    ["fei@example.com"],   // motifd 所在主机
    "tag:motif-tui":       ["fei@example.com"],
    "tag:motif-web":       ["fei@example.com"]
  },

  "acls": [
    // motif-tui 可以连 motif-server 的 7777
    {
      "action": "accept",
      "src":    ["tag:motif-tui"],
      "dst":    ["tag:motif-server:7777"]
    },
    // motif-web (桥接) 同样需要连 motif-server
    {
      "action": "accept",
      "src":    ["tag:motif-web"],
      "dst":    ["tag:motif-server:7777"]
    },
    // motif-tui / motif-web 之间互不需要直连
  ]
}
```

加这层 ACL 是 motif Bearer token 之外的一道**网络层**防线：即使 token 泄漏，攻击者也得在 tailnet 上有一台被授权的设备才能尝试连。

---

## 12. 开放问题

- [ ] **OAuth 交互体验**：libtailscale 输出 URL 的 callback 是 stdout，TUI 模式下需要切出 ratatui 全屏才能让用户看清楚。是否要先弹出"按 Enter 在浏览器中登录"提示？
- [ ] **Headscale 兼容**：libtailscale 支持 `--login-server`，是否在 v1.5 暴露这个参数？应该可以，几行参数透传的事，倾向加。
- [ ] **prebuilt 资产签名**：从 release 下载时怎么校验？方案 A：vendor 一份 `checksums.txt` + minisign 公钥；方案 B：仅 sha256，依赖 GitHub release 完整性。倾向 A。
- [ ] **`--ts-ephemeral` 默认值**：开发者交互式用倾向 false，CI / 容器倾向 true。motif-tui 默认 false（设备稳定），motif-web 默认随构建模式（debug → true，release → false）？

---

## 13. 与已有文档的关系

- [`prd.md`](./prd.md) §7（部署示例）会加一段指向本文档；motifd 仍不集成。
- [`web-client.md`](./web-client.md) §5/§6 会加 motif-tailscale 的依赖说明。
- 本文档是 motif-tailscale crate 的事实标准；任何 Tailscale 相关行为变更优先更新这里。
