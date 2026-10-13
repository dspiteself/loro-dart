import 'package:loro_crdt/loro_crdt.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  final out = web.document.querySelector('#out')!;
  try {
    await initLoro(url: 'loro_crdt_ffi.js');
    final doc = LoroDoc()..peerId = '18446744073709551557';
    doc.getText('t').insert(0, 'hello from wasm 👋');
    doc.commit();
    final copy = LoroDoc()..import(doc.exportSnapshot());
    out.textContent =
        'OK peer=${doc.peerId} text=${copy.getText('t')} jsNumbers=${identical(0, 0.0)}';
  } catch (e, s) {
    out.textContent = 'FAIL $e\n$s';
  }
}
