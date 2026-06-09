/// Web-conditional builder for the file [LogSink]. Native builds get a real
/// rotating file sink (`dart:io` + path_provider); web has no writable file
/// system, so it gets a stub that returns null. This keeps `dart:io` out of the
/// web compile, mirroring `platform/platform_factory.dart`.
library;

export 'file_sink_io.dart' if (dart.library.js_interop) 'file_sink_stub.dart';
