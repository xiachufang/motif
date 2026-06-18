/// Remote motifd bootstrap over SSH.
///
/// The bootstrap installs a user-local `motifd` binary from the latest GitHub
/// Release when needed, then starts it with `nohup` so it survives the SSH
/// session used to initialize it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../../models/settings.dart';

class SshBootstrapper {
  static const String defaultRepository = 'xiachufang/motif';

  SshBootstrapper({
    required this.server,
    this.repository = defaultRepository,
    this.connectTimeout = const Duration(seconds: 15),
    this.runTimeout = const Duration(minutes: 4),
  });

  final MotifServer server;
  final String repository;
  final Duration connectTimeout;
  final Duration runTimeout;

  Future<void> ensureMotifd() async {
    final socket = await SSHSocket.connect(
      server.sshHost.trim(),
      server.sshPort,
      timeout: connectTimeout,
    );
    final client = SSHClient(
      socket,
      username: server.sshUsername.trim(),
      identities: _identities(),
      onPasswordRequest: _usesPassword ? () => server.sshPassword : null,
      onUserInfoRequest: _usesPassword
          ? (dynamic request) {
              final prompts = request.prompts as List<Object?>;
              return List<String>.filled(prompts.length, server.sshPassword);
            }
          : null,
    );
    try {
      await client.ping().timeout(connectTimeout);
      final result = await client
          .runWithResult(
            buildScript(
              repository: repository,
              remoteHost: server.host.trim(),
              remotePort: server.port,
              token: server.token,
            ),
          )
          .timeout(runTimeout);
      if (result.exitCode != 0) {
        final out = utf8.decode(result.output, allowMalformed: true).trim();
        throw SshBootstrapException(
          'remote motifd bootstrap failed'
          '${result.exitCode == null ? '' : ' (${result.exitCode})'}'
          '${out.isEmpty ? '' : ': $out'}',
        );
      }
    } finally {
      client.close();
    }
  }

  bool get _usesPassword => server.sshAuthMethod == SshAuthMethod.password;

  List<SSHKeyPair>? _identities() {
    if (server.sshAuthMethod != SshAuthMethod.privateKey) return null;
    final key = server.sshPrivateKey.trim();
    if (key.isEmpty) return null;
    return SSHKeyPair.fromPem(
      key,
      server.sshPrivateKeyPassphrase.isEmpty
          ? null
          : server.sshPrivateKeyPassphrase,
    );
  }

  static String buildScript({
    required String repository,
    required String remoteHost,
    required int remotePort,
    required String token,
  }) {
    final qRepository = _shQuote(repository);
    final qHost = _shQuote(remoteHost);
    final qPort = _shQuote('$remotePort');
    final qToken = _shQuote(token);
    return '''
set -eu

REPOSITORY=$qRepository
REMOTE_HOST=$qHost
REMOTE_PORT=$qPort
TOKEN_VALUE=$qToken

DATA_HOME=\${XDG_DATA_HOME:-"\$HOME/.local/share"}
STATE_HOME=\${XDG_STATE_HOME:-"\$HOME/.local/state"}
DATA_DIR="\$DATA_HOME/motif"
STATE_DIR="\$STATE_HOME/motif"
BIN_DIR="\$DATA_DIR/bin"
BIN="\$BIN_DIR/motifd"
TOKEN_FILE="\$DATA_DIR/motifd/token"
PID_FILE="\$STATE_DIR/motifd.pid"
LOG_FILE="\$STATE_DIR/motifd.log"
LISTEN="\$REMOTE_HOST:\$REMOTE_PORT"

download_to() {
  url="\$1"
  out="\$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "\$url" -o "\$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "\$out" "\$url"
  else
    echo "curl or wget is required to download motifd" >&2
    return 127
  fi
}

ping_motifd() {
  url="http://\$REMOTE_HOST:\$REMOTE_PORT/ping"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "\$url" 2>/dev/null | grep -q '"service":"motif-server"'
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- -T 2 "\$url" 2>/dev/null | grep -q '"service":"motif-server"'
  else
    return 1
  fi
}

if ping_motifd; then
  echo "motifd already running on \$LISTEN"
  exit 0
fi

mkdir -p "\$BIN_DIR" "\$STATE_DIR" "\$(dirname "\$TOKEN_FILE")"

if [ ! -x "\$BIN" ]; then
  os=\$(uname -s | tr '[:upper:]' '[:lower:]')
  case "\$os" in
    linux) platform=linux ;;
    darwin) platform=macos ;;
    *) echo "unsupported remote OS: \$os" >&2; exit 20 ;;
  esac
  machine=\$(uname -m)
  case "\$machine" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "unsupported remote arch: \$machine" >&2; exit 21 ;;
  esac

  tmp=\$(mktemp -d)
  trap 'rm -rf "\$tmp"' EXIT HUP INT TERM
  api="https://api.github.com/repos/\$REPOSITORY/releases/latest"
  download_to "\$api" "\$tmp/release.json"
  asset_url=\$(
    tr '{}[],' '\\n\\n\\n\\n' < "\$tmp/release.json" |
      sed -n "s|.*\\"browser_download_url\\"[[:space:]]*:[[:space:]]*\\"\\([^\\"]*motifd-[^\\"]*-\$platform-\$arch\\.tar\\.gz\\)\\".*|\\1|p" |
      head -n 1
  )
  if [ -z "\$asset_url" ]; then
    echo "latest release has no motifd asset for \$platform-\$arch" >&2
    exit 22
  fi
  download_to "\$asset_url" "\$tmp/motifd.tar.gz"
  tar -xzf "\$tmp/motifd.tar.gz" -C "\$tmp"
  found=\$(find "\$tmp" -type f -name motifd -print | head -n 1)
  if [ -z "\$found" ]; then
    echo "downloaded motifd archive did not contain motifd" >&2
    exit 23
  fi
  cp "\$found" "\$BIN"
  chmod 0755 "\$BIN"
  echo "installed motifd at \$BIN"
fi

if [ -n "\$TOKEN_VALUE" ]; then
  umask 077
  printf '%s\\n' "\$TOKEN_VALUE" > "\$TOKEN_FILE"
fi

if [ -f "\$PID_FILE" ]; then
  old_pid=\$(cat "\$PID_FILE" 2>/dev/null || true)
  if [ -n "\$old_pid" ] && kill -0 "\$old_pid" 2>/dev/null && ping_motifd; then
    echo "motifd already running on \$LISTEN"
    exit 0
  fi
fi

if [ -n "\$TOKEN_VALUE" ]; then
  nohup "\$BIN" --listen "\$LISTEN" --token-file "\$TOKEN_FILE" >>"\$LOG_FILE" 2>&1 </dev/null &
else
  nohup "\$BIN" --listen "\$LISTEN" >>"\$LOG_FILE" 2>&1 </dev/null &
fi
pid=\$!
printf '%s\\n' "\$pid" > "\$PID_FILE"

i=0
while [ "\$i" -lt 30 ]; do
  if ping_motifd; then
    echo "motifd started on \$LISTEN"
    exit 0
  fi
  if ! kill -0 "\$pid" 2>/dev/null; then
    echo "motifd exited during startup; log follows" >&2
    tail -n 80 "\$LOG_FILE" >&2 2>/dev/null || true
    exit 24
  fi
  i=\$((i + 1))
  sleep 1
done

echo "motifd did not become ready on \$LISTEN; log follows" >&2
tail -n 80 "\$LOG_FILE" >&2 2>/dev/null || true
exit 25
''';
  }

  static String _shQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";
}

class SshBootstrapException implements Exception {
  final String message;

  const SshBootstrapException(this.message);

  @override
  String toString() => message;
}
