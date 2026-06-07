import 'window_title_stub.dart'
    if (dart.library.io) 'window_title_io.dart'
    as impl;

abstract final class MotifWindowTitle {
  static Future<void> ensureInitialized() =>
      impl.ensureWindowTitleInitialized();

  static Future<void> set(String title) => impl.setWindowTitle(title);
}
