import '../models/settings.dart';
import '../net/proxy_client.dart';
import '../platform/services.dart';
import 'connection_state.dart';

sealed class TransportResolution {
  const TransportResolution();
}

class TransportReady extends TransportResolution {
  final MotifServer target;
  final ProxySettings proxy;

  const TransportReady({required this.target, required this.proxy});
}

class TransportBlocked extends TransportResolution {
  final ConnectionBlocker blocker;

  const TransportBlocked(this.blocker);
}

class TransportFailed extends TransportResolution {
  final String message;

  const TransportFailed(this.message);
}

class TransportResolver {
  final PlatformServices platform;

  const TransportResolver(this.platform);

  ConnectionBlocker? currentBlocker(MotifServer server) {
    if (server.kind != ServerKind.tailscale) return null;
    final tailscale = platform.tailscale.state;
    if (tailscale.status == TailscaleStatus.running) return null;
    return ConnectionBlocker.tailscale(tailscale);
  }

  Future<TransportResolution> resolve(MotifServer server) async {
    if (server.kind != ServerKind.tailscale) {
      return TransportReady(target: server, proxy: ProxySettings.none);
    }

    final blocker = currentBlocker(server);
    if (blocker != null) return TransportBlocked(blocker);

    var target = server;
    try {
      final resolved = await platform.tailscale.resolveHost(server.host);
      if (resolved.isNotEmpty && resolved != server.host) {
        target = server.copyWith(host: resolved);
      }
    } catch (_) {
      // Preserve the previous behavior: MagicDNS resolution is helpful but not
      // required for a connection attempt when the tailnet backend is up.
    }

    return TransportReady(
      target: target,
      proxy: platform.tailscale.loopbackProxy ?? ProxySettings.none,
    );
  }
}
