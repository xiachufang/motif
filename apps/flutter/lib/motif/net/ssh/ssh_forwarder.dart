/// Conditional facade for the SSH loopback forwarder.
///
/// Native platforms use `dartssh2` over raw TCP sockets. Web has no native TCP,
/// so the stub reports SSH tunneling as unavailable.
library;

export 'ssh_forwarder_io.dart'
    if (dart.library.js_interop) 'ssh_forwarder_web.dart';
