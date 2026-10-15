import 'package:flutter/material.dart';

/// Below this width the editor uses its compact (phone) layout.
const compactWidth = 700.0;

bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidth;

/// A floating rounded panel, the building block of the editor's chrome.
class Pill extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const Pill({super.key, required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 6), this.radius = 22});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Pure white panels in light mode, as in Inkpad; the theme surface in dark.
    final color = theme.brightness == Brightness.light ? Colors.white : theme.colorScheme.surfaceContainerHigh;
    // The shadow sits behind the panel (a shadow inside it would gray it).
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 18, offset: Offset(0, 4))],
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(radius),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A text button for the floating bars (e.g. "Gallery", "Edit").
class PillTextButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const PillTextButton(this.label, {super.key, this.onPressed});

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w400),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        child: Text(label),
      );
}

enum PopoverSide { above, below, right }

/// Shows [builder]'s content in a floating card next to the widget whose
/// context is [anchor]. On phones it opens as a bottom sheet instead.
Future<T?> showPopover<T>({
  required BuildContext anchor,
  required WidgetBuilder builder,
  double width = 380,
  PopoverSide side = PopoverSide.above,
  bool sheetOnCompact = true,
}) {
  if (sheetOnCompact && isCompact(anchor)) {
    return showModalBottomSheet<T>(
      context: anchor,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(anchor).height * 0.85),
      builder: (context) => SafeArea(child: SingleChildScrollView(child: builder(context))),
    );
  }
  final box = anchor.findRenderObject() as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  return showGeneralDialog<T>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(animation), child: child),
    ),
    pageBuilder: (context, _, _) {
      final screen = MediaQuery.sizeOf(context);
      const margin = 12.0;
      final w = width.clamp(0.0, screen.width - margin * 2);
      double left, top, maxHeight;
      double? bottom;
      switch (side) {
        case PopoverSide.above:
          left = (rect.center.dx - w / 2).clamp(margin, screen.width - w - margin);
          bottom = screen.height - rect.top + 10;
          top = margin;
          maxHeight = rect.top - 10 - margin;
        case PopoverSide.below:
          left = (rect.center.dx - w / 2).clamp(margin, screen.width - w - margin);
          top = rect.bottom + 10;
          maxHeight = screen.height - top - margin;
        case PopoverSide.right:
          left = rect.right + 12;
          top = margin;
          maxHeight = screen.height - margin * 2;
      }
      final card = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: w, maxHeight: maxHeight),
        child: Pill(
          radius: 26,
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: SingleChildScrollView(child: builder(context)),
          ),
        ),
      );
      return Stack(children: [
        if (side == PopoverSide.right)
          Positioned(left: left, top: (rect.top - 8).clamp(margin, screen.height - margin), child: card)
        else if (bottom != null)
          Positioned(left: left, bottom: bottom, width: w, child: card)
        else
          Positioned(left: left, top: top, width: w, child: card),
      ]);
    },
  );
}

/// One entry in a [MenuPanel].
sealed class MenuEntry {
  const MenuEntry();
}

class MenuAction extends MenuEntry {
  final String label;
  final VoidCallback? onSelected;
  final Widget? trailing;

  /// Shown as "coming soon" style: disabled with a tooltip.
  final bool comingSoon;

  const MenuAction(this.label, this.onSelected, {this.trailing, this.comingSoon = false});
}

class MenuDivider extends MenuEntry {
  const MenuDivider();
}

/// The Edit / Arrange / Path menu style: large rows in a rounded card.
class MenuPanel extends StatelessWidget {
  final List<MenuEntry> entries;

  const MenuPanel(this.entries, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in entries)
            switch (e) {
              MenuDivider() => Divider(height: 9, indent: 8, endIndent: 8, color: scheme.outlineVariant),
              MenuAction(:final label, :final onSelected, :final trailing, :final comingSoon) => Tooltip(
                  message: comingSoon ? 'Coming soon' : '',
                  child: InkWell(
                    onTap: onSelected == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            onSelected();
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 18,
                              color: onSelected == null ? scheme.onSurface.withValues(alpha: 0.35) : scheme.onSurface,
                            ),
                          ),
                        ),
                        if (trailing != null)
                          Opacity(opacity: onSelected == null ? 0.35 : 1, child: trailing),
                      ]),
                    ),
                  ),
                ),
            },
        ],
      ),
    );
  }
}

/// A small titled header row used at the top of popovers.
class PopoverHeader extends StatelessWidget {
  final String title;
  final Widget? leading;
  final Widget? trailing;

  const PopoverHeader(this.title, {super.key, this.leading, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 6),
        child: Row(children: [
          ?leading,
          Expanded(
            child: Text(title,
                textAlign: leading == null ? TextAlign.start : TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          ?trailing,
        ]),
      );
}

/// Label – slider – [−] value [+], as in the stroke width and corner
/// radius controls.
class SteppedSlider extends StatelessWidget {
  final String? label;
  final double value, min, max, step;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  const SteppedSlider({
    super.key,
    this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  void _bump(double delta) {
    onChangeStart?.call();
    onChanged((value + delta).clamp(min, max));
    onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: Row(children: [
              Expanded(child: Text(label!, style: const TextStyle(fontSize: 16))),
              Text(format(value), style: const TextStyle(fontSize: 16)),
            ]),
          ),
        Row(children: [
          IconButton(
            tooltip: 'Less',
            icon: Icon(Icons.remove, color: scheme.primary),
            onPressed: value > min ? () => _bump(-step) : null,
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChangeStart: onChangeStart == null ? null : (_) => onChangeStart!(),
              onChanged: onChanged,
              onChangeEnd: onChangeEnd == null ? null : (_) => onChangeEnd!(),
            ),
          ),
          if (label == null) SizedBox(width: 64, child: Text(format(value), textAlign: TextAlign.center)),
          IconButton(
            tooltip: 'More',
            icon: Icon(Icons.add, color: scheme.primary),
            onPressed: value < max ? () => _bump(step) : null,
          ),
        ]),
      ],
    );
  }
}
