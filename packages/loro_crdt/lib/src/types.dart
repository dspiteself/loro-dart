import 'dart:collection';
import 'dart:typed_data';

import 'ffi/bindings.dart' as b;
import 'ffi/runtime.dart';

/// A peer id: the decimal string form of Loro's unsigned 64-bit peer id.
///
/// Strings are used instead of `int` because peer ids are random 64-bit
/// values, which a Dart `int` cannot hold on the web (and only holds as a
/// negative number above 2^63 on native platforms).
typedef PeerId = String;

/// The kind of a Loro container.
///
/// The order matches the codes used by the native library.
enum ContainerType {
  /// `LoroText`.
  text('Text'),

  /// `LoroMap`.
  map('Map'),

  /// `LoroList`.
  list('List'),

  /// `LoroMovableList`.
  movableList('MovableList'),

  /// `LoroTree`.
  tree('Tree'),

  /// `LoroCounter`.
  counter('Counter'),

  /// A type this version of Loro does not know (`LoroUnknown`).
  unknown('Unknown');

  const ContainerType(this.loroName);

  /// The name Loro uses in container ids, e.g. `Text` or `MovableList`.
  final String loroName;

  /// The type whose [loroName] is [name]. Names starting with `Unknown` give
  /// [unknown]; anything else throws a [FormatException].
  static ContainerType fromLoroName(String name) {
    for (final t in values) {
      if (t.loroName == name) return t;
    }
    if (name.startsWith('Unknown')) return unknown;
    throw FormatException('Unknown container type "$name"');
  }
}

int _comparePeers(PeerId a, PeerId b) =>
    a.length != b.length ? a.length.compareTo(b.length) : a.compareTo(b);

/// A unique operation id: the [counter]-th operation created by [peer].
final class Id implements Comparable<Id> {
  /// The [counter]-th operation of [peer].
  const Id(this.peer, this.counter);

  /// Parses Loro's `counter@peer` notation.
  factory Id.parse(String s) {
    final at = s.indexOf('@');
    if (at <= 0) throw FormatException('Invalid id "$s"');
    return Id(s.substring(at + 1), int.parse(s.substring(0, at)));
  }

  /// The peer that created the operation.
  final PeerId peer;

  /// The operation's index among the operations of [peer], from 0.
  final int counter;

  @override
  bool operator ==(Object other) =>
      other is Id && other.peer == peer && other.counter == counter;

  @override
  int get hashCode => Object.hash(peer, counter);

  @override
  int compareTo(Id other) {
    final p = _comparePeers(peer, other.peer);
    return p != 0 ? p : counter.compareTo(other.counter);
  }

  @override
  String toString() => '$counter@$peer';
}

/// The id of a node in a `LoroTree`: the [Id] of the operation that created
/// the node.
final class TreeId {
  /// The node created by the [counter]-th operation of [peer].
  const TreeId(this.peer, this.counter);

  /// Parses Loro's `counter@peer` notation.
  factory TreeId.parse(String s) {
    final id = Id.parse(s);
    return TreeId(id.peer, id.counter);
  }

  /// The peer that created the node.
  final PeerId peer;

  /// The counter of the operation that created the node.
  final int counter;

  @override
  bool operator ==(Object other) =>
      other is TreeId && other.peer == peer && other.counter == counter;

  @override
  int get hashCode => Object.hash(peer, counter, 'tree');

  @override
  String toString() => '$counter@$peer';
}

/// Where a tree node lives.
enum TreeParentKind {
  /// Under another node, see [TreeParent.node].
  node,

  /// A root of the tree.
  root,

  /// The node was deleted.
  deleted,

  /// The node does not exist (yet), e.g. the old parent of a created node.
  nonexistent,
}

/// The parent of a tree node.
final class TreeParent {
  const TreeParent._(this.kind, this.node);

  /// The parent of a root node.
  const TreeParent.root() : this._(TreeParentKind.root, null);

  /// The parent of a deleted node.
  const TreeParent.deleted() : this._(TreeParentKind.deleted, null);

  /// The parent of a node that does not exist.
  const TreeParent.nonexistent() : this._(TreeParentKind.nonexistent, null);

  /// The parent of a child of [node].
  const TreeParent.ofNode(TreeId node) : this._(TreeParentKind.node, node);

  /// Where the node lives.
  final TreeParentKind kind;

  /// The parent node when [kind] is [TreeParentKind.node].
  final TreeId? node;

  /// Whether the node is a root.
  bool get isRoot => kind == TreeParentKind.root;

  @override
  bool operator ==(Object other) =>
      other is TreeParent && other.kind == kind && other.node == node;

  @override
  int get hashCode => Object.hash(kind, node);

  @override
  String toString() => node?.toString() ?? kind.name;
}

/// Identifies a container, either a named root container or one created by
/// an operation.
///
/// The string form (`cid:root-name:Text`, `cid:12@345:Map`) is the same one
/// used by every Loro binding, so ids can be exchanged with other platforms.
final class ContainerId {
  ContainerId._(this._repr, this.type, this.name, this.id);

  /// The id of the root container [name] of the given [type].
  factory ContainerId.root(String name, ContainerType type) =>
      ContainerId._('cid:root-$name:${type.loroName}', type, name, null);

  /// The id of a container created by the operation [id].
  factory ContainerId.normal(Id id, ContainerType type) =>
      ContainerId._('cid:$id:${type.loroName}', type, null, id);

  /// Parses the string form returned by [toString]. Throws a
  /// [FormatException] if [s] is not a container id.
  factory ContainerId.parse(String s) {
    if (!s.startsWith('cid:')) {
      throw FormatException('Invalid container id "$s"');
    }
    final sep = s.lastIndexOf(':');
    if (sep <= 3) throw FormatException('Invalid container id "$s"');
    final type = ContainerType.fromLoroName(s.substring(sep + 1));
    final body = s.substring(4, sep);
    if (body.startsWith('root-')) {
      return ContainerId._(s, type, body.substring(5), null);
    }
    return ContainerId._(s, type, null, Id.parse(body));
  }

  final String _repr;

  /// The kind of container.
  final ContainerType type;

  /// The name of a root container, `null` otherwise.
  final String? name;

  /// The creating operation of a non-root container, `null` for roots.
  final Id? id;

  /// Whether this is a root container, which has a [name].
  bool get isRoot => name != null;

  @override
  bool operator ==(Object other) =>
      other is ContainerId && other._repr == _repr;

  @override
  int get hashCode => _repr.hashCode;

  @override
  String toString() => _repr;
}

/// A set of operation ids that together describe a version of a document:
/// the ids of the latest operations, of which no other included operation is
/// a descendant.
final class Frontiers extends UnmodifiableListView<Id> {
  /// The frontiers made of [ids].
  Frontiers(Iterable<Id> ids) : super(List.unmodifiable(ids));

  /// The version before any operation.
  Frontiers.empty() : super(const []);

  @override
  bool operator ==(Object other) {
    if (other is! Frontiers || other.length != length) return false;
    final a = toSet();
    return other.every(a.contains);
  }

  @override
  int get hashCode => Object.hashAllUnordered(this);

  @override
  String toString() => 'Frontiers(${join(', ')})';
}

/// A version expressed as, for every peer, the number of its operations
/// that are included (i.e. the next counter expected from that peer).
final class VersionVector extends UnmodifiableMapView<PeerId, int> {
  /// The version that includes, for each peer in [entries], that many of its
  /// operations.
  VersionVector(Map<PeerId, int> entries) : super(Map.unmodifiable(entries));

  /// The version before any operation.
  VersionVector.empty() : super(const {});

  /// Compares two versions. Returns a negative number if this version is
  /// strictly older than [other], zero if they are equal, a positive number
  /// if it is strictly newer, and `null` if they are concurrent.
  int? partialCompare(VersionVector other) {
    var less = false;
    var greater = false;
    for (final peer in {...keys, ...other.keys}) {
      final a = this[peer] ?? 0;
      final b = other[peer] ?? 0;
      if (a < b) less = true;
      if (a > b) greater = true;
    }
    if (less && greater) return null;
    if (less) return -1;
    if (greater) return 1;
    return 0;
  }

  /// Whether every operation in [other] is included in this version.
  bool includes(VersionVector other) {
    final c = partialCompare(other);
    return c != null && c >= 0;
  }

  @override
  bool operator ==(Object other) =>
      other is VersionVector && partialCompare(other) == 0;

  @override
  int get hashCode => Object.hashAllUnordered(
    entries.where((e) => e.value != 0).map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() =>
      'VersionVector(${entries.map((e) => '${e.key}: ${e.value}').join(', ')})';
}

/// The operations `[start, end)` of [peer].
final class IdSpan {
  /// The operations `[start, end)` of [peer].
  const IdSpan(this.peer, this.start, this.end);

  /// The peer whose operations are included.
  final PeerId peer;

  /// The counter of the first operation.
  final int start;

  /// The counter after the last operation (exclusive).
  final int end;

  @override
  bool operator ==(Object other) =>
      other is IdSpan &&
      other.peer == peer &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(peer, start, end);

  @override
  String toString() => '$peer:[$start, $end)';
}

/// Which operations an import applied, and which wait for missing
/// dependencies.
final class ImportStatus {
  /// Creates a status; `LoroDoc.import` returns these.
  const ImportStatus(this.success, this.pending);

  /// Imported spans, per peer.
  final List<IdSpan> success;

  /// Spans that could not be applied yet because operations they depend on
  /// are missing, or `null` if nothing is pending.
  final List<IdSpan>? pending;

  @override
  String toString() => 'ImportStatus(success: $success, pending: $pending)';
}

/// Metadata of a change: a run of consecutive operations by one peer.
final class ChangeMeta {
  /// Creates change metadata; `LoroDoc.getChange` returns these.
  const ChangeMeta({
    required this.lamport,
    required this.id,
    required this.timestamp,
    required this.message,
    required this.deps,
    required this.length,
  });

  /// Lamport timestamp of the change.
  final int lamport;

  /// Id of the first operation in the change.
  final Id id;

  /// Unix time in seconds; 0 unless timestamps are recorded, see
  /// `LoroDoc.setRecordTimestamp`.
  final int timestamp;

  /// The commit message, if any.
  final String? message;

  /// The versions this change depends on.
  final Frontiers deps;

  /// Number of operations in the change.
  final int length;

  @override
  String toString() =>
      'ChangeMeta($id, lamport: $lamport, len: $length, message: $message)';
}

/// What `LoroDoc.export` encodes.
final class ExportMode {
  const ExportMode._(this.code, [this.from, this.spans, this.frontiers]);

  /// The full history and state. Self-contained; the usual way to persist a
  /// document.
  const ExportMode.snapshot() : this._(0);

  /// The operations not included in [from] (all operations if omitted).
  /// Send these to a peer that already has [from].
  factory ExportMode.updates({VersionVector? from}) =>
      ExportMode._(1, from ?? VersionVector.empty());

  /// The operations in the given spans.
  factory ExportMode.updatesInRange(List<IdSpan> spans) =>
      ExportMode._(2, null, spans);

  /// A snapshot that only keeps history since [frontiers], to save space.
  factory ExportMode.shallowSnapshot(Frontiers frontiers) =>
      ExportMode._(3, null, null, frontiers);

  /// Only the state at [frontiers] (latest if omitted), without history.
  factory ExportMode.stateOnly([Frontiers? frontiers]) =>
      ExportMode._(4, null, null, frontiers);

  /// A snapshot of the document as of [frontiers].
  factory ExportMode.snapshotAt(Frontiers frontiers) =>
      ExportMode._(5, null, null, frontiers);

  /// The code identifying the mode in the native library.
  final int code;

  /// The starting version of [ExportMode.updates].
  final VersionVector? from;

  /// The spans of [ExportMode.updatesInRange].
  final List<IdSpan>? spans;

  /// The version of [ExportMode.shallowSnapshot], [ExportMode.stateOnly] and
  /// [ExportMode.snapshotAt].
  final Frontiers? frontiers;
}

/// Metadata read from an exported blob without importing it.
final class ImportBlobMetadata {
  /// Creates blob metadata; `LoroDoc.decodeImportBlobMeta` returns these.
  const ImportBlobMetadata({
    required this.mode,
    required this.partialStartVersion,
    required this.partialEndVersion,
    required this.startTimestamp,
    required this.startFrontiers,
    required this.endTimestamp,
    required this.changeCount,
  });

  /// The encoding mode, e.g. `Snapshot`, `Updates` or `ShallowSnapshot`.
  final String mode;

  /// Version vector of the start of the included operations.
  final VersionVector partialStartVersion;

  /// Version vector of the end of the included operations.
  final VersionVector partialEndVersion;

  /// Timestamp (Unix seconds) of the earliest included change, 0 if
  /// timestamps were not recorded.
  final int startTimestamp;

  /// The version the included operations build on: their dependencies
  /// that the blob does not contain. Empty for a full snapshot.
  final Frontiers startFrontiers;

  /// Timestamp (Unix seconds) of the latest included change, 0 if
  /// timestamps were not recorded.
  final int endTimestamp;

  /// Number of changes in the blob.
  final int changeCount;

  /// Whether the blob is a snapshot (of any kind) rather than updates.
  bool get isSnapshot => mode.contains('Snapshot');
}

/// How text positions are measured.
enum TextUnit {
  /// UTF-16 code units, like Dart [String] indices. The default.
  utf16,

  /// Unicode code points (runes).
  unicode,

  /// UTF-8 bytes.
  utf8,
}

/// Whether a style mark grows when text is inserted at its edges.
enum ExpandType {
  /// Text inserted right before the mark gets the style.
  before,

  /// Text inserted right after the mark gets the style (e.g. bold).
  after,

  /// Both.
  both,

  /// Neither (e.g. links).
  none,
}

/// Which side of the element at a position a [Cursor] sticks to.
enum CursorSide {
  /// The left side of the element.
  left(-1),

  /// The element itself. The default.
  middle(0),

  /// The right side of the element.
  right(1);

  const CursorSide(this.value);

  /// The code Loro uses for this side: -1, 0 or 1.
  final int value;

  /// The side with code [v], [middle] if [v] is unknown.
  static CursorSide fromValue(int v) =>
      values.firstWhere((s) => s.value == v, orElse: () => middle);
}

/// A stable position in a text or list that survives concurrent edits.
///
/// Resolve it to an index with `LoroDoc.getCursorPos`. Cursors can be
/// serialized with [encode] and exchanged with other Loro bindings.
final class Cursor {
  Cursor._(this._bytes, this.container, this.side, this.id);

  /// Decodes bytes produced by [encode] (or by another Loro binding).
  factory Cursor.decode(Uint8List bytes) => Runtime.reader(
    b.loro_cursor_decode(Runtime.input(bytes), bytes.length, Runtime.errSlot),
  ).cursor();

  final Uint8List _bytes;

  /// The container the cursor points into.
  final ContainerId container;

  /// Which side of [id] the cursor sticks to.
  final CursorSide side;

  /// The element the cursor is attached to, `null` for an empty container
  /// or the end of the container.
  final Id? id;

  /// Serializes the cursor; restore it with [Cursor.decode].
  Uint8List encode() => Uint8List.fromList(_bytes);

  @override
  bool operator ==(Object other) {
    if (other is! Cursor || other._bytes.length != _bytes.length) return false;
    for (var i = 0; i < _bytes.length; i++) {
      if (other._bytes[i] != _bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_bytes);

  @override
  String toString() => 'Cursor($container, $id, $side)';
}

/// Creates [Cursor]s from decoded parts; used by the codec.
Cursor makeCursor(
  Uint8List bytes,
  ContainerId container,
  CursorSide side,
  Id? id,
) => Cursor._(bytes, container, side, id);

/// The current index of a [Cursor].
final class CursorPosition {
  /// Creates a position; `LoroDoc.getCursorPos` returns these.
  const CursorPosition(this.offset, this.side, this.update);

  /// The index in the container (UTF-16 code units for text).
  final int offset;

  /// Which side of the element at [offset] the cursor sticks to.
  final CursorSide side;

  /// A fresher cursor to store instead of the old one, if Loro produced one
  /// (it does when the original element was deleted).
  final Cursor? update;

  @override
  String toString() => 'CursorPosition($offset, $side)';
}
