import '../state/server/server_connection_pool.dart';
import 'remote_port_forwarder.dart';
import 'rpc_session_transport.dart';
import 'web_link.dart';

/// Uses the same authenticated route (SSH/Tailscale/pinning included) as RPC.
Future<WebLinkProxy> openServerWebLinkProxy(
  ServerConnectionPool pool,
  Uri url,
) async {
  final handle = pool.acquire(
    ownerId: 'web-link:${DateTime.now().microsecondsSinceEpoch}',
    ownerKind: ConnectionOwnerKind.remotePort,
  );
  final rpc = RpcSessionTransport(handle);
  try {
    await handle.ensureReady();
    final forwarder = await RemotePortForwarder.start(
      rpc: rpc,
      remoteHost: url.host.replaceAll('[', '').replaceAll(']', ''),
      remotePort: url.port,
      localScheme: url.scheme,
    );
    var closed = false;
    return WebLinkProxy(
      url: proxiedWebLink(url, forwarder.localUrl),
      close: () async {
        if (closed) return;
        closed = true;
        try {
          await forwarder.stop();
        } finally {
          await rpc.close();
        }
      },
    );
  } catch (_) {
    await rpc.close();
    rethrow;
  }
}
