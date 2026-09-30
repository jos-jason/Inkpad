import 'package:flutter/widgets.dart';

import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import '../tools/tool.dart';

/// Owns the document, selection, undo history and the active tool.
/// Plays the role of Inkpad's WDDrawingController + WDPropertyManager.
class DrawingController extends ChangeNotifier {
  InkDrawing drawing;

  final Set<InkElement> selection = {};

  /// Path currently being built by the pen tool, if any.
  InkPath? activePath;

  /// Style applied to newly created shapes.
  InkColor? fillColor = const InkColor(0.35, 0.6, 0.95);
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
    _undoStack.add(drawing.encode());
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void undo() {
    if (!canUndo) return;
    _redoStack.add(drawing.encode());
    _restore(_undoStack.removeLast());
  }

  void redo() {
    if (!canRedo) return;
    _undoStack.add(drawing.encode());
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
    ..fill = fillColor
    ..stroke = strokeStyle;

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
    notifyListeners();
  }

  void selectNone() {
    if (selection.isEmpty) return;
    selection.clear();
    notifyListeners();
  }

  void selectAll() {
    selection
      ..clear()
      ..addAll(drawing.activeLayer.elements);
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

  void duplicateSelection() {
    if (selection.isEmpty) return;
    checkpoint();
    final copies = <InkElement>[];
    for (final e in selection) {
      final c = e.clone()..transform(Affine.translation(10, 10));
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
  void applyStyleToSelection({bool fill = false, bool stroke = false}) {
    if (selection.isEmpty) return;
    checkpoint();
    void apply(InkElement e) {
      if (e is InkPath) {
        if (fill) e.fill = fillColor;
        if (stroke) e.stroke = strokeStyle;
      } else if (e is InkGroup) {
        e.elements.forEach(apply);
      }
    }
    selection.forEach(apply);
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

  void activateLayer(int i) {
    drawing.activeLayerIndex = i;
    notifyListeners();
  }
}
