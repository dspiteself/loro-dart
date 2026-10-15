import 'dart:typed_data';

import 'codec.dart';
import 'events.dart';
import 'ffi/bindings.dart' as b;
import 'ffi/proxy_ffi.dart';
import 'ffi/runtime.dart';
import 'native_object.dart';

final _err = Runtime.errSlot;

/// Short-lived shared state such as cursors, selections or "who is online".
///
/// Unlike a `LoroDoc`, an ephemeral store keeps
/// no history: each key holds the latest value (last writer wins) and entries
/// expire after [timeout] without updates. Exchange updates with
/// [encode]/[encodeAll] and [apply], typically by sending everything from
/// [subscribeLocalUpdates] to the other peers.
///
/// Conflicts are resolved by millisecond timestamps, so peers ignore a
/// write to a key that is not newer than the one they hold: two writes to
/// the same key within the same millisecond may not both reach other peers.
final class EphemeralStore extends NativeObject {
  /// Creates an empty store whose entries expire after [timeout] without
  /// updates.
  EphemeralStore({Duration timeout = const Duration(seconds: 30)})
    : super(
        _create(timeout),
        b.loro_ephemeral_free_finalizer,
        b.loro_ephemeral_free,
      );

  static Pointer<Void> _create(Duration timeout) {
    final h = b.loro_ephemeral_new(timeout.inMicroseconds / 1000, _err);
    Runtime.check();
    return h;
  }

  void _emit() {
    Runtime.check();
    Events.dispatch();
  }

  /// Sets [key] to a plain value.
  void set(String key, Object? value) {
    final k = utf8Bytes(key);
    final v = encodeValue(value);
    final (kp, vp) = Runtime.input2(k, v);
    b.loro_ephemeral_set(handle, kp, k.length, vp, v.length, _err);
    _emit();
  }

  /// Same as [set].
  void operator []=(String key, Object? value) => set(key, value);

  /// The value of [key], or `null`.
  Object? get(String key) {
    final k = utf8Bytes(key);
    final v = Runtime.reader(
      b.loro_ephemeral_get(handle, Runtime.input(k), k.length, _err),
    ).valueOrContainer();
    return identical(v, absent) ? null : v;
  }

  /// Same as [get].
  Object? operator [](String key) => get(key);

  /// Removes [key].
  void delete(String key) {
    final k = utf8Bytes(key);
    b.loro_ephemeral_delete(handle, Runtime.input(k), k.length, _err);
    _emit();
  }

  /// The live keys in sorted order.
  List<String> get keys =>
      Runtime.reader(b.loro_ephemeral_keys(handle, _err)).strs();

  /// Every live entry.
  Map<String, Object?> getAllStates() =>
      Runtime.reader(b.loro_ephemeral_get_all_states(handle, _err)).value()!
          as Map<String, Object?>;

  /// An update carrying [key].
  Uint8List encode(String key) {
    final k = utf8Bytes(key);
    return Runtime.bytes(
      b.loro_ephemeral_encode(handle, Runtime.input(k), k.length, 0, _err),
    );
  }

  /// An update carrying every live entry.
  Uint8List encodeAll() => Runtime.bytes(
    b.loro_ephemeral_encode(handle, Runtime.input(Uint8List(0)), 0, 1, _err),
  );

  /// Applies an update from another peer.
  void apply(Uint8List update) {
    b.loro_ephemeral_apply(handle, Runtime.input(update), update.length, _err);
    _emit();
  }

  /// Drops expired entries (emitting `timeout` events).
  void removeOutdated() {
    b.loro_ephemeral_remove_outdated(handle, _err);
    _emit();
  }

  /// Calls [listener] when keys are added, updated or removed.
  LoroSubscription subscribe(
    void Function(EphemeralStoreEvent event) listener,
  ) => LoroSubscription.create(
    b.loro_ephemeral_subscribe(handle, _err),
    (payload) => listener(decodeEphemeralEvent(Reader(payload))),
  );

  /// Calls [listener] with an encoded update after every local change.
  LoroSubscription subscribeLocalUpdates(
    void Function(Uint8List update) listener,
  ) => LoroSubscription.create(
    b.loro_ephemeral_subscribe_local_updates(handle, _err),
    (payload) => listener(Uint8List.fromList(Reader(payload).bytes())),
  );

  /// [subscribe] as a broadcast stream.
  Stream<EphemeralStoreEvent> get events => subscriptionStream(subscribe);

  /// [subscribeLocalUpdates] as a broadcast stream.
  Stream<Uint8List> get localUpdates =>
      subscriptionStream(subscribeLocalUpdates);
}
