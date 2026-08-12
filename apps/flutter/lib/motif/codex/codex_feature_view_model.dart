import 'package:flutter_observation/flutter_observation.dart';

import 'codex_service_state.dart';

part 'codex_feature_view_model.g.dart';

/// Observable shell state for the Codex feature lifecycle.
@ObservableModel()
class CodexFeatureViewModel extends _$CodexFeatureViewModel {
  CodexFeatureViewModel({
    CodexServiceState? service,
    String? setupError,
    bool operationInFlight = false,
    bool sideChatOpening = false,
  }) : super(service, setupError, operationInFlight, sideChatOpening);
}
