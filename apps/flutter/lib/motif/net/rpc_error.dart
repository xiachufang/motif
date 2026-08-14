final class RpcException implements Exception {
  const RpcException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => code == null ? 'rpc: $message' : 'rpc $code: $message';
}

/// A mutation may have reached motifd, so replaying it would be unsafe.
final class UncertainDeliveryException implements Exception {
  const UncertainDeliveryException(this.cause);

  final Object cause;

  @override
  String toString() => 'request delivery is uncertain: $cause';
}
