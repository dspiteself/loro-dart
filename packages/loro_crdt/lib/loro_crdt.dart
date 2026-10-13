/// Dart bindings for [Loro](https://loro.dev), a CRDT library for building
/// local-first, collaborative apps.
///
/// On native platforms (Android, iOS, macOS, Windows, Linux) the Rust
/// library is compiled and bundled automatically by the package's build
/// hook. On the web, call [initLoro] once before using any other API.
library;

import 'src/ffi/bindings.dart' as b;

export 'src/containers.dart'
    show
        LoroContainer,
        LoroCounter,
        LoroList,
        LoroMap,
        LoroMovableList,
        LoroText,
        LoroTree,
        LoroTreeNode,
        LoroUnknown,
        TreeNodeInfo;
export 'src/delta.dart'
    show
        ListDelete,
        ListDelta,
        ListInsert,
        ListRetain,
        TextDelete,
        TextDelta,
        TextInsert,
        TextRetain;
export 'src/doc.dart' show LoroDoc, VersionEncoding;
export 'src/ephemeral.dart' show EphemeralStore;
export 'src/errors.dart';
export 'src/events.dart'
    show
        CounterDiff,
        Diff,
        DiffBatch,
        EphemeralStoreEvent,
        EphemeralTrigger,
        EventTrigger,
        ListDiff,
        LoroEvent,
        LoroEventBatch,
        LoroSubscription,
        MapDiff,
        PathSegment,
        TextDiff,
        TreeAction,
        TreeDiff,
        TreeDiffItem,
        UnknownDiff;
export 'src/types.dart' hide makeCursor;
export 'src/undo.dart' show UndoManager;

/// Whether the native library is ready. Always `true` on native platforms;
/// on the web, `true` once [initLoro] has completed.
bool get isLoroInitialized => b.isLoaded;

/// Loads the native library. Required once before using Loro on the web;
/// a no-op on native platforms, where the library is bundled by the build
/// hook.
///
/// On the web, [url] points at the Emscripten glue file `loro_crdt_ffi.js`
/// (the matching `loro_crdt_ffi.wasm` must be served next to it). Both files
/// ship in this package under `lib/src/web/`; Flutter apps get them
/// automatically through the `loro_crdt_flutter` package.
Future<void> initLoro({String url = 'loro_crdt_ffi.js'}) => b.loadLibrary(url);
