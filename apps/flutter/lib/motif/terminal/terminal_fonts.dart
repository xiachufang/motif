import 'package:flutter/foundation.dart';

class TerminalFontSpec {
  final String family;
  final List<String> fallback;

  const TerminalFontSpec(this.family, [this.fallback = const []]);
}

TerminalFontSpec platformTerminalFont() {
  if (kIsWeb) {
    return const TerminalFontSpec('monospace');
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => const TerminalFontSpec(
      'Menlo',
      ['.SF Mono', 'Courier'],
    ),
    TargetPlatform.windows => const TerminalFontSpec('Consolas', [
      'Cascadia Mono',
      'Courier New',
      'monospace',
    ]),
    TargetPlatform.android ||
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => const TerminalFontSpec('monospace'),
  };
}
