# Flutter architecture

Motif is a Flutter shell around three runtime systems: a remote motifd
connection, the Ghostty terminal engine, and optional native platform services.
The application intentionally stays in one Dart package; boundaries are kept by
interfaces and composition rather than by publishing many internal packages.

## Runtime composition

```text
MotifApp
├── AppState                    app shell and compatibility facade
│   ├── WorkspaceRegistry       active/warm workspace identity and LRU
│   │   └── ServerConnectionController
│   │       ├── TransportResolver
│   │       └── MotifClient     RPC session projection
│   ├── PushCoordinator         registration and notification routing
│   ├── settings stores         profiles, terminal and quick commands
│   └── PlatformServices        Tailscale, speech, push and secrets
└── terminal surfaces
    ├── TerminalSession         narrow PTY host interface
    ├── PtyOutputHub            capped replay and direct byte delivery
    └── TerminalWorkerClient    isolate-owned Ghostty engine
```

`lib/main.dart` starts the client-only app. `lib/main_desktop.dart` supplies the
embedded server page and desktop runtime policies through `runMotif`; shared
code never imports the desktop implementation.

## State and data flow

- `RpcClient` owns HTTP, event WebSocket and PTY WebSocket mechanics.
- `MotifClient` projects protocol events into session, PTY and view state.
- `ServerConnectionController` owns reconnect/backoff and transport blockers.
- `WorkspaceRegistry` keeps at most four fully retained desktop workspaces.
  Mobile retains one. Eviction releases the controller, transport and terminal
  pane resources.
- PTY output bypasses `ChangeNotifier`. `PtyOutputHub` delivers bytes directly
  and retains at most 2 MiB per PTY for late subscribers.
- `AppState` relays one notification per client update; connection projection
  only runs when the client connection state actually changes.

## Persistence and secrets

Shared preferences contain only non-sensitive server profiles and UI settings.
Tokens, rendezvous PSKs, SSH passwords/private keys, and the Push E2E key use
`SecretStore`, backed by `flutter_secure_storage`. Startup migrates legacy
plaintext values only after the secure write succeeds.

## Dependency rules

- `models` has no Flutter or platform dependencies.
- `net` may depend on models and transport adapters, never UI.
- `state` coordinates network and platform capabilities.
- terminal rendering depends on `TerminalSession`, not on `MotifClient`.
- desktop-specific composition belongs in the desktop entrypoint.
- UI may depend on state and terminal public interfaces.

## Verification

Pull requests run `flutter analyze` plus pure Dart/widget tests with native FFI
assets disabled. Native, live motifd and Tailscale suites remain explicit tagged
lanes because they require toolchains or external services.
