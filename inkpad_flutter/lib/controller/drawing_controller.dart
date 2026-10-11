import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import '../tools/tool.dart';

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
    _tool = t;
    notifyListeners();
  }

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
    drawing = InkDrawing.decode(snapshot);
    selection.clear();
    activePath = null;
    notifyListeners();
  }

  // ---- Elements ---------------------------------------------------------

  InkPath styledPath(InkPath p) => p
    ..fill = fillPaint
    ..stroke = strokeStyle
    ..opacity = defaultOpacity;

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

  void select(InkElement e, {bool extend = false}) {
    if (!extend) selection.clear();
    selection.add(e);
    // Like Inkpad's property manager, the inspector picks up the style of
    // what you select, so new shapes continue in that style.
    if (!extend && e is InkStylable) {
      final f = e.fill;
      fillPaint = f is InkGradient ? f.copyWith(clearGeometry: true) : f;
      strokeStyle = e.stroke;
    }
    notifyListeners();
  }

  void selectNone() {
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
    void apply(InkElement e) {
      if (e is InkStylable) {
        if (fill) e.fill = _fillFor(e.fill, fillPaint);
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

  // ---- Paths -------------------------------------------------------------

  bool get canReversePaths => selection.any((e) => e is InkPath || e is InkCompoundPath);

  /// Ported from -[WDDrawingController reversePathDirection:].
  void reversePaths() {
    if (!canReversePaths) return;
    checkpoint();
    for (final e in selection) {
      if (e is InkPath) e.reverse();
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
