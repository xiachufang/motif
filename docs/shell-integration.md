# Motif — Shell Integration & Block 流 规划文档（草案）

> 本文档是 [`prd.md`](./prd.md) 的延伸。规划在 v1.5（Web client，见 [`web-client.md`](./web-client.md)）之后引入：server 端解析 PTY 输出里的 OSC 钩子，把 shell 会话拆成结构化 *block*（命令 + 输出 + 退出码 + cwd + git/venv 等上下文）。Web/TUI client 在协议之上叠加只读 block UI，**不**做 GUI 行编辑器、不做协同、不做补全 / 历史 RPC。
>
> 阅读前提：已熟悉 `prd.md` §3（架构）、§4（核心功能）、§5（JSON-RPC 协议）、§14（`motif-proto` 类型）；以及 `web-client.md` §3（Architecture）。
>
> 状态：**草案**。OSC 编号、字段名、ring buffer 容量等具体取值待实现阶段定稿。

---

## 1. Context

v1 / v1.5 PTY 是个透明字节管道：client 拿到 `pty.output` 字节流交给 xterm.js / TUI 终端控件渲染，server 除了 1.5s 轮询 `proc_pidinfo` / `/proc/<pid>/cwd` 跟踪 cwd（broadcast 为 `pty.cwd_changed`）外不理解流的内容。这是个有意的最小集，但也意味着所有"理解"工作必须在 client 重做：

- 不知道一条命令何时开始 / 结束，没有退出码
- 不知道哪段输出属于哪条命令，无法做"跳到上一条命令"、"复制该命令的输出"
- 后加入的 client 只能从 ring buffer 里碰运气，没有 block 维度的历史

业界已经有成熟的 OSC 钩子协议（FinalTerm 提案的 OSC 133；iTerm2、VS Code、Warp 各自扩展的私有 OSC）。motif 复用 OSC 133 + 一组 motif 自定义 OSC，**让 server 成为唯一真相源**：所有 client 共享同一份 block 列表。

motif 的多 client + TUI/Web 双前端 + 远端 server 架构，使"server 端实现"显著优于"client 端各自解析"：

- TUI / Web / 未来的 native GUI 共享同一套事件，无需各写一遍 OSC parser
- 后加入的 client 可以 `pty.list_blocks` 一次性拉历史，不必回放整条 PTY 流
- Bootstrap 脚本本来就要由 spawn PTY 的一方注入，server 端实现没有额外的 injection 成本

## 2. Goals & Non-goals

### Goals

- **结构化 block 流**：每条用户执行的命令产生 `command_started` / `command_finished` 事件，附带 cwd、命令文本、退出码、起止时间。
- **PTY 输出归属**：现有 `pty.output` 增加 `block_id?` 字段，client 可以按 block 折叠 / 导航 / 复制。
- **OSC 7 cwd 精确触发**：现有 pid polling 降为 fallback；shell hook 发 OSC 7 时 server 立即 emit `pty.cwd_changed`，不再等 1.5s 轮询。
- **Shell context 包**：每次 prompt 渲染时 shell hook 发一份 git / venv / node 等上下文，client 渲染状态栏 chip。
- **Block 历史**：每个 PTY 在 server 维护有界 ring buffer，late-join client 能看到最近 N 条 block 的元数据 + 截断输出。
- **Bootstrap 透明**：用户启动 `motifd` 后默认 PTY 行为 = 老 PTY 体验 + 多出来的元数据，不破坏 vim/htop/SSH/tmux 等场景。

### Non-goals

- ❌ **GUI 行编辑器 / Warp 风格 block editor**。client 输入仍走 xterm raw passthrough（v1.5 web）/ 终端 raw（TUI）。
- ❌ **Tab 补全 / Ctrl-R 历史搜索 RPC**。shell 自己处理（用户敲键直接到 shell，shell 自补全），motif 协议层不感知。
- ❌ **In-band generator RPC**（server 主动让 shell 跑函数取数据）。无 GUI editor 就不需要。
- ❌ **Editor lock / 多 client editor 协调**。无 GUI editor，PTY 输入仍按 v1 的"完全镜像"语义共享。
- ❌ **Line editor 状态广播**（`pty.input_mode_changed`）。无 GUI editor 接收方；client 想知道 shell 是否 idle 可从 `command_started` / `finished` 推断。
- ❌ **Shell 语法 parser**。多行命令交给 shell 自己；PS2 出现就出现。
- ❌ **AI 补全 / agent 钩子**。
- ❌ **Windows ConPTY 网格 reset**。motif 暂不目标 Windows server。
- ❌ **强制启用**。用户可关闭 shell integration（env / 配置），此时 PTY 退化为 v1 行为，TUI/Web 也不渲染 block UI。

## 3. Architecture

```
                   ┌─────────────────── motifd ─────────────────────┐
                   │                                                │
   shell (bash/zsh/fish)                                            │
        │  PTY                                                      │
        │  bytes ───────► OSC scanner ──► state machine ──┐         │
        │   │  (扩展 QueryScanner)         │              │         │
        │   ▼                              ▼              │         │
        │  strip motif-OSC           BlockStore           │         │
        │  (passthrough 标准 OSC)    (ring buffer)        │         │
        │                                  │              │         │
        │                                  ▼              ▼         │
        │                            pty.output      block 事件     │
        │                          (含 block_id)  (started/finished/│
        │                                  │       cwd_changed/...) │
        │                                  ▼              │         │
        │             ┌─────── client broadcast ──────────┘         │
        │             │                                             │
        └─────────────┼─────────────────────────────────────────────┘
                      │
              ┌───────┴───────┐
              │               │
          TUI client      Web client
        （命令边界 /     （只读 Block UI
          退出码着色 /    + 状态栏 chip，
          块跳转）         xterm 输入直通）
```

关键改动点：

1. **Bootstrap 注入**：spawn PTY 时不直接 exec 用户 shell，按 shell 类型走对应的注入手法（见 §5）。
2. **OSC scanner**：扩展现有 `terminal_query::QueryScanner`（已用于 DA1 / OSC 10/11 等能力查询的"answer-and-strip"），把 motif 关心的 OSC 序列分类为：消费成事件（OSC 133 / 7770 / 7771 / 7）、passthrough（其它）。**不**另起一份 VTE 状态机。
3. **状态机**：每个 PTY 一份，跟踪 block 生命周期。
4. **BlockStore**：有界 ring buffer，记录最近若干 block 的元数据 + 截断输出。
5. **现有 pid polling cwd 跟踪保留**：作为未 bootstrap 的 shell（含 SSH 进入的远端 shell、不支持的 shell）的 fallback。OSC 7 收到时优先以 OSC 为准，pid polling 退为兜底。

`motifd` 内部新模块：

```
crates/motif-server/src/shell/
    mod.rs                  // 对外 API
    osc_parser.rs           // 扩展 QueryScanner
    state.rs                // BlockState
    block_store.rs          // ring buffer
    bootstrap.rs            // 脚本嵌入与 PTY 启动改写
crates/motif-server/assets/shell/
    bash.sh
    zsh.zsh
    fish.fish
```

## 4. Wire format（OSC 序列）

motif **复用** OSC 133（FinalTerm 标准），并占用一段未冲突的私有号段做扩展。OSC 编号原则：避开已知占用（Warp 9277-9280、VS Code 633、iTerm2 1337）；候选号段 **`7770-7779`**，最终值实现期 grep 一遍 xterm / iTerm2 / VS Code / Warp / WezTerm / alacritty / tmux 文档定。

| 序列 | 含义 | 触发点 |
|---|---|---|
| `ESC ] 133 ; A BEL` | prompt 开始 | precmd 钩子 |
| `ESC ] 133 ; B BEL` | prompt 结束（用户开始输入） | PS1 渲染完成 |
| `ESC ] 133 ; C BEL` | 命令开始执行（与 7770 同时发，命令文本走 7770） | preexec 钩子 |
| `ESC ] 133 ; D ; <exit> BEL` | 命令结束 | precmd 钩子（携带上一条命令的退出码） |
| `ESC ] 7 ; file://<host>/<path> BEL` | cwd 变更（**新增**） | precmd / chpwd |
| `ESC ] 7770 ; <hex_command> BEL` | preexec 命令文本（motif 自定义） | preexec 钩子 |
| `ESC ] 7771 ; <hex_json> BEL` | precmd 上下文包（git / venv / node / ...） | precmd 钩子 |

设计取舍：

- `7770` 单独把命令文本送上来，不依赖"从 PTY 回显里反推"。回显存在 ANSI / 折行 / 自动换行问题，反推不稳。
- `7771` 走一个一次性 JSON 包，扩展字段不影响协议号段。Hex 编码绕开 shell 字符串转义。
- OSC 7 是**新增**——现有 server 的 cwd 跟踪是 1.5s pid polling（`pty.cwd_changed`），shell hook 主动 emit OSC 7 后改由 server 即时触发同一事件，pid polling 退为 fallback。

## 5. Bootstrap 脚本与注入

### 5.1 注入手法

| Shell | 注入方式 |
|---|---|
| Bash | `bash --rcfile <(cat $MOTIF_BOOTSTRAP_BASH)` 或写入 `$BASH_ENV` 后 `--login` |
| Zsh | 设置 `ZDOTDIR=$MOTIF_BOOTSTRAP_DIR`，目录里放 `.zshrc` 包装用户原 zshrc |
| Fish | `fish --init-command "source $MOTIF_BOOTSTRAP_FISH"` |

`motifd` 启动时把脚本（`include_str!` 编入二进制）写到 `$XDG_RUNTIME_DIR/motif/shell-XXXXXX/`（macOS 退化到 `$TMPDIR`），spawn PTY 时按 shell 选对应路径注入。

注入失败 / 用户禁用 / 检测到不支持的 shell 时，PTY 退化为 v1 透明管道，server 端状态机停在 `Unknown`，不发 block 事件；pid polling cwd 跟踪继续工作。

### 5.2 脚本职责

每个 bootstrap 脚本要做的事：

1. 注册 `precmd` / `preexec` 钩子：
   - bash：用 [`rcaloras/bash-preexec`](https://github.com/rcaloras/bash-preexec)（MIT，直接 vendor 进二进制；DEBUG trap 边界已被它处理）
   - zsh：原生 hook 数组 `precmd_functions` / `preexec_functions`
   - fish：event handler，`function __motif_preexec --on-event fish_preexec` / `__motif_postexec --on-event fish_postexec`
2. 在 prompt 渲染前后吐出 `OSC 133;A` / `OSC 133;B`。
3. 在 preexec 里吐 `OSC 7770;<hex_cmd>` 和 `OSC 133;C`。
4. 在 precmd 里吐 `OSC 133;D;<exit>` 和 `OSC 7771;<hex_json>` 和 `OSC 7;file://...`。
5. 启用 bracketed paste（bash 的 `bind 'set enable-bracketed-paste on'` / zsh 默认开 / fish 默认开），多行 paste 时不立刻执行。
6. 设置 `MOTIF_BOOTSTRAPPED=1`、`MOTIF_SESSION_ID=<id>`、`MOTIF_SHELL=<bash|zsh|fish>` 等 env，方便用户脚本检测。
7. 兼容用户原 rcfile：source 完用户的 `.bashrc` / `.zshrc` / `config.fish`，不替代。

公共 helper（三套脚本各自实现）：

- `__motif_hex <text>`：把任意字节流编 hex（OSC 字符串转义）
- `__motif_emit_osc <num> <payload>`：拼 `\e]<num>;<payload>\a`

## 6. Server 状态机

每个 PTY 维护：

```rust
enum BlockState {
    Unknown,                                          // 未 bootstrap，或不支持的 shell
    AtPrompt   { since: Instant },                    // 收到 133;A 之后
    Composing  { prompt_started: Instant },           // 收到 133;B 之后
    Running    { block_id: BlockId,
                 cmd: String,
                 cwd: PathBuf,
                 started: Instant },                  // 收到 7770/133;C 之后
}
```

转移规则：

| 收到 | 当前 | → 新状态 | 副作用 |
|---|---|---|---|
| `133;A` | `Unknown` | `AtPrompt` | 广播 `pty.shell_bootstrapped`（首次） |
| `133;A` | `AtPrompt` / `Composing` | `AtPrompt` | （Ctrl-C 取消编辑、transient prompt 重绘等场景，幂等触发） |
| `133;A` | `Running` | `AtPrompt` | **强制 finalize 当前 block**：`exit_code = None`、写入 BlockStore、广播 `pty.command_finished`（覆盖 SIGINT 杀命令但 shell 没发 `133;D` 的场景） |
| `133;B` | `AtPrompt` | `Composing` | — |
| `7770;<cmd>` 或 `133;C` | `Composing` | `Running` | 分配 `block_id`，广播 `pty.command_started`。两者同时到达时第二个为幂等 no-op |
| `133;D;<exit>` | `Running` | `AtPrompt`（待下个 `133;A`） | 写入 BlockStore，广播 `pty.command_finished` |
| `7771;<json>` | * | (不变) | 广播 `pty.shell_context` |
| `7` (cwd) | * | (不变) | 广播 `pty.cwd_changed`（与现有 pid watcher 同事件，OSC 优先） |
| PTY EOF / `pty.exited` | * | `Unknown` | 现有 `pty.exited` 事件不变 |
| Spawn 后 5s 未收到任何 `133;*` | `Unknown` | `Unknown` | 广播 `pty.shell_bootstrapped { shell: "unknown" }`，client 知道不要再等 |

嵌套 shell（`bash -c bash`、`tmux`、`ssh remote`）：状态机不区分层级，按"最近一次"事件转移。SSH 远端 shell 没 bootstrap 时 inner OSC 流为空，状态停在进入 ssh 时的状态；ssh 退出后下一次 `133;A` 自然恢复。期间 pid polling 仍能跟踪 ssh 进程的 cwd。

## 7. 协议增量

> 命名遵循 `motif-proto` 的 snake_case wire 风格（参见 prd.md §14）。所有事件都带 `seq`。

### 7.1 新事件（server → client，broadcast）

```typescript
| { method: "pty.shell_bootstrapped"; params: { pty_id: PtyId; shell: "bash"|"zsh"|"fish"|"unknown"; session_id: number; seq: Seq } }
| { method: "pty.command_started";    params: { pty_id: PtyId; block_id: BlockId; text: string; cwd: string; started_at: number; seq: Seq } }
| { method: "pty.command_finished";   params: { pty_id: PtyId; block_id: BlockId; exit_code: number | null; finished_at: number; seq: Seq } }
| { method: "pty.shell_context";      params: { pty_id: PtyId; ctx: ShellContext; seq: Seq } }
```

```rust
pub struct ShellContext {
    pub branch: Option<String>,
    pub head:   Option<String>,
    pub venv:   Option<String>,
    pub conda:  Option<String>,
    pub node:   Option<String>,
    // 后续按需扩展，不破坏向后兼容
}
pub type BlockId = String;   // ULID，与 SessionId/ClientId 一致；规避 ts-rs 下 u64 精度问题
```

`ShellContext` 字段都是廉价能拿到的（git symbolic-ref / `$VIRTUAL_ENV` 等 env 变量）。昂贵的 context（kube context、aws profile）不在范围内，避免 precmd 钩子拖慢 prompt。

### 7.2 修改：`pty.output`

现有 `pty.output` 增加可选字段：

```typescript
{ method: "pty.output"; params: { pty_id: PtyId; data_b64: string; block_id?: BlockId | null; seq: Seq } }
```

`block_id`：当前 `Running` 状态下的 block id；`AtPrompt` / `Composing` / `Unknown` 时为 `null`。Web client 用此把字节流分配进对应的 block 卡片；TUI client 可忽略。

### 7.3 新 RPC（client → server）

```typescript
"pty.list_blocks"      { pty_id: PtyId; before?: BlockId; limit: number }   → { blocks: BlockSummary[] }
"pty.get_block_output" { pty_id: PtyId; block_id: BlockId }                 → { data_b64: string; truncated: boolean }
```

```rust
pub struct BlockSummary {
    pub id:               BlockId,
    pub cwd:              String,
    pub cmd:              String,
    pub started_at:       u64,
    pub finished_at:      Option<u64>,
    pub exit_code:        Option<i32>,
    pub output_size:      u64,
    pub output_truncated: bool,
}
```

`list_blocks` 语义：返回 id < `before` 的最近 `limit` 条，按 id 降序；`before` 不传时返回最新 `limit` 条（exclusive 边界）。

### 7.4 错误码增量

补到 prd.md §5 错误码列表：

- `BlockNotFound`：`get_block_output` 指定的 block 已被 ring buffer 滚出

### 7.5 序列化兼容性

新增的 `Event` 变体会让老 client 反序列化失败（`motif-proto::Event` 当前没 `#[serde(other)]` 兜底）。M-SI-1 同时给 `Event` 加 `#[serde(other)] Unknown` 兜底变体，避免 client / server 强升级耦合（v1 老 TUI 在 v2 server 上仍能运行，只是不识别新事件）。

## 8. Block 存储

每个 PTY 一份 ring buffer：

```rust
struct BlockStore {
    blocks:          VecDeque<Block>,    // FIFO，超 cap 弹最早
    cap_count:       usize,              // 默认 1000
    cap_total_bytes: u64,                // 默认 50 MiB
    next_id:         u64,                // 内部计数；对外暴露 ULID
}
struct Block {
    id:               BlockId,           // ULID
    cwd:              PathBuf,
    cmd:              String,
    started_at:       SystemTime,
    finished_at:      Option<SystemTime>,
    exit_code:        Option<i32>,
    output:           Vec<u8>,           // 原始字节，含 ANSI
    output_truncated: bool,              // 单 block 超过 1 MiB 截断尾部
}
```

容量参数走 `motifd` 配置，环境变量 / 命令行覆盖。被滚出的 block id 在 `get_block_output` 返回 `BlockNotFound`。

`get_block_output` 返回原始字节（含 ANSI），client 自渲染——保持简单。如有需要"纯文本复制"再加 server 端 strip，作为新 RPC 不破坏现有路径。

**未持久化**：进程重启 = block 历史丢失。session 持久化是 prd.md 的更大议题，本文档不展开。

## 9. Client 受益

| 客户端 | 用到的协议 | 不需要 |
|---|---|---|
| TUI | `command_started/finished` 状态栏命令 / 退出码着色，键绑跳上下条 block | 编辑器、补全 |
| Web | `command_started/finished` + `pty.output.block_id` 渲染只读 block 卡片；`shell_context` 渲染 prompt chip；`list_blocks/get_block_output` 后加入看历史 | xterm 输入直通不变 |

Web 端 block UI 是 xterm 包一层结构化壳：xterm scrollback 视图按 `block_id` 折叠 / 导航 / 复制。**用户输入仍直接进 xterm**（即 `pty.write` raw 字节），shell 自己处理补全 / 历史 / 多行编辑——避免重复造 GUI editor。

## 10. Milestones

每一步都能独立上线、独立验证。

### M-SI-1：Bootstrap + 基础事件 ✅

- ✅ bash / zsh / fish 三份脚本嵌入 `crates/motif-server/assets/shell/`（`rust-embed`）
- ✅ spawn PTY 时按 shell detect + 注入（`crates/motif-server/src/shell/bootstrap.rs`）
- ✅ `QueryScanner` 扩展识别 `133;A/B/C/D` + `7770` + `7771` + `7`，按 `ScanItem` 顺序保留 query/passthrough 时序
- ✅ BlockState 状态机 + 5s bootstrap 超时（`shell/state.rs`）
- ✅ 广播 `pty.shell_bootstrapped` / `pty.command_started` / `pty.command_finished` / `pty.shell_context`
- ✅ `pty.output` 加可选 `block_id` 字段
- ✅ OSC 7 收到时 emit `pty.cwd_changed`，pid polling 降为 fallback
- ✅ `motif-proto::Event` 加 `#[serde(other)] Unknown` 兜底变体
- ✅ TUI 状态栏 `▶ <cmd>` / `✓ 0` / `✗ N` chip + tab label `<cwd> · <fg>`

### M-SI-2：Block 历史 ✅

- ✅ BlockStore ring buffer（`shell/block_store.rs`，cap 1000 entries / 50 MiB total / 单 block 1 MiB）
- ✅ `pty.list_blocks` / `pty.get_block_output` RPC，错误码 `BlockNotFound`
- ✅ Web 端 `BlockList` 侧栏（attach 时 prefetch 最近 50 条，事件流增量维护）
- ✅ 选中 block 高亮 xterm scrollback：`PtyTab` 在 `command_started` / `finished` 时 register `IMarker`，store 的 `selectedBlock` 驱动 `scrollLines` + `registerDecoration` 染色
- ✅ TUI 跳上 / 下条 block 的 keybinding：`PtyView` 维护 `BlockMark { id, start_abs, end_abs }`，prefix `b` / `f`（含 Scroll mode 内）跳到 `prev_block_anchor` / `next_block_anchor`

### M-SI-3：兼容性打磨 ⏳

- ✅ Disable 开关：`MOTIF_SHELL_INTEGRATION=0` 跳过注入；状态机 5s 超时 emit `shell: "unknown"`
- ✅ BlockStore 容量走 env：`MOTIF_BLOCK_CAP_COUNT` / `MOTIF_BLOCK_CAP_BYTES`
- 🚧 兼容性 e2e 实测：oh-my-zsh、starship（zsh + bash）、powerlevel10k transient prompt（手动验证项）

## 11. 开放问题

1. **OSC 编号最终值**：`7770-7779` 是占位，实现期 grep 一遍 xterm / iTerm2 / VS Code / Warp / WezTerm / alacritty / tmux 的占用文档，挑确实空闲的号段。M-SI-1 验收前完成。
2. **过长 prompt / transient prompt 的处理**：powerlevel10k 等会重写 prompt 区域，`133;A` 可能在重绘里多次出现；状态机已设计成幂等触发（同状态自转移无副作用）。
3. **SSH 远程 shell**：用户在 motif PTY 里 `ssh remote` 之后远端 shell 没 bootstrap，block 跟踪自动停在最后状态；pid polling 仍能跟踪 ssh 进程的 cwd；ssh 退出后下一次 prompt 自然恢复。无需特殊处理。
4. **Block 输出 ANSI 处理**：`get_block_output` 返回原始字节（含 ANSI），client 自渲染——默认保持简单。如有需要"纯文本复制"再加 server 端 strip。
5. **Persisted history**：block ring buffer 落盘？v2 不落，与"session 持久化"耦合，等 prd 决策。

## 12. 与 v1 / v1.5 的衔接

- **不破坏 v1 协议**：所有新增都是新方法 + 新事件 + 现有事件可选字段。给 `motif-proto::Event` 加 `#[serde(other)]` 兜底变体后，client / server 不需强行同版本升级。
- **不破坏 web v1.5**：现有 xterm 输入 + diff 视图不变；Block UI 是新增 panel，灰度。Web client 仍是 xterm raw passthrough，**不**引入 GUI editor。
- **现有 cwd 跟踪不变**：`pty.cwd_changed` 事件保留语义，新增 OSC 7 触发路径；pid polling 退为兜底（未 bootstrap 的 shell / SSH 进入的远端 shell 仍能拿到 cwd）。
- **`motif-proto` 升级**：`BlockId`、`ShellContext`、新事件枚举走同一份 Rust → TS 派生（`ts-rs`）。
- **TUI 受益但不需要重写**：M-SI-1 之后 TUI 拿到事件就能做小改进（命令边界提示、退出码着色），M-SI-2 之后能做 block 跳转。
- **不绑死任何具体 shell**：协议层只关心"是不是有 OSC"，不预设 bash / zsh / fish 之外的 shell。后续可加 nushell / xonsh / pwsh 的 bootstrap，协议不变。
