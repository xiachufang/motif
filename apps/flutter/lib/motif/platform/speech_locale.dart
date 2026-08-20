import 'dart:ui';

/// The private Doubao IME recognizer is exposed only for Chinese system
/// languages. Script and region variants are all Chinese for this purpose.
bool supportsDoubaoSpeechInput(Locale locale) =>
    locale.languageCode.toLowerCase() == 'zh';
