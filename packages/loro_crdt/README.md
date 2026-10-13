# loro_crdt

Dart bindings for [Loro](https://loro.dev) 1.16.2, a CRDT library for
local-first and collaborative apps: rich text, maps, lists, movable lists,
trees and counters that merge concurrent edits from any number of peers,
with full history, time travel and undo.

| Platform | Backend | How the native code ships |
| --- | --- | --- |
| Android, iOS, macOS, Windows, Linux | `dart:ffi` | Compiled from the bundled Rust crate by the package's [build hook](https://dart.dev/tools/hooks) |
| Web (dart2js and dart2wasm) | [`wasm_ffi`](https://pub.dev/packages/wasm_ffi) | Prebuilt Emscripten module in `lib/src/web/` |

Flutter apps should depend on
[`loro_crdt_flutter`](https://pub.dev/packages/loro_crdt_flutter), which
re-exports this package,
bundles the web module as a Flutter asset and adds a `TextEditingController`
bound to a `LoroText`.

## Requirements

- Dart 3.10.8+ (Flutter 3.38+), for build hooks.
- For native targets: [rustup](https://rustup.rs). The first build downloads
  the Rust toolchain pinned in `native/rust-toolchain.toml` (1.90.0) with the
  targets listed there; later builds are incremental.
- Android builds use the NDK configured by your Flutter project.

## Quick start

```dart
import 'package:loro_crdt/loro_crdt.dart';

Future<void> main() async {
  await initLoro(); // Needed once on the web; a no-op elsewhere.

  final doc = LoroDoc();
  final text = doc.getText('notes');
  text.insert(0, 'Hello 👋');
  doc.getMap('meta')['title'] = 'Greetings';
  doc.commit();

  // Persist or send the whole document...
  final snapshot = doc.export(const ExportMode.snapshot());
  final copy = LoroDoc.fromSnapshot(snapshot);

  // ...or only what a peer is missing.
  copy.getText('notes').insert(text.length, '!');
  copy.commit();
  doc.import(copy.exportUpdates(from: doc.oplogVersion));

  print(doc.toJson()); // {meta: {title: Greetings}, notes: Hello 👋!}
}
```

See `example/loro_crdt_example.dart` for two peers editing concurrently.

## Tour

**Containers.** Get root containers from the document (`getText`, `getMap`,
`getList`, `getMovableList`, `getTree`, `getCounter`). Nest containers with
`setContainer` / `insertContainer` / `pushContainer`, passing a detached
container such as `LoroText()`; the call returns the attached handle. Use
`LoroMap.getOrCreateContainer<LoroList>('key')` when several peers may create
the same child concurrently: those children merge instead of overwriting each
other.

**Values.** `null`, `bool`, `int`, `double`, `String`, `Uint8List`, `List`
and `Map<String, …>` can be stored. Reads return the same types, plus
`LoroContainer` objects for child containers. `toJson()` resolves everything
into plain Dart values.

**Text positions are UTF-16 code units**, the same as Dart `String` indices
and Loro's JavaScript API: emoji take two units. Pass
`unit: TextUnit.unicode` or `TextUnit.utf8` to use other units. Text deltas
in events, `toDelta()`/`applyDelta()` and cursors use UTF-16 too.

**Rich text.** Configure how marks expand with `doc.configTextStyle`, then
`text.mark(start, end, 'bold', true)`. `toDelta()` returns a Quill-style
delta.

**Commits and events.** Edits are grouped into a transaction until
`doc.commit()`. Imports, exports and checkouts commit implicitly. Listeners
registered with `doc.subscribe`, `container.subscribe` or
`doc.subscribeLocalUpdates` run synchronously right after the commit, import
or checkout that produced the event. They stay registered until you call
`unsubscribe()`. The `events` and `localUpdates` getters wrap them as
broadcast streams.

**Syncing.** Forward everything from `subscribeLocalUpdates` to other peers
and `import` it there. To catch up after being offline, send
`exportUpdates(from: theirVersion)`. Updates can arrive in any order:
missing dependencies show up in `ImportStatus.pending` and apply once they
arrive.

**Versions and time travel.** `oplogVersion` / `oplogFrontiers` describe a
version; `checkout(frontiers)` shows an old state, `checkoutToLatest()`
returns. `fork`, `forkAt`, `revertTo`, `diff`/`applyDiff`, `getChange`,
`changeAncestors` and the `ExportMode` variants (shallow snapshots,
state-only, updates in a range) are available as well.

**Undo.** `UndoManager(doc)` undoes this peer's own edits. Imported changes
are never undone, but undo steps are adjusted to apply on top of them.

**Presence.** `EphemeralStore` holds short-lived shared state such as cursors
or online status, with expiry and its own update stream.

**Cursors.** `text.getCursor(index)` returns a `Cursor` that stays attached
to the same character under concurrent edits; resolve it with
`doc.getCursorPos(cursor)`. Cursors serialize with `encode()`.

## Web setup

Flutter: use `loro_crdt_flutter` and `await ensureLoroInitialized()`.

Plain Dart web apps: serve `lib/src/web/loro_crdt_ffi.js` and
`loro_crdt_ffi.wasm` from the same directory, then
`await initLoro(url: 'path/to/loro_crdt_ffi.js')` before using any other API.
`example/web/` contains a minimal page.

## Differences from Loro's JavaScript API, and limitations

- Peer ids are decimal `String`s, because they are random 64-bit values that
  a Dart `int` cannot hold on the web.
- APIs that need a synchronous callback into Dart are not available, because
  `wasm_ffi` cannot call back into Dart: pre-commit hooks,
  `UndoManager` `onPush`/`onPop`, `subscribeJsonPath`, and peer-id or
  first-commit subscriptions. Event subscriptions work without callbacks; see
  "How it works".
- The deprecated `Awareness` is not exposed; use `EphemeralStore`.
- On the web a whole-number `double` is indistinguishable from an `int`, so
  it is stored as an integer. This is how JavaScript numbers behave anyway.
- On the web, `wasm_ffi` binds pointers to the first module it loads, so
  don't load another `wasm_ffi`-based module before Loro.
- `EphemeralStore` resolves conflicts by millisecond timestamps: two writes
  to one key within the same millisecond may not both reach other peers.
- Native and web memory is freed when Dart objects are garbage collected.
  Call `dispose()` on `LoroDoc`, `UndoManager` and `EphemeralStore` to free
  it earlier.

## Licenses

This package is MIT licensed. The native library it builds, and the prebuilt
web module it ships, include Loro and other Rust crates under permissive
licenses (MIT, Apache-2.0, MPL-2.0 for the `im` crates), plus the Emscripten
runtime on the web. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for
the full list and texts to include in your app's notices.

## How it works

`native/` is a Rust crate exposing a C ABI over the `loro` crate. The ABI is
deliberately narrow so the same exports work through `dart:ffi` and through
`wasm_ffi`:

- Only `int32_t`, `uint32_t`, `double` and pointers cross the boundary. There
  are no structs by value and no 64-bit integers, which dart2js cannot
  represent.
- Rich values (`LoroValue`, events, versions, deltas) travel in a compact
  binary encoding (`native/src/codec.rs` ↔ `lib/src/codec.dart`).
- Errors and Rust panics become `LoroException`s through an error slot passed
  to every fallible call.
- Subscriptions don't call back into Dart. Each native subscription queues
  encoded events, and the Dart side drains the queues after every operation
  that can emit them. As a result, listeners run synchronously but outside the
  native code.

`tool/generate_bindings.dart` reads the cbindgen header and generates both
binding files: `@Native` externals for `dart:ffi`, and `wasm_ffi` lookups with
the same signatures for the web. A conditional import picks one, so the rest
of the package is platform independent.

The web module is built for `wasm32-unknown-emscripten`, the mode `wasm_ffi`
supports best (`tool/build_web.sh`, needs the Emscripten SDK). Two details
matter there:

- Loro's `wasm` feature is enabled so "event" positions are UTF-16 on every
  platform.
- A small C shim (`native/web/emscripten_shims.c`) gives single-threaded
  Emscripten pthread mutexes real lock state. Loro relies on `try_lock`
  reporting a held lock, and Emscripten's stub `try_lock` always succeeds.

## Development

```sh
dart run tool/generate_bindings.dart          # after changing the Rust ABI (needs cbindgen)
./tool/build_web.sh                           # rebuild lib/src/web (needs emsdk)
dart test                                     # native tests
dart test -p chrome                           # the same tests in Chrome
```
