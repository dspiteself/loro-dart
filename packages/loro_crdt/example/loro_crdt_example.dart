import 'package:loro_crdt/loro_crdt.dart';

/// Two replicas edit concurrently while "offline", then exchange updates and
/// converge.
Future<void> main() async {
  await initLoro(); // Required on the web, a no-op elsewhere.

  final alice = LoroDoc()..peerId = '1';
  final bob = LoroDoc()..peerId = '2';

  alice.getText('title').insert(0, 'Groceries');
  alice.getList('items').push('milk');
  alice.commit();

  // Bob starts from Alice's snapshot.
  bob.import(alice.export(const ExportMode.snapshot()));

  // Concurrent edits.
  alice.getList('items').push('eggs');
  alice.commit();
  bob.getList('items').insert(0, 'coffee');
  bob.getText('title').insert(9, ' 🛒');
  bob.commit();

  // Exchange only what the other side is missing.
  bob.import(alice.exportUpdates(from: bob.oplogVersion));
  alice.import(bob.exportUpdates(from: alice.oplogVersion));

  print(alice.toJson()); // {items: [coffee, milk, eggs], title: Groceries 🛒}
  print(alice.toJson().toString() == bob.toJson().toString()); // true
}
