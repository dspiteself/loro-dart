import 'dart:convert';
import 'dart:typed_data';

import 'package:loro_crdt/loro_crdt.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  setUpLoro();

  test('reports the Loro version', () {
    expect(LoroDoc.loroVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  group('peer ids', () {
    test('round-trip exactly, including values above 2^53 and 2^63', () {
      final doc = LoroDoc();
      for (final peer in [
        '0',
        '1',
        '9007199254740993',
        '18446744073709551557',
      ]) {
        doc.peerId = peer;
        expect(doc.peerId, peer);
      }
    });

    test('random by default', () {
      expect(LoroDoc().peerId, isNot(LoroDoc().peerId));
    });

    test('invalid ids throw', () {
      expect(() => LoroDoc().peerId = 'abc', throwsA(isA<LoroException>()));
      expect(
        () => LoroDoc().peerId = '18446744073709551616',
        throwsA(isA<LoroException>()),
      );
    });
  });

  group('snapshot and updates', () {
    test('snapshot restores the full document', () {
      final doc = LoroDoc();
      doc.getText('text').insert(0, 'hello');
      doc.getMap('map')['k'] = 'v';
      doc.getList('list').push(1);
      doc.commit();

      final snapshot = doc.exportSnapshot();
      final restored = LoroDoc.fromSnapshot(snapshot);
      expect(restored.toJson(), doc.toJson());
      expect(LoroDoc()..import(snapshot), isA<LoroDoc>());
      expect((LoroDoc()..import(snapshot)).toJson(), doc.toJson());
    });

    test('incremental updates sync two peers', () {
      final (a, b) = twoPeers();
      a.getText('t').insert(0, 'A');
      b.getText('t').insert(0, 'B');
      a.commit();
      b.commit();
      sync(a, b);
      expect(a.getText('t').toString(), b.getText('t').toString());
      expect(a.getText('t').toString(), anyOf('AB', 'BA'));
      expect(a.oplogVersion, b.oplogVersion);
      expect(a.oplogVersion, {'1': 1, '2': 1});
    });

    test('import reports pending updates with missing dependencies', () {
      final a = LoroDoc()..peerId = '1';
      final text = a.getText('t');
      text.insert(0, 'a');
      a.commit();
      final v1 = a.oplogVersion;
      text.insert(1, 'b');
      a.commit();
      final second = a.exportUpdates(from: v1);

      final b = LoroDoc();
      final status = b.import(second);
      expect(status.success, isEmpty);
      expect(status.pending, [const IdSpan('1', 1, 2)]);
      expect(b.getText('t').toString(), '');

      final status2 = b.import(a.exportUpdates(from: VersionVector.empty()));
      expect(status2.pending, isNull);
      expect(b.getText('t').toString(), 'ab');
    });

    test('importBatch', () {
      final a = LoroDoc();
      final blobs = <Uint8List>[];
      for (var i = 0; i < 3; i++) {
        final v = a.oplogVersion;
        a.getList('l').push(i);
        a.commit();
        blobs.add(a.exportUpdates(from: v));
      }
      final b = LoroDoc()..importBatch(blobs.reversed.toList());
      expect(b.getList('l').toJson(), [0, 1, 2]);
    });

    test('import with origin is visible to listeners', () {
      final a = LoroDoc();
      a.getText('t').insert(0, 'x');
      final b = LoroDoc();
      final origins = <String>[];
      final sub = b.subscribe((e) => origins.add(e.origin));
      b.import(a.exportSnapshot(), origin: 'network');
      expect(origins, ['network']);
      sub.unsubscribe();
    });

    test('invalid data throws', () {
      expect(
        () => LoroDoc().import(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<LoroException>()),
      );
    });

    test('shallow snapshot and state-only exports', () {
      final doc = LoroDoc();
      for (var i = 0; i < 5; i++) {
        doc.getList('l').push(i);
        doc.commit();
      }
      final shallow = LoroDoc()
        ..import(doc.export(ExportMode.shallowSnapshot(doc.oplogFrontiers)));
      expect(shallow.isShallow, isTrue);
      expect(shallow.toJson(), doc.toJson());

      final stateOnly = LoroDoc()..import(doc.export(ExportMode.stateOnly()));
      expect(stateOnly.toJson(), doc.toJson());

      final meta = LoroDoc.decodeImportBlobMeta(doc.exportSnapshot());
      expect(meta.isSnapshot, isTrue);
      expect(meta.changeCount, greaterThan(0));
    });

    test('updates in range and snapshot at a version', () {
      final doc = LoroDoc()..peerId = '7';
      doc.getText('t').insert(0, 'ab');
      doc.commit();
      final f = doc.oplogFrontiers;
      doc.getText('t').insert(2, 'cd');
      doc.commit();

      final at = LoroDoc()..import(doc.export(ExportMode.snapshotAt(f)));
      expect(at.getText('t').toString(), 'ab');

      final range = doc.export(
        ExportMode.updatesInRange([const IdSpan('7', 0, 2)]),
      );
      expect((LoroDoc()..import(range)).getText('t').toString(), 'ab');
    });

    test('JSON updates round-trip', () {
      final a = LoroDoc();
      a.getMap('m')['n'] = 1;
      a.commit();
      final json = a.exportJsonUpdates();
      expect(jsonDecode(json), containsPair('changes', isA<List>()));
      final b = LoroDoc()..importJsonUpdates(json);
      expect(b.toJson(), a.toJson());
    });
  });

  group('versions', () {
    test('frontiers and version vectors convert both ways', () {
      final doc = LoroDoc()..peerId = '5';
      doc.getText('t').insert(0, 'abc');
      doc.commit();
      expect(doc.oplogFrontiers, Frontiers([const Id('5', 2)]));
      expect(doc.oplogVersion, {'5': 3});
      expect(doc.frontiersToVersion(doc.oplogFrontiers), doc.oplogVersion);
      expect(doc.versionToFrontiers(doc.oplogVersion), doc.oplogFrontiers);
      expect(doc.opCount, 3);
      expect(doc.changeCount, 1);
    });

    test('version vectors compare partially', () {
      final a = VersionVector({'1': 2});
      final b = VersionVector({'1': 1, '2': 1});
      expect(a.partialCompare(b), isNull);
      expect(a.partialCompare(VersionVector({'1': 1})), 1);
      expect(VersionVector.empty().partialCompare(a), -1);
      expect(a.includes(VersionVector({'1': 2})), isTrue);
    });

    test('compare frontiers', () {
      final (a, b) = twoPeers();
      a.getText('t').insert(0, 'a');
      a.commit();
      final f1 = a.oplogFrontiers;
      a.getText('t').insert(1, 'b');
      a.commit();
      expect(a.compareFrontiers(f1, a.oplogFrontiers), -1);
      expect(a.compareWithFrontiers(f1), 1);

      b.getText('t').insert(0, 'x');
      b.commit();
      sync(a, b);
      expect(a.compareFrontiers(f1, Frontiers([const Id('2', 0)])), isNull);
    });

    test('binary encodings are compatible with other bindings', () {
      final vv = VersionVector({'1': 3, '18446744073709551557': 9});
      expect(
        VersionEncoding.decodeVersion(VersionEncoding.encodeVersion(vv)),
        vv,
      );
      final f = Frontiers([const Id('1', 2), const Id('3', 0)]);
      expect(
        VersionEncoding.decodeFrontiers(VersionEncoding.encodeFrontiers(f)),
        f,
      );
    });
  });

  group('time travel', () {
    test('checkout shows old versions and blocks edits', () {
      final doc = LoroDoc();
      final text = doc.getText('t');
      text.insert(0, 'one');
      doc.commit();
      final v1 = doc.oplogFrontiers;
      text.insert(3, ' two');
      doc.commit();

      doc.checkout(v1);
      expect(doc.isDetached, isTrue);
      expect(text.toString(), 'one');
      expect(() => text.insert(0, 'x'), throwsA(isA<LoroException>()));
      doc.checkoutToLatest();
      expect(doc.isDetached, isFalse);
      expect(text.toString(), 'one two');
    });

    test('revertTo creates new changes', () {
      final doc = LoroDoc();
      doc.getText('t').insert(0, 'a');
      doc.commit();
      final v1 = doc.oplogFrontiers;
      doc.getText('t').insert(1, 'b');
      doc.commit();
      doc.revertTo(v1);
      expect(doc.getText('t').toString(), 'a');
      expect(doc.opCount, greaterThan(2));
    });

    test('fork copies the document', () {
      final doc = LoroDoc();
      doc.getText('t').insert(0, 'abc');
      doc.commit();
      final v = doc.oplogFrontiers;
      doc.getText('t').insert(3, 'd');
      final fork = doc.fork();
      expect(fork.getText('t').toString(), 'abcd');
      expect(fork.peerId, isNot(doc.peerId));
      expect(doc.forkAt(v).getText('t').toString(), 'abc');
    });

    test('diff and applyDiff', () {
      final doc = LoroDoc();
      final v0 = doc.oplogFrontiers;
      doc.getText('t').insert(0, 'hi');
      doc.getMap('m')['x'] = 1;
      doc.commit();
      final batch = doc.diff(v0, doc.oplogFrontiers);
      final kinds = batch.entries.map((e) => e.$2.runtimeType).toSet();
      expect(kinds, {TextDiff, MapDiff});

      final other = LoroDoc()..applyDiff(batch);
      expect(other.toJson(), doc.toJson());
    });
  });

  group('history', () {
    test('commit metadata', () {
      final doc = LoroDoc()..peerId = '9';
      doc.setRecordTimestamp(true);
      doc.getText('t').insert(0, 'x');
      doc.commit(message: 'first', timestamp: 1700000000);
      doc.getText('t').insert(1, 'y');
      doc.setNextCommitMessage('second');
      doc.commit();

      final first = doc.getChange(const Id('9', 0))!;
      expect(first.message, 'first');
      expect(first.timestamp, 1700000000);
      expect(first.length, 1);
      expect(doc.getChange(const Id('9', 1))!.message, 'second');
      expect(doc.getChange(const Id('9', 99)), isNull);

      final ancestors = doc.changeAncestors([const Id('9', 1)]);
      expect(ancestors.map((c) => c.message), ['second', 'first']);
      expect(doc.getChangedContainersIn(const Id('9', 0), 2), [
        ContainerId.root('t', ContainerType.text),
      ]);
    });

    test('pending transaction length', () {
      final doc = LoroDoc();
      doc.getText('t').insert(0, 'abc');
      expect(doc.pendingTransactionLength, 3);
      doc.commit();
      expect(doc.pendingTransactionLength, 0);
    });
  });

  group('paths', () {
    test('getByPath, jsonPath and getPathToContainer', () {
      final doc = LoroDoc();
      final map = doc.getMap('root');
      final list = map.setContainer('items', LoroList());
      list.push('a');
      list.push('b');
      final inner = list.pushContainer(LoroMap());
      inner['price'] = 5;
      doc.commit();

      expect(doc.getByPath('root/items/0'), 'a');
      expect(doc.getByPath('root/missing'), isNull);
      expect(doc.getByPath('root/items'), isA<LoroList>());
      expect(doc.jsonPath(r'$.root.items[0]'), ['a']);
      expect(doc.jsonPath(r'$.root.items[*].price'), [5]);

      final path = doc.getPathToContainer(inner.id)!;
      expect(path.map((p) => p.index), ['root', 'items', 2]);
      expect(path.last.container, inner.id);
    });
  });

  group('containers', () {
    test('ids, lookup and identity', () {
      final doc = LoroDoc()..peerId = '3';
      final text = doc.getText('t');
      expect(text.id, ContainerId.root('t', ContainerType.text));
      expect(text.id.toString(), 'cid:root-t:Text');
      expect(ContainerId.parse('cid:root-t:Text'), text.id);
      final child = doc.getMap('m').setContainer('c', LoroText());
      expect(child.id.toString(), 'cid:0@3:Text');
      expect(child.id.id, const Id('3', 0));
      expect(doc.getContainer(child.id), child);
      expect(doc.hasContainer(child.id), isTrue);
      expect(doc.getContainer(ContainerId.parse('cid:5@3:Map')), isNull);
      expect(text.doc!.peerId, '3');
      expect(text, doc.getText('t'));
    });

    test('invalid root names throw', () {
      expect(() => LoroDoc().getText(''), throwsA(isA<LoroException>()));
      expect(() => LoroDoc().getText('a/b'), throwsA(isA<LoroException>()));
    });

    test('toJson resolves nested containers', () {
      final doc = LoroDoc();
      final m = doc.getMap('m');
      m['n'] = 1;
      m['f'] = 1.5;
      m['s'] = 'str';
      m['b'] = true;
      m['null'] = null;
      m['bytes'] = Uint8List.fromList([1, 2, 3]);
      m['nested'] = {
        'list': [1, 'two', null],
      };
      m.setContainer('text', LoroText()).insert(0, 'hi');
      doc.commit();
      expect(doc.toJson(), {
        'm': {
          'n': 1,
          'f': 1.5,
          's': 'str',
          'b': true,
          'null': null,
          'bytes': Uint8List.fromList([1, 2, 3]),
          'nested': {
            'list': [1, 'two', null],
          },
          'text': 'hi',
        },
      });
      expect(doc.getShallowValue(), {
        'm': ContainerId.root('m', ContainerType.map),
      });
    });

    test('hidden empty roots and deleted roots', () {
      final doc = LoroDoc();
      doc.getText('empty');
      doc.getText('full').insert(0, 'x');
      doc.setHideEmptyRootContainers(true);
      expect(doc.toJson().keys, ['full']);
      doc.deleteRootContainer(ContainerId.root('full', ContainerType.text));
      expect(doc.toJson().keys, isEmpty);
    });

    test('dispose releases the native handle', () {
      final doc = LoroDoc()..dispose();
      expect(doc.isDisposed, isTrue);
      expect(() => doc.peerId, throwsStateError);
      doc.dispose();
    });
  });
}
