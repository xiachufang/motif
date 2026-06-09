# Motif

**Motif** is a cross-platform **remote terminal client**, built as a single
Flutter codebase targeting **iOS, macOS, Android, Web, Linux, and Windows**. It
drives a remote `motifd` server over HTTP-RPC + WebSocket and renders the remote
PTYs locally with the **libghostty** VT engine (native FFI on desktop/mobile,
WebAssembly on web).

It is a Flutter port of the Motif iOS app, aiming for feature parity across all
six platforms. All code here is written by AI.

## Requirements

- **Flutter SDK**
- **Zig 0.15.2** — required to build the libghostty native/WASM engine
- **Xcode Command Line Tools** — for macOS/iOS builds
- Platform SDKs as needed (Android NDK 28 + JDK 17 for Android; a Linux/Windows
  host for those desktop builds)

## Setup

### 1. Clone with submodules

```bash
git clone --recursive <repo-url>
cd motif
```

If already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

### 2. Install Zig 0.15.2

Install Zig `0.15.2` and ensure it is on your `PATH`. (Without Zig, pure-Dart
code still analyzes/tests; the terminal just won't render until native assets
are built.)

### 3. Fetch packages

```bash
flutter pub get
```

### 4. Run

`lib/main.dart` is the default entrypoint, so no `-t` flag is needed:

```bash
flutter run            # pick a device, or:
flutter run -d macos
```

On first launch, add a **server** (your `motifd` host/port) in the app to
connect.

### 5. Regenerate FFI bindings

Regenerate the libghostty bindings when the headers change:

```bash
dart run ffigen --config ffigen.yaml
```

## Architecture

- **`lib/motif/`** — the app: `models/`, `net/` (HTTP-RPC + WebSocket transport),
  `state/` (connection + session state via `provider`), `ui/`, `terminal/`,
  `platform/` (Tailscale, speech, push).
- **`lib/src/`** — the shared libghostty renderer: `ghostty_bindings.g.dart`
  (`@ffi.Native` bindings, ffigen `ffi-native` mode), `terminal_state.dart`
  (network-only: feeds remote PTY bytes into the engine and relays key/mouse/
  query output back over the WebSocket), `terminal_painter.dart`, `key_map.dart`.

### Native build flow

`flutter run` / `flutter build <platform>` invoke the package build hook
`hook/build.dart`, which runs `scripts/build_native_deps.sh` to build
`libghostty-vt` via Zig and emit it as a bundled dynamic `CodeAsset` on every
native platform. The asset id tracks the Dart package URI, so Dart resolves the
`@Native` symbols through Flutter's native-assets manifest at runtime — no
custom Xcode phases or `DynamicLibrary.open` needed.

Motif is a *remote* terminal, so there is **no local PTY library** — the engine
only renders bytes relayed from `motifd`.

## Platform build matrix

Requires **Zig 0.15.2** on `PATH` for the libghostty native asset.

| Platform | Build | Native engine | Notes |
|---|---|---|---|
| macOS | `flutter build macos` | libghostty dylib | ✅ builds + runs |
| iOS | `flutter build ios --simulator` | libghostty dylib/framework | sim ✅; device needs signing |
| Android | `flutter build apk` | libghostty `.so` | ✅ bundles `lib*/libghostty-vt.so`; needs NDK 28 + JDK 17 |
| Web | `flutter build web --no-wasm-dry-run` | libghostty WASM | ✅ builds (`web/ghostty-vt.wasm` + `web/ghostty_vt.js`) |
| Linux | `flutter build linux` (on a Linux host) | libghostty `.so` (cross-builds from macOS) | app assembly needs a Linux host/CI |
| Windows | `flutter build windows` (on a Windows host) | libghostty `.dll` (cross-builds from macOS) | app assembly needs a Windows host/CI |

### Terminal renderer

The real **libghostty** engine drives the terminal on every platform: native
FFI on macOS/iOS/Android (default), **WebAssembly** on web. A pure-Dart fallback
(`BasicTerminalView`) is used if the native/WASM engine is unavailable. Disable
the native path with `--dart-define=MOTIF_NATIVE_TERMINAL=false`.

## Tailscale (libtailscale / tsnet)

Native tailnet access via `libtailscale` over FFI (`lib/motif/platform/
tailscale_*.dart`). `flutter build` / `flutter run` automatically builds the
target platform's `libtailscale` dynamic library into `build/native/tailscale/…`
when a matching dynamic library is not already present. The build hook emits it
as a bundled `DynamicLoadingBundled()` native asset; iOS also packages only the
generated dynamic framework. The native app then uses the real
`TailscaleNativeService` (a loopback SOCKS5 proxy; RPC routes through it for
`tailscale`-kind servers). Web has no Tailscale. Use **Connect with browser**
for interactive auth, or enter a Tailscale **auth key** for headless auth.

For manual prebuild/debugging:
`scripts/build_tailscale.sh [--target host|macos-arm64|macos-x64|linux-arm64|linux-x64|windows-arm64|windows-x64|android-arm|android-arm64|android-x64|ios|ios-sim-arm64|ios-sim-x64]`.

## Tests

```bash
flutter test test/motif
```

Tags: `native` needs Zig; `live` / `tailscale_live` need a running server / auth
key; `tailscale` needs the libtailscale dylib.

## Feature status

**Implemented:** terminal (keyboard/mouse/scroll/copy), multi-session/tabs,
quick-commands + sticky modifiers + editor + per-program sets, git diff
(All/By-file), file tree (browse + new/rename/delete), preview/edit (+ conflict
prompt) + image view, change-directory, voice input (`speech_to_text`), photo
attach, notification banner + settings, **Tailscale connect**, **E2E push**
(AES-256-GCM, no Firebase: native APNs + foreground decrypt + iOS Notification
Service Extension for background), push settings + `device.*` RPC, session-list
management.

**Pending:** Linux/Windows app assembly (native libs cross-build from macOS;
final `flutter build` needs those hosts); iOS push background end-to-end
validation (needs a signed device build + the APNs relay).
