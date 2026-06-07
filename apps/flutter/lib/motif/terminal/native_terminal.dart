/// Web-conditional entry to the libghostty-backed terminal.
///
/// The real implementation imports `dart:ffi` (via the `ghostty_*` engine files
/// in this directory), which the web
/// platform can't compile. The conditional export swaps in a stub on web so the
/// app still builds there; `kUseNativeTerminal` is never true on web, so the
/// stub is inert.
library;

export 'native_terminal_io.dart' if (dart.library.html) 'native_terminal_stub.dart';
