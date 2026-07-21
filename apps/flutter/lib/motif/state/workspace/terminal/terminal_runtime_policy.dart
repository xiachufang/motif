import 'dart:async';

import '../../../log/log.dart';

abstract interface class TerminalRuntimeHost {
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
abstract interface class TerminalRuntimePolicy {
  void onSessionAttached(TerminalRuntimeHost client);
  void onPtySubscriptionsChanged(TerminalRuntimeHost client);
  void onActiveViewChanged(TerminalRuntimeHost client);
  Future<void> onTerminalSurfaceReady(TerminalRuntimeHost client, String ptyId);
  Future<void> onTerminalSurfaceDisposed(
    TerminalRuntimeHost client,
    String ptyId,
  );
}

class MobileTerminalRuntimePolicy implements TerminalRuntimePolicy {
  const MobileTerminalRuntimePolicy();

  @override
  void onSessionAttached(TerminalRuntimeHost client) {
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
  void onPtySubscriptionsChanged(TerminalRuntimeHost client) {}

  @override
  void onActiveViewChanged(TerminalRuntimeHost client) {}

  @override
  Future<void> onTerminalSurfaceReady(
    TerminalRuntimeHost client,
    String ptyId,
  ) {
    return client.ensurePtyStream(ptyId);
  }

  @override
  Future<void> onTerminalSurfaceDisposed(
    TerminalRuntimeHost client,
    String ptyId,
  ) {
    return client.closePtyStream(ptyId);
  }
}

class DesktopTerminalRuntimePolicy implements TerminalRuntimePolicy {
  const DesktopTerminalRuntimePolicy({
    this.backgroundRestoreDelay = const Duration(milliseconds: 32),
  });

  final Duration backgroundRestoreDelay;

  @override
  void onSessionAttached(TerminalRuntimeHost client) {
    unawaited(
      _restoreLiveTabPtys(client).catchError((Object e, StackTrace st) {
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
  void onPtySubscriptionsChanged(TerminalRuntimeHost client) {
    // Production controllers route this through TerminalStreamRuntimeController,
    // which invalidates an in-flight staged restore before synchronizing.
    _syncLiveTabPtys(client);
  }

  @override
  void onActiveViewChanged(TerminalRuntimeHost client) {}

  @override
  Future<void> onTerminalSurfaceReady(
    TerminalRuntimeHost client,
    String ptyId,
  ) => Future<void>.value();

  @override
  Future<void> onTerminalSurfaceDisposed(
    TerminalRuntimeHost client,
    String ptyId,
  ) => Future<void>.value();

  void _syncLiveTabPtys(TerminalRuntimeHost client) {
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

  Future<void> _restoreLiveTabPtys(TerminalRuntimeHost client) async {
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
    }

    for (final ptyId in initial) {
      if (restored.contains(ptyId)) continue;
      await Future<void>.delayed(backgroundRestoreDelay);
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
