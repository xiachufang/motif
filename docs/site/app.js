const translations = {
  en: {
    "language.toggle": "中文",
    "nav.features": "Features",
    "nav.screenshots": "Screenshots",
    "nav.compare": "Compare",
    "nav.use": "How to use",
    "nav.rzv": "Relay",
    "nav.connect": "Connect",
    "nav.architecture": "Architecture",
    "nav.faq": "FAQ",
    "nav.docs": "Docs",
    "nav.appstore": "App Store",
    "hero.eyebrow": "Remote terminal, files, and git in one live session",
    "hero.title": "Motif",
    "hero.copy":
      "Run your workdir, shells, file operations, and git state on one machine. Attach from any lightweight client and see the same session.",
    "hero.ctaAppStore": "Download on the App Store",
    "hero.ctaOther": "Other platforms",
    "hero.availability":
      "iOS on the App Store. macOS, Android, Linux, and Windows on GitHub Releases. Web runs in the browser.",
    "hero.openness":
      "Open source (MIT/Apache-2.0) and self-hosted. No account or sign-in—your code stays on the machine running motifd.",
    "hero.fact1.value": "Persistent",
    "hero.fact1.label": "sessions stay alive on the machine running motifd",
    "hero.fact2.value": "Mirrored",
    "hero.fact2.label": "multiple clients see one authoritative session",
    "hero.fact3.value": "Reachable",
    "hero.fact3.label": "Pair, SSH, Tailscale, relay, or browser same-origin",
    "intro.kicker": "What Motif is",
    "intro.title": "A long-lived development session you can reattach to.",
    "intro.copy1":
      "Motif combines a Rust server named motifd with Flutter clients. The server owns the workdir, PTY pool, filesystem operations, and git diff. Clients are thin surfaces that attach, detach, and reconnect.",
    "intro.copy2":
      "The result feels like code-server plus tmux attach: open the same session from your laptop, phone, tablet, desktop app, or browser and keep seeing the same file tree, terminals, and diff.",
    "screenshots.kicker": "Product walkthrough",
    "screenshots.title": "Every core workflow, captured from a live review server.",
    "screenshots.copy":
      "These are real macOS and iPhone captures connected to a public motifd review server: session management, terminal attach, files, git diff, mobile input helpers, settings, and the embedded server view.",
    "screenshots.macGit.title": "Git diff with context",
    "screenshots.macGit.copy":
      "Review working changes next to the file tree and live terminal, with quick commands still one tap away.",
    "screenshots.macSessions.title": "Session list",
    "screenshots.macSessions.copy":
      "See every long-lived session on the server, its workdir, age, and active client count.",
    "screenshots.macTerminal.title": "Remote terminal tabs",
    "screenshots.macTerminal.copy":
      "Attach to PTY-backed shells, keep output on the server, and switch between terminal tabs.",
    "screenshots.macFiles.title": "File tree",
    "screenshots.macFiles.copy":
      "Browse folders and files in the remote workdir without copying the project to the client.",
    "screenshots.macServer.title": "Embedded server",
    "screenshots.macServer.copy":
      "Run motifd from the desktop app, choose loopback/LAN/off, and expose relay or Tailscale endpoints.",
    "screenshots.macSettings.title": "Terminal settings",
    "screenshots.macSettings.copy":
      "Tune font size and theme per client while the underlying session keeps running.",
    "screenshots.iphoneGit.title": "iPhone git review",
    "screenshots.iphoneGit.copy":
      "The same diff is readable on mobile, including working/staged tabs and per-file patch text.",
    "screenshots.iphoneSessions.title": "Mobile session list",
    "screenshots.iphoneSessions.copy":
      "Reconnect from your phone and see the same server state, including attached clients.",
    "screenshots.iphoneTerminal.title": "Mobile terminal input",
    "screenshots.iphoneTerminal.copy":
      "Use quick keys, reusable commands, photo attach, voice input, and send controls from the phone.",
    "screenshots.iphoneFiles.title": "Mobile files",
    "screenshots.iphoneFiles.copy":
      "Open the remote file tree on iPhone for quick inspection and file-level actions.",
    "features.kicker": "Everything in the session",
    "features.title": "Core features",
    "features.copy":
      "Motif focuses on the daily remote development loop: terminals, files, diffs, connection setup, and cross-device continuity.",
    "feature.terminal.title": "Ghostty-powered terminal",
    "feature.terminal.copy":
      "Render remote PTY bytes locally with libghostty on native platforms and WebAssembly in the browser.",
    "feature.sessions.title": "Long-lived sessions",
    "feature.sessions.copy":
      "Sessions live on the server with their workdir and terminal state even when a client disconnects.",
    "feature.mirror.title": "Mirrored clients",
    "feature.mirror.copy":
      "Multiple clients attach to the same session and observe the same PTY output, file tree, and git state.",
    "feature.files.title": "File tree and editing",
    "feature.files.copy":
      "Browse, create, rename, delete, preview, edit, and resolve write conflicts inside the server workdir.",
    "feature.git.title": "Git diff views",
    "feature.git.copy": "Review all changes or per-file diffs without leaving the remote session.",
    "feature.quick.title": "Quick commands",
    "feature.quick.copy":
      "Use reusable command sets, sticky modifiers, and an editor for fast mobile and desktop terminal input.",
    "feature.connectivity.title": "Flexible connectivity",
    "feature.connectivity.copy":
      "Reach motifd over embedded Tailscale (tsnet), relay, or motif://pair links and QR, with certificate pinning and psk-derived bearer auth.",
    "feature.web.title": "Embedded Web client",
    "feature.web.copy":
      "motifd can serve the Flutter Web client from the same origin as RPC, events, and PTY streams.",
    "feature.desktop.title": "Desktop embedded server",
    "feature.desktop.copy":
      "Desktop builds can run motifd in-process, managed from the Server view or system tray.",
    "feature.sshprov.title": "SSH auto-provisioning",
    "feature.sshprov.copy":
      "Connect over SSH and Motif can download, install, and start motifd on the remote host automatically when it is missing.",
    "feature.input.title": "Voice, photo, and image flows",
    "feature.input.copy":
      "Native clients support voice input, photo attach, image view, and terminal-focused interaction helpers.",
    "feature.push.title": "Encrypted push notifications",
    "feature.push.copy":
      "E2E push uses AES-256-GCM and native APNs paths without Firebase in the iOS flow.",
    "compare.kicker": "How it compares",
    "compare.title": "Why Motif instead of SSH + tmux, mosh, or a browser IDE?",
    "compare.copy":
      "Motif keeps one authoritative session on the server and mirrors it to native clients on every device—with files, git diff, and built-in connectivity. Here is how that compares to the usual setups.",
    "compare.col.capability": "Capability",
    "compare.col.ssh": "SSH + tmux",
    "compare.col.mosh": "mosh",
    "compare.col.code": "code-server",
    "compare.col.motif": "Motif",
    "compare.row1": "Persistent, mirrored server session",
    "compare.row2": "Survives roaming and flaky links (local echo)",
    "compare.row3": "Native phone, tablet, and desktop apps",
    "compare.row4": "Native scrollback, no copy-mode keys",
    "compare.row5": "File tree, editing, and git diff",
    "compare.row6": "Custom shortcuts and quick-command input",
    "compare.row7": "Forward remote ports to localhost",
    "compare.row8": "AI agent helpers: image upload, completion hooks",
    "compare.row9": "Built-in Tailscale, relay, and QR pairing",
    "compare.legend": "✓ built in · ~ with extra setup · — not really",
    "use.kicker": "Two ways to run",
    "use.title": "Use Motif as a server daemon or as your computer's remote entrance.",
    "use.lead":
      "Every session lives in a motifd server. Desktop apps include motifd—run it locally in one click. Mobile, web, and other desktops attach to a motifd you run on a computer or server.",
    "run.server.title": "Run on a server",
    "run.server.copy":
      "Deploy motifd on a VPS, cloud box, remote workstation, or long-lived dev machine. Clients attach from anywhere that can reach it.",
    "run.server.pair":
      "Then read the pairing link from the logs and scan or paste it in any client:",
    "run.computer.title": "Run on your computer",
    "run.computer.copy":
      "The desktop app ships motifd built in—no separate install. Start the embedded server from the Server view or tray, then connect from mobile, web, or another desktop.",
    "run.computer.step1": "Open Motif desktop.",
    "run.computer.step2": "Choose Loopback, Local network, Tailscale, or relay pairing.",
    "run.computer.step3": "Scan or paste the pairing link from another client.",
    "rzv.kicker": "Rendezvous relay",
    "rzv.title": "Deploy rzv once, then pair through it when direct routes are hard.",
    "rzv.lead":
      "Run the relay behind an HTTPS/WSS reverse proxy. motifd authenticates with JWT, the relay limits bandwidth by owner, and Motif's inner TLS/psk layer stays end-to-end.",
    "rzv.deploy.title": "Run the relay",
    "rzv.deploy.copy":
      "Keep its WebSocket port private, expose it through your HTTPS proxy, and mount the JWT/rate configuration.",
    "rzv.motifd.title": "Point motifd at it",
    "rzv.motifd.copy":
      "For relay-only deployments, configure MOTIFD_RZV_RELAY plus MOTIFD_RZV_JWT_FILE; binaries use --rzv-relay plus --rzv-jwt-file.",
    "rzv.motifd.docker": "Docker:",
    "rzv.motifd.binary": "Binary:",
    "rzv.pair.title": "Pair and verify",
    "rzv.pair.copy":
      "Copy the motif://pair URI from motifd logs, then scan or paste it in Motif. The same link carries the relay address, psk, and cert pin.",
    "rzv.notes.title": "Operational notes",
    "rzv.note1": "The relay sees JWT/pairing metadata, but application traffic remains inner-TLS ciphertext.",
    "rzv.note2": "Persist /data on motifd so the psk and cert pin survive restarts.",
    "rzv.note3": "One relay can serve many independent motifd servers and clients.",
    "rzv.docs": "Full relay docs",
    "connect.kicker": "Connection paths",
    "connect.title": "Pick the route that matches your network.",
    "connect.col.path": "Path",
    "connect.col.best": "Best for",
    "connect.col.note": "Notes",
    "connect.direct.path": "Direct TCP",
    "connect.direct.best": "LAN or public host",
    "connect.direct.note": "Network listeners auto-encrypt and use pairing credentials.",
    "connect.ssh.path": "SSH forward",
    "connect.ssh.best": "Existing SSH access",
    "connect.ssh.note":
      "Keep motifd on 127.0.0.1 and forward a local port. The desktop app can auto-install and start motifd over SSH when it is missing.",
    "connect.tailscale.path": "Tailscale",
    "connect.tailscale.best": "NAT, travel, private devices",
    "connect.tailscale.note": "Use embedded tsnet on supported clients and servers.",
    "connect.relay.path": "Rendezvous relay",
    "connect.relay.best": "QR pairing when direct routes are hard",
    "connect.relay.note": "The relay forwards encrypted bytes; clients still pin the server cert.",
    "connect.browser.path": "Browser same-origin",
    "connect.browser.best": "Local loopback or trusted HTTPS host",
    "connect.browser.note":
      "motifd serves the Flutter Web client next to RPC and WebSocket routes.",
    "architecture.kicker": "How it fits together",
    "architecture.title": "motifd owns state. Clients attach to it.",
    "architecture.copy":
      "RPC, event streams, and PTY streams share one protocol surface. The web client can be embedded by motifd, while native clients use the same server model through HTTP and WebSocket transports.",
    "diagram.client1": "iOS app",
    "diagram.client2": "macOS app",
    "diagram.client3": "Browser",
    "diagram.client4": "Linux / Windows",
    "diagram.transport": "HTTP RPC + WebSocket",
    "diagram.server1": "Sessions",
    "diagram.server2": "PTY pool",
    "diagram.server3": "File ops",
    "diagram.server4": "Git diff",
    "diagram.host": "Host filesystem, shell, and git",
    "security.kicker": "Security model",
    "security.title": "Single-user by design, explicit about trust.",
    "security.copy":
      "Motif treats the machine running motifd as the trusted execution environment. Shell commands run with that user's permissions, and workdir access is bounded by the server-side path checks.",
    "security.item1": "Network listeners use self-signed TLS with client-side certificate pinning.",
    "security.item2": "Pairing links carry the psk material used to derive bearer auth.",
    "security.item3": "Loopback mode stays plaintext and unauthenticated for local-only workflows.",
    "security.item4":
      "Tailscale and SSH are available when you want network access without opening a public port.",
    "faq.kicker": "FAQ",
    "faq.title": "Common questions",
    "faq.q1": "Does Motif copy my project to the client?",
    "faq.a1":
      "No. The workdir stays on the machine running motifd. Clients operate remotely and render the current server state.",
    "faq.q2": "Can I use it from a browser?",
    "faq.a2":
      "Yes for loopback, SSH-forwarded, or trusted HTTPS origins. Browsers cannot pin Motif's self-signed cert for network pairing, so native apps are recommended there.",
    "faq.q3": "What happens when I close the app?",
    "faq.a3":
      "The client detaches. The session continues on the server until you destroy it or stop motifd.",
    "faq.q4": "Is Motif an AI agent?",
    "faq.a4":
      "No. The current product is a remote development surface, not an LLM agent. It focuses on sessions, terminals, files, git, and connectivity.",
    "faq.q5": "Which platforms are supported?",
    "faq.a5":
      "The Flutter client targets iOS, macOS, Android, Web, Linux, and Windows. Desktop builds can include the embedded server path.",
    "faq.q6": "Where should I read more?",
    "faq.a6":
      "Browse the docs/ folder in the GitHub repo—usage, rpc, tailscale, and web-client guides. For help or bug reports, open a GitHub issue.",
    "faq.q7": "Do I need to install motifd on my remote host?",
    "faq.a7":
      "Not necessarily. For an SSH server, enable Auto initialize and the desktop app downloads, installs, and starts motifd on the remote host (Linux or macOS, x86_64 or arm64) when it is missing. On your own computer, motifd is built into the desktop app.",
    "faq.q8": "Is Motif free, and do I need an account?",
    "faq.a8":
      "Motif is open source (MIT/Apache-2.0) and free to self-host. There is no account or sign-in—clients pair directly with your motifd over pinned TLS, and nothing is sent to a third-party service.",
    "faq.q10": "How mature is Motif?",
    "faq.a10":
      "Motif is actively developed and ships tagged releases. Check the GitHub Releases page for the current version and changelog.",
    "faq.q11": "What does the motifd server need to run?",
    "faq.a11":
      "A single motifd binary on Linux or macOS (x86_64 or arm64). Use the Docker image on a Linux host, or run the binary directly. No database or extra services are required.",
    "footer.copy": "Remote development sessions for every device you actually use.",
    "footer.appstore": "App Store",
    "footer.releases": "Releases",
    "footer.usage": "Usage",
    "footer.rpc": "RPC",
    "footer.tailscale": "Tailscale",
    "footer.rzv": "Rendezvous",
    "footer.support": "Support",
    "footer.repo": "Repository",
  },
  zh: {
    "language.toggle": "English",
    "nav.features": "功能",
    "nav.screenshots": "截图",
    "nav.compare": "对比",
    "nav.use": "如何使用",
    "nav.rzv": "Relay",
    "nav.connect": "连接方式",
    "nav.architecture": "架构",
    "nav.faq": "FAQ",
    "nav.docs": "文档",
    "nav.appstore": "App Store",
    "hero.eyebrow": "终端、文件、Git，都在一个可重连的远程会话里",
    "hero.title": "Motif",
    "hero.copy":
      "把工作目录、shell、文件操作和 git 状态放在同一台机器上运行。任何轻量客户端都能 attach 进去，看到同一个 Session。",
    "hero.ctaAppStore": "App Store 下载",
    "hero.ctaOther": "其他平台",
    "hero.availability":
      "iOS 在 App Store；macOS、Android、Linux、Windows 在 GitHub Releases；Web 直接在浏览器运行。",
    "hero.openness":
      "开源（MIT/Apache-2.0）且自托管。无需账号或登录——代码始终留在运行 motifd 的机器上。",
    "hero.fact1.value": "长期会话",
    "hero.fact1.label": "Session 留在运行 motifd 的机器上持续存在",
    "hero.fact2.value": "多端镜像",
    "hero.fact2.label": "多个客户端共享同一个权威 Session",
    "hero.fact3.value": "多路可达",
    "hero.fact3.label": "Pair、SSH、Tailscale、relay 或浏览器同源访问",
    "intro.kicker": "Motif 是什么",
    "intro.title": "一个长期存在、随时可重连的开发 Session。",
    "intro.copy1":
      "Motif 由 Rust 写的 motifd 服务端和 Flutter 客户端组成。服务端持有 workdir、PTY 池、文件操作和 git diff；客户端只是负责 attach、detach 和重连的轻量界面。",
    "intro.copy2":
      "它的感觉像 code-server 加 tmux attach：从笔记本、手机、平板、桌面 App 或浏览器打开同一个 Session，持续看到同一份文件树、终端和 diff。",
    "screenshots.kicker": "产品使用截图",
    "screenshots.title": "核心工作流都来自真实 review server。",
    "screenshots.copy":
      "这些都是真实 macOS 和 iPhone App 连接公网可达的 motifd review server 后截取的画面：Session 管理、终端 attach、文件、Git diff、移动端输入辅助、设置，以及内嵌 server 页面。",
    "screenshots.macGit.title": "带上下文的 Git diff",
    "screenshots.macGit.copy":
      "在文件树和实时终端旁边查看 working changes，同时保留快捷命令输入栏。",
    "screenshots.macSessions.title": "Session 列表",
    "screenshots.macSessions.copy":
      "查看服务端所有长期 Session，包括 workdir、创建时间和当前 attach 的客户端数量。",
    "screenshots.macTerminal.title": "远程终端标签",
    "screenshots.macTerminal.copy":
      "连接 PTY 驱动的 shell，输出保留在服务端，并可在多个终端标签之间切换。",
    "screenshots.macFiles.title": "文件树",
    "screenshots.macFiles.copy":
      "直接浏览远端 workdir 里的文件夹和文件，不需要把项目复制到客户端。",
    "screenshots.macServer.title": "内嵌 server",
    "screenshots.macServer.copy":
      "在桌面 App 中运行 motifd，选择 loopback/LAN/off，并暴露 relay 或 Tailscale endpoint。",
    "screenshots.macSettings.title": "终端设置",
    "screenshots.macSettings.copy":
      "按客户端调整字号和主题，而底层 Session 继续保持运行。",
    "screenshots.iphoneGit.title": "iPhone Git review",
    "screenshots.iphoneGit.copy":
      "同一份 diff 在手机上也能阅读，包含 working/staged 切换和文件 patch 文本。",
    "screenshots.iphoneSessions.title": "移动端 Session 列表",
    "screenshots.iphoneSessions.copy":
      "从手机重新连接，同步看到同一台 server 的状态和已 attach 客户端。",
    "screenshots.iphoneTerminal.title": "移动端终端输入",
    "screenshots.iphoneTerminal.copy":
      "在手机上使用快捷键、常用命令、照片附加、语音输入和发送控制。",
    "screenshots.iphoneFiles.title": "移动端文件",
    "screenshots.iphoneFiles.copy":
      "在 iPhone 上打开远端文件树，快速查看文件并进行文件级操作。",
    "features.kicker": "Session 里的完整工作流",
    "features.title": "核心功能",
    "features.copy":
      "Motif 聚焦远程开发的日常闭环：终端、文件、diff、连接配置，以及跨设备连续工作。",
    "feature.terminal.title": "Ghostty 驱动的终端",
    "feature.terminal.copy":
      "远端 PTY 字节在本地渲染：原生平台使用 libghostty，浏览器使用 WebAssembly。",
    "feature.sessions.title": "长期存在的 Session",
    "feature.sessions.copy":
      "Session 连同 workdir 和终端状态都留在服务端；客户端断开后不会自动消失。",
    "feature.mirror.title": "多客户端镜像",
    "feature.mirror.copy":
      "多个客户端 attach 到同一个 Session，看到同一份 PTY 输出、文件树和 git 状态。",
    "feature.files.title": "文件树与编辑",
    "feature.files.copy":
      "在服务端 workdir 内浏览、新建、重命名、删除、预览、编辑文件，并处理写入冲突。",
    "feature.git.title": "Git diff 视图",
    "feature.git.copy": "不用离开远程 Session，就能查看全部改动或按文件查看 diff。",
    "feature.quick.title": "快捷命令",
    "feature.quick.copy":
      "用可复用命令集、sticky modifiers 和编辑器提升移动端与桌面端的终端输入效率。",
    "feature.connectivity.title": "灵活的连接方式",
    "feature.connectivity.copy":
      "通过嵌入式 Tailscale (tsnet)、relay 或 motif://pair 链接与二维码连接 motifd，带证书 pin 和 psk 派生的 bearer 鉴权。",
    "feature.web.title": "内嵌 Web 客户端",
    "feature.web.copy":
      "motifd 可以从同一个 origin 提供 Flutter Web 客户端、RPC、events 和 PTY streams。",
    "feature.desktop.title": "桌面内嵌服务端",
    "feature.desktop.copy":
      "桌面版可以在进程内运行 motifd，并从 Server 页或系统托盘管理。",
    "feature.sshprov.title": "SSH 自动部署",
    "feature.sshprov.copy":
      "通过 SSH 连接时，若远端缺少 motifd，Motif 可以自动下载、安装并启动它。",
    "feature.input.title": "语音、照片与图片流程",
    "feature.input.copy":
      "原生客户端支持语音输入、照片附加、图片查看，以及面向终端操作的交互辅助。",
    "feature.push.title": "端到端加密推送",
    "feature.push.copy":
      "E2E push 使用 AES-256-GCM；iOS 流程走原生 APNs，不依赖 Firebase。",
    "compare.kicker": "横向对比",
    "compare.title": "为什么用 Motif，而不是 SSH + tmux、mosh 或浏览器 IDE？",
    "compare.copy":
      "Motif 在服务端保留一个权威 Session，并镜像到每台设备上的原生客户端——内置文件、git diff 和连接能力。下面是它与常见方案的对比。",
    "compare.col.capability": "能力",
    "compare.col.ssh": "SSH + tmux",
    "compare.col.mosh": "mosh",
    "compare.col.code": "code-server",
    "compare.col.motif": "Motif",
    "compare.row1": "常驻并多端镜像的服务端 Session",
    "compare.row2": "弱网/漫游下不掉线（本地回显）",
    "compare.row3": "原生手机、平板和桌面 App",
    "compare.row4": "原生滚动回看，无需 copy-mode 命令",
    "compare.row5": "文件树、编辑与 git diff",
    "compare.row6": "自定义快捷键与快捷命令输入",
    "compare.row7": "把远程端口映射到本地直接访问",
    "compare.row8": "AI agent 辅助：图片上传、完成后提醒 hook",
    "compare.row9": "内置 Tailscale、relay 和二维码配对",
    "compare.legend": "✓ 内置 · ~ 需额外配置 · — 基本没有",
    "use.kicker": "两种运行方式",
    "use.title": "把 Motif 当 server daemon，或把自己的电脑变成远程入口。",
    "use.lead":
      "每个 Session 都跑在 motifd 服务端里。桌面 App 内置 motifd，本机一键启动；移动端、Web 和其他桌面端连接到你在电脑或服务器上运行的 motifd。",
    "run.server.title": "跑在 server 上",
    "run.server.copy":
      "把 motifd 部署在 VPS、云主机、远程工作站或长期在线开发机上。任何能连到它的客户端都可以 attach。",
    "run.server.pair":
      "然后从日志里取出 pairing link，在任意客户端扫码或粘贴：",
    "run.computer.title": "跑在你的电脑上",
    "run.computer.copy":
      "桌面 App 已内置 motifd，无需单独安装。从 Server 页或托盘启动内嵌 server，然后从手机、Web 或另一台桌面端连回来。",
    "run.computer.step1": "打开 Motif 桌面版。",
    "run.computer.step2": "选择 Loopback、Local network、Tailscale 或 relay pairing。",
    "run.computer.step3": "在另一个客户端扫描或粘贴 pairing link。",
    "rzv.kicker": "Rendezvous relay",
    "rzv.title": "部署一次 rzv relay，直连困难时就通过它配对。",
    "rzv.lead":
      "把 relay 放在 HTTPS/WSS 反向代理后。motifd 用 JWT 鉴权，relay 按 owner 限速，Motif 内层 TLS/psk 仍保持端到端。",
    "rzv.deploy.title": "运行 relay",
    "rzv.deploy.copy":
      "保持 WebSocket 端口私有，通过 HTTPS 代理暴露，并挂载 JWT/限速配置。",
    "rzv.motifd.title": "让 motifd 连接它",
    "rzv.motifd.copy":
      "relay-only 部署需同时设置 MOTIFD_RZV_RELAY 和 MOTIFD_RZV_JWT_FILE；二进制使用对应的 --rzv-relay 与 --rzv-jwt-file。",
    "rzv.motifd.docker": "Docker：",
    "rzv.motifd.binary": "二进制：",
    "rzv.pair.title": "配对并验证",
    "rzv.pair.copy":
      "从 motifd 日志复制 motif://pair URI，在 Motif 里扫码或粘贴。这个链接同时包含 relay 地址、psk 和证书 pin。",
    "rzv.notes.title": "运维要点",
    "rzv.note1": "relay 能看到 JWT/配对元数据，但应用流量仍是内层 TLS 密文。",
    "rzv.note2": "给 motifd 持久化 /data，让 psk 和证书 pin 跨重启保持稳定。",
    "rzv.note3": "一台 relay 可以服务多组独立的 motifd 和客户端。",
    "rzv.docs": "完整 relay 文档",
    "connect.kicker": "连接路径",
    "connect.title": "按你的网络环境选择路线。",
    "connect.col.path": "路径",
    "connect.col.best": "适合场景",
    "connect.col.note": "说明",
    "connect.direct.path": "Direct TCP",
    "connect.direct.best": "局域网或公网主机",
    "connect.direct.note": "网络 listener 会自动加密，并使用 pairing 凭证。",
    "connect.ssh.path": "SSH forward",
    "connect.ssh.best": "已有 SSH 权限",
    "connect.ssh.note":
      "让 motifd 只监听 127.0.0.1，再转发一个本地端口。桌面端可在远端缺少 motifd 时通过 SSH 自动安装并启动它。",
    "connect.tailscale.path": "Tailscale",
    "connect.tailscale.best": "NAT、移动办公、私有设备",
    "connect.tailscale.note": "支持的 client 和 server 可以使用嵌入式 tsnet。",
    "connect.relay.path": "Rendezvous relay",
    "connect.relay.best": "直连困难时的二维码配对",
    "connect.relay.note": "relay 只转发加密字节；客户端仍然 pin 服务端证书。",
    "connect.browser.path": "Browser same-origin",
    "connect.browser.best": "本机 loopback 或可信 HTTPS host",
    "connect.browser.note": "motifd 在 RPC 和 WebSocket 路由旁边提供 Flutter Web 客户端。",
    "architecture.kicker": "整体如何协作",
    "architecture.title": "motifd 持有状态，客户端 attach 进去。",
    "architecture.copy":
      "RPC、事件流和 PTY 流共享同一套协议表面。Web 客户端可以由 motifd 内嵌提供；原生客户端也通过同样的 HTTP 和 WebSocket transport 连接同一个服务端模型。",
    "diagram.client1": "iOS App",
    "diagram.client2": "macOS App",
    "diagram.client3": "浏览器",
    "diagram.client4": "Linux / Windows",
    "diagram.transport": "HTTP RPC + WebSocket",
    "diagram.server1": "Sessions",
    "diagram.server2": "PTY 池",
    "diagram.server3": "文件操作",
    "diagram.server4": "Git diff",
    "diagram.host": "宿主文件系统、shell 和 git",
    "security.kicker": "安全模型",
    "security.title": "面向单用户设计，并明确信任边界。",
    "security.copy":
      "Motif 把运行 motifd 的机器视为可信执行环境。Shell 命令以该用户权限运行，workdir 访问由服务端路径检查约束。",
    "security.item1": "网络 listener 使用自签 TLS，并在客户端进行证书 pin。",
    "security.item2": "Pairing link 携带用于派生 bearer 鉴权的 psk 材料。",
    "security.item3": "Loopback 模式保持明文、无鉴权，只用于本机工作流。",
    "security.item4": "当你不想开放公网端口时，可以使用 Tailscale 或 SSH。",
    "faq.kicker": "FAQ",
    "faq.title": "常见问题",
    "faq.q1": "Motif 会把项目复制到客户端吗？",
    "faq.a1": "不会。workdir 留在运行 motifd 的机器上。客户端远程操作并渲染当前服务端状态。",
    "faq.q2": "可以从浏览器使用吗？",
    "faq.a2":
      "可以，适合 loopback、SSH forward 或可信 HTTPS origin。浏览器无法 pin Motif 的自签证书，所以网络配对场景推荐使用原生 App。",
    "faq.q3": "关闭 App 后会怎样？",
    "faq.a3": "客户端会 detach。Session 会继续留在服务端，直到你销毁它或停止 motifd。",
    "faq.q4": "Motif 是 AI agent 吗？",
    "faq.a4":
      "不是。当前产品是远程开发界面，不是 LLM agent。它聚焦 Session、终端、文件、git 和连接能力。",
    "faq.q5": "支持哪些平台？",
    "faq.a5":
      "Flutter 客户端目标平台包括 iOS、macOS、Android、Web、Linux 和 Windows。桌面构建可以包含内嵌 server 路径。",
    "faq.q6": "更多信息从哪里看？",
    "faq.a6":
      "在 GitHub 仓库的 docs/ 目录浏览 usage、rpc、tailscale、web-client 等文档。需要帮助或反馈 bug，请提交 GitHub issue。",
    "faq.q7": "我需要在远端主机上手动安装 motifd 吗？",
    "faq.a7":
      "不一定。对 SSH server 打开「Auto initialize」，桌面端会在远端缺少 motifd 时自动下载、安装并启动它（支持 Linux/macOS，x86_64/arm64）。在自己的电脑上，motifd 已内置在桌面 App 中。",
    "faq.q8": "Motif 收费吗？需要账号吗？",
    "faq.a8":
      "Motif 开源（MIT/Apache-2.0），自托管免费。无需账号或登录——客户端通过 pin 的 TLS 直接与你的 motifd 配对，不经过任何第三方服务。",
    "faq.q10": "Motif 成熟度如何？",
    "faq.a10":
      "Motif 在持续开发，并发布带 tag 的版本。当前版本和更新日志见 GitHub Releases。",
    "faq.q11": "motifd 服务端需要什么运行环境？",
    "faq.a11":
      "只需一个 motifd 二进制，支持 Linux 或 macOS（x86_64 或 arm64）。在 Linux 上可用 Docker 镜像，或直接运行二进制。不需要数据库或额外服务。",
    "footer.copy": "适配你真正会使用的所有设备的远程开发 Session。",
    "footer.appstore": "App Store",
    "footer.releases": "Releases",
    "footer.usage": "使用指南",
    "footer.rpc": "RPC",
    "footer.tailscale": "Tailscale",
    "footer.rzv": "Rendezvous",
    "footer.support": "支持",
    "footer.repo": "仓库",
  },
};

const savedLanguage = localStorage.getItem("motif-site-language");
const browserLanguage = navigator.language && navigator.language.toLowerCase().startsWith("zh")
  ? "zh"
  : "en";
let currentLanguage = savedLanguage || browserLanguage;

function applyLanguage(language) {
  const dictionary = translations[language] || translations.en;
  currentLanguage = language;
  document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
  document.body.dataset.lang = language;
  document.title =
    language === "zh" ? "Motif | 远程开发 Session" : "Motif | Remote development sessions";

  for (const element of document.querySelectorAll("[data-i18n]")) {
    const key = element.dataset.i18n;
    if (dictionary[key]) element.textContent = dictionary[key];
  }

  localStorage.setItem("motif-site-language", language);
}

document.querySelector("[data-lang-toggle]").addEventListener("click", () => {
  applyLanguage(currentLanguage === "en" ? "zh" : "en");
});

const header = document.querySelector("[data-header]");
function updateHeader() {
  header.classList.toggle("is-scrolled", window.scrollY > 18);
}

window.addEventListener("scroll", updateHeader, { passive: true });
applyLanguage(currentLanguage);
updateHeader();

// Screenshot lightbox: click to view large, navigate through all images.
(function setupLightbox() {
  const gallery = document.querySelector(".screenshot-gallery");
  if (!gallery) return;
  const figures = Array.from(gallery.querySelectorAll(".screenshot-card"));
  if (!figures.length) return;

  const labels = {
    en: { close: "Close", prev: "Previous", next: "Next", zoom: "View larger" },
    zh: { close: "关闭", prev: "上一张", next: "下一张", zoom: "查看大图" },
  };
  const lang = () => (document.body.dataset.lang === "zh" ? "zh" : "en");

  const items = figures.map((fig) => ({
    fig,
    frame: fig.querySelector(".screenshot-frame"),
    img: fig.querySelector("img"),
    titleEl: fig.querySelector("figcaption strong"),
    copyEl: fig.querySelector("figcaption span"),
    isPhone: fig.classList.contains("screenshot-card-phone"),
  }));

  const lb = document.createElement("div");
  lb.className = "lightbox";
  lb.setAttribute("aria-hidden", "true");
  lb.setAttribute("role", "dialog");
  lb.setAttribute("aria-modal", "true");
  lb.innerHTML =
    '<div class="lightbox-backdrop" data-lb-close></div>' +
    '<button class="lightbox-close" type="button" data-lb-close>' +
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"><line x1="6" y1="6" x2="18" y2="18"/><line x1="18" y1="6" x2="6" y2="18"/></svg></button>' +
    '<button class="lightbox-nav lightbox-prev" type="button" data-lb-prev>' +
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 6 9 12 15 18"/></svg></button>' +
    '<figure class="lightbox-figure">' +
    '<div class="lightbox-stage"><img class="lightbox-img" alt="" /></div>' +
    '<figcaption class="lightbox-caption"><strong class="lightbox-title"></strong><span class="lightbox-copy"></span><span class="lightbox-counter"></span></figcaption>' +
    "</figure>" +
    '<button class="lightbox-nav lightbox-next" type="button" data-lb-next>' +
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 6 15 12 9 18"/></svg></button>';
  document.body.appendChild(lb);

  const lbImg = lb.querySelector(".lightbox-img");
  const lbTitle = lb.querySelector(".lightbox-title");
  const lbCopy = lb.querySelector(".lightbox-copy");
  const lbCounter = lb.querySelector(".lightbox-counter");
  const lbFigure = lb.querySelector(".lightbox-figure");
  const btnClose = lb.querySelector(".lightbox-close");
  const btnPrev = lb.querySelector(".lightbox-prev");
  const btnNext = lb.querySelector(".lightbox-next");

  let current = -1;
  let lastFocus = null;

  function refreshLabels() {
    const t = labels[lang()];
    btnClose.setAttribute("aria-label", t.close);
    btnPrev.setAttribute("aria-label", t.prev);
    btnNext.setAttribute("aria-label", t.next);
    items.forEach((it) => {
      if (it.frame) it.frame.setAttribute("aria-label", t.zoom);
    });
  }

  function render(i) {
    const it = items[i];
    lbImg.src = it.img.currentSrc || it.img.src;
    lbImg.alt = it.img.alt;
    lbTitle.textContent = it.titleEl ? it.titleEl.textContent : "";
    lbCopy.textContent = it.copyEl ? it.copyEl.textContent : "";
    lbCounter.textContent = i + 1 + " / " + items.length;
    lbFigure.classList.toggle("is-phone", it.isPhone);
    current = i;
  }

  function open(i) {
    lastFocus = document.activeElement;
    render(i);
    lb.classList.add("is-open");
    lb.setAttribute("aria-hidden", "false");
    document.body.style.overflow = "hidden";
    btnClose.focus();
  }

  function close() {
    lb.classList.remove("is-open");
    lb.setAttribute("aria-hidden", "true");
    document.body.style.overflow = "";
    current = -1;
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  const go = (delta) => render((current + delta + items.length) % items.length);

  items.forEach((it, i) => {
    if (!it.frame || !it.img) return;
    it.frame.classList.add("is-zoomable");
    it.frame.setAttribute("role", "button");
    it.frame.setAttribute("tabindex", "0");
    it.frame.addEventListener("click", () => open(i));
    it.frame.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        open(i);
      }
    });
  });

  lb.addEventListener("click", (e) => {
    if (e.target.closest("[data-lb-close]")) close();
    else if (e.target.closest("[data-lb-next]")) go(1);
    else if (e.target.closest("[data-lb-prev]")) go(-1);
  });

  document.addEventListener("keydown", (e) => {
    if (!lb.classList.contains("is-open")) return;
    if (e.key === "Escape") close();
    else if (e.key === "ArrowRight") go(1);
    else if (e.key === "ArrowLeft") go(-1);
    else if (e.key === "Tab") {
      // simple focus trap across the three controls
      const order = [btnClose, btnPrev, btnNext];
      const idx = order.indexOf(document.activeElement);
      e.preventDefault();
      const nextIdx = (idx + (e.shiftKey ? -1 : 1) + order.length) % order.length;
      order[Math.max(0, nextIdx)].focus();
    }
  });

  let touchX = null;
  lb.addEventListener(
    "touchstart",
    (e) => {
      touchX = e.changedTouches[0].clientX;
    },
    { passive: true }
  );
  lb.addEventListener(
    "touchend",
    (e) => {
      if (touchX === null) return;
      const dx = e.changedTouches[0].clientX - touchX;
      touchX = null;
      if (Math.abs(dx) > 45) go(dx < 0 ? 1 : -1);
    },
    { passive: true }
  );

  document.querySelector("[data-lang-toggle]").addEventListener("click", refreshLabels);
  refreshLabels();
})();
