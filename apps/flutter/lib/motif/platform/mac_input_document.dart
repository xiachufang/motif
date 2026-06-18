import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MacInputDocument {
  static const MethodChannel _channel = MethodChannel('motif/ime_document');

  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static Future<void> activate(
    String id, {
    required bool defaultEnglish,
  }) async {
    if (!_isMacOS || id.isEmpty) return;
    await _channel.invokeMethod<void>('activateDocument', {
      'id': id,
      'defaultEnglish': defaultEnglish,
    });
  }

  static Future<void> dispose(String id) async {
    if (!_isMacOS || id.isEmpty) return;
    await _channel.invokeMethod<void>('disposeDocument', {'id': id});
  }
}
