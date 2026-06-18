abstract interface class SshForwarderHandle {
  int get port;
  bool get isRunning;

  bool matches(SshForwarderHandle other);
  Future<int> start();
  Future<void> stop();
}
