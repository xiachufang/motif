import 'dart:io';

/// `package:http`'s native socket exception also implements
/// [SocketException], so this covers failures wrapped by `IOClient` as well as
/// failures raised directly by `dart:io`.
bool isTransportConnectionFailure(Object error) =>
    error is SocketException || error is HandshakeException;
