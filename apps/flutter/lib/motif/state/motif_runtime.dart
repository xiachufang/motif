import 'dart:async';

import '../log/log.dart';

abstract interface class MotifRuntimeClient {
  String? get activePtyId;
  Set<String> get liveTabPtyIds;
  Future<void> ensurePtyStream(String ptyId);
  Future<void> closePtyStream(String ptyId);
  Future<void> syncPtyStreams(Set<String> ptyIds);
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
  void onSessionAttached(MotifRuntimeClient client) {}

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
  const DesktopMotifClientRuntime();

  @override
  void onSessionAttached(MotifRuntimeClient client) => _syncLiveTabPtys(client);

  @override
  void onPtySubscriptionsChanged(MotifRuntimeClient client) =>
      _syncLiveTabPtys(client);

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
}
