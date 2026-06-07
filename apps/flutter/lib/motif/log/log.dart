/// App-wide logger that fans out to the console and, on native platforms, a
/// rotating file. Use the static helpers anywhere:
///
/// ```dart
/// Log.i('connected', name: 'motif.rpc');
/// Log.e('open failed', name: 'motif.rpc', error: e, stackTrace: st);
/// ```
///
/// Console output goes through `dart:developer` (so it's namespaced and shows in
/// DevTools); file output is enabled by calling [Log.init] once at startup. Logs
/// below [minLevel] are dropped before any work is done.
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'file_sink.dart';
import 'log_sink.dart';

export 'log_sink.dart' show LogLevel, LogConfig, LogRecord;

abstract final class Log {
  /// Records below this level are ignored. Debug build → everything; release →
  /// info and up. Assignable to override at runtime.
  static LogLevel minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;

  static LogSink? _file;

  /// Set up the file sink. Safe to call multiple times (later calls replace the
  /// sink); a no-op on web. Console logging works even without calling this.
  static Future<void> init({LogConfig config = const LogConfig()}) async {
    final old = _file;
    final path = await resolveLogFilePath(config);
    _file = await openFileLogSink(config);
    await old?.close();
    if (_file == null) {
      i('File logging unavailable', name: 'motif.log');
    } else {
      i('Log file: $path', name: 'motif.log');
    }
  }

  static void d(
    String message, {
    String name = 'motif',
    Object? error,
    StackTrace? stackTrace,
  }) => _emit(LogLevel.debug, message, name, error, stackTrace);

  static void i(
    String message, {
    String name = 'motif',
    Object? error,
    StackTrace? stackTrace,
  }) => _emit(LogLevel.info, message, name, error, stackTrace);

  static void w(
    String message, {
    String name = 'motif',
    Object? error,
    StackTrace? stackTrace,
  }) => _emit(LogLevel.warn, message, name, error, stackTrace);

  static void e(
    String message, {
    String name = 'motif',
    Object? error,
    StackTrace? stackTrace,
  }) => _emit(LogLevel.error, message, name, error, stackTrace);

  static void _emit(
    LogLevel level,
    String message,
    String name,
    Object? error,
    StackTrace? stackTrace,
  ) {
    if (level.index < minLevel.index) return;
    final record = LogRecord(
      time: DateTime.now(),
      level: level,
      name: name,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    developer.log(
      message,
      time: record.time,
      level: level.devLevel,
      name: name,
      error: error,
      stackTrace: stackTrace,
    );
    _file?.write(record);
  }

  /// Flush buffered file writes to disk (e.g. before exit or when backgrounded).
  static Future<void> flush() => _file?.flush() ?? Future<void>.value();

  /// Close the file sink and release it. Console logging still works after.
  static Future<void> close() async {
    final f = _file;
    _file = null;
    await f?.close();
  }
}
