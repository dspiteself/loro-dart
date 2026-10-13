import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:loro_crdt/loro_crdt.dart';

/// A [TextEditingController] kept in sync with an attached [LoroText].
///
/// Local edits (typing, pasting, `text =`) are written to the [LoroText] as a
/// minimal splice and committed with [commitOrigin]. Committed changes that
/// arrive from elsewhere (imports from other peers, undo/redo, other code
/// editing the same text) update the field, and the selection and composing
/// range are moved through the change so the caret stays where the user left
/// it. A caret sitting exactly where remote text is inserted stays in front of
/// that text.
///
/// The field always mirrors the committed document. Commits apply to the whole
/// [LoroDoc], so creating the controller and every local edit also commit
/// other pending edits in the document; code that edits the same [LoroText]
/// directly should commit its edits too.
///
/// Pass [attributeStyle] to render Loro rich-text marks (see
/// [LoroText.mark]) inside the field.
class LoroTextEditingController extends TextEditingController {
  LoroTextEditingController(
    this.loroText, {
    this.commitOrigin = defaultCommitOrigin,
    this.attributeStyle,
  }) : _doc = _committedDoc(loroText),
       super(text: loroText.toString()) {
    _subscription = loroText.subscribe(_onLoroEvent);
  }

  /// The field starts from the current content, so pending edits must be
  /// committed now: committed later, their event would apply them again.
  static LoroDoc _committedDoc(LoroText text) {
    final doc =
        text.doc ??
        (throw ArgumentError.value(
          text,
          'loroText',
          'must be attached to a LoroDoc',
        ));
    doc.commit();
    return doc;
  }

  /// The origin used for commits made by controllers.
  static const defaultCommitOrigin = 'loro_crdt_flutter';

  final LoroText loroText;

  /// The origin passed to [LoroDoc.commit] for local edits. Exclude it from
  /// an `UndoManager` with `excludeOriginPrefixes` if field edits should not
  /// be undoable.
  final String commitOrigin;

  /// Maps Loro text attributes (e.g. `{'bold': true}`) to a [TextStyle].
  final TextStyle? Function(Map<String, Object?> attributes)? attributeStyle;

  final LoroDoc _doc;
  late final ContainerId _id = loroText.id;
  late final LoroSubscription _subscription;
  bool _writing = false;
  bool _applyingRemote = false;

  @override
  set value(TextEditingValue newValue) {
    final old = super.value.text;
    if (_applyingRemote || newValue.text == old) {
      super.value = newValue;
      return;
    }
    try {
      // Edits made elsewhere but not committed yet would make the splice
      // below miss them. Committing delivers them to the field first.
      _doc.commit();
      if (super.value.text != old) {
        // The field changed under this edit; the document's version wins.
        return;
      }
      final edit = TextSplice.between(old, newValue.text);
      _writing = true;
      if (edit.deleteCount > 0) loroText.delete(edit.start, edit.deleteCount);
      if (edit.insert.isNotEmpty) loroText.insert(edit.start, edit.insert);
      _doc.commit(origin: commitOrigin);
    } on LoroException {
      // The document rejected the edit (e.g. it is checked out at an old
      // version): show what Loro has instead.
      _writing = false;
      _resync();
      return;
    } finally {
      _writing = false;
    }
    super.value = newValue;
  }

  void _onLoroEvent(LoroEventBatch batch) {
    if (_writing) return;
    for (final event in batch.events) {
      final diff = event.diff;
      if (event.target != _id || diff is! TextDiff) continue;
      final next = applyTextDelta(super.value, diff.delta);
      if (next == null) {
        _resync();
        return;
      }
      _setRemote(next);
    }
  }

  void _resync() {
    final text = loroText.toString();
    final sel = super.value.selection;
    _setRemote(
      TextEditingValue(
        text: text,
        selection: sel.isValid
            ? TextSelection(
                baseOffset: math.min(sel.baseOffset, text.length),
                extentOffset: math.min(sel.extentOffset, text.length),
              )
            : const TextSelection.collapsed(offset: -1),
      ),
    );
  }

  void _setRemote(TextEditingValue v) {
    _applyingRemote = true;
    try {
      super.value = v;
    } finally {
      _applyingRemote = false;
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final styleFor = attributeStyle;
    if (styleFor == null || (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final spans = <TextSpan>[];
    var length = 0;
    for (final d in loroText.toDelta()) {
      if (d is! TextInsert) continue;
      length += d.text.length;
      final attrs = d.attributes;
      spans.add(
        TextSpan(text: d.text, style: attrs == null ? null : styleFor(attrs)),
      );
    }
    if (length != value.text.length) {
      // Not in sync with the document (e.g. uncommitted external edits).
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(style: style, children: spans);
  }

  @override
  void dispose() {
    _subscription.unsubscribe();
    super.dispose();
  }
}

/// A single replacement turning one string into another.
@immutable
class TextSplice {
  const TextSplice(this.start, this.deleteCount, this.insert);

  /// The smallest splice turning [from] into [to] (common prefix and suffix
  /// removed). It never splits a UTF-16 surrogate pair, which Loro would
  /// reject.
  factory TextSplice.between(String from, String to) {
    final minLen = math.min(from.length, to.length);
    var start = 0;
    while (start < minLen && from.codeUnitAt(start) == to.codeUnitAt(start)) {
      start++;
    }
    if (start > 0 && _isHighSurrogate(from.codeUnitAt(start - 1))) start--;
    var endFrom = from.length;
    var endTo = to.length;
    while (endFrom > start &&
        endTo > start &&
        from.codeUnitAt(endFrom - 1) == to.codeUnitAt(endTo - 1)) {
      endFrom--;
      endTo--;
    }
    if (endFrom < from.length && _isLowSurrogate(from.codeUnitAt(endFrom))) {
      endFrom++;
      endTo++;
    }
    return TextSplice(start, endFrom - start, to.substring(start, endTo));
  }

  final int start;
  final int deleteCount;
  final String insert;

  @override
  bool operator ==(Object other) =>
      other is TextSplice &&
      other.start == start &&
      other.deleteCount == deleteCount &&
      other.insert == insert;

  @override
  int get hashCode => Object.hash(start, deleteCount, insert);

  @override
  String toString() => 'TextSplice($start, -$deleteCount, +"$insert")';
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Applies a Loro text [delta] to [value], moving the selection and
/// composing range through it. Returns `null` if the delta does not fit the
/// text.
TextEditingValue? applyTextDelta(
  TextEditingValue value,
  List<TextDelta> delta,
) {
  final old = value.text;
  final out = StringBuffer();
  var i = 0;
  for (final d in delta) {
    switch (d) {
      case TextRetain(:final count):
        if (i + count > old.length) return null;
        out.write(old.substring(i, i + count));
        i += count;
      case TextInsert(:final text):
        out.write(text);
      case TextDelete(:final count):
        if (i + count > old.length) return null;
        i += count;
    }
  }
  out.write(old.substring(i));

  int move(int offset) => offset < 0 ? offset : transformOffset(offset, delta);

  final sel = value.selection;
  final composing = value.composing;
  final newComposing = composing.isValid && !composing.isCollapsed
      ? TextRange(start: move(composing.start), end: move(composing.end))
      : TextRange.empty;
  return TextEditingValue(
    text: out.toString(),
    selection: sel.copyWith(
      baseOffset: move(sel.baseOffset),
      extentOffset: move(sel.extentOffset),
    ),
    composing: newComposing.isCollapsed ? TextRange.empty : newComposing,
  );
}

/// Where [offset] in the old text ends up after [delta]. Offsets inside
/// deleted text move to the deletion point; text inserted exactly at
/// [offset] ends up after it.
int transformOffset(int offset, List<TextDelta> delta) {
  var oldPos = 0;
  var newPos = 0;
  for (final d in delta) {
    switch (d) {
      case TextRetain(:final count):
        if (offset < oldPos + count) return newPos + (offset - oldPos);
        oldPos += count;
        newPos += count;
      case TextInsert(:final text):
        if (offset == oldPos) return newPos;
        newPos += text.length;
      case TextDelete(:final count):
        if (offset < oldPos + count) return newPos;
        oldPos += count;
    }
  }
  return newPos + (offset - oldPos);
}
