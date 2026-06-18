/// Web stub for local SSH config/key discovery.
library;

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
  const SshConfigDiscovery({String? homeDir});

  Future<SshConfigSnapshot> load() async =>
      const SshConfigSnapshot(hosts: [], identities: []);
}
