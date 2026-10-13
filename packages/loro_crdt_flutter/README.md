# loro_crdt_flutter

Flutter integration for [`loro_crdt`](https://pub.dev/packages/loro_crdt), the Dart bindings for
the [Loro](https://loro.dev) CRDT library. It runs on Android, iOS, macOS,
Windows, Linux and the web.

- Re-exports the full `loro_crdt` API.
- Bundles Loro's web build as a Flutter asset, so the web works with no setup.
- `LoroTextEditingController` keeps a `TextField` in sync with a
  collaborative `LoroText`.

Native platforms compile Loro's Rust code with the `loro_crdt` build hook,
which requires [rustup](https://rustup.rs) on the build machine.

## Setup

```dart
import 'package:flutter/material.dart';
import 'package:loro_crdt_flutter/loro_crdt_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ensureLoroInitialized(); // loads the wasm module on the web
  runApp(const MyApp());
}
```

## Collaborative text fields

```dart
final doc = LoroDoc();
final controller = LoroTextEditingController(doc.getText('notes'));

TextField(controller: controller, maxLines: null);

// Send local changes to other peers...
doc.subscribeLocalUpdates((update) => channel.send(update));
// ...and apply theirs. The field updates and the caret stays in place.
channel.onMessage((update) => doc.import(update));
```

How the controller behaves:

- **Local edits.** Typing, pasting and `controller.text = ...` are written to
  the `LoroText` as a minimal splice that never splits an emoji, and committed
  with origin `LoroTextEditingController.defaultCommitOrigin`.
- **The field mirrors the committed document.** Creating the controller and
  every local edit commit the document, including other pending edits in it.
  Code that edits the same `LoroText` directly should commit its edits too.
- **Remote edits.** Imports, undo/redo and other code editing the same text
  update the field. The selection and IME composing range move with the
  change, and a caret sitting where remote text is inserted stays in front of
  it.
- **Rejected edits.** If the document rejects an edit (for example, it is
  checked out at an old version), the field reverts to the document's
  content.
- **Rich text.** Pass `attributeStyle` to render Loro marks:

  ```dart
  LoroTextEditingController(
    text,
    attributeStyle: (attrs) => attrs['bold'] == true
        ? const TextStyle(fontWeight: FontWeight.bold)
        : null,
  );
  ```

Call `controller.dispose()` to unsubscribe from the document.

## Example

`example/` shows two peers side by side, with live sync, an offline toggle
that lets them diverge and merge again, per-peer undo/redo and a shared
counter:

```sh
cd example
flutter run -d chrome     # or macos, windows, linux, an emulator...
```
