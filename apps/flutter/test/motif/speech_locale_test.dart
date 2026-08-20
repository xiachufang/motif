import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/speech_locale.dart';

void main() {
  test('Doubao speech input supports every Chinese system locale', () {
    expect(supportsDoubaoSpeechInput(const Locale('zh')), isTrue);
    expect(
      supportsDoubaoSpeechInput(
        const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
          countryCode: 'TW',
        ),
      ),
      isTrue,
    );
  });

  test('Doubao speech input rejects non-Chinese system locales', () {
    expect(supportsDoubaoSpeechInput(const Locale('en', 'US')), isFalse);
    expect(supportsDoubaoSpeechInput(const Locale('ja', 'JP')), isFalse);
  });
}
