import 'dart:typed_data';

import 'codec.dart';
import 'containers.dart';
import 'events.dart';
import 'ffi/bindings.dart' as b;
import 'ffi/proxy_ffi.dart';
import 'ffi/runtime.dart';
import 'native_object.dart';
import 'types.dart';

final _err = Runtime.errSlot;

/// A Loro document: a set of named root containers, the full edit history,
/// and the logic to merge edits from other peers.
///
/// ```dart
/// final doc = LoroDoc();
/// doc.getText('title').insert(0, 'Hello');
/// doc.commit();
///
/// final peer = LoroDoc()..import(doc.export(const ExportMode.snapshot()));
/// ```
///
/// Edits are grouped into a transaction that is committed by [commit] (and
/// implicitly by [import], [export], [checkout] and similar calls). Events
/// are delivered to subscribers synchronously when a transaction commits.
final class LoroDoc extends NativeObject {
  /// Creates an empty document with a random peer id.
  LoroDoc() : this.fromHandle(_newHandle());

  /// Wraps a native document handle; the result owns the handle.
  LoroDoc.fromHandle(Pointer<Void> handle)
    : super(handle, b.loro_doc_free_finalizer, b.loro_doc_free);

  /// Loads a document from a snapshot (see [ExportMode.snapshot]).
  factory LoroDoc.fromSnapshot(Uint8List snapshot) {
    final h = b.loro_doc_from_snapshot(
      Runtime.input(snapshot),
      snapshot.length,
      _err,
    );
    Runtime.check();
    return LoroDoc.fromHandle(h);
  }

  static Pointer<Void> _newHandle() {
    final h = b.loro_doc_new(_err);
    Runtime.check();
    return h;
  }

  /// Version of the underlying Loro library.
  static String get loroVersion => Runtime.string(b.loro_version(_err));

  /// Reads metadata from an exported blob without importing it.
  static ImportBlobMetadata decodeImportBlobMeta(
    Uint8List blob, {
    bool checkChecksum = false,
  }) {
    final r = Runtime.reader(
      b.loro_decode_import_blob_meta(
        Runtime.input(blob),
        blob.length,
        checkChecksum ? 1 : 0,
        _err,
      ),
    );
    return ImportBlobMetadata(
      mode: r.str(),
      partialStartVersion: r.versionVector(),
      partialEndVersion: r.versionVector(),
      startTimestamp: r.f64().toInt(),
      startFrontiers: r.frontiers(),
      endTimestamp: r.f64().toInt(),
      changeCount: r.u32(),
    );
  }

  // Calls that may commit or change the visible state also deliver events.
  T _emit<T>(T result) {
    Runtime.check();
    Events.dispatch();
    return result;
  }

  void _check() => Runtime.check();

  Uint8List _frontiersArg(Frontiers f) => encodeWith((w) => w.frontiers(f));

  /// A copy of this document (history and state) with a new peer id.
  LoroDoc fork() => LoroDoc.fromHandle(_emit(b.loro_doc_fork(handle, _err)));

  /// A copy of the document as of [frontiers].
  LoroDoc forkAt(Frontiers frontiers) {
    final f = _frontiersArg(frontiers);
    return LoroDoc.fromHandle(
      _emit(b.loro_doc_fork_at(handle, Runtime.input(f), f.length, _err)),
    );
  }

  // -------------------------------------------------------------------------
  // Configuration

  /// This replica's peer id (a decimal `u64` string).
  PeerId get peerId => Runtime.string(b.loro_doc_peer_id(handle, _err));

  /// Sets the peer id. Each concurrently editing replica must use a unique
  /// one; never reuse a peer id on two devices.
  set peerId(PeerId peer) {
    final p = utf8Bytes(peer);
    b.loro_doc_set_peer_id(handle, Runtime.input(p), p.length, _err);
    _emit(null);
  }

  /// Whether to store a wall-clock timestamp with each change.
  void setRecordTimestamp(bool record) {
    b.loro_doc_set_record_timestamp(handle, record ? 1 : 0, _err);
    _check();
  }

  /// Consecutive local changes closer together than [interval] are merged
  /// into one change (when timestamps are recorded). Default 1000 seconds.
  void setChangeMergeInterval(Duration interval) {
    b.loro_doc_set_change_merge_interval(
      handle,
      interval.inSeconds.toDouble(),
      _err,
    );
    _check();
  }

  /// Allows editing while detached (checked out at an older version). Edits
  /// then create a new branch of history.
  bool get detachedEditing {
    final r = b.loro_doc_is_detached_editing_enabled(handle, _err);
    _check();
    return r != 0;
  }

  set detachedEditing(bool enable) {
    b.loro_doc_set_detached_editing(handle, enable ? 1 : 0, _err);
    _check();
  }

  /// Configures how rich-text style marks expand when text is inserted at
  /// their edges, e.g. `{'bold': ExpandType.after, 'link': ExpandType.none}`.
  /// [defaultStyle] applies to keys not listed.
  void configTextStyle(
    Map<String, ExpandType> styles, {
    ExpandType? defaultStyle,
  }) {
    final data = encodeWith((w) {
      w.u32(styles.length);
      styles.forEach((k, v) {
        w
          ..str(k)
          ..u8(v.index);
      });
      w.boolean(defaultStyle != null);
      if (defaultStyle != null) w.u8(defaultStyle.index);
    });
    b.loro_doc_config_text_style(
      handle,
      Runtime.input(data),
      data.length,
      _err,
    );
    _check();
  }

  /// Hides root containers that are empty from [toJson]/[getShallowValue].
  void setHideEmptyRootContainers(bool hide) {
    b.loro_doc_set_hide_empty_root_containers(handle, hide ? 1 : 0, _err);
    _check();
  }

  // -------------------------------------------------------------------------
  // Containers

  Pointer<Void> _root(String name, ContainerType type) {
    final n = utf8Bytes(name);
    final h = b.loro_doc_get_root(
      handle,
      Runtime.input(n),
      n.length,
      type.index,
      _err,
    );
    _check();
    return h;
  }

  /// The root text named [name], created on first use.
  LoroText getText(String name) =>
      LoroContainer.fromHandle(
            ContainerType.text,
            _root(name, ContainerType.text),
          )
          as LoroText;

  LoroMap getMap(String name) =>
      LoroContainer.fromHandle(
            ContainerType.map,
            _root(name, ContainerType.map),
          )
          as LoroMap;

  LoroList getList(String name) =>
      LoroContainer.fromHandle(
            ContainerType.list,
            _root(name, ContainerType.list),
          )
          as LoroList;

  LoroMovableList getMovableList(String name) =>
      LoroContainer.fromHandle(
            ContainerType.movableList,
            _root(name, ContainerType.movableList),
          )
          as LoroMovableList;

  LoroTree getTree(String name) =>
      LoroContainer.fromHandle(
            ContainerType.tree,
            _root(name, ContainerType.tree),
          )
          as LoroTree;

  LoroCounter getCounter(String name) =>
      LoroContainer.fromHandle(
            ContainerType.counter,
            _root(name, ContainerType.counter),
          )
          as LoroCounter;

  /// The container with [id], or `null` if it does not exist.
  LoroContainer? getContainer(ContainerId id) {
    final s = utf8Bytes(id.toString());
    return LoroContainer.fromNullableHandle(
      _check2(
        b.loro_doc_get_container(handle, Runtime.input(s), s.length, _err),
      ),
    );
  }

  T _check2<T>(T v) {
    _check();
    return v;
  }

  bool hasContainer(ContainerId id) {
    final s = utf8Bytes(id.toString());
    return _check2(
          b.loro_doc_has_container(handle, Runtime.input(s), s.length, _err),
        ) !=
        0;
  }

  /// Deletes the root container [id] (marks it deleted and hides it).
  void deleteRootContainer(ContainerId id) {
    final s = utf8Bytes(id.toString());
    b.loro_doc_delete_root_container(handle, Runtime.input(s), s.length, _err);
    _check();
  }

  /// The path from the root down to container [id], or `null` if it does not
  /// exist.
  List<PathSegment>? getPathToContainer(ContainerId id) {
    final s = utf8Bytes(id.toString());
    final r = Runtime.reader(
      b.loro_doc_get_path_to_container(
        handle,
        Runtime.input(s),
        s.length,
        _err,
      ),
    );
    return r.opt(
      () => r.list(() => PathSegment(r.containerId(), r.pathIndex())),
    );
  }

  /// The value or container at a slash-separated [path] such as
  /// `"map/key/0"`, or `null`.
  Object? getByPath(String path) {
    final p = utf8Bytes(path);
    final v = Runtime.reader(
      b.loro_doc_get_by_path(handle, Runtime.input(p), p.length, _err),
    ).valueOrContainer();
    return identical(v, absent) ? null : v;
  }

  /// Evaluates a [JSONPath](https://www.rfc-editor.org/rfc/rfc9535) query
  /// such as `$.books[?@.price < 10].title`.
  List<Object?> jsonPath(String query) {
    final q = utf8Bytes(query);
    return Runtime.reader(
      b.loro_doc_jsonpath(handle, Runtime.input(q), q.length, _err),
    ).valuesOrContainers();
  }

  // -------------------------------------------------------------------------
  // Values

  /// The root containers as [ContainerId]s, keyed by name.
  Map<String, Object?> getShallowValue() =>
      Runtime.reader(b.loro_doc_get_value(handle, _err)).value()!
          as Map<String, Object?>;

  /// The whole document as plain Dart values (maps, lists, strings,
  /// numbers, ...), keyed by root container name.
  Map<String, Object?> toJson() =>
      Runtime.reader(b.loro_doc_get_deep_value(handle, _err)).value()!
          as Map<String, Object?>;

  /// Like [toJson], with each container's id under the `cid` key.
  Map<String, Object?> toJsonWithIds() =>
      Runtime.reader(b.loro_doc_get_deep_value_with_id(handle, _err)).value()!
          as Map<String, Object?>;

  // -------------------------------------------------------------------------
  // Transactions

  /// Commits pending edits as one change and emits events.
  ///
  /// [origin] is passed to event listeners (and can be excluded from undo,
  /// see `UndoManager`); [message] is stored with the change; [timestamp] is
  /// Unix time in seconds.
  void commit({String? message, String? origin, int? timestamp}) {
    if (message == null && origin == null && timestamp == null) {
      b.loro_doc_commit(handle, _err);
    } else {
      final data = encodeWith(
        (w) => w
          ..optStr(origin)
          ..optStr(message)
          ..boolean(timestamp != null)
          ..f64((timestamp ?? 0).toDouble())
          ..boolean(true),
      );
      b.loro_doc_commit_with(handle, Runtime.input(data), data.length, _err);
    }
    _emit(null);
  }

  /// Sets the message of the next commit, including implicit ones.
  void setNextCommitMessage(String message) {
    final m = utf8Bytes(message);
    b.loro_doc_set_next_commit_message(
      handle,
      Runtime.input(m),
      m.length,
      _err,
    );
    _check();
  }

  /// Sets the origin of the next commit, including implicit ones.
  void setNextCommitOrigin(String origin) {
    final o = utf8Bytes(origin);
    b.loro_doc_set_next_commit_origin(handle, Runtime.input(o), o.length, _err);
    _check();
  }

  /// Sets the timestamp (Unix seconds) of the next commit.
  void setNextCommitTimestamp(int timestamp) {
    b.loro_doc_set_next_commit_timestamp(handle, timestamp.toDouble(), _err);
    _check();
  }

  void clearNextCommitOptions() {
    b.loro_doc_clear_next_commit_options(handle, _err);
    _check();
  }

  /// Number of operations in the uncommitted transaction.
  int get pendingTransactionLength =>
      _check2(b.loro_doc_get_pending_txn_len(handle, _err));

  // -------------------------------------------------------------------------
  // Import / export

  /// Imports a snapshot or updates from another peer. Missing dependencies
  /// are reported in [ImportStatus.pending] and applied once they arrive.
  ImportStatus import(Uint8List data, {String? origin}) {
    final Pointer<Uint8> result;
    if (origin == null) {
      result = b.loro_doc_import(
        handle,
        Runtime.input(data),
        data.length,
        _err,
      );
    } else {
      final o = utf8Bytes(origin);
      final (dp, op) = Runtime.input2(data, o);
      result = b.loro_doc_import_with(
        handle,
        dp,
        data.length,
        op,
        o.length,
        _err,
      );
    }
    final status = _decodeStatus(result);
    Events.dispatch();
    return status;
  }

  ImportStatus _decodeStatus(Pointer<Uint8> result) =>
      Runtime.reader(result).importStatus();

  /// Imports several blobs at once, faster than importing one by one.
  ImportStatus importBatch(List<Uint8List> blobs) {
    final data = encodeWith((w) {
      w.u32(blobs.length);
      blobs.forEach(w.bytes);
    });
    final status = _decodeStatus(
      b.loro_doc_import_batch(handle, Runtime.input(data), data.length, _err),
    );
    Events.dispatch();
    return status;
  }

  /// Imports updates in Loro's JSON format (see [exportJsonUpdates]).
  ImportStatus importJsonUpdates(String json) {
    final j = utf8Bytes(json);
    final status = _decodeStatus(
      b.loro_doc_import_json_updates(handle, Runtime.input(j), j.length, _err),
    );
    Events.dispatch();
    return status;
  }

  /// Exports the changes between [from] and [to] (everything by default) in
  /// Loro's human-readable JSON format.
  String exportJsonUpdates({VersionVector? from, VersionVector? to}) {
    final data = encodeWith(
      (w) => w
        ..versionVector(from ?? VersionVector.empty())
        ..versionVector(to ?? oplogVersion),
    );
    final s = Runtime.string(
      b.loro_doc_export_json_updates(
        handle,
        Runtime.input(data),
        data.length,
        _err,
      ),
    );
    Events.dispatch();
    return s;
  }

  /// Encodes the document; see [ExportMode] for the options.
  Uint8List export(ExportMode mode) {
    final arg = encodeWith((w) {
      switch (mode.code) {
        case 1:
          w.versionVector(mode.from!);
        case 2:
          w.u32(mode.spans!.length);
          for (final s in mode.spans!) {
            w
              ..peer(s.peer)
              ..i32(s.start)
              ..i32(s.end);
          }
        case 3 || 5:
          w.frontiers(mode.frontiers!);
        case 4:
          w.boolean(mode.frontiers != null);
          if (mode.frontiers != null) w.frontiers(mode.frontiers!);
      }
    });
    final out = Runtime.bytes(
      b.loro_doc_export(
        handle,
        mode.code,
        Runtime.input(arg),
        arg.length,
        _err,
      ),
    );
    Events.dispatch();
    return out;
  }

  /// Shorthand for `export(const ExportMode.snapshot())`.
  Uint8List exportSnapshot() => export(const ExportMode.snapshot());

  /// Shorthand for `export(ExportMode.updates(from: from))`.
  Uint8List exportUpdates({VersionVector? from}) =>
      export(ExportMode.updates(from: from));

  // -------------------------------------------------------------------------
  // Versions

  /// The version including every known operation.
  VersionVector get oplogVersion =>
      Runtime.reader(b.loro_doc_oplog_vv(handle, _err)).versionVector();

  /// The version of the current state (older than [oplogVersion] when
  /// checked out).
  VersionVector get stateVersion =>
      Runtime.reader(b.loro_doc_state_vv(handle, _err)).versionVector();

  /// For shallow documents, the version history starts at.
  VersionVector get shallowSinceVersion =>
      Runtime.reader(b.loro_doc_shallow_since_vv(handle, _err)).versionVector();

  Frontiers get oplogFrontiers =>
      Runtime.reader(b.loro_doc_oplog_frontiers(handle, _err)).frontiers();

  Frontiers get stateFrontiers =>
      Runtime.reader(b.loro_doc_state_frontiers(handle, _err)).frontiers();

  Frontiers get shallowSinceFrontiers => Runtime.reader(
    b.loro_doc_shallow_since_frontiers(handle, _err),
  ).frontiers();

  /// Converts [frontiers] to a version vector, `null` if they are unknown.
  VersionVector? frontiersToVersion(Frontiers frontiers) {
    final f = _frontiersArg(frontiers);
    final r = Runtime.reader(
      b.loro_doc_frontiers_to_vv(handle, Runtime.input(f), f.length, _err),
    );
    return r.opt(r.versionVector);
  }

  Frontiers versionToFrontiers(VersionVector version) {
    final v = encodeWith((w) => w.versionVector(version));
    return Runtime.reader(
      b.loro_doc_vv_to_frontiers(handle, Runtime.input(v), v.length, _err),
    ).frontiers();
  }

  /// Removes ids that are ancestors of other ids in [frontiers].
  Frontiers minimizeFrontiers(Frontiers frontiers) {
    final f = _frontiersArg(frontiers);
    return Runtime.reader(
      b.loro_doc_minimize_frontiers(handle, Runtime.input(f), f.length, _err),
    ).frontiers();
  }

  /// Compares the current oplog with [frontiers]: negative if the document
  /// is behind, 0 if equal, positive if ahead or concurrent.
  int compareWithFrontiers(Frontiers frontiers) {
    final f = _frontiersArg(frontiers);
    return _check2(
      b.loro_doc_cmp_with_frontiers(handle, Runtime.input(f), f.length, _err),
    );
  }

  /// Compares two versions of this document: negative, 0 or positive, or
  /// `null` if they are concurrent.
  int? compareFrontiers(Frontiers a, Frontiers c) {
    final data = encodeWith(
      (w) => w
        ..frontiers(a)
        ..frontiers(c),
    );
    final r = _check2(
      b.loro_doc_cmp_frontiers(handle, Runtime.input(data), data.length, _err),
    );
    return r == 2 ? null : r;
  }

  /// Number of operations in the history.
  int get opCount => _check2(b.loro_doc_len_ops(handle, _err));

  /// Number of changes in the history.
  int get changeCount => _check2(b.loro_doc_len_changes(handle, _err));

  /// Whether the history was truncated (see [ExportMode.shallowSnapshot]).
  bool get isShallow => _check2(b.loro_doc_is_shallow(handle, _err)) != 0;

  // -------------------------------------------------------------------------
  // Time travel

  /// Shows the document as of [frontiers]. The document becomes detached:
  /// edits are rejected (unless [detachedEditing]) until [checkoutToLatest]
  /// or [attach].
  void checkout(Frontiers frontiers) {
    final f = _frontiersArg(frontiers);
    b.loro_doc_checkout(handle, Runtime.input(f), f.length, _err);
    _emit(null);
  }

  void checkoutToLatest() {
    b.loro_doc_checkout_to_latest(handle, _err);
    _emit(null);
  }

  /// Returns to the latest version and resumes tracking it.
  void attach() {
    b.loro_doc_attach(handle, _err);
    _emit(null);
  }

  /// Stops applying imported changes to the visible state.
  void detach() {
    b.loro_doc_detach(handle, _err);
    _emit(null);
  }

  bool get isDetached => _check2(b.loro_doc_is_detached(handle, _err)) != 0;

  /// Creates new changes that bring the state back to [frontiers], keeping
  /// history (unlike [checkout]).
  void revertTo(Frontiers frontiers) {
    final f = _frontiersArg(frontiers);
    b.loro_doc_revert_to(handle, Runtime.input(f), f.length, _err);
    _emit(null);
  }

  /// The changes that turn version [from] into [to].
  DiffBatch diff(Frontiers from, Frontiers to) {
    final data = encodeWith(
      (w) => w
        ..frontiers(from)
        ..frontiers(to),
    );
    final h = b.loro_doc_diff(handle, Runtime.input(data), data.length, _err);
    return DiffBatch.fromHandle(_emit(h));
  }

  /// Applies a [DiffBatch] (possibly from another document) as local edits.
  void applyDiff(DiffBatch batch) {
    b.loro_doc_apply_diff(handle, batch.handle, _err);
    _emit(null);
  }

  // -------------------------------------------------------------------------
  // History

  /// The change containing operation [id].
  ChangeMeta? getChange(Id id) {
    final data = encodeWith((w) => w.id(id));
    final r = Runtime.reader(
      b.loro_doc_get_change(handle, Runtime.input(data), data.length, _err),
    );
    return r.opt(r.changeMeta);
  }

  /// The changes containing [ids] and all their ancestors, newest first.
  List<ChangeMeta> changeAncestors(List<Id> ids) {
    final data = encodeWith((w) {
      w.u32(ids.length);
      ids.forEach(w.id);
    });
    final r = Runtime.reader(
      b.loro_doc_change_ancestors(
        handle,
        Runtime.input(data),
        data.length,
        _err,
      ),
    );
    return r.list(r.changeMeta);
  }

  /// Containers modified by the [length] operations starting at [id].
  List<ContainerId> getChangedContainersIn(Id id, int length) {
    final data = encodeWith((w) => w.id(id));
    final r = Runtime.reader(
      b.loro_doc_get_changed_containers_in(
        handle,
        Runtime.input(data),
        data.length,
        length,
        _err,
      ),
    );
    return r.list(r.containerId);
  }

  // -------------------------------------------------------------------------
  // Cursors

  /// Resolves [cursor] to its current position.
  CursorPosition getCursorPos(Cursor cursor) {
    final data = cursor.encode();
    final r = Runtime.reader(
      b.loro_doc_get_cursor_pos(handle, Runtime.input(data), data.length, _err),
    );
    final update = r.optCursor();
    final offset = r.u32();
    return CursorPosition(offset, CursorSide.fromValue(r.i32()), update);
  }

  // -------------------------------------------------------------------------
  // Events

  /// Calls [listener] after every commit, import or checkout that changes
  /// the document.
  LoroSubscription subscribe(void Function(LoroEventBatch event) listener) =>
      LoroSubscription.create(
        b.loro_doc_subscribe_root(handle, _err),
        (payload) => listener(decodeEventBatch(Reader(payload))),
      );

  /// Calls [listener] after changes to the container [id] or its
  /// descendants.
  LoroSubscription subscribeContainer(
    ContainerId id,
    void Function(LoroEventBatch event) listener,
  ) {
    final s = utf8Bytes(id.toString());
    return LoroSubscription.create(
      b.loro_doc_subscribe(handle, Runtime.input(s), s.length, _err),
      (payload) => listener(decodeEventBatch(Reader(payload))),
    );
  }

  /// Calls [listener] with the encoded update of every local commit; send it
  /// to other peers and [import] it there.
  LoroSubscription subscribeLocalUpdates(
    void Function(Uint8List update) listener,
  ) => LoroSubscription.create(
    b.loro_doc_subscribe_local_update(handle, _err),
    (payload) => listener(Uint8List.fromList(Reader(payload).bytes())),
  );

  /// [subscribe] as a broadcast stream; cancel to unsubscribe.
  Stream<LoroEventBatch> get events => subscriptionStream(subscribe);

  /// [subscribeLocalUpdates] as a broadcast stream.
  Stream<Uint8List> get localUpdates =>
      subscriptionStream(subscribeLocalUpdates);

  // -------------------------------------------------------------------------
  // Maintenance

  /// Compacts the in-memory history to reduce memory usage.
  void compactChangeStore() {
    b.loro_doc_compact_change_store(handle, _err);
    _check();
  }

  /// Frees the history cache used by time travel (rebuilt on demand).
  void freeHistoryCache() {
    b.loro_doc_free_history_cache(handle, _err);
    _check();
  }

  void freeDiffCalculator() {
    b.loro_doc_free_diff_calculator(handle, _err);
    _check();
  }

  bool get hasHistoryCache =>
      _check2(b.loro_doc_has_history_cache(handle, _err)) != 0;

  /// Debug helper: verifies the internal state against the history (slow).
  void checkStateCorrectness() {
    b.loro_doc_check_state_correctness(handle, _err);
    _check();
  }

  @override
  String toString() => 'LoroDoc(peer: $peerId)';
}

/// Converts between Dart [VersionVector]/[Frontiers] and the binary encodings
/// used by other Loro bindings (e.g. `VersionVector.encode()` in JS).
abstract final class VersionEncoding {
  static Uint8List encodeVersion(VersionVector vv) {
    final data = encodeWith((w) => w.versionVector(vv));
    return Runtime.bytes(
      b.loro_vv_encode(Runtime.input(data), data.length, _err),
    );
  }

  static VersionVector decodeVersion(Uint8List bytes) => Runtime.reader(
    b.loro_vv_decode(Runtime.input(bytes), bytes.length, _err),
  ).versionVector();

  static Uint8List encodeFrontiers(Frontiers f) {
    final data = encodeWith((w) => w.frontiers(f));
    return Runtime.bytes(
      b.loro_frontiers_encode(Runtime.input(data), data.length, _err),
    );
  }

  static Frontiers decodeFrontiers(Uint8List bytes) => Runtime.reader(
    b.loro_frontiers_decode(Runtime.input(bytes), bytes.length, _err),
  ).frontiers();
}
