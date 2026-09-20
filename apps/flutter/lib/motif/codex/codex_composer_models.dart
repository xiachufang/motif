import 'dart:typed_data';

import 'protocol/generated/codex_app_server_protocol.dart';

enum CodexAttachmentKind { image, file }

enum CodexComposerReferenceKind { skill, plugin }

final class CodexComposerReference {
  const CodexComposerReference({
    required this.kind,
    required this.name,
    required this.path,
  });

  final CodexComposerReferenceKind kind;
  final String name;
  final String path;
}

final class CodexPendingAttachment {
  const CodexPendingAttachment({
    required this.name,
    required this.bytes,
    required this.kind,
  });

  final String name;
  final Uint8List bytes;
  final CodexAttachmentKind kind;

  bool get isImage => kind == CodexAttachmentKind.image;
}

final class CodexQueuedMessage {
  const CodexQueuedMessage({
    required this.id,
    required this.text,
    required this.attachments,
    this.references = const [],
    this.serverInput,
  });

  final String id;
  final String text;
  final List<CodexPendingAttachment> attachments;
  final List<CodexComposerReference> references;

  /// The authoritative input payload; retain images, files, and tool references
  /// across reloads and text edits without uploading attachments again.
  final List<CodexUserInput>? serverInput;

  factory CodexQueuedMessage.fromSubmission(CodexQueuedSubmission submission) =>
      CodexQueuedMessage(
        id: submission.id,
        text: submission.input
            .whereType<CodexTextUserInput>()
            .map((input) => input.text)
            .join('\n\n'),
        attachments: const [],
        serverInput: List.unmodifiable(submission.input),
      );
}
