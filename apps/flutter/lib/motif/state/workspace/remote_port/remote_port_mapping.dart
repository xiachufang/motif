/// Observable projection of a server-persisted remote endpoint.
///
/// The live forwarder is deliberately not retained here. It is a runtime
/// resource owned by the remote-port controller, while this object is a pure
/// value that can safely live in the ViewModel tree.
final class RemotePortMapping {
  const RemotePortMapping({
    required this.id,
    required this.remoteHost,
    required this.remotePort,
    required this.localScheme,
    required this.createdAt,
    required this.localPort,
    required this.localUrl,
  });

  final String id;
  final String remoteHost;
  final int remotePort;
  final String localScheme;
  final DateTime createdAt;
  final int localPort;
  final Uri localUrl;

  String get remoteEndpoint => '$remoteHost:$remotePort';
  String get displayTitle => '$localScheme://$remoteHost:$remotePort';
}
