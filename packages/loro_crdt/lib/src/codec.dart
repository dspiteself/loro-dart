import 'dart:convert';
import 'dart:typed_data';

import 'containers.dart';
import 'delta.dart';
import 'types.dart';

// Value tags, mirrored in native/src/codec.rs.
const tagNull = 0;
const tagFalse = 1;
const tagTrue = 2;
const tagI64 = 3;
const tagF64 = 4;
const tagString = 5;
const tagBinary = 6;
const tagList = 7;
const tagMap = 8;
const tagContainerId = 9;
const tagContainer = 10;
const tagAbsent = 11;

/// Marker returned by [Reader.valueOrContainer] for a missing value, so that
/// "absent" and "present but null" can be told apart.
const Object absent = _Absent();

final class _Absent {
  const _Absent();
}

const _two32 = 4294967296;

/// Decodes the little-endian format written by `native/src/codec.rs`.
///
/// 64-bit integers are read as two 32-bit halves because `ByteData.getInt64`
/// is not available when compiling to JavaScript.
final class Reader {
  Reader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _pos = 0;

  bool get isEmpty => _pos >= _bytes.length;

  int u8() => _bytes[_pos++];

  bool boolean() => u8() != 0;

  int u32() {
    final v = _data.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int i32() {
    final v = _data.getInt32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int i64() {
    final lo = _data.getUint32(_pos, Endian.little);
    final hi = _data.getInt32(_pos + 4, Endian.little);
    _pos += 8;
    return hi * _two32 + lo;
  }

  double f64() {
    final v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  Uint8List bytes() {
    final n = u32();
    final out = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return out;
  }

  String str() {
    final n = u32();
    final s = utf8.decode(Uint8List.sublistView(_bytes, _pos, _pos + n));
    _pos += n;
    return s;
  }

  String? optStr() => boolean() ? str() : null;

  /// Peer ids travel as decimal strings; see [PeerId].
  String peer() => str();

  Id id() => Id(peer(), i32());

  Frontiers frontiers() {
    final n = u32();
    return Frontiers([for (var i = 0; i < n; i++) id()]);
  }

  VersionVector versionVector() {
    final n = u32();
    return VersionVector({for (var i = 0; i < n; i++) peer(): i32()});
  }

  ContainerId containerId() => ContainerId.parse(str());

  List<T> list<T>(T Function() item) {
    final n = u32();
    return [for (var i = 0; i < n; i++) item()];
  }

  /// `[u8 has]` then [item] when present.
  T? opt<T extends Object>(T Function() item) => boolean() ? item() : null;

  PeerId? optPeer() => opt(peer);

  Cursor? optCursor() => opt(cursor);

  TreeParent? optTreeParent() => opt(treeParent);

  List<TreeId> treeIds() => list(treeId);

  List<TreeId>? optTreeIds() => opt(treeIds);

  List<String> strs() => list(str);

  List<Object?> valuesOrContainers() => list(valueOrContainer);

  Id? optId() => opt(id);

  TreeId treeId() => TreeId(peer(), i32());

  TreeParent treeParent() => switch (u8()) {
    0 => TreeParent.ofNode(treeId()),
    1 => const TreeParent.root(),
    2 => const TreeParent.deleted(),
    _ => const TreeParent.nonexistent(),
  };

  Map<String, Object?>? attributes() {
    if (!boolean()) return null;
    final n = u32();
    final m = <String, Object?>{};
    for (var i = 0; i < n; i++) {
      final k = str();
      m[k] = value();
    }
    return m;
  }

  TextDelta textDelta() => switch (u8()) {
    0 => TextInsert(str(), attributes: attributes()),
    1 => TextDelete(u32()),
    _ => TextRetain(u32(), attributes: attributes()),
  };

  List<TextDelta> textDeltas() => list(textDelta);

  ChangeMeta changeMeta() => ChangeMeta(
    lamport: u32(),
    id: id(),
    timestamp: f64().toInt(),
    message: optStr(),
    deps: frontiers(),
    length: u32(),
  );

  List<IdSpan> versionRange() => list(() => IdSpan(peer(), i32(), i32()));

  ImportStatus importStatus() =>
      ImportStatus(versionRange(), opt(versionRange));

  Cursor cursor() => makeCursor(
    Uint8List.fromList(bytes()),
    containerId(),
    CursorSide.fromValue(i32()),
    optId(),
  );

  /// A path segment: a map key (`String`), a list index (`int`) or a tree
  /// node ([TreeId]).
  Object pathIndex() => switch (u8()) {
    0 => str(),
    1 => u32(),
    _ => treeId(),
  };

  /// A plain value: `null`, `bool`, `int`, `double`, `String`, `Uint8List`,
  /// `List<Object?>`, `Map<String, Object?>` or [ContainerId]. Live
  /// containers ([LoroContainer]) appear only in "value or container" results.
  Object? value() => _value(u8());

  /// A value that may also be a live [LoroContainer] or [absent].
  Object? valueOrContainer() => _value(u8());

  Object? _value(int tag) {
    switch (tag) {
      case tagNull:
        return null;
      case tagFalse:
        return false;
      case tagTrue:
        return true;
      case tagI64:
        return i64();
      case tagF64:
        return f64();
      case tagString:
        return str();
      case tagBinary:
        return Uint8List.fromList(bytes());
      case tagList:
        final n = u32();
        return <Object?>[for (var i = 0; i < n; i++) value()];
      case tagMap:
        final n = u32();
        final m = <String, Object?>{};
        for (var i = 0; i < n; i++) {
          final k = str();
          m[k] = value();
        }
        return m;
      case tagContainerId:
        return containerId();
      case tagContainer:
        final type = ContainerType.values[u8()];
        final lo = u32();
        final hi = u32();
        return LoroContainer.fromAddress(type, hi * _two32 + lo);
      case tagAbsent:
        return absent;
    }
    throw FormatException('Unexpected value tag $tag');
  }
}

/// Encodes inputs in the format read by `native/src/codec.rs`.
final class Writer {
  Uint8List _buf = Uint8List(64);
  late ByteData _data = ByteData.sublistView(_buf);
  int _len = 0;

  void _ensure(int extra) {
    final need = _len + extra;
    if (need <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < need) {
      cap *= 2;
    }
    final next = Uint8List(cap)..setRange(0, _len, _buf);
    _buf = next;
    _data = ByteData.sublistView(next);
  }

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _len);

  void u8(int v) {
    _ensure(1);
    _buf[_len++] = v;
  }

  void boolean(bool v) => u8(v ? 1 : 0);

  void u32(int v) {
    _ensure(4);
    _data.setUint32(_len, v, Endian.little);
    _len += 4;
  }

  void i32(int v) {
    _ensure(4);
    _data.setInt32(_len, v, Endian.little);
    _len += 4;
  }

  void i64(int v) {
    _ensure(8);
    final int lo;
    final int hi;
    if (_jsNumbers) {
      lo = v % _two32;
      hi = (v - lo) ~/ _two32;
    } else {
      lo = v & 0xFFFFFFFF;
      hi = v >> 32;
    }
    _data
      ..setUint32(_len, lo, Endian.little)
      ..setInt32(_len + 4, hi, Endian.little);
    _len += 8;
  }

  void f64(double v) {
    _ensure(8);
    _data.setFloat64(_len, v, Endian.little);
    _len += 8;
  }

  void raw(List<int> v) {
    _ensure(v.length);
    _buf.setRange(_len, _len + v.length, v);
    _len += v.length;
  }

  void bytes(List<int> v) {
    u32(v.length);
    raw(v);
  }

  void str(String s) => bytes(utf8.encode(s));

  void optStr(String? s) {
    boolean(s != null);
    if (s != null) str(s);
  }

  void peer(String peer) => str(peer);

  void id(Id id) {
    peer(id.peer);
    i32(id.counter);
  }

  void frontiers(Frontiers f) {
    u32(f.length);
    f.forEach(id);
  }

  void versionVector(VersionVector vv) {
    u32(vv.length);
    vv.forEach((peer, counter) {
      this.peer(peer);
      i32(counter);
    });
  }

  void containerId(ContainerId id) => str(id.toString());

  void treeId(TreeId id) {
    peer(id.peer);
    i32(id.counter);
  }

  /// `[u8 has][tree id]`; `null` is the tree root.
  void optTreeId(TreeId? id) {
    boolean(id != null);
    if (id != null) treeId(id);
  }

  void attributes(Map<String, Object?>? attrs) {
    boolean(attrs != null);
    if (attrs == null) return;
    u32(attrs.length);
    attrs.forEach((k, v) {
      str(k);
      value(v);
    });
  }

  void textDeltas(List<TextDelta> deltas) {
    u32(deltas.length);
    for (final d in deltas) {
      switch (d) {
        case TextInsert(:final text, :final attributes):
          u8(0);
          str(text);
          this.attributes(attributes);
        case TextDelete(:final count):
          u8(1);
          u32(count);
        case TextRetain(:final count, :final attributes):
          u8(2);
          u32(count);
          this.attributes(attributes);
      }
    }
  }

  /// Encodes a plain Dart value. Supported: `null`, `bool`, `int`, `double`,
  /// `String`, `List<int>` byte arrays as [Uint8List], `Iterable`, `Map` with
  /// `String` keys and [ContainerId].
  void value(Object? v) {
    switch (v) {
      case null:
        u8(tagNull);
      case bool b:
        u8(b ? tagTrue : tagFalse);
      case int i:
        // On the web every whole double is an `int`; keep doubles as doubles
        // when they are outside the safe integer range.
        if (_jsNumbers && (i > _maxSafe || i < -_maxSafe)) {
          u8(tagF64);
          f64(i.toDouble());
        } else {
          u8(tagI64);
          i64(i);
        }
      case double d:
        u8(tagF64);
        f64(d);
      case String s:
        u8(tagString);
        str(s);
      case Uint8List b:
        u8(tagBinary);
        bytes(b);
      case ContainerId id:
        u8(tagContainerId);
        containerId(id);
      case Map m:
        u8(tagMap);
        u32(m.length);
        m.forEach((k, v) {
          if (k is! String) {
            throw ArgumentError.value(m, 'value', 'Map keys must be Strings');
          }
          str(k);
          value(v);
        });
      case Iterable it:
        final items = it.toList(growable: false);
        u8(tagList);
        u32(items.length);
        items.forEach(value);
      case LoroContainer():
        throw ArgumentError(
          'Containers cannot be inserted as values; use insertContainer/setContainer.',
        );
      default:
        throw ArgumentError.value(v, 'value', 'Unsupported Loro value type');
    }
  }
}

/// True when compiled to JavaScript, where `int` is an IEEE double.
const bool _jsNumbers = identical(0, 0.0);
const int _maxSafe = 9007199254740991;

/// Encodes a single value into a fresh buffer.
Uint8List encodeValue(Object? v) => (Writer()..value(v)).takeBytes();

/// Builds a buffer with a [Writer] callback.
Uint8List encodeWith(void Function(Writer w) f) {
  final w = Writer();
  f(w);
  return w.takeBytes();
}
