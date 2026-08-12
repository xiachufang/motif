import 'package:http/http.dart' as http;

/// Browsers do not expose the underlying socket error. A failed HTTP fetch is
/// surfaced as [http.ClientException], which is the closest equivalent to the
/// native connection-failure signal.
bool isTransportConnectionFailure(Object error) =>
    error is http.ClientException;
