/// App configuration models: servers, terminal appearance, and quick commands.
///
/// These are local app-state models, not server wire types. Server profile JSON
/// contains only non-sensitive fields; credentials live in the secret store.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../terminal/terminal_key.dart';

// ─────────────────────────── servers ───────────────────────────

enum ServerKind {
  tailscale,
  direct,
  rendezvous,
  ssh,
  wsl;

  static ServerKind fromWire(Object? v) => switch (v) {
    'tailscale' => ServerKind.tailscale,
    'rendezvous' => ServerKind.rendezvous,
    'ssh' => ServerKind.ssh,
    'wsl' => ServerKind.wsl,
    _ => ServerKind.direct,
  };
}

enum SshAuthMethod {
  password,
  privateKey;

  static SshAuthMethod fromWire(Object? v) => switch (v) {
    'privateKey' => SshAuthMethod.privateKey,
    _ => SshAuthMethod.password,
  };
}

class MotifServer {
  final String id;
  final String name;
  final String host;
  final int port;
  final String scheme;
  final String token;
  final ServerKind kind;

  /// Rendezvous-only fields (`kind == ServerKind.rendezvous`), populated from a
  /// scanned pairing QR. [relay] is the relay endpoint (`host:port`); [psk] and
  /// [pubKey] are base64url-encoded 32-byte secrets — the pairing secret used
  /// to derive the rzv token, and `motifd`'s identity key pinned for E2E TLS.
  /// Empty for `direct` / `tailscale` servers, where `host`/`port` drive the
  /// connection instead.
  final String relay;
  final String psk;
  final String pubKey;

  /// Direct-only (`kind == ServerKind.direct`, from a no-relay pairing QR): all
  /// of motifd's advertised NIC addresses. The resolver probes them (TLS+pin)
  /// and connects to whichever is reachable. Empty for a manually-typed direct
  /// server (which uses [host] directly). [host] holds the first candidate for
  /// display.
  final List<String> directHosts;

  /// SSH-only fields (`kind == ServerKind.ssh`). [host]/[port] remain the
  /// motifd endpoint as seen from the SSH server (usually `127.0.0.1:7777`);
  /// [sshHost]/[sshPort] are the SSH login endpoint. Credentials are currently
  /// persisted with the rest of the server record; see `ServerStore`'s storage
  /// note for the secure-storage follow-up.
  final String sshHost;
  final int sshPort;
  final String sshUsername;
  final SshAuthMethod sshAuthMethod;
  final String sshPassword;
  final String sshPrivateKey;
  final String sshPrivateKeyPassphrase;
  final bool sshAutoInitialize;

  /// WSL-only (`kind == ServerKind.wsl`). Empty selects the user's default
  /// distribution; otherwise this is passed to `wsl.exe --distribution`.
  final String wslDistribution;

  const MotifServer({
    required this.id,
    required this.name,
    required this.host,
    this.port = 7777,
    this.scheme = 'http',
    this.token = '',
    this.kind = ServerKind.direct,
    this.relay = '',
    this.psk = '',
    this.pubKey = '',
    this.directHosts = const [],
    this.sshHost = '',
    this.sshPort = 22,
    this.sshUsername = '',
    this.sshAuthMethod = SshAuthMethod.password,
    this.sshPassword = '',
    this.sshPrivateKey = '',
    this.sshPrivateKeyPassphrase = '',
    this.sshAutoInitialize = false,
    this.wslDistribution = '',
  });

  String get endpoint => '$host:$port';
  String get origin => '$scheme://$endpoint';
  String get sshEndpoint => '$sshHost:$sshPort';
  String get wslLabel => wslDistribution.trim().isEmpty
      ? 'default distribution'
      : wslDistribution.trim();

  MotifServer copyWith({
    String? name,
    String? host,
    int? port,
    String? scheme,
    String? token,
    ServerKind? kind,
    String? relay,
    String? psk,
    String? pubKey,
    List<String>? directHosts,
    String? sshHost,
    int? sshPort,
    String? sshUsername,
    SshAuthMethod? sshAuthMethod,
    String? sshPassword,
    String? sshPrivateKey,
    String? sshPrivateKeyPassphrase,
    bool? sshAutoInitialize,
    String? wslDistribution,
  }) => MotifServer(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    scheme: _normalizeScheme(scheme ?? this.scheme),
    token: token ?? this.token,
    kind: kind ?? this.kind,
    relay: relay ?? this.relay,
    psk: psk ?? this.psk,
    pubKey: pubKey ?? this.pubKey,
    directHosts: directHosts ?? this.directHosts,
    sshHost: sshHost ?? this.sshHost,
    sshPort: sshPort ?? this.sshPort,
    sshUsername: sshUsername ?? this.sshUsername,
    sshAuthMethod: sshAuthMethod ?? this.sshAuthMethod,
    sshPassword: sshPassword ?? this.sshPassword,
    sshPrivateKey: sshPrivateKey ?? this.sshPrivateKey,
    sshPrivateKeyPassphrase:
        sshPrivateKeyPassphrase ?? this.sshPrivateKeyPassphrase,
    sshAutoInitialize: sshAutoInitialize ?? this.sshAutoInitialize,
    wslDistribution: wslDistribution ?? this.wslDistribution,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    if (scheme != 'http') 'scheme': scheme,
    'kind': kind.name,
    if (relay.isNotEmpty) 'relay': relay,
    if (pubKey.isNotEmpty) 'pubKey': pubKey,
    if (directHosts.isNotEmpty) 'directHosts': directHosts,
    if (kind == ServerKind.ssh && sshHost.isNotEmpty) 'sshHost': sshHost,
    if (kind == ServerKind.ssh && sshPort != 22) 'sshPort': sshPort,
    if (kind == ServerKind.ssh && sshUsername.isNotEmpty)
      'sshUsername': sshUsername,
    if (kind == ServerKind.ssh && sshAuthMethod != SshAuthMethod.password)
      'sshAuthMethod': sshAuthMethod.name,
    if (kind == ServerKind.ssh && sshAutoInitialize)
      'sshAutoInitialize': sshAutoInitialize,
    if (kind == ServerKind.wsl && wslDistribution.isNotEmpty)
      'wslDistribution': wslDistribution,
  };

  factory MotifServer.fromJson(Map<String, Object?> j) {
    final kind = ServerKind.fromWire(j['kind']);
    final relay = (j['relay'] as String?) ?? '';
    // Repair profiles created by older clients, which stored a bare relay
    // hostname with the generic motifd port 7777. Rendezvous transport uses
    // `relay`, so derive its display host/port from the same WSS parser too.
    final relayEndpoint = kind == ServerKind.rendezvous
        ? splitRelayEndpoint(relay)
        : null;
    return MotifServer(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      host: relayEndpoint?.host ?? (j['host'] as String?) ?? '',
      port: relayEndpoint?.port ?? (j['port'] as num?)?.toInt() ?? 7777,
      scheme: _normalizeScheme(j['scheme'] as String?),
      kind: kind,
      relay: relay,
      pubKey: (j['pubKey'] as String?) ?? '',
      directHosts:
          (j['directHosts'] as List?)?.whereType<String>().toList() ?? const [],
      sshHost: (j['sshHost'] as String?) ?? '',
      sshPort: (j['sshPort'] as num?)?.toInt() ?? 22,
      sshUsername: (j['sshUsername'] as String?) ?? '',
      sshAuthMethod: SshAuthMethod.fromWire(j['sshAuthMethod']),
      sshAutoInitialize: j['sshAutoInitialize'] == true,
      wslDistribution: (j['wslDistribution'] as String?) ?? '',
    );
  }

  static String _normalizeScheme(String? value) =>
      value == 'https' ? 'https' : 'http';

  /// Split a `host:port` endpoint. Returns null when it isn't a valid pair
  /// (no colon, empty host, or an out-of-range/non-numeric port). Shared by
  /// pairing (`toServer`) and the rendezvous transport resolver.
  static (String, int)? splitHostPort(String s) {
    final i = s.lastIndexOf(':');
    if (i <= 0 || i == s.length - 1) return null;
    final host = s.substring(0, i);
    final port = int.tryParse(s.substring(i + 1));
    if (port == null || port <= 0 || port > 65535) return null;
    return (host, port);
  }

  /// Parse a relay endpoint. Bare `host:port` implies WSS; explicit `ws://`
  /// is useful for local testing and `wss://` may omit the standard port. A
  /// bare hostname also implies WSS on port 443, matching motifd's parser.
  static ({String scheme, String host, int port})? splitRelayEndpoint(
    String value,
  ) {
    final s = value.trim();
    if (s.isEmpty) return null;
    final candidate = s.contains('://') ? s : 'wss://$s';
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        (uri.scheme != 'ws' && uri.scheme != 'wss') ||
        uri.host.isEmpty) {
      return null;
    }
    final port = uri.hasPort ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
    return (scheme: uri.scheme, host: uri.host, port: port);
  }

  static String encodeList(List<MotifServer> servers) =>
      jsonEncode(servers.map((s) => s.toJson()).toList());

  static List<MotifServer> decodeList(String raw) {
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .map((e) => MotifServer.fromJson((e as Map).cast<String, Object?>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

// ─────────────────────────── terminal settings ───────────────────────────

enum TerminalThemeSetting {
  system('System'),
  light('Light'),
  dark('Dark');

  final String label;
  const TerminalThemeSetting(this.label);

  static TerminalThemeSetting fromWire(Object? v) => switch (v) {
    'light' => TerminalThemeSetting.light,
    'dark' => TerminalThemeSetting.dark,
    _ => TerminalThemeSetting.system,
  };
}

class TerminalSettings {
  /// Font size in points; range 8–28, default 13.
  final double fontSize;
  final TerminalThemeSetting theme;

  const TerminalSettings({
    this.fontSize = defaultFontSize,
    this.theme = TerminalThemeSetting.system,
  });

  static const double defaultFontSize = 13;
  static const double minFontSize = 8;
  static const double maxFontSize = 28;

  TerminalSettings copyWith({double? fontSize, TerminalThemeSetting? theme}) =>
      TerminalSettings(
        fontSize: (fontSize ?? this.fontSize).clamp(minFontSize, maxFontSize),
        theme: theme ?? this.theme,
      );

  Map<String, Object?> toJson() => {'fontSize': fontSize, 'theme': theme.name};

  factory TerminalSettings.fromJson(Map<String, Object?> j) => TerminalSettings(
    fontSize: ((j['fontSize'] as num?)?.toDouble() ?? defaultFontSize).clamp(
      minFontSize,
      maxFontSize,
    ),
    theme: TerminalThemeSetting.fromWire(j['theme']),
  );
}

// ─────────────────────────── quick commands ───────────────────────────

enum QuickCommandKind { bytes, key, paste, ctrl, alt, shift, cd }

String newQuickCommandId([String prefix = 'cmd']) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}';

class QuickCommandModifiers {
  final bool ctrl;
  final bool alt;
  final bool shift;

  const QuickCommandModifiers({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  static const none = QuickCommandModifiers();

  bool get isEmpty => !ctrl && !alt && !shift;

  int get rawValue =>
      (ctrl ? 1 : 0) | (alt ? 1 << 1 : 0) | (shift ? 1 << 2 : 0);

  /// Compact glyph string in canonical order (⌃⌥⇧).
  String get glyphs {
    final sb = StringBuffer();
    if (ctrl) sb.write('⌃');
    if (alt) sb.write('⌥');
    if (shift) sb.write('⇧');
    return sb.toString();
  }

  List<String> get names => [
    if (ctrl) 'ctrl',
    if (alt) 'alt',
    if (shift) 'shift',
  ];

  Map<String, Object?> toJson() => {'ctrl': ctrl, 'alt': alt, 'shift': shift};

  factory QuickCommandModifiers.fromJson(Map<String, Object?> j) {
    final raw = (j['rawValue'] as num?)?.toInt();
    if (raw != null) {
      return QuickCommandModifiers(
        ctrl: raw & 1 != 0,
        alt: raw & (1 << 1) != 0,
        shift: raw & (1 << 2) != 0,
      );
    }
    return QuickCommandModifiers(
      ctrl: (j['ctrl'] as bool?) ?? false,
      alt: (j['alt'] as bool?) ?? false,
      shift: (j['shift'] as bool?) ?? false,
    );
  }
}

class QuickCommand {
  final String id;
  final String label;
  final String? symbol;
  final Uint8List payload;
  final String? keyId;
  final bool sendImmediately;
  final QuickCommandKind kind;
  final QuickCommandModifiers modifiers;

  QuickCommand({
    required this.id,
    required this.label,
    this.symbol,
    Uint8List? payload,
    this.keyId,
    this.sendImmediately = true,
    this.kind = QuickCommandKind.bytes,
    this.modifiers = QuickCommandModifiers.none,
  }) : payload = payload ?? Uint8List(0);

  factory QuickCommand.text(
    String id,
    String label,
    String text, {
    String? symbol,
    bool sendImmediately = true,
    QuickCommandModifiers modifiers = QuickCommandModifiers.none,
  }) => QuickCommand(
    id: id,
    label: label,
    symbol: symbol,
    payload: Uint8List.fromList(utf8.encode(text)),
    sendImmediately: sendImmediately,
    modifiers: modifiers,
  );

  factory QuickCommand.bytes(
    String id,
    String label,
    List<int> bytes, {
    String? symbol,
    bool sendImmediately = true,
    QuickCommandModifiers modifiers = QuickCommandModifiers.none,
  }) => QuickCommand(
    id: id,
    label: label,
    symbol: symbol,
    payload: Uint8List.fromList(bytes),
    sendImmediately: sendImmediately,
    modifiers: modifiers,
  );

  factory QuickCommand.key(
    String id,
    String label,
    String keyId, {
    String? symbol,
    QuickCommandModifiers modifiers = QuickCommandModifiers.none,
  }) => QuickCommand(
    id: id,
    label: label,
    symbol: symbol,
    payload: _legacyQuickKeyPayload(keyId, modifiers),
    keyId: keyId,
    kind: QuickCommandKind.key,
    modifiers: modifiers,
  );

  factory QuickCommand.paste(String id, {String label = 'Paste'}) =>
      QuickCommand(
        id: id,
        label: label,
        symbol: 'doc.on.clipboard',
        kind: QuickCommandKind.paste,
      );

  factory QuickCommand.ctrlModifier(String id) => QuickCommand(
    id: id,
    label: 'Ctrl',
    symbol: 'control',
    kind: QuickCommandKind.ctrl,
  );

  factory QuickCommand.altModifier(String id) => QuickCommand(
    id: id,
    label: 'Alt',
    symbol: 'option',
    kind: QuickCommandKind.alt,
  );

  factory QuickCommand.shiftModifier(String id) => QuickCommand(
    id: id,
    label: 'Shift',
    symbol: 'shift',
    kind: QuickCommandKind.shift,
  );

  factory QuickCommand.cd(String id) => QuickCommand(
    id: id,
    label: 'cd',
    symbol: 'arrow.turn.down.right',
    kind: QuickCommandKind.cd,
  );

  QuickCommand copyWith({
    String? id,
    String? label,
    String? symbol,
    Uint8List? payload,
    String? keyId,
    bool? sendImmediately,
    QuickCommandKind? kind,
    QuickCommandModifiers? modifiers,
  }) => QuickCommand(
    id: id ?? this.id,
    label: label ?? this.label,
    symbol: symbol ?? this.symbol,
    payload: payload ?? Uint8List.fromList(this.payload),
    keyId: keyId ?? this.keyId,
    sendImmediately: sendImmediately ?? this.sendImmediately,
    kind: kind ?? this.kind,
    modifiers: modifiers ?? this.modifiers,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'symbol': symbol,
    'payload_b64': base64Encode(payload),
    'keyId': keyId,
    'sendImmediately': sendImmediately,
    'kind': kind.name,
    'modifiers': modifiers.toJson(),
  };

  factory QuickCommand.fromJson(Map<String, Object?> j) {
    final id = (j['id'] as String?) ?? '';
    final label = (j['label'] as String?) ?? '';
    final symbol = j['symbol'] as String?;
    final payload = _decodeQuickCommandPayload(j);
    final kind = QuickCommandKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => QuickCommandKind.bytes,
    );
    final modifiers = j['modifiers'] == null
        ? QuickCommandModifiers.none
        : QuickCommandModifiers.fromJson(
            (j['modifiers'] as Map).cast<String, Object?>(),
          );
    final migrated = kind == QuickCommandKind.bytes
        ? _migrateLegacyQuickKey(
            label: label,
            symbol: symbol,
            payload: payload,
            modifiers: modifiers,
          )
        : null;
    final requestedKeyId = migrated?.keyId ?? j['keyId'] as String?;
    final keySpec = terminalKeySpecForId(requestedKeyId);
    final semanticKey =
        (migrated != null || kind == QuickCommandKind.key) && keySpec != null;
    final effectiveModifiers = migrated?.modifiers ?? modifiers;
    return QuickCommand(
      id: id,
      label: label,
      symbol: symbol,
      payload: semanticKey
          ? _legacyQuickKeyPayload(requestedKeyId!, effectiveModifiers)
          : payload,
      keyId: semanticKey ? requestedKeyId : null,
      sendImmediately: (j['sendImmediately'] as bool?) ?? true,
      // A key id introduced by a newer app can still use its persisted legacy
      // payload instead of becoming an inert chip on this version.
      kind: semanticKey
          ? QuickCommandKind.key
          : kind == QuickCommandKind.key
          ? QuickCommandKind.bytes
          : kind,
      modifiers: effectiveModifiers,
    );
  }
}

Uint8List _legacyQuickKeyPayload(
  String keyId,
  QuickCommandModifiers modifiers,
) {
  if (keyId == TerminalKeyIds.tab && modifiers.shift) {
    return Uint8List.fromList(const [0x1b, 0x5b, 0x5a]);
  }
  return Uint8List.fromList(
    terminalKeySpecForId(keyId)?.legacyBytes ?? const <int>[],
  );
}

({String keyId, QuickCommandModifiers modifiers})? _migrateLegacyQuickKey({
  required String label,
  required String? symbol,
  required Uint8List payload,
  required QuickCommandModifiers modifiers,
}) {
  final match = legacyTerminalKeyForBytes(payload);
  if (match == null) return null;

  // Multi-byte payloads were emitted only by the old key picker. Single-byte
  // payloads are ambiguous with text snippets, so migrate those only when a
  // known key label/icon or explicit modifiers establish that they are keys.
  // In particular, old seeded `|`, `/`, `-`, and `~` entries are snippets.
  final keyLabel =
      label == 'Tab' ||
      label == 'Esc' ||
      label == 'Enter' ||
      label == '⏎' ||
      label == 'Backspace' ||
      label == 'Bksp' ||
      label == '^C' ||
      label == '^D';
  final keySymbol =
      symbol == 'arrow.up' ||
      symbol == 'arrow.down' ||
      symbol == 'arrow.left' ||
      symbol == 'arrow.right' ||
      symbol == 'arrow.right.to.line' ||
      symbol == 'delete.left' ||
      symbol == 'delete.right';
  if (payload.length == 1 && !keyLabel && !keySymbol && modifiers.isEmpty) {
    return null;
  }

  return (
    keyId: match.keyId,
    modifiers: QuickCommandModifiers(
      ctrl: modifiers.ctrl || match.ctrl,
      alt: modifiers.alt || match.alt,
      shift: modifiers.shift || match.shift,
    ),
  );
}

Uint8List _decodeQuickCommandPayload(Map<String, Object?> j) {
  final encoded = j['payload_b64'] as String?;
  if (encoded == null) return Uint8List(0);
  return base64Decode(encoded);
}

class QuickCommandSet {
  final String id;
  final String name;
  final List<String> matches;
  final List<QuickCommand> commands;

  const QuickCommandSet({
    required this.id,
    required this.name,
    required this.matches,
    required this.commands,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'matches': matches,
    'commands': commands.map((c) => c.toJson()).toList(),
  };

  factory QuickCommandSet.fromJson(Map<String, Object?> j) => QuickCommandSet(
    id: (j['id'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    matches: ((j['matches'] as List?) ?? []).map((e) => '$e').toList(),
    commands: ((j['commands'] as List?) ?? [])
        .map((e) => QuickCommand.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
  );
}

/// Legacy byte sequences retained only for persisted-data migration and older
/// callers. New key commands store a semantic [TerminalKeyIds] identifier.
class QuickKeys {
  static const esc = [0x1b];
  static const tab = [0x09];
  static const backTab = [0x1b, 0x5b, 0x5a]; // CSI Z (Shift+Tab)
  static const enter = [0x0d];
  static const backspace = [0x7f];
  static const ctrlC = [0x03];
  static const ctrlD = [0x04];
  static const up = [0x1b, 0x5b, 0x41];
  static const down = [0x1b, 0x5b, 0x42];
  static const right = [0x1b, 0x5b, 0x43];
  static const left = [0x1b, 0x5b, 0x44];
}

/// Default global quick-command list (front-loaded by frequency), mirroring the
/// iOS seed in QuickCommandStore.
List<QuickCommand> defaultQuickCommands() {
  var n = 0;
  String nextId() => 'seed-${n++}';
  return [
    QuickCommand.ctrlModifier(nextId()),
    QuickCommand.key(
      nextId(),
      'Tab',
      TerminalKeyIds.tab,
      symbol: 'arrow.right.to.line',
    ),
    QuickCommand.key(nextId(), 'Esc', TerminalKeyIds.escape),
    QuickCommand.key(nextId(), '↑', TerminalKeyIds.arrowUp, symbol: 'arrow.up'),
    QuickCommand.key(
      nextId(),
      '↓',
      TerminalKeyIds.arrowDown,
      symbol: 'arrow.down',
    ),
    QuickCommand.key(
      nextId(),
      '←',
      TerminalKeyIds.arrowLeft,
      symbol: 'arrow.left',
    ),
    QuickCommand.key(
      nextId(),
      '→',
      TerminalKeyIds.arrowRight,
      symbol: 'arrow.right',
    ),
    QuickCommand.key(
      nextId(),
      '^C',
      TerminalKeyIds.character('c'),
      modifiers: const QuickCommandModifiers(ctrl: true),
    ),
    QuickCommand.cd(nextId()),
    QuickCommand.text(nextId(), 'ls', 'ls\n'),
    QuickCommand.paste(nextId()),
    QuickCommand.key(
      nextId(),
      'Backspace',
      TerminalKeyIds.backspace,
      symbol: 'delete.left',
    ),
    QuickCommand.key(
      nextId(),
      '^D',
      TerminalKeyIds.character('d'),
      modifiers: const QuickCommandModifiers(ctrl: true),
    ),
    QuickCommand.altModifier(nextId()),
    QuickCommand.shiftModifier(nextId()),
    QuickCommand.text(nextId(), '|', '|'),
    QuickCommand.text(nextId(), '/', '/'),
    QuickCommand.text(nextId(), '-', '-'),
    QuickCommand.text(nextId(), '~', '~'),
    QuickCommand.text(nextId(), 'cd ..', 'cd ..\n'),
  ];
}

/// Default per-program command sets seeded alongside the global list. These ride
/// next to "Global" in QuickCommandSetsView and override it when the matching
/// agent CLI is the running program. Each set front-loads that agent's commonly
/// used slash commands, then the keys its TUI needs.
List<QuickCommandSet> defaultQuickCommandSets() => [
  _agentSet(
    id: 'set-claude',
    name: 'claude',
    matches: const ['claude'],
    slash: const ['/clear', '/resume', '/compact', '/model'],
  ),
  _agentSet(
    id: 'set-codex',
    name: 'codex',
    matches: const ['codex'],
    slash: const ['/new', '/clear', '/resume', '/diff', '/compact'],
  ),
];

/// Build a command set for an interactive coding-agent TUI: its frequent slash
/// commands (run on tap), then mode toggle, history nav, submit, interrupt,
/// paste. Slash chips type `<cmd>\n` so a single tap runs them.
QuickCommandSet _agentSet({
  required String id,
  required String name,
  required List<String> matches,
  required List<String> slash,
}) {
  var n = 0;
  String nextId() => '$id-${n++}';
  return QuickCommandSet(
    id: id,
    name: name,
    matches: matches,
    commands: [
      for (final cmd in slash) QuickCommand.text(nextId(), cmd, '$cmd\n'),
      QuickCommand.key(
        nextId(),
        '⇧Tab',
        TerminalKeyIds.tab,
        modifiers: const QuickCommandModifiers(shift: true),
      ),
      QuickCommand.key(nextId(), 'Esc', TerminalKeyIds.escape),
      QuickCommand.key(
        nextId(),
        '↑',
        TerminalKeyIds.arrowUp,
        symbol: 'arrow.up',
      ),
      QuickCommand.key(
        nextId(),
        '↓',
        TerminalKeyIds.arrowDown,
        symbol: 'arrow.down',
      ),
      QuickCommand.key(nextId(), '⏎', TerminalKeyIds.enter),
      QuickCommand.key(
        nextId(),
        '^C',
        TerminalKeyIds.character('c'),
        modifiers: const QuickCommandModifiers(ctrl: true),
      ),
      QuickCommand.paste(nextId()),
    ],
  );
}

/// Extract the program key (basename of first token) from a running command
/// string, mirroring `QuickCommandStore.programKey`.
String? programKey(String? running) {
  if (running == null) return null;
  final trimmed = running.trim();
  if (trimmed.isEmpty) return null;
  final firstToken = trimmed.split(RegExp(r'\s+')).first;
  final base = firstToken.split('/').last;
  return base.isEmpty ? null : base;
}
