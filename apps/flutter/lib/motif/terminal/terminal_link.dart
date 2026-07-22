import 'dart:collection';

import 'terminal_snapshot.dart';

enum TerminalLinkKind { osc8, url, filePath }

class TerminalLinkSegment {
  final int row;
  final int startCol;
  final int endCol;

  const TerminalLinkSegment({
    required this.row,
    required this.startCol,
    required this.endCol,
  });

  bool contains(TerminalCellPoint point) =>
      point.row == row && point.col >= startCol && point.col <= endCol;
}

class TerminalFileTarget {
  final String raw;
  final String path;
  final int? line;
  final int? column;

  const TerminalFileTarget({
    required this.raw,
    required this.path,
    this.line,
    this.column,
  });

  static final RegExp _lineAndColumnLocation = RegExp(
    r'^(.*):([0-9]+):([0-9]+)$',
  );
  static final RegExp _lineLocation = RegExp(r'^(.*):([0-9]+)$');
  static final RegExp _parenLocation = RegExp(r'^(.*)\(([0-9]+),([0-9]+)\)$');
  static final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');
  static final RegExp _uriScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');
  static final RegExp _environmentRoot = RegExp(r'^\$[A-Za-z_]\w*/');
  static final RegExp _dotDirectoryRoot = RegExp(r'^\.[\w][\w.-]*/');
  static final RegExp _nestedEnvironmentRoot = RegExp(
    r'^(?:[\w][\w.-]*/)+\$[A-Za-z_]\w*/',
  );

  static TerminalFileTarget? tryParse(String raw) {
    if (raw.isEmpty) return null;
    var path = raw;
    int? line;
    int? column;
    final paren = _parenLocation.firstMatch(path);
    if (paren != null && paren.group(1)!.isNotEmpty) {
      path = paren.group(1)!;
      line = int.tryParse(paren.group(2)!);
      column = int.tryParse(paren.group(3)!);
    } else {
      final lineAndColumn = _lineAndColumnLocation.firstMatch(path);
      if (lineAndColumn != null && lineAndColumn.group(1)!.isNotEmpty) {
        path = lineAndColumn.group(1)!;
        line = int.tryParse(lineAndColumn.group(2)!);
        column = int.tryParse(lineAndColumn.group(3)!);
      } else {
        final lineOnly = _lineLocation.firstMatch(path);
        if (lineOnly != null && lineOnly.group(1)!.isNotEmpty) {
          path = lineOnly.group(1)!;
          line = int.tryParse(lineOnly.group(2)!);
        }
      }
    }
    if (!_looksLikePath(path)) return null;
    return TerminalFileTarget(raw: raw, path: path, line: line, column: column);
  }

  static TerminalFileTarget? fromFileUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme.toLowerCase() != 'file') return null;
    final path = uri.toFilePath(windows: _windowsAbsolute.hasMatch(uri.path));
    return path.isEmpty ? null : TerminalFileTarget(raw: value, path: path);
  }

  String? resolveAgainst(String? cwd) {
    if (path.startsWith('/') ||
        path.startsWith('~/') ||
        path == '~' ||
        _windowsAbsolute.hasMatch(path)) {
      return path;
    }
    if (cwd == null || cwd.isEmpty) return null;
    final separator = cwd.contains('\\') && !cwd.contains('/') ? '\\' : '/';
    final base = cwd.endsWith('/') || cwd.endsWith('\\')
        ? cwd.substring(0, cwd.length - 1)
        : cwd;
    var relative = path;
    if (relative.startsWith('./') || relative.startsWith('.\\')) {
      relative = relative.substring(2);
    }
    return '$base$separator$relative';
  }

  static bool _looksLikePath(String value) {
    if (value.isEmpty || value.length > TerminalLinkMatcher.maxLogicalLine) {
      return false;
    }
    if (_uriScheme.hasMatch(value) && !_windowsAbsolute.hasMatch(value)) {
      return false;
    }
    if (value.startsWith('/') ||
        value.startsWith('~/') ||
        value.startsWith('./') ||
        value.startsWith('../') ||
        _environmentRoot.hasMatch(value) ||
        _dotDirectoryRoot.hasMatch(value) ||
        _nestedEnvironmentRoot.hasMatch(value) ||
        _windowsAbsolute.hasMatch(value)) {
      return true;
    }
    if (value.contains('\\')) return true;
    return value.contains('/') && value.contains('.');
  }
}

class TerminalLinkMatch {
  final int snapshotId;
  final TerminalLinkKind kind;
  final String target;
  final TerminalFileTarget? file;
  final List<TerminalLinkSegment> segments;

  TerminalLinkMatch({
    required this.snapshotId,
    required this.kind,
    required this.target,
    this.file,
    required List<TerminalLinkSegment> segments,
  }) : segments = List<TerminalLinkSegment>.unmodifiable(segments);

  bool contains(TerminalCellPoint point) =>
      segments.any((segment) => segment.contains(point));
}

class TerminalLinkIndex {
  final int snapshotId;
  final List<TerminalLinkMatch> matches;
  final Map<int, List<TerminalLinkMatch>> _matchesByRow;

  TerminalLinkIndex._({
    required this.snapshotId,
    required List<TerminalLinkMatch> matches,
  }) : matches = List<TerminalLinkMatch>.unmodifiable(matches),
       _matchesByRow = _indexRows(matches);

  factory TerminalLinkIndex.forScreen(TerminalSnapshot snapshot) =>
      TerminalLinkMatcher.indexScreen(snapshot);

  TerminalLinkMatch? matchAt(TerminalCellPoint point) {
    for (final match in _matchesByRow[point.row] ?? const []) {
      if (match.contains(point)) return match;
    }
    return null;
  }

  Iterable<TerminalLinkSegment> get segments sync* {
    for (final match in matches) {
      yield* match.segments;
    }
  }

  static Map<int, List<TerminalLinkMatch>> _indexRows(
    List<TerminalLinkMatch> matches,
  ) {
    final rows = <int, List<TerminalLinkMatch>>{};
    for (final match in matches) {
      for (final segment in match.segments) {
        (rows[segment.row] ??= <TerminalLinkMatch>[]).add(match);
      }
    }
    return UnmodifiableMapView({
      for (final entry in rows.entries)
        entry.key: List<TerminalLinkMatch>.unmodifiable(entry.value),
    });
  }
}

class TerminalLinkMatcher {
  static const int maxLogicalLine = 16 * 1024;

  // Keep these components aligned with Ghostty's `src/config/url.zig`.
  // Dart's RegExp does not support Oniguruma's variable-length lookbehind, so
  // the `$<digits>` guard is expressed as fixed `$` and word guards below.
  static const String _urlSchemes =
      r'https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:';
  static const String _ipv6UrlPattern = r'(?:\[[0-9a-fA-F:]+\](?::[0-9]+)?)';
  static const String _schemeUrlChars = r'[\w\-.~:/?#@!$&*+,;=%]';
  static const String _optionalBracketedWordSuffix = r'(?:[\(\[]\w*[\)\]])?';
  static const String _noTrailingUrlPunctuation = r'(?<![,.])';

  static final String _schemeUrlBranch =
      '''(?:$_urlSchemes)(?:$_ipv6UrlPattern|$_schemeUrlChars+$_optionalBracketedWordSuffix)+$_noTrailingUrlPunctuation''';

  static final RegExp _urlPattern = RegExp(
    _schemeUrlBranch,
    caseSensitive: false,
    unicode: true,
  );

  static const String _pathChars = r'[\w\-.~:/?#@!$&*+;=%]';
  static const String _dottedPathLookahead = r'(?=[\w\-.~:/?#@!$&*+;=%]*\.)';
  static const String _nonDottedPathLookahead = r'(?![\w\-.~:/?#@!$&*+;=%]*\.)';
  static const String _dottedPathSpaceSegments =
      r'(?:(?<!:) (?!\w+://)(?!\.{0,2}/)(?!~/)[\w\-.~:/?#@!$&*+;=%]*[/.])*';
  static const String _anyPathSpaceSegments =
      r'(?:(?<!:) (?!\w+://)(?!\.{0,2}/)(?!~/)[\w\-.~:/?#@!$&*+;=%]+)*';
  static const String _noTrailingColon = r'(?<!:)';
  static const String _trailingSpacesAtEol = r'(?: +(?= *$))?';
  static const String _rootedOrRelativePathPrefix =
      r'(?:\.\./|\./|(?<!\w)~/|(?:[\w][\w\-.]*/)*(?<!\w)\$[A-Za-z_]\w*/|\.[\w][\w\-.]*/|(?<![\w~/])/(?!/))';
  static const String _bareRelativePathPrefix = r'(?<!\$)(?<!\w)[\w][\w\-.]*/';

  static final String _rootedOrRelativePathBranch =
      '''$_rootedOrRelativePathPrefix(?:$_dottedPathLookahead$_pathChars+$_dottedPathSpaceSegments$_noTrailingColon$_trailingSpacesAtEol|$_nonDottedPathLookahead$_pathChars+$_anyPathSpaceSegments$_noTrailingColon$_trailingSpacesAtEol)''';
  static final String _bareRelativePathBranch =
      '''$_dottedPathLookahead$_bareRelativePathPrefix$_pathChars+$_noTrailingColon$_trailingSpacesAtEol''';

  static final RegExp _pathPattern = RegExp(
    '$_rootedOrRelativePathBranch|$_bareRelativePathBranch',
    unicode: true,
  );

  static TerminalLinkIndex indexScreen(TerminalSnapshot snapshot) {
    final matches = <TerminalLinkMatch>[];
    var row = 0;
    while (row < snapshot.lines.length) {
      final end = _logicalLineEnd(snapshot, row);
      matches.addAll(_matchesForRows(snapshot, row, end));
      row = end + 1;
    }
    return TerminalLinkIndex._(snapshotId: snapshot.frameId, matches: matches);
  }

  static TerminalLinkMatch? matchAt(
    TerminalSnapshot snapshot,
    TerminalCellPoint point,
  ) {
    final viewportRow = point.row - snapshot.viewportOffset;
    if (viewportRow < 0 || viewportRow >= snapshot.lines.length) return null;
    final start = _logicalLineStart(snapshot, viewportRow);
    final end = _logicalLineEnd(snapshot, viewportRow);
    for (final match in _matchesForRows(snapshot, start, end)) {
      if (match.contains(point)) return match;
    }
    return null;
  }

  static int _logicalLineStart(TerminalSnapshot snapshot, int row) {
    var result = row;
    while (result > 0 &&
        (snapshot.lines[result].wrapContinuation ||
            snapshot.lines[result - 1].wrap)) {
      result--;
    }
    return result;
  }

  static int _logicalLineEnd(TerminalSnapshot snapshot, int row) {
    var result = row;
    while (result + 1 < snapshot.lines.length &&
        (snapshot.lines[result].wrap ||
            snapshot.lines[result + 1].wrapContinuation)) {
      result++;
    }
    return result;
  }

  static List<TerminalLinkMatch> _matchesForRows(
    TerminalSnapshot snapshot,
    int startRow,
    int endRow,
  ) {
    final line = _MappedLogicalLine.build(snapshot, startRow, endRow);
    final matches = <TerminalLinkMatch>[];
    final occupied = <({int start, int end})>[];

    var offset = 0;
    while (offset < line.mapping.length) {
      final uri = line.mapping[offset].hyperlinkUri;
      if (uri == null || uri.isEmpty) {
        offset++;
        continue;
      }
      var end = offset + 1;
      while (end < line.mapping.length &&
          line.mapping[end].hyperlinkUri == uri) {
        end++;
      }
      _addMatch(
        snapshot,
        line,
        matches,
        occupied,
        start: offset,
        end: end,
        kind: TerminalLinkKind.osc8,
        target: uri,
      );
      offset = end;
    }

    if (line.text.length <= maxLogicalLine) {
      for (final match in _urlPattern.allMatches(line.text)) {
        final end = _trimTrailingUrlPunctuation(
          line.text,
          match.start,
          match.end,
        );
        if (end <= match.start || _overlaps(occupied, match.start, end)) {
          continue;
        }
        _addMatch(
          snapshot,
          line,
          matches,
          occupied,
          start: match.start,
          end: end,
          kind: TerminalLinkKind.url,
          target: line.text.substring(match.start, end),
        );
      }

      for (final path in _pathPattern.allMatches(line.text)) {
        _addPathMatch(snapshot, line, matches, occupied, path.start, path.end);
      }
    }

    matches.sort((a, b) {
      final aa = a.segments.first;
      final bb = b.segments.first;
      final rowCompare = aa.row.compareTo(bb.row);
      return rowCompare != 0 ? rowCompare : aa.startCol.compareTo(bb.startCol);
    });
    return matches;
  }

  static void _addPathMatch(
    TerminalSnapshot snapshot,
    _MappedLogicalLine line,
    List<TerminalLinkMatch> matches,
    List<({int start, int end})> occupied,
    int rawStart,
    int rawEnd,
  ) {
    if (rawEnd <= rawStart || _overlaps(occupied, rawStart, rawEnd)) return;
    final value = line.text.substring(rawStart, rawEnd);
    final file = TerminalFileTarget.tryParse(value);
    if (file == null) return;
    if (_isExtensionlessSingleSegmentAbsolutePath(file.path)) return;
    _addMatch(
      snapshot,
      line,
      matches,
      occupied,
      start: rawStart,
      end: rawEnd,
      kind: TerminalLinkKind.filePath,
      target: value,
      file: file,
    );
  }

  static bool _isExtensionlessSingleSegmentAbsolutePath(String path) {
    if (!path.startsWith('/') || path.startsWith('//')) return false;
    var end = path.length;
    final query = path.indexOf('?');
    if (query >= 0 && query < end) end = query;
    final fragment = path.indexOf('#');
    if (fragment >= 0 && fragment < end) end = fragment;
    final segment = path.substring(1, end).trimRight();
    return segment.isNotEmpty &&
        !segment.contains('/') &&
        !segment.contains('.');
  }

  static void _addMatch(
    TerminalSnapshot snapshot,
    _MappedLogicalLine line,
    List<TerminalLinkMatch> matches,
    List<({int start, int end})> occupied, {
    required int start,
    required int end,
    required TerminalLinkKind kind,
    required String target,
    TerminalFileTarget? file,
  }) {
    final segments = line.segmentsForRange(start, end);
    if (segments.isEmpty) return;
    matches.add(
      TerminalLinkMatch(
        snapshotId: snapshot.frameId,
        kind: kind,
        target: target,
        file: file,
        segments: segments,
      ),
    );
    occupied.add((start: start, end: end));
  }

  static bool _overlaps(
    List<({int start, int end})> occupied,
    int start,
    int end,
  ) => occupied.any((range) => start < range.end && end > range.start);

  static int _trimTrailingUrlPunctuation(String text, int start, int end) {
    var result = end;
    while (result > start && '.,'.contains(text[result - 1])) {
      result--;
    }
    return result;
  }
}

class _MappedLogicalLine {
  final String text;
  final List<_MappedCell> mapping;

  const _MappedLogicalLine(this.text, this.mapping);

  factory _MappedLogicalLine.build(
    TerminalSnapshot snapshot,
    int startRow,
    int endRow,
  ) {
    final text = StringBuffer();
    final mapping = <_MappedCell>[];

    void append(String value, _MappedCell cell) {
      text.write(value);
      for (var i = 0; i < value.length; i++) {
        mapping.add(cell);
      }
    }

    for (var viewportRow = startRow; viewportRow <= endRow; viewportRow++) {
      final row = snapshot.lines[viewportRow];
      final screenRow = snapshot.viewportOffset + viewportRow;
      var col = 0;
      for (final cell in row.cells) {
        while (col < cell.col) {
          append(' ', _MappedCell(row: screenRow, startCol: col, endCol: col));
          col++;
        }
        final width = cell.widthCells <= 0 ? 1 : cell.widthCells;
        final mapped = _MappedCell(
          row: screenRow,
          startCol: cell.col,
          endCol: cell.col + width - 1,
          hyperlinkUri: cell.hyperlinkUri,
        );
        final value = !cell.invisible && cell.text.isNotEmpty ? cell.text : ' ';
        append(value, mapped);
        col = cell.col + width;
      }
      if (row.wrap) {
        while (col < snapshot.cols) {
          append(' ', _MappedCell(row: screenRow, startCol: col, endCol: col));
          col++;
        }
      }
    }
    return _MappedLogicalLine(text.toString(), mapping);
  }

  List<TerminalLinkSegment> segmentsForRange(int start, int end) {
    if (start < 0 || end > mapping.length || end <= start) return const [];
    final segments = <TerminalLinkSegment>[];
    _MappedCell? previousCell;
    for (var i = start; i < end; i++) {
      final cell = mapping[i];
      if (previousCell != null && previousCell.sameCell(cell)) continue;
      previousCell = cell;
      if (segments.isNotEmpty) {
        final previous = segments.last;
        if (previous.row == cell.row && cell.startCol <= previous.endCol + 1) {
          segments[segments.length - 1] = TerminalLinkSegment(
            row: previous.row,
            startCol: previous.startCol,
            endCol: cell.endCol > previous.endCol
                ? cell.endCol
                : previous.endCol,
          );
          continue;
        }
      }
      segments.add(
        TerminalLinkSegment(
          row: cell.row,
          startCol: cell.startCol,
          endCol: cell.endCol,
        ),
      );
    }
    return segments;
  }
}

class _MappedCell {
  final int row;
  final int startCol;
  final int endCol;
  final String? hyperlinkUri;

  const _MappedCell({
    required this.row,
    required this.startCol,
    required this.endCol,
    this.hyperlinkUri,
  });

  bool sameCell(_MappedCell other) =>
      row == other.row && startCol == other.startCol && endCol == other.endCol;
}
