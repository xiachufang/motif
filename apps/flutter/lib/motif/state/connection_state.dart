import '../models/settings.dart';
import '../platform/services.dart';

enum ConnectionBlockerKind {
  tailscaleStopped,
  tailscaleStarting,
  tailscaleNeedsAuth,
  tailscaleDegraded,
  tailscaleFailed,
  transportUnavailable,
}

class ConnectionBlocker {
  final ConnectionBlockerKind kind;
  final String message;
  final TailscaleStatus? tailscaleStatus;

  const ConnectionBlocker({
    required this.kind,
    required this.message,
    this.tailscaleStatus,
  });

  factory ConnectionBlocker.tailscale(TailscaleState state) {
    return switch (state.status) {
      TailscaleStatus.stopped => const ConnectionBlocker(
        kind: ConnectionBlockerKind.tailscaleStopped,
        message: 'Start Tailscale to reach tailnet servers.',
        tailscaleStatus: TailscaleStatus.stopped,
      ),
      TailscaleStatus.starting => ConnectionBlocker(
        kind: ConnectionBlockerKind.tailscaleStarting,
        message: state.detail ?? 'Waiting for Tailscale to finish connecting.',
        tailscaleStatus: TailscaleStatus.starting,
      ),
      TailscaleStatus.needsAuth => ConnectionBlocker(
        kind: ConnectionBlockerKind.tailscaleNeedsAuth,
        message: state.detail ?? 'Tailscale login is required.',
        tailscaleStatus: TailscaleStatus.needsAuth,
      ),
      TailscaleStatus.degraded => ConnectionBlocker(
        kind: ConnectionBlockerKind.tailscaleDegraded,
        message: state.detail ?? 'Tailscale is reconnecting.',
        tailscaleStatus: TailscaleStatus.degraded,
      ),
      TailscaleStatus.failed => ConnectionBlocker(
        kind: ConnectionBlockerKind.tailscaleFailed,
        message: state.detail ?? 'Tailscale failed to start.',
        tailscaleStatus: TailscaleStatus.failed,
      ),
      TailscaleStatus.running => const ConnectionBlocker(
        kind: ConnectionBlockerKind.transportUnavailable,
        message: 'Transport is unavailable.',
        tailscaleStatus: TailscaleStatus.running,
      ),
    };
  }

  factory ConnectionBlocker.transport(String message) => ConnectionBlocker(
    kind: ConnectionBlockerKind.transportUnavailable,
    message: message,
  );

  bool get canOpenTailscale =>
      kind != ConnectionBlockerKind.tailscaleStarting &&
      kind != ConnectionBlockerKind.transportUnavailable;

  String get statusLabel => switch (kind) {
    ConnectionBlockerKind.tailscaleStopped => 'Tailscale off',
    ConnectionBlockerKind.tailscaleStarting => 'Tailscale starting',
    ConnectionBlockerKind.tailscaleNeedsAuth => 'Tailscale login',
    ConnectionBlockerKind.tailscaleDegraded => 'Tailscale reconnecting',
    ConnectionBlockerKind.tailscaleFailed => 'Tailscale failed',
    ConnectionBlockerKind.transportUnavailable => 'Unavailable',
  };

  String get terminalOverlay => switch (kind) {
    ConnectionBlockerKind.tailscaleStopped => 'Tailscale disconnected',
    ConnectionBlockerKind.tailscaleStarting => 'Connecting Tailscale...',
    ConnectionBlockerKind.tailscaleNeedsAuth => 'Tailscale needs login',
    ConnectionBlockerKind.tailscaleDegraded => 'Reconnecting Tailscale...',
    ConnectionBlockerKind.tailscaleFailed => 'Tailscale failed',
    ConnectionBlockerKind.transportUnavailable => message,
  };
}

sealed class ServerConnectionState {
  const ServerConnectionState();
}

class ServerIdle extends ServerConnectionState {
  const ServerIdle();
}

class ServerBlocked extends ServerConnectionState {
  final ConnectionBlocker blocker;
  const ServerBlocked(this.blocker);
}

class ServerConnecting extends ServerConnectionState {
  const ServerConnecting();
}

class ServerConnected extends ServerConnectionState {
  const ServerConnected();
}

class ServerAttached extends ServerConnectionState {
  final String session;
  const ServerAttached(this.session);
}

class ServerSuspended extends ServerConnectionState {
  final String? session;
  final ConnectionBlocker blocker;
  const ServerSuspended({required this.session, required this.blocker});
}

class ServerReconnecting extends ServerConnectionState {
  final String? session;
  final int attempt;
  const ServerReconnecting({required this.session, required this.attempt});
}

class ServerFailed extends ServerConnectionState {
  final String message;
  final String? session;
  const ServerFailed(this.message, {this.session});
}

enum ServerConnectionAction {
  none,
  connect,
  retry,
  disconnect,
  openTailscale,
  openSessions,
}

enum ServerConnectionTone { neutral, accent, success, warning, danger }

enum ServerConnectionIconKind {
  direct,
  tailscale,
  rendezvous,
  sync,
  warning,
  offline,
}

class ServerConnectionViewState {
  final String statusLabel;
  final String subtitle;
  final ServerConnectionTone tone;
  final ServerConnectionIconKind icon;
  final bool showSpinner;
  final bool canOpenTerminal;
  final bool canInput;
  final String? terminalOverlay;
  final ServerConnectionAction primaryAction;
  final ServerConnectionAction tapAction;

  const ServerConnectionViewState({
    required this.statusLabel,
    required this.subtitle,
    required this.tone,
    required this.icon,
    required this.showSpinner,
    required this.canOpenTerminal,
    required this.canInput,
    required this.terminalOverlay,
    required this.primaryAction,
    required this.tapAction,
  });

  factory ServerConnectionViewState.from({
    required MotifServer server,
    required ServerConnectionState state,
  }) {
    final baseIcon = switch (server.kind) {
      ServerKind.tailscale => ServerConnectionIconKind.tailscale,
      ServerKind.rendezvous => ServerConnectionIconKind.rendezvous,
      ServerKind.direct => ServerConnectionIconKind.direct,
    };
    return switch (state) {
      ServerIdle() => ServerConnectionViewState(
        statusLabel: 'Offline',
        subtitle: server.endpoint,
        tone: ServerConnectionTone.neutral,
        icon: baseIcon,
        showSpinner: false,
        canOpenTerminal: false,
        canInput: false,
        terminalOverlay: null,
        primaryAction: ServerConnectionAction.connect,
        tapAction: ServerConnectionAction.connect,
      ),
      ServerBlocked(:final blocker) => ServerConnectionViewState(
        statusLabel: blocker.statusLabel,
        subtitle: '${server.endpoint}\n${blocker.message}',
        tone: blocker.kind == ConnectionBlockerKind.tailscaleStarting
            ? ServerConnectionTone.accent
            : ServerConnectionTone.warning,
        icon: ServerConnectionIconKind.warning,
        showSpinner: blocker.kind == ConnectionBlockerKind.tailscaleStarting,
        canOpenTerminal: false,
        canInput: false,
        terminalOverlay: null,
        primaryAction: blocker.canOpenTailscale
            ? ServerConnectionAction.openTailscale
            : ServerConnectionAction.none,
        tapAction: blocker.canOpenTailscale
            ? ServerConnectionAction.openTailscale
            : ServerConnectionAction.none,
      ),
      ServerConnecting() => ServerConnectionViewState(
        statusLabel: 'Connecting...',
        subtitle: server.endpoint,
        tone: ServerConnectionTone.accent,
        icon: ServerConnectionIconKind.sync,
        showSpinner: true,
        canOpenTerminal: false,
        canInput: false,
        terminalOverlay: 'Connecting...',
        primaryAction: ServerConnectionAction.none,
        tapAction: ServerConnectionAction.none,
      ),
      ServerConnected() => ServerConnectionViewState(
        statusLabel: 'Connected',
        subtitle: server.endpoint,
        tone: ServerConnectionTone.success,
        icon: baseIcon,
        showSpinner: false,
        canOpenTerminal: true,
        canInput: false,
        terminalOverlay: null,
        primaryAction: ServerConnectionAction.disconnect,
        tapAction: ServerConnectionAction.openSessions,
      ),
      ServerAttached(:final session) => ServerConnectionViewState(
        statusLabel: 'Live',
        subtitle: '${server.endpoint}\nAttached: $session',
        tone: ServerConnectionTone.success,
        icon: baseIcon,
        showSpinner: false,
        canOpenTerminal: true,
        canInput: true,
        terminalOverlay: null,
        primaryAction: ServerConnectionAction.disconnect,
        tapAction: ServerConnectionAction.openSessions,
      ),
      ServerSuspended(:final session, :final blocker) =>
        ServerConnectionViewState(
          statusLabel: 'Reconnecting',
          subtitle: '${server.endpoint}\n${blocker.message}',
          tone: ServerConnectionTone.warning,
          icon: ServerConnectionIconKind.warning,
          showSpinner: true,
          canOpenTerminal: session != null,
          canInput: false,
          terminalOverlay: blocker.terminalOverlay,
          primaryAction: blocker.canOpenTailscale
              ? ServerConnectionAction.openTailscale
              : ServerConnectionAction.none,
          tapAction: blocker.canOpenTailscale
              ? ServerConnectionAction.openTailscale
              : ServerConnectionAction.none,
        ),
      ServerReconnecting(:final session) => ServerConnectionViewState(
        statusLabel: 'Reconnecting',
        subtitle: server.endpoint,
        tone: ServerConnectionTone.accent,
        icon: ServerConnectionIconKind.sync,
        showSpinner: true,
        canOpenTerminal: session != null,
        canInput: false,
        terminalOverlay: 'Reconnecting...',
        primaryAction: ServerConnectionAction.none,
        tapAction: ServerConnectionAction.none,
      ),
      ServerFailed(:final message, :final session) => ServerConnectionViewState(
        statusLabel: 'Failed',
        subtitle: '${server.endpoint}\nFailed: $message',
        tone: ServerConnectionTone.danger,
        icon: ServerConnectionIconKind.warning,
        showSpinner: false,
        canOpenTerminal: session != null,
        canInput: false,
        terminalOverlay: session == null ? null : 'Connection failed',
        primaryAction: ServerConnectionAction.retry,
        tapAction: ServerConnectionAction.retry,
      ),
    };
  }
}
