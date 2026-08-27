# 在 Motif 中使用 Codex

Motif 的 **Terminal** 和 **Codex** 是两个独立功能：Terminal 连接由 `motifd`
管理的 PTY；Codex 页面则连接运行在同一台 `motifd` 主机上的
`codex app-server`。因此，Codex 直接在服务端工作目录中读取代码、执行命令和修改
文件，手机、平板或桌面端只负责展示对话与操作界面。

Codex 是可选集成。Motif 不包含 OpenAI 账号、API key 或 Codex 用量；认证方式、
权限和费用由安装在服务端的 Codex CLI 决定。

## 1. 准备 Codex CLI

Flutter 桌面 App 的内嵌 server 会在第一次打开 Codex、且本机找不到 Codex CLI 时，
使用 OpenAI 官方安装脚本静默安装最新版。macOS/Linux 使用 `install.sh`，Windows
使用 `install.ps1`；安装过程不会弹出交互确认。显式设置了无效的
`MOTIFD_CODEX_PATH` 时不会覆盖该配置，而是直接报告配置错误。

独立运行的 `motifd`（包括 daemon、容器和远端主机）不会自动修改运行环境，仍需在
运行它的同一个系统用户下安装 Codex CLI。安装后可这样确认：

```bash
codex --version
codex app-server --help
```

Codex CLI 支持使用 ChatGPT 账号或 OpenAI API key 登录。交互式登录可运行：

```bash
codex login
codex login status
```

无图形界面的远端主机可以使用 device code 登录：

```bash
codex login --device-auth
```

API key 登录时，不要把 key 写入命令历史或 Motif 配置；通过标准输入传递：

```bash
printenv OPENAI_API_KEY | codex login --with-api-key
```

登录缓存属于运行 Codex 的系统用户。请像密码一样保护 `CODEX_HOME` 下的认证文件，
不要提交到仓库、粘贴到 issue，或放进公开的 review/demo 镜像。

OpenAI 官方参考：

- [Codex CLI](https://learn.chatgpt.com/docs/codex/cli)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)

## 2. 让 motifd 找到 Codex

`motifd` 会按以下顺序查找 Codex：

1. `MOTIFD_CODEX_PATH`
2. 当前进程的 `PATH`
3. `~/.local/bin/codex`
4. 常见 Homebrew、npm 和 Node 版本管理器安装位置

如果 `motifd` 由 systemd、launchd 或 Docker 启动，它看到的 `PATH` 可能和交互式
shell 不同。最稳定的方式是显式设置绝对路径：

```bash
MOTIFD_CODEX_PATH=/absolute/path/to/codex motifd --listen 127.0.0.1:7777
```

Motif 在第一次打开 Codex 页面时按需启动服务端的 `codex app-server`。客户端不会
直接连接 OpenAI，也不会把 Codex WebSocket 暴露到公网；它通过已经配对并鉴权的
Motif 连接访问 `motifd` 提供的 Codex 通道。

## 3. 工作区与 Thread

连接 server 后，在 Session 列表中打开 **Codex**：

1. 选择已有 Thread，或为服务端上的某个工作目录创建 Thread。
2. 在对话中选择模型、reasoning effort 和权限配置，然后发送任务。
3. Codex 的文字、命令、文件改动、diff、计划和审批请求会流式显示。
4. 左侧 **Threads** sidebar 可按最近活动查看、搜索、恢复或归档持久 Thread。
5. 在回复下使用 **Fork from this turn**，可以从某个历史节点创建一个新的持久
   Thread，而不覆盖原对话。

Thread 与工作目录都在运行 `motifd` 的主机上。切换手机、平板或桌面客户端时，
重新打开同一个 server 即可继续已有 Thread；关闭 Motif 客户端不会停止正在运行的
服务端任务。

## 4. Side Chat

**Side Chat** 用于在不改写主 Thread 对话的前提下探索一个旁支问题，例如验证发布
风险、比较实现方案或单独检查测试策略。

- Side Chat 从当前主 Thread 建立独立的临时分支，并沿用对应工作区。
- 同一个主 Thread 可以拥有多个 Side Chat；sidebar 会按活动时间展示并恢复本机
  保存的列表。
- Side Chat 中的新消息不会追加到主 Thread。需要长期保留的决策，应整理回主
  Thread，或使用普通的持久 Fork。
- Side Chat 和主 Thread 操作的是同一个服务端工作目录；如果允许写入，文件改动仍
  会影响该工作区。它隔离的是对话历史，不是文件系统。

## 5. 权限与安全

Codex 进程继承运行 `motifd` 的系统用户权限。最终可执行的操作还受 Codex 选择的
permission profile、sandbox 和审批策略约束。

- 不要以 root 身份运行日常开发用的 `motifd`。
- 只把配对链接交给可信设备；获得 Motif server 访问权的客户端也可能访问 Codex。
- 在共享或公开 review server 上使用独立、低权限的 Codex 凭据和一次性工作目录。
- Side Chat 不是额外的安全边界，不能替代操作系统权限、容器或 Codex sandbox。

## 6. 快速排错

**Codex 入口不存在**

- 确认 client 与 server 版本都支持 `codex_v1` capability。

**提示找不到 Codex CLI**

- Flutter 桌面内嵌 server 会自动尝试安装；若安装失败，错误详情会包含下载或安装
  阶段的原因。检查网络、`curl`（macOS/Linux）或 PowerShell（Windows）后重试。
- 以运行 `motifd` 的用户执行 `codex --version`。
- 为 daemon 显式设置 `MOTIFD_CODEX_PATH`，然后重启 `motifd`。

**能打开页面但无法开始任务**

- 执行 `codex login status` 检查服务端用户的登录状态。
- 直接在服务端工作目录运行一次 Codex，确认账号、网络和模型访问正常。

**Thread 或 Side Chat 无法恢复**

- 先检查 `motifd` 与 Codex CLI 是否刚升级或重启。
- Side Chat 是临时分支；如果对应 Codex rollout 已被清理，Motif 会忽略失效条目并
  创建新的 Side Chat。
