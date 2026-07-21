/// Defensive JSON primitives shared by persistence and native-service
/// adapters. This module has no observable state and no application logic.
library;

import 'dart:convert';

Map<String, Object?>? jsonDecodeMap(String raw) {
  final value = _tryDecode(raw);
  return value is Map ? value.cast<String, Object?>() : null;
}

List<Object?>? jsonDecodeList(String raw) {
  final value = _tryDecode(raw);
  return value is List ? value : null;
}

String jsonEncodeMap(Map<String, Object?> value) => jsonEncode(value);

String jsonEncodeList(List<Object?> value) => jsonEncode(value);

Object? _tryDecode(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}
