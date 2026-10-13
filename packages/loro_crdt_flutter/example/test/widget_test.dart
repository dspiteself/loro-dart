import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loro_crdt_flutter/loro_crdt_flutter.dart';
import 'package:loro_crdt_flutter_example/main.dart';

void main() {
  setUpAll(ensureLoroInitialized);

  testWidgets('edits sync between peers, and catch up after going offline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const DemoApp());

    final alice = find.byKey(const Key('notes-Alice'));
    final bob = find.byKey(const Key('notes-Bob'));
    String textOf(Finder f) => tester.widget<TextField>(f).controller!.text;

    expect(textOf(bob), 'Edit me on either side. 👋');

    await tester.enterText(alice, 'Hello from Alice');
    await tester.pump();
    expect(textOf(bob), 'Hello from Alice');

    await tester.tap(find.byKey(const Key('online')));
    await tester.pump();
    await tester.enterText(bob, 'Hello from Alice and Bob');
    await tester.tap(find.byKey(const Key('like-Alice')));
    await tester.pump();
    expect(textOf(alice), 'Hello from Alice');

    await tester.tap(find.byKey(const Key('online')));
    await tester.pump();
    expect(textOf(alice), 'Hello from Alice and Bob');
    expect(
      find.descendant(
        of: find.byKey(const Key('like-Bob')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });
}
