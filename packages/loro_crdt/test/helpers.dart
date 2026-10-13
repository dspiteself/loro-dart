import 'package:loro_crdt/loro_crdt.dart';
import 'package:test/test.dart';

/// Loads the library before the tests of a file. On the web, `dart test`
/// serves `lib/` under `packages/loro_crdt/`.
void setUpLoro() {
  setUpAll(() => initLoro(url: 'packages/loro_crdt/src/web/loro_crdt_ffi.js'));
}

/// Two documents with fixed peer ids, for deterministic tests.
(LoroDoc, LoroDoc) twoPeers() =>
    (LoroDoc()..peerId = '1', LoroDoc()..peerId = '2');

/// Exchanges all updates between [a] and [b].
void sync(LoroDoc a, LoroDoc b) {
  b.import(a.exportUpdates(from: b.oplogVersion));
  a.import(b.exportUpdates(from: a.oplogVersion));
}
