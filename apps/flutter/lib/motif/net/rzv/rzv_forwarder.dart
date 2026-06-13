/// Web-conditional façade for the rzv loopback forwarder.
///
/// The forwarder needs raw TCP sockets (`dart:io`), which the browser doesn't
/// provide — so the rendezvous transport is native-only. On web the stub's
/// [RzvForwarder.start] throws `UnsupportedError`; callers (the transport
/// resolver) surface that as a transport failure. See `rzv_forwarder_io.dart`
/// for the real implementation.
library;

export 'rzv_forwarder_io.dart'
    if (dart.library.js_interop) 'rzv_forwarder_web.dart';
