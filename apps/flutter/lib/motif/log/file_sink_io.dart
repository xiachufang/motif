/// Native rotating file [LogSink]. Appends UTF-8 lines to a log file under the
/// app support directory and rotates by size, keeping a bounded set of backups.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'log_sink.dart';

Future<String?> resolveLogFilePath(LogConfig config) async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}/Motif/logs/${config.fileName}';
}

/// Open the file sink for [config]. Returns null if a writable log directory
/// can't be resolved (the app then logs to console only). Never throws — a
/// broken log file must not take the app down.
Future<LogSink?> openFileLogSink(LogConfig config) async {
  try {
    final path = await resolveLogFilePath(config);
    if (path == null) return null;
    final base = File(path);
    final dir = base.parent;
    await dir.create(recursive: true);
    return _RotatingFileSink(base, config.maxBytes, config.maxBackups);
  } catch (e, st) {
    // No file logging available; surface it on console rather than swallow.
    stderr.writeln('Log: file sink unavailable: $e\n$st');
    return null;
  }
}

class _RotatingFileSink implements LogSink {
  final File _base;
  final int _maxBytes;
  final int _maxBackups;

  IOSink _out;
  int _size;

  /// Serializes appends and rotations so records never interleave and a
  /// rotation can't race a concurrent write.
  Future<void> _tail = Future<void>.value();

  _RotatingFileSink._(
    this._base,
    this._maxBytes,
    this._maxBackups,
    this._out,
    this._size,
  );

  factory _RotatingFileSink(File base, int maxBytes, int maxBackups) {
    final size = base.existsSync() ? base.lengthSync() : 0;
    final out = base.openWrite(mode: FileMode.append);
    return _RotatingFileSink._(base, maxBytes, maxBackups, out, size);
  }

  @override
  void write(LogRecord record) {
    final bytes = utf8.encode(record.format());
    _tail = _tail.then((_) => _append(bytes)).catchError((
      Object e,
      StackTrace st,
    ) {
      stderr.writeln('Log: write failed: $e\n$st');
    });
  }

  Future<void> _append(List<int> bytes) async {
    if (_size > 0 && _size + bytes.length > _maxBytes) {
      await _rotate();
    }
    _out.add(bytes);
    _size += bytes.length;
  }

  /// Close the active file, shift `name.(n)` → `name.(n+1)` dropping the oldest,
  /// move the active file to `name.1`, then reopen a fresh active file.
  Future<void> _rotate() async {
    await _out.flush();
    await _out.close();

    final path = _base.path;
    final oldest = File('$path.$_maxBackups');
    if (oldest.existsSync()) await oldest.delete();
    for (var i = _maxBackups - 1; i >= 1; i--) {
      final f = File('$path.$i');
      if (f.existsSync()) await f.rename('$path.${i + 1}');
    }
    if (_base.existsSync()) await _base.rename('$path.1');

    _out = _base.openWrite(mode: FileMode.write);
    _size = 0;
  }

  @override
  Future<void> flush() async {
    await _tail;
    await _out.flush();
  }

  @override
  Future<void> close() async {
    await _tail;
    await _out.flush();
    await _out.close();
  }
}
