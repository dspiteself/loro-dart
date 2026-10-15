import 'doc.dart';
import 'ffi/proxy_ffi.dart';
import 'events.dart';
import 'ffi/bindings.dart' as b;
import 'ffi/runtime.dart';
import 'native_object.dart';

final _err = Runtime.errSlot;

/// Undo/redo for the local edits of one peer.
///
/// Only changes made through this [LoroDoc] are recorded; changes imported
/// from other peers are never undone, but recorded steps are transformed so
/// they still apply cleanly on top of them.
final class UndoManager extends NativeObject {
  /// Records local edits of [doc]. See [maxUndoSteps], [mergeInterval] and
  /// [addExcludeOriginPrefix] for the options.
  UndoManager(
    LoroDoc doc, {
    int? maxUndoSteps,
    Duration? mergeInterval,
    Iterable<String> excludeOriginPrefixes = const [],
  }) : super(_create(doc), b.loro_undo_free_finalizer, b.loro_undo_free) {
    if (maxUndoSteps != null) this.maxUndoSteps = maxUndoSteps;
    if (mergeInterval != null) this.mergeInterval = mergeInterval;
    excludeOriginPrefixes.forEach(addExcludeOriginPrefix);
  }

  static Pointer<Void> _create(LoroDoc doc) {
    final h = b.loro_undo_new(doc.handle, _err);
    Runtime.check();
    return h;
  }

  /// Undoes the last local step. Returns `false` if there was nothing to
  /// undo.
  bool undo() {
    final r = b.loro_undo_undo(handle, _err);
    Runtime.check();
    Events.dispatch();
    return r != 0;
  }

  /// Redoes the last undone step. Returns `false` if there was nothing to
  /// redo.
  bool redo() {
    final r = b.loro_undo_redo(handle, _err);
    Runtime.check();
    Events.dispatch();
    return r != 0;
  }

  int _query(int which) {
    final r = b.loro_undo_query(handle, which, _err);
    Runtime.check();
    return r;
  }

  /// Whether there is a step to undo.
  bool get canUndo => _query(0) != 0;

  /// Whether there is a step to redo.
  bool get canRedo => _query(1) != 0;

  /// The number of steps on the undo stack.
  int get undoCount => _query(2);

  /// The number of steps on the redo stack.
  int get redoCount => _query(3);

  /// Whether recording is paused, see [pause].
  bool get isPaused => _query(4) != 0;

  /// Records the pending local changes as an undo step now rather than at
  /// the next commit. Steps within the merge interval are still merged.
  void recordNewCheckpoint() {
    b.loro_undo_record_new_checkpoint(handle, _err);
    Runtime.check();
  }

  /// The maximum number of undo steps kept; older steps are dropped.
  set maxUndoSteps(int steps) {
    b.loro_undo_set_max_undo_steps(handle, steps, _err);
    Runtime.check();
  }

  /// Local commits closer together than this are merged into one step.
  set mergeInterval(Duration interval) {
    b.loro_undo_set_merge_interval(
      handle,
      interval.inMicroseconds / 1000,
      _err,
    );
    Runtime.check();
  }

  /// Commits whose origin starts with [prefix] are not recorded.
  void addExcludeOriginPrefix(String prefix) {
    final p = utf8Bytes(prefix);
    b.loro_undo_add_exclude_origin_prefix(
      handle,
      Runtime.input(p),
      p.length,
      _err,
    );
    Runtime.check();
  }

  void _control(int op) {
    b.loro_undo_control(handle, op, _err);
    Runtime.check();
  }

  /// Drops the undo and redo stacks.
  void clear() => _control(0);

  /// Groups every commit until [groupEnd] into a single undo step.
  void groupStart() => _control(1);

  /// Ends the group started by [groupStart].
  void groupEnd() => _control(2);

  /// Stops recording until [resume].
  void pause() => _control(3);

  /// Resumes recording after [pause].
  void resume() => _control(4);
}
