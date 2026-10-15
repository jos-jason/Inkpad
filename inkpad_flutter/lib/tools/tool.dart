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

  /// 1 for a single click or tap, 2 for a double, and so on.
  /// Ported from WDEvent's count.
  final int count;

  /// From a finger (bigger targets) rather than a mouse or pen.
  final bool touch;

  const ToolEvent(this.point, this.viewScale, {this.shift = false, this.alt = false, this.count = 1, this.touch = false});

  /// Hit tolerance of [pixels] screen pixels, in document units.
  double slop([double pixels = 8]) => pixels / viewScale;

  /// How close (in document units) a point or edge must be to snap.
  double get snapTolerance => (touch ? snapPixelsTouch : snapPixelsMouse) / viewScale;
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
