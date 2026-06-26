/// Connection lifecycle + live session state, observable by the UI.
///
/// Ported from `apps/ios/Motif/Native/MotifClient*.swift`. Wraps [RpcClient],
/// owns the events loop, and projects session/pty/view state as a
/// [ChangeNotifier] so Flutter widgets rebuild on change.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../log/log.dart';
import '../models/motif_proto.dart';
import '../models/settings.dart';
import '../net/proxy_client.dart';
import '../net/remote_port_forwarder.dart';
import '../net/rpc_client.dart';
import 'motif_runtime.dart';

const int _kSessionNotFound = -32007;

/// High-level connection state.
sealed class MotifConnState {
  const MotifConnState();
}

class ConnDisconnected extends MotifConnState {
  const ConnDisconnected();
}

class ConnConnecting extends MotifConnState {
  const ConnConnecting();
}

class ConnConnected extends MotifConnState {
  const ConnConnected();
}

class ConnAttached extends MotifConnState {
  final String session;
  const ConnAttached(this.session);
}

class ConnFailed extends MotifConnState {
  final String message;
  const ConnFailed(this.message);
}

class ConnSuspended extends MotifConnState {
  final String message;
  final String? session;
  const ConnSuspended(this.message, {this.session});
}

/// A sink of decoded PTY output bytes for a single PTY surface (the terminal
/// widget subscribes to it).
typedef PtyByteSink = void Function(Uint8List bytes);

class _PtyReplayDelivery {
  _PtyReplayDelivery(this.sink);

  final PtyByteSink sink;
  final List<Uint8List> chunks = <Uint8List>[];
  int index = 0;
  int offset = 0;
  Timer? timer;

  void cancel() {
    timer?.cancel();
    timer = null;
  }
}

class _PendingViewActivation {
  final String? viewId;
  final String? previousViewId;
  final Completer<void> confirmed = Completer<void>();

  _PendingViewActivation({required this.viewId, required this.previousViewId});
}

class RemotePortMapping {
  RemotePortMapping._({
    required this.id,
    required this.remoteHost,
    required this.remotePort,
    required this.localScheme,
    required this.createdAt,
    required this.forwarder,
  });

  final String id;
  final String remoteHost;
  final int remotePort;
  final String localScheme;
  final DateTime createdAt;
  final RemotePortForwarder forwarder;

  int get localPort => forwarder.localPort;
  Uri get localUrl => forwarder.localUrl;

  String get remoteEndpoint => '$remoteHost:$remotePort';
  String get displayTitle => '$localScheme://$remoteHost:$remotePort';

  bool _matchesConfig(_RemotePortMappingConfig config) =>
      id == config.id &&
      remoteHost == config.remoteHost &&
      remotePort == config.remotePort &&
      localScheme == config.localScheme;
}

class _RemotePortMappingConfig {
  const _RemotePortMappingConfig({
    required this.id,
    required this.remoteHost,
    required this.remotePort,
    required this.localScheme,
    required this.createdAt,
  });

  final String id;
  final String remoteHost;
  final int remotePort;
  final String localScheme;
  final DateTime createdAt;

  factory _RemotePortMappingConfig.fromJson(Map<String, Object?> json) {
    final createdAtMs = (json['created_at'] as num?)?.toInt();
    return _RemotePortMappingConfig(
      id: json['id'] as String,
      remoteHost: (json['remote_host'] as String?) ?? '127.0.0.1',
      remotePort: (json['remote_port'] as num).toInt(),
      localScheme: (json['local_scheme'] as String?) ?? 'http',
      createdAt: createdAtMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(createdAtMs),
    );
  }
}

class MotifClient extends ChangeNotifier implements MotifRuntimeClient {
  MotifClient({MotifClientRuntime? runtime})
    : runtime = runtime ?? const MobileMotifClientRuntime();

  final MotifClientRuntime runtime;

  MotifConnState _state = const ConnDisconnected();
  MotifConnState get state => _state;

  RpcClient? _rpc;
  StreamSubscription<MotifEvent>? _eventSub;
  final List<RemotePortMapping> _remotePortMappings = [];

  List<RemotePortMapping> get remotePortMappings =>
      List.unmodifiable(_remotePortMappings);

  // ─── session-scoped state ───
  List<SessionInfo> sessions = [];
  List<PtyInfo> ptys = [];
  List<ViewInfo> views = [];
  String? activeViewId;
  List<ClientInfo> clients = [];

  int lastSeq = 0;
  final Map<String, int> resumeSeqs = {};
  String? intendedSession;
  String? pendingLocalViewId;
  _PendingViewActivation? _pendingViewActivation;

  // palette/theme this device advertises + the server's broadcast theme
  String? termFg;
  String? termBg;
  String? termTheme;
  String? sessionTheme;

  // per-PTY runtime
  final Map<String, String> runningCommand = {};
  final Map<String, ShellKind> shellKind = {};
  final Map<String, ShellContext> shellContext = {};

  int treeChangeTick = 0;
  int gitChangeTick = 0;

  Map<String, int> _carriedPtyCursors = {};
  bool isForeground = true;

  MotifNotification? latestNotification;
  String? connectionNotice;

  /// The most recent `/ping` payload from a successful [connect]. The
  /// rendezvous direct-upgrade path reads its `rzvDirect*` fields to learn
  /// motifd's LAN addresses. `null` until the first successful connect.
  PingInfo? lastPing;

  /// Show an in-app notification (e.g. a decrypted foreground push).
  void showNotification(MotifNotification n) {
    latestNotification = n;
    notifyListeners();
  }

  /// Clear the in-app notification after it's been shown.
  void consumeNotification() {
    if (latestNotification != null) {
      latestNotification = null;
      notifyListeners();
    }
  }

  // PTY output fan-out: one sink per subscribed PTY surface.
  final Map<String, PtyByteSink> _ptySinks = {};
  static const int _maxReplayBytesPerPty = 2 * 1024 * 1024;
  static const int _replayDeliverMaxBytesPerTick = 64 * 1024;
  static const Duration _replayDeliverInterval = Duration(milliseconds: 16);
  final Map<String, List<Uint8List>> _ptyReplay = {};
  final Map<String, int> _ptyReplayBytes = {};
  final Map<String, _PtyReplayDelivery> _ptyReplayDeliveries = {};
  final Map<String, int> _ptyOutputChunks = {};
  final Map<String, int> _ptyOutputBytes = {};

  bool get isLive => _rpc != null;

  bool get hasTerminalSnapshot =>
      intendedSession != null || ptys.isNotEmpty || views.isNotEmpty;

  /// Whether terminal input may be sent. Only true when a session is
  /// attached; blocks input while disconnected or reconnecting.
  bool get canInput => _state is ConnAttached;

  // ─────────────────────────── connect ───────────────────────────

  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
  }) async {
    if (!force && (_state is ConnConnected || _state is ConnAttached)) return;

    if (force && _rpc != null) {
      _carriedPtyCursors = _rpc!.ptyCursors();
      await _teardownRpc();
    }

    _setState(const ConnConnecting());

    final rpc = RpcClient()
      ..connect(
        host: server.host,
        port: server.port,
        scheme: server.scheme,
        token: server.token,
        proxy: proxy,
        certPin: certPin,
      );

    try {
      final ping = await _pingWithRetry(rpc, server);
      if (!ping.isMotifServer) {
        await rpc.close();
        _setState(ConnFailed('Not a motif server at ${server.endpoint}'));
        return;
      }
      lastPing = ping;
    } catch (e) {
      await rpc.close();
      _setState(ConnFailed(_friendlyError(server, e)));
      return;
    }

    _rpc = rpc;
    if (_carriedPtyCursors.isNotEmpty) {
      rpc.seedPtyCursors(_carriedPtyCursors);
      _carriedPtyCursors = {};
    }

    _eventSub = rpc.events.listen(_handleEvent, onDone: _handleConnectionLost);

    final intended = intendedSession;
    if (intended != null) {
      _setState(ConnAttached(intended));
      try {
        await attach(intended);
        final pending = pendingLocalViewId;
        if (pending != null) {
          if (pending != activeViewId && views.any((v) => v.id == pending)) {
            await activateView(pending);
          }
          pendingLocalViewId = null;
        }
      } catch (error) {
        if (_isSessionNotFound(error)) {
          resumeSeqs.remove(intended);
          _carriedPtyCursors = {};
          intendedSession = null;
          pendingLocalViewId = null;
          connectionNotice = null;
          lastSeq = 0;
          sessionTheme = null;
          _clearSessionState();
          _setState(const ConnConnected());
          unawaited(refreshSessions().catchError((_) {}));
        } else {
          connectionNotice = null;
          if (_rpc != null) _carriedPtyCursors = _rpc!.ptyCursors();
          await _teardownRpc();
          _setState(ConnFailed('reattach failed: $error'));
        }
      }
    } else {
      connectionNotice = null;
      _setState(const ConnConnected());
      // populate the session picker
      unawaited(refreshSessions().catchError((_) {}));
    }
  }

  bool _isSessionNotFound(Object error) =>
      error is RpcException && error.code == _kSessionNotFound;

  Future<PingInfo> _pingWithRetry(RpcClient rpc, MotifServer server) async {
    try {
      return await rpc.ping();
    } catch (_) {
      final delay = server.kind == ServerKind.tailscale
          ? const Duration(milliseconds: 900)
          : const Duration(milliseconds: 350);
      await Future<void>.delayed(delay);
      return rpc.ping();
    }
  }

  Future<void> _teardownRpc() async {
    await _stopRemotePortForwarders();
    await _eventSub?.cancel();
    _eventSub = null;
    await _rpc?.close();
    _rpc = null;
  }

  Future<void> disconnect() async {
    await _teardownRpc();
    _clearSessionState();
    resumeSeqs.clear();
    _carriedPtyCursors = {};
    pendingLocalViewId = null;
    intendedSession = null;
    connectionNotice = null;
    lastSeq = 0;
    _setState(const ConnDisconnected());
  }

  Future<void> suspendTransport(String reason) async {
    final s = _state;
    if (s is ConnAttached && lastSeq > 0) {
      resumeSeqs[s.session] = lastSeq;
    }
    if (_rpc != null) _carriedPtyCursors = _rpc!.ptyCursors();
    if (_pendingViewActivation != null) {
      pendingLocalViewId = activeViewId;
      _completePendingViewActivation();
    }
    await _teardownRpc();
    _setState(ConnSuspended(reason, session: intendedSession));
  }

  void setForeground(bool foreground) {
    if (isForeground == foreground) return;
    isForeground = foreground;
    if (foreground) _reclaimPrimary();
  }

  void _clearSessionState() {
    _completePendingViewActivation();
    ptys = [];
    views = [];
    activeViewId = null;
    clients = [];
    runningCommand.clear();
    shellKind.clear();
    shellContext.clear();
    _ptySinks.clear();
    for (final delivery in _ptyReplayDeliveries.values) {
      delivery.cancel();
    }
    _ptyReplayDeliveries.clear();
    _ptyReplay.clear();
    _ptyReplayBytes.clear();
  }

  void _completePendingViewActivation() {
    final pending = _pendingViewActivation;
    _pendingViewActivation = null;
    if (pending != null && !pending.confirmed.isCompleted) {
      pending.confirmed.complete();
    }
  }

  Future<void> markConnectionLost([String message = 'connection lost']) =>
      _handleConnectionLost(message);

  Future<void> _handleConnectionLost([
    String message = 'connection lost',
  ]) async {
    final s = _state;
    if (s is ConnAttached && lastSeq > 0) {
      resumeSeqs[s.session] = lastSeq;
    }
    if (_rpc != null) _carriedPtyCursors = _rpc!.ptyCursors();
    await _eventSub?.cancel();
    _eventSub = null;
    await _rpc?.close();
    _rpc = null;
    await _stopRemotePortForwarders();
    if (_pendingViewActivation != null) {
      pendingLocalViewId = activeViewId;
      _completePendingViewActivation();
    }
    // Keep ptys/views/intendedSession so the terminal stays on screen offline.
    _setState(ConnFailed(message));
  }

  // ─────────────────────────── sessions ───────────────────────────

  Future<void> refreshSessions() async {
    final rpc = _rpc;
    if (rpc == null) return;
    final body = await rpc.call('session.list');
    sessions = ((body['sessions'] as List?) ?? [])
        .map((e) => SessionInfo.fromJson((e as Map).cast<String, Object?>()))
        .toList();
    notifyListeners();
  }

  Future<SessionInfo> createSession(String name, String workdir) async {
    final rpc = _rpc!;
    final body = await rpc.call('session.create', {
      'name': name,
      'workdir': workdir,
    });
    await refreshSessions();
    return SessionInfo.fromJson(
      (body['session'] as Map?)?.cast<String, Object?>() ?? {'name': name},
    );
  }

  Future<void> destroySession(String name) async {
    await _rpc?.call('session.destroy', {'name': name});
    if (intendedSession == name) intendedSession = null;
    pendingLocalViewId = null;
    await refreshSessions();
  }

  Future<void> attach(String name) async {
    final rpc = _rpc;
    if (rpc == null) throw const RpcException('not connected');
    final params = <String, Object?>{
      'name': name,
      'last_seq': ?resumeSeqs[name],
    };
    // Backgrounded clients don't push palette/theme (mirrors iOS), so only
    // advertise it while foreground.
    if (isForeground) {
      params['term_fg'] = termFg;
      params['term_bg'] = termBg;
      params['theme'] = termTheme;
    }
    final body = await rpc.call('session.attach', params);
    final result = AttachResult.fromJson(body);

    ptys = result.ptys;
    // Cold attach replays a VT snapshot with no shell-integration markers, so
    // the client-side OSC parser can't discover a command that was already
    // running. Seed it from the server's authoritative state and prime the
    // per-PTY shell parser so the next live `command end` marker clears it.
    for (final p in ptys) {
      final rc = p.runningCommand;
      if (rc != null && rc.isNotEmpty) {
        runningCommand[p.id] = rc;
        rpc.primePtyRunning(p.id, rc);
      }
    }
    views = result.views;
    _completePendingViewActivation();
    activeViewId = result.activeView;
    clients = result.clients;
    lastSeq = result.lastSeq ?? 0;
    sessionTheme = result.theme;
    intendedSession = name;
    connectionNotice = null;
    resumeSeqs.remove(name);

    _setState(ConnAttached(name));
    runtime.onSessionAttached(this);
    Log.i(
      'attach session=$name ptys=${ptys.map(_describePty).join(",")} '
      'views=${views.map(_describeView).join(",")} active=$activeViewId '
      'lastSeq=$lastSeq',
      name: 'motif.session',
    );

    _reclaimPrimary();
  }

  Future<void> detach() async {
    await _stopRemotePortForwarders();
    await _rpc?.call('session.detach');
    intendedSession = null;
    resumeSeqs.clear();
    pendingLocalViewId = null;
    _clearSessionState();
    _setState(const ConnConnected());
  }

  String? _activePtyId() {
    final vid = activeViewId;
    return _ptyIdForViewId(vid);
  }

  @override
  String? get activePtyId => _activePtyId();

  @override
  Set<String> get liveTabPtyIds {
    final byId = {for (final pty in ptys) pty.id: pty};
    final ids = <String>{};
    for (final view in views) {
      final spec = view.spec;
      if (spec is! PtyViewSpec) continue;
      final pty = byId[spec.ptyId];
      if (pty == null || (pty.alive ?? true)) ids.add(spec.ptyId);
    }
    return ids;
  }

  String? _ptyIdForViewId(String? viewId) {
    if (viewId == null) return null;
    for (final v in views) {
      if (v.id == viewId && v.spec is PtyViewSpec) {
        return (v.spec as PtyViewSpec).ptyId;
      }
    }
    return null;
  }

  // ─────────────────────────── pty I/O ───────────────────────────

  /// Subscribe a terminal surface to a PTY's decoded output bytes.
  void registerPtySink(String ptyId, PtyByteSink sink) {
    final replacing = _ptySinks.containsKey(ptyId);
    _ptyReplayDeliveries.remove(ptyId)?.cancel();
    _ptySinks[ptyId] = sink;
    final replay = _ptyReplay[ptyId];
    Log.i(
      'register sink pty=$ptyId replacing=$replacing '
      'replayChunks=${replay?.length ?? 0} '
      'replayBytes=${_ptyReplayBytes[ptyId] ?? 0} '
      'activeView=$activeViewId activePty=${_activePtyId()}',
      name: 'motif.pty',
    );
    if (replay == null || replay.isEmpty) return;
    _startReplayDelivery(ptyId, sink, replay);
  }

  void _startReplayDelivery(
    String ptyId,
    PtyByteSink sink,
    List<Uint8List> replay,
  ) {
    final delivery = _PtyReplayDelivery(sink)..chunks.addAll(replay);
    _ptyReplayDeliveries[ptyId] = delivery;
    Log.i(
      'replay sink pty=$ptyId chunks=${replay.length} '
      'bytes=${_ptyReplayBytes[ptyId] ?? 0}',
      name: 'motif.pty',
    );
    _scheduleReplayDelivery(ptyId, delivery);
  }

  void _scheduleReplayDelivery(String ptyId, _PtyReplayDelivery delivery) {
    if (delivery.timer != null) return;
    void deliverBatch() {
      delivery.timer = null;
      if (_ptyReplayDeliveries[ptyId] != delivery ||
          _ptySinks[ptyId] != delivery.sink) {
        return;
      }
      var delivered = 0;
      while (delivery.index < delivery.chunks.length &&
          delivered < _replayDeliverMaxBytesPerTick) {
        final chunk = delivery.chunks[delivery.index];
        final remaining = chunk.length - delivery.offset;
        if (remaining <= 0) {
          delivery.index++;
          delivery.offset = 0;
          continue;
        }
        final budget = _replayDeliverMaxBytesPerTick - delivered;
        final take = remaining <= budget ? remaining : budget;
        final start = delivery.offset;
        final end = start + take;
        delivery.sink(Uint8List.sublistView(chunk, start, end));
        delivered += take;
        delivery.offset = end;
        if (delivery.offset >= chunk.length) {
          delivery.index++;
          delivery.offset = 0;
        }
      }
      if (delivery.index < delivery.chunks.length) {
        delivery.timer = Timer(_replayDeliverInterval, deliverBatch);
      } else if (_ptyReplayDeliveries[ptyId] == delivery) {
        _ptyReplayDeliveries.remove(ptyId);
      }
    }

    delivery.timer = Timer(_replayDeliverInterval, deliverBatch);
  }

  void unregisterPtySink(String ptyId, [PtyByteSink? sink]) {
    if (sink != null && _ptySinks[ptyId] != sink) {
      Log.i('skip unregister stale sink pty=$ptyId', name: 'motif.pty');
      return;
    }
    final hadSink = _ptySinks.containsKey(ptyId);
    _ptySinks.remove(ptyId);
    _ptyReplayDeliveries.remove(ptyId)?.cancel();
    Log.i('unregister sink pty=$ptyId hadSink=$hadSink', name: 'motif.pty');
  }

  Future<void> writePty(String ptyId, List<int> data) {
    // Drop writes while not attached so no input leaks out mid-reconnect.
    if (!canInput) return Future<void>.value();
    return _rpc?.writePty(ptyId, data) ?? Future<void>.value();
  }

  Future<PtyInfo> createPty({
    String? cmd,
    String? cwd,
    required int cols,
    required int rows,
  }) async {
    final rpc = _rpc!;
    final body = await rpc.call('pty.create', {
      'cmd': ?cmd,
      'cwd': ?cwd,
      'cols': cols,
      'rows': rows,
    });
    final info = PtyInfo.fromJson(
      (body['info'] as Map).cast<String, Object?>(),
    );
    if (!ptys.any((p) => p.id == info.id)) {
      ptys = [...ptys, info];
      runtime.onPtySubscriptionsChanged(this);
      notifyListeners();
    }
    return info;
  }

  Future<void> resizePty(String ptyId, int cols, int rows) =>
      _rpc?.call('pty.resize', {'pty_id': ptyId, 'cols': cols, 'rows': rows}) ??
      Future<void>.value();

  @override
  Future<void> ensurePtyStream(String ptyId) =>
      _rpc?.activatePty(ptyId) ?? Future<void>.value();

  @override
  Future<void> closePtyStream(String ptyId) =>
      _rpc?.deactivatePty(ptyId) ?? Future<void>.value();

  @override
  Future<void> syncPtyStreams(Set<String> ptyIds) =>
      _rpc?.syncPtyStreams(ptyIds) ?? Future<void>.value();

  Future<void> activatePtyStream(String ptyId) =>
      runtime.onTerminalSurfaceReady(this, ptyId);

  Future<void> deactivatePtyStream(String ptyId) =>
      runtime.onTerminalSurfaceDisposed(this, ptyId);

  Future<void> killPty(String ptyId) =>
      _rpc?.call('pty.kill', {'pty_id': ptyId}) ?? Future<void>.value();

  Future<void> activateView(String? viewId) async {
    final rpc = _rpc;
    if (rpc == null) {
      if (viewId != null) selectViewLocally(viewId);
      return;
    }
    final currentPending = _pendingViewActivation;
    if (currentPending != null && currentPending.viewId == viewId) {
      await currentPending.confirmed.future;
      return;
    }
    final previous = activeViewId;
    Log.i(
      'activate view requested previous=$previous next=$viewId '
      'nextPty=${_ptyIdForViewId(viewId)}',
      name: 'motif.view',
    );
    if (previous == viewId) {
      await rpc.call('view.activate', {'view_id': ?viewId});
      return;
    }
    _completePendingViewActivation();
    final activation = _PendingViewActivation(
      viewId: viewId,
      previousViewId: previous,
    );
    _pendingViewActivation = activation;
    pendingLocalViewId = viewId;
    activeViewId = viewId;
    notifyListeners();
    try {
      await rpc.call('view.activate', {'view_id': ?viewId});
    } catch (_) {
      if (_pendingViewActivation != activation) return;
      _pendingViewActivation = null;
      if (!activation.confirmed.isCompleted) {
        activation.confirmed.complete();
      }
      if (pendingLocalViewId == viewId) pendingLocalViewId = null;
      if (activeViewId == viewId) {
        activeViewId = activation.previousViewId;
        notifyListeners();
      }
      rethrow;
    }
    if (_pendingViewActivation == activation) {
      await activation.confirmed.future;
    }
    Log.i(
      'activate view confirmed active=$activeViewId '
      'activePty=${_activePtyId()}',
      name: 'motif.view',
    );
  }

  Future<void> closeView(String viewId) async {
    final index = views.indexWhere((view) => view.id == viewId);
    if (index < 0) {
      await _rpc?.call('view.close', {'view_id': viewId});
      return;
    }

    final previousViews = views;
    final previousActiveViewId = activeViewId;
    final previousPendingLocalViewId = pendingLocalViewId;
    final nextViews = [...views]..removeAt(index);
    String? nextActiveViewId = activeViewId;
    if (activeViewId == viewId) {
      nextActiveViewId = nextViews.isEmpty
          ? null
          : nextViews[index.clamp(0, nextViews.length - 1).toInt()].id;
    }
    if (pendingLocalViewId == viewId) {
      pendingLocalViewId = nextActiveViewId;
    }
    views = nextViews;
    activeViewId = nextActiveViewId;
    runtime.onPtySubscriptionsChanged(this);
    notifyListeners();

    final rpc = _rpc;
    if (rpc == null) return;

    try {
      await rpc.call('view.close', {'view_id': viewId});
    } catch (_) {
      if (!views.any((view) => view.id == viewId)) {
        views = previousViews;
        activeViewId = previousActiveViewId;
        pendingLocalViewId = previousPendingLocalViewId;
        runtime.onPtySubscriptionsChanged(this);
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> moveView(String viewId, int toIndex) async {
    final fromIndex = views.indexWhere((v) => v.id == viewId);
    if (fromIndex < 0 || views.isEmpty) return;
    final targetIndex = toIndex.clamp(0, views.length - 1).toInt();
    if (fromIndex == targetIndex) return;

    final previous = views;
    final optimistic = _viewsMoved(viewId, targetIndex);
    views = optimistic;
    notifyListeners();

    final rpc = _rpc;
    if (rpc == null) return;

    try {
      await rpc.call('view.move', {'view_id': viewId, 'to_index': targetIndex});
    } catch (_) {
      if (_sameViewOrder(views, optimistic)) {
        views = previous;
        notifyListeners();
      }
      rethrow;
    }
  }

  List<ViewInfo> _viewsMoved(String viewId, int toIndex) {
    final next = [...views];
    final fromIndex = next.indexWhere((v) => v.id == viewId);
    if (fromIndex < 0 || next.isEmpty) return next;
    final view = next.removeAt(fromIndex);
    next.insert(toIndex.clamp(0, next.length).toInt(), view);
    return next;
  }

  bool _sameViewOrder(List<ViewInfo> a, List<ViewInfo> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  /// Switch tabs locally while offline, preserving the user's choice for
  /// reconciliation after the next auto-reattach.
  void selectViewLocally(String viewId) {
    if (!views.any((v) => v.id == viewId)) return;
    activeViewId = viewId;
    pendingLocalViewId = viewId;
    notifyListeners();
  }

  /// Store this surface's terminal palette and push it to motifd while attached
  /// so OSC 10/11 queries and the session-wide light/dark theme match the UI.
  void setTerminalPalette({String? fg, String? bg, String? theme}) {
    if (fg == termFg && bg == termBg && theme == termTheme) return;
    termFg = fg;
    termBg = bg;
    termTheme = theme;
    final rpc = _rpc;
    if (rpc == null || _state is! ConnAttached) return;
    unawaited(
      rpc
          .call('session.set_palette', {
            'term_fg': ?fg,
            'term_bg': ?bg,
            'theme': ?theme,
          })
          .catchError((_) => <String, Object?>{}),
    );
  }

  void _reclaimPrimary() {
    final rpc = _rpc;
    final vid = activeViewId;
    if (!isForeground ||
        rpc == null ||
        vid == null ||
        _state is! ConnAttached) {
      return;
    }
    unawaited(
      rpc
          .call('view.activate', {'view_id': vid})
          .catchError((_) => <String, Object?>{}),
    );
    if (termFg != null || termBg != null || termTheme != null) {
      unawaited(
        rpc
            .call('session.set_palette', {
              'term_fg': ?termFg,
              'term_bg': ?termBg,
              'theme': ?termTheme,
            })
            .catchError((_) => <String, Object?>{}),
      );
    }
  }

  Future<ViewInfo> openView({
    required ViewSpec spec,
    bool activate = true,
  }) async {
    final rpc = _rpc;
    if (rpc == null) throw const RpcException('not connected');
    final body = await rpc.call('view.open', {
      'spec': spec.toJson(),
      'activate': activate,
    });
    final view = ViewInfo.fromJson(
      (body['view'] as Map).cast<String, Object?>(),
    );
    if (!views.any((v) => v.id == view.id)) {
      views = [...views, view];
      runtime.onPtySubscriptionsChanged(this);
      notifyListeners();
    }
    return view;
  }

  // ─────────────────────────── filesystem / git ───────────────────────────

  Future<List<TreeEntry>> fsTree(
    String path, {
    int? depth,
    bool? showHidden,
  }) async {
    final rpc = _rpc;
    if (rpc == null) return const [];
    final body = await rpc.call('fs.tree', {
      'path': path,
      'depth': ?depth,
      'show_hidden': ?showHidden,
    });
    return ((body['entries'] as List?) ?? [])
        .map((e) => TreeEntry.fromJson((e as Map).cast<String, Object?>()))
        .toList();
  }

  Future<FsReadResult> fsRead(String path, {int? maxBytes}) async {
    final body = await _rpc!.call('fs.read', {
      'path': path,
      'max_bytes': ?maxBytes,
    });
    return FsReadResult.fromJson(body);
  }

  Future<String> fsWrite(
    String path,
    String contentB64, {
    String? expectedSha256,
    bool force = true,
  }) async {
    final body = await _rpc!.call('fs.write', {
      'path': path,
      'content_b64': contentB64,
      'expected_sha256': ?expectedSha256,
      'force': force,
    });
    return (body['sha256'] as String?) ?? '';
  }

  /// Upload raw bytes to a path via the binary fs.write fast path.
  Future<String> writeFileBytes(String path, Uint8List data) =>
      _rpc?.writeFileBinary(path, data) ?? Future.value('');

  Future<List<RemotePortMapping>> refreshRemotePortMappings() async {
    final rpc = _rpc;
    if (rpc == null) throw const RpcException('not connected');
    if (rpc.sessionId == null) {
      throw const RpcException('must attach a session before listing ports');
    }
    final body = await rpc.call('remote_port.list');
    final configs = ((body['mappings'] as List?) ?? [])
        .map(
          (e) => _RemotePortMappingConfig.fromJson(
            (e as Map).cast<String, Object?>(),
          ),
        )
        .toList();
    await _reconcileRemotePortMappings(configs);
    return remotePortMappings;
  }

  Future<RemotePortMapping> addRemotePortMapping({
    String remoteHost = '127.0.0.1',
    required int remotePort,
    String localScheme = 'http',
  }) async {
    final body = await _rpc!.call('remote_port.add', {
      'remote_host': remoteHost,
      'remote_port': remotePort,
      'local_scheme': localScheme,
    });
    final config = _RemotePortMappingConfig.fromJson(
      ((body['mapping'] as Map?) ?? const {}).cast<String, Object?>(),
    );
    final mapping = await _startRemotePortMapping(config);
    _upsertRemotePortMapping(mapping);
    return mapping;
  }

  Future<RemotePortMapping> _startRemotePortMapping(
    _RemotePortMappingConfig config, {
    int? localPort,
  }) async {
    final forwarder = await _startRemotePortForwarder(
      remoteHost: config.remoteHost,
      remotePort: config.remotePort,
      localPort: localPort,
      localScheme: config.localScheme,
    );
    return RemotePortMapping._(
      id: config.id,
      remoteHost: config.remoteHost,
      remotePort: config.remotePort,
      localScheme: config.localScheme,
      createdAt: config.createdAt,
      forwarder: forwarder,
    );
  }

  Future<void> _reconcileRemotePortMappings(
    List<_RemotePortMappingConfig> configs,
  ) async {
    final existingById = {
      for (final mapping in _remotePortMappings) mapping.id: mapping,
    };
    final next = <RemotePortMapping>[];
    final started = <RemotePortForwarder>[];
    final stopAfterSwap = <RemotePortForwarder>[];

    try {
      for (final config in configs) {
        final existing = existingById.remove(config.id);
        if (existing != null && existing._matchesConfig(config)) {
          next.add(existing);
          continue;
        }
        final mapping = await _startRemotePortMapping(config);
        started.add(mapping.forwarder);
        next.add(mapping);
        if (existing != null) stopAfterSwap.add(existing.forwarder);
      }
    } catch (_) {
      await Future.wait([for (final forwarder in started) forwarder.stop()]);
      rethrow;
    }

    stopAfterSwap.addAll(existingById.values.map((m) => m.forwarder));
    _remotePortMappings
      ..clear()
      ..addAll(next);
    notifyListeners();

    await Future.wait([
      for (final forwarder in stopAfterSwap) forwarder.stop(),
    ]);
  }

  void _upsertRemotePortMapping(RemotePortMapping mapping) {
    final index = _remotePortMappings.indexWhere((m) => m.id == mapping.id);
    if (index < 0) {
      _remotePortMappings.add(mapping);
    } else {
      final old = _remotePortMappings[index];
      _remotePortMappings[index] = mapping;
      unawaited(old.forwarder.stop());
    }
    notifyListeners();
  }

  Future<RemotePortMapping> updateRemotePortMapping(
    String id, {
    String remoteHost = '127.0.0.1',
    required int remotePort,
    String localScheme = 'http',
  }) async {
    final body = await _rpc!.call('remote_port.update', {
      'id': id,
      'remote_host': remoteHost,
      'remote_port': remotePort,
      'local_scheme': localScheme,
    });
    final config = _RemotePortMappingConfig.fromJson(
      ((body['mapping'] as Map?) ?? const {}).cast<String, Object?>(),
    );
    final existing = _remotePortMappings
        .where((mapping) => mapping.id == id)
        .firstOrNull;
    if (existing != null && existing._matchesConfig(config)) return existing;

    final mapping = await _startRemotePortMapping(config);
    _upsertRemotePortMapping(mapping);
    return mapping;
  }

  Future<void> removeRemotePortMapping(String id) async {
    await _rpc!.call('remote_port.remove', {'id': id});
    final index = _remotePortMappings.indexWhere((m) => m.id == id);
    if (index < 0) return;
    final mapping = _remotePortMappings.removeAt(index);
    notifyListeners();
    await mapping.forwarder.stop();
  }

  Future<RemotePortForwarder> openRemotePort({
    String remoteHost = '127.0.0.1',
    required int remotePort,
    int? localPort,
    String localScheme = 'http',
  }) async {
    final body = await _rpc!.call('remote_port.add', {
      'remote_host': remoteHost,
      'remote_port': remotePort,
      'local_scheme': localScheme,
    });
    final config = _RemotePortMappingConfig.fromJson(
      ((body['mapping'] as Map?) ?? const {}).cast<String, Object?>(),
    );
    final mapping = await _startRemotePortMapping(config, localPort: localPort);
    _upsertRemotePortMapping(mapping);
    return mapping.forwarder;
  }

  Future<void> stopRemotePortForwarder(RemotePortForwarder forwarder) async {
    final index = _remotePortMappings.indexWhere(
      (m) => identical(m.forwarder, forwarder),
    );
    if (index >= 0) {
      final id = _remotePortMappings[index].id;
      await _rpc?.call('remote_port.remove', {'id': id});
      _remotePortMappings.removeAt(index);
      notifyListeners();
    }
    await forwarder.stop();
  }

  Future<void> _stopRemotePortForwarders() async {
    final mappings = _remotePortMappings.toList();
    _remotePortMappings.clear();
    if (mappings.isNotEmpty) notifyListeners();
    await Future.wait([
      for (final mapping in mappings) mapping.forwarder.stop(),
    ]);
  }

  Future<RemotePortForwarder> _startRemotePortForwarder({
    required String remoteHost,
    required int remotePort,
    int? localPort,
    required String localScheme,
  }) async {
    final rpc = _rpc;
    if (rpc == null) throw const RpcException('not connected');
    final sessionId = rpc.sessionId;
    if (sessionId == null) {
      throw const RpcException('must attach a session before forwarding ports');
    }
    return RemotePortForwarder.start(
      rpc: rpc,
      remoteHost: remoteHost,
      remotePort: remotePort,
      localPort: localPort,
      localScheme: localScheme,
      sessionId: sessionId,
    );
  }

  Future<void> fsMkdir(String path) =>
      _rpc?.call('fs.mkdir', {'path': path}) ?? Future.value();
  Future<void> fsRemove(String path) =>
      _rpc?.call('fs.remove', {'path': path}) ?? Future.value();
  Future<void> fsRename(String from, String to) =>
      _rpc?.call('fs.rename', {'from': from, 'to': to}) ?? Future.value();

  Future<GitStatusResult> gitStatus({String? cwd}) async {
    final body = await _rpc!.call('git.status', {'cwd': ?cwd});
    return GitStatusResult.fromJson(body);
  }

  Future<String> gitDiff({
    String? path,
    bool staged = false,
    String? cwd,
  }) async {
    final body = await _rpc!.call('git.diff', {
      'path': ?path,
      'staged': staged,
      'cwd': ?cwd,
    });
    return (body['patch'] as String?) ?? '';
  }

  Future<List<DiffSummaryFile>> gitDiffSummary({
    String? path,
    bool staged = false,
    String? cwd,
  }) async {
    final body = await _rpc!.call('git.diffSummary', {
      'path': ?path,
      'staged': staged,
      'cwd': ?cwd,
    });
    return ((body['files'] as List?) ?? [])
        .map(
          (e) => DiffSummaryFile.fromJson((e as Map).cast<String, Object?>()),
        )
        .toList();
  }

  /// The cwd of the active PTY, used as the default root for fs/git panels.
  String? get activeCwd {
    final id = _activePtyId();
    if (id == null) return ptys.isEmpty ? null : ptys.first.cwd;
    for (final p in ptys) {
      if (p.id == id) return p.cwd;
    }
    return null;
  }

  // ─────────────────────────── device / push ───────────────────────────

  /// Register this device for E2E push. [encKeyBase64] is the per-device
  /// AES-256-GCM key the server encrypts payloads with. Returns instance_id.
  Future<String?> registerDevice({
    required String deviceToken,
    required String platform,
    required String encKeyBase64,
    String? environment,
    String? appVersion,
    List<String> mutedSessions = const [],
  }) async {
    final rpc = _rpc;
    if (rpc == null) return null;
    final body = await rpc.call('device.register', {
      'device_token': deviceToken,
      'platform': platform,
      'environment': ?environment,
      'enc_key': encKeyBase64,
      'app_version': ?appVersion,
      'muted_sessions': mutedSessions,
    });
    return body['instance_id'] as String?;
  }

  Future<void> unregisterDevice(String deviceToken) =>
      _rpc?.call('device.unregister', {'device_token': deviceToken}) ??
      Future<void>.value();

  Future<void> setSessionMuted({
    required String deviceToken,
    required String session,
    required bool muted,
  }) =>
      _rpc?.call('device.set_session_muted', {
        'device_token': deviceToken,
        'session': session,
        'muted': muted,
      }) ??
      Future<void>.value();

  // ─────────────────────────── event handling ───────────────────────────

  void _handleEvent(MotifEvent e) {
    final p = e.params;
    final seq = (p['seq'] as num?)?.toInt();
    if (seq != null && seq > lastSeq) lastSeq = seq;

    switch (e.method) {
      case 'pty.output':
        final id = p['pty_id'] as String?;
        final bytes = _bytesFromPtyOutput(p);
        if (id != null && bytes != null) {
          _rememberPtyBytes(id, bytes);
          _notePtyOutput(id, bytes.length);
          final delivery = _ptyReplayDeliveries[id];
          if (delivery != null && _ptySinks[id] == delivery.sink) {
            delivery.chunks.add(bytes);
            _scheduleReplayDelivery(id, delivery);
          } else {
            _ptySinks[id]?.call(bytes);
          }
        }
        return; // hot path: no rebuild
      case 'pty.exited':
        final id = p['pty_id'] as String?;
        if (id != null) {
          _updatePty(id, (pty) => pty.copyWith(alive: false));
          _ptyReplayDeliveries.remove(id)?.cancel();
          _ptyReplay.remove(id);
          _ptyReplayBytes.remove(id);
          runningCommand.remove(id);
          shellKind.remove(id);
          shellContext.remove(id);
          runtime.onPtySubscriptionsChanged(this);
        }
      case 'pty.created':
        final info = PtyInfo.fromJson(
          (p['info'] as Map).cast<String, Object?>(),
        );
        if (!ptys.any((x) => x.id == info.id)) {
          ptys = [...ptys, info];
          runtime.onPtySubscriptionsChanged(this);
        }
      case 'pty.resize':
        final id = p['pty_id'] as String?;
        if (id != null) {
          _updatePty(
            id,
            (pty) => pty.copyWith(
              cols: (p['cols'] as num?)?.toInt(),
              rows: (p['rows'] as num?)?.toInt(),
            ),
          );
        }
      case 'pty.cwd_changed':
        final id = p['pty_id'] as String?;
        if (id != null) {
          _updatePty(id, (pty) => pty.copyWith(cwd: p['cwd'] as String?));
        }
      case 'pty.command_started':
        final id = p['pty_id'] as String?;
        final text = p['text'] as String?;
        if (id != null && text != null && text.isNotEmpty) {
          runningCommand[id] = text;
        }
      case 'pty.command_finished':
        final id = p['pty_id'] as String?;
        if (id != null) runningCommand.remove(id);
      case 'pty.shell_bootstrapped':
        final id = p['pty_id'] as String?;
        if (id != null) shellKind[id] = ShellKind.fromWire(p['shell']);
      case 'pty.shell_context':
        final id = p['pty_id'] as String?;
        if (id != null && p['ctx'] is Map) {
          shellContext[id] = ShellContext.fromMap(
            (p['ctx'] as Map).map((k, v) => MapEntry('$k', '$v')),
          );
        }
      case 'view.opened':
        final v = ViewInfo.fromJson((p['view'] as Map).cast<String, Object?>());
        if (!views.any((x) => x.id == v.id)) views = [...views, v];
        runtime.onPtySubscriptionsChanged(this);
      case 'view.closed':
        final id = p['view_id'] as String?;
        views = views.where((v) => v.id != id).toList();
        if (activeViewId == id) activeViewId = null;
        final pending = _pendingViewActivation;
        if (pending != null && pending.viewId == id) {
          _pendingViewActivation = null;
          if (pendingLocalViewId == id) pendingLocalViewId = null;
          if (!pending.confirmed.isCompleted) {
            pending.confirmed.complete();
          }
        }
        runtime.onPtySubscriptionsChanged(this);
      case 'view.active_changed':
        final id = p['view_id'] as String?;
        final pending = _pendingViewActivation;
        if (pending != null && pending.viewId != id) {
          return;
        }
        if (pending != null) {
          _pendingViewActivation = null;
          if (pendingLocalViewId == id) pendingLocalViewId = null;
          if (!pending.confirmed.isCompleted) {
            pending.confirmed.complete();
          }
        }
        activeViewId = id;
        Log.i(
          'event active_changed view=$id pty=${_ptyIdForViewId(id)}',
          name: 'motif.view',
        );
        _onActiveViewChanged();
      case 'view.moved':
        final order = ((p['order'] as List?) ?? []).map((e) => '$e').toList();
        final byId = {for (final v in views) v.id: v};
        views = [
          for (final id in order)
            if (byId[id] != null) byId[id]!,
        ];
      case 'tree.changed':
        treeChangeTick++;
      case 'git.changed':
        gitChangeTick++;
      case 'session.theme_changed':
        sessionTheme = p['theme'] as String?;
      case 'client.joined':
        final c = ClientInfo.fromJson(p);
        clients = [...clients.where((x) => x.id != c.id), c];
      case 'client.left':
        final id = p['client_id'] as String?;
        clients = clients.where((c) => c.id != id).toList();
      case 'notification':
        latestNotification = MotifNotification.fromJson(p);
    }
    notifyListeners();
  }

  void _onActiveViewChanged() {
    runtime.onActiveViewChanged(this);
  }

  void _rememberPtyBytes(String ptyId, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final chunks = _ptyReplay.putIfAbsent(ptyId, () => <Uint8List>[]);
    chunks.add(Uint8List.fromList(bytes));
    var total = (_ptyReplayBytes[ptyId] ?? 0) + bytes.length;
    while (total > _maxReplayBytesPerPty && chunks.isNotEmpty) {
      total -= chunks.removeAt(0).length;
    }
    _ptyReplayBytes[ptyId] = total;
  }

  void _notePtyOutput(String ptyId, int byteCount) {
    final chunks = (_ptyOutputChunks[ptyId] ?? 0) + 1;
    final bytes = (_ptyOutputBytes[ptyId] ?? 0) + byteCount;
    _ptyOutputChunks[ptyId] = chunks;
    _ptyOutputBytes[ptyId] = bytes;
    final logAtInfo = chunks <= 3 || chunks == 10;
    final logAtDebug = chunks == 100 || chunks % 1000 == 0;
    if (logAtInfo || logAtDebug) {
      final message =
          'output pty=$ptyId chunk=$chunks bytes=$byteCount totalBytes=$bytes '
          'hasSink=${_ptySinks.containsKey(ptyId)} '
          'activePty=${_activePtyId()} '
          'replayBytes=${_ptyReplayBytes[ptyId] ?? 0}';
      if (logAtInfo) {
        Log.i(message, name: 'motif.pty');
      } else {
        Log.d(message, name: 'motif.pty');
      }
    }
  }

  Uint8List? _bytesFromPtyOutput(Map<String, Object?> params) {
    final raw = params['data_bytes'];
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    final b64 = params['data_b64'];
    if (b64 is String) return base64Decode(b64);
    return null;
  }

  void _updatePty(String id, PtyInfo Function(PtyInfo) f) {
    ptys = [
      for (final pty in ptys)
        if (pty.id == id) f(pty) else pty,
    ];
  }

  void _setState(MotifConnState s) {
    _state = s;
    notifyListeners();
  }

  String _friendlyError(MotifServer server, Object e) {
    if (e is RpcException) {
      if (e.code != null) return 'Server error ${e.code}: ${e.message}';
      return e.message;
    }
    final msg = e.toString();
    if (server.kind == ServerKind.tailscale) {
      return "Can't reach ${server.endpoint} over Tailscale. Check MagicDNS "
          'and that the peer is online.\n$msg';
    }
    if (server.kind == ServerKind.ssh) {
      return "Can't reach ${server.endpoint} through the SSH tunnel. Check the "
          'SSH login, remote motifd host/port, and that motifd is running.\n$msg';
    }
    return "Can't reach ${server.endpoint}. Check the host/port and that "
        'motifd is running.\n$msg';
  }

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

  @override
  void dispose() {
    _teardownRpc();
    super.dispose();
  }
}
