import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../tools/tool.dart';
import 'chrome.dart';

/// One tool in the palette. [tool] is null for tools that aren't built yet;
/// they show disabled with a "coming soon" tooltip.
class PaletteTool {
  final String label;
  final String? shortcut;
  final Widget icon;
  final Tool? tool;

  const PaletteTool(this.label, this.icon, this.tool, {this.shortcut});

  String get tooltip => tool == null
      ? '$label (coming soon)'
      : shortcut == null
      ? label
      : '$label ($shortcut)';
}

/// Several tools sharing one palette slot, chosen from a fly-out
/// (e.g. the shape tools).
class PaletteGroup {
  final List<PaletteTool> variants;
  int current = 0;

  PaletteGroup(this.variants);

  PaletteTool get shown => variants[current];
}

/// The floating vertical tool palette with fly-outs and a delete button.
class ToolPalette extends StatelessWidget {
  final DrawingController controller;

  /// [PaletteTool]s and [PaletteGroup]s, top to bottom.
  final List<Object> items;

  const ToolPalette({super.key, required this.controller, required this.items});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Pill(
        radius: 24,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        // Fixed width: the divider would otherwise stretch it across the screen.
        child: SizedBox(
          width: 56,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items)
                  switch (item) {
                    PaletteGroup g => _GroupButton(
                      controller: controller,
                      group: g,
                    ),
                    PaletteTool t => _ToolButton(
                      controller: controller,
                      tool: t,
                    ),
                    _ => const SizedBox.shrink(),
                  },
                const Divider(height: 12, indent: 8, endIndent: 8),
                IconButton(
                  tooltip: 'Delete',
                  icon: Icon(Icons.delete_outline, color: Colors.red.shade300),
                  onPressed: controller.selection.isEmpty
                      ? null
                      : controller.deleteSelection,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final DrawingController controller;
  final PaletteTool tool;
  final VoidCallback? onSelected;

  /// Group slots show a chevron and stay tappable (to open the fly-out)
  /// even when the shown tool isn't built yet.
  final bool isGroup;

  const _ToolButton({
    required this.controller,
    required this.tool,
    this.onSelected,
    this.isGroup = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = tool.tool;
    final active = t != null && identical(controller.tool, t);
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tool.tooltip,
      preferBelow: false,
      child: Semantics(
        button: true,
        selected: active,
        enabled: t != null,
        label: tool.label,
        child: InkResponse(
          radius: 24,
          onTap: t == null && !isGroup
              ? null
              : (onSelected ?? () => controller.tool = t!),
          child: Container(
            width: 48,
            height: 48,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? scheme.onSurface.withValues(alpha: 0.22) : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                IconTheme(
                  data: IconThemeData(
                    color: t == null
                        ? scheme.onSurface.withValues(alpha: 0.3)
                        : scheme.onSurface,
                    size: 26,
                  ),
                  child: tool.icon,
                ),
                if (isGroup)
                  Positioned(
                    right: 2,
                    bottom: 4,
                    child: Icon(
                      Icons.chevron_right,
                      size: 13,
                      color: scheme.onSurface,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupButton extends StatelessWidget {
  final DrawingController controller;
  final PaletteGroup group;

  const _GroupButton({required this.controller, required this.group});

  bool get _active => group.variants.any(
    (v) => v.tool != null && identical(v.tool, controller.tool),
  );

  Future<void> _openFlyout(BuildContext context) => showPopover(
    anchor: context,
    side: PopoverSide.right,
    sheetOnCompact: false,
    width: 64,
    builder: (popover) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, v) in group.variants.indexed)
            _ToolButton(
              controller: controller,
              tool: v,
              onSelected: () {
                group.current = i;
                controller.tool = v.tool!;
                Navigator.of(popover).pop();
              },
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => _openFlyout(context),
      child: _ToolButton(
        controller: controller,
        tool: group.shown,
        isGroup: true,
        onSelected: () {
          // Like Inkpad: tap picks the group's tool; tap again for the fly-out.
          final shown = group.shown.tool;
          if (_active || shown == null) {
            _openFlyout(context);
          } else {
            controller.tool = shown;
          }
        },
      ),
    );
  }
}
