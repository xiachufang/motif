/// Web stub: the browser has no writable file system, so there is no file sink.
/// [Log] falls back to console-only output.
library;

import 'log_sink.dart';

Future<String?> resolveLogFilePath(LogConfig config) async => null;

Future<LogSink?> openFileLogSink(LogConfig config) async => null;
