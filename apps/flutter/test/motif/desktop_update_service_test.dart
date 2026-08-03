import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/update/desktop_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  DesktopUpdateChecker checkerFor({
    required String installedVersion,
    required String response,
  }) {
    return DesktopUpdateChecker(
      installedVersion: () async => installedVersion,
      releasePlatform: () => 'linux-x86_64',
      client: MockClient((request) async {
        expect(request.url.toString(), contains('/meta/v1/app/stable.json'));
        expect(request.headers['accept'], 'application/json');
        return http.Response(response, 200);
      }),
    );
  }

  test('returns a newer stable GitHub release', () async {
    final result = await checkerFor(
      installedVersion: '1.0.35',
      response: '''
        {
          "schema": 1,
          "channel": "stable",
          "product": "app",
          "assets": {
            "linux-x86_64": {
              "version": "1.0.36",
              "tag": "v1.0.36",
              "releasePage": "https://github.com/xiachufang/motif/releases/tag/v1.0.36",
              "url": "https://github.com/xiachufang/motif/releases/download/v1.0.36/Motif-linux.tar.gz",
              "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "size": 123
            }
          }
        }
      ''',
    ).check();

    expect(result.status, DesktopUpdateCheckStatus.updateAvailable);
    expect(result.update?.version, '1.0.36');
    expect(
      result.update?.releaseUrl.toString(),
      'https://github.com/xiachufang/motif/releases/tag/v1.0.36',
    );
  });

  test('does not offer the same or an older release', () async {
    final result = await checkerFor(
      installedVersion: '1.0.36',
      response: '''
        {
          "schema": 1,
          "channel": "stable",
          "product": "app",
          "assets": {
            "linux-x86_64": {
              "version": "1.0.35",
              "tag": "v1.0.35",
              "releasePage": "https://github.com/xiachufang/motif/releases/tag/v1.0.35",
              "url": "https://github.com/xiachufang/motif/releases/download/v1.0.35/Motif-linux.tar.gz",
              "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "size": 123
            }
          }
        }
      ''',
    ).check();

    expect(result.status, DesktopUpdateCheckStatus.upToDate);
    expect(result.update, isNull);
  });

  test('does not offer prereleases', () async {
    final result = await checkerFor(
      installedVersion: '1.0.35',
      response: '''
        {
          "schema": 1,
          "channel": "stable",
          "product": "app",
          "assets": {
            "linux-x86_64": {
              "version": "1.0.36-rc.1",
              "tag": "v1.0.36-rc.1",
              "releasePage": "https://github.com/xiachufang/motif/releases/tag/v1.0.36-rc.1",
              "url": "https://github.com/xiachufang/motif/releases/download/v1.0.36-rc.1/Motif-linux.tar.gz",
              "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
              "size": 123
            }
          }
        }
      ''',
    ).check();

    expect(result.status, DesktopUpdateCheckStatus.upToDate);
  });

  test('does not use another platform stable pointer', () async {
    final result = await checkerFor(
      installedVersion: '1.0.35',
      response: '''
        {
          "schema": 1,
          "channel": "stable",
          "product": "app",
          "assets": {
            "macos-arm64": {
              "version": "1.0.99",
              "tag": "v1.0.99",
              "releasePage": "https://github.com/xiachufang/motif/releases/tag/v1.0.99",
              "url": "https://github.com/xiachufang/motif/releases/download/v1.0.99/Motif.dmg",
              "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
              "size": 123
            }
          }
        }
      ''',
    ).check();

    expect(result.status, DesktopUpdateCheckStatus.unavailable);
    expect(result.update, isNull);
  });

  test('allows only one update presentation at a time', () async {
    final service = DesktopUpdateService();
    final update = DesktopUpdate(
      version: '1.0.36',
      releaseUrl: Uri.parse(
        'https://github.com/xiachufang/motif/releases/tag/v1.0.36',
      ),
      title: 'Motif 1.0.36',
    );
    final firstPresentationClosed = Completer<void>();

    final first = service.presentUpdate(
      update,
      () => firstPresentationClosed.future,
    );
    final overlapping = await service.presentUpdate(
      update,
      () async => fail('overlapping presentation should not run'),
    );

    expect(overlapping, isFalse);
    firstPresentationClosed.complete();
    expect(await first, isTrue);

    final later = await service.presentUpdate(update, () async {});
    expect(later, isTrue);
  });

  test('persists a skipped version but allows a newer one', () async {
    SharedPreferences.setMockInitialValues({});
    final service = DesktopUpdateService();
    final skipped = DesktopUpdate(
      version: '1.0.36',
      releaseUrl: Uri.parse(
        'https://github.com/xiachufang/motif/releases/tag/v1.0.36',
      ),
      title: 'Motif 1.0.36',
    );
    final newer = DesktopUpdate(
      version: '1.0.37',
      releaseUrl: Uri.parse(
        'https://github.com/xiachufang/motif/releases/tag/v1.0.37',
      ),
      title: 'Motif 1.0.37',
    );

    await service.skipVersion(skipped);
    expect(await service.isVersionSkipped(skipped), isTrue);
    expect(await service.isVersionSkipped(newer), isFalse);

    final reloaded = DesktopUpdateService();
    expect(await reloaded.isVersionSkipped(skipped), isTrue);
  });
}
