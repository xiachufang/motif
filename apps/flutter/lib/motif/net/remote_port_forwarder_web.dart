import 'rpc_client.dart';

class RemotePortForwarder {
  RemotePortForwarder._();

  int get localPort =>
      throw UnsupportedError('remote port forwarding is not available on web');

  Uri get localUrl =>
      throw UnsupportedError('remote port forwarding is not available on web');

  static Future<RemotePortForwarder> start({
    required RpcClient rpc,
    required String sessionId,
    String remoteHost = '127.0.0.1',
    required int remotePort,
    int? localPort,
    String localScheme = 'http',
  }) async {
    throw UnsupportedError('remote port forwarding is not available on web');
  }

  Future<void> stop() async {}
}
