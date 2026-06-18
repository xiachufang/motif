import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/ssh/ssh_config_discovery_io.dart';

const _privateKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
test-key
-----END OPENSSH PRIVATE KEY-----
''';

void main() {
  group('SshConfigDiscovery', () {
    test('parses selectable Host entries from OpenSSH config', () {
      final hosts = SshConfigDiscovery.parseConfig(
        r'''
Host * *.internal !blocked
  User ignored

Host dev *.lan !deny
  HostName dev.example.com
  User fei
  Port 2222
  IdentityFile ~/.ssh/id_ed25519

Host staging
  HostName staging.example.com
  IdentityFile keys/staging.pem # comment after value
''',
        homeDir: '/home/fei',
        sshDir: '/home/fei/.ssh',
      );

      expect(hosts.map((h) => h.alias), ['dev', 'staging']);

      final dev = hosts.firstWhere((h) => h.alias == 'dev');
      expect(dev.hostName, 'dev.example.com');
      expect(dev.user, 'fei');
      expect(dev.port, 2222);
      expect(dev.identityFile, '/home/fei/.ssh/id_ed25519');

      final staging = hosts.firstWhere((h) => h.alias == 'staging');
      expect(staging.hostName, 'staging.example.com');
      expect(staging.identityFile, '/home/fei/.ssh/keys/staging.pem');
    });

    test('loads hosts and private keys from a home .ssh directory', () async {
      final home = await Directory.systemTemp.createTemp(
        'motif_ssh_home_test_',
      );
      addTearDown(() async {
        if (await home.exists()) await home.delete(recursive: true);
      });

      final sshDir = await Directory('${home.path}/.ssh').create();
      final keysDir = await Directory('${sshDir.path}/keys').create();
      final defaultKey = File('${sshDir.path}/id_ed25519');
      final deployKey = File('${keysDir.path}/deploy');
      await defaultKey.writeAsString(_privateKey);
      await deployKey.writeAsString(_privateKey);
      await File('${sshDir.path}/id_ed25519.pub').writeAsString('public-key');
      await File('${sshDir.path}/known_hosts').writeAsString('known-host');
      await File('${sshDir.path}/config').writeAsString('''
Host devbox
  HostName devbox.local
  User fei
  Port 2200
  IdentityFile ~/.ssh/id_ed25519

Host deploybox
  HostName deploy.example.com
  IdentityFile keys/deploy

Host *
  User ignored
''');

      final snapshot = await SshConfigDiscovery(homeDir: home.path).load();

      expect(snapshot.hosts.map((h) => h.alias), ['deploybox', 'devbox']);
      final devbox = snapshot.hosts.firstWhere((h) => h.alias == 'devbox');
      expect(devbox.hostName, 'devbox.local');
      expect(devbox.user, 'fei');
      expect(devbox.port, 2200);
      expect(devbox.identityFile, defaultKey.path);

      expect(snapshot.identities.map((i) => i.path), [
        deployKey.path,
        defaultKey.path,
      ]);
      expect(snapshot.identities.map((i) => i.name), ['deploy', 'id_ed25519']);
      expect(snapshot.identities.every((i) => i.contents == _privateKey), true);
    });
  });
}
