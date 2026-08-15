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
    "hero.eyebrow": "Remote terminal, files, git, and Codex in one live workspace",
    "hero.title": "Motif",
    "hero.copy":
      "Keep your workdir, terminals, files, git state, and Codex threads on one machine. Attach from any client and continue the same work.",
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
      "Motif combines a Rust server named motifd with Flutter clients. The server owns the workdir, PTY pool, filesystem operations, git diff, and an optional Codex app-server bridge. Clients are thin surfaces that attach, detach, and reconnect.",
    "intro.copy2":
      "The result feels like code-server plus tmux attach, with Codex alongside it: open the same workspace from a laptop, phone, tablet, desktop app, or browser and continue terminals, files, diffs, and agent threads.",
    "screenshots.kicker": "Product walkthrough",
    "screenshots.title": "Every core workflow, captured from a live review server.",
    "screenshots.copy":
      "These are real macOS and iPhone captures connected to a motifd review server: workspaces, terminal attach, files, git diff, Codex threads, Side Chat, settings, and the embedded server view.",
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
    "screenshots.iphoneGit.title": "Review changes before shipping",
    "screenshots.iphoneGit.copy":
      "The same diff is readable on mobile, including working/staged tabs and per-file patch text.",
    "screenshots.iphoneWorkspaces.title": "Every workspace, one connection",
    "screenshots.iphoneWorkspaces.copy":
      "Reconnect from your phone and see every long-lived workspace on the selected server.",
    "screenshots.iphoneCodex.title": "Codex on the go",
    "screenshots.iphoneCodex.copy":
      "Review a release, inspect changes, and continue a Codex task from the same remote workdir.",
    "screenshots.iphoneThreads.title": "Codex thread sidebar",
    "screenshots.iphoneThreads.copy":
      "Browse, search, resume, and organize persistent Codex threads without losing the active conversation.",
    "screenshots.iphoneSideChat.title": "Explore in Side Chat",
    "screenshots.iphoneSideChat.copy":
      "Investigate a parallel question without appending messages to the main Codex thread.",
    "screenshots.iphoneTerminal.title": "A real mobile terminal",
    "screenshots.iphoneTerminal.copy":
      "Use quick keys, reusable commands, photo attach, voice input, and send controls from the phone.",
    "screenshots.iphoneFiles.title": "Mobile files",
    "screenshots.iphoneFiles.copy":
      "Open the remote file tree on iPhone for quick inspection and file-level actions.",
    "features.kicker": "Everything in the session",
    "features.title": "Core features",
    "features.copy":
      "Motif covers the daily remote development loop: terminals, files, diffs, Codex, connectivity, and cross-device continuity.",
    "feature.codex.title": "Codex workspace",
    "feature.codex.copy":
      "Run the Codex CLI on the motifd host and stream conversations, commands, diffs, plans, and approvals to every client.",
    "feature.sidechat.title": "Threads, forks, and Side Chat",
    "feature.sidechat.copy":
      "Resume persistent threads, fork from a turn, or explore a temporary branch without rewriting the main conversation.",
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
    "compare.row8": "Codex threads, persistent forks, and Side Chat",
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
      "Motif is not an AI model or account provider. It can integrate the Codex CLI installed and authenticated on your motifd host, exposing Codex threads, forks, approvals, and Side Chat alongside terminals, files, and git.",
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
    "nav.screenshots": "产品截图",
    "nav.compare": "方案对比",
    "nav.use": "使用方式",
    "nav.rzv": "中继",
    "nav.connect": "如何连接",
    "nav.architecture": "工作原理",
    "nav.faq": "常见问题",
    "nav.docs": "文档",
    "nav.appstore": "App Store",
    "hero.eyebrow": "终端、文件、Git 和 Codex，换台设备也能接着做",
    "hero.title": "Motif",
    "hero.copy":
      "工作目录、终端、文件、Git 状态和 Codex 对话都留在同一台机器上。无论从哪台设备连接，都能接着上次的进度继续。",
    "hero.ctaAppStore": "前往 App Store 下载",
    "hero.ctaOther": "其他平台",
    "hero.availability":
      "iOS 版可从 App Store 下载；macOS、Android、Linux 和 Windows 版本可在 GitHub Releases 获取；Web 版直接在浏览器中运行。",
    "hero.openness":
      "开源（MIT/Apache-2.0）、支持自托管，也不要求注册 Motif 账号。代码始终留在运行 motifd 的机器上。",
    "hero.fact1.value": "会话常驻",
    "hero.fact1.label": "客户端断开后，会话仍由 motifd 持续运行",
    "hero.fact2.value": "多端同步",
    "hero.fact2.label": "所有设备看到的都是同一份会话状态",
    "hero.fact3.value": "随处连接",
    "hero.fact3.label": "支持配对、SSH、Tailscale、中继和浏览器同源访问",
    "intro.kicker": "Motif 是什么",
    "intro.title": "一个随时都能接着用的远程开发工作区。",
    "intro.copy1":
      "Motif 由 Rust 编写的 motifd 服务端和 Flutter 客户端组成。工作目录、终端会话、文件操作、Git 改动以及可选的 Codex app-server 都由服务端管理；客户端只负责连接、操作和显示。",
    "intro.copy2":
      "你可以把它理解为 code-server 与 tmux attach 的结合，再加上 Codex：无论使用笔记本、手机、平板、桌面应用还是浏览器，打开的都是同一个工作区，终端、文件、改动和 Codex 对话都能接着上次继续。",
    "screenshots.kicker": "产品实拍",
    "screenshots.title": "核心工作流，全部来自真实服务器。",
    "screenshots.copy":
      "以下截图均来自连接到 motifd 演示服务器的 macOS 和 iPhone 应用，涵盖工作区、终端、文件、Git 改动、Codex 对话、Side Chat、设置和内置服务端。",
    "screenshots.macGit.title": "结合上下文查看 Git 改动",
    "screenshots.macGit.copy":
      "在文件树和实时终端旁查看尚未提交的改动，快捷命令栏也始终触手可及。",
    "screenshots.macSessions.title": "会话列表",
    "screenshots.macSessions.copy":
      "一眼查看服务端上的所有常驻会话，包括工作目录、创建时间和当前连接的客户端数量。",
    "screenshots.macTerminal.title": "多个远程终端",
    "screenshots.macTerminal.copy":
      "连接服务端的 Shell，终端输出保存在服务端，并可随时切换不同的终端标签。",
    "screenshots.macFiles.title": "文件树",
    "screenshots.macFiles.copy":
      "直接浏览远程工作目录中的文件和文件夹，无需先把项目复制到本地。",
    "screenshots.macServer.title": "内置服务端",
    "screenshots.macServer.copy":
      "直接在桌面应用中运行 motifd，可选择仅本机、局域网或关闭监听，并查看中继与 Tailscale 访问地址。",
    "screenshots.macSettings.title": "终端设置",
    "screenshots.macSettings.copy":
      "每台设备都可以独立调整字号和主题，服务端会话不会受到影响。",
    "screenshots.iphoneGit.title": "发布前检查改动",
    "screenshots.iphoneGit.copy":
      "在手机上也能清楚查看同一份改动，切换未暂存与已暂存内容，并按文件阅读差异。",
    "screenshots.iphoneWorkspaces.title": "连一次，查看所有工作区",
    "screenshots.iphoneWorkspaces.copy":
      "用手机连接服务器，即可查看上面所有持续运行的工作区。",
    "screenshots.iphoneCodex.title": "随时继续 Codex",
    "screenshots.iphoneCodex.copy":
      "在同一个远程工作目录中检查发布情况、查看改动，并继续处理 Codex 任务。",
    "screenshots.iphoneThreads.title": "Codex 对话侧边栏",
    "screenshots.iphoneThreads.copy":
      "随时浏览、搜索、恢复和整理历史对话，当前内容也不会丢失。",
    "screenshots.iphoneSideChat.title": "用 Side Chat 并行探索",
    "screenshots.iphoneSideChat.copy":
      "单独验证一个旁支问题，不打乱主 Codex 对话。",
    "screenshots.iphoneTerminal.title": "手机上的完整终端",
    "screenshots.iphoneTerminal.copy":
      "通过快捷键、常用命令、照片附件和语音输入，让手机上的终端操作同样顺手。",
    "screenshots.iphoneFiles.title": "移动端文件",
    "screenshots.iphoneFiles.copy":
      "在 iPhone 上打开远程文件树，快速查看和管理项目文件。",
    "features.kicker": "一个工作区，完整开发流程",
    "features.title": "核心功能",
    "features.copy":
      "从终端、文件和 Git 改动，到 Codex、远程连接与多设备接力，日常开发所需的流程都在这里。",
    "feature.codex.title": "Codex 工作区",
    "feature.codex.copy":
      "Motif 会在 motifd 主机上调用 Codex CLI，并把对话、命令、代码改动、计划和审批实时同步到各个客户端。",
    "feature.sidechat.title": "对话、分支与 Side Chat",
    "feature.sidechat.copy":
      "恢复历史对话、从任意消息派生新的持久分支，或通过 Side Chat 临时探索，不打乱主线。",
    "feature.terminal.title": "Ghostty 驱动的终端",
    "feature.terminal.copy":
      "服务端只传输 PTY 数据，画面由客户端渲染：原生平台使用 libghostty，浏览器使用 WebAssembly。",
    "feature.sessions.title": "客户端断开，会话仍在",
    "feature.sessions.copy":
      "工作目录和终端状态都保留在服务端，即使关闭客户端，也可以稍后回来继续。",
    "feature.mirror.title": "多设备实时同步",
    "feature.mirror.copy":
      "多台设备可以同时连接同一会话，看到一致的终端输出、文件树和 Git 状态。",
    "feature.files.title": "文件树与编辑",
    "feature.files.copy":
      "直接在远程工作目录中浏览、新建、重命名、删除、预览和编辑文件，也能妥善处理写入冲突。",
    "feature.git.title": "随时查看 Git 改动",
    "feature.git.copy": "无需离开当前工作区，即可查看全部改动或逐个文件检查差异。",
    "feature.quick.title": "高效输入快捷命令",
    "feature.quick.copy":
      "通过可复用的命令集、可锁定的修饰键和输入编辑器，让手机与桌面端的终端操作都更高效。",
    "feature.connectivity.title": "多种连接方式",
    "feature.connectivity.copy":
      "可通过内置 Tailscale（tsnet）、中继、motif://pair 链接或二维码连接 motifd，并使用证书固定与 PSK 派生令牌保障访问安全。",
    "feature.web.title": "内嵌 Web 客户端",
    "feature.web.copy":
      "motifd 可在同一站点下提供 Flutter Web 客户端、RPC、事件流和 PTY 数据流。",
    "feature.desktop.title": "桌面应用内置服务端",
    "feature.desktop.copy":
      "桌面版可直接运行 motifd，并通过“服务端”页面或系统托盘进行管理。",
    "feature.sshprov.title": "SSH 自动部署",
    "feature.sshprov.copy":
      "通过 SSH 连接时，如果远程主机尚未安装 motifd，Motif 可以自动完成下载、安装和启动。",
    "feature.input.title": "语音、照片和图片",
    "feature.input.copy":
      "原生客户端支持语音输入、添加照片和查看图片，并针对终端操作提供便捷的输入辅助。",
    "feature.push.title": "端到端加密通知",
    "feature.push.copy":
      "推送内容使用 AES-256-GCM 端到端加密；iOS 直接使用 APNs，不依赖 Firebase。",
    "compare.kicker": "方案对比",
    "compare.title": "为什么用 Motif，而不是 SSH + tmux、mosh 或浏览器 IDE？",
    "compare.copy":
      "Motif 将会话状态完整保留在服务端，并同步到每台设备的原生客户端，同时内置文件管理、Git 改动查看和多种连接方式。下面是它与常见方案的区别。",
    "compare.col.capability": "能力",
    "compare.col.ssh": "SSH + tmux",
    "compare.col.mosh": "mosh",
    "compare.col.code": "code-server",
    "compare.col.motif": "Motif",
    "compare.row1": "服务端会话常驻，并在多端保持同步",
    "compare.row2": "切换网络或信号不稳时仍可继续（本地回显）",
    "compare.row3": "提供手机、平板和桌面原生应用",
    "compare.row4": "原生滚动回看，无需进入 copy mode",
    "compare.row5": "文件树、文件编辑和 Git 改动查看",
    "compare.row6": "自定义快捷键与快捷命令",
    "compare.row7": "将远程端口映射到本机访问",
    "compare.row8": "Codex 历史对话、持久分支和 Side Chat",
    "compare.row9": "内置 Tailscale、中继和二维码配对",
    "compare.legend": "✓ 开箱即用 · ~ 需要额外配置 · — 通常不支持",
    "use.kicker": "按需要部署",
    "use.title": "既可以常驻服务器，也可以把自己的电脑变成远程开发主机。",
    "use.lead":
      "所有会话都由 motifd 托管。桌面应用已经内置 motifd，可以在本机一键启动；手机、浏览器和其他电脑只需连接到这台开发主机。",
    "run.server.title": "部署到服务器",
    "run.server.copy":
      "把 motifd 部署到 VPS、云主机、远程工作站或长期在线的开发机，任何能够访问它的客户端都可以连接。",
    "run.server.pair":
      "启动后，从日志中找到配对链接，再用任意客户端扫码或粘贴：",
    "run.computer.title": "运行在自己的电脑上",
    "run.computer.copy":
      "桌面应用已内置 motifd，无需另行安装。从“服务端”页面或系统托盘启动后，就能通过手机、浏览器或另一台电脑连接回来。",
    "run.computer.step1": "打开 Motif 桌面版。",
    "run.computer.step2": "选择仅本机、局域网、Tailscale 或中继配对。",
    "run.computer.step3": "在另一台设备上扫描或粘贴配对链接。",
    "rzv.kicker": "中继配对",
    "rzv.title": "部署一套中继服务，直连不便时也能轻松配对。",
    "rzv.lead":
      "将中继服务部署在 HTTPS/WSS 反向代理之后。motifd 使用 JWT 进行身份验证，中继可按用户限速，而 Motif 内层的 TLS/PSK 加密始终保持端到端。",
    "rzv.deploy.title": "部署中继服务",
    "rzv.deploy.copy":
      "不要直接暴露 WebSocket 端口，只通过 HTTPS 代理提供访问，并挂载 JWT 与限速配置。",
    "rzv.motifd.title": "将 motifd 接入中继",
    "rzv.motifd.copy":
      "仅使用中继时，需要同时设置 MOTIFD_RZV_RELAY 和 MOTIFD_RZV_JWT_FILE；直接运行二进制则使用对应的 --rzv-relay 与 --rzv-jwt-file 参数。",
    "rzv.motifd.docker": "Docker：",
    "rzv.motifd.binary": "二进制：",
    "rzv.pair.title": "配对并验证",
    "rzv.pair.copy":
      "从 motifd 日志中复制 motif://pair 链接，再到 Motif 中扫码或粘贴。链接里已包含中继地址、PSK 和服务端证书指纹。",
    "rzv.notes.title": "运维要点",
    "rzv.note1": "中继能看到 JWT 和配对元数据，但实际应用流量始终是内层 TLS 密文。",
    "rzv.note2": "请持久化 motifd 的 /data 目录，确保 PSK 和证书指纹在重启后保持不变。",
    "rzv.note3": "一套中继服务可以同时连接多组彼此独立的 motifd 与客户端。",
    "rzv.docs": "查看完整中继文档",
    "connect.kicker": "连接方式",
    "connect.title": "根据网络环境，选择最合适的连接方式。",
    "connect.col.path": "方式",
    "connect.col.best": "适合场景",
    "connect.col.note": "说明",
    "connect.direct.path": "TCP 直连",
    "connect.direct.best": "局域网或公网主机",
    "connect.direct.note": "监听网络连接时会自动启用加密，并使用配对凭证进行验证。",
    "connect.ssh.path": "SSH 端口转发",
    "connect.ssh.best": "已有 SSH 权限",
    "connect.ssh.note":
      "让 motifd 仅监听 127.0.0.1，再通过 SSH 转发到本地端口。如果远程主机尚未安装 motifd，桌面端还可以自动完成安装和启动。",
    "connect.tailscale.path": "Tailscale",
    "connect.tailscale.best": "穿越 NAT、外出办公或连接私有设备",
    "connect.tailscale.note": "在支持的平台上，客户端和服务端都可直接使用内置的 tsnet。",
    "connect.relay.path": "中继服务",
    "connect.relay.best": "直连困难时的二维码配对",
    "connect.relay.note": "中继只负责转发加密数据，客户端仍会校验并固定服务端证书。",
    "connect.browser.path": "浏览器同源访问",
    "connect.browser.best": "本机访问或可信的 HTTPS 站点",
    "connect.browser.note": "motifd 会在同一来源下提供 Flutter Web 客户端、RPC 和 WebSocket 接口。",
    "architecture.kicker": "工作原理",
    "architecture.title": "状态都在 motifd，客户端随时连接。",
    "architecture.copy":
      "RPC、事件流和 PTY 数据流共用一套协议。motifd 可以直接提供 Web 客户端，原生客户端则通过同样的 HTTP 与 WebSocket 接口访问同一份服务端状态。",
    "diagram.client1": "iOS 应用",
    "diagram.client2": "macOS 应用",
    "diagram.client3": "浏览器",
    "diagram.client4": "Linux / Windows",
    "diagram.transport": "HTTP RPC + WebSocket",
    "diagram.server1": "会话",
    "diagram.server2": "PTY 池",
    "diagram.server3": "文件操作",
    "diagram.server4": "Git 改动",
    "diagram.host": "主机文件系统、Shell 和 Git",
    "security.kicker": "安全模型",
    "security.title": "为单用户场景设计，信任边界清晰明确。",
    "security.copy":
      "Motif 将运行 motifd 的机器视为可信执行环境。Shell 命令会以 motifd 所属用户的权限执行，服务端路径检查则限制了工作目录的访问范围。",
    "security.item1": "网络连接使用自签名 TLS，客户端会固定并校验服务端证书。",
    "security.item2": "配对链接包含用于生成访问令牌的 PSK 信息。",
    "security.item3": "仅本机模式使用明文且不做身份验证，因此只适合本机访问。",
    "security.item4": "当你不想开放公网端口时，可以使用 Tailscale 或 SSH。",
    "faq.kicker": "你可能想知道",
    "faq.title": "常见问题",
    "faq.q1": "Motif 会把项目复制到客户端吗？",
    "faq.a1": "不会。工作目录始终留在运行 motifd 的机器上，客户端只负责远程操作和显示服务端状态。",
    "faq.q2": "可以从浏览器使用吗？",
    "faq.a2":
      "可以。浏览器适合通过本机地址、SSH 端口转发或可信的 HTTPS 站点访问。由于浏览器无法固定 Motif 的自签名证书，其他网络配对场景更推荐使用原生应用。",
    "faq.q3": "关闭应用后，会话会停止吗？",
    "faq.a3": "不会。关闭应用只会断开客户端，会话仍在服务端运行，直到你主动结束会话或停止 motifd。",
    "faq.q4": "Motif 自带 AI 模型吗？",
    "faq.a4":
      "不自带。Motif 不提供 AI 模型或账号，而是连接已在 motifd 主机上安装并登录的 Codex CLI，把 Codex 对话、分支、审批和 Side Chat 与终端、文件、Git 整合在一起。",
    "faq.q5": "支持哪些平台？",
    "faq.a5":
      "客户端支持 iOS、macOS、Android、Web、Linux 和 Windows；桌面版还可以直接运行内置服务端。",
    "faq.q6": "在哪里可以查看更多资料？",
    "faq.a6":
      "GitHub 仓库的 docs/ 目录中提供了使用指南、RPC、Tailscale 和 Web 客户端等文档。需要帮助或反馈问题时，可以提交 GitHub Issue。",
    "faq.q7": "我需要在远端主机上手动安装 motifd 吗？",
    "faq.a7":
      "不一定。通过 SSH 连接时开启“自动初始化”，桌面端会在需要时自动下载、安装并启动 motifd（支持 Linux 和 macOS，以及 x86_64 和 arm64）。如果连接的是自己的电脑，桌面应用已经内置 motifd。",
    "faq.q8": "Motif 收费吗？需要账号吗？",
    "faq.a8":
      "Motif 采用 MIT/Apache-2.0 开源许可，可免费自行托管，也不要求注册 Motif 账号。客户端会通过证书固定和配对凭证安全连接到你的 motifd。",
    "faq.q10": "Motif 目前稳定吗？",
    "faq.a10":
      "Motif 仍在持续迭代，并会定期发布版本。你可以在 GitHub Releases 查看最新版本和更新记录。",
    "faq.q11": "motifd 服务端需要什么运行环境？",
    "faq.a11":
      "motifd 只需要一个二进制文件，支持 Linux 和 macOS（x86_64 或 arm64）。在 Linux 上既可以使用 Docker 镜像，也可以直接运行二进制，无需数据库或其他配套服务。",
    "footer.copy": "在你常用的每台设备上，随时继续远程开发。",
    "footer.appstore": "App Store",
    "footer.releases": "版本下载",
    "footer.usage": "使用指南",
    "footer.rpc": "RPC",
    "footer.tailscale": "Tailscale",
    "footer.rzv": "中继",
    "footer.support": "支持",
    "footer.repo": "代码仓库",
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
    language === "zh"
      ? "Motif | 随时继续的远程开发工作区"
      : "Motif | Remote development with Terminal and Codex";

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
