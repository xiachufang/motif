# Motif — Shell Integration

motifd 给每个新建的 PTY 注入一段 shell bootstrap 脚本，让 shell 在 prompt /
preexec / precmd 边界发出 OSC 标记。服务端 OSC scanner 把这些标记拆成结构化
*block*（命令 + 输出 + 退出码 + cwd + git/venv 等上下文）。Web/TUI client 在
协议之上叠加只读 block UI，输入仍是 PTY raw 字节直通——**不**做 GUI 行编辑器、
不做协同编辑、不做补全 / 历史 RPC。

协议形态见 `rpc.md`：
- §6 Block 模型与三段字节流（prompt / command / output）+ `OutputScope`
- §7.3-7.4 PTY 推送事件
- 错误码 `BlockNotFound`

本文档讲**机制**：OSC 序列、bootstrap 注入、状态机、BlockStore。

---

## 1. 设计原则

- **server 是唯一真相源**：所有 client 共享同一份 block 列表，TUI/Web/未来
  GUI 不各自重写 OSC parser。
- **bootstrap 透明**：默认 PTY 行为 = 老 PTY 体验 + 多出来的元数据；vim/htop/
  SSH/tmux 等正常工作。
- **shell hook 优先，pid polling fallback**：bootstrap 成功的 shell 用 OSC 7
  即时 emit `pty.cwd_changed`；未 bootstrap 的 shell（旧版本、SSH 远端、不
  支持的 shell）走 1.5s pid polling 兜底。
- **可关闭**：`MOTIF_SHELL_INTEGRATION=0` 跳过注入，PTY 退化为透明字节管道。

---

## 2. OSC 序列

motif **复用** FinalTerm OSC 133，加一段私有号段 `7770-7779`。

| 序列 | 含义 | 触发点 |
| --- | --- | --- |
| `ESC ] 133 ; A BEL` | prompt 开始 | precmd 钩子 |
| `ESC ] 133 ; B BEL` | prompt 结束（用户开始输入） | PS1 渲染完成 |
| `ESC ] 133 ; C BEL` | 命令开始执行 | preexec 钩子 |
| `ESC ] 133 ; D ; <exit> BEL` | 命令结束 | 下一次 precmd 钩子 |
| `ESC ] 7 ; file://<host>/<path> BEL` | cwd 变更 | precmd / chpwd |
| `ESC ] 7770 ; <hex_command> BEL` | preexec 命令文本 | preexec 钩子 |
| `ESC ] 7771 ; <hex_json> BEL` | precmd 上下文包（git / venv / node / ...） | precmd 钩子 |

设计取舍：

- `7770` 把命令文本独立送上来，不依赖从 PTY 回显反推（回显有 ANSI / 折行 /
  自动换行问题，反推不稳）。
- `7771` 走一次性 JSON 包，扩展字段不影响协议号段。Hex 编码绕开 shell 字符串
  转义。
- OSC 7 与 motifd 的 1.5s pid polling 出同一个事件（`pty.cwd_changed`）；OSC
  到达即立即触发，pid polling 退为 fallback。

### 2.1 扩展参数（FinalTerm 之外）

真实 shell 会在标准子命令之后挂 `;key=value` 参数,parser 必须识别这些边界
否则状态机会卡住:

| 形态 | 等价于 | 见于 |
| --- | --- | --- |
| `ESC ] 133 ; A ; click_events=1 ST` | `133;A` | fish 4.x（每次 prompt） |
| `ESC ] 133 ; A ; aid=<n> ST` | `133;A` | iTerm2 兼容广播 |
| `ESC ] 133 ; C ; cmdline_url=<percent> ST` | `133;C` | fish 4.x（每次 Enter） |
| `ESC ] 133 ; D ; <exit> ; <key=val>... ST` | `133;D;<exit>` | iTerm2 / 各家扩展 |

motif 用 `<sub>` 字段做状态转移,`133;C` 上额外消费 `cmdline_url=<percent>`
(优先级高于 OSC 7770 — 见 §3.2 step 3 的时序解释),其它 `key=value` 项忽略
并随同 OSC 一起从字节流剥离。`133;<未知子命令>`(`E` / `P` / ...)继续
passthrough,保留前向兼容。

---

## 3. Bootstrap 脚本

### 3.1 注入手法

| Shell | 注入方式 |
| --- | --- |
| Bash | `bash --rcfile <(cat $MOTIF_BOOTSTRAP_BASH)` 或写入 `$BASH_ENV` 后 `--login` |
| Zsh | 设置 `ZDOTDIR=$MOTIF_BOOTSTRAP_DIR`，目录里放 `.zshrc` 包装用户原 zshrc |
| Fish | `fish --init-command "source $MOTIF_BOOTSTRAP_FISH"` |

`motifd` 启动时把脚本（`include_str!` 编入二进制）写到
`$XDG_RUNTIME_DIR/motif/shell-XXXXXX/`（macOS 退化到 `$TMPDIR`），spawn PTY 时
按 shell 选对应路径注入。

注入失败 / 用户禁用 / 检测到不支持的 shell 时，PTY 退化为透明字节管道，
状态机停在 `Unknown`，不发 block 事件；pid polling cwd 跟踪继续工作。

### 3.2 脚本职责

每个 bootstrap 脚本要做：

1. 注册钩子：
   - bash：vendor [`rcaloras/bash-preexec`](https://github.com/rcaloras/bash-preexec)（MIT，DEBUG trap 边界已被它处理）
   - zsh：原生 hook 数组 `precmd_functions` / `preexec_functions`
   - fish：event handler，`function __motif_preexec --on-event fish_preexec` / `__motif_postexec --on-event fish_postexec`
2. 在 prompt 渲染前后吐出 `OSC 133;A` / `OSC 133;B`。**注意 fish ≥ 4.0 会原生发
   `133;A;click_events=1` / `133;B`**,这种情况下 motif 的 `__motif_prompt` 钩
   子(它在 `fish_prompt` event 上,触发时机在 PS1 实际渲染**之前**)就**不能
   再发 `133;A`/`133;B`** —— 否则 motif 的 `133;B` 会先于 PS1 字节到达,把状
   态机切到 Composing,导致 PS1 字节被错记进 `command_buf`(BlockStore 里
   prompt 段为空,backfill 退化成 `$ X`)。`fish.fish` 用 `$FISH_VERSION` 做
   gating,fish 4.x 上完全交给 native;fish 3.x 才发自家的。bash/zsh 不存在这
   问题,因为 bash-preexec 和 zsh `precmd_functions` 都暴露明确的 "PS1 之
   前/之后" 锚点,我们的 `133;A`/`133;B` 能精准夹住 PS1 paint。
3. 在 preexec 里吐 `OSC 7770;<hex_cmd>` 和 `OSC 133;C`。**注意 fish 4.x 的
   native `133;C;cmdline_url=<percent>` 在 `fish_preexec` event **之前**
   fire**(见 fish-shell `reader/reader.rs:858-862`:`Osc133CommandStart`
   先 write,然后 `event::fire_generic(... fish_preexec ...)`)。也就是说
   motif 的 `__motif_preexec`(连同它发的 7770 + 133;C)**晚于** fish 的
   native 133;C 到达字节流。状态机的处理:
   - native 133;C(带 `cmdline_url`):`Composing → Running`,**优先用
     cmdline_url 作为 cmd**,清空 `pending_cmd`,广播 CommandStarted。
   - motif 的 7770:把 `pending_cmd` 设为 hex 解码值(状态已 Running,本周
     期不再消费,作为 bash/zsh 等无 cmdline_url 的 shell 的兜底)。
   - motif 的 bare 133;C:状态 Running → idempotent fall-through,不重复
     广播。

   在 bash / zsh 上没有 native `133;C;cmdline_url`,只有 motif 自己的 7770
   + 133;C 顺序到达,走 `pending_cmd` 兜底路径,行为不变。
4. 在 precmd 里吐 `OSC 133;D;<exit>` + `OSC 7771;<hex_json>` + `OSC 7;file://...`。
5. 启用 bracketed paste（bash 的 `bind 'set enable-bracketed-paste on'` / zsh
   默认开 / fish 默认开），多行 paste 时不立刻执行。
6. 设置 `MOTIF_BOOTSTRAPPED=1`、`MOTIF_SESSION_ID=<id>`、`MOTIF_SHELL=<bash|zsh|fish>`
   等 env，方便用户脚本检测。
7. 兼容用户原 rcfile：source 完用户的 `.bashrc` / `.zshrc` / `config.fish`，
   不替代。

公共 helper（三套脚本各自实现）：

- `__motif_hex <text>`：把任意字节流编 hex。
- `__motif_emit_osc <num> <payload>`：拼 `\e]<num>;<payload>\a`。

---

## 4. Server 状态机

每个 PTY 一份 `BlockState`。`block_id` 在进入 `AtPrompt` 时分配，从此刻起
所有该 PTY 的 `pty.output` 都带这个 id —— 直到该 block `133;D` 进 BlockStore
后状态降回 `Unknown`，下一次 `133;A` 再分配新 id。**不变量**:任何带非空
`block_id` 的 `pty.output` 之前都已经广播过对应的 `pty.prompt_started`。
fish 等 prompt 重绘**不**换 id —— 不论从 `AtPrompt` 还是 `Composing` 自循环
都视作 redraw,只清 prompt buffer。

`133;D` 之后到下一次 `133;A` 之间的 housekeeping 字节(fish 改窗口标题
`OSC 0`、bracketed paste 模式开关、kitty kbd 协议握手等)以
`block_id=null, scope=passthrough` 流给客户端 —— 跟 spawn 后到第一次
`133;A` 之间的 fish welcome banner 以及 `MOTIF_SHELL_INTEGRATION=0`
的纯透明 PTY 走同一条路径,不绑定到任何 block。

```rust
enum BlockState {
    Unknown,                                                  // pre-bootstrap
    AtPrompt   { block_id: BlockId, prompt_buf: Vec<u8> },
    Composing  { block_id: BlockId, prompt_buf: Vec<u8>, command_buf: Vec<u8> },
    Running {
        block_id:           BlockId,
        cmd:                String,        // OSC 133;C cmdline_url 优先,7770 兜底
        cwd:                PathBuf,
        started_at:         Instant,       // 进入 Running(133;C)那一刻;不是 prompt paint 时间
        prompt:             Vec<u8>,       // 自 Composing.prompt_buf
        prompt_truncated:   bool,
        command:            Vec<u8>,       // 自 Composing.command_buf
        command_truncated:  bool,
        output:             Vec<u8>,
        output_truncated:   bool,
    },
}
```

OSC 转移规则：

| 收到 | 当前 | → 新状态 | 副作用 |
| --- | --- | --- | --- |
| `133;A` | `Unknown` | `AtPrompt { id: NEW, prompt_buf: [] }` | 首次广播 `pty.shell_bootstrapped`；广播 `pty.prompt_started { block_id: NEW }` |
| `133;A` | `AtPrompt { id }` | `AtPrompt { id: SAME, prompt_buf: [] }` | 重绘：id 不变，清 prompt_buf；广播 `pty.prompt_started { block_id: id }` |
| `133;A` | `Composing { id, prompt, command }` | `AtPrompt { id: SAME, prompt_buf: [] }` | 重绘：id 不变，清 prompt_buf 与 command_buf（fish 4.x 每次按键都走这条边）；广播 `pty.prompt_started { block_id: id }`。**不**合成 CommandStarted/Finished |
| `133;A` | `Running { id, ... }` | `AtPrompt { id: NEW, prompt_buf: [] }` | 旧 id 强制 finalize（`exit_code = None`），写入 BlockStore；广播 `pty.command_finished { block_id: id, exit_code: null }`；广播 `pty.prompt_started { block_id: NEW }` |
| `133;B` | `AtPrompt { id, prompt_buf }` | `Composing { id, prompt_buf, command_buf: [] }` | 广播 `pty.prompt_ended { block_id: id }` |
| `133;C` | `Composing { id, prompt_buf, command_buf }` | `Running { id, prompt: prompt_buf, command: command_buf, ... }` | 广播 `pty.command_started { block_id: id, text, cwd, ... }` |
| `133;D;<exit>` | `Running { id, ... }` | `Unknown` | 旧 id 写入 BlockStore；广播 `pty.command_finished { block_id: id, exit_code: <exit> }`；下一次 `133;A` 走 `Unknown→AtPrompt` 分支分配新 id 并广播 `pty.prompt_started`,中间的 housekeeping 字节以 `block_id=null` 流走 |
| `7771;<json>` | * | (不变) | 广播 `pty.shell_context` |
| `7` (cwd) | * | (不变) | 广播 `pty.cwd_changed`（OSC 优先，pid watcher 退为 fallback） |
| 字节 passthrough | `Unknown` | (不变) | 不缓冲；广播 `pty.output { block_id: null, scope: "passthrough" }` |
| 字节 passthrough | `AtPrompt { id }` | (不变) | 追加到 `prompt_buf`；广播 `pty.output { block_id: id, scope: "prompt" }` |
| 字节 passthrough | `Composing { id }` | (不变) | 追加到 `command_buf`；广播 `pty.output { block_id: id, scope: "command" }` |
| 字节 passthrough | `Running { id }` | (不变) | 追加到 `output`；广播 `pty.output { block_id: id, scope: "output" }` |
| PTY EOF | * | `Unknown` | `Running` 时强制 finalize；`AtPrompt` / `Composing` 时丢弃当前 block（未 commit） |
| spawn 后 5s 未收任何 `133;*` | `Unknown` | `Unknown` | 广播 `pty.shell_bootstrapped { shell: "unknown" }` |

每段缓冲单独 cap 在 1 MiB，超出截断尾部并置 `*_truncated=true`。

要点：

- **每个 `133;A` 边界都广播 `pty.prompt_started`**（含重绘）；client 用它做
  "PS1 开始绘制，重置渲染器"信号。重绘时 block_id 与上一次相同；其它情况
  block_id 是新 id（前一条 `pty.command_finished` / `pty.shell_bootstrapped`
  把旧 id 收尾,中间可能夹一段 `block_id=null` 的 housekeeping 字节）。
- **空 Enter / Ctrl-C 取消编辑 / fish autosuggestion repaint 都走"redraw"
  路径**:server 视角看到的都是 `Composing → 133;A`,无法区分意图。统一保留
  block_id、清 prompt + command buffer、不广播任何 CommandStarted/Finished、
  不入库。结果是这些事件在 UI 上完全静默,不再像旧版那样为每次按键产出一张
  空 block 卡片。下游真有命令运行时会走 `Composing → 133;C` 的正常路径生成
  block。
- **嵌套 shell**（`bash -c bash`、`tmux`、`ssh remote`）：状态机不区分层级，
  按"最近一次"事件转移。SSH 远端 shell 没 bootstrap 时 inner OSC 流为空，
  状态停在进入 ssh 时的状态；ssh 退出后下一次 `133;A` 自然恢复。pid polling
  仍能跟踪 ssh 进程的 cwd。

---

## 5. BlockStore

每个 PTY 一份 ring buffer。**只有走过 `133;D` 或被强制 finalize（`Running →
133;A`,SIGINT 跳过 `133;D` 时）的 block 才入库**——prompt 重绘(`AtPrompt
→ 133;A` / `Composing → 133;A`)不入库。

```rust
struct BlockStore {
    blocks:          VecDeque<Block>,    // FIFO，超 cap 弹最早
    cap_count:       usize,              // 默认 1000
    cap_total_bytes: u64,                // 默认 50 MiB
}

struct Block {
    id:               BlockId,
    cwd:              PathBuf,
    cmd:              String,
    started_at:       SystemTime,
    finished_at:      SystemTime,
    exit_code:        Option<i32>,

    prompt:            Vec<u8>,
    prompt_truncated:  bool,
    command:           Vec<u8>,
    command_truncated: bool,
    output:            Vec<u8>,
    output_truncated:  bool,
}
```

容量参数走环境变量：`MOTIF_BLOCK_CAP_COUNT` / `MOTIF_BLOCK_CAP_BYTES`。被滚出
的 block id 在 `pty.get_block_output` 返回 `BlockNotFound`。

`get_block_output` 三段都返回原始字节（含 ANSI），客户端按 §6 模型自渲染——
保持简单。如有需要"纯文本复制"再加 server 端 strip，作为新 RPC 不破坏现有
路径。

**未持久化**：进程重启 = block 历史丢失。session 持久化是更大的议题，本文档
不展开。

---

## 6. Client 渲染策略

- TUI：用 `pty.command_started/finished` 做状态栏命令 / 退出码着色；
  `prev_block` / `next_block` 跳转 keybinding 用 BlockId 锚点 + xterm scrollback。
- Web：xterm 包一层结构化壳，按 `(block_id, scope)` 把字节路由到不同子终端：
  - `scope: "prompt"` / `"command"` → 浮动 prompt 渲染器（FloatTerm）
  - `scope: "output"` → 对应 `block_id` 的子终端（BlockTerm）
  - `block_id: null` → 普通透明终端（未 bootstrap 的 PTY）

  `pty.prompt_started` 携带的 `block_id` 是"从现在起 `pty.output` 字节将带的
  id"的预告，client 可在这个边界提前为新 block 准备渲染槽位。

  Backfill 时 `pty.list_blocks` 拿元数据 + `pty.get_block_output` 拿三段字节，
  把 `prompt + command + output` 依次喂给同一个 headless xterm 序列化为 HTML——
  与实时观看完全一致。

  用户输入仍是 `pty.write` raw 字节直通，shell 自己处理补全 / 历史 / 多行编辑。
