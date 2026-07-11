/// PTY output fan-out: sinks, replay buffers, and throttled late-subscriber
/// delivery. Intentionally not a [ChangeNotifier] — terminal widgets paint from
/// sink callbacks, not Flutter rebuilds.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../log/log.dart';
import '../terminal/terminal_session.dart';

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

/// Owns per-PTY byte sinks and a capped replay ring so late-mounted terminal
/// surfaces can catch up without going through [ChangeNotifier].
class PtyOutputHub {
  static const int maxReplayBytesPerPty = 2 * 1024 * 1024;
  static const int replayDeliverMaxBytesPerTick = 64 * 1024;
  static const Duration replayDeliverInterval = Duration(milliseconds: 16);

  final Map<String, PtyByteSink> _sinks = {};
  final Map<String, List<Uint8List>> _replay = {};
  final Map<String, int> _replayBytes = {};
  final Map<String, _PtyReplayDelivery> _deliveries = {};
  final Map<String, int> _outputChunks = {};
  final Map<String, int> _outputBytes = {};

  /// Optional context for diagnostic logs (active view / active PTY).
  String? Function()? describeActive;

  bool hasSink(String ptyId) => _sinks.containsKey(ptyId);

  int replayBytesFor(String ptyId) => _replayBytes[ptyId] ?? 0;

  /// Subscribe a terminal surface to a PTY's decoded output bytes.
  void registerSink(String ptyId, PtyByteSink sink) {
    final replacing = _sinks.containsKey(ptyId);
    _deliveries.remove(ptyId)?.cancel();
    _sinks[ptyId] = sink;
    final replay = _replay[ptyId];
    final active = describeActive?.call() ?? '';
    Log.i(
      'register sink pty=$ptyId replacing=$replacing '
      'replayChunks=${replay?.length ?? 0} '
      'replayBytes=${_replayBytes[ptyId] ?? 0}'
      '${active.isEmpty ? '' : ' $active'}',
      name: 'motif.pty',
    );
    if (replay == null || replay.isEmpty) return;
    _startReplayDelivery(ptyId, sink, replay);
  }

  void unregisterSink(String ptyId, [PtyByteSink? sink]) {
    if (sink != null && _sinks[ptyId] != sink) {
      Log.i('skip unregister stale sink pty=$ptyId', name: 'motif.pty');
      return;
    }
    final hadSink = _sinks.containsKey(ptyId);
    _sinks.remove(ptyId);
    _deliveries.remove(ptyId)?.cancel();
    Log.i('unregister sink pty=$ptyId hadSink=$hadSink', name: 'motif.pty');
  }

  /// Route a live `pty.output` chunk: remember for replay, then deliver to the
  /// active sink (or queue behind an in-flight replay).
  void handleOutput(String ptyId, Uint8List bytes) {
    _rememberBytes(ptyId, bytes);
    _noteOutput(ptyId, bytes.length);
    final delivery = _deliveries[ptyId];
    if (delivery != null && _sinks[ptyId] == delivery.sink) {
      delivery.chunks.add(bytes);
      _scheduleReplayDelivery(ptyId, delivery);
    } else {
      _sinks[ptyId]?.call(bytes);
    }
  }

  /// Decode `pty.output` event params into bytes, or `null` if absent.
  static Uint8List? bytesFromPtyOutput(Map<String, Object?> params) {
    final raw = params['data_bytes'];
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    final b64 = params['data_b64'];
    if (b64 is String) return base64Decode(b64);
    return null;
  }

  /// Drop replay + in-flight delivery for one PTY (e.g. on `pty.exited`).
  void clearPty(String ptyId) {
    _deliveries.remove(ptyId)?.cancel();
    _replay.remove(ptyId);
    _replayBytes.remove(ptyId);
  }

  /// Drop all sinks, replay, and deliveries (session clear / disconnect).
  void clearAll() {
    _sinks.clear();
    for (final delivery in _deliveries.values) {
      delivery.cancel();
    }
    _deliveries.clear();
    _replay.clear();
    _replayBytes.clear();
  }

  void dispose() => clearAll();

  void _startReplayDelivery(
    String ptyId,
    PtyByteSink sink,
    List<Uint8List> replay,
  ) {
    final delivery = _PtyReplayDelivery(sink)..chunks.addAll(replay);
    _deliveries[ptyId] = delivery;
    Log.i(
      'replay sink pty=$ptyId chunks=${replay.length} '
      'bytes=${_replayBytes[ptyId] ?? 0}',
      name: 'motif.pty',
    );
    _scheduleReplayDelivery(ptyId, delivery);
  }

  void _scheduleReplayDelivery(String ptyId, _PtyReplayDelivery delivery) {
    if (delivery.timer != null) return;
    void deliverBatch() {
      delivery.timer = null;
      if (_deliveries[ptyId] != delivery || _sinks[ptyId] != delivery.sink) {
        return;
      }
      var delivered = 0;
      while (delivery.index < delivery.chunks.length &&
          delivered < replayDeliverMaxBytesPerTick) {
        final chunk = delivery.chunks[delivery.index];
        final remaining = chunk.length - delivery.offset;
        if (remaining <= 0) {
          delivery.index++;
          delivery.offset = 0;
          continue;
        }
        final budget = replayDeliverMaxBytesPerTick - delivered;
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
        delivery.timer = Timer(replayDeliverInterval, deliverBatch);
      } else if (_deliveries[ptyId] == delivery) {
        _deliveries.remove(ptyId);
      }
    }

    delivery.timer = Timer(replayDeliverInterval, deliverBatch);
  }

  void _rememberBytes(String ptyId, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final chunks = _replay.putIfAbsent(ptyId, () => <Uint8List>[]);
    chunks.add(Uint8List.fromList(bytes));
    var total = (_replayBytes[ptyId] ?? 0) + bytes.length;
    while (total > maxReplayBytesPerPty && chunks.isNotEmpty) {
      total -= chunks.removeAt(0).length;
    }
    _replayBytes[ptyId] = total;
  }

  void _noteOutput(String ptyId, int byteCount) {
    final chunks = (_outputChunks[ptyId] ?? 0) + 1;
    final bytes = (_outputBytes[ptyId] ?? 0) + byteCount;
    _outputChunks[ptyId] = chunks;
    _outputBytes[ptyId] = bytes;
    final logAtInfo = chunks <= 3 || chunks == 10;
    final logAtDebug = chunks == 100 || chunks % 1000 == 0;
    if (logAtInfo || logAtDebug) {
      final active = describeActive?.call() ?? '';
      final message =
          'output pty=$ptyId chunk=$chunks bytes=$byteCount totalBytes=$bytes '
          'hasSink=${_sinks.containsKey(ptyId)} '
          'replayBytes=${_replayBytes[ptyId] ?? 0}'
          '${active.isEmpty ? '' : ' $active'}';
      if (logAtInfo) {
        Log.i(message, name: 'motif.pty');
      } else {
        Log.d(message, name: 'motif.pty');
      }
    }
  }
}
