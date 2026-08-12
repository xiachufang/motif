import 'dart:convert';
import 'dart:typed_data';

import 'motif_proto.dart';

/// Immutable bytes and metadata consumed by the shared file preview surface.
class FilePreviewDocument {
  const FilePreviewDocument({
    required this.path,
    required this.bytes,
    this.mime,
    this.binary = false,
    this.truncated = false,
    this.image = false,
  });

  final String path;
  final Uint8List bytes;
  final String? mime;
  final bool binary;
  final bool truncated;
  final bool image;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// One protocol patch associated with a concrete file path.
class FilePatch {
  const FilePatch({required this.path, required this.patch, this.sourcePath});

  final String path;
  final String patch;
  final String? sourcePath;
}

/// A stable diff snapshot that can be rendered without querying a workspace.
class DiffDocument {
  const DiffDocument({required this.files});

  factory DiffDocument.fromFilePatches(Iterable<FilePatch> patches) {
    final files = <String, _MutableDiffDocumentFile>{};
    for (final entry in patches) {
      final path = entry.path.trim().replaceAll('\\', '/');
      if (path.isEmpty) continue;
      final file = files.putIfAbsent(
        path,
        () => _MutableDiffDocumentFile(path, entry.sourcePath),
      );
      if (file.lines.isNotEmpty) file.lines.add('');
      file.lines.addAll(_visibleDiffLines(entry.patch));
      final stats = _diffStats(entry.patch);
      file.additions += stats.additions;
      file.deletions += stats.deletions;
    }
    return DiffDocument(
      files: List.unmodifiable(files.values.map((file) => file.freeze())),
    );
  }

  factory DiffDocument.fromUnifiedPatch({
    required String patch,
    required List<DiffSummaryFile> summary,
    String? fallbackPath,
  }) {
    final summaryByPath = {for (final file in summary) file.path: file};
    final files = <DiffDocumentFile>[];
    var currentLines = <String>[];
    String? currentPath;

    void flush() {
      if (currentLines.isEmpty) return;
      final path = currentPath ?? fallbackPath ?? summary.firstOrNull?.path;
      final summaryFile = path == null ? null : summaryByPath[path];
      final visibleLines = currentLines
          .where((line) => !_isDiffMetadataLine(line))
          .toList(growable: false);
      final stats = _diffStats(currentLines.join('\n'));
      files.add(
        DiffDocumentFile(
          path: path ?? 'Diff',
          sourcePath: path,
          additions: summaryFile?.additions ?? stats.additions,
          deletions: summaryFile?.deletions ?? stats.deletions,
          lines: visibleLines,
        ),
      );
      currentLines = <String>[];
    }

    for (final line in const LineSplitter().convert(patch)) {
      if (line.startsWith('diff --git ')) {
        flush();
        currentPath = _pathFromDiffHeader(line) ?? fallbackPath;
        continue;
      }
      currentLines.add(line);
    }
    flush();

    if (files.isEmpty && patch.isNotEmpty) {
      final path = fallbackPath ?? summary.firstOrNull?.path ?? 'Diff';
      final summaryFile = summaryByPath[path];
      final stats = _diffStats(patch);
      files.add(
        DiffDocumentFile(
          path: path,
          sourcePath: path,
          additions: summaryFile?.additions ?? stats.additions,
          deletions: summaryFile?.deletions ?? stats.deletions,
          lines: _visibleDiffLines(patch),
        ),
      );
    }
    return DiffDocument(files: List.unmodifiable(files));
  }

  final List<DiffDocumentFile> files;

  bool get isEmpty => files.isEmpty;

  List<DiffSummaryFile> get summary => [
    for (final file in files)
      DiffSummaryFile(
        path: file.path,
        additions: file.additions,
        deletions: file.deletions,
      ),
  ];
}

class DiffDocumentFile {
  const DiffDocumentFile({
    required this.path,
    this.sourcePath,
    required this.additions,
    required this.deletions,
    required this.lines,
  });

  final String path;
  final String? sourcePath;
  final int additions;
  final int deletions;
  final List<String> lines;
}

final class _MutableDiffDocumentFile {
  _MutableDiffDocumentFile(this.path, this.sourcePath);

  final String path;
  final String? sourcePath;
  final List<String> lines = [];
  int additions = 0;
  int deletions = 0;

  DiffDocumentFile freeze() => DiffDocumentFile(
    path: path,
    sourcePath: sourcePath,
    additions: additions,
    deletions: deletions,
    lines: List.unmodifiable(lines),
  );
}

List<String> _visibleDiffLines(String patch) => const LineSplitter()
    .convert(patch)
    .where((line) => !line.startsWith('diff --git '))
    .where((line) => !_isDiffMetadataLine(line))
    .toList(growable: false);

({int additions, int deletions}) _diffStats(String patch) {
  var additions = 0;
  var deletions = 0;
  for (final line in const LineSplitter().convert(patch)) {
    if (line.startsWith('+') && !line.startsWith('+++')) additions++;
    if (line.startsWith('-') && !line.startsWith('---')) deletions++;
  }
  return (additions: additions, deletions: deletions);
}

String? _pathFromDiffHeader(String line) {
  const marker = ' b/';
  final index = line.lastIndexOf(marker);
  if (index < 0) return null;
  return line.substring(index + marker.length).trim();
}

bool _isDiffMetadataLine(String line) =>
    line.startsWith('@@ ') ||
    line.startsWith('index ') ||
    line.startsWith('--- ') ||
    line.startsWith('+++ ') ||
    line.startsWith('new file mode ') ||
    line.startsWith('deleted file mode ') ||
    line.startsWith('old mode ') ||
    line.startsWith('new mode ') ||
    line.startsWith('similarity index ') ||
    line.startsWith('rename from ') ||
    line.startsWith('rename to ');
