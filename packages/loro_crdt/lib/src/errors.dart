/// An error reported by Loro.
///
/// [code] names the kind of failure, usually the Rust error variant such as
/// `OutOfBound`, `DecodeError` or `ImportUnsupportedEncodingMode`. Errors raised
/// by the bindings themselves use `InvalidArgument`; an internal Loro panic is
/// reported as `Panic`.
final class LoroException implements Exception {
  const LoroException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'LoroException($code): $message';
}
