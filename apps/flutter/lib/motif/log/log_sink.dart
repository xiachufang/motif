/// Shared logging types: severity levels, a single log record, the file-sink
/// configuration, and the sink interface. Kept dependency-free (no `dart:io`)
/// so it compiles on every target, including web.
library;

/// Severity, ordered low → high. `index` doubles as the comparison key.
enum LogLevel {
  debug('D', 500),
  info('I', 800),
  warn('W', 900),
  error('E', 1000);

  const LogLevel(this.tag, this.devLevel);

  /// Single-letter tag used in the file line.
  final String tag;

  /// `dart:developer` level, so DevTools/console color these correctly.
  final int devLevel;
}

/// One log entry. Immutable; formatted lazily by sinks that need text.
class LogRecord {
  final DateTime time;
  final LogLevel level;
  final String name;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogRecord({
    required this.time,
    required this.level,
    required this.name,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// `2026-06-02T12:34:56.789 [I] motif.rpc: message`, with the error and stack
  /// trace appended on indented continuation lines. Always ends with a newline.
  String format() {
    final ts = time.toIso8601String();
    final buf = StringBuffer('$ts [${level.tag}] $name: $message\n');
    if (error != null) buf.write('  error: $error\n');
    if (stackTrace != null) {
      for (final line in stackTrace.toString().trimRight().split('\n')) {
        buf.write('  $line\n');
      }
    }
    return buf.toString();
  }
}

/// Tunables for the rotating file sink. Defaults: 5 MiB per file, 3 backups
/// (so at most ~20 MiB of logs on disk).
class LogConfig {
  /// Base log file name (backups append `.1`, `.2`, …).
  final String fileName;

  /// Rotate once the active file would exceed this many bytes.
  final int maxBytes;

  /// How many rotated files to keep besides the active one.
  final int maxBackups;

  const LogConfig({
    this.fileName = 'motif.log',
    this.maxBytes = 5 * 1024 * 1024,
    this.maxBackups = 3,
  });
}

/// A destination for log records. Implementations must be safe to call from the
/// app's main isolate and serialize their own writes.
abstract interface class LogSink {
  void write(LogRecord record);

  /// Drain any buffered writes to the underlying medium.
  Future<void> flush();

  /// Flush and release resources. The sink must not be used afterwards.
  Future<void> close();
}
