## 0.1.0

- Initial release: bindings for Loro 1.16.2 on Android, iOS, macOS, Windows,
  Linux (dart:ffi + build hook) and the web (wasm_ffi + Emscripten).
- `LoroDoc` (import/export modes, versions, checkout, fork, revert, diff,
  history, JSONPath), `LoroText` (UTF-16 indices, rich text, cursors),
  `LoroMap`, `LoroList`, `LoroMovableList`, `LoroTree`, `LoroCounter`.
- Events, local-update subscriptions and streams; `UndoManager`;
  `EphemeralStore`.
- `THIRD_PARTY_NOTICES.md` lists the licenses of the bundled Rust crates and
  the Emscripten runtime.
