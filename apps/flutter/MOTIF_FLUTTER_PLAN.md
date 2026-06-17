# Motif → Flutter Migration Plan

Migrate the Motif iOS app (`~/AllSunday/claude-proj/motif/apps/ios`, ~13.5k LOC SwiftUI) to
a single Flutter codebase targeting **iOS, macOS, Web, Windows, Android, Linux**, at feature
parity with the iOS implementation.

This plan lives in the `flutter_ghostty` repo because that project already solves the hardest
piece — embedding **libghostty** as a terminal renderer in Flutter via `dart:ffi`. The Motif app
is built on top of it under `lib/motif/`.

---

## 1. What Motif Is

Motif is a **remote terminal client**. The shell/PTY runs on a remote `motifd` server; the app:

- Connects to `motifd` over **HTTP-RPC + WebSocket** (optionally through a Tailscale tunnel).
- Renders remote PTY output locally with **libghostty** (the VT engine), fed network bytes.
- Sends keystrokes/mouse/resize back over a per-PTY WebSocket.
- Adds: multi-session/multi-view management, quick-command bar, voice input (ASR), file tree,
  git diff viewer, file preview/edit, and E2E-encrypted push notifications.

Implication for Flutter: the existing `flutter_ghostty` terminal reads a **local** PTY
(`lib/src/pty_ffi.dart`). Motif must instead **feed bytes from the network** into
`ghostty_terminal_vt_write` and route encoded input to the WebSocket. `TerminalState` becomes
I/O-pluggable.

---

## 2. Repository / Module Layout

Keep `lib/src/` (the reusable ghostty terminal layer) as-is — the native-asset hook references
assets by name (`src/ghostty_bindings.g.dart`, `src/pty_ffi.dart`). Add the Motif app alongside:

```
lib/
  src/                      # reusable ghostty terminal embedder (existing — do not move)
  motif/
    models/                 # wire/domain models (MotifProto port)
    net/
      rpc_client.dart       # HTTP-RPC + /events + /pty WebSocket transport
      shell_integration.dart# OSC 133/777/7 parser → ShellEvent stream
      transport.dart        # platform HTTP/WS abstraction (dart:io vs web)
    state/
      app_state.dart        # top-level app state (servers, settings, commands)
      motif_client.dart     # connection lifecycle + session/pty/view state
      settings_store.dart   # persisted settings (font, theme, quick commands)
    terminal/
      remote_terminal.dart  # network-fed TerminalState wrapper + widget
    ui/
      theme/                # MotifTheme tokens + button widgets
      screens/              # welcome, connection, session list, session, settings
      widgets/              # bottom input bar, quick command row, tab bar, panels
    platform/               # platform-channel plugins (tailscale, asr, push, secure storage)
    app.dart                # MaterialApp / routing root
  main_motif.dart           # Motif entrypoint (separate from main.dart demo)
```

---

## 3. Wire Contract (authoritative — keep names EXACT, JSON wire)

### 3.1 RPC methods (HTTP POST `/rpc/<method>`, Bearer token, `X-Motif-Session` header)

| Method | Params | Result |
|---|---|---|
| `ping` (GET `/ping`, unauth) | — | `service, version` |
| `session.list` | — | `sessions: [SessionInfo]` |
| `session.create` | `name, workdir` | `session: SessionInfo` |
| `session.attach` | `name, last_seq?, term_fg?, term_bg?, theme?` | `session, client_id?, clients?, ptys?, views?, active_view?, last_seq?, theme?` |
| `session.detach` | — | — |
| `session.destroy` | `name` | — |
| `session.set_palette` | `term_fg?, term_bg?, theme?` | — |
| `pty.create` | `cmd?, cwd?, env?:[[String]], cols, rows` | `info: PtyInfo` |
| `pty.resize` | `pty_id, cols, rows` | — |
| `pty.kill` | `pty_id` | — |
| `view.open` | `spec: ViewSpec, activate` | `view: ViewInfo` |
| `view.activate` | `view_id?` | — |
| `view.close` | `view_id` | — |
| `view.move` | `view_id, to_index` | — |
| `fs.tree` | `path, depth?, show_hidden?` | `path, entries: [TreeEntry]` |
| `fs.stat` | `path` | `type, size, mtime, git_status?` |
| `fs.read` | `path, max_bytes?` | `content_b64, sha256, truncated, binary, mime?` |
| `fs.write` | `path, content_b64, expected_sha256?, force` | `sha256` |
| `fs.mkdir` / `fs.remove` | `path` | — |
| `fs.rename` | `from, to` | — |
| `git.status` | `cwd?` | `branch?, ahead, behind, files: [GitFile]` |
| `git.diff` | `path?, staged, cwd?` | `patch` |
| `git.diffSummary` | `path?, staged, cwd?` | `files: [DiffSummaryFile]` |
| `device.register` | `device_token, platform, environment?, enc_key, app_version?, muted_sessions?` | `instance_id` |
| `device.unregister` | `device_token` | — |
| `device.setSessionMuted` | `device_token, session, muted` | — |

Special channels: `fs.write` binary form (POST `application/octet-stream`, params in query → `sha256`);
per-PTY write = raw binary frame on `/pty/<id>`; `activatePty`/`deactivatePty` open/close that WS.

### 3.2 Events (from `/events` WS, and client-synthesized from `/pty`). All carry `seq?`.

`pty.output {pty_id, data_b64, block_id?, scope}` · `pty.exited {pty_id, exit_code?}` ·
`pty.created {info}` · `pty.resize {pty_id, cols, rows}` · `pty.cwd_changed {pty_id, cwd}` ·
`pty.command_started {pty_id, block_id, text, cwd?, started_at?}` ·
`pty.command_finished {pty_id, block_id, exit_code?, finished_at?}` ·
`pty.shell_bootstrapped {pty_id, shell}` · `pty.shell_context {pty_id, ctx}` ·
`view.opened {view}` · `view.closed {view_id}` · `view.active_changed {view_id?}` ·
`view.moved {order:[String]}` · `tree.changed {paths}` · `git.changed {}` ·
`session.theme_changed {theme}` · `client.joined {client_id, since?}` · `client.left {client_id}` ·
`notification {title, body, session_id?, kind}`.

### 3.3 Models

```
PingInfo{service, version}
SessionInfo{id=name, name, workdir?, created_at?, client_count?}
ClientInfo{id, since?}
ShellContext{branch?, head?, venv?, conda?, node?}
ShellKind = bash|zsh|fish|unknown
PtyInfo{id, cmd?, cwd?, cols, rows, alive?, created_at?}
ViewInfo{id, spec: ViewSpec, created_at?}
ViewSpec = pty{pty_id} | preview{path} | diff{staged, path?} | image{path} | other{typeName}
FileType = file|dir|symlink
GitFileStatus = unmodified|modified|added|deleted|renamed|copied|untracked|ignored|conflicted
TreeEntry{name, type, size, mtime, git_status?}
GitFile{path, staged: GitFileStatus, unstaged: GitFileStatus}
DiffSummaryFile{path, additions, deletions}
```

### 3.4 Shell integration (client-side OSC parser → ShellEvent)

Scan PTY bytes for OSC sequences (`ESC ] … (BEL | ESC \\)`):
- `OSC 7 ;file://host/path` → `cwdChanged(cwd)` (URL-decode)
- `OSC 133;A` → `promptStarted(blockID)` (blockID = locally-generated 26-char ULID-ish on first A)
- `OSC 133;B` → `promptEnded(blockID)`
- `OSC 133;C[;cmdline_url=…]` → `commandStarted(blockID, text, cwd, startedAt)`
- `OSC 133;D[;<exit>]` → `commandFinished(blockID, exit?, finishedAt)`
- `OSC 777;E;<hex>` / `OSC 7770;<hex>` → command text (stashed as pendingCmd until start marker)
- `OSC 777;P;Cwd=<url>` → `cwdChanged`; `OSC 777;P;Context=<hex>` / `OSC 7771;<hex>` → `shellContext(map)`
- first OSC seen → `bootstrapped(shell)`

State machine: unknown →A→ atPrompt →B→ composing →C→ running →D→ unknown.
`activeScope ∈ {Prompt, Command, Output, Passthrough}` tags emitted `pty.output`. Unknown OSC pass through verbatim.

---

## 4. App State & Persistence (port targets)

- **AppState**: `tailscale`, `servers` (MotifServerStore), `commands` (QuickCommandStore),
  `motif` (MotifClient), `terminalSettings`, UI flags (`isShowingConnection/Settings`),
  `pendingDeepLink`, `nativeReloadKey`.
- **MotifServer**`{id:UUID, name, host, port=7777, token, kind: direct|tailscale|rendezvous|ssh}` →
  stored in **secure storage** (was Keychain `io.allsunday.motif.servers` / `list.v1`); active id in prefs `activeServerID`.
- **TerminalSettings**`{fontSize 8–28 (def 10), theme: system|light|dark}` → prefs `motif.terminalSettings.v1`.
  Resolves to OSC 10/11 fg/bg + light/dark color scheme broadcast on attach.
- **QuickCommand**`{id, label, symbol?, payload:bytes, sendImmediately, kind: bytes|paste|ctrl|alt|shift|cd, modifiers:{ctrl,alt,shift}}`;
  **QuickCommandSet**`{id, name, matches:[program], commands}`. Prefs `motif.quickCommands.v1` / `.sets.v1`.
  Resolution by running-program basename; sets override global.
- **MotifClient state**: `state ∈ disconnected|connecting|connected|attached(name)|failed(msg)`;
  `sessions, ptys, views, activeViewID, clients, lastSeq, resumeSeqs, intendedSession,
  pendingLocalViewID, termFg/Bg/Theme, sessionTheme, runningCommand[pty], shellKind[pty],
  shellContext[pty], treeChangeTick, gitChangeTick, carriedPtyCursors, isForeground`.
- **Connection lifecycle**: pick URLSession config (tailscale proxy vs direct) → (tailscale) resolve
  host + pre-warm path → `ping` with startup retry → store rpc → seed carried pty cursors →
  register push → spawn events loop → auto-reattach `intendedSession`. On events-loop end →
  `handleConnectionLost` (save `resumeSeqs`, snapshot pty cursors, keep session state, state=failed).
  Reconnect backoff 1,2,4,8,15,15s (in NativeRoot).

State management choice for Flutter: **Riverpod** (or `ChangeNotifier` + `provider`). Plan assumes
Riverpod `Notifier`s mirroring the Swift `@Observable` objects.

---

## 5. UI (screen inventory → Flutter)

Welcome (first-run add server) · ConnectionView (servers + Tailscale) · SessionListView (picker +
create) · **SessionView** (tab bar + active pane + BottomInputBar) · GitDiffPanel · FileTreePanel
(sheet) · PreviewPane · ChangeDirectoryPanel (sheet) · TerminalSettingsSheet · QuickCommandEditor /
SetsView · LiveNotificationBanner.

**Design system (MotifTheme)** — port to a Flutter `ThemeExtension`:
- Colors: accent, accentContainer, background, surface, surfaceElevated, surfaceTranslucent,
  border, borderStrong, textPrimary/Secondary/Tertiary, textOnAccent, danger, shadow (light+dark).
- Spacing xs4 sm8 md12 lg16 xl24 xxl32 xxxl40 · Radius xs8 sm12 md16 lg20 xl24 · control sizes 32/40/48/64.
- Buttons: capsule text button + circular icon button, roles filled|tinted|bordered|plain,
  sizes sm|md|lg(|xl), press feedback (opacity .72, scale .96, 160ms).

**SessionView** is the centerpiece: horizontal scrollable tab bar (pty/preview/diff/image), active
pane, keyboard-lift handling, BottomInputBar (quick-command row with sticky Ctrl/Alt/Shift chips +
composer + mic + send + photo attach). Grid-settling "OneShotGate" before first `/pty` open.

---

## 6. Platform-specific risk areas & strategy

| Feature | iOS | macOS | Android | Windows | Linux | Web |
|---|---|---|---|---|---|---|
| **libghostty** (FFI) | build for iOS | done | build (NDK) | build (Zig) | build (Zig) | **WASM + JS interop** (no dart:ffi) |
| **Tailscale** | TailscaleKit | TailscaleKit | tsnet/Go via JNI | tsnet/Go | tsnet/Go | none → require user VPN / direct only |
| **ASR** | DoubaoASR XCFramework | platform speech | Android STT / cloud | cloud/SAPI | cloud | Web Speech API |
| **Push (E2E)** | APNs + NSE AES-GCM | APNs + NSE | FCM + decrypt | WNS/none | none | Web Push |
| **Secure storage** | Keychain | Keychain | Keystore | DPAPI | libsecret | IndexedDB (best-effort) |

Abstractions: `TerminalEngine`, `TailscaleService`, `SpeechService`, `PushService`, `SecureStore` —
each an interface with `direct/no-op` fallbacks so the app runs on every platform from day one and
gains native capability incrementally. **Direct (non-Tailscale) servers + keyboard input work on all
6 platforms first**; Tailscale/ASR/push are additive.

E2E push scheme: per-device **AES-256-GCM** key (32 random bytes), base64 → `device.register.enc_key`.
Server encrypts payload; platform notification-service decrypts using key from secure storage
(shared app-group on iOS). Deep link payload carries session name + instance_id.

---

## 7. Phased delivery

- **P0 — Foundation (this session):** plan; scaffold `lib/motif`; port models + JSON codec; shell
  parser; `RpcClient` (dart:io HTTP+WS); `MotifClient` skeleton + events loop; MotifTheme + buttons;
  network-fed `TerminalState` mode. Pure-Dart unit tests for codec + shell parser. `flutter analyze` clean.
- **P1 — Connect & run a session (macOS first):** Welcome/Connection/SessionList/SessionView wired to
  a real `motifd` (direct server); attach → open `/pty` → render → type. Settings persistence + secure store.
- **P2 — Terminal parity:** tabs/views, resize+grid-settling, sticky modifiers, quick-command bar,
  reconnect/backoff, palette/theme broadcast, mouse/scroll.
- **P3 — Panels:** FileTree, GitDiff (+summary), Preview/edit, ChangeDirectory, image view, photo attach.
- **P4 — Cross-platform builds:** iOS/Android/Linux/Windows libghostty native asset hooks; run app on each.
- **P5 — Tailscale** integration per platform (Apple first).
- **P6 — ASR** (per platform) + **Push** (APNs/FCM + decrypt) + Notification banner/deep links.
- **P7 — Web:** libghostty WASM + JS-interop terminal engine; direct-server only.

Risk order: terminal engine cross-platform (P4) and web WASM (P7) are the largest unknowns; Tailscale
and DoubaoASR have no turnkey cross-platform story and may need server-side or alternative providers.
