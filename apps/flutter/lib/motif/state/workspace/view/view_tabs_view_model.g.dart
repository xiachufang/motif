// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'view_tabs_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$ViewTabsViewModel with ObservableModelMixin {
  _$ViewTabsViewModel(ObservableList<ViewInfo> items, String? activeViewId)
    : _items = items,
      _activeViewId = activeViewId {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_itemsKey, () => _items);
      observationRegisterDebugProperty(_activeViewIdKey, () => _activeViewId);
    }
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
