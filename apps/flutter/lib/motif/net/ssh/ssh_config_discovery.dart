/// Conditional facade for local SSH config/key discovery.
library;

export 'ssh_config_discovery_web.dart'
    if (dart.library.io) 'ssh_config_discovery_io.dart';
