abstract interface class WindowTitleDelegate {
  Future<void> ensureInitialized();
  Future<void> set(String title);
}

class NoopWindowTitleDelegate implements WindowTitleDelegate {
  const NoopWindowTitleDelegate();

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> set(String title) async {}
}

abstract final class MotifWindowTitle {
  static WindowTitleDelegate _delegate = const NoopWindowTitleDelegate();

  static void install(WindowTitleDelegate delegate) {
    _delegate = delegate;
  }

  static Future<void> ensureInitialized() => _delegate.ensureInitialized();

  static Future<void> set(String title) => _delegate.set(title);
}
