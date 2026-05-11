# Motif iOS

motif 的 iOS native App，包含：

- WKWebView 加载 motif-web（从本地 127.0.0.1 的 HTTP 服务器加载 bundle 内资源）
- TailscaleKit (tsnet) 让 App 自身加入 tailnet，反代访问远端 motifd
- Doubao ASR（gfreezy/DoubaoASR SwiftPM 包），给网页里的"按住说话"提供原生语音识别

## 第一次构建

```bash
brew install xcodegen
cd ios
./scripts/sync-web.sh           # 把 ../crates/motif-web/static/ 拷到 Motif/Resources/web/
xcodegen                        # 由 Project.yml 生成 Motif.xcodeproj
open Motif.xcodeproj
```

或者纯命令行：

```bash
xcodebuild -project Motif.xcodeproj -scheme Motif \
    -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## 目录

```
ios/
├── Project.yml              xcodegen 工程定义
├── Motif/                   App 源码
│   ├── MotifApp.swift
│   ├── ContentView.swift
│   ├── WebView/             WKWebView + 本地 HTTP server
│   ├── Tailscale/           TailscaleKit 包装（待实现）
│   ├── ASR/                 AVAudioSession glue（识别本身由 DoubaoASR 包实现）
│   ├── Settings/            全局状态
│   ├── Info.plist
│   └── Resources/web/       同步自 ../crates/motif-web/static（ignore）
├── scripts/
│   └── sync-web.sh          web 资源同步
└── vendor/                  外部 xcframework（ignore，由 build 脚本产出）
```

## 路线图

详见 `~/.claude/plans/sharded-tinkering-nest.md`：P0 → P6。
