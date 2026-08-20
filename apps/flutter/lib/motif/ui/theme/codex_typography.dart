import 'package:material_ui/material_ui.dart';

/// Codex-specific primary text styles.
///
/// Supporting labels and screen titles continue to use [MotifType] so their
/// hierarchy remains intact; only the former 15px Codex styles are compacted.
abstract final class CodexType {
  static const headline = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

  static const body = TextStyle(fontSize: 14, fontWeight: FontWeight.w400);
}
