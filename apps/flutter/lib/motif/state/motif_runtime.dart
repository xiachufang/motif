import 'dart:async';

import '../log/log.dart';

abstract interface class MotifRuntimeClient {
  String? get activePtyId;
  Set<String> get liveTabPtyIds;
  Set<String> get terminalSurfacePtyIds;
  Future<void> ensurePtyStream(String ptyId);
  Future<void> closePtyStream(String ptyId);
  Future<void> syncPtyStreams(Set<String> ptyIds);
  Future<void> waitForPtyReplay(String ptyId);
}

/// Platform runtime semantics for Motif's live session.
///
/// The shared client owns protocol state, but desktop and mobile have different
/// product behavior. Desktop terminals are persistent workspace connections;
/// mobile terminals are lifecycle-sensitive surfaces.
abstract interface class MotifClientRuntime {
  void onSessionAttached(MotifRuntimeClient client);
  void onPtySubscriptionsChanged(MotifRuntimeClient client);
  void onActiveViewChanged(MotifRuntimeClient client);
  Future<void> onTerminalSurfaceReady(MotifRuntimeClient client, String ptyId);
  Future<void> onTerminalSurfaceDisposed(
    MotifRuntimeClient client,
    String ptyId,
  );
}

class MobileMotifClientRuntime implements MotifClientRuntime {
  const MobileMotifClientRuntime();

  @override
  void onSessionAttached(MotifRuntimeClient client) {
    // Mobile normally opens PTY streams when a terminal surface mounts. During
    // reconnect that surface stays mounted, so its ready callback does not run
    // again. Restore exactly the streams that still have live surface sinks.
    final mountedLivePtys = client.terminalSurfacePtyIds.intersection(
      client.liveTabPtyIds,
    );
    for (final ptyId in mountedLivePtys) {
      unawaited(
        client.ensurePtyStream(ptyId).catchError((Object e, StackTrace st) {
          Log.w(
            'mobile mounted pty restore failed pty=$ptyId',
            name: 'motif.runtime',
            error: e,
            stackTrace: st,
          );
        }),
      );
    }
  }

  @override
  void onPtySubscriptionsChanged(MotifRuntimeClient client) {}

  @override
  void onActiveViewChanged(MotifRuntimeClient client) {}

  @override
  Future<void> onTerminalSurfaceReady(MotifRuntimeClient client, String ptyId) {
    return client.ensurePtyStream(ptyId);
  }

  @override
  Future<void> onTerminalSurfaceDisposed(
    MotifRuntimeClient client,
    String ptyId,
  ) {
    return client.closePtyStream(ptyId);
  }
}

class DesktopMotifClientRuntime implements MotifClientRuntime {
  const DesktopMotifClientRuntime({
    this.backgroundRestoreDelay = const Duration(milliseconds: 32),
  });

  final Duration backgroundRestoreDelay;
  static final Expando<int> _restoreGeneration = Expando<int>();
  static int _nextRestoreGeneration = 1;

  @override
  void onSessionAttached(MotifRuntimeClient client) {
    final generation = _nextRestoreGeneration++;
    _restoreGeneration[client] = generation;
    unawaited(
      _restoreLiveTabPtys(client, generation).catchError((
        Object e,
        StackTrace st,
      ) {
        Log.w(
          'desktop staged pty restore failed',
          name: 'motif.runtime',
          error: e,
          stackTrace: st,
        );
      }),
    );
  }

  @override
  void onPtySubscriptionsChanged(MotifRuntimeClient client) {
    // A view was opened/closed while a staged attach restore was in flight.
    // Cancel that snapshot and converge immediately on the new authoritative set.
    _restoreGeneration[client] = _nextRestoreGeneration++;
    _syncLiveTabPtys(client);
  }

  @override
  void onActiveViewChanged(MotifRuntimeClient client) {}

  @override
  Future<void> onTerminalSurfaceReady(
    MotifRuntimeClient client,
    String ptyId,
  ) => Future<void>.value();

  @override
  Future<void> onTerminalSurfaceDisposed(
    MotifRuntimeClient client,
    String ptyId,
  ) => Future<void>.value();

  void _syncLiveTabPtys(MotifRuntimeClient client) {
    final ptyIds = client.liveTabPtyIds;
    Log.i(
      'desktop sync live tab pty streams count=${ptyIds.length}',
      name: 'motif.runtime',
    );
    unawaited(
      client.syncPtyStreams(ptyIds).catchError((Object e, StackTrace st) {
        Log.w(
          'desktop pty stream sync failed',
          name: 'motif.runtime',
          error: e,
          stackTrace: st,
        );
      }),
    );
  }

  Future<void> _restoreLiveTabPtys(
    MotifRuntimeClient client,
    int generation,
  ) async {
    final initial = client.liveTabPtyIds;
    final active = client.activePtyId;
    final restored = <String>{};
    if (active != null && initial.contains(active)) {
      restored.add(active);
      Log.i(
        'desktop restore active pty first pty=$active',
        name: 'motif.runtime',
      );
      await client.syncPtyStreams(restored);
      Log.i(
        'desktop wait active pty replay pty=$active',
        name: 'motif.runtime',
      );
      await client.waitForPtyReplay(active);
      Log.i(
        'desktop active pty replay complete pty=$active',
        name: 'motif.runtime',
      );
      if (_restoreGeneration[client] != generation) return;
    }

    for (final ptyId in initial) {
      if (restored.contains(ptyId)) continue;
      await Future<void>.delayed(backgroundRestoreDelay);
      if (_restoreGeneration[client] != generation) return;
      final live = client.liveTabPtyIds;
      if (!live.contains(ptyId)) continue;
      restored
        ..removeWhere((id) => !live.contains(id))
        ..add(ptyId);
      Log.i(
        'desktop restore background pty=$ptyId restored=${restored.length} '
        'total=${live.length}',
        name: 'motif.runtime',
      );
      await client.syncPtyStreams(restored);
    }
  }
}
