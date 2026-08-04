/// Web stub for SSH remote motifd bootstrapping.
library;

import '../../models/settings.dart';

class SshBootstrapper {
  SshBootstrapper({required this.server});

  final MotifServer server;

  Future<void> ensureMotifd() async =>
      throw UnsupportedError('SSH transport is not available on web');

  Future<SshMotifdVersionInfo> checkForUpdate() async =>
      throw UnsupportedError('SSH transport is not available on web');

  Future<void> upgradeMotifd() async =>
      throw UnsupportedError('SSH transport is not available on web');
}

class SshMotifdVersionInfo {
  const SshMotifdVersionInfo({
    required this.serverVersion,
    required this.localVersion,
    required this.availableVersion,
    required this.updateAvailable,
  });

  final String? serverVersion;
  final String localVersion;
  final String availableVersion;
  final bool updateAvailable;
}

class SshBootstrapException implements Exception {
  const SshBootstrapException({
    required this.stage,
    required this.message,
    this.cause,
    this.exitCode,
    this.exitSignal,
    this.stdout,
    this.stderr,
  });

  final String stage;
  final String message;
  final Object? cause;
  final int? exitCode;
  final String? exitSignal;
  final String? stdout;
  final String? stderr;

  @override
  String toString() => message;
}
