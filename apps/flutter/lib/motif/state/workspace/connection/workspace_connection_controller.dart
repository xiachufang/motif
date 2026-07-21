/// Connection lifecycle + live session state, observable by the UI.
///
/// Owns one workspace transport and its attachment lifecycle. Feature commands
/// are exposed by the focused controllers composed beside it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../../log/log.dart';
import '../../../models/motif_proto.dart';
import '../../../models/settings.dart';
import '../../../net/proxy_client.dart';
import '../../../net/remote_port_forwarder.dart';
import '../../../net/rpc_client.dart';
import '../terminal/terminal_runtime_policy.dart';
import '../remote_port/remote_port_controller.dart';
import '../session_attachment.dart';
import '../terminal/terminal_controller.dart';
import '../terminal/terminal_view_model.dart';
import '../view/view_controller.dart';
import '../view/view_tabs_view_model.dart';
import 'workspace_connection_view_model.dart';
import '../workspace_content_view_model.dart';
import '../workspace_api.dart';
import '../workspace_event_router.dart';
import '../workspace_presence_view_model.dart';

part 'workspace_connection_transport.dart';
part 'workspace_attachment_recovery.dart';
part 'workspace_palette_controller.dart';
part 'workspace_session_attachment.dart';

const int _kSessionNotFound = -32007;
const int _kNotAttached = -32009;

class WorkspaceConnectionController implements SessionAttachment {
  @override
  final String session;

  @override
  final WorkspaceConnectionViewModel connection =
      WorkspaceConnectionViewModel();
  final WorkspaceContentViewModel content = WorkspaceContentViewModel();
  final WorkspacePresenceViewModel presence = WorkspacePresenceViewModel(
    clients: ObservableList(),
  );

  @protected
  void updateConnectionState(WorkspaceConnectionStatus value, {bool? live}) =>
      connection.applyStatus(value, live: live);

  WorkspaceConnectionController({
    required this.session,
    TerminalRuntimePolicy? runtime,
  }) {
    _remotePorts = RemotePortController(
      transport: RemotePortTransport(
        call: (method, [params = const {}]) {
          final rpc = _rpc;
          if (rpc == null) throw const RpcException('not connected');
          return rpc.call(method, params);
        },
        requireAttachment: () {
          final rpc = _rpc;
          if (rpc == null) throw const RpcException('not connected');
          if (rpc.sessionId == null) {
            throw const RpcException(
              'must attach a session before listing ports',
            );
          }
        },
        startForwarder:
            ({
              required remoteHost,
              required remotePort,
              localPort,
              required localScheme,
            }) {
              final rpc = _rpc;
              if (rpc == null) throw const RpcException('not connected');
              final sessionId = rpc.sessionId;
              if (sessionId == null) {
                throw const RpcException(
                  'must attach a session before forwarding ports',
                );
              }
              return RemotePortForwarder.start(
                rpc: rpc,
                remoteHost: remoteHost,
                remotePort: remotePort,
                localPort: localPort,
                localScheme: localScheme,
                sessionId: sessionId,
              );
            },
      ),
    );
    _viewsController = ViewController(
      viewModel: ViewTabsViewModel(items: ObservableList()),
      transport: ViewTransport(
        isAvailable: () => _rpc != null,
        call: (method, [params = const {}]) {
          final rpc = _rpc;
          if (rpc == null) throw const RpcException('not connected');
          return rpc.call(method, params);
        },
      ),
      callbacks: ViewProjectionCallbacks(
        onTabsChanged: () => terminal.onPtySubscriptionsChanged(),
        onActiveChanged: () => terminal.onActiveViewChanged(),
      ),
    );
    _terminal = TerminalController(
      viewModel: TerminalViewModel(
        ptys: ObservableList(),
        runningCommand: ObservableMap(),
        shellKind: ObservableMap(),
        shellContext: ObservableMap(),
      ),
      transport: TerminalTransport(
        canInput: () => connection.canInput && _rpc?.sessionId != null,
        call: (method, [params = const {}]) {
          final rpc = _rpc;
          if (rpc == null) throw const RpcException('not connected');
          return rpc.call(method, params);
        },
        writePty: (ptyId, data) =>
            _rpc?.writePty(ptyId, data) ?? Future<void>.value(),
        resizePty: (ptyId, cols, rows) => _runAttachedTerminalRpc((rpc) async {
          await rpc.call('pty.resize', {
            'pty_id': ptyId,
            'cols': cols,
            'rows': rows,
          });
        }),
        ensurePtyStream: (ptyId) =>
            _runAttachedTerminalRpc((rpc) => rpc.activatePty(ptyId)),
        closePtyStream: (ptyId) =>
            _rpc?.deactivatePty(ptyId) ?? Future<void>.value(),
        syncPtyStreams: (ptyIds) =>
            _runAttachedTerminalRpc((rpc) => rpc.syncPtyStreams(ptyIds)),
        waitForPtyReplay: (ptyId) =>
            _rpc?.waitForPtyReplay(ptyId) ?? Future<void>.value(),
        resyncPtyStream: (ptyId, {required reason}) =>
            _rpc?.resyncPty(ptyId, reason: reason) ?? Future<void>.value(),
      ),
      runtime: runtime ?? const MobileTerminalRuntimePolicy(),
      viewProjection: TerminalViewProjection(
        activePtyId: _activePtyId,
        liveTabPtyIds: _liveTabPtyIds,
      ),
    );
    _workspace = WorkspaceApi(
      content: content,
      transport: WorkspaceApiTransport(
        isAvailable: () => _rpc != null,
        call: (method, [params = const {}]) {
          final rpc = _rpc;
          if (rpc == null) throw const RpcException('not connected');
          return rpc.call(method, params);
        },
        writeFileBytes: (path, data) =>
            _rpc?.writeFileBinary(path, data) ?? Future<String>.value(''),
      ),
      activeCwd: _resolveActiveCwd,
    );
    events = WorkspaceEventRouter(
      terminal: terminal,
      views: viewsController,
      content: content,
      presence: presence,
      onSequence: (sequence) {
        if (sequence > lastSeq) lastSeq = sequence;
      },
    );
  }

  late final RemotePortController _remotePorts;
  RemotePortController get remotePorts => _remotePorts;
  late final ViewController _viewsController;
  ViewController get viewsController => _viewsController;
  late final TerminalController _terminal;
  TerminalController get terminal => _terminal;
  late final WorkspaceApi _workspace;
  WorkspaceApi get workspace => _workspace;
  late final WorkspaceEventRouter events;
  TerminalViewModel get _terminalState => terminal.viewModel;
  ViewTabsViewModel get _viewState => viewsController.viewModel;

  WorkspaceConnectionStatus get _state => connection.status;
  set _state(WorkspaceConnectionStatus value) => connection.applyStatus(value);
  WorkspaceConnectionStatus get state => _state;

  RpcClient? _rpc;
  void _setRpc(RpcClient? value) {
    _rpc = value;
    connection.transportAvailable = value != null;
  }

  Future<void>? _attachInFlight;
  Future<void>? _attachmentRecovery;
  StreamSubscription<MotifEvent>? _eventSub;
  int lastSeq = 0;
  int? resumeSequence;
  String? get pendingLocalViewId => viewsController.pendingLocalViewId;

  set pendingLocalViewId(String? value) {
    viewsController.pendingLocalViewId = value;
  }

  // palette/theme this device advertises + the server's broadcast theme
  String? termFg;
  String? termBg;
  String? termTheme;
  Map<String, int> _carriedPtyCursors = {};
  bool isForeground = true;

  /// The most recent `/ping` payload from a successful [connect]. The
  /// rendezvous direct-upgrade path reads its `rzvDirect*` fields to learn
  /// motifd's LAN addresses. `null` until the first successful connect.
  PingInfo? lastPing;

  @override
  bool get isLive => connection.transportAvailable;

  bool get hasTerminalSnapshot =>
      _terminalState.ptys.isNotEmpty ||
      _viewState.items.isNotEmpty ||
      _state is ConnAttached;

  // ─────────────────────────── connect ───────────────────────────

  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
  }) => _connectImpl(server, force: force, proxy: proxy, certPin: certPin);

  Future<void> disconnect() => _disconnectImpl();

  Future<void> suspendTransport(String reason) => _suspendTransportImpl(reason);

  @override
  void setForeground(bool foreground) => _setForegroundImpl(foreground);

  Future<void> markConnectionLost([String message = 'connection lost']) =>
      _handleConnectionLost(message);

  @override
  Future<void> attach() => _attachImpl();

  @override
  Future<void> detach() => _detachImpl();

  /// Store this surface's terminal palette and push it to motifd while attached
  /// so OSC 10/11 queries and the session-wide light/dark theme match the UI.
  @override
  void setTerminalPalette({String? fg, String? bg, String? theme}) =>
      _setTerminalPaletteImpl(fg: fg, bg: bg, theme: theme);

  static String _describePty(PtyInfo pty) =>
      '${pty.id}(alive=${pty.alive},${pty.cols}x${pty.rows})';

  static String _describeView(ViewInfo view) =>
      '${view.id}:${_describeSpec(view.spec)}';

  static String _describeSpec(ViewSpec spec) => switch (spec) {
    PtyViewSpec(:final ptyId) => 'pty/$ptyId',
    PreviewViewSpec(:final path) => 'preview/$path',
    DiffViewSpec(:final path, :final staged) => 'diff/$path/$staged',
    ImageViewSpec(:final path) => 'image/$path',
    OtherViewSpec(:final typeName) => 'other/$typeName',
  };

  String? _resolveActiveCwd() {
    final id = _activePtyId();
    final ptys = _terminalState.ptys;
    if (id == null) return ptys.isEmpty ? null : ptys.first.cwd;
    return ptys.where((pty) => pty.id == id).firstOrNull?.cwd;
  }

  void dispose() {
    unawaited(_teardownRpc());
    terminal.dispose();
  }
}
