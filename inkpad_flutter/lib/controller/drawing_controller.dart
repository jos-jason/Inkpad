import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../geometry/pathfinder.dart';
import '../model/bezier_node.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import '../text/font_library.dart';
import '../tools/tool.dart';
import 'snapping.dart';

export 'snapping.dart';

/// Ported from WDAlignment.
enum AlignEdge { left, center, right, top, middle, bottom }

/// Owns the document, selection, undo history and the active tool.
/// Plays the role of Inkpad's WDDrawingController + WDPropertyManager.
class DrawingController extends ChangeNotifier {
  InkDrawing drawing;

  final Set<InkElement> selection = {};

  /// Path currently being built by the pen tool, if any.
  InkPath? activePath;

  /// Style applied to newly created shapes.
  /// A color or gradient. Gradients here never carry geometry, so they fit
  /// whatever shape they're applied to.
  InkPaint? fillPaint = const InkColor(0.35, 0.6, 0.95);
  StrokeStyle? strokeStyle = const StrokeStyle(width: 2);

  Tool _tool;

  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  static const _maxUndo = 100;

  DrawingController({InkDrawing? drawing})
      : drawing = drawing ?? InkDrawing(),
        _tool = SelectionTool();

  Tool get tool => _tool;

  set tool(Tool t) {
    finishActivePath();
    endEditing();
    if (t is! DirectSelectTool) selectedNodes.clear();
    _tool = t;
    notifyListeners();
  }

  /// Where the point being dragged snapped to, shown on the canvas.
  SnapResult? snapFeedback;

  /// Notify listeners that the document or selection changed.
  void changed() => notifyListeners();

  // ---- Undo -------------------------------------------------------------

  /// Records the current document state so the next change can be undone.
  /// Call before mutating the drawing.
  void checkpoint() {
    _undoStack.add(drawing.encode(includeImages: false));
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void undo() {
    if (!canUndo) return;
    _redoStack.add(drawing.encode(includeImages: false));
    _restore(_undoStack.removeLast());
  }

  void redo() {
    if (!canRedo) return;
    _undoStack.add(drawing.encode(includeImages: false));
    _restore(_redoStack.removeLast());
  }

  void _restore(String snapshot) {
    editingText = null;
    editingRange = null;
    drawing = InkDrawing.decode(snapshot);
    selection.clear();
    selectedNodes.clear();
    activePath = null;
    notifyListeners();
  }

  // ---- Elements ---------------------------------------------------------

  InkPath styledPath(InkPath p) => p
    ..fill = fillPaint
    ..stroke = strokeStyle
    ..opacity = defaultOpacity
    ..shadow = defaultShadow
    ..blendMode = defaultBlendMode;

  void addElement(InkElement e) {
    drawing.activeLayer.elements.add(e);
    notifyListeners();
  }

  InkLayer? layerOf(InkElement e) {
    for (final l in drawing.layers) {
      if (l.elements.contains(e)) return l;
    }
    return null;
  }

  /// Topmost editable element under [pt].
  InkElement? elementAt(Offset pt, double tolerance) {
    for (final layer in drawing.layers.reversed) {
      if (!layer.editable) continue;
      for (final e in layer.elements.reversed) {
        if (e.hitTest(pt, tolerance)) return e;
      }
    }
    return null;
  }

  Iterable<InkElement> elementsInRect(Rect r) sync* {
    for (final layer in drawing.layers) {
      if (!layer.editable) continue;
      yield* layer.elements.where((e) => e.intersectsRect(r));
    }
  }

  // ---- Selection --------------------------------------------------------

  /// A stroke to reuse on other shapes: its gradient (if any) fits each
  /// shape, as fills do.
  static StrokeStyle? _unplaced(StrokeStyle? s) {
    final g = s?.gradient;
    return g == null ? s : s!.copyWith(gradient: g.copyWith(clearGeometry: true));
  }

  void select(InkElement e, {bool extend = false}) {
    if (!identical(e, editingText)) endEditing();
    if (!extend) selection.clear();
    selectedNodes.clear();
    selection.add(e);
    // Like Inkpad's property manager, the inspector picks up the style of
    // what you select, so new shapes continue in that style.
    if (!extend && e is InkStylable) {
      adoptTextStyle(e);
      final f = e.fill;
      fillPaint = f is InkGradient ? f.copyWith(clearGeometry: true) : f;
      strokeStyle = _unplaced(e.stroke);
    }
    notifyListeners();
  }

  void selectNone() {
    endEditing();
    if (selection.isEmpty) return;
    selection.clear();
    notifyListeners();
  }

  /// Everything in every visible, unlocked layer.
  void selectAll() {
    selection
      ..clear()
      ..addAll([for (final l in drawing.layers) if (l.editable) ...l.elements]);
    notifyListeners();
  }

  void selectAllInLayer() {
    selection
      ..clear()
      ..addAll(drawing.activeLayer.editable ? drawing.activeLayer.elements : const []);
    notifyListeners();
  }

  Rect? get selectionBounds {
    Rect? r;
    for (final e in selection) {
      r = unionRects(r, e.bounds);
    }
    return r;
  }

  /// The single selected path, when exactly one path is selected.
  InkPath? get singleSelectedPath =>
      selection.length == 1 && selection.first is InkPath ? selection.first as InkPath : null;

  /// The single selected shape (path or compound path).
  InkStylable? get singleSelectedStylable =>
      selection.length == 1 && selection.first is InkStylable ? selection.first as InkStylable : null;

  void transformSelection(Affine t) {
    for (final e in selection) {
      e.transform(t);
    }
    notifyListeners();
  }

  void deleteSelection() {
    // With points selected (direct select), Delete removes the points.
    if (selectedNodes.isNotEmpty) {
      deleteSelectedAnchors();
      return;
    }
    if (selection.isEmpty) return;
    checkpoint();
    for (final l in drawing.layers) {
      l.elements.removeWhere(selection.contains);
    }
    selection.clear();
    notifyListeners();
  }

  // ---- Clipboard (ported from WDDrawingController copy:/paste:) ----------

  List<Map<String, dynamic>> _clipboard = [];

  bool get canPaste => _clipboard.isNotEmpty;

  void copySelection() {
    if (selection.isEmpty) return;
    _clipboard = [for (final e in orderedSelection) e.toJson()];
    notifyListeners();
  }

  void cutSelection() {
    copySelection();
    deleteSelection();
  }

  /// Pastes in place into the active layer and selects the result.
  void paste() {
    if (_clipboard.isEmpty) return;
    checkpoint();
    final pasted = [for (final j in _clipboard) InkElement.fromJson(j)];
    drawing.activeLayer.elements.addAll(pasted);
    selection
      ..clear()
      ..addAll(pasted);
    notifyListeners();
  }

  /// Copies of the selection exactly on top of the originals.
  void duplicateInPlace() => _duplicate(Affine.identity);

  void duplicateSelection() => _duplicate(Affine.translation(10, 10));

  void _duplicate(Affine offset) {
    if (selection.isEmpty) return;
    checkpoint();
    final copies = <InkElement>[];
    for (final e in orderedSelection) {
      final c = e.clone()..transform(offset);
      (layerOf(e) ?? drawing.activeLayer).elements.add(c);
      copies.add(c);
    }
    selection
      ..clear()
      ..addAll(copies);
    notifyListeners();
  }

  void groupSelection() {
    if (selection.length < 2) return;
    checkpoint();
    final layer = drawing.activeLayer;
    // Preserve stacking order.
    final ordered = drawing.layers
        .expand((l) => l.elements)
        .where(selection.contains)
        .toList();
    for (final l in drawing.layers) {
      l.elements.removeWhere(selection.contains);
    }
    final g = InkGroup(ordered);
    layer.elements.add(g);
    selection
      ..clear()
      ..add(g);
    notifyListeners();
  }

  void ungroupSelection() {
    final groups = selection.whereType<InkGroup>().toList();
    if (groups.isEmpty) return;
    checkpoint();
    for (final g in groups) {
      final layer = layerOf(g)!;
      final i = layer.elements.indexOf(g);
      layer.elements
        ..removeAt(i)
        ..insertAll(i, g.elements);
      selection
        ..remove(g)
        ..addAll(g.elements);
    }
    notifyListeners();
  }

  /// Moves each selected element up past the next unselected one.
  /// Ported from -[WDLayer bringForward:].
  void bringForward() => _step(up: true);

  /// Ported from -[WDLayer sendBackward:].
  void sendBackward() => _step(up: false);

  void _step({required bool up}) {
    if (selection.isEmpty) return;
    checkpoint();
    for (final l in drawing.layers) {
      final els = l.elements;
      final indices = [for (var i = 0; i < els.length; i++) if (selection.contains(els[i])) i];
      for (final i in up ? indices.reversed : indices) {
        final j = up ? i + 1 : i - 1;
        if (j < 0 || j >= els.length || selection.contains(els[j])) continue;
        final e = els[i];
        els[i] = els[j];
        els[j] = e;
      }
    }
    notifyListeners();
  }

  void bringToFront() => _reorder(toFront: true);
  void sendToBack() => _reorder(toFront: false);

  void _reorder({required bool toFront}) {
    if (selection.isEmpty) return;
    checkpoint();
    for (final l in drawing.layers) {
      final moving = l.elements.where(selection.contains).toList();
      if (moving.isEmpty) continue;
      l.elements.removeWhere(selection.contains);
      toFront ? l.elements.addAll(moving) : l.elements.insertAll(0, moving);
    }
    notifyListeners();
  }

  /// Applies the current fill/stroke to the selection (like the style inspector).
  /// Pass record: false while a slider is moving (call [checkpoint] once
  /// when it starts), so a drag is one undo step.
  void applyStyleToSelection({bool fill = false, bool stroke = false, bool record = true}) {
    if (selection.isEmpty) return;
    if (record) checkpoint();
    // Letters selected while typing: color just those.
    final t = editingText, range = editingRange;
    if (fill && t is InkText && range != null && !range.isCollapsed) {
      t.runs = t.runs.restyle(range.start, range.end, (st) => _simplified(t, TextRunStyle(fill: fillPaint), st));
      notifyListeners();
      return;
    }
    void apply(InkElement e) {
      if (e is InkStylable) {
        if (fill) e.fill = _fillFor(e.fill, fillPaint);
        // The whole text in one color again.
        if (fill && e is InkText) e.runs = e.runs.restyleAll((st) => st.without(fill: true));
        if (stroke) e.stroke = strokeStyle;
      } else if (e is InkGroup) {
        e.elements.forEach(apply);
      }
    }
    selection.forEach(apply);
    notifyListeners();
  }

  /// A gradient applied over an existing gradient keeps that shape's
  /// gradient position; otherwise it fits the shape.
  static InkPaint? _fillFor(InkPaint? old, InkPaint? paint) {
    if (paint is InkGradient && old is InkGradient && old.geometry != null) {
      return paint.copyWith(geometry: old.geometry);
    }
    return paint;
  }

  // ---- Point selection (direct select) -----------------------------------

  /// Selected anchor points, by path and node index. Any change to a path's
  /// structure clears this, since indices would no longer match.
  final Map<InkPath, Set<int>> selectedNodes = {};

  /// Every editable path (inside groups, compound paths and masks too),
  /// mapped to the top-level element that contains it. Bottom first.
  Map<InkPath, InkElement> pathOwners() {
    final owners = <InkPath, InkElement>{};
    void walk(InkElement e, InkElement owner) {
      switch (e) {
        case InkCompoundPath():
          for (final p in e.subpaths) {
            owners[p] = owner;
          }
        case InkPath():
          owners[e] = owner;
        case InkGroup():
          for (final c in e.elements) {
            walk(c, owner);
          }
        default:
          break;
      }
      if (e is InkStylable) {
        for (final m in e.maskedElements) {
          walk(m, owner);
        }
      }
    }

    for (final l in drawing.layers) {
      if (!l.editable) continue;
      for (final e in l.elements) {
        walk(e, e);
      }
    }
    return owners;
  }

  /// Replaces the point selection; the containing elements become the
  /// selection, so the style panels apply to them.
  void setSelectedNodes(Map<InkPath, Set<int>> nodes) {
    selectedNodes
      ..clear()
      ..addAll({for (final e in nodes.entries) if (e.value.isNotEmpty) e.key: {...e.value}});
    final owners = pathOwners();
    selection
      ..clear()
      ..addAll([for (final p in selectedNodes.keys) if (owners[p] != null) owners[p]!]);
    notifyListeners();
  }

  bool get canDeleteAnchors => selectedNodes.isNotEmpty;

  /// Ported from -[WDPath deleteAnchors]. A path left with fewer than two
  /// points is removed altogether.
  void deleteSelectedAnchors() {
    if (selectedNodes.isEmpty) return;
    checkpoint();
    for (final MapEntry(key: path, value: indices) in selectedNodes.entries) {
      if (path.nodes.length - indices.length >= 2) {
        for (final i in indices.toList()..sort((a, b) => b - a)) {
          path.nodes.removeAt(i);
        }
      } else {
        _removePath(path);
      }
    }
    selectedNodes.clear();
    notifyListeners();
  }

  /// Removes [path] from wherever it lives (layer, group, compound path, mask).
  void _removePath(InkPath path) {
    bool removeFrom(List<InkElement> list) {
      if (list.remove(path)) return true;
      for (final e in list) {
        if (e is InkCompoundPath && e.subpaths.remove(path)) {
          if (e.subpaths.isEmpty) list.remove(e);
          return true;
        }
        if (e is InkGroup && removeFrom(e.elements)) return true;
        if (e is InkStylable && removeFrom(e.maskedElements)) return true;
      }
      return false;
    }

    for (final l in drawing.layers) {
      if (removeFrom(l.elements)) break;
    }
    selection.remove(path);
  }

  /// The list that holds [e] (a layer's, a group's, a mask's or a compound
  /// path's subpaths), or null.
  List<InkElement>? containerOf(InkElement e) {
    List<InkElement>? search(List<InkElement> list) {
      if (list.contains(e)) return list;
      for (final x in list) {
        if (x is InkCompoundPath && x.subpaths.contains(e)) return x.subpaths;
        final inner = switch (x) {
          InkGroup() => search(x.elements),
          _ => null,
        };
        if (inner != null) return inner;
        if (x is InkStylable) {
          final masked = search(x.maskedElements);
          if (masked != null) return masked;
        }
      }
      return null;
    }

    for (final l in drawing.layers) {
      final found = search(l.elements);
      if (found != null) return found;
    }
    return null;
  }

  // ---- Scissors (ported from WDScissorTool / -[WDPath splitAtNode:]) -----

  /// Cuts [path] at node [index]. An open path becomes two paths (it can't
  /// be cut at its ends); a closed path opens up at that point. Returns the
  /// path holding the second half, or null if nothing was cut.
  InkPath? splitPath(InkPath path, int index) {
    final n = path.nodes.length;
    if (!path.closed && (index <= 0 || index >= n - 1)) return null;
    final container = containerOf(path);
    if (container == null) return null;
    checkpoint();
    final node = path.nodes[index];
    InkPath result;
    if (path.closed) {
      path
        ..nodes = [...path.nodes.sublist(index), ...path.nodes.sublist(0, index), node]
        ..closed = false;
      result = path;
    } else {
      final sibling = InkPath(
        nodes: path.nodes.sublist(index),
        fill: path.fill,
        stroke: path.stroke,
        fillRule: path.fillRule,
      )..copyEffects(path);
      path.nodes = path.nodes.sublist(0, index + 1);
      container.insert(container.indexOf(path) + 1, sibling);
      result = sibling;
    }
    final owner = pathOwners()[result];
    selection
      ..clear()
      ..addAll([?owner]);
    selectedNodes.clear();
    notifyListeners();
    return result;
  }

  /// Cuts [path] where segment [segment] is at parameter [t].
  InkPath? splitPathAt(InkPath path, int segment, double t) {
    path.insertAnchor(segment, t);
    final result = splitPath(path, segment + 1);
    if (result == null) path.deleteAnchor(segment + 1); // ends can't be cut
    return result;
  }

  // ---- Eraser (ported from -[WDDrawingController eraseWithPath:]) ---------

  /// Erases [eraser]'s area from the selected shapes, or from every shape in
  /// visible, unlocked layers when nothing is selected. Closed shapes lose
  /// the area; open paths are cut into the pieces that remain.
  void erase(InkStylable eraser) {
    final area = eraser.bounds;
    final targets = <InkStylable>[
      if (selection.isNotEmpty)
        ...orderedSelection.whereType<InkStylable>()
      else
        for (final l in drawing.layers)
          if (l.editable) ...l.elements.whereType<InkStylable>(),
    ].where((e) => !e.isMasking && e.bounds.overlaps(area)).toList();
    if (targets.isEmpty) return;
    checkpoint();
    final wasSelected = selection.isNotEmpty;
    final results = <InkElement>[];
    for (final e in targets) {
      final layer = layerOf(e);
      if (layer == null) continue;
      final List<InkStylable> pieces;
      if (e is InkPath && !e.closed) {
        pieces = [
          for (final p in Pathfinder.eraseOpen(e, eraser))
            p
              ..fill = e.fill
              ..stroke = e.stroke
              ..copyEffects(e),
        ];
      } else {
        final r = Pathfinder.combine([e, eraser], BooleanOp.subtractFront);
        pieces = [
          if (r != null)
            r
              ..fill = e.fill
              ..stroke = e.stroke
              ..fillRule = r.fillRule
              ..copyEffects(e),
        ];
      }
      final i = layer.elements.indexOf(e);
      layer.elements
        ..removeAt(i)
        ..insertAll(i, pieces);
      results.addAll(pieces);
    }
    selection.clear();
    if (wasSelected) selection.addAll(results);
    selectedNodes.clear();
    notifyListeners();
  }

  // ---- Eyedropper (ported from WDEyedropperTool) ---------------------------

  /// Copies [source]'s style into the current style and onto the selection.
  /// For images, [sampled] (the pixel color) becomes the fill.
  void pickStyle(InkElement source, {InkColor? sampled}) {
    if (source is InkStylable) {
      final f = source.fill;
      fillPaint = f is InkGradient ? f.copyWith(clearGeometry: true) : f;
      strokeStyle = _unplaced(source.stroke);
    } else if (sampled != null) {
      fillPaint = sampled;
    } else {
      return;
    }
    defaultOpacity = source.opacity;
    defaultShadow = source.shadow;
    defaultBlendMode = source.blendMode;
    final targets = selection.where((e) => !identical(e, source)).toList();
    if (targets.isNotEmpty) {
      checkpoint();
      void apply(InkElement e) {
        if (e is InkStylable) {
          e.fill = fillPaint;
          if (source is InkStylable) e.stroke = strokeStyle;
          e.copyEffects(source);
        } else if (e is InkGroup) {
          e.elements.forEach(apply);
        }
      }
      targets.forEach(apply);
    }
    notifyListeners();
  }

  // ---- Text (ported from WDDrawingController's text handling) -----------

  String fontFamily = FontLibrary.instance.defaultFamily;
  String fontStyle = 'Regular';
  double fontSize = FontLibrary.defaultSize;
  TextAlignment textAlignment = TextAlignment.left;

  /// The text being typed into, if any.
  InkStylable? editingText;

  /// The letters selected while typing (null or collapsed: none). Font,
  /// size and color changes then apply to just these letters.
  TextRange? editingRange;

  /// Called as the selection in the text being typed changes: the panels
  /// show the style of the selected letters.
  void setEditingRange(TextRange range) {
    if (range == editingRange) return;
    editingRange = range;
    final t = editingText;
    if (t is InkText && range.isValid && !range.isCollapsed) {
      final st = t.runs.styleAt(range.start);
      fontFamily = t.familyOf(st);
      fontStyle = t.styleOf(st);
      fontSize = t.sizeOf(st);
      fillPaint = st.fill ?? t.fill;
    } else if (t != null) {
      adoptTextStyle(t);
      fillPaint = t.fill;
    }
    notifyListeners();
  }

  /// [st] changed by [change], minus settings that match the text's own.
  static TextRunStyle _simplified(InkText t, TextRunStyle change, TextRunStyle st) {
    final m = st.merge(change);
    return TextRunStyle(
      fontFamily: m.fontFamily == t.fontFamily ? null : m.fontFamily,
      fontStyle: m.fontStyle == t.fontStyle ? null : m.fontStyle,
      fontSize: m.fontSize == t.fontSize ? null : m.fontSize,
      fill: m.fill == t.fill ? null : m.fill,
    );
  }

  /// Selected text objects and text on paths.
  List<InkStylable> get selectedTexts => [for (final e in selection) if (e is InkText || e is InkTextPath) e as InkStylable];

  /// Ported from -[WDDrawingController createTextObjectInRect:]: area text in
  /// [area] (at least [InkText.minimumWidth] wide), or point text at [at].
  InkText createText({Offset? at, Rect? area}) {
    finishActivePath();
    checkpoint();
    final t = InkText(
      text: 'Text',
      fontFamily: fontFamily,
      fontStyle: fontStyle,
      fontSize: fontSize,
      alignment: textAlignment,
      width: area == null ? null : math.max(InkText.minimumWidth, area.width),
      placement: area != null ? Affine.translation(area.left, area.top) : Affine.translation(at!.dx, at.dy),
      // Make sure the text isn't invisible.
      fill: fillPaint is InkGradient ? (fillPaint as InkGradient).copyWith(clearGeometry: true) : (fillPaint ?? InkColor.black),
      opacity: defaultOpacity,
    )
      ..shadow = defaultShadow
      ..blendMode = defaultBlendMode;
    drawing.activeLayer.elements.add(t);
    selection
      ..clear()
      ..add(t);
    editingText = t;
    editingRange = null;
    notifyListeners();
    return t;
  }

  /// Starts typing into [t] (one undo step for the whole edit).
  void beginEditing(InkStylable t) {
    finishActivePath();
    checkpoint();
    selection
      ..clear()
      ..add(t);
    editingText = t;
    editingRange = null;
    notifyListeners();
  }

  void updateEditingText(String value) {
    final t = editingText;
    if (t is InkText) t.text = value;
    if (t is InkTextPath) t.text = value;
    notifyListeners();
  }

  /// Finishes typing; text left empty is removed.
  void endEditing() {
    final t = editingText;
    if (t == null) return;
    editingText = null;
    editingRange = null;
    final text = t is InkText ? t.text : (t as InkTextPath).text;
    if (text.trim().isEmpty) {
      for (final l in drawing.layers) {
        l.elements.remove(t);
      }
      selection.remove(t);
    }
    notifyListeners();
  }

  /// Sets font settings for new text and the selected text. Pass record:
  /// false while a slider moves.
  void setTextStyle({String? family, String? style, double? size, TextAlignment? alignment, bool record = true}) {
    if (family != null) {
      fontFamily = family;
      // Keep the style if the new family has it, else its regular face.
      final styles = FontLibrary.instance.stylesOf(family);
      final keep = styles.any((f) => f.style == (style ?? fontStyle));
      fontStyle = keep ? (style ?? fontStyle) : (styles.firstOrNull?.style ?? 'Regular');
    } else if (style != null) {
      fontStyle = style;
    }
    if (size != null) fontSize = size;
    if (alignment != null) textAlignment = alignment;
    // Letters selected while typing: restyle just those (alignment is for
    // the whole text).
    final editing = editingText, range = editingRange;
    if (editing is InkText && range != null && !range.isCollapsed && (family != null || style != null || size != null)) {
      if (record) checkpoint();
      final change = TextRunStyle(
        fontFamily: family != null || style != null ? fontFamily : null,
        fontStyle: family != null || style != null ? fontStyle : null,
        fontSize: size,
      );
      editing.runs = editing.runs.restyle(range.start, range.end, (st) => _simplified(editing, change, st));
      if (alignment != null) editing.alignment = alignment;
      notifyListeners();
      return;
    }
    final texts = selectedTexts;
    if (texts.isNotEmpty) {
      if (record) checkpoint();
      for (final t in texts) {
        if (t is InkText) {
          if (family != null || style != null) {
            t.fontFamily = fontFamily;
            t.fontStyle = fontStyle;
          }
          if (size != null) t.fontSize = size;
          if (alignment != null) t.alignment = alignment;
          // The whole text takes the change, letters with their own included.
          t.runs = t.runs.restyleAll((st) => st.without(family: family != null || style != null, style: family != null || style != null, size: size != null));
        } else if (t is InkTextPath) {
          if (family != null || style != null) {
            t.fontFamily = fontFamily;
            t.fontStyle = fontStyle;
          }
          if (size != null) t.fontSize = size;
        }
      }
    }
    notifyListeners();
  }

  /// When selecting text, its font becomes the current one (as in Inkpad).
  void adoptTextStyle(InkStylable t) {
    if (t is InkText) {
      fontFamily = t.fontFamily;
      fontStyle = t.fontStyle;
      fontSize = t.fontSize;
      textAlignment = t.alignment;
    } else if (t is InkTextPath) {
      fontFamily = t.fontFamily;
      fontStyle = t.fontStyle;
      fontSize = t.fontSize;
    }
  }

  bool get canCreateOutlines => selectedTexts.isNotEmpty;

  /// Ported from -[WDDrawingController createTextOutlines:]: text becomes
  /// one compound path of its letter shapes, with the same style.
  void createOutlines() {
    if (!canCreateOutlines) return;
    endEditing();
    checkpoint();
    final results = <InkElement>[];
    for (final t in selectedTexts) {
      final layer = layerOf(t);
      if (layer == null) continue;
      final typo = t as InkTypography;
      if (typo.outlines.isEmpty) continue;
      // One compound path per color (letters with their own color apart).
      final parts = [
        for (final (paint, shapes) in typo.paintGroups)
          InkCompoundPath(
            [for (final p in shapes) InkPath(nodes: List.of(p.nodes), closed: true)],
            fill: paint,
            stroke: t.stroke,
          ),
      ];
      final InkElement outline = parts.length == 1 ? (parts.single..copyEffects(t)) : (InkGroup(parts)..copyEffects(t));
      layer.elements[layer.elements.indexOf(t)] = outline;
      results.add(outline);
    }
    selection
      ..clear()
      ..addAll(results);
    notifyListeners();
  }

  /// Ported from -[WDDrawingController canPlaceTextOnPath]: a path alone, or
  /// a path and a text object.
  bool get canPlaceTextOnPath {
    final paths = selection.whereType<InkPath>().where((p) => !p.isMasking).toList();
    final texts = selection.whereType<InkText>().toList();
    return paths.length == 1 && texts.length <= 1 && selection.length == paths.length + texts.length;
  }

  /// Ported from -[WDDrawingController placeTextOnPath:]: the path becomes a
  /// text path, carrying the selected text (or "Text") and its font.
  void placeTextOnPath() {
    if (!canPlaceTextOnPath) return;
    endEditing();
    checkpoint();
    final path = selection.whereType<InkPath>().single;
    final source = selection.whereType<InkText>().firstOrNull;
    final layer = layerOf(path)!;
    final tp = InkTextPath(
      text: source?.text.replaceAll('\n', ' ') ?? 'Text',
      guide: InkPath(nodes: List.of(path.nodes), closed: path.closed),
      fontFamily: source?.fontFamily ?? fontFamily,
      fontStyle: source?.fontStyle ?? fontStyle,
      fontSize: source?.fontSize ?? fontSize,
      fill: source?.fill ?? fillPaint ?? InkColor.black,
      stroke: source?.stroke,
    )..copyEffects(source ?? path);
    layer.elements[layer.elements.indexOf(path)] = tp;
    if (source != null) layerOf(source)?.elements.remove(source);
    selection
      ..clear()
      ..add(tp);
    editingText = source == null ? tp : null; // type the text straight away
    notifyListeners();
  }

  // ---- Path menu (ported from Inkpad's Path menu) ---------------------------

  /// Selected paths, including the subpaths of selected compound paths.
  List<InkPath> get _selectedPaths => [
        for (final e in orderedSelection)
          if (e is InkPath) e else if (e is InkCompoundPath) ...e.subpaths,
      ];

  bool get canAddAnchors => _selectedPaths.isNotEmpty;

  /// Ported from -[WDDrawingController addAnchors:].
  void addAnchorPoints() {
    if (!canAddAnchors) return;
    finishActivePath();
    checkpoint();
    _selectedPaths.forEach(addAnchorsToPath);
    selectedNodes.clear();
    notifyListeners();
  }

  /// Ported from -[WDDrawingController canJoinPaths]: two open paths.
  bool get canJoinPaths =>
      selection.length == 2 && selection.every((e) => e is InkPath && !e.closed && e.nodes.length > 1 && !e.isMasking);

  /// Joins two open paths at their nearest ends: ends that touch are merged,
  /// otherwise a straight segment connects them. (Inkpad instead moved the
  /// second path to meet the first.) The result keeps the top path's style.
  void joinPaths() {
    if (!canJoinPaths) return;
    checkpoint();
    final ordered = orderedSelection;
    final top = ordered.last as InkPath, other = ordered.first as InkPath;
    // Choose the closest pair of ends; orient so top ends where other starts.
    final options = [
      (false, false), (false, true), (true, false), (true, true), // reverse top?, reverse other?
    ];
    (bool, bool) best = options.first;
    var bestD = double.infinity;
    for (final o in options) {
      final end = o.$1 ? top.nodes.first.anchorPoint : top.nodes.last.anchorPoint;
      final start = o.$2 ? other.nodes.last.anchorPoint : other.nodes.first.anchorPoint;
      final d = (end - start).distance;
      if (d < bestD) {
        bestD = d;
        best = o;
      }
    }
    if (best.$1) top.reverse();
    if (best.$2) other.reverse();
    final incoming = List.of(other.nodes);
    if (bestD < 0.5) {
      // Merge the touching ends into one point.
      final last = top.nodes.removeLast(), first = incoming.removeAt(0);
      top.nodes.add(BezierNode(last.inPoint, last.anchorPoint, first.outPoint + (last.anchorPoint - first.anchorPoint)));
    }
    top.nodes.addAll(incoming);
    // Closed up: ends meet.
    if (top.nodes.length > 2 && (top.nodes.first.anchorPoint - top.nodes.last.anchorPoint).distance < 0.5) {
      final last = top.nodes.removeLast();
      top.nodes[0] = BezierNode(last.inPoint, top.nodes[0].anchorPoint, top.nodes[0].outPoint);
      top.closed = true;
    }
    for (final l in drawing.layers) {
      l.elements.remove(other);
    }
    selection
      ..clear()
      ..add(top);
    selectedNodes.clear();
    notifyListeners();
  }

  bool get canOutlineStroke => selection.any((e) => e is InkStylable && !e.isMasking && (e.stroke?.willRender ?? false));

  /// Ported from -[WDDrawingController outlineStroke:]: the stroke becomes
  /// a filled shape in the stroke's color. A shape that also has a fill
  /// keeps it (minus the stroke) beneath the new outline.
  void outlineStroke() {
    if (!canOutlineStroke) return;
    finishActivePath();
    checkpoint();
    final results = <InkElement>[];
    for (final e in orderedSelection) {
      if (e is! InkStylable || e.isMasking || !(e.stroke?.willRender ?? false)) {
        results.add(e);
        continue;
      }
      final outline = Pathfinder.outlineStroke(e);
      final layer = layerOf(e)!;
      final index = layer.elements.indexOf(e);
      if (outline == null) continue;
      outline
        // A gradient keeps its place: fitted to the original shape.
        ..fill = switch (e.stroke!.gradient) { null => e.stroke!.color, final g => g.copyWith(geometry: g.fitted(e.bounds)) }
        ..copyEffects(e);
      if (e.fill != null) {
        e.stroke = null;
        layer.elements.insert(index + 1, outline);
      } else {
        layer.elements[index] = outline;
      }
      results.add(outline);
    }
    selection
      ..clear()
      ..addAll(results);
    selectedNodes.clear();
    notifyListeners();
  }

  /// Ported from -[WDDrawingController canMakeCompoundPath].
  bool get canCombinePaths =>
      selection.length > 1 && selection.every((e) => (e is InkPath || e is InkCompoundPath) && !(e as InkStylable).isMasking);

  /// Ported from -[WDDrawingController makeCompoundPath:]: one compound
  /// path styled like the topmost shape, where the topmost was.
  void combinePaths() {
    if (!canCombinePaths) return;
    checkpoint();
    final ordered = orderedSelection.cast<InkStylable>();
    final top = ordered.last;
    final compound = InkCompoundPath(
      [for (final e in ordered) ...(e is InkCompoundPath ? e.subpaths : [e as InkPath])]
          .map((p) => InkPath(nodes: List.of(p.nodes), closed: p.closed))
          .toList(),
      fill: top.fill,
      stroke: top.stroke,
      fillRule: top.fillRule,
    )..copyEffects(top);
    _replace(ordered, top, compound);
  }

  bool get canSeparatePaths => selection.any((e) => e is InkCompoundPath);

  /// Ported from -[WDDrawingController releaseCompoundPath:]: each subpath
  /// becomes a path of its own with the compound path's style. A compound
  /// path that is a clipping mask lets go of its contents first (as in
  /// Inkpad). Gradients keep their place across the whole shape instead of
  /// starting over in each piece.
  void separatePaths() {
    if (!canSeparatePaths) return;
    checkpoint();
    final released = <InkElement>[];
    for (final e in orderedSelection) {
      if (e is! InkCompoundPath) {
        released.add(e);
        continue;
      }
      final layer = layerOf(e)!;
      final masked = e.maskedElements;
      e.maskedElements = [];
      final b = e.bounds;
      final fill = switch (e.fill) {
        InkGradient g when g.geometry == null => g.copyWith(geometry: g.fitted(b)),
        final f => f,
      };
      final sg = e.stroke?.gradient;
      final stroke = sg != null && sg.geometry == null ? e.stroke!.copyWith(gradient: sg.copyWith(geometry: sg.fitted(b))) : e.stroke;
      final parts = [
        for (final p in e.subpaths)
          InkPath(nodes: p.nodes, closed: p.closed, fill: fill, stroke: stroke, fillRule: e.fillRule)..copyEffects(e),
      ];
      final i = layer.elements.indexOf(e);
      layer.elements
        ..removeAt(i)
        ..insertAll(i, [...parts, ...masked]);
      released.addAll(parts);
    }
    selection
      ..clear()
      ..addAll(released);
    selectedNodes.clear();
    notifyListeners();
  }

  bool get canCombineShapes =>
      selection.length > 1 && selection.every((e) => (e is InkPath || e is InkCompoundPath) && !(e as InkStylable).isMasking);

  /// Unite / intersect / subtract front / exclude. Ported from
  /// -[WDDrawingController booleanWithOperation:] and subtractPaths:.
  /// Subtract keeps the bottom shape's style; the others take the top's.
  void combineShapes(BooleanOp op) {
    if (!canCombineShapes) return;
    finishActivePath();
    final ordered = orderedSelection.cast<InkStylable>();
    final result = Pathfinder.combine(ordered, op);
    checkpoint();
    final styleFrom = op == BooleanOp.subtractFront ? ordered.first : ordered.last;
    if (result != null) {
      result
        ..fill = styleFrom.fill is InkGradient ? (styleFrom.fill as InkGradient).copyWith(clearGeometry: true) : styleFrom.fill
        ..stroke = styleFrom.stroke
        ..copyEffects(styleFrom);
    }
    _replace(ordered, styleFrom, result);
  }

  /// Replaces [olds] with [result] at [anchor]'s position, selecting it.
  void _replace(List<InkElement> olds, InkElement anchor, InkElement? result) {
    final layer = layerOf(anchor)!;
    if (result != null) layer.elements.insert(layer.elements.indexOf(anchor) + 1, result);
    for (final l in drawing.layers) {
      l.elements.removeWhere(olds.contains);
    }
    selection.clear();
    if (result != null) selection.add(result);
    selectedNodes.clear();
    notifyListeners();
  }

  // ---- Paths -------------------------------------------------------------

  bool get canReversePaths => selection.any((e) => e is InkPath || e is InkCompoundPath);

  /// Ported from -[WDDrawingController reversePathDirection:].
  void reversePaths() {
    if (!canReversePaths) return;
    checkpoint();
    for (final e in selection) {
      if (e is InkPath) {
        e.reverse();
        // Arrowheads stay where they were (Inkpad swaps them too).
        e.stroke = e.stroke?.swappedArrows;
      }
      if (e is InkCompoundPath) {
        for (final p in e.subpaths) {
          p.reverse();
        }
      }
    }
    notifyListeners();
  }

  // ---- Align and distribute (ported from WDDrawingController) ------------

  /// Aligns the selected elements to their combined bounds, or a single
  /// element to the page. Ported from -[WDDrawingController align...].
  void align(AlignEdge edge) {
    final target = selection.length == 1 ? drawing.bounds : selectionBounds;
    if (target == null) return;
    checkpoint();
    for (final e in selection) {
      final b = e.bounds;
      final d = switch (edge) {
        AlignEdge.left => Offset(target.left - b.left, 0),
        AlignEdge.center => Offset(target.center.dx - b.center.dx, 0),
        AlignEdge.right => Offset(target.right - b.right, 0),
        AlignEdge.top => Offset(0, target.top - b.top),
        AlignEdge.middle => Offset(0, target.center.dy - b.center.dy),
        AlignEdge.bottom => Offset(0, target.bottom - b.bottom),
      };
      e.transform(Affine.translation(d.dx, d.dy));
    }
    notifyListeners();
  }

  /// Spaces the centers of three or more elements evenly.
  void distribute({required bool horizontal}) {
    if (selection.length < 3) return;
    checkpoint();
    double c(InkElement e) => horizontal ? e.bounds.center.dx : e.bounds.center.dy;
    final sorted = selection.toList()..sort((a, b) => c(a).compareTo(c(b)));
    final first = c(sorted.first), step = (c(sorted.last) - first) / (sorted.length - 1);
    for (final (i, e) in sorted.indexed) {
      final d = first + step * i - c(e);
      e.transform(horizontal ? Affine.translation(d, 0) : Affine.translation(0, d));
    }
    notifyListeners();
  }

  // ---- Transform again (ported from WDDrawingController) ----------------

  /// The last whole move, scale, rotation or flip applied to a selection.
  Affine? lastTransform;

  /// Tools call this when a transforming gesture finishes.
  void recordTransform(Affine t) {
    if (!t.isIdentity) lastTransform = t;
  }

  void transformAgain() {
    final t = lastTransform;
    if (t == null || selection.isEmpty) return;
    checkpoint();
    transformSelection(t);
  }

  void duplicateAndTransformAgain() {
    final t = lastTransform;
    if (t == null || selection.isEmpty) return;
    duplicateInPlace();
    transformSelection(t);
  }

  // ---- Opacity ------------------------------------------------------------

  /// Opacity for new shapes, and the selection's when one is selected.
  double get opacity => selection.isEmpty ? defaultOpacity : selection.first.opacity;
  double defaultOpacity = 1;

  /// Sets the selection's opacity. Pass record: false while a slider is
  /// moving (call [checkpoint] once when it starts).
  void setOpacity(double value, {bool record = true}) {
    defaultOpacity = value;
    if (selection.isNotEmpty) {
      if (record) checkpoint();
      for (final e in selection) {
        e.opacity = value;
      }
    }
    notifyListeners();
  }

  // ---- Shadow and blend mode (Inkpad's shadow & opacity panel) -------------

  /// Shadow for new shapes, and the selection's when one is selected.
  InkShadow? get shadow => selection.isEmpty ? defaultShadow : selection.first.shadow;
  InkShadow? defaultShadow;

  /// The settings the shadow controls show (and restore when turned on).
  InkShadow lastShadow = const InkShadow();

  InkBlendMode get blendMode => selection.isEmpty ? defaultBlendMode : selection.first.blendMode;
  InkBlendMode defaultBlendMode = InkBlendMode.normal;

  /// Sets the shadow (null removes it) for the selection and new shapes.
  /// Pass record: false while a control is moving.
  void setShadow(InkShadow? value, {bool record = true}) {
    defaultShadow = value;
    if (value != null) lastShadow = value;
    if (selection.isNotEmpty) {
      if (record) checkpoint();
      for (final e in selection) {
        e.shadow = value;
      }
    }
    notifyListeners();
  }

  void setBlendMode(InkBlendMode value) {
    defaultBlendMode = value;
    if (selection.isNotEmpty) {
      checkpoint();
      for (final e in selection) {
        e.blendMode = value;
      }
    }
    notifyListeners();
  }

  // ---- Color menu (ported from WDDrawingController's color actions) --------

  /// Filled shapes to blend, back to front, including inside groups and
  /// masks. Ported from -[WDDrawingController blendables].
  List<InkStylable> get blendables {
    final out = <InkStylable>[];
    void add(InkElement e) {
      if (e is InkGroup) {
        e.elements.forEach(add);
      } else if (e is InkStylable) {
        if (e.fill != null) out.add(e);
        e.maskedElements.forEach(add);
      }
    }

    orderedSelection.forEach(add);
    return out;
  }

  /// The blendables in the order [direction] blends them.
  List<InkStylable> _blendOrder(ColorBlend direction) {
    final b = blendables;
    switch (direction) {
      case ColorBlend.backToFront:
        return b;
      case ColorBlend.horizontally:
        return b..sort((x, y) => x.bounds.center.dx.compareTo(y.bounds.center.dx));
      case ColorBlend.vertically:
        return b..sort((x, y) => x.bounds.center.dy.compareTo(y.bounds.center.dy));
    }
  }

  /// Blending needs three or more shapes, the first and last filled with
  /// solid colors.
  bool canBlendColors(ColorBlend direction) {
    final b = _blendOrder(direction);
    return b.length >= 3 && b.first.fill is InkColor && b.last.fill is InkColor;
  }

  /// Fills the shapes between the first and last with the colors in
  /// between: in stacking order, or by position across or down the page.
  void blendColors(ColorBlend direction) {
    if (!canBlendColors(direction)) return;
    final b = _blendOrder(direction);
    final first = b.first.fill as InkColor, last = b.last.fill as InkColor;
    double fraction(int i, InkStylable e) {
      switch (direction) {
        case ColorBlend.backToFront:
          return i / (b.length - 1);
        case ColorBlend.horizontally:
          final start = b.first.bounds.center.dx, end = b.last.bounds.center.dx;
          return end == start ? 0 : (e.bounds.center.dx - start) / (end - start);
        case ColorBlend.vertically:
          final start = b.first.bounds.center.dy, end = b.last.bounds.center.dy;
          return end == start ? 0 : (e.bounds.center.dy - start) / (end - start);
      }
    }

    checkpoint();
    for (final (i, e) in b.indexed) {
      e.fill = first.lerp(last, fraction(i, e));
    }
    notifyListeners();
  }

  /// Fill, stroke and shadow colors of the selection (inside groups and
  /// masks too), with the element each belongs to.
  Iterable<InkElement> get _colored sync* {
    for (final e in selection) {
      for (final d in e.selfAndDescendants) {
        if (d.shadow != null || (d is InkStylable && (d.fill != null || d.stroke != null))) yield d;
      }
    }
  }

  bool get canAdjustColors => _colored.isNotEmpty;

  /// The original colors while an adjustment panel is open.
  List<(InkElement, InkPaint?, StrokeStyle?, InkShadow?)>? _colorBase;

  /// Starts a live adjustment (Color Balance, Hue and Saturation): one undo
  /// step, previewed on the drawing as the sliders move.
  void beginColorAdjustment() {
    checkpoint();
    _colorBase = [
      for (final e in _colored) (e, e is InkStylable ? e.fill : null, e is InkStylable ? e.stroke : null, e.shadow),
    ];
  }

  /// Shows the selection with [adjust] applied to its original colors.
  void previewColorAdjustment(InkColor Function(InkColor) adjust) {
    final base = _colorBase;
    if (base == null) return;
    for (final (e, fill, stroke, shadow) in base) {
      _applyColors(e, fill, stroke, shadow, adjust);
    }
    notifyListeners();
  }

  /// Keeps the adjustment, or puts the colors back if [cancel] is true.
  void endColorAdjustment({bool cancel = false}) {
    final base = _colorBase;
    if (base == null) return;
    _colorBase = null;
    final changed = base.any((r) {
      final (e, fill, stroke, shadow) = r;
      return e is InkStylable && (e.fill != fill || e.stroke != stroke) || e.shadow != shadow;
    });
    if (cancel || !changed) {
      for (final (e, fill, stroke, shadow) in base) {
        _applyColors(e, fill, stroke, shadow, (c) => c);
      }
      if (_undoStack.isNotEmpty) _undoStack.removeLast(); // nothing to undo
      if (cancel) notifyListeners();
    }
  }

  /// Applies [adjust] to every color of the selection as one undo step.
  void adjustColors(InkColor Function(InkColor) adjust) {
    if (!canAdjustColors) return;
    checkpoint();
    for (final e in _colored.toList()) {
      _applyColors(e, e is InkStylable ? e.fill : null, e is InkStylable ? e.stroke : null, e.shadow, adjust);
    }
    notifyListeners();
  }

  void desaturate() => adjustColors((c) => c.adjustHsb(0, -1, 0));

  void invertColors() => adjustColors((c) => c.inverted);

  static void _applyColors(InkElement e, InkPaint? fill, StrokeStyle? stroke, InkShadow? shadow, InkColor Function(InkColor) adjust) {
    if (e is InkStylable) {
      e.fill = switch (fill) {
        InkColor c => adjust(c),
        InkGradient g => g.copyWith(stops: [for (final s in g.stops) GradientStop(s.offset, adjust(s.color))]),
        _ => fill,
      };
      final sg = stroke?.gradient;
      e.stroke = stroke?.copyWith(
        color: adjust(stroke.color),
        gradient: sg?.copyWith(stops: [for (final s in sg.stops) GradientStop(s.offset, adjust(s.color))]),
      );
    }
    e.shadow = shadow?.copyWith(color: adjust(shadow.color));
  }

  // ---- Rotate and flip --------------------------------------------------

  /// Rotates the selection about its center; positive is clockwise on screen.
  void rotateSelection(double degrees) =>
      _transformAboutCenter((c) => Affine.rotationAbout(c, degrees * math.pi / 180));

  /// Ported from -[WDDrawingController flipHorizontally:] / flipVertically:.
  void flipSelection({required bool horizontal}) =>
      _transformAboutCenter((c) => Affine.scaleAbout(c, horizontal ? -1 : 1, horizontal ? 1 : -1));

  void _transformAboutCenter(Affine Function(Offset center) make) {
    final b = selectionBounds;
    if (b == null) return;
    checkpoint();
    final t = make(b.center);
    transformSelection(t);
    recordTransform(t);
  }

  // ---- Images -----------------------------------------------------------

  /// Places an image file centered on the page, scaled down (never up) to
  /// fit, and selects it. Ported from -[WDDrawingController placeImage:].
  /// Returns false if the file isn't a supported image.
  bool placeImage(Uint8List bytes) {
    final data = ImageData.register(bytes);
    if (data == null || data.width == 0 || data.height == 0) return false;
    finishActivePath();
    checkpoint();
    final scale = math.min(1.0, math.min(drawing.width / data.width, drawing.height / data.height));
    final w = data.width * scale, h = data.height * scale;
    final image = InkImage(
      data,
      placement: Affine.scale(scale, scale).then(Affine.translation((drawing.width - w) / 2, (drawing.height - h) / 2)),
    );
    drawing.activeLayer.elements.add(image);
    selection
      ..clear()
      ..add(image);
    notifyListeners();
    return true;
  }

  // ---- Clipping masks ---------------------------------------------------

  /// Selected elements in stacking order, bottom first.
  List<InkElement> get orderedSelection =>
      [for (final l in drawing.layers) ...l.elements.where(selection.contains)];

  /// Ported from -[WDDrawingController canMaskElements]: the topmost
  /// selected element must be a shape, with something below it to clip.
  bool get canMakeMask {
    final ordered = orderedSelection;
    return ordered.length > 1 && ordered.last is InkStylable && !(ordered.last as InkStylable).isMasking;
  }

  bool get canReleaseMask => selection.any((e) => e is InkStylable && e.isMasking);

  /// Ported from -[WDDrawingController makeMask:]: the topmost selected
  /// shape clips the other selected elements.
  void makeMask() {
    if (!canMakeMask) return;
    checkpoint();
    final ordered = orderedSelection;
    final mask = ordered.removeLast() as InkStylable;
    for (final l in drawing.layers) {
      l.elements.removeWhere(ordered.contains);
    }
    mask.maskedElements = ordered;
    selection
      ..clear()
      ..add(mask);
    notifyListeners();
  }

  /// Ported from -[WDDrawingController releaseMask:]: the clipped elements
  /// go back into the layer, just above the shape that clipped them.
  void releaseMask() {
    final masks = orderedSelection.whereType<InkStylable>().where((e) => e.isMasking).toList();
    if (masks.isEmpty) return;
    checkpoint();
    for (final mask in masks) {
      final layer = layerOf(mask)!;
      final released = mask.maskedElements;
      mask.maskedElements = [];
      layer.elements.insertAll(layer.elements.indexOf(mask) + 1, released);
      selection.addAll(released);
    }
    notifyListeners();
  }

  // ---- Gradient editing -------------------------------------------------

  /// Moves an end of the selected shape's gradient to a document point.
  void moveGradientHandle(InkStylable shape, {required bool start, required Offset to}) {
    final g = shape.fill;
    if (g is! InkGradient) return;
    final geom = g.fitted(shape.bounds);
    shape.fill = g.copyWith(geometry: start ? geom.withDocumentStart(to) : geom.withDocumentEnd(to));
    notifyListeners();
  }

  /// Adds another drawing's contents to the active layer as one selected
  /// group (or a single element), keeping its coordinates.
  void place(InkDrawing other) {
    final elements = [for (final e in other.allElements) e.clone()];
    if (elements.isEmpty) return;
    checkpoint();
    final placed = elements.length == 1 ? elements.single : InkGroup(elements);
    drawing.activeLayer.elements.add(placed);
    selection
      ..clear()
      ..add(placed);
    notifyListeners();
  }

  // ---- Pen tool support -------------------------------------------------

  void finishActivePath() {
    if (activePath == null) return;
    if (activePath!.nodes.length < 2) {
      for (final l in drawing.layers) {
        l.elements.remove(activePath);
      }
    }
    activePath = null;
    notifyListeners();
  }

  // ---- Layers -----------------------------------------------------------

  void addLayer() {
    checkpoint();
    drawing.addLayer();
    selection.clear();
    notifyListeners();
  }

  void deleteActiveLayer() {
    if (drawing.layers.length <= 1) return;
    checkpoint();
    drawing.deleteActiveLayer();
    selection.clear();
    notifyListeners();
  }

  void duplicateActiveLayer() {
    checkpoint();
    drawing.duplicateActiveLayer();
    selection.clear();
    notifyListeners();
  }

  void moveLayer(int from, int to) {
    if (from == to) return;
    checkpoint();
    drawing.moveLayer(from, to);
    notifyListeners();
  }

  /// Pass record: false while a slider is moving.
  void setLayerOpacity(double value, {bool record = true}) {
    if (record) checkpoint();
    drawing.activeLayer.opacity = value;
    notifyListeners();
  }

  void updateLayer(int i, void Function(InkLayer layer) change) {
    checkpoint();
    change(drawing.layers[i]);
    if (!drawing.layers[i].editable) selection.removeWhere((e) => drawing.layers[i].elements.contains(e));
    notifyListeners();
  }

  void activateLayer(int i) {
    drawing.activeLayerIndex = i;
    notifyListeners();
  }
}

/// The color menu's blend directions.
enum ColorBlend { backToFront, horizontally, vertically }
