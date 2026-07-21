/// Persisted app stores: servers, terminal settings, quick commands.
///
/// Non-sensitive settings are backed by `shared_preferences`; credentials and
/// encryption keys are backed exclusively by the platform secret store.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/settings.dart';
import '../../platform/secret_store.dart';
import 'serialization.dart';
import 'store_view_models.dart';

abstract final class _Keys {
  static const servers = 'motif.servers.v1';
  static const activeServer = 'activeServerID';
  static const terminalSettings = 'motif.terminalSettings.v1';
  static const quickCommands = 'motif.quickCommands.v1';
  static const quickCommandSets = 'motif.quickCommands.sets.v1';
  static const pushEnabled = 'motif.push.enabled';
  static const pushMuted = 'motif.push.mutedSessions';
  static const pushInstanceServers = 'motif.push.instanceServers';
}

abstract final class _SecretKeys {
  static const pushEncKey = 'motif.push.encKey';
}

/// Push notification preferences + the per-device E2E key. The key is a random
/// 256-bit secret the server encrypts payloads with (AES-256-GCM); generated
/// once and persisted in the platform secret store.
class PushSettingsStore {
  final SharedPreferences _prefs;
  final PushPreferencesViewModel _state;
  Map<String, String> _instanceServers;
  late final String encKeyBase64;

  PushSettingsStore(this._prefs, {String? encKeyOverride})
    : _state = PushPreferencesViewModel(
        enabled: _prefs.getBool(_Keys.pushEnabled) ?? true,
        mutedSessions: ObservableSet(
          _prefs.getStringList(_Keys.pushMuted) ?? const [],
        ),
      ),
      _instanceServers = _loadInstanceServers(
        _prefs.getString(_Keys.pushInstanceServers),
      ) {
    encKeyBase64 = encKeyOverride ?? _generateKey();
  }

  /// Production loader. The synchronous constructor is retained for isolated
  /// tests that do not exercise persistence.
  static Future<PushSettingsStore> load(
    SharedPreferences prefs,
    SecretStore secrets,
  ) async {
    if (!secrets.isAvailable) {
      throw StateError('A platform secret store is required');
    }
    final stored = await secrets.read(_SecretKeys.pushEncKey);
    final key = stored ?? _generateKey();
    if (stored == null) await secrets.write(_SecretKeys.pushEncKey, key);
    return PushSettingsStore(prefs, encKeyOverride: key);
  }

  static String _generateKey() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List.generate(32, (_) => rng.nextInt(256)),
    );
    return base64Encode(bytes);
  }

  bool get enabled => _state.enabled;

  PushPreferencesViewModel get viewModel => _state;

  Set<String> get mutedSessions => _state.mutedSessions;

  bool isMuted(String session) => _state.mutedSessions.contains(session);

  /// The configured server last registered with this stable motifd instance.
  /// Kept across launches so a cold-start notification can select the right
  /// server before any clients have reconnected.
  String? serverIdForInstance(String instanceId) =>
      _instanceServers[instanceId];

  Future<void> bindInstanceToServer(String instanceId, String serverId) async {
    if (instanceId.isEmpty || serverId.isEmpty) return;
    if (_instanceServers[instanceId] == serverId) return;
    _instanceServers = {..._instanceServers, instanceId: serverId};
    await _persistInstanceServers();
  }

  Future<void> retainInstanceServers(Set<String> serverIds) async {
    final next = <String, String>{
      for (final entry in _instanceServers.entries)
        if (serverIds.contains(entry.value)) entry.key: entry.value,
    };
    if (mapEquals(next, _instanceServers)) return;
    _instanceServers = next;
    await _persistInstanceServers();
  }

  Future<void> setEnabled(bool v) async {
    if (_state.enabled == v) return;
    await _prefs.setBool(_Keys.pushEnabled, v);
    _state.enabled = v;
  }

  Future<void> setMuted(String session, bool muted) async {
    final next = {..._state.mutedSessions};
    if (muted) {
      next.add(session);
    } else {
      next.remove(session);
    }
    await _prefs.setStringList(_Keys.pushMuted, next.toList());
    if (muted) {
      _state.mutedSessions.add(session);
    } else {
      _state.mutedSessions.remove(session);
    }
  }

  Future<void> _persistInstanceServers() => _prefs.setString(
    _Keys.pushInstanceServers,
    jsonEncodeMap(_instanceServers),
  );

  static Map<String, String> _loadInstanceServers(String? raw) {
    if (raw == null) return {};
    final decoded = jsonDecodeMap(raw);
    if (decoded == null) return {};
    return <String, String>{
      for (final entry in decoded.entries)
        if (entry.value is String) entry.key: entry.value as String,
    };
  }
}

/// Configured servers + active selection.
class ServerStore {
  final SharedPreferences _prefs;
  final SecretStore secrets;
  final ServerProfilesViewModel _state;

  ServerStore(this._prefs, {this.secrets = const NoopSecretStore()})
    : _state = _loadState(_prefs);

  static ServerProfilesViewModel _loadState(SharedPreferences prefs) {
    final servers = MotifServer.decodeList(
      prefs.getString(_Keys.servers) ?? '[]',
    );
    var activeId = prefs.getString(_Keys.activeServer);
    if (activeId != null && !servers.any((server) => server.id == activeId)) {
      activeId = servers.isEmpty ? null : servers.first.id;
    }
    return ServerProfilesViewModel(
      servers: ObservableList(servers),
      activeId: activeId,
    );
  }

  /// Load profiles and hydrate their credentials from secure storage.
  static Future<ServerStore> load(
    SharedPreferences prefs, {
    required SecretStore secrets,
  }) async {
    final store = ServerStore(prefs, secrets: secrets);
    await store._hydrateSecrets();
    return store;
  }

  List<MotifServer> get servers => _state.servers;

  ServerProfilesViewModel get viewModel => _state;

  String? get activeId => _state.activeId;

  MotifServer? get activeServer {
    final activeId = _state.activeId;
    for (final server in _state.servers) {
      if (server.id == activeId) return server;
    }
    return null;
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _Keys.servers,
      MotifServer.encodeList(_state.servers),
    );
    final id = _state.activeId;
    if (id == null) {
      await _prefs.remove(_Keys.activeServer);
    } else {
      await _prefs.setString(_Keys.activeServer, id);
    }
  }

  Future<void> add(MotifServer server) async {
    await _writeSecrets(server);
    observationTransaction(() {
      _state.servers.add(server);
      _state.activeId ??= server.id;
    });
    await _persist();
  }

  Future<void> update(MotifServer server) async {
    await _writeSecrets(server);
    final index = _state.servers.indexWhere((item) => item.id == server.id);
    if (index >= 0) _state.servers[index] = server;
    await _persist();
  }

  Future<void> delete(String id) async {
    if (secrets.isAvailable) await secrets.delete(_serverSecretKey(id));
    observationTransaction(() {
      _state.servers.removeWhere((server) => server.id == id);
      if (_state.activeId == id) {
        _state.activeId = _state.servers.isEmpty
            ? null
            : _state.servers.first.id;
      }
    });
    await _persist();
  }

  Future<void> setActive(String id) async {
    if (_state.activeId == id) return;
    _state.activeId = id;
    await _persist();
  }

  Future<void> _hydrateSecrets() async {
    if (!secrets.isAvailable) {
      throw StateError('A platform secret store is required');
    }
    final hydrated = await Future.wait([
      for (final profile in _state.servers) _hydrateServer(profile),
    ]);
    _state.servers.replaceRange(0, _state.servers.length, hydrated);
  }

  Future<MotifServer> _hydrateServer(MotifServer profile) async {
    final raw = await secrets.read(_serverSecretKey(profile.id));
    final stored = raw == null ? null : jsonDecodeMap(raw);
    return stored == null ? profile : _withSecrets(profile, stored);
  }

  Future<void> _writeSecrets(MotifServer server) async {
    if (!secrets.isAvailable) return;
    final credentials = _credentialsJson(server);
    final key = _serverSecretKey(server.id);
    if (credentials.isEmpty) {
      await secrets.delete(key);
    } else {
      await secrets.write(key, jsonEncodeMap(credentials));
    }
  }

  static String _serverSecretKey(String id) => 'motif.server.credentials.$id';

  static Map<String, Object?> _credentialsJson(MotifServer server) => {
    if (server.token.isNotEmpty) 'token': server.token,
    if (server.psk.isNotEmpty) 'psk': server.psk,
    if (server.sshPassword.isNotEmpty) 'sshPassword': server.sshPassword,
    if (server.sshPrivateKey.isNotEmpty) 'sshPrivateKey': server.sshPrivateKey,
    if (server.sshPrivateKeyPassphrase.isNotEmpty)
      'sshPrivateKeyPassphrase': server.sshPrivateKeyPassphrase,
  };

  static MotifServer _withSecrets(
    MotifServer profile,
    Map<String, Object?> credentials,
  ) => profile.copyWith(
    token: credentials['token'] as String? ?? '',
    psk: credentials['psk'] as String? ?? '',
    sshPassword: credentials['sshPassword'] as String? ?? '',
    sshPrivateKey: credentials['sshPrivateKey'] as String? ?? '',
    sshPrivateKeyPassphrase:
        credentials['sshPrivateKeyPassphrase'] as String? ?? '',
  );
}

/// Terminal appearance (font + theme).
class TerminalSettingsStore {
  final SharedPreferences _prefs;
  final TerminalPreferencesViewModel _state;

  TerminalSettingsStore(this._prefs)
    : _state = TerminalPreferencesViewModel(
        settings: _load(_prefs.getString(_Keys.terminalSettings)),
      );

  static TerminalSettings _load(String? raw) {
    if (raw == null) return const TerminalSettings();
    try {
      return TerminalSettings.fromJson((jsonDecodeMap(raw)) ?? const {});
    } catch (_) {
      return const TerminalSettings();
    }
  }

  TerminalSettings get settings => _state.settings;

  TerminalPreferencesViewModel get viewModel => _state;

  Future<void> update(TerminalSettings next) async {
    if (_state.settings == next) return;
    await _prefs.setString(
      _Keys.terminalSettings,
      jsonEncodeMap(next.toJson()),
    );
    _state.settings = next;
  }

  Future<void> setFontSize(double v) =>
      update(_state.settings.copyWith(fontSize: v));
  Future<void> setTheme(TerminalThemeSetting t) =>
      update(_state.settings.copyWith(theme: t));
}

/// Global + per-program quick command lists.
class QuickCommandStore {
  final SharedPreferences _prefs;
  final QuickCommandViewModel _state;

  QuickCommandStore(this._prefs)
    : _state = QuickCommandViewModel(
        commands: ObservableList(
          _loadCommands(_prefs.getString(_Keys.quickCommands)),
        ),
        sets: ObservableList(
          _loadSets(_prefs.getString(_Keys.quickCommandSets)),
        ),
      );

  static List<QuickCommand> _loadCommands(String? raw) {
    if (raw == null) return defaultQuickCommands();
    final list = jsonDecodeList(raw);
    if (list == null || list.isEmpty) return defaultQuickCommands();
    return list
        .map((e) => QuickCommand.fromJson((e as Map).cast<String, Object?>()))
        .toList();
  }

  static List<QuickCommandSet> _loadSets(String? raw) {
    // Never persisted → seed the built-in agent presets. An explicit empty list
    // means the user cleared every set, so honor that and stay empty.
    if (raw == null) return defaultQuickCommandSets();
    final list = jsonDecodeList(raw);
    if (list == null) return [];
    return list
        .map(
          (e) => QuickCommandSet.fromJson((e as Map).cast<String, Object?>()),
        )
        .toList();
  }

  List<QuickCommand> get commands => _state.commands;

  List<QuickCommandSet> get sets => _state.sets;

  QuickCommandViewModel get viewModel => _state;

  /// Commands effective for the currently-running program (set override → global).
  List<QuickCommand> resolved(String? runningProgram) {
    final commands = _state.commands;
    final sets = _state.sets;
    final key = programKey(runningProgram);
    if (key != null) {
      for (final set in sets) {
        if (set.matches.contains(key)) return set.commands;
      }
    }
    return commands;
  }

  String? effectiveSetId(String? runningProgram) {
    final sets = _state.sets;
    final key = programKey(runningProgram);
    if (key == null) return null;
    for (final set in sets) {
      if (set.matches.contains(key)) return set.id;
    }
    return null;
  }

  Future<void> setGlobal(List<QuickCommand> cmds) async {
    _state.commands.replaceRange(0, _state.commands.length, cmds);
    // Notify synchronously (before the async disk write). ReorderableListView
    // expects the item list to update in the same frame as the reorder
    // callback; deferring the rebuild past `await` desyncs its internal
    // bookkeeping and makes items vanish on drop (worse on mobile). Persist
    // after.
    await _prefs.setString(
      _Keys.quickCommands,
      jsonEncodeList(cmds.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> add(QuickCommand cmd) => setGlobal([..._state.commands, cmd]);

  Future<void> update(QuickCommand cmd) => setGlobal([
    for (final c in _state.commands)
      if (c.id == cmd.id) cmd else c,
  ]);

  Future<void> removeAt(int index) {
    final next = [..._state.commands]..removeAt(index);
    return setGlobal(next);
  }

  /// For `ReorderableListView.onReorderItem`: `newIndex` is already adjusted for
  /// the removed item.
  Future<void> moveItem(int oldIndex, int newIndex) {
    final next = [..._state.commands];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    return setGlobal(next);
  }

  Future<void> resetToDefaults() => setGlobal(defaultQuickCommands());

  // ── per-program sets ──

  QuickCommandSet? setById(String id) {
    for (final s in _state.sets) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Commands for a scope: a set id, or null/`global` for the global list.
  List<QuickCommand> commandsForScope(String? setId) =>
      setId == null ? commands : (setById(setId)?.commands ?? const []);

  Future<void> _persistSets() async {
    await _prefs.setString(
      _Keys.quickCommandSets,
      jsonEncodeList(_state.sets.map((s) => s.toJson()).toList()),
    );
  }

  /// Create a set seeded from the current global commands. Returns its id.
  Future<String> createSet(String name, List<String> matches) async {
    final id = 'set-${_state.sets.length}-${name.hashCode}';
    _state.sets.add(
      QuickCommandSet(
        id: id,
        name: name,
        matches: matches,
        commands: [
          for (final command in _state.commands)
            command.copyWith(id: newQuickCommandId('copy')),
        ],
      ),
    );
    await _persistSets();
    return id;
  }

  Future<void> removeSet(String id) async {
    _state.sets.removeWhere((set) => set.id == id);
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
    final index = _state.sets.indexWhere((set) => set.id == id);
    if (index >= 0) _state.sets[index] = f(_state.sets[index]);
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
