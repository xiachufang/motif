library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'log_sink.dart';

class LogExportResult {
  final String path;
  final int bytes;
  final int sourceCount;

  const LogExportResult({
    required this.path,
    required this.bytes,
    required this.sourceCount,
  });
}

Future<LogExportResult> exportLogFiles({
  LogConfig config = const LogConfig(),
}) async {
  final sourceDir = await _logDirectory();
  final sources = await _logSources(sourceDir, config);
  final exportDir = await _exportDirectory();
  await exportDir.create(recursive: true);

  final output = File('${exportDir.path}/${_exportFileName()}');
  final out = output.openWrite(mode: FileMode.write);
  try {
    if (sources.isEmpty) {
      out.writeln('No Motif log files found.');
    } else {
      for (final source in sources) {
        out.writeln('===== ${_basename(source.path)} =====');
        await out.addStream(source.openRead());
        out.writeln();
      }
    }
  } finally {
    await out.close();
  }

  return LogExportResult(
    path: output.path,
    bytes: await output.length(),
    sourceCount: sources.length,
  );
}

Future<Directory> _logDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/Motif/logs');
}

Future<List<File>> _logSources(Directory dir, LogConfig config) async {
  final files = <File>[];
  final basePath = '${dir.path}/${config.fileName}';
  for (var i = config.maxBackups; i >= 1; i--) {
    final file = File('$basePath.$i');
    if (await file.exists()) files.add(file);
  }
  final active = File(basePath);
  if (await active.exists()) files.add(active);
  return files;
}

Future<Directory> _exportDirectory() async {
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads;
  } catch (_) {}
  return getTemporaryDirectory();
}

String _exportFileName() {
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  return 'motif-logs-$stamp.txt';
}

String _basename(String path) {
  final slash = path.lastIndexOf(Platform.pathSeparator);
  return slash < 0 ? path : path.substring(slash + 1);
}
