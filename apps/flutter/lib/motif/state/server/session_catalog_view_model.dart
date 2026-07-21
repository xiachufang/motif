import 'package:flutter_observation/flutter_observation.dart';

import '../../models/motif_proto.dart';

part 'session_catalog_view_model.g.dart';

enum SessionCatalogPhase { idle, loading, ready, failed }

@ObservableModel()
class SessionCatalogViewModel extends _$SessionCatalogViewModel {
  SessionCatalogViewModel({
    SessionCatalogPhase phase = SessionCatalogPhase.idle,
    @ObservationReadOnly() required ObservableList<SessionInfo> sessions,
    String? error,
    DateTime? lastUpdatedAt,
  }) : super(phase, sessions, error, lastUpdatedAt);
}
