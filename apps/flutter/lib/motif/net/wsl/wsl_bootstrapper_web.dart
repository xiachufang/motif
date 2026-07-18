/// Web stub for WSL motifd bootstrapping.
library;

import '../../models/settings.dart';

class WslBootstrapper {
  WslBootstrapper({required this.server});

  final MotifServer server;

  Future<void> ensureMotifd() async =>
      throw UnsupportedError('WSL transport is available only on Windows');
}

class WslBootstrapException implements Exception {
  const WslBootstrapException({required this.stage, required this.message});

  final String stage;
  final String message;

  @override
  String toString() => message;
}
