// Generates the Dart bindings for the Rust C ABI.
//
// Reads `native/include/loro_crdt_ffi.h` (produced by cbindgen) and writes:
//
// * `lib/src/ffi/bindings_native.g.dart` — `@Native` externals resolved
//   against the code asset built by `hook/build.dart`.
// * `lib/src/ffi/bindings_web.g.dart` — the same top-level functions,
//   implemented with `wasm_ffi` lookups into the Emscripten module.
//
// Both files expose an identical surface so the rest of the package is
// platform independent. Run from the package root:
//
//   dart run tool/generate_bindings.dart          # cbindgen + generate
//   dart run tool/generate_bindings.dart --check  # fail if outputs are stale
import 'dart:io';

const _header = 'native/include/loro_crdt_ffi.h';
const _nativeOut = 'lib/src/ffi/bindings_native.g.dart';
const _webOut = 'lib/src/ffi/bindings_web.g.dart';
const _exportsOut = 'native/exports.txt';
const _assetId = 'package:loro_crdt/src/ffi/bindings_native.g.dart';

void main(List<String> args) {
  final check = args.contains('--check');
  if (!args.contains('--no-cbindgen')) {
    final result = Process.runSync('cbindgen', [
      '--config',
      'cbindgen.toml',
      '--crate',
      'loro_crdt_ffi',
      '--output',
      'include/loro_crdt_ffi.h',
    ], workingDirectory: 'native');
    if (result.exitCode != 0) {
      stderr
        ..writeln('cbindgen failed:')
        ..writeln(result.stderr);
      exit(1);
    }
  }

  final functions = _parseHeader(File(_header).readAsStringSync());
  final outputs = {
    _nativeOut: _native(functions),
    _webOut: _web(functions),
    _exportsOut: _exports(functions),
  };
  _formatDartOutputs(outputs);

  var stale = false;
  for (final MapEntry(key: path, value: content) in outputs.entries) {
    final file = File(path);
    if (file.existsSync() && file.readAsStringSync() == content) continue;
    if (check) {
      stderr.writeln('$path is out of date');
      stale = true;
    } else {
      file.writeAsStringSync(content);
      stdout.writeln('wrote $path');
    }
  }
  if (stale) exit(1);
  stdout.writeln('${functions.length} functions');
}

/// Runs `dart format` over the generated Dart sources (pub.dev scores
/// formatting). Files are formatted in `.dart_tool/` inside this package so
/// the package's language version picks the formatter style.
void _formatDartOutputs(Map<String, String> outputs) {
  final dir = Directory('.dart_tool/loro_codegen')..createSync(recursive: true);
  final paths = <String, File>{};
  outputs.forEach((path, content) {
    if (!path.endsWith('.dart')) return;
    final f = File('${dir.path}/${path.split('/').last}')
      ..writeAsStringSync(content);
    paths[path] = f;
  });
  final result = Process.runSync('dart', [
    'format',
    ...paths.values.map((f) => f.path),
  ]);
  if (result.exitCode != 0) {
    stderr
      ..writeln('dart format failed:')
      ..writeln(result.stderr);
    exit(1);
  }
  paths.forEach((path, f) => outputs[path] = f.readAsStringSync());
}

class _Type {
  const _Type(this.native, this.dart);
  final String native;
  final String dart;
}

class _Param {
  const _Param(this.name, this.type);
  final String name;
  final _Type type;
}

class _Fn {
  const _Fn(this.name, this.ret, this.params, this.doc);
  final String name;
  final _Type ret;
  final List<_Param> params;
  final List<String> doc;

  String get nativeSig =>
      '${ret.native} Function(${params.map((p) => p.type.native).join(', ')})';
  String get dartSig =>
      '${ret.dart} Function(${params.map((p) => p.type.dart).join(', ')})';
  String get dartParams =>
      params.map((p) => '${p.type.dart} ${p.name}').join(', ');
  String get args => params.map((p) => p.name).join(', ');

  /// Destructors are `void x_free(T *)`; they get finalizer helpers.
  bool get isDestructor =>
      name.endsWith('_free') &&
      ret.native == 'Void' &&
      params.length == 1 &&
      params.single.type.native == 'Pointer<Void>';
}

final _fnPattern = RegExp(r'^(.+?)\b(loro_\w+)\((.*)\);$');

List<_Fn> _parseHeader(String header) {
  final fns = <_Fn>[];
  final doc = <String>[];
  var inComment = false;
  for (final raw in header.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('/**')) {
      inComment = true;
      doc.clear();
      continue;
    }
    if (inComment) {
      if (line.startsWith('*/')) {
        inComment = false;
      } else {
        doc.add(line.replaceFirst(RegExp(r'^\* ?'), ''));
      }
      continue;
    }
    final m = _fnPattern.firstMatch(line);
    if (m == null) {
      if (line.isNotEmpty) doc.clear();
      continue;
    }
    final name = m[2]!;
    final params = <_Param>[];
    final rawParams = m[3]!.trim();
    if (rawParams.isNotEmpty && rawParams != 'void') {
      for (final p in rawParams.split(',')) {
        final pm = RegExp(r'^(.*?)(\w+)$').firstMatch(p.trim())!;
        params.add(_Param(pm[2]!, _mapType(pm[1]!, '$name(${pm[2]})')));
      }
    }
    fns.add(_Fn(name, _mapType(m[1]!, name), params, List.of(doc)));
    doc.clear();
  }
  return fns;
}

/// Maps a C type to `(native type, dart type)`. Only types that both
/// `dart:ffi` and `wasm_ffi` marshal identically are accepted.
_Type _mapType(String c, String where) {
  final t = c
      .replaceAll('const ', '')
      .replaceAll('struct ', '')
      .replaceAll(' ', '');
  switch (t) {
    case 'void':
      return const _Type('Void', 'void');
    case 'int32_t':
      return const _Type('Int32', 'int');
    case 'uint32_t':
      return const _Type('Uint32', 'int');
    case 'uint8_t':
      return const _Type('Uint8', 'int');
    case 'double':
      return const _Type('Double', 'double');
    case 'uint8_t*':
      return const _Type('Pointer<Uint8>', 'Pointer<Uint8>');
    case 'ErrSlot':
    case 'uint8_t**':
      return const _Type('Pointer<Pointer<Uint8>>', 'Pointer<Pointer<Uint8>>');
  }
  if (RegExp(r'^Loro\w+Handle\*$').hasMatch(t)) {
    return const _Type('Pointer<Void>', 'Pointer<Void>');
  }
  throw FormatException('Unsupported C type "$c" in $where');
}

const _banner = '''
// GENERATED by tool/generate_bindings.dart from native/include/loro_crdt_ffi.h.
// Do not edit by hand.
// ignore_for_file: type=lint, unused_element
''';

String _docComment(_Fn f) => f.doc.isEmpty
    ? ''
    : '${f.doc.map((l) => '/// $l'.trimRight()).join('\n')}\n';

String _native(List<_Fn> fns) {
  final b = StringBuffer(_banner)
    ..writeln("@DefaultAsset('$_assetId')")
    ..writeln('library;')
    ..writeln()
    ..writeln("import 'dart:ffi';")
    ..writeln()
    ..writeln('/// Native code is bundled by the build hook; nothing to load.')
    ..writeln('Future<void> loadLibrary(String url) async {}')
    ..writeln()
    ..writeln('bool get isLoaded => true;')
    ..writeln()
    ..writeln(
      '/// Frees a native handle when its Dart owner is garbage collected.',
    )
    ..writeln('final class LoroFinalizer {')
    ..writeln('  LoroFinalizer._(this._finalizer);')
    ..writeln('  final NativeFinalizer _finalizer;')
    ..writeln(
      '  void attach(Finalizable value, Pointer<Void> ptr, {Object? detach}) =>',
    )
    ..writeln('      _finalizer.attach(value, ptr, detach: detach);')
    ..writeln('  void detach(Object detach) => _finalizer.detach(detach);')
    ..writeln('}')
    ..writeln();
  for (final f in fns) {
    b
      ..write(_docComment(f))
      ..writeln("@Native<${f.nativeSig}>(symbol: '${f.name}')")
      ..writeln('external ${f.ret.dart} ${f.name}(${f.dartParams});')
      ..writeln();
  }
  for (final f in fns.where((f) => f.isDestructor)) {
    b
      ..writeln('final ${f.name}_finalizer = LoroFinalizer._(')
      ..writeln(
        '  NativeFinalizer(Native.addressOf<NativeFunction<${f.nativeSig}>>(${f.name}).cast()),',
      )
      ..writeln(');')
      ..writeln();
  }
  return b.toString();
}

String _web(List<_Fn> fns) {
  final b = StringBuffer(_banner)
    ..writeln("import 'package:wasm_ffi/ffi.dart';")
    ..writeln()
    ..writeln('DynamicLibrary? _library;')
    ..writeln()
    ..writeln('DynamicLibrary get _lib =>')
    ..writeln('    _library ??')
    ..writeln('    (throw StateError(')
    ..writeln(
      "      'loro_crdt is not initialized. Call `await initLoro()` before using Loro on the web.',",
    )
    ..writeln('    ));')
    ..writeln()
    ..writeln('/// Loads the Emscripten module (`loro_crdt_ffi.js` + `.wasm`).')
    ..writeln('Future<void> loadLibrary(String url) async {')
    ..writeln('  _library ??= await DynamicLibrary.open(url);')
    ..writeln('}')
    ..writeln()
    ..writeln('bool get isLoaded => _library != null;')
    ..writeln()
    ..writeln(
      '/// Frees a native handle when its Dart owner is garbage collected.',
    )
    ..writeln('final class LoroFinalizer {')
    ..writeln(
      '  LoroFinalizer._(void Function(Pointer<Void>) free) : _finalizer = Finalizer(free);',
    )
    ..writeln('  final Finalizer<Pointer<Void>> _finalizer;')
    ..writeln(
      '  void attach(Finalizable value, Pointer<Void> ptr, {Object? detach}) =>',
    )
    ..writeln('      _finalizer.attach(value, ptr, detach: detach);')
    ..writeln('  void detach(Object detach) => _finalizer.detach(detach);')
    ..writeln('}')
    ..writeln();
  for (final f in fns) {
    b
      ..writeln(
        "late final _${f.name} = _lib.lookupFunction<${f.nativeSig}, ${f.dartSig}>('${f.name}');",
      )
      ..write(_docComment(f))
      ..writeln(
        '${f.ret.dart} ${f.name}(${f.dartParams}) => _${f.name}(${f.args});',
      )
      ..writeln();
  }
  for (final f in fns.where((f) => f.isDestructor)) {
    b
      ..writeln('final ${f.name}_finalizer = LoroFinalizer._(${f.name});')
      ..writeln();
  }
  return b.toString();
}

/// Symbol list for `emcc -sEXPORTED_FUNCTIONS=@native/exports.txt`.
String _exports(List<_Fn> fns) =>
    '${['_malloc', '_free', ...fns.map((f) => '_${f.name}')].join('\n')}\n';
