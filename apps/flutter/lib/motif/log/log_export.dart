/// Log export helpers. Native targets merge the rotating log files into one
/// text artifact; web has no file sink, so it reports unsupported.
library;

export 'log_export_io.dart' if (dart.library.js_interop) 'log_export_stub.dart';
