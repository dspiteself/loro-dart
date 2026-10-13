# Loro for Dart and Flutter

Bindings for the [Loro](https://loro.dev) CRDT library (1.16.2) on every
platform Dart runs on.

| Package | What it is |
| --- | --- |
| [`packages/loro_crdt`](packages/loro_crdt) | Pure Dart package. `dart:ffi` on Android, iOS, macOS, Windows and Linux (Rust built by a build hook); [`wasm_ffi`](https://pub.dev/packages/wasm_ffi) on the web |
| [`packages/loro_crdt_flutter`](packages/loro_crdt_flutter) | Flutter package: bundles the web module, adds `LoroTextEditingController` |
| [`packages/loro_crdt_flutter/example`](packages/loro_crdt_flutter/example) | Demo app with two peers editing side by side |

The repository is a [pub workspace](https://dart.dev/tools/pub/workspaces):
run `flutter pub get` at the root.

## Status

| Target | Verified locally | In the CI workflow (written, not yet run) |
| --- | --- | --- |
| Linux x64, Dart VM (`dart test`) | ✅ 77 tests | ✅ |
| Flutter tests on the host (`flutter test`) | ✅ | ✅ Linux, macOS, Windows |
| Web, dart2js (`dart test -p chrome`) | ✅ 77 tests | ✅ |
| Flutter web, dart2js and `--wasm` | ✅ example app run in a browser | ✅ build |
| Android, macOS, Linux arm64 | Rust `cargo check` only | ✅ `flutter build` |
| iOS, Windows | — | ✅ `flutter build` |
| Linux desktop app | — (needs `libgtk-3-dev`) | ✅ `flutter build linux` |

## Web: does `wasm_ffi` work?

Yes. The same generated bindings and the same Dart code run on top of
`wasm_ffi` under both dart2js and dart2wasm, and the full test suite passes in
Chrome. Making that work required a few constraints:

- **Narrow ABI.** `wasm_ffi` has no `@Native`, `NativeCallable`,
  `NativeFinalizer` or struct-by-value support, and dart2js has no 64-bit
  integers. The C ABI therefore uses only 32-bit integers, doubles and
  pointers. Events are polled from native queues instead of delivered by
  callback, and finalizers use Dart's `Finalizer` on the web.
- **Emscripten module.** Loro's `wasm32-unknown-unknown` build depends on
  wasm-bindgen imports that `wasm_ffi`'s standalone loader cannot provide, so
  the module targets `wasm32-unknown-emscripten`. That requires a mutex shim,
  because Emscripten's single-threaded pthread stubs don't track lock state;
  see `packages/loro_crdt/native/web/`.
- **Async init.** The module must be loaded with `await initLoro()`
  (`ensureLoroInitialized()` in Flutter) before first use.
- **Size.** The module is about 3.6 MB of wasm (1.3 MB gzipped) plus 90 KB of
  JavaScript glue.
- **One wasm_ffi module per app.** `wasm_ffi` binds pointers to the memory
  of the first module it loads. An app that loads another `wasm_ffi` module
  before Loro would break it.
- **dart2wasm tests.** Test suites compiled with `dart test -c dart2wasm` hit
  a Chrome WasmGC type-depth limit in `wasm_ffi` together with
  `package:test`, a limitation `wasm_ffi`'s own README notes. Apps compiled
  with dart2wasm work; the tests run under dart2js.
