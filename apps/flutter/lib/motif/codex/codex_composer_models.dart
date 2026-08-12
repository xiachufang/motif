import 'dart:typed_data';

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
  });

  final String id;
  final String text;
  final List<CodexPendingAttachment> attachments;
  final List<CodexComposerReference> references;
}
