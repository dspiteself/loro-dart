import 'dart:typed_data';

import 'package:loro_crdt/loro_crdt.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  setUpLoro();

  group('LoroMap', () {
    test('basic operations', () {
      final doc = LoroDoc();
      final map = doc.getMap('m');
      expect(map.isEmpty, isTrue);
      map['b'] = 2;
      map['a'] = 'one';
      map.set('c', [1, 2]);
      expect(map['a'], 'one');
      expect(map.get('missing'), isNull);
      expect(map.containsKey('a'), isTrue);
      map['nil'] = null;
      expect(map.containsKey('nil'), isTrue);
      expect(map.containsKey('missing'), isFalse);
      expect(map.keys, ['a', 'b', 'c', 'nil']);
      expect(map.length, 4);
      map.delete('b');
      expect(map.toJson(), {
        'a': 'one',
        'c': [1, 2],
        'nil': null,
      });
      map.clear();
      expect(map.isEmpty, isTrue);
    });

    test('child containers', () {
      final doc = LoroDoc();
      final map = doc.getMap('m');
      final text = map.setContainer('text', LoroText());
      text.insert(0, 'x');
      expect(map['text'], isA<LoroText>());
      expect((map['text']! as LoroText).toString(), 'x');
      expect(map.entries.keys, ['text']);
      expect(map.values.single, text);
      expect(map.getShallowValue(), {'text': text.id});
    });

    test('getOrCreateContainer merges concurrent creation', () {
      final (a, b) = twoPeers();
      a.getMap('m').getOrCreateContainer<LoroList>('items').push('from a');
      b.getMap('m').getOrCreateContainer<LoroList>('items').push('from b');
      a.commit();
      b.commit();
      sync(a, b);
      final items = a.getMap('m').getOrCreateContainer<LoroList>('items');
      expect(items.toJson(), unorderedEquals(['from a', 'from b']));
      expect(b.toJson(), a.toJson());
    });

    test('last writer wins and last editor', () {
      final (a, b) = twoPeers();
      a.getMap('m')['k'] = 'a';
      a.commit();
      sync(a, b);
      b.getMap('m')['k'] = 'b';
      b.commit();
      sync(a, b);
      expect(a.getMap('m')['k'], 'b');
      expect(a.getMap('m').getLastEditor('k'), '2');
    });

    test('unsupported values throw', () {
      final map = LoroDoc().getMap('m');
      expect(() => map['x'] = DateTime(2020), throwsArgumentError);
      expect(() => map['x'] = {1: 'a'}, throwsArgumentError);
      expect(() => map['x'] = LoroText(), throwsArgumentError);
    });

    test('binary values', () {
      final map = LoroDoc().getMap('m');
      map['bytes'] = Uint8List.fromList([0, 255]);
      expect(map['bytes'], Uint8List.fromList([0, 255]));
    });

    test('large integers and doubles', () {
      final map = LoroDoc().getMap('m');
      map['i'] = 1 << 40;
      map['neg'] = -(1 << 40) - 7;
      map['d'] = 0.1;
      expect(map['i'], 1 << 40);
      expect(map['neg'], -(1 << 40) - 7);
      expect(map['d'], 0.1);
    });
  });

  group('LoroList', () {
    test('basic operations', () {
      final list = LoroDoc().getList('l');
      list.push(1);
      list.push('two');
      list.insert(0, 0);
      expect(list.toJson(), [0, 1, 'two']);
      expect(list[1], 1);
      expect(list.get(5), isNull);
      expect(list.length, 3);
      expect(list.pop(), 'two');
      list.delete(0, 1);
      expect(list.toList(), [1]);
      list.clear();
      expect(list.isEmpty, isTrue);
      expect(list.pop(), isNull);
    });

    test('nested containers and ids', () {
      final doc = LoroDoc()..peerId = '4';
      final list = doc.getList('l');
      final map = list.pushContainer(LoroMap());
      map['k'] = 'v';
      final text = list.insertContainer(0, LoroText());
      text.insert(0, 'hi');
      expect(doc.toJson(), {
        'l': [
          'hi',
          {'k': 'v'},
        ],
      });
      expect(list[0], text);
      expect(list.getIdAt(1), const Id('4', 0));
      expect(list.getCursor(1), isNotNull);
    });

    test('concurrent inserts keep both', () {
      final (a, b) = twoPeers();
      a.getList('l').push('a');
      b.getList('l').push('b');
      a.commit();
      b.commit();
      sync(a, b);
      expect(a.getList('l').toJson(), unorderedEquals(['a', 'b']));
      expect(a.getList('l').toJson(), b.getList('l').toJson());
    });
  });

  group('LoroMovableList', () {
    test('set and move', () {
      final doc = LoroDoc()..peerId = '8';
      final list = doc.getMovableList('l');
      list.push('a');
      list.push('b');
      list.push('c');
      list.move(0, 2);
      expect(list.toJson(), ['b', 'c', 'a']);
      list[1] = 'C';
      expect(list.toJson(), ['b', 'C', 'a']);
      final counter = list.setContainer(0, LoroCounter());
      counter.increment(3);
      expect(list.toJson(), [3.0, 'C', 'a']);
      expect(list.getCreatorAt(1), '8');
      expect(list.getLastMoverAt(2), '8');
      expect(list.getLastEditorAt(1), '8');
    });

    test('concurrent moves do not duplicate', () {
      final (a, b) = twoPeers();
      final la = a.getMovableList('l');
      la.push('x');
      la.push('y');
      la.push('z');
      a.commit();
      sync(a, b);
      la.move(0, 2);
      b.getMovableList('l').move(0, 1);
      a.commit();
      b.commit();
      sync(a, b);
      final result = a.getMovableList('l').toJson();
      expect(result, b.getMovableList('l').toJson());
      expect(result, unorderedEquals(['x', 'y', 'z']));
    });

    test('getIdAt is List-only', () {
      expect(() => LoroMovableList().getCursor(0), returnsNormally);
    });
  });

  group('LoroCounter', () {
    test('concurrent increments add up', () {
      final (a, b) = twoPeers();
      a.getCounter('c').increment(2);
      b.getCounter('c').increment(3.5);
      b.getCounter('c').decrement();
      a.commit();
      b.commit();
      sync(a, b);
      expect(a.getCounter('c').value, 4.5);
      expect(b.toJson(), {'c': 4.5});
    });
  });

  group('LoroTree', () {
    test('create, move and delete nodes', () {
      final doc = LoroDoc()..peerId = '6';
      final tree = doc.getTree('tree');
      final root = tree.createNode();
      root.data['name'] = 'root';
      final a = root.createNode();
      final b = root.createNode();
      final c = root.createNode(index: 0);
      expect(root.children(), [c, a, b]);
      expect(a.parent, root);
      expect(a.index, 1);
      expect(tree.rootIds(), [root.id]);
      expect(tree.childrenCount(root.id), 3);

      b.moveBefore(c);
      expect(root.children(), [b, c, a]);
      a.move();
      expect(tree.roots(), [root, a]);
      expect(a.parent, isNull);
      expect(tree.parent(a.id), const TreeParent.root());

      c.delete();
      expect(c.isDeleted, isTrue);
      expect(tree.contains(c.id), isTrue);
      expect(tree.nodeIds(), unorderedEquals([root.id, a.id, b.id]));
      expect(tree.nodeIds(withDeleted: true), hasLength(4));
      expect(tree.getNodes(withDeleted: true).length, 4);
      expect(root.fractionalIndex, isNotNull);
      expect(tree.getLastMoveId(a.id), isNotNull);
      expect(TreeId.parse(root.id.toString()), root.id);
    });

    test('moving a node under its descendant fails', () {
      final tree = LoroDoc().getTree('t');
      final parent = tree.createNode();
      final child = parent.createNode();
      expect(() => parent.move(parent: child), throwsA(isA<LoroException>()));
    });

    test('toJson includes metadata', () {
      final tree = LoroDoc().getTree('t');
      final n = tree.createNode();
      n.data['title'] = 'Hello';
      n.createNode();
      final json = tree.toJson();
      expect(json, hasLength(1));
      final node = json.single! as Map;
      expect(node['meta'], {'title': 'Hello'});
      expect(node['children'], hasLength(1));
    });

    test('fractional index can be disabled', () {
      final tree = LoroDoc().getTree('t');
      expect(tree.isFractionalIndexEnabled, isTrue);
      tree.disableFractionalIndex();
      expect(tree.isFractionalIndexEnabled, isFalse);
      expect(() => tree.createNode(index: 0), throwsA(isA<LoroException>()));
      tree.enableFractionalIndex(8);
      expect(tree.createNode(index: 0), isA<LoroTreeNode>());
    });
  });
}
