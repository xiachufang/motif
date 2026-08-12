import 'protocol/generated/codex_app_server_protocol.dart';

final class CodexParsedUserInputs {
  CodexParsedUserInputs({
    required this.text,
    required Iterable<CodexLocalImageUserInput> localImages,
    required Iterable<CodexImageUserInput> remoteImages,
    required Iterable<CodexUserInput> unhandledInputs,
  }) : localImages = List.unmodifiable(localImages),
       remoteImages = List.unmodifiable(remoteImages),
       unhandledInputs = List.unmodifiable(unhandledInputs);

  final String text;
  final List<CodexLocalImageUserInput> localImages;
  final List<CodexImageUserInput> remoteImages;
  final List<CodexUserInput> unhandledInputs;
}

final class CodexUserInputParser {
  const CodexUserInputParser();

  static const _filesHeader = '# Files mentioned by the user:';
  static final _requestHeader = RegExp(r'^## My request:\s*$', multiLine: true);

  CodexParsedUserInputs parse(Iterable<CodexUserInput> inputs) {
    final textParts = <String>[];
    final localImages = <CodexLocalImageUserInput>[];
    final remoteImages = <CodexImageUserInput>[];
    final unhandledInputs = <CodexUserInput>[];

    for (final input in inputs) {
      if (input is CodexTextUserInput) {
        final text = _parseText(input.text);
        if (text.isNotEmpty) textParts.add(text);
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
      localImages: localImages,
      remoteImages: remoteImages,
      unhandledInputs: unhandledInputs,
    );
  }

  String _parseText(String text) {
    final normalized = text.trimLeft();
    if (!normalized.startsWith(_filesHeader)) return text;

    final requestHeader = _requestHeader.firstMatch(normalized);
    if (requestHeader == null) return text;

    return normalized.substring(requestHeader.end).trim();
  }
}
