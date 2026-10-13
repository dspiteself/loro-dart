import 'package:loro_crdt/loro_crdt.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  setUpLoro();

  group('LoroText', () {
    late LoroDoc doc;
    late LoroText text;

    setUp(() {
      doc = LoroDoc();
      text = doc.getText('t');
    });

    test('indices are UTF-16 code units, like Dart strings', () {
      const s = 'a😀b';
      text.insert(0, s);
      expect(text.length, s.length); // 4: the emoji is a surrogate pair
      expect(text.lengthIn(TextUnit.unicode), 3);
      expect(text.lengthIn(TextUnit.utf8), 6);
      text.insert(3, 'X'); // after the emoji
      expect(text.toString(), 'a😀Xb');
      text.delete(1, 2); // the emoji
      expect(text.toString(), 'aXb');
    });

    test('other units', () {
      text.insert(0, 'a😀b');
      text.insert(2, 'U', unit: TextUnit.unicode);
      expect(text.toString(), 'a😀Ub');
      text.insert(5, '8', unit: TextUnit.utf8);
      expect(text.toString(), 'a😀8Ub');
      expect(text.slice(1, 2, unit: TextUnit.unicode), '😀');
      expect(text.convertPos(3, from: TextUnit.utf16, to: TextUnit.unicode), 2);
      expect(
        text.convertPos(99, from: TextUnit.utf16, to: TextUnit.unicode),
        isNull,
      );
    });

    test('splitting a surrogate pair is rejected', () {
      text.insert(0, '😀');
      expect(() => text.insert(1, 'x'), throwsA(isA<LoroException>()));
    });

    test('slice, splice and push', () {
      text.insert(0, 'Hello world');
      expect(text.slice(6, 11), 'world');
      expect(text.splice(0, 5, 'Howdy'), 'Hello');
      text.push('!');
      expect(text.toString(), 'Howdy world!');
      expect(text.isEmpty, isFalse);
    });

    test('out of bounds edits throw', () {
      expect(
        () => text.insert(1, 'x'),
        throwsA(
          isA<LoroException>().having((e) => e.code, 'code', 'OutOfBound'),
        ),
      );
      expect(() => text.delete(0, 1), throwsA(isA<LoroException>()));
    });

    test('update computes a minimal diff', () {
      text.insert(0, 'The quick fox');
      doc.commit();
      final ops = doc.opCount;
      text.update('The quick brown fox');
      doc.commit();
      expect(text.toString(), 'The quick brown fox');
      expect(doc.opCount - ops, 'brown '.length);
      text.update('line one\nline 2\n', byLine: true);
      expect(text.toString(), 'line one\nline 2\n');
    });

    test('rich text marks and deltas', () {
      doc.configTextStyle({'bold': ExpandType.after, 'link': ExpandType.none});
      text.insert(0, 'Hello world');
      text.mark(0, 5, 'bold', true);
      text.mark(6, 11, 'link', 'https://loro.dev');
      expect(text.toDelta(), [
        const TextInsert('Hello', attributes: {'bold': true}),
        const TextInsert(' '),
        const TextInsert('world', attributes: {'link': 'https://loro.dev'}),
      ]);
      text.insert(5, '!'); // bold expands after
      text.insert(12, '?'); // link does not
      expect(
        text.toDelta().first,
        const TextInsert('Hello!', attributes: {'bold': true}),
      );
      expect(text.toString(), 'Hello! world?');
      text.unmark(0, 6, 'bold');
      expect(text.toDelta().first, const TextInsert('Hello! '));
      expect(text.sliceDelta(7, 12), [
        const TextInsert('world', attributes: {'link': 'https://loro.dev'}),
      ]);
      expect(text.getRichTextValue(), isA<List>());
    });

    test('applyDelta', () {
      doc.configTextStyle({'bold': ExpandType.after});
      text.insert(0, 'abc');
      text.applyDelta([
        const TextRetain(1),
        const TextDelete(1),
        const TextInsert('Z', attributes: {'bold': true}),
      ]);
      expect(text.toString(), 'aZc');
      expect(
        text.toDelta()[1],
        const TextInsert('Z', attributes: {'bold': true}),
      );
      expect(TextDelta.fromJson({'retain': 2}), const TextRetain(2));
      expect(const TextInsert('x').toJson(), {'insert': 'x'});
    });

    test('cursors follow concurrent edits', () {
      final (a, b) = twoPeers();
      final ta = a.getText('t');
      ta.insert(0, 'hello world');
      a.commit();
      b.import(a.exportSnapshot());

      final cursor = ta.getCursor(6)!; // before "world"
      expect(cursor.container, ta.id);
      final restored = Cursor.decode(cursor.encode());
      expect(restored, cursor);

      b.getText('t').insert(0, '😀 ');
      b.commit();
      sync(a, b);
      expect(a.getCursorPos(restored).offset, 6 + '😀 '.length);
      expect(b.getCursorPos(restored).offset, 6 + '😀 '.length);
    });

    test('editor at position', () {
      final (a, b) = twoPeers();
      a.getText('t').insert(0, 'aa');
      a.commit();
      sync(a, b);
      b.getText('t').insert(2, 'bb');
      b.commit();
      sync(a, b);
      expect(a.getText('t').getEditorAt(0), '1');
      expect(a.getText('t').getEditorAt(3), '2');
    });

    test('detached text', () {
      final detached = LoroText()..insert(0, 'draft');
      expect(detached.isAttached, isFalse);
      expect(detached.doc, isNull);
      expect(detached.toString(), 'draft');
      final attached = doc.getMap('m').setContainer('note', detached);
      expect(attached.isAttached, isTrue);
      expect(attached.toString(), 'draft');
      expect(detached.getAttached(), attached);
    });
  });
}
