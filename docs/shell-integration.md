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
- **shell hook 优先，pid polling fallback**：bootstrap 成功的 shell 用私有
  OSC 属性即时 emit `pty.cwd_changed`；未 bootstrap 的 shell（旧版本、SSH 远端、不
  支持的 shell）走 1.5s pid polling 兜底。
- **可关闭**：`MOTIF_SHELL_INTEGRATION=0` 跳过注入，PTY 退化为透明字节管道。

---

## 2. OSC 序列

motif 主协议使用一个私有 OSC code：`777`。形态参考 VS Code 的 `OSC 633`：
生命周期子命令走 `A/B/C/D`，显式命令文本走 `E`，属性包走 `P`。旧的
FinalTerm `133`、`OSC 7`、`7770`、`7771` 只作为兼容输入继续解析，bootstrap
不再主动发它们。

| 序列 | 含义 | 触发点 |
| --- | --- | --- |
| `ESC ] 777 ; A BEL` | prompt 开始 | precmd / prompt wrapper |
| `ESC ] 777 ; B BEL` | prompt 结束（用户开始输入） | PS1 渲染完成 |
| `ESC ] 777 ; E ; <hex_command> BEL` | preexec 命令文本 | preexec 钩子 |
| `ESC ] 777 ; C BEL` | 命令开始执行 | preexec 钩子 |
| `ESC ] 777 ; D ; <exit> BEL` | 命令结束 | 下一次 precmd / postexec |
| `ESC ] 777 ; P ; Cwd=file://<host>/<path> BEL` | cwd 变更 | precmd / chpwd |
| `ESC ] 777 ; P ; Context=<hex_json> BEL` | shell 上下文包（git / venv / node / ...） | precmd / prompt wrapper |

设计取舍：

- 单个私有 code 避免“FinalTerm code + Motif code”混用，协议形态和 VS Code
  的 shell integration 一致，但不占用 VS Code 的 `633`。
- `777;E` 把命令文本独立送上来，不依赖从 PTY 回显反推（回显有 ANSI / 折行 /
  自动换行问题，反推不稳）。
- `777;P` 承载可扩展属性。`Context=<hex_json>` 走一次性 JSON 包，Hex 编码绕开
  shell 字符串转义；`Cwd=...` 与 pid polling 出同一个 `pty.cwd_changed` 事件。

### 2.1 兼容输入

parser 继续识别旧协议，便于旧 bootstrap、远端 shell 或 fish/iTerm2 自带 marker
混入时不破坏状态机：

| 形态 | 等价于 | 见于 |
| --- | --- | --- |
| `ESC ] 133 ; A ; click_events=1 ST` | `133;A` | fish 4.x（每次 prompt） |
| `ESC ] 133 ; A ; aid=<n> ST` | `133;A` | iTerm2 兼容广播 |
| `ESC ] 133 ; C ; cmdline_url=<percent> ST` | `133;C` | fish 4.x（每次 Enter） |
| `ESC ] 133 ; D ; <exit> ; <key=val>... ST` | `133;D;<exit>` | iTerm2 / 各家扩展 |
| `ESC ] 7 ; file://<host>/<path> ST` | `777;P;Cwd=...` | 通用 cwd marker |
| `ESC ] 7770 ; <hex_command> ST` | `777;E;<hex_command>` | Motif 旧 bootstrap |
| `ESC ] 7771 ; <hex_json> ST` | `777;P;Context=<hex_json>` | Motif 旧 bootstrap |

`133;C` 上的 `cmdline_url=<percent>` 仍会被消费，优先级高于 pending 的显式命令
文本；其它 `key=value` 项忽略并随同 OSC 一起剥离。`133;<未知子命令>` 继续
passthrough，保留前向兼容。

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
2. 在 prompt 渲染前后吐出 `OSC 777;A` / `OSC 777;B`。bash/zsh 依赖 hook 的
   prompt 前/后锚点；fish 用 prompt function wrapper 夹住真实 `fish_prompt`
   输出，避免 `fish_prompt` event 早于 PS1 paint 的问题。
3. 在 preexec 里吐 `OSC 777;E;<hex_cmd>` 和 `OSC 777;C`。若 fish 或其它 shell
   同时发出旧的 `133;C;cmdline_url=<percent>`，状态机会优先用 `cmdline_url`，
   并在 `D` 边界清空 late pending command，避免串到下一轮。
4. 在 precmd / postexec 里吐 `OSC 777;D;<exit>`、`OSC 777;P;Context=<hex_json>`、
   `OSC 777;P;Cwd=file://...`。
5. 启用 bracketed paste（bash 的 `bind 'set enable-bracketed-paste on'` / zsh
   默认开 / fish 默认开），多行 paste 时不立刻执行。
6. 设置 `MOTIF_BOOTSTRAPPED=1`、`MOTIF_SESSION_ID=<id>`、`MOTIF_SHELL=<bash|zsh|fish>`
   等 env，方便用户脚本检测。
7. 兼容用户原 rcfile：source 完用户的 `.bashrc` / `.zshrc` / `config.fish`，
   不替代。

公共 helper（三套脚本各自实现）：

- `__motif_hex <text>`：把任意字节流编 hex。
- `__motif_emit_si <sub> [payload]`：拼 `\e]777;<sub>[;<payload>]\a`。

---

## 4. Server 状态机

每个 PTY 一份 `BlockState`。`block_id` 在进入 `AtPrompt` 时分配，从此刻起
所有该 PTY 的 `pty.output` 都带这个 id —— 直到该 block `777;D` 进 BlockStore
后状态降回 `Unknown`，下一次 `777;A` 再分配新 id。**不变量**:任何带非空
`block_id` 的 `pty.output` 之前都已经广播过对应的 `pty.prompt_started`。
fish 等 prompt 重绘**不**换 id —— 不论从 `AtPrompt` 还是 `Composing` 自循环
都视作 redraw,只清 prompt buffer。

`777;D` 之后到下一次 `777;A` 之间的 housekeeping 字节(fish 改窗口标题
`OSC 0`、bracketed paste 模式开关、kitty kbd 协议握手等)以
`block_id=null, scope=passthrough` 流给客户端 —— 跟 spawn 后到第一次
`777;A` 之间的 fish welcome banner 以及 `MOTIF_SHELL_INTEGRATION=0`
的纯透明 PTY 走同一条路径,不绑定到任何 block。

```rust
enum BlockState {
    Unknown,                                                  // pre-bootstrap
    AtPrompt   { block_id: BlockId, prompt_buf: Vec<u8> },
    Composing  { block_id: BlockId, prompt_buf: Vec<u8>, command_buf: Vec<u8> },
    Running {
        block_id:           BlockId,
        cmd:                String,        // 777;E 显式命令文本；兼容 133;C cmdline_url
        cwd:                PathBuf,
        started_at:         Instant,       // 进入 Running(777;C)那一刻;不是 prompt paint 时间
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
| `777;A` | `Unknown` | `AtPrompt { id: NEW, prompt_buf: [] }` | 首次广播 `pty.shell_bootstrapped`；广播 `pty.prompt_started { block_id: NEW }` |
| `777;A` | `AtPrompt { id }` | `AtPrompt { id: SAME, prompt_buf: [] }` | 重绘：id 不变，清 prompt_buf；广播 `pty.prompt_started { block_id: id }` |
| `777;A` | `Composing { id, prompt, command }` | `AtPrompt { id: SAME, prompt_buf: [] }` | 重绘：id 不变，清 prompt_buf 与 command_buf；广播 `pty.prompt_started { block_id: id }`。**不**合成 CommandStarted/Finished |
| `777;A` | `Running { id, ... }` | `AtPrompt { id: NEW, prompt_buf: [] }` | 旧 id 强制 finalize（`exit_code = None`），写入 BlockStore；广播 `pty.command_finished { block_id: id, exit_code: null }`；广播 `pty.prompt_started { block_id: NEW }` |
| `777;B` | `AtPrompt { id, prompt_buf }` | `Composing { id, prompt_buf, command_buf: [] }` | 广播 `pty.prompt_ended { block_id: id }` |
| `777;E;<hex_cmd>` | * | (不变) | 暂存显式命令文本，供下一次 `777;C` 消费 |
| `777;C` | `Composing { id, prompt_buf, command_buf }` | `Running { id, prompt: prompt_buf, command: command_buf, ... }` | 广播 `pty.command_started { block_id: id, text, cwd, ... }` |
| `777;D;<exit>` | `Running { id, ... }` | `Unknown` | 旧 id 写入 BlockStore；广播 `pty.command_finished { block_id: id, exit_code: <exit> }`；下一次 `777;A` 走 `Unknown→AtPrompt` 分支分配新 id 并广播 `pty.prompt_started`,中间的 housekeeping 字节以 `block_id=null` 流走 |
| `777;P;Context=<hex_json>` | * | (不变) | 广播 `pty.shell_context` |
| `777;P;Cwd=...` | * | (不变) | 广播 `pty.cwd_changed`（OSC 优先，pid watcher 退为 fallback） |
| 字节 passthrough | `Unknown` | (不变) | 不缓冲；广播 `pty.output { block_id: null, scope: "passthrough" }` |
| 字节 passthrough | `AtPrompt { id }` | (不变) | 追加到 `prompt_buf`；广播 `pty.output { block_id: id, scope: "prompt" }` |
| 字节 passthrough | `Composing { id }` | (不变) | 追加到 `command_buf`；广播 `pty.output { block_id: id, scope: "command" }` |
| 字节 passthrough | `Running { id }` | (不变) | 追加到 `output`；广播 `pty.output { block_id: id, scope: "output" }` |
| PTY EOF | * | `Unknown` | `Running` 时强制 finalize；`AtPrompt` / `Composing` 时丢弃当前 block（未 commit） |
| spawn 后 5s 未收任何 shell-integration marker | `Unknown` | `Unknown` | 广播 `pty.shell_bootstrapped { shell: "unknown" }` |

每段缓冲单独 cap 在 1 MiB，超出截断尾部并置 `*_truncated=true`。

要点：

- **每个 `777;A` 边界都广播 `pty.prompt_started`**（含重绘）；client 用它做
  "PS1 开始绘制，重置渲染器"信号。重绘时 block_id 与上一次相同；其它情况
  block_id 是新 id（前一条 `pty.command_finished` / `pty.shell_bootstrapped`
  把旧 id 收尾,中间可能夹一段 `block_id=null` 的 housekeeping 字节）。
- **空 Enter / Ctrl-C 取消编辑 / fish autosuggestion repaint 都走"redraw"
  路径**:server 视角看到的都是 `Composing → 777;A`,无法区分意图。统一保留
  block_id、清 prompt + command buffer、不广播任何 CommandStarted/Finished、
  不入库。结果是这些事件在 UI 上完全静默,不再像旧版那样为每次按键产出一张
  空 block 卡片。下游真有命令运行时会走 `Composing → 777;C` 的正常路径生成
  block。
- **嵌套 shell**（`bash -c bash`、`tmux`、`ssh remote`）：状态机不区分层级，
  按"最近一次"事件转移。SSH 远端 shell 没 bootstrap 时 inner OSC 流为空，
  状态停在进入 ssh 时的状态；ssh 退出后下一次 `777;A` 自然恢复。pid polling
  仍能跟踪 ssh 进程的 cwd。

---

## 5. BlockStore

每个 PTY 一份 ring buffer。**只有走过 `777;D` 或被强制 finalize（`Running →
777;A`,SIGINT 跳过 `777;D` 时）的 block 才入库**——prompt 重绘(`AtPrompt
→ 777;A` / `Composing → 777;A`)不入库。

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
