# Windows / WSL 实验指南

Motif 在 Windows 上有两条不同的运行链路。先选清楚 `motifd` 属于哪一个系统，
因为 Session 的文件路径、Git、shell 和子进程都会属于它：

| 模式 | `motifd` 运行位置 | Session 路径 | 适合 |
| --- | --- | --- | --- |
| Windows App 内嵌 | Windows 原生进程 | `C:\...` | Windows 项目；PowerShell；快速试验 WSL shell |
| WSL daemon | WSL Linux 进程 | `/home/...` | 主要在 WSL 里开发；完整 Bash/Zsh/Fish 集成 |

## 1. Windows App 内启动 motifd

Windows desktop 构建会把三个 DLL 放到 App 目录：

- `motif_embed.dll`：Flutter 通过 FFI 启停的进程内 motifd；
- `ghostty-vt.dll`：motifd 的 headless VT 和 App 的终端渲染引擎；
- `flutter_windows.dll`：Flutter Windows runtime。

开发启动：

```powershell
cd apps\flutter
flutter run -d windows -t lib\main_desktop.dart
```

构建钩子会自动编译并打包前两个 DLL。打开 App 后进入 **Server** 页面：

1. 在 **Default shell** 选择 **PowerShell** 或 **WSL**；
2. 保持默认 **Loopback**；
3. 点 **Start**。

`Start server on launch` 默认开启。App 启动时会加载 `motif_embed.dll`，调用
`motif_embed_init`，然后把持久化配置传给 `motif_embed_start`。Server 运行后，Client
页会自动出现 `This computer`。

### 在原生 motifd 中试 WSL shell

先在 PowerShell 确认 WSL 已安装，而且默认 distribution 至少成功启动过一次：

```powershell
wsl.exe --status
wsl.exe --list --verbose
wsl.exe
```

然后在 Motif 的 **Server → Default shell** 选择 **WSL** 并重启 Server。新 PTY
会由 Windows ConPTY 启动 `wsl.exe`；未显式指定 distribution 时使用 WSL 的默认值。

这是实验模式，当前边界是：

- Session/workdir 仍是 Windows 路径；`wsl.exe` 负责把当前目录映射进 WSL；
- WSL launcher 暂时不注入 Bash/Zsh bootstrap，因此 prompt 边界、cwd 跟踪和
  Claude/Codex notify hook 不如 motifd 整体跑在 WSL 完整；
- 暂不在 App 内选择 distribution 或 WSL user；先用 `wsl.exe --set-default <Distro>`
  设置默认 distribution；
- 如果 WSL 没安装或没初始化，Server 本身仍能启动，但创建 PTY 会返回 spawn error。

独立运行 `motifd.exe` 时可用同一入口：

```powershell
$env:MOTIFD_SHELL = 'wsl.exe'
.\motifd.exe --listen 127.0.0.1:7777
```

## 2. motifd 整体跑在 WSL

如果代码主要位于 `/home/<user>/...`，推荐让 motifd 也成为 Linux 进程。进入 WSL
中的仓库，在安装 Rust、Zig 0.15.2 和常规 C/C++ 构建依赖后运行：

```bash
cargo run -p motif-server --bin motifd -- \
  --listen 127.0.0.1:7777
```

然后在 Windows App 的 Client 页新增 Direct server：`127.0.0.1:7777`。先从
PowerShell 验证 Windows 能访问 WSL listener：

```powershell
curl.exe http://127.0.0.1:7777/ping
```

如果当前 WSL 网络配置没有转发 loopback，用 `wsl.exe hostname -I` 取得 WSL IP，
再用该地址测试。需要让手机或其它机器访问时，不要直接假定 WSL listener 已经对局域网
开放；先单独处理 Windows 防火墙和 WSL 网络转发，再把 motifd 改成 LAN listener 并使用
它打印的 `motif://pair` 链接。

## 3. 验收清单

- Windows release 目录同时存在 `motif_embed.dll` 和 `ghostty-vt.dll`；
- App 的 Server 页面可见，Start 后状态变为 Running；
- `http://127.0.0.1:7777/ping` 返回 `service: motif-server`；
- PowerShell 模式可创建 PTY；
- WSL 模式在已初始化的默认 distribution 中打开 shell；
- motifd-in-WSL 模式下，新 Session 能使用 `/home/...` workdir。
