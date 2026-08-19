import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../platform/desktop_launch.dart';
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
    this.client,
    UpdateDownloadDirectoryProvider? downloadDirectoryPath,
    UpdateFileOpener? openFile,
  }) : _downloadDirectoryPath =
           downloadDirectoryPath ?? _defaultDownloadDirectoryPath,
       _openFile = openFile ?? openDesktopFile;

  final http.Client? client;
  final UpdateDownloadDirectoryProvider _downloadDirectoryPath;
  final UpdateFileOpener _openFile;

  @override
  Future<DesktopUpdateDownloadResult> downloadAndOpen(
    DesktopUpdate update, {
    void Function(DesktopUpdateDownloadProgress progress)? onProgress,
  }) async {
    final directory = Directory(await _downloadDirectoryPath());
    await directory.create(recursive: true);

    var destination = File(_join(directory.path, update.fileName));
    if (await destination.exists()) {
      if (await _matchesRelease(destination, update)) {
        onProgress?.call(
          DesktopUpdateDownloadProgress(
            receivedBytes: update.size,
            totalBytes: update.size,
          ),
        );
        await _openVerifiedFile(destination);
        return DesktopUpdateDownloadResult(
          path: destination.path,
          reused: true,
        );
      }
      destination = File(
        _join(
          directory.path,
          '${DateTime.now().microsecondsSinceEpoch}-${update.fileName}',
        ),
      );
    }

    final partial = File('${destination.path}.$pid.part');
    try {
      await _download(update, partial, onProgress: onProgress);
      if (!await _matchesRelease(partial, update)) {
        throw const DesktopUpdateDownloadException(
          'The downloaded update failed verification',
        );
      }
      destination = await partial.rename(destination.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }

    await _openVerifiedFile(destination);
    return DesktopUpdateDownloadResult(path: destination.path, reused: false);
  }

  Future<void> _download(
    DesktopUpdate update,
    File destination, {
    void Function(DesktopUpdateDownloadProgress progress)? onProgress,
  }) async {
    final requestClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final request = http.Request('GET', update.downloadUrl)
        ..headers.addAll(<String, String>{
          'Accept': 'application/octet-stream',
          'User-Agent': 'Motif/${update.version}',
        });
      final response = await requestClient
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        throw DesktopUpdateDownloadException(
          'Update download returned HTTP ${response.statusCode}',
        );
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength != update.size) {
        throw const DesktopUpdateDownloadException(
          'The update download size did not match its metadata',
        );
      }

      var received = 0;
      final output = destination.openWrite(mode: FileMode.writeOnly);
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > update.size) {
            throw const DesktopUpdateDownloadException(
              'The update download exceeded its expected size',
            );
          }
          output.add(chunk);
          onProgress?.call(
            DesktopUpdateDownloadProgress(
              receivedBytes: received,
              totalBytes: update.size,
            ),
          );
        }
      } finally {
        await output.close();
      }
      if (received != update.size) {
        throw const DesktopUpdateDownloadException(
          'The update download was incomplete',
        );
      }
    } finally {
      if (ownsClient) requestClient.close();
    }
  }

  Future<void> _openVerifiedFile(File file) async {
    if (!await _openFile(file.path)) {
      throw DesktopUpdateDownloadException(
        'The update was downloaded but could not be opened: ${file.path}',
      );
    }
  }

  static Future<bool> _matchesRelease(File file, DesktopUpdate update) async {
    if (!await file.exists() || await file.length() != update.size) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == update.sha256;
  }

  static Future<String> _defaultDownloadDirectoryPath() async {
    final candidates = <Future<Directory?> Function()>[
      getDownloadsDirectory,
      () async => getTemporaryDirectory(),
    ];
    for (final candidate in candidates) {
      try {
        final directory = await candidate();
        if (directory != null) return directory.path;
      } catch (_) {
        // Try the app-owned temporary directory if Downloads is unavailable.
      }
    }
    throw const FileSystemException(
      'Unable to find a writable update download directory',
    );
  }

  static String _join(String directory, String fileName) =>
      '$directory${Platform.pathSeparator}$fileName';
}
