import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../tools/tool.dart';
import '../chrome/chrome.dart';
import 'constraint_glyphs.dart';

/// The Constraints tool's options: which constraint to make, what to pick,
/// and how much of the sketch is still free to move.
class ConstraintBar extends StatelessWidget {
  final DrawingController controller;
  final ConstraintTool tool;

  const ConstraintBar({super.key, required this.controller, required this.tool});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    final info = c.sketchInfo;
    final status = c.drawing.constraints.isEmpty
        ? 'No constraints yet'
        : c.sketchConflict
            ? 'The constraints can\'t all be met: delete or change one'
            : info == null
                ? ''
                : info.free == 0
                    ? 'Fully constrained'
                    : '${info.free} degree${info.free == 1 ? '' : 's'} of freedom left · green shapes are fully held';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Pill(
        radius: 18,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final m in SketchMode.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Tooltip(
                    message: '${m.label}: ${m.prompt}',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => tool.setMode(c, m),
                      child: Container(
                        width: m == SketchMode.dimension ? 44 : 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: tool.mode == m ? theme.colorScheme.primary : null,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ConstraintGlyph(m, color: tool.mode == m ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface, size: 20),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: Text(
              '${tool.mode.label}: ${tool.picks.isEmpty ? tool.mode.prompt : '${tool.picks.length} picked…'}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
              child: Text(
                status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.sketchConflict ? theme.colorScheme.error : theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
