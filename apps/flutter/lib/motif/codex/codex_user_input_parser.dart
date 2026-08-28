import 'dart:convert';

import 'protocol/generated/codex_app_server_protocol.dart';

final class CodexResponseAnnotation {
  const CodexResponseAnnotation({required this.text, this.annotation});

  /// Text selected from the earlier assistant response.
  final String text;

  /// Optional comment the user added to the selection.
  final String? annotation;
}

final class CodexParsedUserInputs {
  CodexParsedUserInputs({
    required this.text,
    required Iterable<CodexResponseAnnotation> responseAnnotations,
    required Iterable<CodexLocalImageUserInput> localImages,
    required Iterable<CodexImageUserInput> remoteImages,
    required Iterable<CodexUserInput> unhandledInputs,
  }) : responseAnnotations = List.unmodifiable(responseAnnotations),
       localImages = List.unmodifiable(localImages),
       remoteImages = List.unmodifiable(remoteImages),
       unhandledInputs = List.unmodifiable(unhandledInputs);

  final String text;
  final List<CodexResponseAnnotation> responseAnnotations;
  final List<CodexLocalImageUserInput> localImages;
  final List<CodexImageUserInput> remoteImages;
  final List<CodexUserInput> unhandledInputs;
}

final class _ParsedTextInput {
  const _ParsedTextInput({
    required this.text,
    this.responseAnnotations = const [],
  });

  final String text;
  final List<CodexResponseAnnotation> responseAnnotations;
}

final class CodexUserInputParser {
  const CodexUserInputParser();

  static const _filesHeader = '# Files mentioned by the user:';
  static const _responseAnnotationsHeader = '# Response annotations:';
  static const _responseAnnotationsOpen = '<response-annotations>';
  static const _responseAnnotationsClose = '</response-annotations>';
  static final _requestHeader = RegExp(
    r'^## My request(?: for Codex)?:\s*$',
    multiLine: true,
  );

  CodexParsedUserInputs parse(Iterable<CodexUserInput> inputs) {
    final textParts = <String>[];
    final responseAnnotations = <CodexResponseAnnotation>[];
    final localImages = <CodexLocalImageUserInput>[];
    final remoteImages = <CodexImageUserInput>[];
    final unhandledInputs = <CodexUserInput>[];

    for (final input in inputs) {
      if (input is CodexTextUserInput) {
        final parsed = _parseText(input.text);
        if (parsed.text.isNotEmpty) textParts.add(parsed.text);
        responseAnnotations.addAll(parsed.responseAnnotations);
      } else if (input is CodexLocalImageUserInput) {
        localImages.add(input);
      } else if (input is CodexImageUserInput) {
        remoteImages.add(input);
      } else {
        unhandledInputs.add(input);
      }
    }

    return CodexParsedUserInputs(
      text: textParts.join('\n\n'),
      responseAnnotations: responseAnnotations,
      localImages: localImages,
      remoteImages: remoteImages,
      unhandledInputs: unhandledInputs,
    );
  }

  _ParsedTextInput _parseText(String text) {
    final normalized = text.trimLeft();
    final annotated = _parseResponseAnnotations(normalized);
    if (annotated != null) return annotated;
    if (!normalized.startsWith(_filesHeader)) {
      return _ParsedTextInput(text: text);
    }

    final requestHeader = _lastRequestHeader(normalized);
    if (requestHeader == null) return _ParsedTextInput(text: text);

    return _ParsedTextInput(
      text: normalized.substring(requestHeader.end).trim(),
    );
  }

  _ParsedTextInput? _parseResponseAnnotations(String text) {
    final firstLineEnd = text.indexOf('\n');
    final firstLine = firstLineEnd == -1
        ? text
        : text.substring(0, firstLineEnd);
    if (firstLine.trimRight() != _responseAnnotationsHeader) return null;

    final openIndex = text.indexOf(_responseAnnotationsOpen);
    if (openIndex == -1) return null;
    final payloadStart = openIndex + _responseAnnotationsOpen.length;
    final closeIndex = text.indexOf(_responseAnnotationsClose, payloadStart);
    if (closeIndex == -1) return null;
    final requestHeader = _lastRequestHeader(
      text,
      start: closeIndex + _responseAnnotationsClose.length,
    );
    if (requestHeader == null) return null;

    final annotations = _decodeResponseAnnotations(
      text.substring(payloadStart, closeIndex).trim(),
    );
    // Keep an unfamiliar or damaged prompt visible instead of silently
    // discarding user context.
    if (annotations == null) return null;

    return _ParsedTextInput(
      text: text.substring(requestHeader.end).trim(),
      responseAnnotations: annotations,
    );
  }

  List<CodexResponseAnnotation>? _decodeResponseAnnotations(String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;

    final annotations = <CodexResponseAnnotation>[];
    for (final item in decoded) {
      if (item is! Map) return null;
      final text = item['text'];
      final annotation = item['annotation'];
      if (text is! String ||
          text.trim().isEmpty ||
          (annotation != null && annotation is! String)) {
        return null;
      }
      final normalizedAnnotation = annotation is String
          ? annotation.trim()
          : '';
      annotations.add(
        CodexResponseAnnotation(
          text: text.trim(),
          annotation: normalizedAnnotation.isEmpty
              ? null
              : normalizedAnnotation,
        ),
      );
    }
    return annotations;
  }

  RegExpMatch? _lastRequestHeader(String text, {int start = 0}) {
    RegExpMatch? result;
    for (final match in _requestHeader.allMatches(text, start)) {
      result = match;
    }
    return result;
  }
}
