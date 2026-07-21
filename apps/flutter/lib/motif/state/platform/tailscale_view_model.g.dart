// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tailscale_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$TailscaleViewModel with ObservableModelMixin {
  _$TailscaleViewModel(
    TailscaleStatus status,
    String? authUrl,
    String? detail,
    bool discovering,
    ObservableList<TailscalePeer> peers,
    String? error,
  ) : _status = status,
      _authUrl = authUrl,
      _detail = detail,
      _discovering = discovering,
      _peers = peers,
      _error = error {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_statusKey, () => _status);
      observationRegisterDebugProperty(_authUrlKey, () => _authUrl);
      observationRegisterDebugProperty(_detailKey, () => _detail);
      observationRegisterDebugProperty(_discoveringKey, () => _discovering);
      observationRegisterDebugProperty(_peersKey, () => _peers);
      observationRegisterDebugProperty(_errorKey, () => _error);
    }
  }
  final ObservationKey<TailscaleStatus> _statusKey =
      ObservationKey<TailscaleStatus>('TailscaleViewModel.status');
  TailscaleStatus _status;

  TailscaleStatus get status {
    observationAccess(_statusKey);
    return _status;
  }

  set status(TailscaleStatus value) {
    if (_status == value) return;
    observationMutation(_statusKey, () {
      _status = value;
    });
  }

  final ObservationKey<String?> _authUrlKey = ObservationKey<String?>(
    'TailscaleViewModel.authUrl',
  );
  String? _authUrl;

  String? get authUrl {
    observationAccess(_authUrlKey);
    return _authUrl;
  }

  set authUrl(String? value) {
    if (_authUrl == value) return;
    observationMutation(_authUrlKey, () {
      _authUrl = value;
    });
  }

  final ObservationKey<String?> _detailKey = ObservationKey<String?>(
    'TailscaleViewModel.detail',
  );
  String? _detail;

  String? get detail {
    observationAccess(_detailKey);
    return _detail;
  }

  set detail(String? value) {
    if (_detail == value) return;
    observationMutation(_detailKey, () {
      _detail = value;
    });
  }

  final ObservationKey<bool> _discoveringKey = ObservationKey<bool>(
    'TailscaleViewModel.discovering',
  );
  bool _discovering;

  bool get discovering {
    observationAccess(_discoveringKey);
    return _discovering;
  }

  set discovering(bool value) {
    if (_discovering == value) return;
    observationMutation(_discoveringKey, () {
      _discovering = value;
    });
  }

  final ObservationKey<ObservableList<TailscalePeer>> _peersKey =
      ObservationKey<ObservableList<TailscalePeer>>('TailscaleViewModel.peers');
  final ObservableList<TailscalePeer> _peers;

  ObservableList<TailscalePeer> get peers {
    observationAccess(_peersKey);
    return _peers;
  }

  final ObservationKey<String?> _errorKey = ObservationKey<String?>(
    'TailscaleViewModel.error',
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
}
