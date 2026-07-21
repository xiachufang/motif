// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session_catalog_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$SessionCatalogViewModel with ObservableModelMixin {
  _$SessionCatalogViewModel(
    SessionCatalogPhase phase,
    ObservableList<SessionInfo> sessions,
    String? error,
    DateTime? lastUpdatedAt,
  ) : _phase = phase,
      _sessions = sessions,
      _error = error,
      _lastUpdatedAt = lastUpdatedAt {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_phaseKey, () => _phase);
      observationRegisterDebugProperty(_sessionsKey, () => _sessions);
      observationRegisterDebugProperty(_errorKey, () => _error);
      observationRegisterDebugProperty(_lastUpdatedAtKey, () => _lastUpdatedAt);
    }
  }
  final ObservationKey<SessionCatalogPhase> _phaseKey =
      ObservationKey<SessionCatalogPhase>('SessionCatalogViewModel.phase');
  SessionCatalogPhase _phase;

  SessionCatalogPhase get phase {
    observationAccess(_phaseKey);
    return _phase;
  }

  set phase(SessionCatalogPhase value) {
    if (_phase == value) return;
    observationMutation(_phaseKey, () {
      _phase = value;
    });
  }

  final ObservationKey<ObservableList<SessionInfo>> _sessionsKey =
      ObservationKey<ObservableList<SessionInfo>>(
        'SessionCatalogViewModel.sessions',
      );
  final ObservableList<SessionInfo> _sessions;

  ObservableList<SessionInfo> get sessions {
    observationAccess(_sessionsKey);
    return _sessions;
  }

  final ObservationKey<String?> _errorKey = ObservationKey<String?>(
    'SessionCatalogViewModel.error',
  );
  String? _error;

  String? get error {
    observationAccess(_errorKey);
    return _error;
  }

  set error(String? value) {
    if (_error == value) return;
    observationMutation(_errorKey, () {
      _error = value;
    });
  }

  final ObservationKey<DateTime?> _lastUpdatedAtKey = ObservationKey<DateTime?>(
    'SessionCatalogViewModel.lastUpdatedAt',
  );
  DateTime? _lastUpdatedAt;

  DateTime? get lastUpdatedAt {
    observationAccess(_lastUpdatedAtKey);
    return _lastUpdatedAt;
  }

  set lastUpdatedAt(DateTime? value) {
    if (_lastUpdatedAt == value) return;
    observationMutation(_lastUpdatedAtKey, () {
      _lastUpdatedAt = value;
    });
  }
}
