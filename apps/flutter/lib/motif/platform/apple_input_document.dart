import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppleInputDocument {
  static const MethodChannel _channel = MethodChannel('motif/ime_document');

  static bool get _isApplePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static Future<void> activate(
    String id, {
    required bool defaultEnglish,
  }) async {
    if (!_isApplePlatform || id.isEmpty) return;
    await _channel.invokeMethod<void>('activateDocument', {
      'id': id,
      'defaultEnglish': defaultEnglish,
    });
  }

  static Future<void> dispose(String id) async {
    if (!_isApplePlatform || id.isEmpty) return;
    await _channel.invokeMethod<void>('disposeDocument', {'id': id});
  }
}
