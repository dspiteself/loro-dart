import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Compiles the Rust crate in `native/` and bundles it as the code asset that
/// `lib/src/ffi/bindings_native.g.dart` binds to.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await const RustBuilder(
      assetName: 'src/ffi/bindings_native.g.dart',
      cratePath: 'native',
    ).run(input: input, output: output);
  });
}
