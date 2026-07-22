import 'dart:async';

import '../../../log/log.dart';
import '../../../models/motif_proto.dart';
import '../../../terminal/terminal_session.dart';
import 'terminal_runtime_policy.dart';
import 'terminal_stream_runtime.dart';
import 'pty_input_router.dart';
import 'pty_output_hub.dart';
import 'terminal_view_model.dart';

typedef TerminalRpcCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> params,
    ]);

/// Narrow attachment/transport capability used by [TerminalController].
final class TerminalTransport {
  const TerminalTransport({
    required this.canInput,
    required this.call,
    required this.writePty,
    required this.resizePty,
    required this.ensurePtyStream,
    required this.closePtyStream,
    required this.syncPtyStreams,
    required this.waitForPtyReplay,
    required this.resyncPtyStream,
  });

  final bool Function() canInput;
  final TerminalRpcCall call;
  final Future<void> Function(String ptyId, List<int> data) writePty;
  final Future<void> Function(String ptyId, int cols, int rows) resizePty;
  final Future<void> Function(String ptyId) ensurePtyStream;
  final Future<void> Function(String ptyId) closePtyStream;
  final Future<void> Function(Set<String> ptyIds) syncPtyStreams;
  final Future<void> Function(String ptyId) waitForPtyReplay;
  final Future<void> Function(String ptyId, {required String reason})
  resyncPtyStream;
}

/// Read-only view projection needed by terminal runtime policy.
final class TerminalViewProjection {
  const TerminalViewProjection({
    required this.activePtyId,
    required this.liveTabPtyIds,
  });

  final String? Function() activePtyId;
  final Set<String> Function() liveTabPtyIds;
}

/// Owns terminal state, PTY surfaces/output buffers, and terminal commands for
/// one workspace. It has no dependency on views or the workspace composition
/// root; the coordinator supplies the two small projection callbacks.
final class TerminalController implements TerminalSession, TerminalRuntimeHost {
  TerminalController({
    required this.viewModel,
    required this.transport,
    required this.runtime,
    required this.viewProjection,
  }) {
    _streamRuntime = switch (runtime) {
      DesktopTerminalRuntimePolicy(:final backgroundRestoreDelay) =>
        TerminalStreamRuntimeController(
          host: this,
          policy: TerminalStreamPlatformPolicy.desktop,
          backgroundRestoreDelay: backgroundRestoreDelay,
          onStateChanged: (state) => viewModel.runtime = state,
        ),
      MobileTerminalRuntimePolicy() => TerminalStreamRuntimeController(
        host: this,
        policy: TerminalStreamPlatformPolicy.mobile,
        onStateChanged: (state) => viewModel.runtime = state,
      ),
      _ => null,
    };
    _output.describeActive = () =>
        'activePty=$activePtyId liveTabs=${liveTabPtyIds.length}';
    _output.onReplayOverflow = (ptyId, pendingBytes) {
      unawaited(
        resyncPtyStream(
          ptyId,
          reason: 'replay backlog $pendingBytes bytes',
        ).catchError((Object error, StackTrace stackTrace) {
          Log.w(
            'pty replay overflow resync failed pty=$ptyId',
            name: 'motif.pty',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    };
  }

  final TerminalViewModel viewModel;
  final TerminalTransport transport;
  final TerminalRuntimePolicy runtime;
  final TerminalViewProjection viewProjection;
  final PtyOutputHub _output = PtyOutputHub();
  final PtyInputRouter _input = PtyInputRouter();
  late final TerminalStreamRuntimeController? _streamRuntime;

  TerminalStreamRuntimeState get runtimeState =>
      _streamRuntime?.state ?? viewModel.runtime;

  @override
  bool get canInput => transport.canInput();

  @override
  String? get activePtyId => viewProjection.activePtyId();

  @override
  Set<String> get liveTabPtyIds => viewProjection.liveTabPtyIds();

  @override
  Set<String> get terminalSurfacePtyIds => _output.sinkPtyIds;

  @override
  void registerPtySink(String ptyId, PtyByteSink sink) =>
      _output.registerSink(ptyId, sink);

  @override
  void unregisterPtySink(String ptyId, [PtyByteSink? sink]) =>
      _output.unregisterSink(ptyId, sink);

  @override
  void registerTerminalInputSink(String ptyId, TerminalInputSink sink) =>
      _input.register(ptyId, sink);

  @override
  void unregisterTerminalInputSink(String ptyId, [TerminalInputSink? sink]) =>
      _input.unregister(ptyId, sink);

  @override
  bool dispatchTerminalInput(String ptyId, TerminalInputEvent event) =>
      canInput && _input.dispatch(ptyId, event);

  @override
  Future<void> writePty(String ptyId, List<int> data) {
    if (!canInput) return Future<void>.value();
    return transport.writePty(ptyId, data);
  }

  Future<PtyInfo> create({
    String? cmd,
    String? cwd,
    required int cols,
    required int rows,
  }) async {
    final body = await transport.call('pty.create', {
      'cmd': ?cmd,
      'cwd': ?cwd,
      'cols': cols,
      'rows': rows,
    });
    final info = PtyInfo.fromJson(
      (body['info'] as Map).cast<String, Object?>(),
    );
    addCreated(info);
    return info;
  }

  @override
  Future<void> resizePty(String ptyId, int cols, int rows) =>
      transport.resizePty(ptyId, cols, rows);

  @override
  Future<void> ensurePtyStream(String ptyId) =>
      transport.ensurePtyStream(ptyId);

  @override
  Future<void> closePtyStream(String ptyId) => transport.closePtyStream(ptyId);

  @override
  Future<void> syncPtyStreams(Set<String> ptyIds) =>
      transport.syncPtyStreams(ptyIds);

  @override
  Future<void> waitForPtyReplay(String ptyId) =>
      transport.waitForPtyReplay(ptyId);

  Future<void> waitForPtySurfaceReplay(String ptyId) =>
      _output.waitForReplayDelivery(ptyId);

  @override
  Future<void> activatePtyStream(String ptyId) =>
      _streamRuntime?.surfaceReady(ptyId) ??
      runtime.onTerminalSurfaceReady(this, ptyId);

  @override
  Future<void> deactivatePtyStream(String ptyId) =>
      _streamRuntime?.surfaceDisposed(ptyId) ??
      runtime.onTerminalSurfaceDisposed(this, ptyId);

  @override
  Future<void> resyncPtyStream(String ptyId, {required String reason}) async {
    _output.clearPty(ptyId);
    await transport.resyncPtyStream(ptyId, reason: reason);
  }

  Future<void> kill(String ptyId) =>
      transport.call('pty.kill', {'pty_id': ptyId}).then((_) {});

  void handleOutput(Map<String, Object?> params) {
    final id = params['pty_id'] as String?;
    final bytes = PtyOutputHub.bytesFromPtyOutput(params);
    if (id != null && bytes != null) _output.handleOutput(id, bytes);
  }

  void addCreated(PtyInfo info) {
    if (viewModel.ptys.any((pty) => pty.id == info.id)) return;
    viewModel.ptys.add(info);
    onPtySubscriptionsChanged();
  }

  void markExited(String id) {
    updatePty(id, (pty) => pty.copyWith(alive: false));
    _output.clearPty(id);
    _input.clearPty(id);
    viewModel.runningCommand.remove(id);
    viewModel.shellKind.remove(id);
    viewModel.shellContext.remove(id);
    onPtySubscriptionsChanged();
  }

  void updatePty(String id, PtyInfo Function(PtyInfo) transform) {
    final index = viewModel.ptys.indexWhere((pty) => pty.id == id);
    if (index >= 0) viewModel.ptys[index] = transform(viewModel.ptys[index]);
  }

  void replacePtys(Iterable<PtyInfo> ptys) {
    viewModel.ptys.replaceRange(0, viewModel.ptys.length, ptys);
  }

  void clear() {
    viewModel.ptys.clear();
    viewModel.runningCommand.clear();
    viewModel.shellKind.clear();
    viewModel.shellContext.clear();
    _output.clearAll();
    _input.clearAll();
  }

  void onSessionAttached() {
    final streamRuntime = _streamRuntime;
    if (streamRuntime != null) {
      streamRuntime.sessionAttached();
    } else {
      runtime.onSessionAttached(this);
    }
  }

  void onPtySubscriptionsChanged() {
    final streamRuntime = _streamRuntime;
    if (streamRuntime != null) {
      streamRuntime.subscriptionsChanged();
    } else {
      runtime.onPtySubscriptionsChanged(this);
    }
  }

  void onActiveViewChanged() => runtime.onActiveViewChanged(this);

  void dispose() {
    _streamRuntime?.dispose();
    _output.dispose();
    _input.clearAll();
  }
}
