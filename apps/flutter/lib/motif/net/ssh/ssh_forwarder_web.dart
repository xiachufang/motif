/// Web stub for [SshForwarder]. Browsers do not expose raw TCP sockets, so SSH
/// tunneling needs a separate browser-compatible gateway and is unavailable in
/// the built-in transport.
library;

import '../../models/settings.dart';
import 'ssh_forwarder_handle.dart';

class SshForwarder implements SshForwarderHandle {
  SshForwarder({
    required this.sshHost,
    required this.sshPort,
    required this.username,
    required this.authMethod,
    required this.password,
    required this.privateKey,
    required this.privateKeyPassphrase,
    required this.remoteHost,
    required this.remotePort,
    this.connectTimeout = const Duration(seconds: 15),
  });

  final String sshHost;
  final int sshPort;
  final String username;
  final SshAuthMethod authMethod;
  final String password;
  final String privateKey;
  final String privateKeyPassphrase;
  final String remoteHost;
  final int remotePort;
  final Duration connectTimeout;

  @override
  bool get isRunning => false;

  @override
  int get port =>
      throw UnsupportedError('SSH transport is not available on web');

  @override
  bool matches(SshForwarderHandle other) => false;

  @override
  Future<int> start() async =>
      throw UnsupportedError('SSH transport is not available on web');

  @override
  Future<void> stop() async {}
}
