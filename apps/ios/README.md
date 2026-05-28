# Motif iOS

motif 的 iOS native App,包含:

- 纯 SwiftUI + libghostty 的原生终端 UI(`Motif/Native/`),通过 WebSocket/RPC 接入远端 motifd
- TailscaleKit (tsnet) 让 App 自身加入 tailnet,反代访问远端 motifd
- Doubao ASR(gfreezy/DoubaoASR SwiftPM 包),给底部输入栏的"按住说话"提供原生语音识别

## 第一次构建

```bash
brew install xcodegen
cd apps/ios
xcodegen                        # 由 Project.yml 生成 Motif.xcodeproj
open Motif.xcodeproj
```

或者纯命令行:

```bash
xcodebuild -project Motif.xcodeproj -scheme Motif \
    -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## 目录

```
apps/ios/
├── Project.yml              xcodegen 工程定义
├── Motif/                   App 源码
│   ├── MotifApp.swift
│   ├── ContentView.swift
│   ├── Native/              SwiftUI + libghostty 的原生终端 UI
│   ├── Tailscale/           TailscaleKit 包装
│   ├── ASR/                 AVAudioSession glue(识别本身由 DoubaoASR 包实现)
│   ├── Settings/            全局状态
│   └── Info.plist
└── vendor/                  外部 xcframework(ignore,由 build 脚本产出)
```

## 路线图

详见 `~/.claude/plans/sharded-tinkering-nest.md`:P0 → P6。
