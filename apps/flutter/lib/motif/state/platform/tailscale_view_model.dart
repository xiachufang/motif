import 'package:flutter_observation/flutter_observation.dart';

import 'tailscale_models.dart';
import 'tailscale_runtime_state.dart';

export 'tailscale_models.dart';
export 'tailscale_runtime_state.dart';

part 'tailscale_view_model.g.dart';

@ObservableModel()
class TailscaleViewModel extends _$TailscaleViewModel {
  TailscaleViewModel({
    TailscaleRuntimeState runtime = const TailscaleRuntimeState.initial(),
    TailscaleStatus status = TailscaleStatus.stopped,
    String? authUrl,
    String? detail,
    bool discovering = false,
    @ObservationReadOnly() required ObservableList<TailscalePeer> peers,
    String? error,
  }) : super(runtime, status, authUrl, detail, discovering, peers, error);

  bool get isRunning => status == TailscaleStatus.running;

  TailscaleState get snapshot =>
      TailscaleState(status, authUrl: authUrl, detail: detail);

  void applyRuntime(TailscaleRuntimeState state) {
    observationTransaction(() {
      runtime = state;
      final visible = state.visibleState;
      status = visible.status;
      authUrl = visible.authUrl;
      detail = visible.detail;
      error = visible.status == TailscaleStatus.failed ? visible.detail : null;
    });
  }

  void apply(TailscaleState state) {
    observationTransaction(() {
      status = state.status;
      authUrl = state.authUrl;
      detail = state.detail;
      error = state.status == TailscaleStatus.failed ? state.detail : null;
    });
  }
}
