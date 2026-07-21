// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'view_tabs_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$ViewTabsViewModel with ObservableModelMixin {
  _$ViewTabsViewModel(
    ViewRuntimeState runtime,
    ObservableList<ViewInfo> items,
    String? activeViewId,
  ) : _runtime = runtime,
      _items = items,
      _activeViewId = activeViewId {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_runtimeKey, () => _runtime);
      observationRegisterDebugProperty(_itemsKey, () => _items);
      observationRegisterDebugProperty(_activeViewIdKey, () => _activeViewId);
    }
  }
  final ObservationKey<ViewRuntimeState> _runtimeKey =
      ObservationKey<ViewRuntimeState>('ViewTabsViewModel.runtime');
  ViewRuntimeState _runtime;

  ViewRuntimeState get runtime {
    observationAccess(_runtimeKey);
    return _runtime;
  }

  set runtime(ViewRuntimeState value) {
    if (_runtime == value) return;
    observationMutation(_runtimeKey, () {
      _runtime = value;
    });
  }

  final ObservationKey<ObservableList<ViewInfo>> _itemsKey =
      ObservationKey<ObservableList<ViewInfo>>('ViewTabsViewModel.items');
  final ObservableList<ViewInfo> _items;

  ObservableList<ViewInfo> get items {
    observationAccess(_itemsKey);
    return _items;
  }

  final ObservationKey<String?> _activeViewIdKey = ObservationKey<String?>(
    'ViewTabsViewModel.activeViewId',
  );
  String? _activeViewId;

  String? get activeViewId {
    observationAccess(_activeViewIdKey);
    return _activeViewId;
  }

  set activeViewId(String? value) {
    if (_activeViewId == value) return;
    observationMutation(_activeViewIdKey, () {
      _activeViewId = value;
    });
  }
}
