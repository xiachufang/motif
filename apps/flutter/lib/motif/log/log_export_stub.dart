library;

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

Future<LogExportResult> exportLogFiles({LogConfig config = const LogConfig()}) {
  throw UnsupportedError('Log export is not available on this platform.');
}
