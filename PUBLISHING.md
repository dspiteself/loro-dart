# Publishing to pub.dev

`loro_crdt_flutter` depends on `loro_crdt`, so `loro_crdt` is always
published first.

## Before every release

1. Bump `version` in the package's `pubspec.yaml` and add a `CHANGELOG.md`
   entry (`loro_crdt_flutter` must allow the new `loro_crdt` version).
2. If the Rust ABI or dependencies changed, in `packages/loro_crdt`:
   - `dart run tool/generate_bindings.dart` (needs cbindgen 0.29.4)
   - `./tool/build_web.sh` (needs emsdk 6.0.12): the prebuilt web module in
     `lib/src/web/` is what web users run
   - `dart run tool/generate_notices.dart`
3. Make sure CI is green, then check the archive:
   `dart pub publish --dry-run` (and `flutter pub publish --dry-run` for the
   Flutter package). The only acceptable warning is about uncommitted files,
   and that one should be gone too.

## First release (manual)

The GitHub repository must be public: pubspecs link to it.

```sh
cd packages/loro_crdt && dart pub publish
cd ../loro_crdt_flutter && flutter pub publish
```

Then, on each package's pub.dev **Admin** page, enable automated publishing
from GitHub Actions for `dspiteself/loro-dart`, with the tag patterns listed
in `.github/workflows/publish.yml`. Requiring the `pub.dev` GitHub
environment is recommended. Consider transferring the packages to a verified
publisher.

## Later releases

Push a tag, and `.github/workflows/publish.yml` publishes:

```sh
git tag loro_crdt-v0.1.1 && git push origin loro_crdt-v0.1.1
git tag loro_crdt_flutter-v0.1.1 && git push origin loro_crdt_flutter-v0.1.1
```
