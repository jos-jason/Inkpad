import 'dart:math' as math;

import 'package:glyph_path/glyph_path.dart' as gp;

/// One run of text to lay out, already resolved to a face and size.
class LayoutRun {
  final String text;
  final gp.Font font;
  final double size;

  const LayoutRun(this.text, this.font, this.size);

  double get _scale => size / font.unitsPerEm;
  double get ascent => font.ascender * _scale;
  double get descent => -font.descender * _scale;
  double get gap => font.lineGap * _scale;
}

/// A glyph placed on a line: [x] from the line's start; [run] indexes the
/// input runs.
class LaidGlyph {
  final gp.GlyphPathResult glyph;
  final double x;
  final int run;

  const LaidGlyph(this.glyph, this.x, this.run);
}

class LaidLine {
  final List<LaidGlyph> glyphs;

  /// Width without trailing spaces (what alignment uses).
  final double width;

  /// Baseline below the first line's baseline.
  final double baseline;
  final double ascent, descent;

  const LaidLine(this.glyphs, this.width, this.baseline, this.ascent, this.descent);

  /// The line's text in stretches of one run each.
  List<({int run, String text})> get segments {
    final out = <({int run, String text})>[];
    for (final g in glyphs) {
      if (out.isNotEmpty && out.last.run == g.run) {
        out[out.length - 1] = (run: g.run, text: out.last.text + g.glyph.sourceText);
      } else {
        out.add((run: g.run, text: g.glyph.sourceText));
      }
    }
    return out;
  }
}

/// A piece of text shaped in one go: a word or a stretch of spaces, within
/// one run.
class _Atom {
  final List<gp.GlyphPathResult> glyphs;
  final double width;
  final int run;
  final bool space;

  _Atom(this.glyphs, this.width, this.run, this.space);
}

/// Lays out text in several fonts and sizes: wraps at [maxWidth] (if
/// given), breaking between words (or, for a word too long for a line,
/// between letters); each line is as tall as its tallest letters. With one
/// run this matches glyph_path's TextLayout (Inkpad's line spacing:
/// ascender + descender + line gap).
List<LaidLine> layoutRuns(List<LayoutRun> runs, {double? maxWidth}) {
  // Paragraphs of (text, run) pieces; a paragraph remembers its run for
  // the height of an empty line.
  final paragraphs = <({List<(String, int)> pieces, int run})>[];
  var current = <(String, int)>[];
  var currentRun = 0;
  for (final (i, r) in runs.indexed) {
    final parts = r.text.split('\n');
    for (final (j, part) in parts.indexed) {
      if (j > 0) {
        paragraphs.add((pieces: current, run: currentRun));
        current = [];
        currentRun = i;
      }
      if (part.isNotEmpty) {
        if (current.isEmpty) currentRun = i;
        current.add((part, i));
      }
    }
  }
  paragraphs.add((pieces: current, run: currentRun));

  final tokens = RegExp(r'\s+|\S+');
  _Atom shape(String text, int run) {
    final r = runs[run];
    final glyphs = r.font.generateGlyphPaths(text, fontSize: r.size.clamp(0.1, 10000)).glyphs;
    final width = glyphs.isEmpty ? 0.0 : glyphs.last.positionX + glyphs.last.advanceWidth;
    return _Atom(glyphs, width, run, text.trim().isEmpty);
  }

  final lines = <({List<_Atom> atoms, int run})>[];
  for (final p in paragraphs) {
    // Words (letters with no space between, possibly in several runs) and spaces.
    final items = <List<_Atom>>[];
    var lastWasWord = false;
    for (final (text, run) in p.pieces) {
      for (final m in tokens.allMatches(text)) {
        final a = shape(m.group(0)!, run);
        if (!a.space && lastWasWord) {
          items.last.add(a);
        } else {
          items.add([a]);
        }
        lastWasWord = !a.space;
      }
    }

    var line = <_Atom>[];
    var width = 0.0;
    var pending = <_Atom>[];
    void newLine() {
      lines.add((atoms: line, run: line.isEmpty ? p.run : line.first.run));
      line = [];
      width = 0;
      pending = [];
    }

    double sum(List<_Atom> atoms) => atoms.fold(0.0, (s, a) => s + a.width);

    for (final item in items) {
      if (item.first.space) {
        if (line.isEmpty) {
          line.addAll(item);
          width += sum(item);
        } else {
          pending.addAll(item);
        }
        continue;
      }
      final w = sum(item);
      final limit = maxWidth;
      if (limit == null || width + sum(pending) + w <= limit + 1e-6) {
        line.addAll(pending);
        width += sum(pending);
        pending = [];
        line.addAll(item);
        width += w;
        continue;
      }
      if (line.isNotEmpty) newLine();
      if (w <= limit + 1e-6) {
        line.addAll(item);
        width += w;
        continue;
      }
      // Too long for any line: break between letters.
      for (final a in item) {
        for (final g in a.glyphs) {
          final gw = g.advanceWidth;
          if (line.isNotEmpty && width + gw > limit + 1e-6) newLine();
          final shifted = gp.GlyphPathResult(
            contours: g.contours,
            positionX: 0,
            advanceWidth: g.advanceWidth,
            bounds: g.bounds,
            sourceText: g.sourceText,
          );
          line.add(_Atom([shifted], gw, a.run, false));
          width += gw;
        }
      }
    }
    line.addAll(pending);
    lines.add((atoms: line, run: line.isEmpty ? p.run : line.first.run));
  }

  // Place glyphs and stack the lines.
  final out = <LaidLine>[];
  double? prevBaseline;
  var prevDescent = 0.0, prevGap = 0.0;
  for (final l in lines) {
    final used = l.atoms.isEmpty ? [runs[l.run]] : {for (final a in l.atoms) a.run}.map((i) => runs[i]).toList();
    final ascent = used.map((r) => r.ascent).reduce(math.max);
    final descent = used.map((r) => r.descent).reduce(math.max);
    final gap = used.map((r) => r.gap).reduce(math.max);
    final baseline = prevBaseline == null ? 0.0 : prevBaseline + prevDescent + prevGap + ascent;
    final glyphs = <LaidGlyph>[];
    var x = 0.0, contentWidth = 0.0;
    for (final a in l.atoms) {
      for (final g in a.glyphs) {
        glyphs.add(LaidGlyph(g, x + g.positionX, a.run));
      }
      x += a.width;
      if (!a.space) contentWidth = x;
    }
    out.add(LaidLine(glyphs, contentWidth, baseline, ascent, descent));
    prevBaseline = baseline;
    prevDescent = descent;
    prevGap = gap;
  }
  return out;
}
