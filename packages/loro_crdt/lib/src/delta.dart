/// One step of a rich-text delta, in the same shape as a
/// [Quill delta](https://quilljs.com/docs/delta/). Lengths are UTF-16 code
/// units.
sealed class TextDelta {
  const TextDelta();

  /// Parses the Quill-style JSON form produced by [toJson].
  factory TextDelta.fromJson(Map<String, Object?> json) {
    final attrs = (json['attributes'] as Map?)?.cast<String, Object?>();
    if (json.containsKey('insert')) {
      return TextInsert(json['insert']! as String, attributes: attrs);
    }
    if (json.containsKey('delete')) return TextDelete(json['delete']! as int);
    if (json.containsKey('retain')) {
      return TextRetain(json['retain']! as int, attributes: attrs);
    }
    throw FormatException('Not a text delta: $json');
  }

  Map<String, Object?> toJson();
}

/// Inserts [text] with optional style [attributes].
final class TextInsert extends TextDelta {
  const TextInsert(this.text, {this.attributes});

  final String text;
  final Map<String, Object?>? attributes;

  @override
  Map<String, Object?> toJson() => {
    'insert': text,
    if (attributes != null) 'attributes': attributes,
  };

  @override
  bool operator ==(Object other) =>
      other is TextInsert &&
      other.text == text &&
      deepEquals(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(text, deepHash(attributes));

  @override
  String toString() => 'TextInsert(${toJson()})';
}

/// Deletes [count] code units.
final class TextDelete extends TextDelta {
  const TextDelete(this.count);

  final int count;

  @override
  Map<String, Object?> toJson() => {'delete': count};

  @override
  bool operator ==(Object other) => other is TextDelete && other.count == count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'TextDelete($count)';
}

/// Keeps [count] code units, optionally changing their style [attributes]
/// (a `null` attribute value removes that style).
final class TextRetain extends TextDelta {
  const TextRetain(this.count, {this.attributes});

  final int count;
  final Map<String, Object?>? attributes;

  @override
  Map<String, Object?> toJson() => {
    'retain': count,
    if (attributes != null) 'attributes': attributes,
  };

  @override
  bool operator ==(Object other) =>
      other is TextRetain &&
      other.count == count &&
      deepEquals(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(count, deepHash(attributes));

  @override
  String toString() => 'TextRetain(${toJson()})';
}

/// One step of a list diff.
sealed class ListDelta {
  const ListDelta();
}

/// Inserts [values]: plain values or `LoroContainer`s. [isMove] is set when
/// the values were moved here within a `LoroMovableList`.
final class ListInsert extends ListDelta {
  const ListInsert(this.values, {this.isMove = false});

  final List<Object?> values;
  final bool isMove;

  @override
  bool operator ==(Object other) =>
      other is ListInsert &&
      other.isMove == isMove &&
      deepEquals(other.values, values);

  @override
  int get hashCode => Object.hash(isMove, deepHash(values));

  @override
  String toString() => 'ListInsert($values${isMove ? ', move' : ''})';
}

/// Deletes [count] elements.
final class ListDelete extends ListDelta {
  const ListDelete(this.count);

  final int count;

  @override
  bool operator ==(Object other) => other is ListDelete && other.count == count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'ListDelete($count)';
}

/// Skips [count] unchanged elements.
final class ListRetain extends ListDelta {
  const ListRetain(this.count);

  final int count;

  @override
  bool operator ==(Object other) => other is ListRetain && other.count == count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'ListRetain($count)';
}

/// Structural equality for decoded Loro values.
bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int deepHash(Object? v) => switch (v) {
  Map m => Object.hashAllUnordered(
    m.entries.map((e) => Object.hash(e.key, deepHash(e.value))),
  ),
  List l => Object.hashAll(l.map(deepHash)),
  _ => v.hashCode,
};
