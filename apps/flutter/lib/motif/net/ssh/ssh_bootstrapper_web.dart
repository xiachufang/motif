/// Web stub for SSH remote motifd bootstrapping.
library;

import '../../models/settings.dart';

class SshBootstrapper {
  SshBootstrapper({required this.server});

  final MotifServer server;

  Future<void> ensureMotifd() async =>
      throw UnsupportedError('SSH transport is not available on web');
}
