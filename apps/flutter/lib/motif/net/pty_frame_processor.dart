/// Background processing for PTY WebSocket frames.
///
/// Native builds use a persistent isolate so zlib inflation and shell marker
/// scanning never occupy Flutter's UI isolate. Web builds use the same API with
/// an in-isolate fallback because browser Dart has no native isolates.
library;

export 'pty_frame_processor_types.dart';
export 'pty_frame_processor_stub.dart'
    if (dart.library.io) 'pty_frame_processor_io.dart';
