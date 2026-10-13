import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:loro_crdt_flutter/loro_crdt_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ensureLoroInitialized();
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Loro CRDT demo',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const DemoPage(),
  );
}

/// One replica of the shared document, as it would live on one device.
class Peer {
  Peer(this.name, String peerId) : doc = LoroDoc()..peerId = peerId {
    notes = LoroTextEditingController(doc.getText('notes'));
    undo = UndoManager(doc, mergeInterval: const Duration(milliseconds: 600));
  }

  final String name;
  final LoroDoc doc;
  late final LoroTextEditingController notes;
  late final UndoManager undo;

  LoroCounter get likes => doc.getCounter('likes');

  void dispose() {
    notes.dispose();
    undo.dispose();
    doc.dispose();
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final alice = Peer('Alice', '1');
  final bob = Peer('Bob', '2');
  final _subscriptions = <LoroSubscription>[];
  bool online = true;

  @override
  void initState() {
    super.initState();
    alice.doc.getText('notes').insert(0, 'Edit me on either side. 👋');
    alice.doc.commit();
    _syncAll();
    for (final (from, to) in [(alice, bob), (bob, alice)]) {
      // A real app would send these bytes over the network.
      _subscriptions.add(
        from.doc.subscribeLocalUpdates((update) {
          if (online) _deliver(to, update);
        }),
      );
      // Rebuild for counter and undo state changes.
      _subscriptions.add(from.doc.subscribe((_) => setState(() {})));
    }
  }

  void _deliver(Peer to, Uint8List update) => to.doc.import(update);

  /// Exchanges everything each side is missing (after being offline).
  void _syncAll() {
    bob.doc.import(alice.doc.exportUpdates(from: bob.doc.oplogVersion));
    alice.doc.import(bob.doc.exportUpdates(from: alice.doc.oplogVersion));
  }

  void _setOnline(bool value) {
    setState(() => online = value);
    if (value) _syncAll();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.unsubscribe();
    }
    alice.dispose();
    bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final panels = [
      Expanded(child: PeerPanel(peer: alice)),
      const SizedBox(width: 16, height: 16),
      Expanded(child: PeerPanel(peer: bob)),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('Loro ${LoroDoc.loroVersion}'),
        actions: [
          Text(online ? 'Online' : 'Offline'),
          Switch(
            key: const Key('online'),
            value: online,
            onChanged: _setOnline,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth > 700
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: panels,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: panels,
                ),
        ),
      ),
    );
  }
}

class PeerPanel extends StatelessWidget {
  const PeerPanel({super.key, required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = peer.doc.oplogVersion;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(peer.name, style: theme.textTheme.titleLarge),
            Text(
              'peer ${peer.doc.peerId} · version '
              '${version.entries.map((e) => '${e.key}:${e.value}').join(' ')}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                key: Key('notes-${peer.name}'),
                controller: peer.notes,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Shared notes',
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  tooltip: 'Undo',
                  onPressed: peer.undo.canUndo ? peer.undo.undo : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: peer.undo.canRedo ? peer.undo.redo : null,
                  icon: const Icon(Icons.redo),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  key: Key('like-${peer.name}'),
                  onPressed: () {
                    peer.likes.increment();
                    peer.doc.commit();
                  },
                  icon: const Icon(Icons.thumb_up),
                  label: Text('${peer.likes.value.toInt()}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
