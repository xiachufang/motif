import 'package:flutter_observation/flutter_observation.dart';

part 'tailscale_view_model.g.dart';

enum TailscaleStatus { stopped, starting, running, needsAuth, degraded, failed }

/// Immutable snapshot used at service and controller boundaries.
class TailscaleState {
  final TailscaleStatus status;
  final String? authUrl;
  final String? detail;

  const TailscaleState(this.status, {this.authUrl, this.detail});

  static const stopped = TailscaleState(TailscaleStatus.stopped);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailscaleState &&
          status == other.status &&
          authUrl == other.authUrl &&
          detail == other.detail;

  @override
  int get hashCode => Object.hash(status, authUrl, detail);
}

/// A visible tailnet peer that may be a motifd target.
class TailscalePeer {
  final String hostname;
  final String dnsName;
  final String? primaryIP;
  final bool isLikelyMotifd;
  final bool isOnline;

  const TailscalePeer({
    required this.hostname,
    required this.dnsName,
    this.primaryIP,
    required this.isLikelyMotifd,
    required this.isOnline,
  });

  String get id => dnsName.isEmpty ? hostname : dnsName;

  /// Best address to persist in a server config: MagicDNS when present, IP
  /// otherwise.
  String get preferredAddress {
    if (dnsName.isNotEmpty) {
      return dnsName.endsWith('.')
          ? dnsName.substring(0, dnsName.length - 1)
          : dnsName;
    }
    return primaryIP ?? hostname;
  }
}

@ObservableModel()
class TailscaleViewModel extends _$TailscaleViewModel {
  TailscaleViewModel({
    TailscaleStatus status = TailscaleStatus.stopped,
    String? authUrl,
    String? detail,
    bool discovering = false,
    @ObservationReadOnly() required ObservableList<TailscalePeer> peers,
    String? error,
  }) : super(status, authUrl, detail, discovering, peers, error);

  bool get isRunning => status == TailscaleStatus.running;

  TailscaleState get snapshot =>
      TailscaleState(status, authUrl: authUrl, detail: detail);

  void apply(TailscaleState state) {
    observationTransaction(() {
      status = state.status;
      authUrl = state.authUrl;
      detail = state.detail;
      error = state.status == TailscaleStatus.failed ? state.detail : null;
    });
  }
}
