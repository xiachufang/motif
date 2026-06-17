import '../models/settings.dart';
import '../platform/services.dart';

enum TransportStatus {
  ready,
  setupNeeded,
  starting,
  degraded,
  unavailable,
  failed,
}

enum TransportAction { none, setup, retry }

class TransportViewState {
  final ServerKind kind;
  final TransportStatus status;
  final String statusLabel;
  final String message;
  final ServerConnectionTone tone;
  final ServerConnectionIconKind icon;
  final bool showSpinner;
  final TransportAction action;

  const TransportViewState({
    required this.kind,
    required this.status,
    required this.statusLabel,
    required this.message,
    required this.tone,
    required this.icon,
    this.showSpinner = false,
    this.action = TransportAction.none,
  });

  bool get isReady => status == TransportStatus.ready;

  factory TransportViewState.direct(MotifServer server) => TransportViewState(
    kind: ServerKind.direct,
    status: TransportStatus.ready,
    statusLabel: 'Direct',
    message: server.endpoint,
    tone: ServerConnectionTone.neutral,
    icon: ServerConnectionIconKind.direct,
  );

  factory TransportViewState.rendezvous(
    MotifServer server, {
    String? validationMessage,
  }) {
    if (validationMessage != null) {
      return TransportViewState(
        kind: ServerKind.rendezvous,
        status: TransportStatus.setupNeeded,
        statusLabel: 'Rendezvous setup',
        message: validationMessage,
        tone: ServerConnectionTone.warning,
        icon: ServerConnectionIconKind.rendezvous,
        action: TransportAction.setup,
      );
    }
    return TransportViewState(
      kind: ServerKind.rendezvous,
      status: TransportStatus.ready,
      statusLabel: 'Rendezvous paired',
      message: server.relay.isEmpty ? server.endpoint : server.relay,
      tone: ServerConnectionTone.neutral,
      icon: ServerConnectionIconKind.rendezvous,
    );
  }

  factory TransportViewState.ssh(
    MotifServer server, {
    String? validationMessage,
  }) {
    if (validationMessage != null) {
      return TransportViewState(
        kind: ServerKind.ssh,
        status: TransportStatus.setupNeeded,
        statusLabel: 'SSH setup',
        message: validationMessage,
        tone: ServerConnectionTone.warning,
        icon: ServerConnectionIconKind.ssh,
        action: TransportAction.setup,
      );
    }
    final user = server.sshUsername.trim();
    final ssh = user.isEmpty
        ? server.sshEndpoint
        : '$user@${server.sshEndpoint}';
    return TransportViewState(
      kind: ServerKind.ssh,
      status: TransportStatus.ready,
      statusLabel: 'SSH configured',
      message: '$ssh -> ${server.endpoint}',
      tone: ServerConnectionTone.neutral,
      icon: ServerConnectionIconKind.ssh,
    );
  }

  factory TransportViewState.tailscale(
    MotifServer server,
    TailscaleState state,
  ) {
    return switch (state.status) {
      TailscaleStatus.stopped => const TransportViewState(
        kind: ServerKind.tailscale,
        status: TransportStatus.setupNeeded,
        statusLabel: 'Tailscale setup',
        message: 'Start Tailscale to reach tailnet servers.',
        tone: ServerConnectionTone.warning,
        icon: ServerConnectionIconKind.tailscale,
        action: TransportAction.setup,
      ),
      TailscaleStatus.starting => TransportViewState(
        kind: ServerKind.tailscale,
        status: TransportStatus.starting,
        statusLabel: 'Tailscale starting',
        message: state.detail ?? 'Waiting for Tailscale to finish connecting.',
        tone: ServerConnectionTone.accent,
        icon: ServerConnectionIconKind.tailscale,
        showSpinner: true,
      ),
      TailscaleStatus.needsAuth => TransportViewState(
        kind: ServerKind.tailscale,
        status: TransportStatus.setupNeeded,
        statusLabel: 'Tailscale login',
        message: state.detail ?? 'Tailscale login is required.',
        tone: ServerConnectionTone.warning,
        icon: ServerConnectionIconKind.tailscale,
        action: TransportAction.setup,
      ),
      TailscaleStatus.running => TransportViewState(
        kind: ServerKind.tailscale,
        status: TransportStatus.ready,
        statusLabel: 'Tailscale ready',
        message: state.detail ?? server.endpoint,
        tone: ServerConnectionTone.neutral,
        icon: ServerConnectionIconKind.tailscale,
      ),
      TailscaleStatus.degraded => TransportViewState(
        kind: ServerKind.tailscale,
        status: TransportStatus.degraded,
        statusLabel: 'Tailscale reconnecting',
        message: state.detail ?? 'Tailscale is reconnecting.',
        tone: ServerConnectionTone.warning,
        icon: ServerConnectionIconKind.tailscale,
        showSpinner: true,
        action: TransportAction.setup,
      ),
      TailscaleStatus.failed => TransportViewState(
        kind: ServerKind.tailscale,
        status: TransportStatus.failed,
        statusLabel: 'Tailscale failed',
        message: state.detail ?? 'Tailscale failed to start.',
        tone: ServerConnectionTone.danger,
        icon: ServerConnectionIconKind.tailscale,
        action: TransportAction.setup,
      ),
    };
  }

  factory TransportViewState.unavailable({
    required ServerKind kind,
    required String statusLabel,
    required String message,
  }) => TransportViewState(
    kind: kind,
    status: TransportStatus.unavailable,
    statusLabel: statusLabel,
    message: message,
    tone: ServerConnectionTone.warning,
    icon: _iconForKind(kind),
  );

  factory TransportViewState.failure({
    required ServerKind kind,
    required String statusLabel,
    required String message,
    TransportAction action = TransportAction.retry,
  }) => TransportViewState(
    kind: kind,
    status: TransportStatus.failed,
    statusLabel: statusLabel,
    message: message,
    tone: ServerConnectionTone.danger,
    icon: _iconForKind(kind),
    action: action,
  );

  static ServerConnectionIconKind _iconForKind(ServerKind kind) =>
      switch (kind) {
        ServerKind.direct => ServerConnectionIconKind.direct,
        ServerKind.tailscale => ServerConnectionIconKind.tailscale,
        ServerKind.rendezvous => ServerConnectionIconKind.rendezvous,
        ServerKind.ssh => ServerConnectionIconKind.ssh,
      };
}

class ConnectionBlocker {
  final TransportViewState transport;
  final String message;

  const ConnectionBlocker({required this.transport, required this.message});

  factory ConnectionBlocker.fromTransport(TransportViewState transport) =>
      ConnectionBlocker(transport: transport, message: transport.message);

  factory ConnectionBlocker.transport(
    String message, {
    ServerKind kind = ServerKind.direct,
  }) => ConnectionBlocker(
    transport: TransportViewState.unavailable(
      kind: kind,
      statusLabel: 'Transport unavailable',
      message: message,
    ),
    message: message,
  );

  String get statusLabel => transport.statusLabel;
  ServerConnectionTone get tone => transport.tone;
  ServerConnectionIconKind get icon => transport.icon;
  bool get showSpinner => transport.showSpinner;

  String get terminalOverlay => message;
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
  setupTransport,
  openSessions,
}

enum ServerConnectionTone { neutral, accent, success, warning, danger }

enum ServerConnectionIconKind {
  direct,
  tailscale,
  rendezvous,
  ssh,
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
    required TransportViewState transport,
  }) {
    final endpoint = _subtitleEndpoint(server);
    return switch (state) {
      ServerIdle() =>
        transport.isReady
            ? ServerConnectionViewState(
                statusLabel: 'Offline',
                subtitle: endpoint,
                tone: ServerConnectionTone.neutral,
                icon: transport.icon,
                showSpinner: false,
                canOpenTerminal: false,
                canInput: false,
                terminalOverlay: null,
                primaryAction: ServerConnectionAction.connect,
                tapAction: ServerConnectionAction.connect,
              )
            : _fromTransport(
                transport: transport,
                endpoint: endpoint,
                canOpenTerminal: false,
              ),
      ServerBlocked(:final blocker) => ServerConnectionViewState(
        statusLabel: blocker.statusLabel,
        subtitle: '$endpoint\n${blocker.message}',
        tone: blocker.tone,
        icon: blocker.icon,
        showSpinner: blocker.showSpinner,
        canOpenTerminal: false,
        canInput: false,
        terminalOverlay: null,
        primaryAction: _serverActionForTransport(blocker.transport.action),
        tapAction: _serverActionForTransport(blocker.transport.action),
      ),
      ServerConnecting() => ServerConnectionViewState(
        statusLabel: 'Connecting...',
        subtitle: endpoint,
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
        subtitle: endpoint,
        tone: ServerConnectionTone.success,
        icon: transport.icon,
        showSpinner: false,
        canOpenTerminal: true,
        canInput: false,
        terminalOverlay: null,
        primaryAction: ServerConnectionAction.disconnect,
        tapAction: ServerConnectionAction.openSessions,
      ),
      ServerAttached(:final session) => ServerConnectionViewState(
        statusLabel: 'Live',
        subtitle: '$endpoint\nAttached: $session',
        tone: ServerConnectionTone.success,
        icon: transport.icon,
        showSpinner: false,
        canOpenTerminal: true,
        canInput: true,
        terminalOverlay: null,
        primaryAction: ServerConnectionAction.disconnect,
        tapAction: ServerConnectionAction.openSessions,
      ),
      ServerSuspended(:final session, :final blocker) =>
        ServerConnectionViewState(
          statusLabel: blocker.statusLabel,
          subtitle: '$endpoint\n${blocker.message}',
          tone: blocker.tone,
          icon: blocker.icon,
          showSpinner: blocker.showSpinner,
          canOpenTerminal: session != null,
          canInput: false,
          terminalOverlay: blocker.terminalOverlay,
          primaryAction: _serverActionForTransport(blocker.transport.action),
          tapAction: _serverActionForTransport(blocker.transport.action),
        ),
      ServerReconnecting(:final session) => ServerConnectionViewState(
        statusLabel: 'Reconnecting',
        subtitle: endpoint,
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
        subtitle: '$endpoint\nFailed: $message',
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

  static ServerConnectionViewState _fromTransport({
    required TransportViewState transport,
    required String endpoint,
    required bool canOpenTerminal,
  }) {
    final action = _serverActionForTransport(transport.action);
    return ServerConnectionViewState(
      statusLabel: transport.statusLabel,
      subtitle: '$endpoint\n${transport.message}',
      tone: transport.tone,
      icon: transport.icon,
      showSpinner: transport.showSpinner,
      canOpenTerminal: canOpenTerminal,
      canInput: false,
      terminalOverlay: transport.message,
      primaryAction: action,
      tapAction: action,
    );
  }

  static ServerConnectionAction _serverActionForTransport(
    TransportAction action,
  ) => switch (action) {
    TransportAction.none => ServerConnectionAction.none,
    TransportAction.setup => ServerConnectionAction.setupTransport,
    TransportAction.retry => ServerConnectionAction.retry,
  };

  static String _subtitleEndpoint(MotifServer server) {
    if (server.kind != ServerKind.ssh) return server.endpoint;
    final user = server.sshUsername.trim();
    final ssh = user.isEmpty
        ? server.sshEndpoint
        : '$user@${server.sshEndpoint}';
    return '${server.endpoint} via SSH $ssh';
  }
}
