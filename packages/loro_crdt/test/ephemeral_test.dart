import 'dart:typed_data';

import 'package:loro_crdt/loro_crdt.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  setUpLoro();

  test('set, get and sync between peers', () async {
    final a = EphemeralStore();
    final b = EphemeralStore();
    final sub = a.subscribeLocalUpdates(b.apply);
    final events = <EphemeralStoreEvent>[];
    final bSub = b.subscribe(events.add);

    a['cursor'] = {'anchor': 1, 'focus': 4};
    a.set('name', 'Ada');
    expect(a['cursor'], {'anchor': 1, 'focus': 4});
    expect(b['name'], 'Ada');
    expect(b.keys, ['cursor', 'name']);
    expect(b.getAllStates(), {
      'cursor': {'anchor': 1, 'focus': 4},
      'name': 'Ada',
    });
    expect(events.first.by, EphemeralTrigger.import);
    expect(events.first.added, ['cursor']);

    // Entries are last-writer-wins on millisecond timestamps: a peer drops
    // a write that is not newer than the one it has.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    a.delete('name');
    expect(b['name'], isNull);
    expect(events.last.removed, ['name']);
    sub.unsubscribe();
    bSub.unsubscribe();
  });

  test('encode and apply', () {
    final a = EphemeralStore()..set('k', 1);
    final c = EphemeralStore()..apply(a.encodeAll());
    expect(c['k'], 1);
    final d = EphemeralStore()..apply(a.encode('k'));
    expect(d['k'], 1);
    expect(
      () => d.apply(Uint8List.fromList([9, 9, 9])),
      throwsA(isA<LoroException>()),
    );
  });

  test('entries expire', () async {
    final store = EphemeralStore(timeout: const Duration(milliseconds: 1))
      ..set('k', 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final events = <EphemeralStoreEvent>[];
    final sub = store.subscribe(events.add);
    store.removeOutdated();
    expect(store['k'], isNull);
    expect(events.single.by, EphemeralTrigger.timeout);
    sub.unsubscribe();
  });
}
