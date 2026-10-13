import 'package:loro_crdt/loro_crdt.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  setUpLoro();

  test('undo and redo local edits', () {
    final doc = LoroDoc();
    final undo = UndoManager(doc, mergeInterval: Duration.zero);
    final text = doc.getText('t');
    text.insert(0, 'hello');
    doc.commit();
    text.insert(5, ' world');
    doc.commit();
    expect(undo.canUndo, isTrue);
    expect(undo.undoCount, 2);

    expect(undo.undo(), isTrue);
    expect(text.toString(), 'hello');
    expect(undo.canRedo, isTrue);
    expect(undo.redo(), isTrue);
    expect(text.toString(), 'hello world');
    undo.undo();
    undo.undo();
    expect(text.toString(), '');
    expect(undo.undo(), isFalse);
    undo.dispose();
  });

  test('remote edits are not undone', () {
    final (a, b) = twoPeers();
    final undo = UndoManager(a, mergeInterval: Duration.zero);
    a.getText('t').insert(0, 'local ');
    a.commit();
    sync(a, b);
    b.getText('t').insert(6, 'remote');
    b.commit();
    sync(a, b);
    undo.undo();
    expect(a.getText('t').toString(), 'remote');
  });

  test('excluded origins, groups and checkpoints', () {
    final doc = LoroDoc();
    final undo = UndoManager(
      doc,
      mergeInterval: const Duration(hours: 1),
      excludeOriginPrefixes: ['sys'],
    );
    final list = doc.getList('l');
    list.push('ignored');
    doc.commit(origin: 'sys:init');
    expect(undo.canUndo, isFalse);

    list.push(1);
    doc.commit();
    list.push(2);
    doc.commit();
    expect(undo.undoCount, 1); // merged: within the merge interval
    undo.mergeInterval = Duration.zero;
    list.push(3);
    doc.commit();
    undo.recordNewCheckpoint();
    expect(undo.undoCount, 2);

    undo.groupStart();
    list.push(4);
    doc.commit();
    list.push(5);
    doc.commit();
    undo.groupEnd();
    undo.undo();
    expect(list.toJson(), ['ignored', 1, 2, 3]);

    undo.pause();
    expect(undo.isPaused, isTrue);
    undo.resume();
    undo.clear();
    expect(undo.canUndo, isFalse);
  });

  test('undo emits events', () {
    final doc = LoroDoc();
    final undo = UndoManager(doc);
    doc.getText('t').insert(0, 'x');
    doc.commit();
    var events = 0;
    final sub = doc.subscribe((_) => events++);
    undo.undo();
    expect(events, 1);
    sub.unsubscribe();
  });
}
