import 'tool.dart';

/// Pans the canvas with a single pointer. Ported from WDHandTool.
class HandTool extends Tool {
  @override
  String get name => 'Hand';

  @override
  bool get pansView => true;
}
