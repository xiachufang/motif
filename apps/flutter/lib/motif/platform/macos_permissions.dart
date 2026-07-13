import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum MacosPermission {
  fullDiskAccess('fullDiskAccess'),
  screenRecording('screenRecording'),
  accessibility('accessibility'),
  automation('automation');

  const MacosPermission(this.wireName);

  final String wireName;
}

enum MacosPermissionStatus {
  granted('granted'),
  notGranted('notGranted'),
  managedExternally('managedExternally'),
  unavailable('unavailable');

  const MacosPermissionStatus(this.wireName);

  final String wireName;

  static MacosPermissionStatus fromWire(Object? value) {
    for (final status in values) {
      if (status.wireName == value) return status;
    }
    return unavailable;
  }
}

typedef MacosPermissionStatuses = Map<MacosPermission, MacosPermissionStatus>;

abstract interface class MacosPermissions {
  Future<MacosPermissionStatuses> getStatuses();

  Future<MacosPermissionStatus> request(MacosPermission permission);

  Future<void> openSystemSettings(MacosPermission permission);
}

class MethodChannelMacosPermissions implements MacosPermissions {
  const MethodChannelMacosPermissions({
    this.channel = const MethodChannel('motif/macos_permissions'),
    this.supported,
  });

  final MethodChannel channel;
  final bool? supported;

  bool get _isSupported =>
      supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<MacosPermissionStatuses> getStatuses() async {
    if (!_isSupported) {
      return {
        for (final permission in MacosPermission.values)
          permission: MacosPermissionStatus.unavailable,
      };
    }
    final raw = await channel.invokeMapMethod<Object?, Object?>('getStatuses');
    return {
      for (final permission in MacosPermission.values)
        permission: MacosPermissionStatus.fromWire(raw?[permission.wireName]),
    };
  }

  @override
  Future<MacosPermissionStatus> request(MacosPermission permission) async {
    if (!_isSupported) return MacosPermissionStatus.unavailable;
    final raw = await channel.invokeMethod<Object?>('request', {
      'permission': permission.wireName,
    });
    return MacosPermissionStatus.fromWire(raw);
  }

  @override
  Future<void> openSystemSettings(MacosPermission permission) async {
    if (!_isSupported) return;
    await channel.invokeMethod<void>('openSystemSettings', {
      'permission': permission.wireName,
    });
  }
}
