import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loro_crdt_flutter/loro_crdt_flutter.dart';

void main() {
  setUpAll(ensureLoroInitialized);

  group('TextSplice.between', () {
    test('finds the minimal splice', () {
      expect(TextSplice.between('hello', 'help'), const TextSplice(3, 2, 'p'));
      expect(TextSplice.between('', 'abc'), const TextSplice(0, 0, 'abc'));
      expect(TextSplice.between('abc', ''), const TextSplice(0, 3, ''));
      expect(TextSplice.between('aaa', 'aaaa'), const TextSplice(3, 0, 'a'));
    });

    test('never splits surrogate pairs', () {
      // Same high surrogate, different low surrogate.
      expect(TextSplice.between('😀', '😁'), const TextSplice(0, 2, '😁'));
      // Same low surrogate, different high surrogate.
      expect(
        TextSplice.between('a\u{1F600}b', 'a\u{1FA00}b'),
        const TextSplice(1, 2, '\u{1FA00}'),
      );
      expect(TextSplice.between('x😀', '😀'), const TextSplice(0, 1, ''));
      expect(TextSplice.between('😀😀', '😀'), const TextSplice(2, 2, ''));
    });
  });

  group('transformOffset', () {
    const delta = [TextRetain(2), TextDelete(2), TextInsert('XYZ')];
    test('moves offsets through retains, deletes and inserts', () {
      expect(transformOffset(0, delta), 0);
      expect(transformOffset(2, delta), 2); // insert lands after the caret
      expect(transformOffset(3, delta), 2); // inside the deletion
      expect(transformOffset(4, delta), 2); // remote insert at the caret
      expect(transformOffset(6, delta), 6 - 2 + 3);
    });
  });

  group('LoroTextEditingController', () {
    late LoroDoc doc;
    late LoroText text;
    late LoroTextEditingController controller;

    setUp(() {
      doc = LoroDoc();
      text = doc.getText('t');
      text.insert(0, 'hello');
      doc.commit();
      controller = LoroTextEditingController(text);
    });

    tearDown(() => controller.dispose());

    test('starts with the text content', () {
      expect(controller.text, 'hello');
    });

    test('local edits are written to Loro and committed', () {
      final origins = <String>[];
      final sub = doc.subscribe((e) => origins.add(e.origin));
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection.collapsed(offset: 11),
      );
      expect(text.toString(), 'hello world');
      expect(doc.pendingTransactionLength, 0);
      expect(origins, [LoroTextEditingController.defaultCommitOrigin]);
      controller.text = 'h😀llo world';
      expect(text.toString(), 'h😀llo world');
      controller.text = 'h😁llo world';
      expect(text.toString(), 'h😁llo world');
      sub.unsubscribe();
    });

    test('remote edits update the field and keep the caret', () {
      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 4), // before the "o"
      );
      final remote = LoroDoc.fromSnapshot(doc.exportSnapshot());
      remote.getText('t').insert(0, '>> ');
      remote.getText('t').insert(remote.getText('t').length, '!');
      remote.commit();
      doc.import(remote.exportUpdates(from: doc.oplogVersion));
      expect(controller.text, '>> hello!');
      expect(controller.selection, const TextSelection.collapsed(offset: 7));
    });

    test('a deletion around the selection collapses it', () {
      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection(baseOffset: 1, extentOffset: 4),
      );
      text.delete(0, 5);
      text.insert(0, 'bye');
      doc.commit();
      expect(controller.text, 'bye');
      expect(controller.selection, const TextSelection.collapsed(offset: 0));
    });

    test('undo flows back into the field', () {
      final undo = UndoManager(doc);
      controller.text = 'hello there';
      expect(undo.undo(), isTrue);
      expect(controller.text, 'hello');
      undo.dispose();
    });

    test('edits rejected by the document are reverted', () {
      final v = doc.oplogFrontiers;
      text.insert(5, '!');
      doc.commit();
      doc.checkout(v);
      expect(controller.text, 'hello');
      controller.text = 'hello?';
      expect(controller.text, 'hello');
      doc.checkoutToLatest();
      expect(controller.text, 'hello!');
    });

    test('uncommitted edits at construction are not applied twice', () {
      text.insert(5, ' world'); // not committed
      final c = LoroTextEditingController(text);
      expect(c.text, 'hello world');
      doc.commit();
      expect(c.text, 'hello world');
      c.text = 'hello world!';
      doc.commit();
      expect(c.text, 'hello world!');
      expect(text.toString(), 'hello world!');
      c.dispose();
    });

    test('uncommitted edits made elsewhere reach the field first', () {
      text.insert(0, '>> '); // edited directly, not committed
      controller.text = 'hello!'; // computed against the stale field
      expect(controller.text, '>> hello');
      expect(text.toString(), '>> hello');
      controller.text = '>> hello!';
      expect(text.toString(), '>> hello!');
      doc.commit();
      expect(controller.text, '>> hello!');
    });

    test('requires an attached text', () {
      expect(() => LoroTextEditingController(LoroText()), throwsArgumentError);
    });

    testWidgets('typing in a TextField updates Loro', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(child: TextField(controller: controller)),
        ),
      );
      await tester.enterText(find.byType(TextField), 'typed text');
      expect(text.toString(), 'typed text');

      // A remote change re-renders the field.
      final remote = LoroDoc.fromSnapshot(doc.exportSnapshot());
      remote.getText('t').insert(0, 'remote ');
      remote.commit();
      doc.import(remote.exportUpdates(from: doc.oplogVersion));
      await tester.pump();
      expect(find.text('remote typed text'), findsOneWidget);
    });

    testWidgets('renders rich-text marks', (tester) async {
      doc.configTextStyle({'bold': ExpandType.after});
      text.mark(0, 2, 'bold', true);
      doc.commit();
      final styled = LoroTextEditingController(
        text,
        attributeStyle: (attrs) => attrs['bold'] == true
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Material(child: TextField(controller: styled)),
        ),
      );
      final span = styled.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        withComposing: false,
      );
      expect(span.children, hasLength(2));
      expect((span.children!.first as TextSpan).text, 'he');
      expect(
        (span.children!.first as TextSpan).style?.fontWeight,
        FontWeight.bold,
      );
      styled.dispose();
    });
  });
}
