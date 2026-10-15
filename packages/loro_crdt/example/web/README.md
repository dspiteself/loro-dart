# Plain Dart web example

A minimal web page using `loro_crdt` without Flutter. It loads the prebuilt
Loro module with `initLoro`, edits a document and prints the result.

From `packages/loro_crdt`:

```sh
dart compile wasm example/web/main.dart -o example/web/main.wasm
cp lib/src/web/loro_crdt_ffi.* example/web/
python3 -m http.server --directory example/web
```

Then open <http://localhost:8000>. The page shows a line starting with `OK`.
