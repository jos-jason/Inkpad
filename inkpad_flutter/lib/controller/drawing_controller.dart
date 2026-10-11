import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../geometry/pathfinder.dart';
import '../model/bezier_node.dart';
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
    if (t is! DirectSelectTool) selectedNodes.clear();
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
    selectedNodes.clear();
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
    selectedNodes.clear();
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
        opacity: path.opacity,
      );
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
              ..opacity = e.opacity,
        ];
      } else {
        final r = Pathfinder.combine([e, eraser], BooleanOp.subtractFront);
        pieces = [
          if (r != null)
            r
              ..fill = e.fill
              ..stroke = e.stroke
              ..fillRule = r.fillRule
              ..opacity = e.opacity,
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
      strokeStyle = source.stroke;
    } else if (sampled != null) {
      fillPaint = sampled;
    } else {
      return;
    }
    defaultOpacity = source.opacity;
    final targets = selection.where((e) => !identical(e, source)).toList();
    if (targets.isNotEmpty) {
      checkpoint();
      void apply(InkElement e) {
        if (e is InkStylable) {
          e.fill = fillPaint;
          if (source is InkStylable) e.stroke = strokeStyle;
          e.opacity = defaultOpacity;
        } else if (e is InkGroup) {
          e.elements.forEach(apply);
        }
      }
      targets.forEach(apply);
    }
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
        ..fill = e.stroke!.color
        ..opacity = e.opacity;
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
      opacity: top.opacity,
    );
    _replace(ordered, top, compound);
  }

  bool get canSeparatePaths => selection.any((e) => e is InkCompoundPath && !e.isMasking);

  /// Ported from -[WDDrawingController releaseCompoundPath:]: each subpath
  /// becomes a path of its own with the compound path's style.
  void separatePaths() {
    if (!canSeparatePaths) return;
    checkpoint();
    final released = <InkElement>[];
    for (final e in orderedSelection) {
      if (e is! InkCompoundPath || e.isMasking) {
        released.add(e);
        continue;
      }
      final layer = layerOf(e)!;
      final parts = [
        for (final p in e.subpaths)
          InkPath(nodes: p.nodes, closed: p.closed, fill: e.fill, stroke: e.stroke, fillRule: e.fillRule, opacity: e.opacity),
      ];
      final i = layer.elements.indexOf(e);
      layer.elements
        ..removeAt(i)
        ..insertAll(i, parts);
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
        ..opacity = styleFrom.opacity;
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
