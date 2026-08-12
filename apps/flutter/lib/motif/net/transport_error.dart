/// Cross-platform classification for failures that mean the current network
/// route is no longer usable.
library;

export 'transport_error_io.dart'
    if (dart.library.js_interop) 'transport_error_web.dart';
