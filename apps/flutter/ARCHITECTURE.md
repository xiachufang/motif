# Flutter architecture

This is the high-level implementation overview. The complete Observable state
tree, ownership rules, and collection semantics are documented in
[WORKSPACE_STATE_ARCHITECTURE.md](WORKSPACE_STATE_ARCHITECTURE.md).

Motif is a Flutter shell around remote motifd servers, the Ghostty terminal
engine, and optional native platform services. Boundaries are enforced by
focused interfaces and composition inside one Dart package.

## Runtime composition

```text
MotifApp
└── AppState                         application coordinator
    ├── AppViewModel                 Observable process state root
    ├── PlatformServices             Tailscale, speech, push, secrets
    ├── ServerInstance registry
    │   └── ServerInstance
    │       ├── ServerTransport
    │       ├── ServerAccessController
    │       ├── SessionCatalogController
    │       └── DeviceController
    ├── WorkspaceRegistry            ordinary runtime resource index
    │   └── WorkspaceInstance(serverId, session)
    │       ├── WorkspaceConnectionController
    │       ├── WorkspaceLifecycleController
    │       ├── TerminalController
    │       ├── ViewController
    │       ├── RemotePortController
    │       └── WorkspaceApi
    └── PushCoordinator
```

One `ServerInstance` owns one configured server control channel. One
`WorkspaceInstance` owns exactly one `(serverId, session)` attachment. SSH,
Tailscale, WSL, and Rendezvous access state belongs to the Server projection;
PTY, View, File/Git invalidation, presence, and remote ports belong to the
Workspace projection.

## State source layout

`lib/motif/state` is grouped by owning domain first, then by Workspace feature:

```text
state/
├── app/                    composition root, app shell state, and scopes
├── connection/             shared connection/access value types
├── embedded/               embedded motifd models, service, and ViewModel
├── persistence/            stores, serialization, and preference ViewModels
├── platform/               observable projections of platform capabilities
├── server/                 server access, catalog, device, push, and transport
└── workspace/              workspace composition, lifecycle, content, presence
    ├── connection/         fixed-session transport and attach coordination
    ├── terminal/           PTY state, runtime policy, and output delivery
    ├── view/               tab/view state and commands
    └── remote_port/        remote-port state and forwarding
```

The directory name answers which lifetime owns a file. A Controller is kept
beside the ViewModel and transport contract it drives; generated `.g.dart`
parts stay beside their source. New files must enter the narrowest owning
domain. Do not create generic `common`, `models`, `controllers`, or `utils`
dumping grounds under `state`.

`app` is the outer composition layer and may depend on every lower domain.
Server and Workspace coordinators may compose focused features. Leaf Workspace
features (`terminal`, `view`, and `remote_port`) do not import `app`, instances,
or one another. The Workspace connection layer is the explicit attach
coordinator, so it may assemble those focused features without turning them
into a mutual dependency graph.

## State and data flow

- All long-lived UI-readable state is an `@ObservableModel` ViewModel.
- ViewModels live in state-only source files; Services and Controllers depend
  on them, never the reverse.
- Every UI region that reads observable state runs through a generated
  `@ObservationWidget()` boundary. Widget-owned observable state uses
  `@ObservableState()`; ordinary owned resources use `@PlainState()`.
- Widgets that require Flutter-only lifecycle mixins remain `StatefulWidget`s
  and delegate their reactive subtree to generated `ObservationSelect` regions.
- Long-lived collections use stable `ObservableList`, `ObservableMap`, or
  `ObservableSet` identities and support direct mutation.
- `RpcClient`, timers, sockets, forwarders, subscriptions, and replay buffers
  are runtime resources and never enter the ViewModel tree.
- `WorkspaceLifecycleController` projects reconnect metadata into the same
  `WorkspaceConnectionViewModel`; it does not keep a parallel access state.
- `WorkspaceScope` injects focused capabilities. Widgets never receive a
  `WorkspaceInstance` or a broad command facade.
- PTY bytes bypass the observable state tree. `PtyOutputHub` delivers bytes
  directly and keeps a capped replay buffer for late surfaces.

## Persistence and secrets

Persistence adapters serialize immutable DTO snapshots; ViewModels contain no
JSON or SharedPreferences logic. Shared preferences store non-sensitive
profiles and preferences. Tokens, rendezvous PSKs, SSH credentials, and the
Push E2E key use `SecretStore`.

## Dependency direction

```text
UI -> ViewModels + focused feature interfaces
AppState/registries -> ServerInstance + WorkspaceInstance
instances/coordinators -> focused controllers -> transport interfaces
transport implementations -> RpcClient/platform services
ViewModels -> immutable DTOs/enums only
```

Reverse dependencies are forbidden: ViewModels do not import controllers,
features do not import instances or sibling features, and transports do not
mutate ViewModels.

## Verification

The migration guard requires no legacy client symbols or handwritten
observation keys in production source. Pull requests run `flutter analyze` and
the Flutter test suite; native/live motifd and Tailscale suites remain explicit
lanes when they require external services.
