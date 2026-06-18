import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/connection_state.dart';
import 'package:motif/motif/ui/widgets/connection_details_dialog.dart';

void main() {
  test('summarizes SSH bootstrap diagnostics with exit code and stderr', () {
    const view = ServerConnectionViewState(
      statusLabel: 'SSH init failed',
      subtitle:
          '127.0.0.1:7777\n'
          'SSH auto-initialize failed while running remote bootstrap script.\n'
          'SSH: fei@bastion.example.com:22\n'
          'Remote motifd target: 127.0.0.1:7777\n'
          'Auth: password\n'
          'Remote bootstrap script failed before motifd became ready.\n'
          'Stage: running remote bootstrap script\n'
          'Exit code: 22\n'
          'stderr:\n'
          'latest release has no motifd asset for linux-armv7\n'
          'stdout:\n'
          'remote platform: linux-armv7',
      tone: ServerConnectionTone.danger,
      icon: ServerConnectionIconKind.ssh,
      showSpinner: false,
      canOpenTerminal: false,
      canInput: false,
      terminalOverlay: null,
      primaryAction: ServerConnectionAction.retry,
      tapAction: ServerConnectionAction.retry,
    );

    expect(hasConnectionDetails(view), isTrue);
    expect(
      connectionStatusSummary(view, fallback: 'Connection failed'),
      [
        'SSH auto-initialize failed while running remote bootstrap script.',
        'Exit code: 22',
        'latest release has no motifd asset for linux-armv7',
      ].join('\n'),
    );
  });

  test('does not mark ordinary attached session subtitles as diagnostics', () {
    const view = ServerConnectionViewState(
      statusLabel: 'Live',
      subtitle: '127.0.0.1:7777\nAttached: shell',
      tone: ServerConnectionTone.success,
      icon: ServerConnectionIconKind.direct,
      showSpinner: false,
      canOpenTerminal: true,
      canInput: true,
      terminalOverlay: null,
      primaryAction: ServerConnectionAction.openSessions,
      tapAction: ServerConnectionAction.openSessions,
    );

    expect(hasConnectionDetails(view), isFalse);
  });
}
