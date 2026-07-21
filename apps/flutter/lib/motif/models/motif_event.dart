import 'package:flutter/widgets.dart';

/// A server-pushed notification (no id). Carries decoded protocol values only.
@immutable
final class MotifEvent {
  const MotifEvent(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}
