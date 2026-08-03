/// Lightweight desktop release checking backed by the per-platform stable
/// manifest on GitHub Pages. This deliberately only discovers a new version;
/// it never downloads or changes the installed application.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../log/log.dart';

const _defaultReleaseUrl =
    'https://xiachufang.github.io/motif/meta/v1/app/stable.json';
const _skippedVersionKey = 'motif.update.skippedVersion';

/// A published desktop release that is newer than the running application.
class DesktopUpdate {
  const DesktopUpdate({
    required this.version,
    required this.releaseUrl,
    required this.title,
  });

  final String version;
  final Uri releaseUrl;
  final String title;
}

enum DesktopUpdateCheckStatus { updateAvailable, upToDate, unavailable }

class DesktopUpdateCheckResult {
  const DesktopUpdateCheckResult._(this.status, [this.update]);

  const DesktopUpdateCheckResult.updateAvailable(DesktopUpdate update)
    : this._(DesktopUpdateCheckStatus.updateAvailable, update);

  const DesktopUpdateCheckResult.upToDate()
    : this._(DesktopUpdateCheckStatus.upToDate);

  const DesktopUpdateCheckResult.unavailable()
    : this._(DesktopUpdateCheckStatus.unavailable);

  final DesktopUpdateCheckStatus status;
  final DesktopUpdate? update;
}

typedef InstalledVersionProvider = Future<String> Function();
typedef ReleasePlatformProvider = String? Function();

/// Queries the stable release feed and compares its version with the installed app
/// version. Supplying dependencies makes the network and version logic easy to
/// test without a running desktop shell.
class DesktopUpdateChecker {
  DesktopUpdateChecker({
    this.client,
    InstalledVersionProvider? installedVersion,
    ReleasePlatformProvider? releasePlatform,
    Uri? releaseUrl,
  }) : _installedVersion = installedVersion ?? _platformVersion,
       _releasePlatform = releasePlatform ?? _defaultReleasePlatform,
       _releaseUrl = releaseUrl ?? Uri.parse(_defaultReleaseUrl);

  final http.Client? client;
  final InstalledVersionProvider _installedVersion;
  final ReleasePlatformProvider _releasePlatform;
  final Uri _releaseUrl;

  static Future<String> _platformVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  static String? _defaultReleasePlatform() => switch (defaultTargetPlatform) {
    TargetPlatform.linux => 'linux-x86_64',
    TargetPlatform.macOS => 'macos-arm64',
    TargetPlatform.windows => 'windows-x86_64',
    _ => null,
  };

  Future<DesktopUpdateCheckResult> check() async {
    final requestClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final installed = await _installedVersion();
      final platform = _releasePlatform();
      if (platform == null) {
        return const DesktopUpdateCheckResult.unavailable();
      }
      final response = await requestClient
          .get(
            _releaseUrl,
            headers: <String, String>{
              'Accept': 'application/json',
              'User-Agent': 'Motif/$installed',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        Log.w(
          'Stable app metadata returned HTTP ${response.statusCode}',
          name: 'motif.update',
        );
        return const DesktopUpdateCheckResult.unavailable();
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        Log.w('Stable app metadata was not an object', name: 'motif.update');
        return const DesktopUpdateCheckResult.unavailable();
      }

      final assets = decoded['assets'];
      final asset = assets is Map<String, Object?> ? assets[platform] : null;
      if (decoded['schema'] != 1 ||
          decoded['channel'] != 'stable' ||
          decoded['product'] != 'app' ||
          asset is! Map<String, Object?>) {
        Log.w(
          'Stable app metadata has no valid $platform asset',
          name: 'motif.update',
        );
        return const DesktopUpdateCheckResult.unavailable();
      }

      final version = asset['version'];
      final tag = asset['tag'];
      final releasePage = asset['releasePage'];
      final downloadUrl = asset['url'];
      final checksum = asset['sha256'];
      final size = asset['size'];
      if (version is! String ||
          tag is! String ||
          releasePage is! String ||
          downloadUrl is! String ||
          checksum is! String ||
          size is! int ||
          size <= 0 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
        Log.w(
          'Stable app metadata has an incomplete $platform asset',
          name: 'motif.update',
        );
        return const DesktopUpdateCheckResult.unavailable();
      }
      final installedVersion = _ReleaseVersion.tryParse(installed);
      final latestVersion = _ReleaseVersion.tryParse(version);
      final releaseUri = Uri.tryParse(releasePage);
      final downloadUri = Uri.tryParse(downloadUrl);
      if (installedVersion == null ||
          latestVersion == null ||
          releaseUri == null ||
          releaseUri.scheme != 'https' ||
          releaseUri.host != 'github.com' ||
          downloadUri == null ||
          downloadUri.scheme != 'https' ||
          downloadUri.host != 'github.com') {
        Log.w(
          'Unable to compare or open stable app metadata',
          name: 'motif.update',
        );
        return const DesktopUpdateCheckResult.unavailable();
      }
      // The publisher only advances stable pointers, but reject a malformed
      // suffixed version defensively.
      if (latestVersion.prerelease != null) {
        return const DesktopUpdateCheckResult.upToDate();
      }
      if (latestVersion.compareTo(installedVersion) <= 0) {
        return const DesktopUpdateCheckResult.upToDate();
      }

      return DesktopUpdateCheckResult.updateAvailable(
        DesktopUpdate(
          version: latestVersion.display,
          releaseUrl: releaseUri,
          title: tag,
        ),
      );
    } on TimeoutException catch (error, stackTrace) {
      Log.w(
        'Stable app metadata check timed out',
        name: 'motif.update',
        error: error,
        stackTrace: stackTrace,
      );
      return const DesktopUpdateCheckResult.unavailable();
    } catch (error, stackTrace) {
      Log.w(
        'Stable app metadata check failed',
        name: 'motif.update',
        error: error,
        stackTrace: stackTrace,
      );
      return const DesktopUpdateCheckResult.unavailable();
    } finally {
      if (ownsClient) requestClient.close();
    }
  }
}

/// Owns the startup and periodic checks for one desktop app process.
class DesktopUpdateService {
  DesktopUpdateService({
    DesktopUpdateChecker? checker,
    this.checkInterval = const Duration(hours: 6),
  }) : _checker = checker ?? DesktopUpdateChecker();

  final DesktopUpdateChecker _checker;
  final Duration checkInterval;
  Timer? _timer;
  Future<DesktopUpdateCheckResult>? _inFlight;
  Future<void> Function(DesktopUpdate update)? _onUpdateAvailable;
  String? _notifiedVersion;
  String? _presentingVersion;
  String? _skippedVersion;
  Future<SharedPreferences>? _preferences;
  Future<void>? _loadSkippedVersion;

  /// Starts an immediate check, then repeats it while the app remains open.
  /// A particular version is only presented once per launch.
  void start({
    required Future<void> Function(DesktopUpdate update) onUpdateAvailable,
  }) {
    if (_timer != null) return;
    _onUpdateAvailable = onUpdateAvailable;
    unawaited(_checkAndNotify());
    _timer = Timer.periodic(checkInterval, (_) => unawaited(_checkAndNotify()));
  }

  /// Performs a user-initiated check without automatically showing a prompt.
  Future<DesktopUpdateCheckResult> checkNow() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final check = _checker.check();
    _inFlight = check;
    return check.whenComplete(() => _inFlight = null);
  }

  /// Runs one update presentation at a time. Both automatic and manual checks
  /// use this gate, so a shared in-flight network response cannot create two
  /// stacked dialogs. Manual checks may present the same version again after
  /// the previous dialog has closed.
  Future<bool> presentUpdate(
    DesktopUpdate update,
    Future<void> Function() present,
  ) async {
    if (_presentingVersion != null) return false;
    _presentingVersion = update.version;
    // Any presentation counts as the automatic notice for this launch.
    _notifiedVersion = update.version;
    try {
      await present();
      return true;
    } finally {
      if (_presentingVersion == update.version) _presentingVersion = null;
    }
  }

  /// Persistently suppresses automatic prompts for exactly this version.
  /// A newer release is still presented, and manual checks remain available.
  Future<void> skipVersion(DesktopUpdate update) async {
    await _ensureSkippedVersionLoaded();
    _skippedVersion = update.version;
    try {
      final preferences = await _getPreferences();
      await preferences.setString(_skippedVersionKey, update.version);
    } catch (error, stackTrace) {
      Log.w(
        'Could not persist skipped update version',
        name: 'motif.update',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> isVersionSkipped(DesktopUpdate update) async {
    await _ensureSkippedVersionLoaded();
    return _skippedVersion == update.version;
  }

  Future<SharedPreferences> _getPreferences() =>
      _preferences ??= SharedPreferences.getInstance();

  Future<void> _ensureSkippedVersionLoaded() =>
      _loadSkippedVersion ??= _readSkippedVersion();

  Future<void> _readSkippedVersion() async {
    try {
      final preferences = await _getPreferences();
      _skippedVersion = preferences.getString(_skippedVersionKey);
    } catch (error, stackTrace) {
      Log.w(
        'Could not read skipped update version',
        name: 'motif.update',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _checkAndNotify() async {
    final result = await checkNow();
    final update = result.update;
    final notify = _onUpdateAvailable;
    if (update == null ||
        notify == null ||
        _notifiedVersion == update.version) {
      return;
    }
    if (await isVersionSkipped(update)) return;
    await presentUpdate(update, () => notify(update));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

class _ReleaseVersion implements Comparable<_ReleaseVersion> {
  const _ReleaseVersion(this.major, this.minor, this.patch, this.prerelease);

  final int major;
  final int minor;
  final int patch;
  final String? prerelease;

  String get display =>
      '$major.$minor.$patch${prerelease == null ? '' : '-$prerelease'}';

  static final RegExp _pattern = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  static _ReleaseVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    return _ReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4),
    );
  }

  @override
  int compareTo(_ReleaseVersion other) {
    for (final pair in <(int, int)>[
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final comparison = pair.$1.compareTo(pair.$2);
      if (comparison != 0) return comparison;
    }
    // A stable release is newer than a prerelease of the same numeric version.
    if (prerelease == null && other.prerelease != null) return 1;
    if (prerelease != null && other.prerelease == null) return -1;
    return (prerelease ?? '').compareTo(other.prerelease ?? '');
  }
}
