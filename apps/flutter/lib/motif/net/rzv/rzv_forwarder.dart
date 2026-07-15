/// Web-conditional façade for the rzv loopback forwarder.
///
/// The WSS forwarder needs a loopback `ServerSocket` to expose its byte stream,
/// which browsers cannot create — so the rendezvous transport is native-only. On web the stub's
/// [RzvForwarder.start] throws `UnsupportedError`; callers (the transport
/// resolver) surface that as a transport failure. See `rzv_forwarder_io.dart`
/// for the real implementation.
library;

export 'rzv_forwarder_io.dart'
    if (dart.library.js_interop) 'rzv_forwarder_web.dart';
