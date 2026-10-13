import 'package:meta/meta.dart';

import 'ffi/bindings.dart' as b;
import 'ffi/proxy_ffi.dart';

/// Base of the Dart objects that own a native Loro handle.
///
/// The handle is released when the object is garbage collected, or earlier
/// with [dispose].
abstract class NativeObject implements Finalizable {
  NativeObject(Pointer<Void> handle, this._finalizer, this._free)
    : _handle = handle {
    if (handle.address == 0) {
      throw StateError('Loro returned a null handle');
    }
    _finalizer.attach(this, handle, detach: this);
  }

  Pointer<Void> _handle;
  final b.LoroFinalizer _finalizer;
  final void Function(Pointer<Void>) _free;

  /// The native handle. Throws once [dispose]d.
  @internal
  Pointer<Void> get handle {
    final h = _handle;
    if (h.address == 0) {
      throw StateError('This $runtimeType has been disposed.');
    }
    return h;
  }

  bool get isDisposed => _handle.address == 0;

  /// Releases the native resources now instead of waiting for garbage
  /// collection. The object must not be used afterwards.
  @mustCallSuper
  void dispose() {
    final h = _handle;
    if (h.address == 0) return;
    _handle = Pointer.fromAddress(0);
    _finalizer.detach(this);
    _free(h);
  }
}
