/// Web stub for [RzvForwarder]. The rendezvous transport relies on raw TCP
/// sockets (`dart:io`), unavailable in the browser, so every operation that
/// would touch the network throws `UnsupportedError`. The API mirrors
/// `rzv_forwarder_io.dart` so the transport resolver compiles on web.
library;

import 'dart:typed_data';

class RzvForwarder {
  RzvForwarder({
    required this.relayHost,
    required this.relayPort,
    required Uint8List token,
    this.pairTimeout = const Duration(seconds: 30),
    this.dialTimeout = const Duration(seconds: 10),
  }) : token = Uint8List.fromList(token);

  final String relayHost;
  final int relayPort;
  final Uint8List token;
  final Duration pairTimeout;
  final Duration dialTimeout;

  bool get isRunning => false;

  int get port =>
      throw UnsupportedError('rendezvous transport is not available on web');

  Future<int> start() async =>
      throw UnsupportedError('rendezvous transport is not available on web');

  Future<void> stop() async {}
}
