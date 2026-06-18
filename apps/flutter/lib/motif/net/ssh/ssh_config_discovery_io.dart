/// Local OpenSSH config and private-key discovery.
library;

import 'dart:io';

class SshConfigHost {
  const SshConfigHost({
    required this.alias,
    required this.hostName,
    this.user,
    this.port,
    this.identityFile,
  });

  final String alias;
  final String hostName;
  final String? user;
  final int? port;
  final String? identityFile;

  String get effectiveHost => hostName.isEmpty ? alias : hostName;
}

class SshIdentity {
  const SshIdentity({
    required this.path,
    required this.name,
    required this.contents,
  });

  final String path;
  final String name;
  final String contents;
}

class SshConfigSnapshot {
  const SshConfigSnapshot({required this.hosts, required this.identities});

  final List<SshConfigHost> hosts;
  final List<SshIdentity> identities;
}

class SshConfigDiscovery {
  const SshConfigDiscovery({String? homeDir}) : _homeDirOverride = homeDir;

  final String? _homeDirOverride;

  Future<SshConfigSnapshot> load() async {
    final home = _homeDirOverride ?? _homeDir();
    if (home == null || home.isEmpty) {
      return const SshConfigSnapshot(hosts: [], identities: []);
    }
    final sshDir = Directory('$home/.ssh');
    final hosts = await _loadHosts(home, sshDir);
    final identities = await _loadIdentities(home, sshDir, hosts);
    return SshConfigSnapshot(hosts: hosts, identities: identities);
  }

  static String? _homeDir() =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  static Future<List<SshConfigHost>> _loadHosts(
    String home,
    Directory sshDir,
  ) async {
    final config = File('${sshDir.path}/config');
    if (!await config.exists()) return const [];
    final text = await config.readAsString();
    return parseConfig(text, homeDir: home, sshDir: sshDir.path);
  }

  static List<SshConfigHost> parseConfig(
    String text, {
    required String homeDir,
    String? sshDir,
  }) {
    final hosts = <SshConfigHost>[];
    var aliases = <String>[];
    var hostName = '';
    String? user;
    int? port;
    String? identityFile;

    void flush() {
      if (aliases.isEmpty) return;
      for (final alias in aliases) {
        if (_isSelectableHost(alias)) {
          hosts.add(
            SshConfigHost(
              alias: alias,
              hostName: hostName.isEmpty ? alias : hostName,
              user: user,
              port: port,
              identityFile: identityFile,
            ),
          );
        }
      }
    }

    for (final rawLine in text.split('\n')) {
      final line = _stripComment(rawLine).trim();
      if (line.isEmpty) continue;
      final parts = _splitSshWords(line);
      if (parts.isEmpty) continue;
      final key = parts.first.toLowerCase();
      final values = parts.skip(1).toList();
      if (key == 'host') {
        flush();
        aliases = values;
        hostName = '';
        user = null;
        port = null;
        identityFile = null;
        continue;
      }
      if (aliases.isEmpty || values.isEmpty) continue;
      switch (key) {
        case 'hostname':
          hostName = values.first;
        case 'user':
          user = values.first;
        case 'port':
          final parsed = int.tryParse(values.first);
          if (parsed != null && parsed > 0 && parsed <= 65535) port = parsed;
        case 'identityfile':
          identityFile = _expandPath(
            values.first,
            homeDir: homeDir,
            sshDir: sshDir,
          );
      }
    }
    flush();
    hosts.sort((a, b) => a.alias.compareTo(b.alias));
    return hosts;
  }

  static Future<List<SshIdentity>> _loadIdentities(
    String home,
    Directory sshDir,
    List<SshConfigHost> hosts,
  ) async {
    final byPath = <String, SshIdentity>{};
    if (await sshDir.exists()) {
      await for (final ent in sshDir.list(followLinks: false)) {
        if (ent is! File) continue;
        final identity = await _readIdentity(ent);
        if (identity != null) byPath[identity.path] = identity;
      }
    }
    for (final host in hosts) {
      final path = host.identityFile;
      if (path == null || byPath.containsKey(path)) continue;
      final identity = await _readIdentity(File(path));
      if (identity != null) byPath[identity.path] = identity;
    }
    final values = byPath.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return values;
  }

  static Future<SshIdentity?> _readIdentity(File file) async {
    final name = _basename(file.path);
    if (name.endsWith('.pub') ||
        name == 'config' ||
        name.startsWith('known_hosts') ||
        name == 'authorized_keys') {
      return null;
    }
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size > 1024 * 1024) {
        return null;
      }
      final contents = await file.readAsString();
      if (!contents.contains('-----BEGIN') ||
          !contents.contains('PRIVATE KEY-----')) {
        return null;
      }
      return SshIdentity(path: file.path, name: name, contents: contents);
    } catch (_) {
      return null;
    }
  }

  static bool _isSelectableHost(String alias) =>
      alias.isNotEmpty &&
      !alias.contains('*') &&
      !alias.contains('?') &&
      !alias.startsWith('!');

  static String _stripComment(String line) {
    var quote = '';
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (quote.isNotEmpty) {
        if (ch == quote) quote = '';
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (ch == '#' && (i == 0 || line.codeUnitAt(i - 1) <= 32)) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  static List<String> _splitSshWords(String line) {
    final words = <String>[];
    final buf = StringBuffer();
    var quote = '';
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (escaped) {
        buf.write(ch);
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (quote.isNotEmpty) {
        if (ch == quote) {
          quote = '';
        } else {
          buf.write(ch);
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (ch.trim().isEmpty) {
        if (buf.isNotEmpty) {
          words.add(buf.toString());
          buf.clear();
        }
        continue;
      }
      buf.write(ch);
    }
    if (escaped) buf.write('\\');
    if (buf.isNotEmpty) words.add(buf.toString());
    return words;
  }

  static String _expandPath(
    String raw, {
    required String homeDir,
    String? sshDir,
  }) {
    if (raw == '~') return homeDir;
    if (raw.startsWith('~/')) return '$homeDir/${raw.substring(2)}';
    if (raw.startsWith(r'$HOME/')) return '$homeDir/${raw.substring(6)}';
    if (raw.startsWith('\${HOME}/')) return '$homeDir/${raw.substring(8)}';
    if (raw.startsWith('/')) return raw;
    final base = sshDir ?? '$homeDir/.ssh';
    return '$base/$raw';
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final i = normalized.lastIndexOf('/');
    return i < 0 ? normalized : normalized.substring(i + 1);
  }
}
