import 'dart:async';
import 'dart:typed_data';

import 'codec.dart';
import 'delta.dart';
import 'ffi/bindings.dart' as b;
import 'ffi/proxy_ffi.dart';
import 'ffi/runtime.dart';
import 'native_object.dart';
import 'types.dart';

/// Delivers queued native events to their Dart listeners.
///
/// Native subscriptions only enqueue events. Every API that can emit events
/// (commits, imports, checkouts, undo/redo, ephemeral store updates) calls
/// [dispatch] before returning, so listeners run synchronously after the
/// operation, outside of the native library.
final class Events {
  Events._();

  static final Set<LoroSubscription> _active = {};
  static bool _dispatching = false;

  static void dispatch() {
    if (_active.isEmpty || _dispatching) return;
    if (b.loro_events_pending() == 0) return;
    _dispatching = true;
    try {
      // Listeners may cause more events (e.g. by committing); keep draining
      // until a full pass delivers nothing.
      var progressed = true;
      while (progressed) {
        progressed = false;
        for (final sub in _active.toList(growable: false)) {
          while (!sub.isDisposed) {
            final p = b.loro_subscription_poll(sub.handle);
            if (p.address == 0) break;
            progressed = true;
            final payload = Runtime.takeBuffer(p);
            try {
              sub._deliver(payload);
            } catch (e, s) {
              Zone.current.handleUncaughtError(e, s);
            }
          }
        }
      }
    } finally {
      _dispatching = false;
    }
  }
}

/// An active subscription. Listeners stay registered until [unsubscribe] is
/// called, like a `StreamSubscription`.
final class LoroSubscription extends NativeObject {
  LoroSubscription._(Pointer<Void> handle, this._deliver)
    : super(
        handle,
        b.loro_subscription_free_finalizer,
        b.loro_subscription_free,
      ) {
    Events._active.add(this);
  }

  /// Wraps a native subscription handle (checking for errors first).
  static LoroSubscription create(
    Pointer<Void> handle,
    void Function(Uint8List payload) deliver,
  ) {
    Runtime.check();
    return LoroSubscription._(handle, deliver);
  }

  final void Function(Uint8List payload) _deliver;

  /// Whether events are still delivered, i.e. [unsubscribe] was not called.
  bool get isActive => !isDisposed;

  /// Stops delivering events. Events queued but not yet delivered are
  /// dropped.
  void unsubscribe() => dispose();

  @override
  void dispose() {
    Events._active.remove(this);
    super.dispose();
  }
}

/// Builds a broadcast [Stream] that subscribes while it has listeners.
Stream<T> subscriptionStream<T>(
  LoroSubscription Function(void Function(T) onEvent) subscribe,
) {
  LoroSubscription? sub;
  late final StreamController<T> controller;
  controller = StreamController<T>.broadcast(
    sync: true,
    onListen: () => sub = subscribe(controller.add),
    onCancel: () {
      sub?.unsubscribe();
      sub = null;
    },
  );
  return controller.stream;
}

/// What caused an event.
enum EventTrigger {
  /// A local commit.
  local,

  /// Importing changes from another peer.
  import,

  /// Checking out another version.
  checkout,
}

/// All changes from one commit, import or checkout.
final class LoroEventBatch {
  /// Creates a batch; subscription listeners receive these.
  const LoroEventBatch({
    required this.by,
    required this.origin,
    required this.currentTarget,
    required this.events,
  });

  /// What caused the changes.
  final EventTrigger by;

  /// The origin passed to `commit`/`import`, empty if none.
  final String origin;

  /// For container subscriptions, the container subscribed to.
  final ContainerId? currentTarget;

  /// One event per changed container, parents before children.
  final List<LoroEvent> events;

  @override
  String toString() =>
      'LoroEventBatch(by: ${by.name}, origin: "$origin", events: $events)';
}

/// The change to one container.
final class LoroEvent {
  /// Creates an event; see [LoroEventBatch.events].
  const LoroEvent({
    required this.target,
    required this.path,
    required this.isUnknown,
    required this.diff,
  });

  /// The changed container.
  final ContainerId target;

  /// From the root container down to [target].
  final List<PathSegment> path;

  /// The container type is unknown to this version of Loro.
  final bool isUnknown;

  /// What changed in [target].
  final Diff diff;

  @override
  String toString() => 'LoroEvent($target, $diff)';
}

/// A step on the path to a container.
final class PathSegment {
  /// The step to [container], found at [index] in its parent.
  const PathSegment(this.container, this.index);

  /// The container at this step.
  final ContainerId container;

  /// Where the container sits in its parent: a map key (`String`), a list
  /// index (`int`) or a tree node ([TreeId]).
  final Object index;

  @override
  String toString() => '$container[$index]';
}

/// A change to a container.
sealed class Diff {
  const Diff();
}

/// List changes, for `LoroList` and `LoroMovableList`.
final class ListDiff extends Diff {
  /// A list change described by [delta].
  const ListDiff(this.delta);

  /// The changes as a delta over the old list.
  final List<ListDelta> delta;

  @override
  String toString() => 'ListDiff($delta)';
}

/// Text changes; lengths are UTF-16 code units.
final class TextDiff extends Diff {
  /// A text change described by [delta].
  const TextDiff(this.delta);

  /// The changes as a delta over the old text.
  final List<TextDelta> delta;

  @override
  String toString() => 'TextDiff($delta)';
}

/// Map changes.
final class MapDiff extends Diff {
  /// A map change that sets the [updated] keys and removes the [deleted]
  /// ones.
  const MapDiff(this.updated, this.deleted);

  /// Keys set to a new value or container.
  final Map<String, Object?> updated;

  /// Keys that were removed.
  final Set<String> deleted;

  @override
  String toString() => 'MapDiff(updated: $updated, deleted: $deleted)';
}

/// Tree changes: created, moved and deleted nodes.
final class TreeDiff extends Diff {
  /// A tree change made of [items].
  const TreeDiff(this.items);

  /// The node changes, in the order they apply.
  final List<TreeDiffItem> items;

  @override
  String toString() => 'TreeDiff($items)';
}

/// A counter change.
final class CounterDiff extends Diff {
  /// A counter change that adds [increment].
  const CounterDiff(this.increment);

  /// The amount added, negative for a decrease.
  final double increment;

  @override
  String toString() => 'CounterDiff($increment)';
}

/// A change to a container of a type this version of Loro does not know.
final class UnknownDiff extends Diff {
  /// A change to an unknown container.
  const UnknownDiff();
}

/// What happened to a tree node.
enum TreeAction {
  /// The node was created.
  create,

  /// The node was moved to another parent or position.
  move,

  /// The node was deleted.
  delete,
}

/// A created, moved or deleted tree node.
final class TreeDiffItem {
  /// Creates a node change; see [TreeDiff.items].
  const TreeDiffItem({
    required this.target,
    required this.action,
    this.parent,
    this.index,
    this.fractionalIndex,
    this.oldParent,
    this.oldIndex,
  });

  /// The node that changed.
  final TreeId target;

  /// What happened to [target].
  final TreeAction action;

  /// The new parent (create and move).
  final TreeParent? parent;

  /// The new position among the siblings (create and move).
  final int? index;

  /// The new fractional index (create and move).
  final String? fractionalIndex;

  /// The previous parent (move and delete).
  final TreeParent? oldParent;

  /// The previous position among the siblings (move and delete).
  final int? oldIndex;

  @override
  String toString() =>
      'TreeDiffItem(${action.name} $target, parent: $parent, index: $index)';
}

/// What caused an ephemeral store event.
enum EphemeralTrigger {
  /// A local `set` or `delete`.
  local,

  /// Applying an update from another peer.
  import,

  /// Entries expired, see `EphemeralStore.removeOutdated`.
  timeout,
}

/// Keys that changed in an `EphemeralStore`.
final class EphemeralStoreEvent {
  /// Creates an event; `EphemeralStore` listeners receive these.
  const EphemeralStoreEvent(this.by, this.added, this.updated, this.removed);

  /// What caused the changes.
  final EphemeralTrigger by;

  /// Keys that did not exist before.
  final List<String> added;

  /// Keys whose value changed.
  final List<String> updated;

  /// Keys that were deleted or expired.
  final List<String> removed;

  @override
  String toString() =>
      'EphemeralStoreEvent(${by.name}, added: $added, updated: $updated, removed: $removed)';
}

// ---------------------------------------------------------------------------
// Decoding, mirroring native/src/events.rs.

LoroEventBatch decodeEventBatch(Reader r) => LoroEventBatch(
  by: EventTrigger.values[r.u8()],
  origin: r.str(),
  currentTarget: r.opt(r.containerId),
  events: r.list(
    () => LoroEvent(
      target: r.containerId(),
      path: r.list(() => PathSegment(r.containerId(), r.pathIndex())),
      isUnknown: r.boolean(),
      diff: decodeDiff(r),
    ),
  ),
);

Diff decodeDiff(Reader r) {
  switch (r.u8()) {
    case 0:
      return ListDiff(
        r.list<ListDelta>(
          () => switch (r.u8()) {
            0 => ListInsert(r.valuesOrContainers(), isMove: r.boolean()),
            1 => ListDelete(r.u32()),
            _ => ListRetain(r.u32()),
          },
        ),
      );
    case 1:
      return TextDiff(r.textDeltas());
    case 2:
      final updated = <String, Object?>{};
      final deleted = <String>{};
      final n = r.u32();
      for (var i = 0; i < n; i++) {
        final k = r.str();
        final v = r.valueOrContainer();
        if (identical(v, absent)) {
          deleted.add(k);
        } else {
          updated[k] = v;
        }
      }
      return MapDiff(updated, deleted);
    case 3:
      return TreeDiff(
        r.list(() {
          final target = r.treeId();
          return switch (r.u8()) {
            0 => TreeDiffItem(
              target: target,
              action: TreeAction.create,
              parent: r.treeParent(),
              index: r.u32(),
              fractionalIndex: r.str(),
            ),
            1 => TreeDiffItem(
              target: target,
              action: TreeAction.move,
              parent: r.treeParent(),
              index: r.u32(),
              fractionalIndex: r.str(),
              oldParent: r.treeParent(),
              oldIndex: r.u32(),
            ),
            _ => TreeDiffItem(
              target: target,
              action: TreeAction.delete,
              oldParent: r.treeParent(),
              oldIndex: r.u32(),
            ),
          };
        }),
      );
    case 4:
      return CounterDiff(r.f64());
    default:
      return const UnknownDiff();
  }
}

EphemeralStoreEvent decodeEphemeralEvent(Reader r) => EphemeralStoreEvent(
  EphemeralTrigger.values[r.u8()],
  r.strs(),
  r.strs(),
  r.strs(),
);

/// A set of container diffs between two versions, from `LoroDoc.diff`. Apply
/// it to a document with `LoroDoc.applyDiff`.
final class DiffBatch extends NativeObject {
  /// Wraps a native diff batch handle; the result owns the handle.
  DiffBatch.fromHandle(Pointer<Void> handle)
    : super(handle, b.loro_diff_batch_free_finalizer, b.loro_diff_batch_free);

  /// The diffs in application order.
  List<(ContainerId, Diff)> get entries {
    final r = Runtime.reader(
      b.loro_diff_batch_entries(handle, Runtime.errSlot),
    );
    return r.list(() => (r.containerId(), decodeDiff(r)));
  }

  @override
  String toString() => 'DiffBatch($entries)';
}
