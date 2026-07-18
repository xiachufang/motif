# Windows / WSL 实验指南

Windows App 把原生 Windows 和 WSL 当作两个不同的 server 环境，而不是让原生
`motifd` 启动一个 `wsl.exe` shell。这样 Session 的路径、Git、shell 和所有子进程
始终属于同一个操作系统。

| App 中的模式 | `motifd` 运行位置 | Session 路径 | 连接实现 |
| --- | --- | --- | --- |
| Server 页内嵌服务 | Windows 原生进程 | `C:\...` | App 内加载 `motif_embed.dll`；PTY 使用 PowerShell |
| Client 页的 WSL server | WSL Linux 进程 | `/home/...` | `wsl.exe` 执行 bootstrap；App 连接 `127.0.0.1` |

从产品模型看，`Direct`、`Tailscale`、`SSH` 和 `WSL` 都是同一层的“到达方式”。
实现上，WSL 的安装和进程生命周期更像 SSH，网络路径则更像 Direct：

```text
SSH = SSH exec bootstrap + SSH local forward + Motif RPC
WSL = wsl.exe bootstrap     + localhost forwarding + Motif RPC
```

Tailscale 只提供网络可达性，不负责进入目标系统安装或启动 `motifd`。

## 1. Windows App 内启动原生 motifd

Windows desktop 构建会把这些 DLL 放到 App 目录：

- `motif_embed.dll`：Flutter 通过 FFI 启停的进程内 motifd；
- `ghostty-vt.dll`：motifd 的 headless VT 和 App 的终端渲染引擎；
- `flutter_windows.dll`：Flutter Windows runtime。

开发启动：

```powershell
cd apps\flutter
flutter run -d windows -t lib\main_desktop.dart
```

打开 App 的 **Server** 页面，保持默认 **Loopback**，然后点 **Start**。App 会加载
`motif_embed.dll`，调用 `motif_embed_init` 和 `motif_embed_start`。Server 运行后，
Client 页会自动出现 `This computer`。

这个服务是原生 Windows 进程：workdir 使用 Windows 路径，新 PTY 优先启动
PowerShell 7，并回退到 Windows PowerShell。它不再提供 WSL shell 选项。

## 2. 把 WSL 添加为连接类型

先在 PowerShell 确认 WSL 已安装，并至少启动过一次目标 distribution：

```powershell
wsl.exe --status
wsl.exe --list --verbose
wsl.exe
```

然后在 Motif 的 Client/Connections 页面：

1. 点 **Add Server**；
2. 在 **Reach via** 选择 **WSL**；
3. 可选填入 Distribution，例如 `Ubuntu-24.04`；留空使用默认 distribution；
4. 选择 WSL 内 `motifd` 的端口，默认 `7777`；
5. 点 **Save and Connect**。

每次连接时，App 会运行：

```text
wsl.exe [--distribution <name>] --exec sh
```

并通过 stdin 传入与 SSH Auto initialize 完全相同的 POSIX bootstrap 脚本。脚本会：

1. 先探测 `http://127.0.0.1:<port>/ping`，已有 motifd 就直接复用；
2. 缺少可执行文件时，从 `xiachufang/motif` 的最新 GitHub Release 下载匹配架构的
   Linux `motifd`；
3. 安装到 `$XDG_DATA_HOME/motif/bin/motifd`，没有设置 XDG 时使用
   `~/.local/share/motif/bin/motifd`；
4. 用 `nohup` 启动 loopback listener，并把 PID、日志写到
   `$XDG_STATE_HOME/motif`（默认 `~/.local/state/motif`）；
5. 等待 `/ping` 成功后，Windows App 直接连接 `127.0.0.1:<port>`。

首次安装需要 WSL 内有 `sh`、`tar`，以及 `curl` 或 `wget`，并且能访问 GitHub。
连接断开时不会停止 WSL 内的 motifd，这与 SSH Auto initialize 的远端 daemon 语义
一致；下一次连接会先 ping 并复用它。

motifd、PTY 和 shell integration 全都运行在 Linux 中，因此 Bash、Zsh、Fish 的
prompt 边界、cwd 跟踪、Git 和 Claude/Codex notify hook 都使用现有 Linux 实现，
Session 也可以直接使用 `/home/...` workdir。

## 3. 网络边界与排错

WSL 类型依赖 Windows/WSL localhost forwarding。bootstrap 成功后可从 PowerShell
验证：

```powershell
curl.exe http://127.0.0.1:7777/ping
```

如果 WSL 内 `/ping` 成功而 Windows 侧失败，检查 `.wslconfig` 是否禁用了
`localhostForwarding`，然后执行 `wsl.exe --shutdown` 让配置重新生效。这个 listener
只用于本机 App，不应作为手机或其它 LAN 设备的入口；跨设备访问请使用配对、
Tailscale、SSH 或单独配置过的网络 listener。

常见失败：

- `wsl.exe` 找不到：先安装 WSL；
- distribution 不存在：用 `wsl.exe --list --verbose` 检查名称，或把字段留空；
- bootstrap 报缺少下载工具：在 WSL 内安装 `curl` 或 `wget`；
- GitHub release 下载失败：检查 WSL 自己的 DNS、代理和网络；
- 端口被其它进程占用：更换 WSL server 的端口，或停止旧进程。

## 4. 验收清单

- Windows release 目录同时存在 `motif_embed.dll` 和 `ghostty-vt.dll`；
- Server 页能启动原生 Windows motifd，并创建 PowerShell PTY；
- Add Server 的 **Reach via** 在 Windows 上显示 **WSL**；
- 可以选择默认或指定 distribution；
- 首次连接会安装并启动 Linux motifd，再次连接会复用它；
- `curl.exe http://127.0.0.1:7777/ping` 返回 `service: motif-server`；
- WSL Session 能使用 `/home/...` workdir，并获得完整 Linux shell integration。
