# Desktop window architecture

## Status and decision

Motif targets Flutter 3.47, but its desktop windowing API is still
experimental. The implementation is present in the SDK for macOS, Linux, and
Windows, while the feature gate is available only on Flutter's `main` channel.
The API is also exposed from Flutter implementation libraries and explicitly
permits breaking changes in patch releases.

Therefore:

- production builds stay on the existing single-window backend;
- the application state is refactored now so it no longer assumes that client
  and server UI share one window;
- a Flutter-windowing backend is developed and tested behind one adapter on an
  experimental lane;
- the windowing backend becomes the default only after Flutter exposes the
  feature on stable without implementation imports.

Useful upstream references:

- [Flutter 3.47: experimental multi-window progress](https://flutter.dev/blog/whats-new-in-flutter-3-47#experimental-multi-window-progress)
- [Flutter's multiple-windows example](https://github.com/flutter/flutter/tree/4cf2416426/examples/multiple_windows)
- [Flutter 3.47 windowing feature gate](https://github.com/flutter/flutter/blob/4cf2416426/packages/flutter_tools/lib/src/features.dart)
- [Flutter 3.47 experimental windowing API](https://github.com/flutter/flutter/blob/4cf2416426/packages/flutter/lib/src/widgets/_window.dart)

## Product model

The first multi-window release has two logical top-level windows:

| Window | Cardinality | Responsibility | Close behavior |
| --- | --- | --- | --- |
| Client | exactly one | server selection, sessions, terminal, files, git, Codex | close/hide UI; do not stop embedded motifd |
| Server | zero or one, created lazily | configure and operate this computer's embedded motifd | destroy/hide UI; do not stop embedded motifd |

The Server window is a regular independent window, not a satellite or dialog.
It must remain independently movable and reopenable even when the Client window
is closed. Dialog and popup windows remain children of whichever top-level
window invoked them.

Multiple Client windows and detached Session windows are deliberately deferred.
The current state model has one process-wide active server and one active
workspace per server. Supporting multiple independent Client windows requires
window-scoped navigation and workspace leases; it is a separate product step,
not a side effect of enabling Flutter windowing.

## Ownership model

```text
DesktopProcess
├── AppKernel                         process lifetime; no window assumptions
│   ├── PlatformServices
│   ├── EmbeddedServerService        exactly one in-process motifd
│   ├── ServerInstance registry
│   ├── ServerConnectionPoolRegistry
│   ├── WorkspaceRegistry
│   ├── PushCoordinator
│   └── CodexState
├── DesktopWindowCoordinator
│   ├── ClientWindowSession          exactly one in the first release
│   │   ├── navigator key
│   │   ├── navigation/open intents
│   │   ├── sidebar/chrome state
│   │   └── close-shortcut state
│   └── ServerWindowSession?         lazy singleton
├── TrayService
└── DesktopUpdateService
```

The embedded server is owned by the process, never by `ServerWindowSession` or
an `EmbeddedServerPage` widget. Closing every Flutter window may leave Motif
running in the tray with motifd still serving. Only **Quit Motif** stops the
embedded server and disposes process resources.

The Client and Server windows are projections over the same `AppKernel` in one
Dart isolate. They do not communicate over HTTP with each other, and the Client
continues to access the local embedded motifd through the same loopback server
transport used today. This preserves the client/server boundary and makes the
embedded and remote paths exercise the same protocol.

## State boundaries

### Process state

Keep these shared across all windows:

- server profiles, secrets, terminal preferences, quick commands, and push
  settings;
- embedded motifd configuration, lifecycle, pairing, and advertised endpoint;
- server access, probes, connection pools, session catalogs, and devices;
- `(serverId, session)` Workspace runtime resources and capped warm retention;
- terminal byte streams, FFI handles, replay buffers, Codex connections, and
  platform capabilities.

### Client-window state

Move these out of `AppState.shell` into `ClientWindowSession` and its ViewModel:

- root and nested Navigator keys;
- pending session-open intents;
- session sidebar visibility, width, and split positions;
- the `Command-W`/`Control-W` consumed flag;
- per-window toast/dialog presentation targets;
- later, when multiple Client windows are supported: active server and active
  workspace selection.

`PendingSessionOpen` becomes an ordered intent queue owned by the window
coordinator. A process notification currently writes into one nullable slot,
so a second notification can replace the first. The new flow is:

```text
Push / tray / deep link
  -> DesktopWindowCoordinator.openClient(intent)
  -> create or focus Client window
  -> enqueue intent on ClientWindowSession
  -> that window's Navigator consumes and acknowledges the intent
```

On mobile and web, a single `ClientWindowSession` is installed by the ordinary
application shell, so routing behavior remains shared without importing
desktop windowing code.

### Server-window state

The Server window owns only presentation state: Navigator, focus, geometry, and
ephemeral form/dialog state. `EmbeddedServerService` remains process-owned. The
server page observes it and invokes `start`, `stop`, and configuration commands
exactly as it does today.

## Window abstraction

Flutter's experimental types must not leak into application, state, or feature
code. Put them behind a narrow desktop-only boundary:

```dart
abstract interface class DesktopWindowHost {
  bool get supportsMultipleWindows;

  Future<void> openClient({ClientOpenIntent? intent});
  Future<void> openServer();
  Future<void> closeCurrent();
  Future<void> quit();
}
```

Provide two implementations:

1. `LegacySingleWindowHost` keeps the current stable behavior. `openClient` and
   `openServer` show the existing native window and select the corresponding
   pane during the transition period.
2. `FlutterWindowingHost` is the only code allowed to import Flutter's internal
   `_window.dart`. It owns `RegularWindowController`, `WindowEntry`, and
   `WindowRegistry` objects and maps their destruction callbacks back to stable
   Motif window ids.

The experimental backend uses `RegularWindow` for both Client and Server. Each
window owns its own `MaterialApp`, Navigator, overlay, focus tree, shortcuts,
MediaQuery, dialogs, and toast host. `MotifScope`/`AppKernel` sits above the
window content so runtime objects are shared without making a Navigator global.

Do not use `SatelliteWindow` for the Server window: it is parent-owned and is
destroyed with its parent. It may later be useful for a detached inspector or
tool palette.

## Lifecycle rules

Window visibility, window focus, application lifecycle, and server lifecycle
are separate signals:

- losing focus in one window does not background the process;
- closing the Server window does not stop motifd;
- closing the Client window releases only its UI resources;
- no visible windows is valid while the tray or embedded server is active;
- app pause/resume continues to drive process-level connectivity policy;
- only an explicit Quit command stops motifd, disposes workspaces and platform
  services, destroys all windows, and terminates the process.

For the first two-window release, the existing desktop workspace retention
policy remains valid. When multiple Client windows are introduced, replace
"foreground workspace" with reference-counted visibility leases: a workspace
is foreground while at least one visible Client surface holds a lease, warm
while retained but invisible, and disposable only when it has no leases and is
outside the warm-retention limit.

## Native and plugin constraints

The current native glue assumes one initial window:

- the macOS method channel captures one `MainFlutterWindow`;
- `DesktopWindow.show/hide/startDrag` targets that window;
- `MotifWindowTitle` and `nativeapi.WindowManager.getCurrent()` assume a single
  current window;
- the custom macOS title bar is configured only on `MainFlutterWindow`;
- update dialogs use one global `motifNavigatorKey`.

The stock Motif runners also create the first native window before Dart starts.
Flutter's reference multi-window application instead starts an engine without
a visible application window on macOS and Windows, then lets
`RegularWindowController` create every visible window. Linux currently uses a
bootstrap Flutter view to own the engine, but does not show that bootstrap
window before a Flutter frame. The experimental backend must follow the
reference runner pattern or it will create an orphan/blank legacy window in
addition to the controller-owned windows.

The windowing backend replaces those calls with window-scoped controller
operations. Start with native system title bars on both windows; reintroducing a
custom title bar should wait until all three embedders expose reliable
per-window decoration control. Permission and tray services stay process-level,
but any UI they present must route through `DesktopWindowCoordinator`.

Plugins must be verified per secondary Flutter view. Motif's FFI-based terminal
and embedded server are naturally process-scoped, but WebView, file picker,
IME/text input, accessibility, drag/drop, and method-channel plugins need an
explicit secondary-window smoke test before release.

## Target source layout

```text
lib/motif/
├── desktop/
│   ├── desktop_process.dart
│   └── window/
│       ├── desktop_window_host.dart
│       ├── desktop_window_coordinator.dart
│       ├── desktop_window_models.dart
│       ├── legacy_single_window_host.dart
│       └── flutter_windowing_host.dart       experimental imports live here
├── state/
│   ├── app/                                  process/application state
│   └── window/
│       ├── client_window_session.dart
│       ├── client_window_view_model.dart
│       └── window_open_intent.dart
└── ui/window/
    ├── client_window_app.dart
    └── server_window_app.dart
```

Keep `main.dart` as the client-only web/mobile entrypoint. `main_desktop.dart`
builds `DesktopProcess`, installs a window host, starts the tray and embedded
server runtime, and then opens the Client window. The stable backend can keep
using the shared `runMotif`/`runApp` bootstrap. The experimental backend needs a
desktop root built with `runWidget`, because visible root views are supplied by
`RegularWindow` rather than attached to the implicit view by `runApp`.

## Migration plan

### Phase 0: remove single-window state assumptions

- Introduce `ClientWindowSession` and move pending-open, sidebar, Navigator, and
  close-shortcut state out of `AppState`.
- Replace direct uses of `motifNavigatorKey` with a window presentation router.
- Replace `AppViewMode` commands in tray/push code with `openClient` and
  `openServer` intents.
- Keep the current UI visually unchanged through `LegacySingleWindowHost`.

Exit criterion: existing stable desktop, mobile, and web behavior and tests are
unchanged, while process code no longer selects a Client/Server pane directly.

### Phase 1: split Client and Server widgets

- Extract `_ClientNavigator` into `ClientWindowApp`.
- Extract the embedded server page into `ServerWindowApp`.
- Give each root its own MaterialApp, Navigator, overlays, shortcuts, title, and
  toast host.
- Keep both mounted by the legacy host until the experimental backend is used.

Exit criterion: the two roots can be pumped independently in widget tests and
share one fake `AppKernel` without global keys.

### Phase 2: experimental Flutter 3.47 backend

- Implement `FlutterWindowingHost` using regular window controllers and a lazy
  singleton Server window.
- Adapt the macOS and Windows runners to start an engine without a visible
  legacy window, and adapt Linux to the upstream hidden-bootstrap-view pattern.
- Add a desktop `runWidget` composition root; do not attach `MotifApp` to the
  implicit bootstrap view with `runApp`.
- Run only on a pinned Flutter `main` revision with windowing enabled; do not
  publish this backend in production artifacts.
- Remove multi-window paths through `nativeapi.WindowManager.getCurrent()` and
  the one-window macOS channel.
- Persist window geometry only after controller APIs report reliable bounds on
  all three desktop platforms.

Exit criterion: the matrix below passes on macOS, Windows, Linux X11, and Linux
Wayland, with two independently focusable windows.

### Phase 3: stable cutover

- Require public Flutter windowing APIs available on the stable channel.
- Pin the minimum Flutter version in CI and delete implementation imports.
- Make the multi-window host the default, retaining the legacy host for one
  release as a runtime/build fallback.
- Remove `AppViewMode`, the Client/Server title-bar switch, and the legacy
  single-window native glue after the fallback window expires.

## Verification matrix

At minimum, automate or manually sign off:

- launch opens one Client window; Server window is lazy;
- tray Open Client/Open Server focuses an existing window and never duplicates
  the Server window;
- closing/reopening Server preserves motifd status and configuration;
- closing Client while motifd runs leaves the process and tray alive;
- Quit stops motifd once, disposes all workspaces, and exits cleanly;
- notification/deep link opens the requested session in Client even when only
  Server is visible;
- terminal input, IME, clipboard, file picker, WebView, dialogs, tooltips,
  accessibility, and window titles work in both initial and secondary views;
- focus or resize in one window does not alter the other window's MediaQuery,
  shortcuts, Navigator, or toast overlay;
- hot restart does not leave stale windows, tray icons, FFI callbacks, or
  connection subscriptions;
- the legacy backend still passes the normal stable-channel release build.

## Deferred multiple-Client design

When detached sessions become a product requirement, change the coordinator to
own `Map<WindowId, ClientWindowSession>` and move active server/workspace
selection fully into each session. `WorkspaceRegistry` then indexes only by
`WorkspaceKey(serverId, session)` and exposes acquire/release leases. Connection
pools, ServerInstances, and one WorkspaceInstance per exact key remain shared;
only navigation and visible terminal surfaces are per window.

That extension should follow the two-window split, because it changes workspace
ownership and routing semantics independently of Flutter's ability to draw more
than one native window.
