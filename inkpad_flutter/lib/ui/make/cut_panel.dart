import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/element.dart';
import '../../model/style.dart';
import '../chrome/chrome.dart';
import 'length_field.dart';

/// Make mode: how the selection is cut — type (Shaper Origin's five), depth
/// and offset. Like Shaper Studio's cut settings.
class CutPanel extends StatelessWidget {
  final DrawingController controller;

  const CutPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final d = c.drawing;
        final cut = c.currentCut;
        final hasSelection = c.cuttables.isNotEmpty;
        final theme = Theme.of(context);
        final onlyOpen = hasSelection && c.cuttables.every((s) => s is InkPath && !s.closed);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Cut'),
            if (!hasSelection)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Nothing selected: choose the cut new shapes get.', style: theme.textTheme.bodySmall),
              ),
            for (final type in CutType.values)
              ListTile(
                dense: true,
                enabled: !(onlyOpen && type.needsClosedShape),
                selected: cut.type == type,
                leading: SizedBox.square(dimension: 28, child: CustomPaint(painter: _CutSwatch(type))),
                title: Text(type.label),
                subtitle: Text(type.needsClosedShape && onlyOpen ? 'Needs a closed shape' : type.description),
                trailing: cut.type == type ? const Icon(Icons.check) : null,
                onTap: () => c.setCutType(type),
              ),
            const Divider(indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                const Expanded(child: Text('Depth')),
                if (cut.depth != null)
                  TextButton(onPressed: hasSelection ? () => c.setCutDepth(null) : null, child: const Text('Use default')),
                LengthField(
                  value: cut.depth ?? d.defaultCutDepth,
                  lengths: d.lengths,
                  enabled: hasSelection && cut.type != CutType.guide,
                  width: 120,
                  onChanged: (v) => c.setCutDepth(v.clamp(0, 10000)),
                ),
              ]),
            ),
            if (cut.depth == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('Using the default depth (set in Settings, under Make mode).', style: theme.textTheme.bodySmall),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                const Expanded(child: Text('Offset')),
                LengthField(
                  value: cut.offset,
                  lengths: d.lengths,
                  enabled: hasSelection && cut.type != CutType.guide,
                  width: 120,
                  onChanged: c.setCutOffset,
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text(
                'Offset moves the cut out from the line (or in, when negative): for fitting parts together.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A small square in a cut type's colors.
class _CutSwatch extends CustomPainter {
  final CutType type;

  _CutSwatch(this.type);

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(4);
    final fill = type.fill;
    if (fill is InkColor) canvas.drawRect(r, Paint()..color = fill.toColor());
    final s = type.stroke;
    if (s != null) {
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = s.color.toColor(),
      );
    }
    if (fill == null && s == null) canvas.drawRect(r, Paint()..color = const Color(0x22000000));
  }

  @override
  bool shouldRepaint(_CutSwatch old) => old.type != type;
}
