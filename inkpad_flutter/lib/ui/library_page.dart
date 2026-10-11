import 'package:flutter/material.dart';

import '../library/drawing_store.dart';
import '../library/library_controller.dart';
import 'drawing_thumbnail.dart';
import 'editor_page.dart';
import 'file_actions.dart';

enum _Action { open, rename, duplicate, exportSvg, exportInkpad, delete }

/// Grid of saved drawings. Ported in spirit from Inkpad's WDBrowserController.
class LibraryPage extends StatefulWidget {
  final LibraryController library;

  const LibraryPage({super.key, required this.library});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  LibraryController get library => widget.library;

  @override
  void initState() {
    super.initState();
    if (!library.loaded) library.load();
  }

  Future<void> _open(DrawingInfo info) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EditorPage(library: library, info: info)),
      );

  Future<void> _newDrawing() async => _open(await library.create());

  Future<void> _import() async {
    final files = await pickDrawingFiles(context);
    for (final f in files) {
      await library.create(drawing: f.drawing, name: f.name);
    }
    if (mounted) reportImport(context, files);
  }

  Future<void> _perform(_Action action, DrawingInfo info) async {
    switch (action) {
      case _Action.open:
        await _open(info);
      case _Action.rename:
        final name = await promptForText(context, title: 'Rename drawing', initial: info.name);
        if (name != null) await library.rename(info, name);
      case _Action.duplicate:
        await library.duplicate(info);
      case _Action.exportSvg:
        await exportSvg(context, info.drawing, info.name);
      case _Action.exportInkpad:
        await exportInkpad(context, info.drawing, info.name);
      case _Action.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete "${info.name}"?'),
            content: const Text('This drawing will be permanently removed from your library.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok == true) await library.delete(info);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final error = library.error;
        if (error != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || library.error == null) return;
            showSnack(context, library.error!);
            library.error = null;
          });
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Gallery'),
            actions: [
              IconButton(
                tooltip: 'Import SVG or .inkpad files',
                icon: const Icon(Icons.file_open_outlined),
                onPressed: _import,
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _newDrawing,
            icon: const Icon(Icons.add),
            label: const Text('New drawing'),
          ),
          body: !library.loaded
              ? const Center(child: CircularProgressIndicator())
              : library.drawings.isEmpty
                  ? _emptyState(context)
                  : _grid(context),
        );
      },
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.draw_outlined, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('No drawings yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Tap “New drawing” to start one.', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.72,
      ),
      itemCount: library.drawings.length,
      itemBuilder: (context, i) {
        final info = library.drawings[i];
        return _DrawingCard(
          key: ValueKey(info.id),
          info: info,
          onOpen: () => _open(info),
          onAction: (a) => _perform(a, info),
        );
      },
    );
  }
}

class _DrawingCard extends StatelessWidget {
  final DrawingInfo info;
  final VoidCallback onOpen;
  final ValueChanged<_Action> onAction;

  const _DrawingCard({super.key, required this.info, required this.onOpen, required this.onAction});

  static const _items = [
    (_Action.open, 'Open', Icons.edit_outlined),
    (_Action.rename, 'Rename…', Icons.drive_file_rename_outline),
    (_Action.duplicate, 'Duplicate', Icons.copy_outlined),
    (_Action.exportSvg, 'Export SVG…', Icons.ios_share),
    (_Action.exportInkpad, 'Export .inkpad…', Icons.save_alt),
    (_Action.delete, 'Delete…', Icons.delete_outline),
  ];

  Future<void> _showMenuAt(BuildContext context, Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<_Action>(
      context: context,
      position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
      items: [
        for (final (a, label, icon) in _items)
          PopupMenuItem(value: a, child: ListTile(leading: Icon(icon), title: Text(label), dense: true)),
      ],
    );
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.outlined(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onLongPress: () {
          final box = context.findRenderObject() as RenderBox;
          _showMenuAt(context, box.localToGlobal(box.size.center(Offset.zero)));
        },
        onSecondaryTapUp: (d) => _showMenuAt(context, d.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(12),
                child: Center(child: DrawingThumbnail(drawing: info.drawing)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(info.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                        Text(_describeDate(info.modified), style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  PopupMenuButton<_Action>(
                    tooltip: 'More',
                    onSelected: onAction,
                    itemBuilder: (_) => [
                      for (final (a, label, icon) in _items)
                        PopupMenuItem(value: a, child: ListTile(leading: Icon(icon), title: Text(label), dense: true)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _describeDate(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  final sameDay = now.year == t.year && now.month == t.month && now.day == t.day;
  final hh = t.hour.toString().padLeft(2, '0'), mm = t.minute.toString().padLeft(2, '0');
  if (sameDay) return 'Today $hh:$mm';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = '${months[t.month - 1]} ${t.day}';
  return now.year == t.year ? date : '$date, ${t.year}';
}
