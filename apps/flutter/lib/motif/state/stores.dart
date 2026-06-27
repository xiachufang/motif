/// Persisted app stores: servers, terminal settings, quick commands.
///
/// Ported from the iOS `*Store` types. Backed by `shared_preferences` (works on
/// all six target platforms). Server tokens and SSH credentials are sensitive;
/// on a hardened build they should move to platform secure storage
/// (Keychain/Keystore/DPAPI/libsecret) — tracked as a follow-up. For now
/// servers persist as JSON.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';

abstract final class _Keys {
  static const servers = 'motif.servers.v1';
  static const activeServer = 'activeServerID';
  static const terminalSettings = 'motif.terminalSettings.v1';
  static const quickCommands = 'motif.quickCommands.v1';
  static const quickCommandSets = 'motif.quickCommands.sets.v1';
  static const pushEnabled = 'motif.push.enabled';
  static const pushMuted = 'motif.push.mutedSessions';
  static const pushEncKey = 'motif.push.encKey';
}

/// Push notification preferences + the per-device E2E key. The key is a random
/// 256-bit secret the server encrypts payloads with (AES-256-GCM); generated
/// once and persisted. (On a hardened build it should live in platform secure
/// storage — Keychain/Keystore — rather than shared_preferences.)
class PushSettingsStore extends ChangeNotifier {
  final SharedPreferences _prefs;
  bool _enabled;
  Set<String> _muted;
  late final String encKeyBase64;

  PushSettingsStore(this._prefs)
    : _enabled = _prefs.getBool(_Keys.pushEnabled) ?? true,
      _muted = (_prefs.getStringList(_Keys.pushMuted) ?? const []).toSet() {
    final existing = _prefs.getString(_Keys.pushEncKey);
    if (existing != null) {
      encKeyBase64 = existing;
    } else {
      encKeyBase64 = _generateKey();
      _prefs.setString(_Keys.pushEncKey, encKeyBase64);
    }
  }

  static String _generateKey() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List.generate(32, (_) => rng.nextInt(256)),
    );
    return base64Encode(bytes);
  }

  bool get enabled => _enabled;
  Set<String> get mutedSessions => Set.unmodifiable(_muted);
  bool isMuted(String session) => _muted.contains(session);

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    await _prefs.setBool(_Keys.pushEnabled, v);
    notifyListeners();
  }

  Future<void> setMuted(String session, bool muted) async {
    if (muted) {
      _muted = {..._muted, session};
    } else {
      _muted = {..._muted}..remove(session);
    }
    await _prefs.setStringList(_Keys.pushMuted, _muted.toList());
    notifyListeners();
  }
}

/// Configured servers + active selection.
class ServerStore extends ChangeNotifier {
  final SharedPreferences _prefs;
  List<MotifServer> _servers;
  String? _activeId;

  ServerStore(this._prefs)
    : _servers = MotifServer.decodeList(
        _prefs.getString(_Keys.servers) ?? '[]',
      ),
      _activeId = _prefs.getString(_Keys.activeServer) {
    // Heal a dangling active id.
    if (_activeId != null && !_servers.any((s) => s.id == _activeId)) {
      _activeId = _servers.isEmpty ? null : _servers.first.id;
    }
  }

  List<MotifServer> get servers => List.unmodifiable(_servers);
  String? get activeId => _activeId;
  MotifServer? get activeServer {
    for (final s in _servers) {
      if (s.id == _activeId) return s;
    }
    return null;
  }

  Future<void> _persist() async {
    await _prefs.setString(_Keys.servers, MotifServer.encodeList(_servers));
    final id = _activeId;
    if (id == null) {
      await _prefs.remove(_Keys.activeServer);
    } else {
      await _prefs.setString(_Keys.activeServer, id);
    }
    notifyListeners();
  }

  Future<void> add(MotifServer server) async {
    _servers = [..._servers, server];
    _activeId ??= server.id;
    await _persist();
  }

  Future<void> update(MotifServer server) async {
    _servers = [
      for (final s in _servers)
        if (s.id == server.id) server else s,
    ];
    await _persist();
  }

  Future<void> delete(String id) async {
    _servers = _servers.where((s) => s.id != id).toList();
    if (_activeId == id) {
      _activeId = _servers.isEmpty ? null : _servers.first.id;
    }
    await _persist();
  }

  Future<void> setActive(String id) async {
    _activeId = id;
    await _persist();
  }
}

/// Terminal appearance (font + theme).
class TerminalSettingsStore extends ChangeNotifier {
  final SharedPreferences _prefs;
  TerminalSettings _settings;

  TerminalSettingsStore(this._prefs)
    : _settings = _load(_prefs.getString(_Keys.terminalSettings));

  static TerminalSettings _load(String? raw) {
    if (raw == null) return const TerminalSettings();
    try {
      return TerminalSettings.fromJson((jsonDecodeMap(raw)) ?? const {});
    } catch (_) {
      return const TerminalSettings();
    }
  }

  TerminalSettings get settings => _settings;

  Future<void> update(TerminalSettings next) async {
    _settings = next;
    await _prefs.setString(
      _Keys.terminalSettings,
      jsonEncodeMap(next.toJson()),
    );
    notifyListeners();
  }

  Future<void> setFontSize(double v) => update(_settings.copyWith(fontSize: v));
  Future<void> setTheme(TerminalThemeSetting t) =>
      update(_settings.copyWith(theme: t));
}

/// Global + per-program quick command lists.
class QuickCommandStore extends ChangeNotifier {
  final SharedPreferences _prefs;
  List<QuickCommand> _commands;
  List<QuickCommandSet> _sets;

  QuickCommandStore(this._prefs)
    : _commands = _loadCommands(_prefs.getString(_Keys.quickCommands)),
      _sets = _loadSets(_prefs.getString(_Keys.quickCommandSets));

  static List<QuickCommand> _loadCommands(String? raw) {
    if (raw == null) return defaultQuickCommands();
    final list = jsonDecodeList(raw);
    if (list == null || list.isEmpty) return defaultQuickCommands();
    return list
        .map((e) => QuickCommand.fromJson((e as Map).cast<String, Object?>()))
        .toList();
  }

  static List<QuickCommandSet> _loadSets(String? raw) {
    final list = raw == null ? null : jsonDecodeList(raw);
    if (list == null) return [];
    return list
        .map(
          (e) => QuickCommandSet.fromJson((e as Map).cast<String, Object?>()),
        )
        .toList();
  }

  List<QuickCommand> get commands => List.unmodifiable(_commands);
  List<QuickCommandSet> get sets => List.unmodifiable(_sets);

  /// Commands effective for the currently-running program (set override → global).
  List<QuickCommand> resolved(String? runningProgram) {
    final key = programKey(runningProgram);
    if (key != null) {
      for (final set in _sets) {
        if (set.matches.contains(key)) return set.commands;
      }
    }
    return _commands;
  }

  String? effectiveSetId(String? runningProgram) {
    final key = programKey(runningProgram);
    if (key == null) return null;
    for (final set in _sets) {
      if (set.matches.contains(key)) return set.id;
    }
    return null;
  }

  Future<void> setGlobal(List<QuickCommand> cmds) async {
    _commands = cmds;
    // Notify synchronously (before the async disk write). ReorderableListView
    // expects the item list to update in the same frame as the reorder
    // callback; deferring the rebuild past `await` desyncs its internal
    // bookkeeping and makes items vanish on drop (worse on mobile). Persist
    // after.
    notifyListeners();
    await _prefs.setString(
      _Keys.quickCommands,
      jsonEncodeList(cmds.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> add(QuickCommand cmd) => setGlobal([..._commands, cmd]);

  Future<void> update(QuickCommand cmd) => setGlobal([
    for (final c in _commands)
      if (c.id == cmd.id) cmd else c,
  ]);

  Future<void> removeAt(int index) {
    final next = [..._commands]..removeAt(index);
    return setGlobal(next);
  }

  /// For `ReorderableListView.onReorderItem`: `newIndex` is already adjusted for
  /// the removed item.
  Future<void> moveItem(int oldIndex, int newIndex) {
    final next = [..._commands];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    return setGlobal(next);
  }

  Future<void> resetToDefaults() => setGlobal(defaultQuickCommands());

  // ── per-program sets ──

  QuickCommandSet? setById(String id) {
    for (final s in _sets) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Commands for a scope: a set id, or null/`global` for the global list.
  List<QuickCommand> commandsForScope(String? setId) =>
      setId == null ? _commands : (setById(setId)?.commands ?? const []);

  Future<void> _persistSets() async {
    // Notify synchronously before persisting (same reorder-frame requirement as
    // setGlobal — see note there).
    notifyListeners();
    await _prefs.setString(
      _Keys.quickCommandSets,
      jsonEncodeList(_sets.map((s) => s.toJson()).toList()),
    );
  }

  /// Create a set seeded from the current global commands. Returns its id.
  Future<String> createSet(String name, List<String> matches) async {
    final id = 'set-${_sets.length}-${name.hashCode}';
    _sets = [
      ..._sets,
      QuickCommandSet(
        id: id,
        name: name,
        matches: matches,
        commands: [
          for (final command in _commands)
            command.copyWith(id: newQuickCommandId('copy')),
        ],
      ),
    ];
    await _persistSets();
    return id;
  }

  Future<void> removeSet(String id) async {
    _sets = _sets.where((s) => s.id != id).toList();
    await _persistSets();
  }

  QuickCommandSet _replaceSet(
    QuickCommandSet s, {
    String? name,
    List<String>? matches,
    List<QuickCommand>? commands,
  }) => QuickCommandSet(
    id: s.id,
    name: name ?? s.name,
    matches: matches ?? s.matches,
    commands: commands ?? s.commands,
  );

  Future<void> _mutateSet(
    String id,
    QuickCommandSet Function(QuickCommandSet) f,
  ) {
    _sets = [
      for (final s in _sets)
        if (s.id == id) f(s) else s,
    ];
    return _persistSets();
  }

  Future<void> renameSet(String id, String name) =>
      _mutateSet(id, (s) => _replaceSet(s, name: name));

  Future<void> updateMatches(String id, List<String> matches) =>
      _mutateSet(id, (s) => _replaceSet(s, matches: matches));

  /// Scope-aware command list setter (null scope = global).
  Future<void> setScopeCommands(String? setId, List<QuickCommand> cmds) {
    if (setId == null) return setGlobal(cmds);
    return _mutateSet(setId, (s) => _replaceSet(s, commands: cmds));
  }

  Future<void> addTo(String? setId, QuickCommand cmd) =>
      setScopeCommands(setId, [...commandsForScope(setId), cmd]);

  Future<void> updateIn(String? setId, QuickCommand cmd) =>
      setScopeCommands(setId, [
        for (final c in commandsForScope(setId))
          if (c.id == cmd.id) cmd else c,
      ]);

  Future<void> removeAtIn(String? setId, int index) {
    final next = [...commandsForScope(setId)]..removeAt(index);
    return setScopeCommands(setId, next);
  }

  Future<void> moveItemIn(String? setId, int oldIndex, int newIndex) {
    final next = [...commandsForScope(setId)];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    return setScopeCommands(setId, next);
  }
}

// ── small JSON helpers ──

Map<String, Object?>? jsonDecodeMap(String raw) {
  final v = _tryDecode(raw);
  return v is Map ? v.cast<String, Object?>() : null;
}

List<Object?>? jsonDecodeList(String raw) {
  final v = _tryDecode(raw);
  return v is List ? v : null;
}

String jsonEncodeMap(Map<String, Object?> m) => jsonEncode(m);
String jsonEncodeList(List<Object?> l) => jsonEncode(l);

Object? _tryDecode(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}
