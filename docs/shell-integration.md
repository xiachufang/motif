# Motif — Shell Integration

motifd 给每个新建的 PTY 注入一段 shell bootstrap 脚本，让 shell 在 prompt /
preexec / precmd 边界发出 OSC 标记。服务端**只**做 bootstrap 注入 + 把
master 的原始字节通过 `WS /pty/<id>` 直通广播；OSC 解析与 block 合成由
**客户端**自己跑（见 `crates/motif-client/src/shell_integration.rs:1`）。
TUI / 未来 Web 各自吃同一份字节流，按本地状态机拼出 *block*（命令 + 输出 +
退出码 + cwd + git/venv 等上下文）。输入仍是 PTY raw 字节直通——**不**做 GUI
行编辑器、不做协同编辑、不做补全 / 历史 RPC。

本文档讲**机制**：OSC 序列、bootstrap 注入、状态机。bootstrap 脚本和 OSC
线协议是 *唯一真相源*；同一份字节流喂给任意客户端都应该跑出同一组 block。
共享的 wire 类型（`ShellKind` / `ShellContext` / `OutputScope` /
`BlockSummary` / `BlockId` / `ListBlocksParams` / `ListBlocksResult` /
`GetBlockOutputParams` / `GetBlockOutputResult`）定义在
`crates/motif-proto/src/pty.rs:1`，由客户端代码构造，没有对应的 server
RPC。

---

## 1. 设计原则

- **bootstrap + OSC 线协议是唯一真相源**：服务端只注入脚本、转发字节
  （`crates/motif-server/src/shell/bootstrap.rs:1`、
  `crates/motif-server/src/pty.rs:545`）。客户端各自把同一份字节流跑过
  本地状态机，理论上应该拼出同一组 block；OSC parser 只在客户端实现一份
  （`crates/motif-client/src/shell_integration.rs:1`），不在服务端再写一份。
- **bootstrap 透明**：默认 PTY 行为 = 老 PTY 体验 + 多出来的元数据；vim/htop/
  SSH/tmux 等正常工作。
- **shell hook 是唯一 cwd 来源**：bootstrap 成功的 shell 用私有 OSC 属性即时
  emit cwd 变更。未 bootstrap 的 shell（旧版本、SSH 远端、不支持的 shell）
  没有 cwd 信号——bootstrap 没成功的 PTY 状态机停在 `Unknown`，根目录回退到
  session.workdir。服务端的 pid 轮询机制在协议改造时被移除（曾经服务端发
  `pty.cwd_changed`，现在 cwd 完全是客户端 OSC 派生事件）。
- **可关闭**：`MOTIF_SHELL_INTEGRATION=0` 跳过注入
  （`crates/motif-server/src/shell/bootstrap.rs:56`），PTY 退化为透明字节
  管道；客户端 5s 超时后把 shell 标成 `Unknown`，停止产出 block 事件
  （`crates/motif-client/src/shell_integration.rs:522`）。

---

## 2. OSC 序列

motif 主协议使用一个私有 OSC code：`777`。形态参考 VS Code 的 `OSC 633`：
生命周期子命令走 `A/B/C/D`，显式命令文本走 `E`，属性包走 `P`。FinalTerm
`133` 与 `OSC 7` 作为兼容输入解析（外部 shell 如 fish 4.x 会原生发），
bootstrap 不主动发它们。

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
  shell 字符串转义；`Cwd=...` 由客户端 OSC parser 翻成
  `ShellEvent::CwdChanged`（参见 §4）。

### 2.1 兼容输入

parser 继续识别业界标准 marker，便于远端 shell 或 fish/iTerm2 自带 marker
混入时不破坏状态机：

| 形态 | 等价于 | 见于 |
| --- | --- | --- |
| `ESC ] 133 ; A ; click_events=1 ST` | `133;A` | fish 4.x（每次 prompt） |
| `ESC ] 133 ; A ; aid=<n> ST` | `133;A` | iTerm2 兼容广播 |
| `ESC ] 133 ; C ; cmdline_url=<percent> ST` | `133;C` | fish 4.x（每次 Enter） |
| `ESC ] 133 ; D ; <exit> ; <key=val>... ST` | `133;D;<exit>` | iTerm2 / 各家扩展 |
| `ESC ] 7 ; file://<host>/<path> ST` | `777;P;Cwd=...` | 通用 cwd marker |

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
客户端状态机停在 `Unknown`，不产出 block 事件，也没有 cwd 信号——这种 PTY
的根目录由 session.workdir 决定，不会跟随 shell 内部 `cd`。

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

## 4. 客户端状态机

实现见 `crates/motif-client/src/shell_integration.rs:120`。每个 PTY 一份
`BlockState`。`block_id` 在进入 `AtPrompt` 时分配，从此刻起到该 block 收到
`777;D`、状态降回 `Unknown` 之前，PTY master 的字节都被记为属于这个 id；下
一次 `777;A` 再分配新 id。**不变量**：任何 `ShellState::active_block_id()`
为 `Some(id)` 的字节产出前，状态机都已经发过对应的
`ShellEvent::PromptStarted { block_id: id }`。fish 等 prompt 重绘**不**换 id
——不论从 `AtPrompt` 还是 `Composing` 自循环都视作 redraw，只清 prompt buffer。

每次 OSC marker 到达，`ShellState::on_osc(QueryKind)` 返回 `Vec<ShellEvent>`
（in-process Rust 枚举，不是 JSON-RPC 通知）；调用方 (motif-tui 的
`apply_shell_event` / 未来 Web client) 直接消费这些值驱动本地 UI。原始
PTY 字节走 `/pty/<id>` WebSocket 二进制帧，每客户端自行决定怎么渲染——
没有"服务端先解析再合成事件"的中间层。

`777;D` 之后到下一次 `777;A` 之间的 housekeeping 字节（fish 改窗口标题
`OSC 0`、bracketed paste 模式开关、kitty kbd 协议握手等）此时
`ShellState::active_block_id()` 为 `None`、`active_scope()` 为
`Passthrough` ——跟 spawn 后到第一次 `777;A` 之间的 fish welcome banner
以及 `MOTIF_SHELL_INTEGRATION=0` 的纯透明 PTY 走同一条路径，不绑定到任
何 block（`crates/motif-client/src/shell_integration.rs:163`）。

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

OSC 转移规则（"emits" 指 `ShellState::on_osc` 把 `ShellEvent` 推到调用方，
不是服务端广播）：

| 收到 | 当前 | → 新状态 | 副作用 |
| --- | --- | --- | --- |
| `777;A` | `Unknown` | `AtPrompt { id: NEW, prompt_buf: [] }` | 首次 emit `ShellEvent::Bootstrapped`；emit `ShellEvent::PromptStarted { block_id: NEW }` |
| `777;A` | `AtPrompt { id }` | `AtPrompt { id: SAME, prompt_buf: [] }` | 重绘：id 不变，清 prompt_buf；emit `ShellEvent::PromptStarted { block_id: id }` |
| `777;A` | `Composing { id, prompt, command }` | `AtPrompt { id: SAME, prompt_buf: [] }` | 重绘：id 不变，清 prompt_buf 与 command_buf；emit `ShellEvent::PromptStarted { block_id: id }`。**不** emit CommandStarted/Finished |
| `777;A` | `Running { id, ... }` | `AtPrompt { id: NEW, prompt_buf: [] }` | 旧 id 强制 finalize（`exit_code = None`）；emit `ShellEvent::CommandFinished { id, exit: None, ... }`；emit `ShellEvent::PromptStarted { block_id: NEW }` |
| `777;B` | `AtPrompt { id, prompt_buf }` | `Composing { id, prompt_buf, command_buf: [] }` | emit `ShellEvent::PromptEnded { block_id: id }` |
| `777;E;<hex_cmd>` | * | (不变) | 暂存显式命令文本，供下一次 `777;C` 消费 |
| `777;C` | `Composing { id, prompt_buf, command_buf }` | `Running { id, prompt: prompt_buf, command: command_buf, ... }` | emit `ShellEvent::CommandStarted { id, text, cwd, started_at }` |
| `777;D;<exit>` | `Running { id, ... }` | `Unknown` | emit `ShellEvent::CommandFinished { id, exit: <exit>, ... }`；下一次 `777;A` 走 `Unknown→AtPrompt` 分支分配新 id 并 emit `ShellEvent::PromptStarted`，中间的 housekeeping 字节以 `active_block_id() = None` 流走 |
| `777;P;Context=<hex_json>` | * | (不变) | emit `ShellEvent::Context { ctx }` |
| `777;P;Cwd=...` | * | (不变) | emit `ShellEvent::CwdChanged { cwd }` |
| 字节 passthrough | `Unknown` | (不变) | 不缓冲；`active_block_id() = None`，`active_scope() = Passthrough` |
| 字节 passthrough | `AtPrompt { id }` | (不变) | 追加到 `prompt_buf`；`active_block_id() = Some(id)`，`active_scope() = Prompt` |
| 字节 passthrough | `Composing { id }` | (不变) | 追加到 `command_buf`；`active_scope() = Command` |
| 字节 passthrough | `Running { id }` | (不变) | 追加到 `output`；`active_scope() = Output` |
| PTY EOF | * | `Unknown` | `Running` 时强制 finalize（`ShellState::on_exit`）；`AtPrompt` / `Composing` 时丢弃当前 block |
| spawn 后 5s 未收任何 shell-integration marker | `Unknown` | `Unknown` | emit `ShellEvent::Bootstrapped` (`ShellKind::Unknown`) via `ShellState::note_bootstrap_timeout` |

每段缓冲单独 cap 在 1 MiB（`SEGMENT_MAX_BYTES`，
`crates/motif-client/src/shell_integration.rs:28`），超出截断尾部并置
`*_truncated=true`。

要点：

- **每个 `777;A` 边界都会 emit `ShellEvent::PromptStarted`**（含重绘）；
  client 用它做"PS1 开始绘制，重置渲染器"信号。重绘时 block_id 与上一次相
  同；其它情况 block_id 是新 id（前一条 `ShellEvent::CommandFinished` /
  `ShellEvent::Bootstrapped` 把旧 id 收尾，中间可能夹一段
  `active_block_id() = None` 的 housekeeping 字节）。
- **空 Enter / Ctrl-C 取消编辑 / fish autosuggestion repaint 都走"redraw"
  路径**：客户端视角看到的都是 `Composing → 777;A`，无法区分意图。统一保留
  block_id、清 prompt + command buffer、不 emit 任何 CommandStarted/Finished，
  避免按键引发的 prompt 重绘产出空 block 卡片。下游真有命令运行时走
  `Composing → 777;C` 的正常路径生成 block。
- **嵌套 shell**（`bash -c bash`、`tmux`、`ssh remote`）：状态机不区分层级，
  按"最近一次"事件转移。SSH 远端 shell 没 bootstrap 时 inner OSC 流为空，
  状态停在进入 ssh 时的状态；ssh 退出后下一次 `777;A` 自然恢复。新协议下
  没有 pid 兜底——SSH 进程内的 `cd` 不再被任何机制感知，直到回到 outer shell
  下一次 `777;P;Cwd=...` 到达。

---

## 5. Block 存储

服务端只保留每 PTY 2 MB 的原始字节 ring
（`crates/motif-server/src/pty.rs:44`）；不维护 block 列表，也不提供 block
回填 RPC。晚到 / 重连的客户端用 `WS /pty/<id>?since=N` 拉这个字节流，按
§4 的状态机自己重放成 block。

block 在客户端的存活策略由各客户端自定（TUI 按需在内存里维持，未持久
化），共享 wire 形态由 `BlockSummary` / `GetBlockOutputResult` 等 proto
类型描述（`crates/motif-proto/src/pty.rs:67`），供未来本地 RPC / IPC 复用。

**未持久化**：客户端重启或服务端 ring 被滚出 = block 历史丢失。session
持久化是更大的议题，本文档不展开。

---
