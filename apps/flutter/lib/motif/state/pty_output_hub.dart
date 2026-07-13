/// PTY output fan-out: sinks, replay buffers, and throttled late-subscriber
/// delivery. Intentionally not a [ChangeNotifier] — terminal widgets paint from
/// sink callbacks, not Flutter rebuilds.
library;

import 'dart:async';
import 'dart:collection';
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
  int pendingBytes = 0;
  Timer? timer;

  void add(Uint8List bytes) {
    if (bytes.isEmpty) return;
    chunks.add(bytes);
    pendingBytes += bytes.length;
  }

  void cancel() {
    timer?.cancel();
    timer = null;
  }
}

/// A lazily allocated, bounded byte ring backed by fixed-size segments.
///
/// PTY output commonly arrives as hundreds of tiny terminal-redraw frames. A
/// `List<Uint8List>` makes evicting the oldest frame O(frame count) and retains
/// one Dart object per frame; a busy 2 MB replay window can therefore grow to
/// tens of thousands of entries. This ring copies incoming bytes into at most
/// `capacity / segmentBytes + 1` segments and trims from the head in O(1).
///
/// [snapshotChunks] returns views whose covered bytes are immutable: appends
/// only write after a segment's current `end`, and evicted segments are never
/// reused. An in-flight replay can consequently retain the views safely while
/// the live ring continues advancing, without copying the whole replay window.
class _ReplayByteRing {
  _ReplayByteRing({required this.capacity, required this.segmentBytes})
    : assert(capacity > 0),
      assert(segmentBytes > 0);

  final int capacity;
  final int segmentBytes;
  final ListQueue<_ReplaySegment> _segments = ListQueue<_ReplaySegment>();

  int length = 0;
  bool get isEmpty => length == 0;

  void add(Uint8List bytes) {
    if (bytes.isEmpty) return;

    var offset = 0;
    if (bytes.length >= capacity) {
      // Earlier buffered bytes cannot survive this write. Skip its prefix too,
      // so we allocate/copy exactly the retained tail rather than temporarily
      // materializing an oversized ring.
      clear();
      offset = bytes.length - capacity;
    }

    while (offset < bytes.length) {
      var tail = _segments.isEmpty ? null : _segments.last;
      if (tail == null || tail.remaining == 0) {
        tail = _ReplaySegment(segmentBytes);
        _segments.addLast(tail);
      }
      final available = bytes.length - offset;
      final take = available < tail.remaining ? available : tail.remaining;
      tail.bytes.setRange(tail.end, tail.end + take, bytes, offset);
      tail.end += take;
      length += take;
      offset += take;
    }

    _trimToCapacity();
  }

  List<Uint8List> snapshotChunks() => <Uint8List>[
    for (final segment in _segments)
      if (segment.length > 0)
        Uint8List.sublistView(segment.bytes, segment.start, segment.end),
  ];

  void clear() {
    _segments.clear();
    length = 0;
  }

  void _trimToCapacity() {
    var excess = length - capacity;
    while (excess > 0) {
      final head = _segments.first;
      final drop = excess < head.length ? excess : head.length;
      head.start += drop;
      length -= drop;
      excess -= drop;
      if (head.length == 0) _segments.removeFirst();
    }
  }
}

class _ReplaySegment {
  _ReplaySegment(int size) : bytes = Uint8List(size);

  final Uint8List bytes;
  int start = 0;
  int end = 0;

  int get length => end - start;
  int get remaining => bytes.length - end;
}

/// Owns per-PTY byte sinks and a capped replay ring so late-mounted terminal
/// surfaces can catch up without going through [ChangeNotifier].
class PtyOutputHub {
  PtyOutputHub({
    int replayCapacityBytes = maxReplayBytesPerPty,
    int replayBytesPerTick = replayDeliverMaxBytesPerTick,
    Duration replayInterval = replayDeliverInterval,
    int? maxReplayBacklogBytes,
  }) : assert(replayCapacityBytes > 0),
       assert(replayBytesPerTick > 0),
       assert(
         (maxReplayBacklogBytes ?? replayCapacityBytes * 2) >=
             replayCapacityBytes,
       ),
       _replayCapacityBytes = replayCapacityBytes,
       _replayBytesPerTick = replayBytesPerTick,
       _deliveryInterval = replayInterval,
       _maxReplayBacklogBytes =
           maxReplayBacklogBytes ?? replayCapacityBytes * 2;

  static const int maxReplayBytesPerPty = 2 * 1024 * 1024;
  static const int replayDeliverMaxBytesPerTick = 64 * 1024;
  static const Duration replayDeliverInterval = Duration(milliseconds: 16);

  final int _replayCapacityBytes;
  final int _replayBytesPerTick;
  final Duration _deliveryInterval;
  final int _maxReplayBacklogBytes;

  final Map<String, PtyByteSink> _sinks = {};
  final Map<String, _ReplayByteRing> _replay = {};
  final Map<String, _PtyReplayDelivery> _deliveries = {};
  final Map<String, int> _outputChunks = {};
  final Map<String, int> _outputBytes = {};

  /// Optional context for diagnostic logs (active view / active PTY).
  String? Function()? describeActive;

  /// Called after an in-flight replay backlog hits its hard byte cap. The
  /// owner should cold-reconnect this PTY so the server replaces the skipped
  /// stream with a self-contained VT snapshot.
  void Function(String ptyId, int pendingBytes)? onReplayOverflow;

  bool hasSink(String ptyId) => _sinks.containsKey(ptyId);

  int replayBytesFor(String ptyId) => _replay[ptyId]?.length ?? 0;

  int replayBacklogBytesFor(String ptyId) =>
      _deliveries[ptyId]?.pendingBytes ?? 0;

  /// Subscribe a terminal surface to a PTY's decoded output bytes.
  void registerSink(String ptyId, PtyByteSink sink) {
    final replacing = _sinks.containsKey(ptyId);
    _deliveries.remove(ptyId)?.cancel();
    _sinks[ptyId] = sink;
    final ring = _replay[ptyId];
    final replay = ring?.snapshotChunks();
    final active = describeActive?.call() ?? '';
    Log.i(
      'register sink pty=$ptyId replacing=$replacing '
      'replayChunks=${replay?.length ?? 0} '
      'replayBytes=${ring?.length ?? 0}'
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
      final nextPending = delivery.pendingBytes + bytes.length;
      if (nextPending > _maxReplayBacklogBytes) {
        _deliveries.remove(ptyId)?.cancel();
        _replay.remove(ptyId);
        Log.w(
          'replay backlog overflow pty=$ptyId pending=$nextPending '
          'limit=$_maxReplayBacklogBytes; requesting cold resync',
          name: 'motif.pty',
        );
        onReplayOverflow?.call(ptyId, nextPending);
        return;
      }
      delivery.add(bytes);
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
  }

  /// Drop all sinks, replay, and deliveries (session clear / disconnect).
  void clearAll() {
    _sinks.clear();
    for (final delivery in _deliveries.values) {
      delivery.cancel();
    }
    _deliveries.clear();
    _replay.clear();
  }

  void dispose() => clearAll();

  void _startReplayDelivery(
    String ptyId,
    PtyByteSink sink,
    List<Uint8List> replay,
  ) {
    final delivery = _PtyReplayDelivery(sink);
    for (final bytes in replay) {
      delivery.add(bytes);
    }
    _deliveries[ptyId] = delivery;
    Log.i(
      'replay sink pty=$ptyId chunks=${replay.length} '
      'bytes=${_replay[ptyId]?.length ?? 0}',
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
          delivered < _replayBytesPerTick) {
        final chunk = delivery.chunks[delivery.index];
        final remaining = chunk.length - delivery.offset;
        if (remaining <= 0) {
          delivery.index++;
          delivery.offset = 0;
          continue;
        }
        final budget = _replayBytesPerTick - delivered;
        final take = remaining <= budget ? remaining : budget;
        final start = delivery.offset;
        final end = start + take;
        delivery.sink(Uint8List.sublistView(chunk, start, end));
        delivered += take;
        delivery.pendingBytes -= take;
        delivery.offset = end;
        if (delivery.offset >= chunk.length) {
          // Release evicted ring segments/live frames as soon as their bytes
          // have reached the sink instead of retaining the whole replay until
          // its final timer tick.
          delivery.chunks[delivery.index] = Uint8List(0);
          delivery.index++;
          delivery.offset = 0;
        }
      }
      if (delivery.index < delivery.chunks.length) {
        delivery.timer = Timer(_deliveryInterval, deliverBatch);
      } else if (_deliveries[ptyId] == delivery) {
        _deliveries.remove(ptyId);
      }
    }

    delivery.timer = Timer(_deliveryInterval, deliverBatch);
  }

  void _rememberBytes(String ptyId, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final segmentBytes = _replayBytesPerTick < _replayCapacityBytes
        ? _replayBytesPerTick
        : _replayCapacityBytes;
    final ring = _replay.putIfAbsent(
      ptyId,
      () => _ReplayByteRing(
        capacity: _replayCapacityBytes,
        segmentBytes: segmentBytes,
      ),
    );
    ring.add(bytes);
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
          'replayBytes=${_replay[ptyId]?.length ?? 0}'
          '${active.isEmpty ? '' : ' $active'}';
      if (logAtInfo) {
        Log.i(message, name: 'motif.pty');
      } else {
        Log.d(message, name: 'motif.pty');
      }
    }
  }
}
