import 'package:http/http.dart' as http;

import 'desktop_update_service.dart';

class DesktopUpdateDownloadProgress {
  const DesktopUpdateDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int totalBytes;

  double get fraction => totalBytes <= 0 ? 0 : receivedBytes / totalBytes;
}

class DesktopUpdateDownloadResult {
  const DesktopUpdateDownloadResult({required this.path, required this.reused});

  final String path;
  final bool reused;
}

abstract interface class DesktopUpdateDownloadController {
  Future<DesktopUpdateDownloadResult> downloadAndOpen(
    DesktopUpdate update, {
    void Function(DesktopUpdateDownloadProgress progress)? onProgress,
  });
}

typedef UpdateDownloadDirectoryProvider = Future<String> Function();
typedef UpdateFileOpener = Future<bool> Function(String path);

class DesktopUpdateDownloadException implements Exception {
  const DesktopUpdateDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DesktopUpdateDownloader implements DesktopUpdateDownloadController {
  DesktopUpdateDownloader({
    http.Client? client,
    UpdateDownloadDirectoryProvider? downloadDirectoryPath,
    UpdateFileOpener? openFile,
  });

  @override
  Future<DesktopUpdateDownloadResult> downloadAndOpen(
    DesktopUpdate update, {
    void Function(DesktopUpdateDownloadProgress progress)? onProgress,
  }) {
    throw UnsupportedError('Desktop update downloads are unavailable');
  }
}
