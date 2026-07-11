/// Coordinator-style client for the motif protocol.
///
/// Ported from `apps/ios/Motif/Native/RpcClient.swift`. RPC is HTTP POST to
/// `/rpc/<method>`; the `/events` WebSocket carries server notifications and is
/// opened lazily after `session.attach`; per-PTY `/pty/<id>` WebSockets stream
/// raw terminal bytes for whichever PTYs the platform runtime subscribes to.
///
/// Transport is cross-platform: `package:http` for RPC and
/// `package:web_socket_channel` for the WebSockets (via [connectWebSocket],
/// which keeps header-based auth on native and degrades to query-string auth on
/// web where the browser can't set upgrade headers).
///
/// Routing (mirrors the Rust Coordinator):
///   - `session.attach` → POST; on success store session id + open `/events`.
///   - `session.detach` → close PTY + events WS, then POST.
///   - `pty.create`     → POST; higher-level runtime decides PTY subscription.
///   - `pty.kill`       → POST; then close that PTY WS.
///   - everything else  → POST passthrough.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../log/log.dart';
import '../models/motif_proto.dart';
import 'pty_frame_processor.dart';
import 'proxy_client.dart';
import 'shell_integration.dart';
import 'ws_channel.dart';

/// A server-pushed notification (no id). Carries the decoded `params` map.
class MotifEvent {
  final String method;
  final Map<String, Object?> params;
  const MotifEvent(this.method, this.params);
}

class RpcException implements Exception {
  final String message;
  final int? code;
  const RpcException(this.message, {this.code});
  @override
  String toString() => code == null ? 'rpc: $message' : 'rpc $code: $message';
}

/// PTY close code signalling our resume cursor is unusable.
const _kCursorTruncated = 4011;

class _PtyChannel {
  WebSocketChannel? socket;
  StreamSubscription<Object?>? sub;
  Future<void>? opening;
  Future<void> processing = Future<void>.value();
  int cursor = 0;
  bool hasCursor = false;
  bool awaitingMeta = true;
  int generation = 0;
  Stopwatch? openStopwatch;
  bool firstOutputLogged = false;
  int? replayBytesRemaining;
  int? replayBytesTotal;
  Completer<void>? replayComplete;
}

class _PtyMeta {
  final int since;
  final int replayBytes;
  const _PtyMeta({required this.since, required this.replayBytes});
}

class RpcClient {
  RpcClient() : _http = _createHttpClient();

  static http.Client Function()? debugHttpClientFactory;

  static http.Client _createHttpClient() =>
      debugHttpClientFactory?.call() ?? http.Client();

  http.Client _http;
  ProxySettings _proxy = ProxySettings.none;

  /// rzv end-to-end TLS cert pin (`sha256(cert.der)`), or null for plaintext
  /// transports. Applied to the RPC http client and every PTY/events WS.
  Uint8List? _certPin;

  String _host = '';
  int _port = 0;
  String _scheme = 'http';
  String _token = '';

  String? _sessionId;

  WebSocketChannel? _eventsSocket;
  StreamSubscription<Object?>? _eventsSub;

  final Map<String, _PtyChannel> _ptys = {};
  String? _activePtyId;
  final Set<String> _streamingPtys = {};
  Set<String> _desiredStreamingPtys = {};
  Future<void>? _ptyStreamSync;
  int _ptyStreamGeneration = 0;
  Future<PtyFrameProcessor>? _ptyProcessor;

  final StreamController<MotifEvent> _events =
      StreamController<MotifEvent>.broadcast();

  /// Stream of server notifications + client-synthesized pty events.
  Stream<MotifEvent> get events => _events.stream;

  bool get isConnected => _host.isNotEmpty;
  String? get sessionId => _sessionId;

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $_token',
    'X-Motif-Session': ?_sessionId,
  };

  void connect({
    required String host,
    required int port,
    required String token,
    String scheme = 'http',
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
  }) {
    _host = host;
    _port = port;
    _scheme = scheme == 'https' ? 'https' : 'http';
    _token = token;
    _proxy = proxy;
    _certPin = certPin;
    if (proxy.isActive || certPin != null) {
      _http.close();
      _http = makeHttpClient(proxy, certPin: certPin);
    }
  }

  Future<void> close() async {
    await _closeSessionStreams();
    await _resetPtyProcessor();
    _sessionId = null;
    if (!_events.isClosed) await _events.close();
    _http.close();
  }

  // ─────────────────────────── HTTP RPC ───────────────────────────

  /// GET /ping — unauthenticated identity probe.
  Future<PingInfo> ping() async {
    final uri = _uri('/ping');
    final resp = await _http.get(uri).timeout(const Duration(seconds: 8));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw RpcException('ping HTTP ${resp.statusCode}');
    }
    return PingInfo.fromJson(jsonDecode(resp.body) as Map<String, Object?>);
  }

  /// Generic RPC call. Returns the decoded JSON result (`{}` when empty).
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    switch (method) {
      case 'session.attach':
        return _doAttach(params);
      case 'session.detach':
        return _doDetach();
      case 'pty.kill':
        return _doPtyKill(params);
      default:
        final (body, _) = await _rawCall(method, params);
        return body;
    }
  }

  Future<(Map<String, Object?>, String?)> _rawCall(
    String method,
    Map<String, Object?> params,
  ) async {
    final uri = _uri('/rpc/$method');
    final timeout = method == 'fs.write'
        ? const Duration(seconds: 60)
        : const Duration(seconds: 30);
    final resp = await _http
        .post(
          uri,
          headers: {..._authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode(params),
        )
        .timeout(timeout);
    final sidHeader = resp.headers['x-motif-session'];
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      try {
        final err = jsonDecode(resp.body) as Map<String, Object?>;
        throw RpcException(
          (err['message'] as String?) ?? 'error',
          code: (err['code'] as num?)?.toInt(),
        );
      } on RpcException {
        rethrow;
      } catch (_) {
        throw RpcException('HTTP ${resp.statusCode}');
      }
    }
    final decoded = resp.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(resp.body);
    return (
      decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{},
      sidHeader,
    );
  }

  Future<Map<String, Object?>> _doAttach(Map<String, Object?> params) async {
    // session.attach replaces an existing attachment server-side when the
    // current X-Motif-Session is reused. Tear down the old local streams in
    // parallel, but deliberately keep _sessionId so the attach is atomic and
    // needs no preceding session.detach round trip.
    if (_sessionId != null) {
      await _closeSessionStreams();
      await _resetPtyProcessor();
    }
    final sw = Stopwatch()..start();
    final (body, sid) = await _rawCall('session.attach', params);
    final postMs = sw.elapsedMilliseconds;
    if (sid == null) {
      throw const RpcException('session.attach: no X-Motif-Session header');
    }
    _sessionId = sid;
    final requestedSince = (params['last_seq'] as num?)?.toInt();
    final since = requestedSince ?? (body['last_seq'] as num?)?.toInt() ?? 0;
    await _openEvents(since);
    Log.i(
      'attach timing post=${postMs}ms events=${sw.elapsedMilliseconds - postMs}ms '
      'eventsSince=$since',
      name: 'motif.rpc',
    );
    return body;
  }

  Future<Map<String, Object?>> _doDetach() async {
    await _closeSessionStreams();
    await _resetPtyProcessor();
    final (body, _) = await _rawCall('session.detach', {});
    _sessionId = null;
    return body;
  }

  Future<Map<String, Object?>> _doPtyKill(Map<String, Object?> params) async {
    final pid = params['pty_id'] as String?;
    final (body, _) = await _rawCall('pty.kill', params);
    if (pid != null) {
      await _closePty(pid, removeState: true);
      if (_activePtyId == pid) _activePtyId = null;
      _streamingPtys.remove(pid);
      _desiredStreamingPtys.remove(pid);
    }
    return body;
  }

  /// Binary `fs.write`: POST raw bytes as octet-stream, params in query.
  Future<String> writeFileBinary(
    String path,
    Uint8List data, {
    bool force = true,
    String? expectedSha256,
  }) async {
    final uri = Uri(
      scheme: _scheme,
      host: _host,
      port: _port,
      path: '/rpc/fs.write',
      queryParameters: {
        'path': path,
        if (force) 'force': 'true',
        'expected_sha256': ?expectedSha256,
      },
    );
    final resp = await _http
        .post(
          uri,
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/octet-stream',
          },
          body: data,
        )
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw RpcException('fs.write (binary) failed: HTTP ${resp.statusCode}');
    }
    return (jsonDecode(resp.body) as Map)['sha256'] as String;
  }

  // ─────────────────────────── /events ───────────────────────────

  String _wsAuthQuery() => 'token=${Uri.encodeQueryComponent(_token)}';

  Future<void> _openEvents(int since) async {
    final sid = _sessionId;
    if (sid == null) throw const RpcException('not connected');
    final url =
        '$_wsScheme://$_host:$_port/events?session=$sid&since=$since&${_wsAuthQuery()}';
    final socket = connectWebSocket(
      url,
      headers: {'Authorization': 'Bearer $_token'},
      proxyHost: _proxy.proxyHost,
      proxyPort: _proxy.proxyPort,
      proxyUser: _proxy.username,
      proxyPass: _proxy.password,
      certPin: _certPin,
    );
    final sw = Stopwatch()..start();
    await socket.ready;
    Log.i(
      'ws ready events since=$since took=${sw.elapsedMilliseconds}ms',
      name: 'motif.resume',
    );
    _eventsSocket = socket;
    _eventsSub = socket.stream.listen(
      (msg) {
        final data = msg is String ? utf8.encode(msg) : (msg as List<int>);
        _yieldFrame(Uint8List.fromList(data));
      },
      onDone: () {
        if (!_events.isClosed) _events.close();
      },
      onError: (Object _) {
        if (!_events.isClosed) _events.close();
      },
      cancelOnError: true,
    );
  }

  /// Open a raw WebSocket endpoint on motifd using this client's currently
  /// resolved transport (direct, tailscale proxy, rendezvous loopback, or SSH
  /// loopback). Callers own the returned channel.
  WebSocketChannel openRawWebSocket(
    String path, {
    Map<String, String> query = const {},
  }) {
    if (_host.isEmpty) throw const RpcException('not connected');
    final uri = Uri(
      scheme: _wsScheme,
      host: _host,
      port: _port,
      path: path,
      queryParameters: {...query, 'token': _token},
    );
    return connectWebSocket(
      uri.toString(),
      headers: {'Authorization': 'Bearer $_token'},
      proxyHost: _proxy.proxyHost,
      proxyPort: _proxy.proxyPort,
      proxyUser: _proxy.username,
      proxyPass: _proxy.password,
      certPin: _certPin,
    );
  }

  void _yieldFrame(Uint8List frame) {
    try {
      final obj = jsonDecode(utf8.decode(frame));
      if (obj is Map) {
        final method = obj['method'] as String? ?? '?';
        final params =
            (obj['params'] as Map?)?.cast<String, Object?>() ?? const {};
        _emit(MotifEvent(method, params));
      }
    } catch (_) {
      // Non-JSON event frame — ignore.
    }
  }

  void _emit(MotifEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  Uri _uri(String path) =>
      Uri(scheme: _scheme, host: _host, port: _port, path: path);

  String get _wsScheme => _scheme == 'https' ? 'wss' : 'ws';

  // ─────────────────────────── /pty/<id> ───────────────────────────

  /// Snapshot per-PTY byte cursors so a successor client can resume.
  Map<String, int> ptyCursors() => {
    for (final e in _ptys.entries) e.key: e.value.cursor,
  };

  /// Seed cursors carried over from a previous connection.
  void seedPtyCursors(Map<String, int> cursors) {
    cursors.forEach((id, cursor) {
      final ch = _ptys[id] ?? _PtyChannel();
      if (ch.socket != null) return;
      ch.cursor = cursor;
      ch.hasCursor = true;
      _ptys[id] = ch;
    });
  }

  Future<void> activatePty(String ptyId) async {
    _activePtyId = ptyId;
    _streamingPtys.add(ptyId);
    _desiredStreamingPtys.add(ptyId);
    Log.i(
      'activate pty=$ptyId streaming=${_streamingPtys.length}',
      name: 'motif.rpc',
    );
    await _openPty(ptyId);
  }

  Future<void> syncPtyStreams(Set<String> ptyIds) {
    _desiredStreamingPtys = Set<String>.from(ptyIds);
    final running = _ptyStreamSync;
    if (running != null) return running;
    late final Future<void> sync;
    final generation = _ptyStreamGeneration;
    sync = _drainPtyStreamSync(generation).whenComplete(() {
      if (identical(_ptyStreamSync, sync)) _ptyStreamSync = null;
    });
    _ptyStreamSync = sync;
    return _ptyStreamSync!;
  }

  Future<void> waitForPtyReplay(String ptyId) {
    final pending = _ptys[ptyId]?.replayComplete;
    return pending?.future ?? Future<void>.value();
  }

  Future<void> _drainPtyStreamSync(int generation) async {
    while (generation == _ptyStreamGeneration) {
      final wanted = Set<String>.from(_desiredStreamingPtys);
      await _applyPtyStreamSet(wanted, generation);
      if (generation != _ptyStreamGeneration) return;
      if (_sameStringSet(wanted, _desiredStreamingPtys)) return;
    }
  }

  Future<void> _applyPtyStreamSet(Set<String> wanted, int generation) async {
    if (generation != _ptyStreamGeneration) return;
    final current = Set<String>.from(_streamingPtys);
    final toClose = current.difference(wanted);

    for (final ptyId in toClose) {
      if (_activePtyId == ptyId) _activePtyId = null;
      _streamingPtys.remove(ptyId);
      await _closePty(ptyId, removeState: false);
      if (generation != _ptyStreamGeneration) return;
    }

    for (final ptyId in wanted) {
      _streamingPtys.add(ptyId);
    }

    if (generation != _ptyStreamGeneration) return;
    await Future.wait([for (final ptyId in wanted) _openPty(ptyId)]);
  }

  Future<void> deactivatePty(String ptyId) async {
    if (_activePtyId == ptyId) _activePtyId = null;
    _streamingPtys.remove(ptyId);
    _desiredStreamingPtys.remove(ptyId);
    Log.i(
      'deactivate pty=$ptyId streaming=${_streamingPtys.length}',
      name: 'motif.rpc',
    );
    await _closePty(ptyId, removeState: false);
  }

  /// Seed the per-PTY shell parser with a command the server reports as
  /// running on cold attach, so the client recognizes it even though the VT
  /// snapshot carried no start marker. The next live `command end` marker then
  /// clears it through the normal parser path. Safe to call before the socket
  /// opens — the channel (and its [ShellState]) is created on demand and reused
  /// by [_openPty].
  Future<void> primePtyRunning(String ptyId, String cmd) async {
    if (cmd.isEmpty) return;
    final processor = await _frameProcessor();
    await processor.primeRunning(ptyId, cmd);
  }

  Future<void> _openPty(String ptyId) async {
    final sid = _sessionId;
    if (sid == null) throw const RpcException('not connected');
    final existing = _ptys[ptyId];
    if (existing?.socket != null) {
      Log.i(
        'open pty=$ptyId skipped existing socket cursor=${existing!.cursor}',
        name: 'motif.rpc',
      );
      return;
    }
    final existingOpen = existing?.opening;
    if (existingOpen != null) {
      Log.i('open pty=$ptyId joining existing open', name: 'motif.rpc');
      return existingOpen;
    }

    final ch = existing ?? _PtyChannel();
    _ptys[ptyId] = ch;
    final generation = ++ch.generation;
    ch.replayComplete = Completer<void>();
    Log.i(
      'open pty=$ptyId gen=$generation hasCursor=${ch.hasCursor} '
      'cursor=${ch.cursor}',
      name: 'motif.rpc',
    );
    late final Future<void> opening;
    opening = _openPtySocket(ptyId, ch, generation, sid).whenComplete(() {
      final current = _ptys[ptyId];
      if (identical(current, ch) &&
          ch.generation == generation &&
          identical(ch.opening, opening)) {
        ch.opening = null;
      }
    });
    ch.opening = opening;
    return opening;
  }

  Future<void> _openPtySocket(
    String ptyId,
    _PtyChannel ch,
    int generation,
    String sid,
  ) async {
    final sw = Stopwatch()..start();
    final sinceQuery = ch.hasCursor ? '&since=${ch.cursor}' : '';
    final url =
        '$_wsScheme://$_host:$_port/pty/$ptyId?session=$sid$sinceQuery&pty_frame=v1&pty_compress=zlib&${_wsAuthQuery()}';
    Log.i(
      'ws open pty=$ptyId gen=$generation since=${ch.hasCursor ? ch.cursor : "full"}',
      name: 'motif.rpc',
    );
    final socket = connectWebSocket(
      url,
      headers: {'Authorization': 'Bearer $_token'},
      proxyHost: _proxy.proxyHost,
      proxyPort: _proxy.proxyPort,
      proxyUser: _proxy.username,
      proxyPass: _proxy.password,
      certPin: _certPin,
    );
    try {
      await socket.ready;
    } catch (e, st) {
      if (!identical(_ptys[ptyId], ch) || ch.generation != generation) {
        _completePtyReplay(ch);
        // Superseded by a newer open/close; the failure is expected but must
        // not be swallowed silently.
        Log.d(
          'pty $ptyId: stale ws open failed (ignored)',
          name: 'motif.rpc',
          error: e,
          stackTrace: st,
        );
        return;
      }
      rethrow;
    }
    if (!identical(_ptys[ptyId], ch) || ch.generation != generation) {
      _completePtyReplay(ch);
      unawaited(socket.sink.close(1000));
      Log.i(
        'ws open superseded pty=$ptyId gen=$generation currentGen=${ch.generation}',
        name: 'motif.rpc',
      );
      // A concurrent _closePty bumped the generation while we awaited `ready`,
      // so this socket — along with the server's cold full-screen replay — is
      // discarded. If the PTY should still be streaming and nothing else is
      // opening it, reopen with the current generation; otherwise the grid
      // stays empty until the user types, which lazily reconnects with a
      // `since` tail that never replays the screen.
      final current = _ptys[ptyId];
      if (_streamingPtys.contains(ptyId) &&
          current != null &&
          current.socket == null &&
          current.opening == null) {
        unawaited(_openPty(ptyId));
      }
      return;
    }
    ch.socket = socket;
    ch.awaitingMeta = true;
    ch.openStopwatch = sw;
    ch.firstOutputLogged = false;
    ch.replayBytesRemaining = null;
    ch.replayBytesTotal = null;
    Log.i(
      'ws ready pty=$ptyId gen=$generation took=${sw.elapsedMilliseconds}ms',
      name: 'motif.resume',
    );
    ch.sub = socket.stream.listen(
      (msg) => _onPtyMessage(ptyId, socket, msg),
      onDone: () => _onPtyDone(ptyId, socket),
      onError: (Object _) => _onPtyDone(ptyId, socket),
      cancelOnError: true,
    );
  }

  void _onPtyMessage(String ptyId, WebSocketChannel socket, Object? msg) {
    final ch = _ptys[ptyId];
    if (ch == null || ch.socket != socket) return;

    if (ch.awaitingMeta) {
      ch.awaitingMeta = false;
      final meta = msg is String ? _parsePtyMeta(msg) : null;
      if (meta == null) {
        unawaited(socket.sink.close(1002, 'invalid PTY metadata'));
        return;
      }
      ch.cursor = meta.since;
      ch.hasCursor = true;
      ch.replayBytesRemaining = meta.replayBytes;
      ch.replayBytesTotal = meta.replayBytes;
      Log.i(
        'ws meta pty=$ptyId since=${meta.since} '
        'replayBytes=${meta.replayBytes}',
        name: 'motif.rpc',
      );
      if (meta.replayBytes == 0) {
        Log.i(
          'ws replay complete pty=$ptyId bytes=0 '
          'took=${ch.openStopwatch?.elapsedMilliseconds ?? -1}ms',
          name: 'motif.resume',
        );
        ch.replayBytesRemaining = null;
        _completePtyReplay(ch);
      }
      return;
    }

    final Uint8List data;
    if (msg is String) {
      data = Uint8List.fromList(utf8.encode(msg));
    } else if (msg is Uint8List) {
      data = msg;
    } else if (msg is List<int>) {
      data = Uint8List.fromList(msg);
    } else {
      return;
    }
    final generation = ch.generation;
    final isFirstOutput = !ch.firstOutputLogged;
    ch.firstOutputLogged = true;
    ch.processing = ch.processing.then((_) async {
      if (!_isCurrentPtySocket(ptyId, ch, socket, generation)) return;
      try {
        final processor = await _frameProcessor();
        final result = await processor.process(ptyId, data);
        if (!_isCurrentPtySocket(ptyId, ch, socket, generation)) return;
        ch.cursor += result.decodedLength;
        if (isFirstOutput) {
          Log.i(
            'ws first output pty=$ptyId bytes=${result.decodedLength} '
            'took=${ch.openStopwatch?.elapsedMilliseconds ?? -1}ms',
            name: 'motif.resume',
          );
        }
        final replayRemaining = ch.replayBytesRemaining;
        if (replayRemaining != null) {
          final next = replayRemaining - result.decodedLength;
          if (next <= 0) {
            Log.i(
              'ws replay complete pty=$ptyId bytes=${ch.replayBytesTotal} '
              'took=${ch.openStopwatch?.elapsedMilliseconds ?? -1}ms',
              name: 'motif.resume',
            );
            ch.replayBytesRemaining = null;
            _completePtyReplay(ch);
          } else {
            ch.replayBytesRemaining = next;
          }
        }
        _emitProcessedPtyFrame(ptyId, result);
      } catch (e, st) {
        if (!_isCurrentPtySocket(ptyId, ch, socket, generation)) return;
        Log.w(
          'pty $ptyId: framed decode failed',
          name: 'motif.rpc',
          error: e,
          stackTrace: st,
        );
        await _recoverPtyAfterDecodeError(ptyId, ch);
      }
    });
  }

  Future<void> _recoverPtyAfterDecodeError(String ptyId, _PtyChannel ch) async {
    ch
      ..cursor = 0
      ..hasCursor = false;
    final socket = ch.socket;
    await _closePty(ptyId, matching: socket, removeState: false);
    if (!_streamingPtys.contains(ptyId) || _ptys[ptyId] == null) return;
    try {
      await _openPty(ptyId);
    } catch (e, st) {
      Log.w(
        'pty $ptyId: framed decode recovery failed',
        name: 'motif.rpc',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _onPtyDone(String ptyId, WebSocketChannel socket) async {
    final ch = _ptys[ptyId];
    if (ch == null || ch.socket != socket) return;
    await ch.processing;
    if (_ptys[ptyId] != ch || ch.socket != socket) return;
    final closeCode = socket.closeCode;
    final cursorUnusable = closeCode == _kCursorTruncated;
    Log.i(
      'ws done pty=$ptyId closeCode=$closeCode cursor=${ch.cursor} '
      'cursorUnusable=$cursorUnusable streaming=${_streamingPtys.contains(ptyId)}',
      name: 'motif.rpc',
    );
    await _closePty(ptyId, matching: socket, removeState: false);
    if (cursorUnusable &&
        _streamingPtys.contains(ptyId) &&
        _ptys[ptyId] != null) {
      _ptys[ptyId]!
        ..cursor = 0
        ..hasCursor = false;
      try {
        await _openPty(ptyId);
      } catch (e, st) {
        // Best-effort tail reconnect; log rather than swallow.
        Log.w(
          'pty $ptyId: tail reconnect failed',
          name: 'motif.rpc',
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  /// Run a /pty byte chunk through the per-PTY shell parser, then synthesize
  /// `pty.output` + shell events. The wire protocol uses `data_b64`, but local
  /// synthesized events can keep raw bytes to avoid a hot-path base64 roundtrip.
  void _emitProcessedPtyFrame(String ptyId, ProcessedPtyFrame result) {
    if (result.passthrough.isNotEmpty) {
      _emit(
        MotifEvent('pty.output', {
          'pty_id': ptyId,
          'data_bytes': result.passthrough,
          'block_id': result.blockId,
          'scope': result.scope.wire,
          'seq': 0,
        }),
      );
    }
    for (final ev in result.events) {
      final (method, params) = _shellEventFrame(ptyId, ev);
      _emit(MotifEvent(method, params));
    }
  }

  (String, Map<String, Object?>) _shellEventFrame(String ptyId, ShellEvent ev) {
    switch (ev) {
      case ShellBootstrapped(:final shell):
        return (
          'pty.shell_bootstrapped',
          {'pty_id': ptyId, 'shell': shell, 'seq': 0},
        );
      case ShellPromptStarted(:final blockId):
        return (
          'pty.prompt_started',
          {'pty_id': ptyId, 'block_id': blockId, 'seq': 0},
        );
      case ShellPromptEnded(:final blockId):
        return (
          'pty.prompt_ended',
          {'pty_id': ptyId, 'block_id': blockId, 'seq': 0},
        );
      case ShellCommandStarted(
        :final blockId,
        :final text,
        :final cwd,
        :final startedAt,
      ):
        return (
          'pty.command_started',
          {
            'pty_id': ptyId,
            'block_id': blockId,
            'text': text,
            'cwd': cwd,
            'started_at': startedAt,
            'seq': 0,
          },
        );
      case ShellCommandFinished(
        :final blockId,
        :final exitCode,
        :final finishedAt,
      ):
        return (
          'pty.command_finished',
          {
            'pty_id': ptyId,
            'block_id': blockId,
            'exit_code': ?exitCode,
            'finished_at': finishedAt,
            'seq': 0,
          },
        );
      case ShellContextEvent(:final ctx):
        return ('pty.shell_context', {'pty_id': ptyId, 'ctx': ctx, 'seq': 0});
      case ShellCwdChanged(:final cwd):
        return ('pty.cwd_changed', {'pty_id': ptyId, 'cwd': cwd, 'seq': 0});
    }
  }

  /// Write raw PTY input (stdin) over the PTY's WS as a binary frame.
  Future<void> writePty(String ptyId, List<int> data) async {
    var socket = _ptys[ptyId]?.socket;
    if (socket == null) {
      try {
        await activatePty(ptyId);
        socket = _ptys[ptyId]?.socket;
      } catch (e, st) {
        Log.w(
          'pty $ptyId: writePty failed to (re)open socket',
          name: 'motif.rpc',
          error: e,
          stackTrace: st,
        );
        return;
      }
    }
    if (socket == null) return;
    socket.sink.add(Uint8List.fromList(data));
  }

  Future<void> _closePty(
    String ptyId, {
    WebSocketChannel? matching,
    required bool removeState,
    bool removeProcessorState = true,
  }) async {
    final ch = _ptys[ptyId];
    if (ch == null) return;
    Log.i(
      'close pty=$ptyId removeState=$removeState matching=${matching != null} '
      'hasSocket=${ch.socket != null} gen=${ch.generation}',
      name: 'motif.rpc',
    );
    if (matching != null && ch.socket != matching) return;
    _completePtyReplay(ch);
    ch.generation++;
    ch.opening = null;
    final sub = ch.sub;
    ch.sub = null;
    final socket = ch.socket;
    ch.socket = null;
    if (removeState) {
      _ptys.remove(ptyId);
    } else {
      _ptys[ptyId] = ch;
    }
    await Future.wait<void>([
      if (sub != null)
        _settleStreamCleanup(sub.cancel(), 'pty $ptyId subscription'),
      if (socket != null)
        _settleStreamCleanup(socket.sink.close(1000), 'pty $ptyId socket'),
    ]);
    if (removeState && removeProcessorState) {
      final processor = _ptyProcessor;
      if (processor != null) {
        unawaited(
          processor.then((p) => p.removePty(ptyId)).catchError((Object _) {}),
        );
      }
    }
  }

  bool _isCurrentPtySocket(
    String ptyId,
    _PtyChannel channel,
    WebSocketChannel socket,
    int generation,
  ) =>
      identical(_ptys[ptyId], channel) &&
      identical(channel.socket, socket) &&
      channel.generation == generation;

  Future<PtyFrameProcessor> _frameProcessor() =>
      _ptyProcessor ??= PtyFrameProcessor.spawn();

  Future<void> _resetPtyProcessor() async {
    final processor = _ptyProcessor;
    _ptyProcessor = null;
    if (processor == null) return;
    try {
      await (await processor).dispose();
    } catch (_) {
      // A failed/spawn-racing worker has no UI-visible state to preserve.
    }
  }

  Future<void> _closeSessionStreams() async {
    _ptyStreamGeneration++;
    _desiredStreamingPtys = {};
    _streamingPtys.clear();
    _activePtyId = null;
    _ptyStreamSync = null;

    final eventSub = _eventsSub;
    final eventSocket = _eventsSocket;
    _eventsSub = null;
    _eventsSocket = null;
    final ptyIds = _ptys.keys.toList();

    await Future.wait<void>([
      if (eventSub != null)
        _settleStreamCleanup(eventSub.cancel(), 'events subscription'),
      if (eventSocket != null)
        _settleStreamCleanup(eventSocket.sink.close(1000), 'events socket'),
      for (final id in ptyIds)
        _closePty(id, removeState: true, removeProcessorState: false),
    ]);
    _ptys.clear();
  }

  Future<void> _settleStreamCleanup(
    Future<void> operation,
    String description,
  ) async {
    try {
      await operation;
    } catch (e, st) {
      // The local channel is already invalidated. A broken old socket must not
      // prevent a replacement session from attaching on the live transport.
      Log.w(
        '$description cleanup failed',
        name: 'motif.rpc',
        error: e,
        stackTrace: st,
      );
    }
  }

  static _PtyMeta? _parsePtyMeta(String s) {
    try {
      final obj = jsonDecode(s);
      if (obj is Map &&
          obj['since'] is num &&
          obj['pty_frame'] == 'v1' &&
          obj['pty_compress'] == 'zlib' &&
          obj['replay_bytes'] is num) {
        return _PtyMeta(
          since: (obj['since'] as num).toInt(),
          replayBytes: (obj['replay_bytes'] as num).toInt(),
        );
      }
    } catch (_) {}
    return null;
  }

  static void _completePtyReplay(_PtyChannel channel) {
    final completer = channel.replayComplete;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  static bool _sameStringSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
