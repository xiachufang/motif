import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/update/desktop_update_download.dart';
import 'package:motif/motif/update/desktop_update_service.dart';

void main() {
  test('downloads, verifies, opens, and reuses the platform asset', () async {
    final directory = await Directory.systemTemp.createTemp(
      'motif-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bytes = utf8.encode('verified Motif update');
    var requests = 0;
    final opened = <String>[];
    final progress = <DesktopUpdateDownloadProgress>[];
    final update = _update(bytes);
    final downloader = DesktopUpdateDownloader(
      client: MockClient((request) async {
        requests++;
        expect(request.url, update.downloadUrl);
        expect(request.headers['accept'], 'application/octet-stream');
        return http.Response.bytes(bytes, HttpStatus.ok);
      }),
      downloadDirectoryPath: () async => directory.path,
      openFile: (path) async {
        opened.add(path);
        return true;
      },
    );

    final first = await downloader.downloadAndOpen(
      update,
      onProgress: progress.add,
    );
    final second = await downloader.downloadAndOpen(update);

    expect(first.reused, isFalse);
    expect(second.reused, isTrue);
    expect(requests, 1);
    expect(opened, [first.path, first.path]);
    expect(await File(first.path).readAsBytes(), bytes);
    expect(progress.last.receivedBytes, bytes.length);
    expect(progress.last.fraction, 1);
  });

  test('does not open an update that fails checksum verification', () async {
    final directory = await Directory.systemTemp.createTemp(
      'motif-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bytes = utf8.encode('tampered update');
    var opened = false;
    final update = _update(
      bytes,
      checksum:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    final downloader = DesktopUpdateDownloader(
      client: MockClient(
        (_) async => http.Response.bytes(bytes, HttpStatus.ok),
      ),
      downloadDirectoryPath: () async => directory.path,
      openFile: (_) async {
        opened = true;
        return true;
      },
    );

    await expectLater(
      downloader.downloadAndOpen(update),
      throwsA(isA<DesktopUpdateDownloadException>()),
    );

    expect(opened, isFalse);
    expect(await directory.list().toList(), isEmpty);
  });
}

DesktopUpdate _update(List<int> bytes, {String? checksum}) {
  const fileName = 'Motif-flutter-1.2.3-4-linux-x86_64.tar.gz';
  return DesktopUpdate(
    version: '1.2.3',
    releaseUrl: Uri.parse(
      'https://github.com/xiachufang/motif/releases/tag/v1.2.3',
    ),
    downloadUrl: Uri.parse(
      'https://github.com/xiachufang/motif/releases/download/v1.2.3/$fileName',
    ),
    fileName: fileName,
    sha256: checksum ?? sha256.convert(bytes).toString(),
    size: bytes.length,
    title: 'v1.2.3',
  );
}
