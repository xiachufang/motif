import 'package:flutter_observation/flutter_observation.dart';

import 'embedded_server_models.dart';
import 'embedded_server_runtime_state.dart';

part 'embedded_server_view_model.g.dart';

@ObservableModel()
class EmbeddedServerViewModel extends _$EmbeddedServerViewModel {
  EmbeddedServerViewModel({
    bool available = false,
    EmbeddedServerRuntimeState runtime =
        const EmbeddedServerRuntimeState.initial(),
    EmbeddedServerConfig config = const EmbeddedServerConfig(),
    EmbeddedServerStatus status = const EmbeddedServerStatus(),
  }) : super(available, runtime, config, status);

  void applyRuntime(
    EmbeddedServerRuntimeState next, {
    EmbeddedServerStatus? status,
    EmbeddedServerConfig? config,
  }) {
    observationTransaction(() {
      runtime = next;
      available = next.available;
      if (status != null) this.status = status;
      if (config != null) this.config = config;
    });
  }
}
