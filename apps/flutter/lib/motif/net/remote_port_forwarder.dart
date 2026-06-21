/// Local loopback forwarder for remote services exposed by motifd `/tcp`.
///
/// Native platforms bind `127.0.0.1:<local>` and tunnel each incoming TCP
/// connection over the currently resolved Motif transport. Web has no raw TCP
/// listener, so the conditional stub reports the feature as unavailable.
library;

export 'remote_port_forwarder_io.dart'
    if (dart.library.js_interop) 'remote_port_forwarder_web.dart';
