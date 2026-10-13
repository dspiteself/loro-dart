import 'package:loro_crdt/loro_crdt.dart';

import 'asset_url.dart' if (dart.library.js_interop) 'asset_url_web.dart';

/// Prepares Loro for use. Await it once before using any Loro API, e.g. in
/// `main()` before `runApp`.
///
/// On the web this loads the bundled wasm module; on other platforms the
/// native library is bundled by the build hook and this completes
/// immediately.
Future<void> ensureLoroInitialized() async {
  if (isLoroInitialized) return;
  await initLoro(url: loroWebAssetUrl());
}
