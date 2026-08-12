final class CodexAgentOutputParser {
  const CodexAgentOutputParser();

  static final _gitDirectiveLine = RegExp(
    r'^\s*::git-(?:stage|commit|push|create-branch|create-pr)\{.*\}\s*$',
  );

  String parse(String text) {
    final visible = <String>[];
    String? fenceMarker;
    var fenceLength = 0;
    for (final line in text.split('\n')) {
      final fence = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line)?.group(1);
      if (fence != null) {
        final marker = fence[0];
        if (fenceMarker == null) {
          fenceMarker = marker;
          fenceLength = fence.length;
        } else if (marker == fenceMarker && fence.length >= fenceLength) {
          fenceMarker = null;
          fenceLength = 0;
        }
        visible.add(line);
        continue;
      }
      if (fenceMarker == null && _gitDirectiveLine.hasMatch(line)) continue;
      visible.add(line);
    }
    return visible.join('\n').trimRight();
  }
}
