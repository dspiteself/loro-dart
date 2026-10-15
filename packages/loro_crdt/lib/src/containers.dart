import 'dart:typed_data';

import 'codec.dart';
import 'delta.dart';
import 'doc.dart';
import 'events.dart';
import 'ffi/bindings.dart' as b;
import 'ffi/proxy_ffi.dart';
import 'ffi/runtime.dart';
import 'native_object.dart';
import 'types.dart';

final _err = Runtime.errSlot;

Object? _orNull(Object? v) => identical(v, absent) ? null : v;

/// Base class of the Loro containers: [LoroText], [LoroMap], [LoroList],
/// [LoroMovableList], [LoroTree] and [LoroCounter].
///
/// A container is either *attached* to a [LoroDoc] (obtained from the
/// document or from a parent container) or *detached* (created with its
/// constructor, e.g. `LoroText()`). Detached containers work standalone and
/// become attached by inserting them with `insertContainer`/`setContainer`,
/// which returns the attached handle.
sealed class LoroContainer extends NativeObject {
  LoroContainer._(Pointer<Void> handle)
    : super(handle, b.loro_container_free_finalizer, b.loro_container_free);

  /// Wraps a native container handle; the result owns the handle.
  static LoroContainer fromAddress(ContainerType type, int address) =>
      fromHandle(type, Pointer<Void>.fromAddress(address));

  /// Wraps a native container handle of [type]; the result owns the handle.
  static LoroContainer fromHandle(ContainerType type, Pointer<Void> handle) =>
      switch (type) {
        ContainerType.text => LoroText._(handle),
        ContainerType.map => LoroMap._(handle),
        ContainerType.list => LoroList._(handle),
        ContainerType.movableList => LoroMovableList._(handle),
        ContainerType.tree => LoroTree._(handle),
        ContainerType.counter => LoroCounter._(handle),
        ContainerType.unknown => LoroUnknown._(handle),
      };

  /// Wraps a handle of unknown type, or returns `null` for a null handle.
  static LoroContainer? fromNullableHandle(Pointer<Void> handle) {
    if (handle.address == 0) return null;
    final type = ContainerType.values[b.loro_container_type(handle, _err)];
    Runtime.check();
    return fromHandle(type, handle);
  }

  static Pointer<Void> _create(ContainerType type) {
    final h = b.loro_container_new(type.index, _err);
    Runtime.check();
    return h;
  }

  /// The id of this container, e.g. for [LoroDoc.getContainer].
  ContainerId get id => ContainerId.parse(
    Runtime.reader(b.loro_container_id(handle, _err)).str(),
  );

  /// The kind of container.
  ContainerType get type;

  /// Whether the container is part of a document.
  bool get isAttached {
    final r = b.loro_container_is_attached(handle, _err);
    Runtime.check();
    return r != 0;
  }

  /// The attached counterpart of a detached container that has since been
  /// inserted into a document, or `null`.
  LoroContainer? getAttached() {
    final h = b.loro_container_get_attached(handle, _err);
    Runtime.check();
    return h.address == 0 ? null : fromHandle(type, h);
  }

  /// Whether the container was deleted from its document (e.g. its parent
  /// map entry was overwritten).
  bool get isDeleted {
    final r = b.loro_container_is_deleted(handle, _err);
    Runtime.check();
    return r != 0;
  }

  /// The document of an attached container, `null` when detached.
  LoroDoc? get doc {
    final h = b.loro_container_doc(handle, _err);
    Runtime.check();
    return h.address == 0 ? null : LoroDoc.fromHandle(h);
  }

  /// The value with child containers as [ContainerId]s.
  Object? getShallowValue() =>
      Runtime.reader(b.loro_container_get_value(handle, _err)).value();

  /// The value with child containers resolved recursively into plain
  /// Dart values (`Map`, `List`, `String`, numbers, ...).
  Object? toJson() =>
      Runtime.reader(b.loro_container_get_deep_value(handle, _err)).value();

  /// Calls [listener] after every change to this container or its
  /// descendants. The container must be attached.
  LoroSubscription subscribe(void Function(LoroEventBatch event) listener) {
    final d = doc;
    if (d == null) {
      throw StateError('Only attached containers can be subscribed to.');
    }
    return d.subscribeContainer(id, listener);
  }

  /// Containers are equal when they refer to the same container.
  @override
  bool operator ==(Object other) =>
      other is LoroContainer && (identical(other, this) || other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => '$runtimeType($id)';
}

ContainerType _typeOf<T extends LoroContainer>() {
  if (T == LoroText) return ContainerType.text;
  if (T == LoroMap) return ContainerType.map;
  if (T == LoroList) return ContainerType.list;
  if (T == LoroMovableList) return ContainerType.movableList;
  if (T == LoroTree) return ContainerType.tree;
  if (T == LoroCounter) return ContainerType.counter;
  throw ArgumentError('Specify a concrete container type, e.g. LoroText.');
}

/// Passes one string argument and checks for errors.
void _withStr(String s, void Function(Pointer<Uint8> p, int len) call) {
  final data = utf8Bytes(s);
  call(Runtime.input(data), data.length);
  Runtime.check();
}

// ---------------------------------------------------------------------------

/// A collaborative text with rich-text support.
///
/// Positions and lengths are measured in UTF-16 code units, the same as Dart
/// [String] indices, unless another [TextUnit] is passed.
final class LoroText extends LoroContainer {
  LoroText._(super.handle) : super._();

  /// Creates a detached text.
  LoroText() : super._(LoroContainer._create(ContainerType.text));

  @override
  ContainerType get type => ContainerType.text;

  /// Inserts [text] at [index], measured in [unit].
  ///
  /// Throws a [LoroException] if [index] is out of bounds (`OutOfBound`) or
  /// falls inside a character (e.g. between the two halves of an emoji).
  void insert(int index, String text, {TextUnit unit = TextUnit.utf16}) =>
      _withStr(
        text,
        (p, n) => b.loro_text_insert(handle, index, unit.index, p, n, _err),
      );

  /// Deletes [length] units starting at [index], both measured in [unit].
  ///
  /// Throws a [LoroException] if the range is out of bounds or splits a
  /// character.
  void delete(int index, int length, {TextUnit unit = TextUnit.utf16}) {
    b.loro_text_delete(handle, index, length, unit.index, _err);
    Runtime.check();
  }

  /// Appends [text].
  void push(String text) =>
      _withStr(text, (p, n) => b.loro_text_push(handle, p, n, _err));

  /// The text between [start] and [end].
  String slice(int start, int end, {TextUnit unit = TextUnit.utf16}) =>
      Runtime.string(b.loro_text_slice(handle, start, end, unit.index, _err));

  /// Replaces [deleteCount] units at [index] with [insert]; returns the
  /// removed text.
  String splice(
    int index,
    int deleteCount,
    String insert, {
    TextUnit unit = TextUnit.utf16,
  }) {
    final data = utf8Bytes(insert);
    return Runtime.string(
      b.loro_text_splice(
        handle,
        index,
        deleteCount,
        unit.index,
        Runtime.input(data),
        data.length,
        _err,
      ),
    );
  }

  /// Length in UTF-16 code units.
  int get length => lengthIn(TextUnit.utf16);

  /// Length measured in [unit].
  int lengthIn(TextUnit unit) {
    final n = b.loro_text_len(handle, unit.index, _err);
    Runtime.check();
    return n;
  }

  /// Whether the text is empty.
  bool get isEmpty => length == 0;

  /// Whether the text is not empty.
  bool get isNotEmpty => !isEmpty;

  /// Replaces the whole content with [text], recording the minimal set of
  /// edits so that concurrent changes merge well. Use [byLine] for long
  /// texts (faster, line-granular diff). Throws a [LoroException] with code
  /// `UpdateTimeout` if [timeout] is exceeded.
  void update(
    String text, {
    bool byLine = false,
    Duration? timeout,
    bool useRefinedDiff = false,
  }) => _withStr(
    text,
    (p, n) => b.loro_text_update(
      handle,
      p,
      n,
      byLine ? 1 : 0,
      timeout == null ? -1.0 : timeout.inMicroseconds / 1000,
      useRefinedDiff ? 1 : 0,
      _err,
    ),
  );

  /// Applies the style [key] = [value] to `[start, end)`. Configure how marks
  /// expand with `LoroDoc.configTextStyle`.
  void mark(
    int start,
    int end,
    String key,
    Object? value, {
    TextUnit unit = TextUnit.utf16,
  }) {
    final k = utf8Bytes(key);
    final v = encodeValue(value);
    final (kp, vp) = Runtime.input2(k, v);
    b.loro_text_mark(
      handle,
      start,
      end,
      unit.index,
      kp,
      k.length,
      vp,
      v.length,
      _err,
    );
    Runtime.check();
  }

  /// Removes the style [key] from `[start, end)`.
  void unmark(
    int start,
    int end,
    String key, {
    TextUnit unit = TextUnit.utf16,
  }) => _withStr(
    key,
    (p, n) => b.loro_text_unmark(handle, start, end, unit.index, p, n, _err),
  );

  /// The content as a rich-text delta.
  List<TextDelta> toDelta() =>
      Runtime.reader(b.loro_text_to_delta(handle, _err)).textDeltas();

  /// The delta of `[start, end)`.
  List<TextDelta> sliceDelta(
    int start,
    int end, {
    TextUnit unit = TextUnit.utf16,
  }) => Runtime.reader(
    b.loro_text_slice_delta(handle, start, end, unit.index, _err),
  ).textDeltas();

  /// Applies a rich-text delta, e.g. one received from an editor.
  void applyDelta(List<TextDelta> delta) {
    final data = encodeWith((w) => w.textDeltas(delta));
    b.loro_text_apply_delta(handle, Runtime.input(data), data.length, _err);
    Runtime.check();
  }

  /// The rich-text value as a list of `{insert, attributes}` maps.
  Object? getRichTextValue() =>
      Runtime.reader(b.loro_text_get_richtext_value(handle, _err)).value();

  /// A stable cursor at UTF-16 [index]; resolve it with
  /// [LoroDoc.getCursorPos]. An [index] at or past the end gives a cursor
  /// that stays at the end. Returns `null` if the text is detached.
  Cursor? getCursor(int index, {CursorSide side = CursorSide.middle}) =>
      Runtime.reader(
        b.loro_text_get_cursor(handle, index, side.value, _err),
      ).optCursor();

  /// Converts [index] between units; `null` if out of bounds.
  int? convertPos(int index, {required TextUnit from, required TextUnit to}) {
    final r = b.loro_text_convert_pos(
      handle,
      index,
      from.index,
      to.index,
      _err,
    );
    Runtime.check();
    return r < 0 ? null : r;
  }

  /// The peer that inserted the character at [index].
  PeerId? getEditorAt(int index, {TextUnit unit = TextUnit.utf16}) =>
      Runtime.reader(
        b.loro_text_get_editor_at(handle, index, unit.index, _err),
      ).optPeer();

  @override
  String toString() => Runtime.string(b.loro_text_to_string(handle, _err));
}

// ---------------------------------------------------------------------------

/// A collaborative map with string keys. Concurrent writes to the same key
/// resolve with last-writer-wins.
final class LoroMap extends LoroContainer {
  LoroMap._(super.handle) : super._();

  /// Creates a detached map.
  LoroMap() : super._(LoroContainer._create(ContainerType.map));

  @override
  ContainerType get type => ContainerType.map;

  /// Sets [key] to a plain [value] (`null`, `bool`, `num`, `String`,
  /// `Uint8List`, `List`, `Map`).
  void set(String key, Object? value) {
    final k = utf8Bytes(key);
    final v = encodeValue(value);
    final (kp, vp) = Runtime.input2(k, v);
    b.loro_map_insert(handle, kp, k.length, vp, v.length, _err);
    Runtime.check();
  }

  /// Same as [set].
  void operator []=(String key, Object? value) => set(key, value);

  /// The value or child container at [key], or `null` if absent.
  Object? get(String key) => _orNull(_get(key));

  /// Same as [get].
  Object? operator [](String key) => get(key);

  Object? _get(String key) {
    final k = utf8Bytes(key);
    return Runtime.reader(
      b.loro_map_get(handle, Runtime.input(k), k.length, _err),
    ).valueOrContainer();
  }

  /// Whether [key] holds a value or child container.
  bool containsKey(String key) => !identical(_get(key), absent);

  /// Removes [key]; does nothing if it is absent.
  void delete(String key) =>
      _withStr(key, (p, n) => b.loro_map_delete(handle, p, n, _err));

  /// Removes every key.
  void clear() {
    b.loro_map_clear(handle, _err);
    Runtime.check();
  }

  /// The number of keys.
  int get length {
    final n = b.loro_map_len(handle, _err);
    Runtime.check();
    return n;
  }

  /// Whether the map has no keys.
  bool get isEmpty => length == 0;

  /// Whether the map has at least one key.
  bool get isNotEmpty => !isEmpty;

  /// The keys in sorted order.
  List<String> get keys => Runtime.reader(b.loro_map_keys(handle, _err)).strs();

  /// All entries sorted by key; child containers are [LoroContainer]s.
  Map<String, Object?> get entries {
    final r = Runtime.reader(b.loro_map_entries(handle, _err));
    final n = r.u32();
    final m = <String, Object?>{};
    for (var i = 0; i < n; i++) {
      final k = r.str();
      m[k] = r.valueOrContainer();
    }
    return m;
  }

  /// The values sorted by key; child containers are [LoroContainer]s.
  List<Object?> get values => entries.values.toList();

  /// Inserts the detached [child] at [key] and returns the attached
  /// container.
  T setContainer<T extends LoroContainer>(String key, T child) {
    final k = utf8Bytes(key);
    final h = b.loro_map_insert_container(
      handle,
      Runtime.input(k),
      k.length,
      child.handle,
      _err,
    );
    Runtime.check();
    return LoroContainer.fromHandle(child.type, h) as T;
  }

  /// Returns the child container of type [T] at [key], creating it if
  /// needed. Containers created this way by different peers at the same key
  /// are merged rather than overwriting each other.
  T getOrCreateContainer<T extends LoroContainer>(String key) {
    final type = _typeOf<T>();
    final k = utf8Bytes(key);
    final h = b.loro_map_ensure_mergeable(
      handle,
      Runtime.input(k),
      k.length,
      type.index,
      _err,
    );
    Runtime.check();
    return LoroContainer.fromHandle(type, h) as T;
  }

  /// The peer that last wrote [key].
  PeerId? getLastEditor(String key) {
    final k = utf8Bytes(key);
    return Runtime.reader(
      b.loro_map_get_last_editor(handle, Runtime.input(k), k.length, _err),
    ).optPeer();
  }

  @override
  Map<String, Object?> toJson() => super.toJson()! as Map<String, Object?>;
}

// ---------------------------------------------------------------------------

/// Operations shared by [LoroList] and [LoroMovableList].
base mixin _ListOps on LoroContainer {
  /// Inserts a plain [value] (see [LoroMap.set] for the allowed types) at
  /// [index]. Throws a [LoroException] if [index] is out of bounds.
  void insert(int index, Object? value) {
    final v = encodeValue(value);
    b.loro_list_insert(handle, index, Runtime.input(v), v.length, _err);
    Runtime.check();
  }

  /// Appends a plain [value].
  void push(Object? value) {
    final v = encodeValue(value);
    b.loro_list_push(handle, Runtime.input(v), v.length, _err);
    Runtime.check();
  }

  /// Deletes [count] elements starting at [index]. Throws a [LoroException]
  /// if the range is out of bounds.
  void delete(int index, int count) {
    b.loro_list_delete(handle, index, count, _err);
    Runtime.check();
  }

  /// Removes and returns the last element, `null` if empty.
  Object? pop() =>
      _orNull(Runtime.reader(b.loro_list_pop(handle, _err)).valueOrContainer());

  /// The value or child container at [index], `null` if out of range.
  Object? get(int index) => _orNull(
    Runtime.reader(b.loro_list_get(handle, index, _err)).valueOrContainer(),
  );

  /// Same as [get].
  Object? operator [](int index) => get(index);

  /// The number of elements.
  int get length {
    final n = b.loro_list_len(handle, _err);
    Runtime.check();
    return n;
  }

  /// Whether the list has no elements.
  bool get isEmpty => length == 0;

  /// Whether the list has at least one element.
  bool get isNotEmpty => !isEmpty;

  /// Removes every element.
  void clear() {
    b.loro_list_clear(handle, _err);
    Runtime.check();
  }

  /// The elements; child containers are [LoroContainer]s.
  List<Object?> toList() =>
      Runtime.reader(b.loro_list_items(handle, _err)).valuesOrContainers();

  /// Inserts the detached [child] at [index] and returns the attached
  /// container.
  T insertContainer<T extends LoroContainer>(int index, T child) {
    final h = b.loro_list_insert_container(handle, index, child.handle, _err);
    Runtime.check();
    return LoroContainer.fromHandle(child.type, h) as T;
  }

  /// Appends the detached [child] and returns the attached container.
  T pushContainer<T extends LoroContainer>(T child) {
    final h = b.loro_list_push_container(handle, child.handle, _err);
    Runtime.check();
    return LoroContainer.fromHandle(child.type, h) as T;
  }

  /// A stable cursor at [index]; resolve it with [LoroDoc.getCursorPos].
  /// Returns `null` if the list is detached.
  Cursor? getCursor(int index, {CursorSide side = CursorSide.middle}) =>
      Runtime.reader(
        b.loro_list_get_cursor(handle, index, side.value, _err),
      ).optCursor();

  @override
  List<Object?> toJson() => super.toJson()! as List<Object?>;
}

/// A collaborative list. Use [LoroMovableList] if elements need to be moved
/// or replaced.
final class LoroList extends LoroContainer with _ListOps {
  LoroList._(super.handle) : super._();

  /// Creates a detached list.
  LoroList() : super._(LoroContainer._create(ContainerType.list));

  @override
  ContainerType get type => ContainerType.list;

  /// The id of the operation that inserted the element at [index].
  Id? getIdAt(int index) =>
      Runtime.reader(b.loro_list_get_id_at(handle, index, _err)).optId();
}

/// A collaborative list that also supports moving and replacing elements
/// without duplicating them under concurrency.
final class LoroMovableList extends LoroContainer with _ListOps {
  LoroMovableList._(super.handle) : super._();

  /// Creates a detached movable list.
  LoroMovableList() : super._(LoroContainer._create(ContainerType.movableList));

  @override
  ContainerType get type => ContainerType.movableList;

  /// Replaces the element at [index].
  void set(int index, Object? value) {
    final v = encodeValue(value);
    b.loro_movable_list_set(handle, index, Runtime.input(v), v.length, _err);
    Runtime.check();
  }

  /// Same as [set].
  void operator []=(int index, Object? value) => set(index, value);

  /// Replaces the element at [index] with the detached [child] and returns
  /// the attached container.
  T setContainer<T extends LoroContainer>(int index, T child) {
    final h = b.loro_movable_list_set_container(
      handle,
      index,
      child.handle,
      _err,
    );
    Runtime.check();
    return LoroContainer.fromHandle(child.type, h) as T;
  }

  /// Moves the element at [from] so that it ends up at index [to].
  void move(int from, int to) {
    b.loro_movable_list_move(handle, from, to, _err);
    Runtime.check();
  }

  /// The peer that inserted the element at [index].
  PeerId? getCreatorAt(int index) => _peerAt(index, 0);

  /// The peer that last moved the element at [index].
  PeerId? getLastMoverAt(int index) => _peerAt(index, 1);

  /// The peer that last set the value at [index].
  PeerId? getLastEditorAt(int index) => _peerAt(index, 2);

  PeerId? _peerAt(int index, int which) => Runtime.reader(
    b.loro_movable_list_peer_at(handle, index, which, _err),
  ).optPeer();
}

// ---------------------------------------------------------------------------

/// A movable tree (a forest: there can be several roots). Each node has a
/// [LoroMap] of metadata, see [getMeta] / [LoroTreeNode.data].
final class LoroTree extends LoroContainer {
  LoroTree._(super.handle) : super._();

  /// Creates a detached tree.
  LoroTree() : super._(LoroContainer._create(ContainerType.tree));

  @override
  ContainerType get type => ContainerType.tree;

  Uint8List _ids(void Function(Writer w) f) => encodeWith(f);

  /// Creates a node under [parent] (a root if `null`), at [index] among its
  /// siblings (requires fractional indexes, enabled by default) or last.
  LoroTreeNode createNode({TreeId? parent, int? index}) {
    final args = _ids((w) => w.optTreeId(parent));
    final p = Runtime.input(args);
    final id = Runtime.reader(
      index == null
          ? b.loro_tree_create(handle, p, args.length, _err)
          : b.loro_tree_create_at(handle, p, args.length, index, _err),
    ).treeId();
    return LoroTreeNode._(this, id);
  }

  /// Moves [target] under [parent] (to the roots if `null`), at [index] or
  /// last.
  void move(TreeId target, {TreeId? parent, int? index}) {
    final args = _ids(
      (w) => w
        ..treeId(target)
        ..optTreeId(parent),
    );
    b.loro_tree_move(
      handle,
      Runtime.input(args),
      args.length,
      index ?? -1,
      _err,
    );
    Runtime.check();
  }

  /// Moves [target] right after its new sibling [after].
  void moveAfter(TreeId target, TreeId after) => _moveBeside(target, after, 1);

  /// Moves [target] right before its new sibling [before].
  void moveBefore(TreeId target, TreeId before) =>
      _moveBeside(target, before, 0);

  void _moveBeside(TreeId target, TreeId sibling, int after) {
    final args = _ids(
      (w) => w
        ..treeId(target)
        ..treeId(sibling),
    );
    b.loro_tree_move_beside(
      handle,
      Runtime.input(args),
      args.length,
      after,
      _err,
    );
    Runtime.check();
  }

  /// Deletes [target] and its descendants.
  void delete(TreeId target) {
    final args = _ids((w) => w.treeId(target));
    b.loro_tree_delete(handle, Runtime.input(args), args.length, _err);
    Runtime.check();
  }

  /// The metadata map of [target].
  LoroMap getMeta(TreeId target) {
    final args = _ids((w) => w.treeId(target));
    final h = b.loro_tree_get_meta(
      handle,
      Runtime.input(args),
      args.length,
      _err,
    );
    Runtime.check();
    return LoroMap._(h);
  }

  /// The parent of [target], `null` if the node does not exist.
  TreeParent? parent(TreeId target) {
    final args = _ids((w) => w.treeId(target));
    return Runtime.reader(
      b.loro_tree_parent(handle, Runtime.input(args), args.length, _err),
    ).optTreeParent();
  }

  /// The children of [parent] (the roots if `null`) in order, or `null` if
  /// [parent] does not exist.
  List<TreeId>? children([TreeId? parent]) {
    final args = _ids((w) => w.optTreeId(parent));
    return Runtime.reader(
      b.loro_tree_children(handle, Runtime.input(args), args.length, _err),
    ).optTreeIds();
  }

  /// The number of children of [parent] (the roots if `null`).
  int? childrenCount([TreeId? parent]) {
    final args = _ids((w) => w.optTreeId(parent));
    final n = b.loro_tree_children_num(
      handle,
      Runtime.input(args),
      args.length,
      _err,
    );
    Runtime.check();
    return n < 0 ? null : n;
  }

  /// Whether [target] exists (it may be deleted, see [isNodeDeleted]).
  bool contains(TreeId target) {
    final args = _ids((w) => w.treeId(target));
    final r = b.loro_tree_contains(
      handle,
      Runtime.input(args),
      args.length,
      _err,
    );
    Runtime.check();
    return r != 0;
  }

  /// Whether [target] was deleted. Throws a [LoroException] if it does not
  /// exist (see [contains]).
  bool isNodeDeleted(TreeId target) {
    final args = _ids((w) => w.treeId(target));
    final r = b.loro_tree_is_node_deleted(
      handle,
      Runtime.input(args),
      args.length,
      _err,
    );
    Runtime.check();
    return r != 0;
  }

  /// Ids of all nodes; deleted nodes are included only if [withDeleted].
  List<TreeId> nodeIds({bool withDeleted = false}) => withDeleted
      ? Runtime.reader(b.loro_tree_node_ids(handle, 0, _err)).treeIds()
      : [for (final n in getNodes()) n.id];

  /// Ids of the root nodes in order.
  List<TreeId> rootIds() =>
      Runtime.reader(b.loro_tree_node_ids(handle, 1, _err)).treeIds();

  /// All nodes; deleted nodes are included only if [withDeleted].
  List<LoroTreeNode> nodes({bool withDeleted = false}) => [
    for (final id in nodeIds(withDeleted: withDeleted))
      LoroTreeNode._(this, id),
  ];

  /// The root nodes in order.
  List<LoroTreeNode> roots() => [
    for (final id in rootIds()) LoroTreeNode._(this, id),
  ];

  /// A handle to the node [id].
  LoroTreeNode node(TreeId id) => LoroTreeNode._(this, id);

  /// Every node with its position, including deleted ones if requested.
  List<TreeNodeInfo> getNodes({bool withDeleted = false}) {
    final r = Runtime.reader(
      b.loro_tree_get_nodes(handle, withDeleted ? 1 : 0, _err),
    );
    return r.list(
      () => TreeNodeInfo(r.treeId(), r.treeParent(), r.str(), r.u32()),
    );
  }

  /// The fractional index of [target] among its siblings.
  String? fractionalIndex(TreeId target) {
    final args = _ids((w) => w.treeId(target));
    return Runtime.reader(
      b.loro_tree_fractional_index(
        handle,
        Runtime.input(args),
        args.length,
        _err,
      ),
    ).optStr();
  }

  /// The id of the last operation that moved [target].
  Id? getLastMoveId(TreeId target) {
    final args = _ids((w) => w.treeId(target));
    return Runtime.reader(
      b.loro_tree_get_last_move_id(
        handle,
        Runtime.input(args),
        args.length,
        _err,
      ),
    ).optId();
  }

  /// Enables ordered children (needed for `index` arguments). [jitter]
  /// randomizes positions to reduce collisions between concurrent inserts.
  void enableFractionalIndex([int jitter = 0]) {
    b.loro_tree_set_fractional_index(handle, jitter, _err);
    Runtime.check();
  }

  /// Disables ordered children; children are then unordered.
  void disableFractionalIndex() {
    b.loro_tree_set_fractional_index(handle, -1, _err);
    Runtime.check();
  }

  /// Whether children are ordered, see [enableFractionalIndex].
  bool get isFractionalIndexEnabled {
    final r = b.loro_tree_is_fractional_index_enabled(handle, _err);
    Runtime.check();
    return r != 0;
  }

  /// The tree as nested maps: `{id, parent, meta, index, fractional_index,
  /// children}`.
  @override
  List<Object?> toJson() => super.toJson()! as List<Object?>;
}

/// A node of a [LoroTree].
final class LoroTreeNode {
  LoroTreeNode._(this.tree, this.id);

  /// The tree the node belongs to.
  final LoroTree tree;

  /// The node's id.
  final TreeId id;

  /// The node's metadata map.
  LoroMap get data => tree.getMeta(id);

  /// Creates a child, at [index] or last.
  LoroTreeNode createNode({int? index}) =>
      tree.createNode(parent: id, index: index);

  /// Moves this node under [parent] (to the roots if `null`).
  void move({LoroTreeNode? parent, int? index}) =>
      tree.move(id, parent: parent?.id, index: index);

  /// Moves this node right after its new sibling [sibling].
  void moveAfter(LoroTreeNode sibling) => tree.moveAfter(id, sibling.id);

  /// Moves this node right before its new sibling [sibling].
  void moveBefore(LoroTreeNode sibling) => tree.moveBefore(id, sibling.id);

  /// Deletes this node and its descendants.
  void delete() => tree.delete(id);

  /// The parent node, `null` for a root (or a deleted node).
  LoroTreeNode? get parent {
    final p = tree.parent(id)?.node;
    return p == null ? null : LoroTreeNode._(tree, p);
  }

  /// The child nodes in order.
  List<LoroTreeNode> children() => [
    for (final c in tree.children(id) ?? const <TreeId>[])
      LoroTreeNode._(tree, c),
  ];

  /// The position among the siblings.
  int? get index {
    final p = tree.parent(id);
    if (p == null || p.kind == TreeParentKind.deleted) return null;
    final i = tree.children(p.node)?.indexOf(id) ?? -1;
    return i < 0 ? null : i;
  }

  /// The fractional index among the siblings, see
  /// [LoroTree.fractionalIndex].
  String? get fractionalIndex => tree.fractionalIndex(id);

  /// Whether the node was deleted.
  bool get isDeleted => tree.isNodeDeleted(id);

  @override
  bool operator ==(Object other) =>
      other is LoroTreeNode && other.id == id && other.tree == tree;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LoroTreeNode($id)';
}

/// A tree node with its position, from [LoroTree.getNodes].
final class TreeNodeInfo {
  /// Creates node info; [LoroTree.getNodes] returns these.
  const TreeNodeInfo(this.id, this.parent, this.fractionalIndex, this.index);

  /// The node.
  final TreeId id;

  /// The node's parent.
  final TreeParent parent;

  /// The node's sort key among its siblings, see [LoroTree.fractionalIndex].
  final String fractionalIndex;

  /// The node's position among its siblings.
  final int index;

  @override
  String toString() => 'TreeNodeInfo($id, parent: $parent, index: $index)';
}

// ---------------------------------------------------------------------------

/// A collaborative number. Concurrent increments add up.
final class LoroCounter extends LoroContainer {
  LoroCounter._(super.handle) : super._();

  /// Creates a detached counter.
  LoroCounter() : super._(LoroContainer._create(ContainerType.counter));

  @override
  ContainerType get type => ContainerType.counter;

  /// Adds [by], which may be fractional or negative.
  void increment([num by = 1]) {
    b.loro_counter_increment(handle, by.toDouble(), _err);
    Runtime.check();
  }

  /// Subtracts [by].
  void decrement([num by = 1]) => increment(-by);

  /// The current value: the sum of every peer's increments.
  double get value {
    final v = b.loro_counter_value(handle, _err);
    Runtime.check();
    return v;
  }

  @override
  double toJson() => value;
}

/// A container of a type this version of Loro does not know (created by a
/// newer version). Its data is preserved but cannot be edited.
final class LoroUnknown extends LoroContainer {
  LoroUnknown._(super.handle) : super._();

  @override
  ContainerType get type => ContainerType.unknown;
}
