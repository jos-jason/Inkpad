import 'dart:ui';

import '../controller/drawing_controller.dart';

export 'anchor_tool.dart';
export 'constraint_tool.dart';
export 'direct_select_tool.dart';
export 'drawing_tools.dart';
export 'hand_tool.dart';
export 'pen_tool.dart';
export 'transform_tool.dart';
export 'selection_tool.dart';
export 'shape_tool.dart';
export 'joinery_tool.dart';
export 'measure_tool.dart';
export 'text_tool.dart';

/// A pointer event already converted to document coordinates.
class ToolEvent {
  /// Location in document space.
  final Offset point;

  /// Screen pixels per document unit (for zoom-independent hit slop).
  final double viewScale;

  /// Shift: constrain. Alt/Option: independent handles / draw from center.
  final bool shift, alt;

  /// A second finger on the screen while dragging with the first: as in
  /// Inkpad, it constrains (like Shift) or breaks handles apart (like
  /// Option), whichever the tool uses.
  final bool secondary;

  /// 1 for a single click or tap, 2 for a double, and so on.
  /// Ported from WDEvent's count.
  final int count;

  /// From a finger (bigger targets) or an Apple Pencil or other stylus,
  /// rather than a mouse.
  final bool touch, pencil;

  const ToolEvent(this.point, this.viewScale,
      {this.shift = false, this.alt = false, this.secondary = false, this.count = 1, this.touch = false, this.pencil = false});

  /// Shift or a second finger: keep to straight lines, squares, 45°.
  bool get constrain => shift || secondary;

  /// Option/Alt or a second finger: move a handle without its partner.
  bool get independent => alt || secondary;

  /// How close (screen pixels) a point must be to grab it: a fingertip's
  /// reach as in Inkpad (kNodeSelectionTolerance, 25), less for a Pencil
  /// or a mouse, which are precise.
  double get reach => touch ? 25 : (pencil ? 12 : 8);

  /// Hit tolerance in document units: [pixels] for a mouse, scaled up in
  /// the same proportion for a Pencil or a finger.
  double slop([double pixels = 8]) => pixels * reach / 8 / viewScale;

  /// How close (in document units) a point or edge must be to snap.
  double get snapTolerance => (touch ? snapPixelsTouch : (pencil ? snapPixelsPencil : snapPixelsMouse)) / viewScale;
}

/// Base class for canvas tools. Ported from WDTool.
abstract class Tool {
  String get name;

  /// Pans the view instead of receiving document events.
  bool get pansView => false;

  void begin(DrawingController c, ToolEvent e) {}
  void move(DrawingController c, ToolEvent e) {}
  void end(DrawingController c, ToolEvent e) {}

  /// The gesture was interrupted (e.g. a second finger started a pinch).
  void cancel(DrawingController c) {}

  /// Draws tool feedback in document coordinates.
  void paintOverlay(Canvas canvas, DrawingController c, double viewScale) {}
}
