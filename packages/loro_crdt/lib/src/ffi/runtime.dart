import 'dart:convert';
import 'dart:typed_data';

import '../codec.dart';
import '../errors.dart';
import 'bindings.dart' as b;
import 'proxy_ffi.dart';

/// Shared, per-isolate state for calling into the native library.
///
/// Every fallible native function takes [errSlot] as its last argument. On
/// failure Rust stores an owned error buffer there; [check] turns it into a
/// [LoroException].
final class Runtime {
  Runtime._();

  static final Pointer<Pointer<Uint8>> errSlot = b
      .loro_alloc(8)
      .cast<Pointer<Uint8>>();

  /// Throws if the last native call reported an error.
  @pragma('vm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  static void check() {
    final e = errSlot.value;
    if (e.address != 0) _throw(e);
  }

  static Never _throw(Pointer<Uint8> e) {
    errSlot.value = Pointer.fromAddress(0);
    final r = Reader(takeBuffer(e));
    final code = r.str();
    final message = r.str();
    throw LoroException(code, message);
  }

  /// Copies an owned output buffer into Dart memory and frees it.
  static Uint8List takeBuffer(Pointer<Uint8> p) {
    if (p.address == 0) {
      throw StateError('native call returned a null buffer');
    }
    final h = p.asTypedList(4);
    final len = h[0] + h[1] * 0x100 + h[2] * 0x10000 + h[3] * 0x1000000;
    final out = Uint8List.fromList(
      Uint8List.sublistView(p.asTypedList(4 + len), 4),
    );
    b.loro_buf_free(p);
    return out;
  }

  /// [check]s, then decodes an owned output buffer with a [Reader].
  static Reader reader(Pointer<Uint8> p) {
    check();
    return Reader(takeBuffer(p));
  }

  /// [check]s, then returns the byte array encoded in an owned output
  /// buffer (`[u32 len][u32 n][n bytes]`), copied once out of native memory.
  static Uint8List bytes(Pointer<Uint8> p) {
    check();
    if (p.address == 0) {
      throw StateError('native call returned a null buffer');
    }
    final h = p.asTypedList(8);
    final n = h[4] + h[5] * 0x100 + h[6] * 0x10000 + h[7] * 0x1000000;
    final out = Uint8List.fromList(
      Uint8List.sublistView(p.asTypedList(8 + n), 8),
    );
    b.loro_buf_free(p);
    return out;
  }

  /// [check]s, then returns the string in an owned output buffer.
  static String string(Pointer<Uint8> p) {
    check();
    return Reader(takeBuffer(p)).str();
  }

  // Input arena. Inputs are copied into native memory right before a call and
  // stay valid only until the next `input*` call. Calls are synchronous and
  // never re-enter Dart, so one arena per isolate is enough.
  static const _scratchLimit = 1 << 20;
  static Pointer<Uint8> _scratch = Pointer.fromAddress(0);
  static int _scratchCap = 0;
  static Pointer<Uint8> _large = Pointer.fromAddress(0);
  static int _largeLen = 0;

  static Pointer<Uint8> _reserve(int total) {
    if (_largeLen != 0) {
      b.loro_dealloc(_large, _largeLen);
      _large = Pointer.fromAddress(0);
      _largeLen = 0;
    }
    if (total > _scratchLimit) {
      _large = b.loro_alloc(total);
      _largeLen = total;
      return _large;
    }
    if (total > _scratchCap) {
      if (_scratchCap != 0) b.loro_dealloc(_scratch, _scratchCap);
      var cap = _scratchCap == 0 ? 4096 : _scratchCap;
      while (cap < total) {
        cap *= 2;
      }
      _scratch = b.loro_alloc(cap);
      _scratchCap = cap;
    }
    return _scratch;
  }

  /// Copies [data] into native memory valid until the next `input*` call.
  static Pointer<Uint8> input(Uint8List data) {
    final base = _reserve(data.isEmpty ? 1 : data.length);
    if (data.isNotEmpty) base.asTypedList(data.length).setAll(0, data);
    return base;
  }

  /// Like [input] for two buffers passed to the same call.
  static (Pointer<Uint8>, Pointer<Uint8>) input2(Uint8List a, Uint8List c) {
    final base = _reserve(a.length + c.length + 1);
    final view = base.asTypedList(a.length + c.length + 1);
    view.setAll(0, a);
    view.setAll(a.length, c);
    return (base, Pointer.fromAddress(base.address + a.length));
  }

  /// Like [input] for three buffers passed to the same call.
  static (Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>) input3(
    Uint8List a,
    Uint8List c,
    Uint8List d,
  ) {
    final total = a.length + c.length + d.length;
    final base = _reserve(total + 1);
    final view = base.asTypedList(total + 1);
    view.setAll(0, a);
    view.setAll(a.length, c);
    view.setAll(a.length + c.length, d);
    return (
      base,
      Pointer.fromAddress(base.address + a.length),
      Pointer.fromAddress(base.address + a.length + c.length),
    );
  }
}

/// UTF-8 encodes a string for passing to native code.
Uint8List utf8Bytes(String s) => utf8.encode(s);
