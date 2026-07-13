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
      client: MockClient((request) async {
        expect(request.url.toString(), contains('/releases/latest'));
        expect(request.headers['accept'], 'application/vnd.github+json');
        return http.Response(response, 200);
      }),
    );
  }

  test('returns a newer stable GitHub release', () async {
    final result = await checkerFor(
      installedVersion: '1.0.35',
      response: '''
        {
          "tag_name": "v1.0.36",
          "name": "Motif 1.0.36",
          "html_url": "https://github.com/xiachufang/motif/releases/tag/v1.0.36"
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
          "tag_name": "v1.0.35",
          "html_url": "https://github.com/xiachufang/motif/releases/tag/v1.0.35"
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
          "tag_name": "v1.0.36-rc.1",
          "html_url": "https://github.com/xiachufang/motif/releases/tag/v1.0.36-rc.1",
          "prerelease": false
        }
      ''',
    ).check();

    expect(result.status, DesktopUpdateCheckStatus.upToDate);
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
