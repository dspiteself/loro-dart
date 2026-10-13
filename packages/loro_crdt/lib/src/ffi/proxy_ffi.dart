// `dart:ffi` on native platforms, `wasm_ffi` (same API shape) on the web.
export 'package:wasm_ffi/ffi.dart' if (dart.library.ffi) 'dart:ffi';
