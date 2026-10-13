import 'dart:ui_web' as ui_web;

/// URL of the Emscripten glue bundled as a Flutter asset, honoring the app's
/// base href.
String loroWebAssetUrl() => ui_web.assetManager.getAssetUrl(
  'packages/loro_crdt/src/web/loro_crdt_ffi.js',
);
