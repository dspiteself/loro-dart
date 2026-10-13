Minimal plain-Dart web page using `loro_crdt` (no Flutter).

```sh
dart compile wasm example/web/main.dart -o example/web/main.wasm
cp lib/src/web/loro_crdt_ffi.* example/web/
python3 -m http.server --directory example/web
```
