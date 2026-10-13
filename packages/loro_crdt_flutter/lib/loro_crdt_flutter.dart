/// Flutter integration for [loro_crdt](https://pub.dev/packages/loro_crdt).
///
/// * Re-exports the whole `loro_crdt` API.
/// * Bundles the web build of Loro; call [ensureLoroInitialized] before
///   using Loro (required on the web, harmless elsewhere).
/// * [LoroTextEditingController] binds a `TextField` to a `LoroText`.
library;

export 'package:loro_crdt/loro_crdt.dart';

export 'src/init.dart';
export 'src/text_controller.dart'
    show LoroTextEditingController, TextSplice, applyTextDelta, transformOffset;
