// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sticky_modifiers.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$StickyModifiers with ObservableModelMixin {
  _$StickyModifiers(StickyLevel ctrl, StickyLevel alt, StickyLevel shift)
    : _ctrl = ctrl,
      _alt = alt,
      _shift = shift {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_ctrlKey, () => _ctrl);
      observationRegisterDebugProperty(_altKey, () => _alt);
      observationRegisterDebugProperty(_shiftKey, () => _shift);
    }
  }
  final ObservationKey<StickyLevel> _ctrlKey = ObservationKey<StickyLevel>(
    'StickyModifiers.ctrl',
  );
  StickyLevel _ctrl;

  StickyLevel get ctrl {
    observationAccess(_ctrlKey);
    return _ctrl;
  }

  set ctrl(StickyLevel value) {
    if (_ctrl == value) return;
    observationMutation(_ctrlKey, () {
      _ctrl = value;
    });
  }

  final ObservationKey<StickyLevel> _altKey = ObservationKey<StickyLevel>(
    'StickyModifiers.alt',
  );
  StickyLevel _alt;

  StickyLevel get alt {
    observationAccess(_altKey);
    return _alt;
  }

  set alt(StickyLevel value) {
    if (_alt == value) return;
    observationMutation(_altKey, () {
      _alt = value;
    });
  }

  final ObservationKey<StickyLevel> _shiftKey = ObservationKey<StickyLevel>(
    'StickyModifiers.shift',
  );
  StickyLevel _shift;

  StickyLevel get shift {
    observationAccess(_shiftKey);
    return _shift;
  }

  set shift(StickyLevel value) {
    if (_shift == value) return;
    observationMutation(_shiftKey, () {
      _shift = value;
    });
  }
}
