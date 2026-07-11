/// Wire/domain models for the motif protocol.
///
/// Ported from `apps/ios/Motif/Native/MotifProto.swift`. Field names match the
/// JSON wire format exactly (snake_case) so these decode/encode against the
/// same `motifd` server the iOS app talks to. Keep names in sync with the Rust
/// `motif-proto` crate.
library;

// ─────────────────────────── small helpers ───────────────────────────

int? _asInt(Object? v) => v == null ? null : (v as num).toInt();
String? _asString(Object? v) => v as String?;

// ─────────────────────────── enums ───────────────────────────

enum ShellKind {
  bash,
  zsh,
  fish,
  unknown;

  static ShellKind fromWire(Object? v) => switch (v) {
    'bash' => ShellKind.bash,
    'zsh' => ShellKind.zsh,
    'fish' => ShellKind.fish,
    _ => ShellKind.unknown,
  };

  String get wire => name;
}

enum FileType {
  file,
  dir,
  symlink;

  static FileType fromWire(Object? v) => switch (v) {
    'dir' => FileType.dir,
    'symlink' => FileType.symlink,
    _ => FileType.file,
  };

  String get wire => name;
}

enum GitFileStatus {
  unmodified,
  modified,
  added,
  deleted,
  renamed,
  copied,
  untracked,
  ignored,
  conflicted;

  static GitFileStatus fromWire(Object? v) {
    for (final s in values) {
      if (s.name == v) return s;
    }
    return GitFileStatus.unmodified;
  }

  String get wire => name;
}

// ─────────────────────────── core structs ───────────────────────────

class PingInfo {
  final String service;
  final String version;

  /// LAN-direct hint for a rendezvous server: the plaintext port and this
  /// host's NIC addresses to try at it. Empty/`null` unless the paired motifd
  /// opened a non-loopback `--listen` (see the rzv direct-upgrade path). A
  /// same-LAN client probes these and upgrades off the relay.
  final int? rzvDirectPort;
  final List<String> rzvDirectAddrs;

  const PingInfo({
    required this.service,
    required this.version,
    this.rzvDirectPort,
    this.rzvDirectAddrs = const [],
  });

  factory PingInfo.fromJson(Map<String, Object?> j) => PingInfo(
    service: (j['service'] as String?) ?? '',
    version: (j['version'] as String?) ?? '',
    rzvDirectPort: (j['rzv_direct_port'] as num?)?.toInt(),
    rzvDirectAddrs:
        (j['rzv_direct_addrs'] as List?)?.cast<String>().toList() ?? const [],
  );

  /// True when the peer is a genuine motif-server (vs. some other HTTP service
  /// answering on the port).
  bool get isMotifServer => service == 'motif-server';
}

class SessionInfo {
  final String name;
  final String? workdir;
  final int? createdAt;
  final int? clientCount;

  const SessionInfo({
    required this.name,
    this.workdir,
    this.createdAt,
    this.clientCount,
  });

  String get id => name;

  factory SessionInfo.fromJson(Map<String, Object?> j) => SessionInfo(
    name: (j['name'] as String?) ?? '',
    workdir: _asString(j['workdir']),
    createdAt: _asInt(j['created_at']),
    clientCount: _asInt(j['client_count']),
  );
}

class ClientInfo {
  final String id;
  final int? since;

  const ClientInfo({required this.id, this.since});

  factory ClientInfo.fromJson(Map<String, Object?> j) =>
      ClientInfo(id: (j['id'] as String?) ?? '', since: _asInt(j['since']));
}

class ShellContext {
  final String? branch;
  final String? head;
  final String? venv;
  final String? conda;
  final String? node;

  const ShellContext({
    this.branch,
    this.head,
    this.venv,
    this.conda,
    this.node,
  });

  factory ShellContext.fromJson(Map<String, Object?> j) => ShellContext(
    branch: _asString(j['branch']),
    head: _asString(j['head']),
    venv: _asString(j['venv']),
    conda: _asString(j['conda']),
    node: _asString(j['node']),
  );

  /// Build from the loose string map carried by OSC 777 Context payloads.
  factory ShellContext.fromMap(Map<String, String> m) => ShellContext(
    branch: m['branch'],
    head: m['head'],
    venv: m['venv'],
    conda: m['conda'],
    node: m['node'],
  );
}

class PtyInfo {
  final String id;
  final String? cmd;
  final String? cwd;
  final int cols;
  final int rows;
  final bool? alive;
  final int? createdAt;

  /// Command currently executing, as tracked server-side from shell-integration
  /// markers. Present on cold attach so a restored client can recognize a
  /// running command whose start marker it never saw. Null at a prompt.
  final String? runningCommand;

  const PtyInfo({
    required this.id,
    this.cmd,
    this.cwd,
    required this.cols,
    required this.rows,
    this.alive,
    this.createdAt,
    this.runningCommand,
  });

  factory PtyInfo.fromJson(Map<String, Object?> j) => PtyInfo(
    id: (j['id'] as String?) ?? '',
    cmd: _asString(j['cmd']),
    cwd: _asString(j['cwd']),
    cols: _asInt(j['cols']) ?? 80,
    rows: _asInt(j['rows']) ?? 24,
    alive: j['alive'] as bool?,
    createdAt: _asInt(j['created_at']),
    runningCommand: _asString(j['running_command']),
  );

  PtyInfo copyWith({
    String? cmd,
    String? cwd,
    int? cols,
    int? rows,
    bool? alive,
  }) => PtyInfo(
    id: id,
    cmd: cmd ?? this.cmd,
    cwd: cwd ?? this.cwd,
    cols: cols ?? this.cols,
    rows: rows ?? this.rows,
    alive: alive ?? this.alive,
    createdAt: createdAt,
    runningCommand: runningCommand,
  );
}

/// Tagged union describing what a view renders. Wire form is
/// `{"kind": "...", ...}`.
sealed class ViewSpec {
  const ViewSpec();

  factory ViewSpec.fromJson(Map<String, Object?> j) {
    switch (j['kind']) {
      case 'pty':
        return PtyViewSpec((j['pty_id'] as String?) ?? '');
      case 'preview':
        return PreviewViewSpec((j['path'] as String?) ?? '');
      case 'diff':
        return DiffViewSpec(
          staged: (j['staged'] as bool?) ?? false,
          path: _asString(j['path']),
        );
      case 'image':
        return ImageViewSpec((j['path'] as String?) ?? '');
      default:
        return OtherViewSpec((j['kind'] as String?) ?? 'unknown');
    }
  }

  Map<String, Object?> toJson();
}

class PtyViewSpec extends ViewSpec {
  final String ptyId;
  const PtyViewSpec(this.ptyId);
  @override
  Map<String, Object?> toJson() => {'kind': 'pty', 'pty_id': ptyId};
}

class PreviewViewSpec extends ViewSpec {
  final String path;
  const PreviewViewSpec(this.path);
  @override
  Map<String, Object?> toJson() => {'kind': 'preview', 'path': path};
}

class DiffViewSpec extends ViewSpec {
  final bool staged;
  final String? path;
  const DiffViewSpec({required this.staged, this.path});
  @override
  Map<String, Object?> toJson() => {
    'kind': 'diff',
    'staged': staged,
    if (path != null) 'path': path,
  };
}

class ImageViewSpec extends ViewSpec {
  final String path;
  const ImageViewSpec(this.path);
  @override
  Map<String, Object?> toJson() => {'kind': 'image', 'path': path};
}

class OtherViewSpec extends ViewSpec {
  final String typeName;
  const OtherViewSpec(this.typeName);
  @override
  Map<String, Object?> toJson() => {'kind': typeName};
}

class ViewInfo {
  final String id;
  final ViewSpec spec;
  final int? createdAt;

  const ViewInfo({required this.id, required this.spec, this.createdAt});

  factory ViewInfo.fromJson(Map<String, Object?> j) => ViewInfo(
    id: (j['id'] as String?) ?? '',
    spec: ViewSpec.fromJson((j['spec'] as Map?)?.cast<String, Object?>() ?? {}),
    createdAt: _asInt(j['created_at']),
  );
}

// ─────────────────────────── filesystem / git ───────────────────────────

class TreeEntry {
  final String name;
  final FileType type;
  final int size;
  final int mtime;
  final GitFileStatus? gitStatus;

  const TreeEntry({
    required this.name,
    required this.type,
    required this.size,
    required this.mtime,
    this.gitStatus,
  });

  factory TreeEntry.fromJson(Map<String, Object?> j) => TreeEntry(
    name: (j['name'] as String?) ?? '',
    type: FileType.fromWire(j['type']),
    size: _asInt(j['size']) ?? 0,
    mtime: _asInt(j['mtime']) ?? 0,
    gitStatus: j['git_status'] == null
        ? null
        : GitFileStatus.fromWire(j['git_status']),
  );
}

class FsStatResult {
  final FileType type;
  final int size;
  final int mtime;
  final GitFileStatus? gitStatus;

  const FsStatResult({
    required this.type,
    required this.size,
    required this.mtime,
    this.gitStatus,
  });

  factory FsStatResult.fromJson(Map<String, Object?> j) => FsStatResult(
    type: FileType.fromWire(j['type']),
    size: _asInt(j['size']) ?? 0,
    mtime: _asInt(j['mtime']) ?? 0,
    gitStatus: j['git_status'] == null
        ? null
        : GitFileStatus.fromWire(j['git_status']),
  );
}

class FsReadResult {
  final String contentB64;
  final String sha256;
  final bool truncated;
  final bool binary;
  final String? mime;

  const FsReadResult({
    required this.contentB64,
    required this.sha256,
    required this.truncated,
    required this.binary,
    this.mime,
  });

  factory FsReadResult.fromJson(Map<String, Object?> j) => FsReadResult(
    contentB64: (j['content_b64'] as String?) ?? '',
    sha256: (j['sha256'] as String?) ?? '',
    truncated: (j['truncated'] as bool?) ?? false,
    binary: (j['binary'] as bool?) ?? false,
    mime: _asString(j['mime']),
  );
}

class FsWriteResult {
  final String sha256;
  const FsWriteResult({required this.sha256});
  factory FsWriteResult.fromJson(Map<String, Object?> j) =>
      FsWriteResult(sha256: (j['sha256'] as String?) ?? '');
}

class GitFile {
  final String path;
  final GitFileStatus staged;
  final GitFileStatus unstaged;

  const GitFile({
    required this.path,
    required this.staged,
    required this.unstaged,
  });

  factory GitFile.fromJson(Map<String, Object?> j) => GitFile(
    path: (j['path'] as String?) ?? '',
    staged: GitFileStatus.fromWire(j['staged']),
    unstaged: GitFileStatus.fromWire(j['unstaged']),
  );
}

class GitStatusResult {
  final String? branch;
  final int ahead;
  final int behind;
  final List<GitFile> files;

  const GitStatusResult({
    this.branch,
    required this.ahead,
    required this.behind,
    required this.files,
  });

  factory GitStatusResult.fromJson(Map<String, Object?> j) => GitStatusResult(
    branch: _asString(j['branch']),
    ahead: _asInt(j['ahead']) ?? 0,
    behind: _asInt(j['behind']) ?? 0,
    files: ((j['files'] as List?) ?? [])
        .map((e) => GitFile.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
  );
}

class DiffSummaryFile {
  final String path;
  final int additions;
  final int deletions;

  const DiffSummaryFile({
    required this.path,
    required this.additions,
    required this.deletions,
  });

  factory DiffSummaryFile.fromJson(Map<String, Object?> j) => DiffSummaryFile(
    path: (j['path'] as String?) ?? '',
    additions: _asInt(j['additions']) ?? 0,
    deletions: _asInt(j['deletions']) ?? 0,
  );
}

// ─────────────────────────── attach result ───────────────────────────

class AttachResult {
  final SessionInfo? session;
  final String? clientId;
  final List<ClientInfo> clients;
  final List<PtyInfo> ptys;
  final List<ViewInfo> views;
  final String? activeView;
  final int? lastSeq;
  final String? theme;

  const AttachResult({
    this.session,
    this.clientId,
    this.clients = const [],
    this.ptys = const [],
    this.views = const [],
    this.activeView,
    this.lastSeq,
    this.theme,
  });

  factory AttachResult.fromJson(Map<String, Object?> j) {
    List<T> list<T>(String key, T Function(Map<String, Object?>) f) =>
        ((j[key] as List?) ?? [])
            .map((e) => f((e as Map).cast<String, Object?>()))
            .toList();
    return AttachResult(
      session: j['session'] == null
          ? null
          : SessionInfo.fromJson((j['session'] as Map).cast<String, Object?>()),
      clientId: _asString(j['client_id']),
      clients: list('clients', ClientInfo.fromJson),
      ptys: list('ptys', PtyInfo.fromJson),
      views: list('views', ViewInfo.fromJson),
      activeView: _asString(j['active_view']),
      lastSeq: _asInt(j['last_seq']),
      theme: _asString(j['theme']),
    );
  }
}

class MotifNotification {
  final String title;
  final String body;
  final String? sessionId;
  final String kind;

  const MotifNotification({
    required this.title,
    required this.body,
    this.sessionId,
    required this.kind,
  });

  factory MotifNotification.fromJson(Map<String, Object?> j) =>
      MotifNotification(
        title: (j['title'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        sessionId: _asString(j['session_id']),
        kind: (j['kind'] as String?) ?? '',
      );
}
