import 'package:flutter_observation/flutter_observation.dart';

import 'embedded_server_models.dart';

part 'embedded_server_view_model.g.dart';

@ObservableModel()
class EmbeddedServerViewModel extends _$EmbeddedServerViewModel {
  EmbeddedServerViewModel({
    bool available = false,
    EmbeddedServerConfig config = const EmbeddedServerConfig(),
    EmbeddedServerStatus status = const EmbeddedServerStatus(),
  }) : super(available, config, status);
}
