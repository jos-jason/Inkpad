import 'style.dart';

/// Per-letter styling: what a stretch of text changes from its text
/// object's own font, style, size and fill. Null means "as the text object".
class TextRunStyle {
  final String? fontFamily;
  final String? fontStyle;
  final double? fontSize;
  final InkPaint? fill;

  const TextRunStyle({this.fontFamily, this.fontStyle, this.fontSize, this.fill});

  static const plain = TextRunStyle();

  bool get isPlain => fontFamily == null && fontStyle == null && fontSize == null && fill == null;

  /// [other]'s settings over these.
  TextRunStyle merge(TextRunStyle other) => TextRunStyle(
        fontFamily: other.fontFamily ?? fontFamily,
        fontStyle: other.fontStyle ?? fontStyle,
        fontSize: other.fontSize ?? fontSize,
        fill: other.fill ?? fill,
      );

  /// These settings without the ones named (back to the text object's).
  TextRunStyle without({bool family = false, bool style = false, bool size = false, bool fill = false}) => TextRunStyle(
        fontFamily: family ? null : fontFamily,
        fontStyle: style ? null : fontStyle,
        fontSize: size ? null : fontSize,
        fill: fill ? null : this.fill,
      );

  Map<String, dynamic> toJson() => {
        if (fontFamily != null) 'font': fontFamily,
        if (fontStyle != null) 'fontStyle': fontStyle,
        if (fontSize != null) 'size': fontSize,
        if (fill != null) 'fill': fill!.toJson(),
      };

  factory TextRunStyle.fromJson(Map<String, dynamic> j) => TextRunStyle(
        fontFamily: j['font'] as String?,
        fontStyle: j['fontStyle'] as String?,
        fontSize: (j['size'] as num?)?.toDouble(),
        fill: j['fill'] == null ? null : InkPaint.fromJson(j['fill']),
      );

  @override
  bool operator ==(Object other) =>
      other is TextRunStyle &&
      other.fontFamily == fontFamily &&
      other.fontStyle == fontStyle &&
      other.fontSize == fontSize &&
      other.fill == fill;

  @override
  int get hashCode => Object.hash(fontFamily, fontStyle, fontSize, fill);
}

/// A stretch of text in one style.
class TextRun {
  final String text;
  final TextRunStyle style;

  const TextRun(this.text, [this.style = TextRunStyle.plain]);

  Map<String, dynamic> toJson() => {'text': text, ...style.toJson()};

  factory TextRun.fromJson(Map<String, dynamic> j) => TextRun(j['text'] as String, TextRunStyle.fromJson(j));

  @override
  bool operator ==(Object other) => other is TextRun && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);
}

/// Editing styled text (immutable: each returns new runs).
extension TextRuns on List<TextRun> {
  String get plainText => map((r) => r.text).join();

  bool get isStyled => any((r) => !r.style.isPlain);

  /// Adjacent runs in the same style joined, empty runs dropped (keeping one).
  List<TextRun> normalized() {
    final out = <TextRun>[];
    for (final r in this) {
      if (r.text.isEmpty) continue;
      if (out.isNotEmpty && out.last.style == r.style) {
        out[out.length - 1] = TextRun(out.last.text + r.text, r.style);
      } else {
        out.add(r);
      }
    }
    if (out.isEmpty) return [TextRun('', isEmpty ? TextRunStyle.plain : first.style)];
    return out;
  }

  /// The style of the letter at [index] (or just before it, at the end).
  TextRunStyle styleAt(int index) {
    var pos = 0;
    for (final r in this) {
      if (index < pos + r.text.length) return r.style;
      pos += r.text.length;
    }
    return isEmpty ? TextRunStyle.plain : last.style;
  }

  /// Splits so a run boundary falls at [index].
  List<TextRun> _splitAt(int index) {
    final out = <TextRun>[];
    var pos = 0;
    for (final r in this) {
      final end = pos + r.text.length;
      if (index > pos && index < end) {
        out.add(TextRun(r.text.substring(0, index - pos), r.style));
        out.add(TextRun(r.text.substring(index - pos), r.style));
      } else {
        out.add(r);
      }
      pos = end;
    }
    return out;
  }

  /// Restyles letters [start]..[end] with [change].
  List<TextRun> restyle(int start, int end, TextRunStyle Function(TextRunStyle) change) {
    final split = _splitAt(start)._splitAt(end);
    final out = <TextRun>[];
    var pos = 0;
    for (final r in split) {
      final inside = pos >= start && pos + r.text.length <= end && r.text.isNotEmpty;
      out.add(inside ? TextRun(r.text, change(r.style)) : r);
      pos += r.text.length;
    }
    return out.normalized();
  }

  /// Every run restyled with [change] (e.g. clearing an override).
  List<TextRun> restyleAll(TextRunStyle Function(TextRunStyle) change) =>
      [for (final r in this) TextRun(r.text, change(r.style))].normalized();

  /// The runs after the text is edited to [value]: the changed stretch is
  /// found by comparing the start and end, and typed letters take the style
  /// of the letter before them (as in word processors).
  List<TextRun> edited(String value) {
    final old = plainText;
    if (old == value) return this;
    var prefix = 0;
    final maxPrefix = old.length < value.length ? old.length : value.length;
    while (prefix < maxPrefix && old.codeUnitAt(prefix) == value.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < old.length - prefix &&
        suffix < value.length - prefix &&
        old.codeUnitAt(old.length - 1 - suffix) == value.codeUnitAt(value.length - 1 - suffix)) {
      suffix++;
    }
    final removedEnd = old.length - suffix;
    final inserted = value.substring(prefix, value.length - suffix);
    final style = prefix > 0 ? styleAt(prefix - 1) : styleAt(0);
    final split = _splitAt(prefix)._splitAt(removedEnd);
    final out = <TextRun>[];
    var pos = 0;
    var placed = false;
    for (final r in split) {
      final end = pos + r.text.length;
      if (!placed && pos >= prefix) {
        out.add(TextRun(inserted, style));
        placed = true;
      }
      if (pos >= prefix && end <= removedEnd && r.text.isNotEmpty) {
        // Deleted.
      } else {
        out.add(r);
      }
      pos = end;
    }
    if (!placed) out.add(TextRun(inserted, style));
    return out.normalized();
  }
}
