/// Web stub for [RzvForwarder]. WSS still needs a local loopback server to
/// expose its byte stream to the existing client stack; browsers cannot create
/// one. Every operation that would touch the network throws. The API mirrors
/// `rzv_forwarder_io.dart` so the transport resolver compiles on web.
library;

import 'dart:typed_data';

class RzvForwarder {
  RzvForwarder({
    required this.relayHost,
    required this.relayPort,
    required Uint8List token,
    this.relayScheme = 'wss',
    this.pairTimeout = const Duration(seconds: 30),
    this.dialTimeout = const Duration(seconds: 10),
  }) : token = Uint8List.fromList(token);

  final String relayHost;
  final int relayPort;
  final String relayScheme;
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
