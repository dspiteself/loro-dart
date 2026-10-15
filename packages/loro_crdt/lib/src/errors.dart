/// An error reported by Loro.
///
/// [code] names the kind of failure, usually the Rust error variant such as
/// `OutOfBound`, `DecodeError` or `ImportUnsupportedEncodingMode`. Errors raised
/// by the bindings themselves use `InvalidArgument`; an internal Loro panic is
/// reported as `Panic`.
final class LoroException implements Exception {
  /// Creates an exception of kind [code].
  const LoroException(this.code, this.message);

  /// The kind of failure, e.g. `OutOfBound`.
  final String code;

  /// A description of the failure.
  final String message;

  @override
  String toString() => 'LoroException($code): $message';
}
