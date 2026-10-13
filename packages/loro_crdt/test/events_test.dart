import 'dart:async';
import 'dart:typed_data';

import 'package:loro_crdt/loro_crdt.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  setUpLoro();

  test('events are delivered synchronously when a commit happens', () {
    final doc = LoroDoc();
    final events = <LoroEventBatch>[];
    final sub = doc.subscribe(events.add);
    doc.getText('t').insert(0, 'hi');
    expect(events, isEmpty); // not committed yet
    doc.commit(origin: 'me');
    expect(events, hasLength(1));
    final batch = events.single;
    expect(batch.by, EventTrigger.local);
    expect(batch.origin, 'me');
    final e = batch.events.single;
    expect(e.target, ContainerId.root('t', ContainerType.text));
    expect((e.diff as TextDiff).delta, [const TextInsert('hi')]);
    sub.unsubscribe();
    doc.getText('t').insert(0, 'x');
    doc.commit();
    expect(events, hasLength(1));
    expect(sub.isActive, isFalse);
  });

  test('implicit commits (export) also deliver events', () {
    final doc = LoroDoc();
    var count = 0;
    final sub = doc.subscribe((_) => count++);
    doc.getMap('m')['k'] = 1;
    doc.exportSnapshot();
    expect(count, 1);
    sub.unsubscribe();
  });

  test('text deltas use UTF-16 lengths', () {
    final doc = LoroDoc();
    doc.getText('t').insert(0, '😀😀');
    doc.commit();
    final deltas = <TextDelta>[];
    final sub = doc.subscribe(
      (b) => deltas.addAll((b.events.single.diff as TextDiff).delta),
    );
    doc.getText('t').insert(4, '!');
    doc.getText('t').delete(0, 2);
    doc.commit();
    expect(deltas, [
      const TextDelete(2),
      const TextRetain(2),
      const TextInsert('!'),
    ]);
    sub.unsubscribe();
  });

  test('map, list, counter and tree diffs', () {
    final doc = LoroDoc()..peerId = '1';
    final diffs = <Diff>[];
    final sub = doc.subscribe((b) => diffs.addAll(b.events.map((e) => e.diff)));
    final map = doc.getMap('m');
    map['a'] = 1;
    map['gone'] = 2;
    doc.commit();
    map.delete('gone');
    doc.getList('l').push('x');
    doc.getCounter('c').increment(5);
    final node = doc.getTree('t').createNode();
    doc.commit();

    expect((diffs[0] as MapDiff).updated, {'a': 1, 'gone': 2});
    final rest = {for (final d in diffs.skip(1)) d.runtimeType: d};
    expect((rest[MapDiff]! as MapDiff).deleted, {'gone'});
    expect((rest[ListDiff]! as ListDiff).delta, [
      const ListInsert(['x']),
    ]);
    expect((rest[CounterDiff]! as CounterDiff).increment, 5);
    final item = (rest[TreeDiff]! as TreeDiff).items.single;
    expect(item.action, TreeAction.create);
    expect(item.target, node.id);
    expect(item.parent, const TreeParent.root());
    expect(item.index, 0);
    sub.unsubscribe();
  });

  test('nested container events carry paths and live containers', () {
    final doc = LoroDoc();
    final batches = <LoroEventBatch>[];
    final sub = doc.subscribe(batches.add);
    final list = doc.getMap('root').setContainer('list', LoroList());
    final text = list.pushContainer(LoroText());
    text.insert(0, 'deep');
    doc.commit();

    final events = batches.single.events;
    final mapEvent = events.firstWhere((e) => e.diff is MapDiff);
    expect((mapEvent.diff as MapDiff).updated['list'], list);
    final textEvent = events.firstWhere((e) => e.diff is TextDiff);
    expect(textEvent.path.map((p) => p.index), ['root', 'list', 0]);
    final listEvent = events.firstWhere((e) => e.diff is ListDiff);
    final inserted =
        ((listEvent.diff as ListDiff).delta.single as ListInsert).values.single;
    expect(inserted, isA<LoroText>());
    expect(inserted.toString(), 'deep');
    sub.unsubscribe();
  });

  test('container subscriptions only see their subtree', () {
    final doc = LoroDoc();
    final a = doc.getText('a');
    final seen = <ContainerId>[];
    final sub = a.subscribe((batch) {
      expect(batch.currentTarget, a.id);
      seen.addAll(batch.events.map((e) => e.target));
    });
    doc.getText('b').insert(0, 'other');
    doc.commit();
    a.insert(0, 'mine');
    doc.commit();
    expect(seen, [a.id]);
    sub.unsubscribe();
  });

  test('import and checkout triggers', () {
    final source = LoroDoc();
    source.getText('t').insert(0, 'v1');
    source.commit();
    final v1 = source.oplogFrontiers;
    source.getText('t').insert(2, '+v2');
    source.commit();

    final doc = LoroDoc();
    final triggers = <EventTrigger>[];
    final sub = doc.subscribe((b) => triggers.add(b.by));
    doc.import(source.exportSnapshot());
    doc.checkout(v1);
    doc.checkoutToLatest();
    expect(triggers, [
      EventTrigger.import,
      EventTrigger.checkout,
      EventTrigger.checkout,
    ]);
    sub.unsubscribe();
  });

  test('local updates keep two peers in sync', () {
    final (a, b) = twoPeers();
    final subA = a.subscribeLocalUpdates(b.import);
    final subB = b.subscribeLocalUpdates(a.import);
    a.getText('t').insert(0, 'hello');
    a.commit();
    expect(b.getText('t').toString(), 'hello');
    b.getText('t').insert(5, ' world');
    b.commit();
    expect(a.getText('t').toString(), 'hello world');
    subA.unsubscribe();
    subB.unsubscribe();
  });

  test('listeners may edit the document', () {
    final doc = LoroDoc();
    final log = doc.getList('log');
    final sub = doc.getText('t').subscribe((_) {
      log.push('changed');
      doc.commit();
    });
    doc.getText('t').insert(0, 'x');
    doc.commit();
    expect(log.toJson(), ['changed']);
    sub.unsubscribe();
  });

  test('a throwing listener does not block others', () async {
    final doc = LoroDoc();
    var delivered = false;
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final bad = doc.subscribe((_) => throw StateError('boom'));
      final good = doc.subscribe((_) => delivered = true);
      doc.getText('t').insert(0, 'x');
      doc.commit();
      bad.unsubscribe();
      good.unsubscribe();
    }, (e, _) => errors.add(e));
    expect(delivered, isTrue);
    expect(errors.single, isA<StateError>());
  });

  test('streams subscribe while listened to', () async {
    final doc = LoroDoc();
    final updates = <Uint8List>[];
    final sub = doc.localUpdates.listen(updates.add);
    final events = doc.events.first;
    doc.getText('t').insert(0, 'x');
    doc.commit();
    expect((await events).events.single.diff, isA<TextDiff>());
    expect(updates, hasLength(1));
    await sub.cancel();
    doc.getText('t').insert(0, 'y');
    doc.commit();
    expect(updates, hasLength(1));
  });

  test('unsubscribing with queued events frees them', () {
    final doc = LoroDoc();
    final events = <LoroEventBatch>[];
    final sub = doc.subscribe(events.add);
    final other = doc.subscribe((_) => sub.unsubscribe());
    doc.getMap('m').setContainer('c', LoroText());
    doc.commit();
    other.unsubscribe();
    expect(sub.isActive, isFalse);
  });
}
