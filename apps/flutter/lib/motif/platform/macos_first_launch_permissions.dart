import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../log/log.dart';
import 'macos_permissions.dart';

const String kMacosInitialPermissionsRequestedKey =
    'motif.macos.initialPermissionsRequested.v1';

/// Requests Motif's macOS permissions once, after the first frame has made the
/// app window available for native consent UI.
final class MacosFirstLaunchPermissions {
  MacosFirstLaunchPermissions({
    MacosPermissions? permissions,
    Future<SharedPreferences>? preferences,
    bool? supported,
  }) : _permissions = permissions ?? const MethodChannelMacosPermissions(),
       _providedPreferences = preferences,
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);

  final MacosPermissions _permissions;
  final Future<SharedPreferences>? _providedPreferences;
  final bool _supported;
  Future<SharedPreferences>? _loadedPreferences;
  Future<void>? _running;

  Future<void> requestIfNeeded() {
    if (!_supported) return Future<void>.value();
    return _running ??= _requestIfNeeded();
  }

  Future<void> _requestIfNeeded() async {
    final preferences = await (_loadedPreferences ??=
        _providedPreferences ?? SharedPreferences.getInstance());
    if (preferences.getBool(kMacosInitialPermissionsRequestedKey) == true) {
      return;
    }

    // Persist before opening any system UI. A quit/relaunch while System
    // Settings is open must not start the entire prompt train again.
    await preferences.setBool(kMacosInitialPermissionsRequestedKey, true);

    MacosPermissionStatuses statuses = const {};
    try {
      statuses = await _permissions.getStatuses();
    } catch (error, stackTrace) {
      Log.w(
        'Could not read initial macOS permission statuses',
        name: 'motif.permissions',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // The first three APIs wait for user interaction. Accessibility is last
    // because its native prompt is asynchronous and would otherwise overlap
    // the next consent surface.
    const requestOrder = [
      MacosPermission.screenRecording,
      MacosPermission.automation,
      MacosPermission.homeDirectory,
      MacosPermission.accessibility,
    ];
    for (final permission in requestOrder) {
      if (statuses[permission] == MacosPermissionStatus.granted) continue;
      try {
        await _permissions.request(permission);
      } catch (error, stackTrace) {
        Log.w(
          'Initial macOS permission request failed: ${permission.wireName}',
          name: 'motif.permissions',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }
}
