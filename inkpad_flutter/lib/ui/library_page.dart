import 'package:flutter/material.dart';

import '../library/drawing_store.dart';
import '../library/library_controller.dart';
import 'drawing_thumbnail.dart';
import 'editor_page.dart';
import 'file_actions.dart';

enum _Action { open, rename, duplicate, move, exportSvg, exportInkpad, delete }

enum _PortfolioAction { open, rename, delete }

/// The gallery of saved drawings, or one portfolio's drawings. Ported in
/// spirit from Inkpad's WDBrowserController, plus search and portfolios
/// (named groups of drawings, like folders).
class LibraryPage extends StatefulWidget {
  final LibraryController library;

  /// The portfolio shown (null: the gallery itself).
  final PortfolioInfo? portfolio;

  const LibraryPage({super.key, required this.library, this.portfolio});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _search = TextEditingController();

  LibraryController get library => widget.library;
  PortfolioInfo? get portfolio => widget.portfolio;
  String get query => _search.text.trim();

  @override
  void initState() {
    super.initState();
    if (!library.loaded) library.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(DrawingInfo info) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EditorPage(library: library, info: info)),
      );

  Future<void> _openPortfolio(PortfolioInfo p) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LibraryPage(library: library, portfolio: p)),
      );

  /// Asks for a name (suggesting "Untitled", "Untitled 2", …), then opens
  /// the new drawing.
  Future<void> _newDrawing() async {
    final name = await promptForText(context, title: 'New drawing', initial: library.uniqueName(), action: 'Create');
    if (name == null || !mounted) return;
    final trimmed = name.trim();
    await _open(await library.create(name: trimmed.isEmpty ? null : trimmed, portfolio: portfolio?.id));
  }

  Future<void> _import() async {
    final files = await pickDrawingFiles(context);
    for (final f in files) {
      await library.create(drawing: f.drawing, name: f.name, portfolio: portfolio?.id);
    }
    if (mounted) reportImport(context, files);
  }

  Future<PortfolioInfo?> _newPortfolio() async {
    final name = await promptForText(context, title: 'New portfolio', initial: library.uniquePortfolioName());
    if (name == null || name.trim().isEmpty) return null;
    return library.createPortfolio(name);
  }

  /// Asks where to move [info]: another portfolio, a new one, or back to
  /// the gallery.
  Future<void> _move(DrawingInfo info) async {
    const newOne = '\u0000new';
    const gallery = '\u0000gallery';
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Move "${info.name}" to'),
        children: [
          if (info.portfolio != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, gallery),
              child: const ListTile(leading: Icon(Icons.grid_view), title: Text('Gallery (no portfolio)'), dense: true),
            ),
          for (final p in library.portfolios)
            if (p.id != info.portfolio)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, p.id),
                child: ListTile(leading: const Icon(Icons.folder_outlined), title: Text(p.name), dense: true),
              ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, newOne),
            child: const ListTile(leading: Icon(Icons.create_new_folder_outlined), title: Text('New portfolio…'), dense: true),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == gallery) return library.move([info], null);
    if (choice == newOne) {
      final p = await _newPortfolio();
      if (p != null) await library.move([info], p.id);
      return;
    }
    await library.move([info], choice);
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
      case _Action.move:
        await _move(info);
      case _Action.exportSvg:
        await exportSvg(context, info.drawing, info.name);
      case _Action.exportInkpad:
        await exportInkpad(context, info.drawing, info.name);
      case _Action.delete:
        final ok = await _confirm(
          title: 'Delete "${info.name}"?',
          message: 'This drawing will be permanently removed from your library.',
          action: 'Delete',
        );
        if (ok == true) await library.delete(info);
    }
  }

  Future<void> _renamePortfolio(PortfolioInfo p) async {
    final name = await promptForText(context, title: 'Rename portfolio', initial: p.name);
    if (name != null) await library.renamePortfolio(p, name);
  }

  Future<void> _performOnPortfolio(_PortfolioAction action, PortfolioInfo p) async {
    switch (action) {
      case _PortfolioAction.open:
        await _openPortfolio(p);
      case _PortfolioAction.rename:
        await _renamePortfolio(p);
      case _PortfolioAction.delete:
        final count = library.drawingsIn(p.id).length;
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete the portfolio "${p.name}"?'),
            content: Text(count == 0
                ? 'It has no drawings.'
                : 'Its ${count == 1 ? 'drawing goes' : '$count drawings go'} back to the gallery, unless you delete '
                    '${count == 1 ? 'it' : 'them'} too.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              if (count > 0)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () => Navigator.pop(context, 'all'),
                  child: Text(count == 1 ? 'Delete drawing too' : 'Delete drawings too'),
                ),
              FilledButton(onPressed: () => Navigator.pop(context, 'keep'), child: Text(count == 0 ? 'Delete' : 'Keep drawings')),
            ],
          ),
        );
        if (choice == null) return;
        await library.deletePortfolio(p, deleteDrawings: choice == 'all');
        // Leave a portfolio that no longer exists.
        if (mounted && identical(p, portfolio)) Navigator.of(context).pop();
    }
  }

  Future<bool?> _confirm({required String title, required String message, required String action}) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([library, _search]),
      builder: (context, _) {
        final error = library.error;
        if (error != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || library.error == null) return;
            showSnack(context, library.error!);
            library.error = null;
          });
        }
        final p = portfolio;
        return Scaffold(
          appBar: AppBar(
            title: p == null
                ? const Text('Gallery')
                : Tooltip(
                    message: 'Rename portfolio',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _renamePortfolio(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 6),
                          const Icon(Icons.edit_outlined, size: 18),
                        ]),
                      ),
                    ),
                  ),
            actions: [
              if (p == null)
                IconButton(
                  tooltip: 'New portfolio',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: _newPortfolio,
                ),
              IconButton(
                tooltip: 'Import SVG or .inkpad files',
                icon: const Icon(Icons.file_open_outlined),
                onPressed: _import,
              ),
              if (p != null)
                PopupMenuButton<_PortfolioAction>(
                  tooltip: 'Portfolio',
                  onSelected: (a) => _performOnPortfolio(a, p),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: _PortfolioAction.rename, child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Rename…'), dense: true)),
                    PopupMenuItem(value: _PortfolioAction.delete, child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete…'), dense: true)),
                  ],
                ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(60),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: SearchBar(
                  controller: _search,
                  hintText: p == null ? 'Search drawings and portfolios' : 'Search in ${p.name}',
                  leading: const Icon(Icons.search),
                  trailing: [
                    if (query.isNotEmpty)
                      IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close), onPressed: _search.clear),
                  ],
                  elevation: const WidgetStatePropertyAll(0),
                  constraints: const BoxConstraints(minHeight: 46, maxHeight: 46),
                ),
              ),
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _newDrawing,
            icon: const Icon(Icons.add),
            label: const Text('New drawing'),
          ),
          body: !library.loaded ? const Center(child: CircularProgressIndicator()) : _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final p = portfolio;
    final searching = query.isNotEmpty;
    // In the gallery, a search looks in every portfolio too.
    final drawings = searching ? library.search(query, within: p?.id, everywhere: p == null) : library.drawingsIn(p?.id);
    final portfolios = p != null ? <PortfolioInfo>[] : (searching ? library.searchPortfolios(query) : library.portfolios);

    if (drawings.isEmpty && portfolios.isEmpty) {
      return searching
          ? _message(context, Icons.search_off, 'Nothing matches “$query”', 'Try another name, or a word that appears in a drawing.')
          : p != null
              ? _message(context, Icons.folder_open_outlined, 'This portfolio is empty',
                  'Tap “New drawing”, or move drawings here from the gallery.')
              : _message(context, Icons.draw_outlined, 'No drawings yet', 'Tap “New drawing” to start one.');
    }

    const grid = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 220,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 0.72,
    );
    Widget heading(String text) => SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(text, style: Theme.of(context).textTheme.titleSmall),
          ),
        );
    return CustomScrollView(slivers: [
      if (portfolios.isNotEmpty) ...[
        heading('Portfolios'),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          sliver: SliverGrid.builder(
            gridDelegate: grid,
            itemCount: portfolios.length,
            itemBuilder: (context, i) {
              final pf = portfolios[i];
              return _PortfolioCard(
                key: ValueKey('portfolio-${pf.id}'),
                portfolio: pf,
                library: library,
                onOpen: () => _openPortfolio(pf),
                onAction: (a) => _performOnPortfolio(a, pf),
                onDrop: (d) => library.move([d], pf.id),
              );
            },
          ),
        ),
      ],
      if (drawings.isNotEmpty) ...[
        if (portfolios.isNotEmpty || searching) heading(searching ? 'Drawings' : 'Not in a portfolio'),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          sliver: SliverGrid.builder(
            gridDelegate: grid,
            itemCount: drawings.length,
            itemBuilder: (context, i) {
              final info = drawings[i];
              // In search results, say which portfolio a drawing is in.
              final where = searching && info.portfolio != p?.id ? library.portfolioById(info.portfolio)?.name : null;
              return _DrawingCard(
                key: ValueKey(info.id),
                info: info,
                portfolioName: where,
                onOpen: () => _open(info),
                onAction: (a) => _perform(a, info),
              );
            },
          ),
        ),
      ] else
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
    ]);
  }

  Widget _message(BuildContext context, IconData icon, String title, String detail) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(detail, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// A portfolio: its newest drawings in a 2×2 mosaic. Drop a drawing on it
/// to move the drawing in.
class _PortfolioCard extends StatelessWidget {
  final PortfolioInfo portfolio;
  final LibraryController library;
  final VoidCallback onOpen;
  final ValueChanged<_PortfolioAction> onAction;
  final ValueChanged<DrawingInfo> onDrop;

  const _PortfolioCard({
    super.key,
    required this.portfolio,
    required this.library,
    required this.onOpen,
    required this.onAction,
    required this.onDrop,
  });

  static const _items = [
    (_PortfolioAction.open, 'Open', Icons.folder_open_outlined),
    (_PortfolioAction.rename, 'Rename…', Icons.drive_file_rename_outline),
    (_PortfolioAction.delete, 'Delete…', Icons.delete_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final members = library.drawingsIn(portfolio.id);
    final count = members.length;
    return DragTarget<DrawingInfo>(
      onWillAcceptWithDetails: (d) => d.data.portfolio != portfolio.id,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) => Card.outlined(
        clipBehavior: Clip.antiAlias,
        shape: candidates.isEmpty
            ? null
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.primary, width: 3),
              ),
        child: InkWell(
          onTap: onOpen,
          onSecondaryTapUp: (d) => _showMenuAt(context, d.globalPosition, _items, onAction),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  color: theme.colorScheme.secondaryContainer,
                  padding: const EdgeInsets.all(8),
                  child: count == 0
                      ? Icon(Icons.folder_outlined, size: 56, color: theme.colorScheme.onSecondaryContainer)
                      : GridView.count(
                          crossAxisCount: 2,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            for (final d in members.take(4))
                              Container(
                                color: theme.colorScheme.surface,
                                padding: const EdgeInsets.all(4),
                                child: DrawingThumbnail(drawing: d.drawing),
                              ),
                          ],
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
                child: Row(children: [
                  Icon(Icons.folder_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(portfolio.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                        Text(count == 1 ? '1 drawing' : '$count drawings', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  PopupMenuButton<_PortfolioAction>(
                    tooltip: 'More',
                    onSelected: onAction,
                    itemBuilder: (_) => _menuItems(_items),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<PopupMenuEntry<T>> _menuItems<T>(List<(T, String, IconData)> items) => [
      for (final (a, label, icon) in items)
        PopupMenuItem(value: a, child: ListTile(leading: Icon(icon), title: Text(label), dense: true)),
    ];

Future<void> _showMenuAt<T>(BuildContext context, Offset globalPosition, List<(T, String, IconData)> items, ValueChanged<T> onAction) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final action = await showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
    items: _menuItems(items),
  );
  if (action != null) onAction(action);
}

class _DrawingCard extends StatelessWidget {
  final DrawingInfo info;

  /// The portfolio it's in, shown in search results.
  final String? portfolioName;
  final VoidCallback onOpen;
  final ValueChanged<_Action> onAction;

  const _DrawingCard({super.key, required this.info, this.portfolioName, required this.onOpen, required this.onAction});

  static const _items = [
    (_Action.open, 'Open', Icons.edit_outlined),
    (_Action.rename, 'Rename…', Icons.drive_file_rename_outline),
    (_Action.duplicate, 'Duplicate', Icons.copy_outlined),
    (_Action.move, 'Move to Portfolio…', Icons.drive_file_move_outline),
    (_Action.exportSvg, 'Export SVG…', Icons.ios_share),
    (_Action.exportInkpad, 'Export .inkpad…', Icons.save_alt),
    (_Action.delete, 'Delete…', Icons.delete_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = Card.outlined(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onSecondaryTapUp: (d) => _showMenuAt(context, d.globalPosition, _items, onAction),
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
                        Text(
                          portfolioName == null ? _describeDate(info.modified) : 'In $portfolioName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<_Action>(
                    tooltip: 'More',
                    onSelected: onAction,
                    itemBuilder: (_) => _menuItems(_items),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // Press and hold, then drag onto a portfolio to move it there.
    return LongPressDraggable<DrawingInfo>(
      data: info,
      feedback: SizedBox(
        width: 140,
        height: 180,
        child: Material(elevation: 8, borderRadius: BorderRadius.circular(12), clipBehavior: Clip.antiAlias, child: card),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
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
