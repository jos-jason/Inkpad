import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/drawing_controller.dart';
import '../library/drawing_store.dart';
import '../library/library_controller.dart';
import '../model/drawing.dart';
import '../tools/tool.dart';
import 'drawing_canvas.dart';
import 'file_actions.dart';
import 'inspector.dart';

class _ToolEntry {
  final Tool tool;
  final IconData icon;
  final String shortcut;
  const _ToolEntry(this.tool, this.icon, this.shortcut);
}

class EditorPage extends StatefulWidget {
  final LibraryController library;
  final DrawingInfo info;

  const EditorPage({super.key, required this.library, required this.info});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  // The editor works on its own copy; the library only ever receives
  // snapshots, so its thumbnails always match what was saved.
  late final controller = DrawingController(drawing: InkDrawing.decode(widget.info.drawing.encode(includeImages: false)));
  final canvasKey = GlobalKey<DrawingCanvasState>();

  // Autosave: edits are written to the library shortly after they happen,
  // when leaving the editor, and when the app is backgrounded.
  static const _autosaveDelay = Duration(milliseconds: 800);
  Timer? _autosave;
  late String _lastSaved;
  late final AppLifecycleListener _lifecycle;

  late final List<_ToolEntry> tools = [
    _ToolEntry(controller.tool, Icons.near_me_outlined, 'V'),
    _ToolEntry(PenTool(), Icons.edit_outlined, 'P'),
    _ToolEntry(AnchorTool(), Icons.control_point, 'A'),
    _ToolEntry(ShapeTool(ShapeKind.rectangle), Icons.crop_square, 'R'),
    _ToolEntry(ShapeTool(ShapeKind.oval), Icons.circle_outlined, 'E'),
    _ToolEntry(ShapeTool(ShapeKind.star), Icons.star_outline, 'S'),
    _ToolEntry(ShapeTool(ShapeKind.polygon), Icons.hexagon_outlined, 'G'),
    _ToolEntry(ShapeTool(ShapeKind.line), Icons.horizontal_rule, 'L'),
    _ToolEntry(HandTool(), Icons.pan_tool_outlined, 'H'),
  ];

  DrawingCanvasState? get canvas => canvasKey.currentState;

  @override
  void initState() {
    super.initState();
    _lastSaved = controller.drawing.encode(includeImages: false);
    controller.addListener(_scheduleAutosave);
    _lifecycle = AppLifecycleListener(onHide: _saveNow, onPause: _saveNow);
  }

  @override
  void dispose() {
    // Defer the final save: it notifies the library page, which mustn't
    // rebuild while this page is being torn down.
    _autosave?.cancel();
    final encoded = controller.drawing.encode(includeImages: false);
    if (encoded != _lastSaved) {
      Future.microtask(() => widget.library.saveEdits(widget.info, InkDrawing.decode(encoded)));
    }
    _lifecycle.dispose();
    controller.dispose();
    super.dispose();
  }

  void _scheduleAutosave() {
    _autosave?.cancel();
    _autosave = Timer(_autosaveDelay, _saveNow);
  }

  void _saveNow() {
    _autosave?.cancel();
    final encoded = controller.drawing.encode(includeImages: false);
    if (encoded == _lastSaved) return;
    _lastSaved = encoded;
    widget.library.saveEdits(widget.info, InkDrawing.decode(encoded));
  }

  /// Ported from Inkpad's "Place Photo".
  Future<void> _placeImage() async {
    final files = await pickImageFiles(context);
    final unsupported = [
      for (final (name, bytes) in files)
        if (!controller.placeImage(bytes)) name,
    ];
    if (unsupported.isNotEmpty && mounted) {
      showSnack(context, '${unsupported.join(', ')}: not a supported image (PNG, JPEG, GIF, WebP or BMP)');
    }
  }

  Future<void> _placeSvg() async {
    final files = await pickDrawingFiles(context, inkpad: false);
    for (final f in files) {
      controller.place(f.drawing);
    }
    if (mounted) reportImport(context, files);
  }

  Future<void> _rename() async {
    final name = await promptForText(context, title: 'Rename drawing', initial: widget.info.name);
    if (name == null) return;
    await widget.library.rename(widget.info, name);
    setState(() {});
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final c = controller;
    final map = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.delete): c.deleteSelection,
      const SingleActivator(LogicalKeyboardKey.backspace): c.deleteSelection,
      const SingleActivator(LogicalKeyboardKey.escape): () {
        c.finishActivePath();
        c.selectNone();
      },
      const SingleActivator(LogicalKeyboardKey.enter): c.finishActivePath,
      const SingleActivator(LogicalKeyboardKey.equal): () => canvas?.zoomBy(1.25),
      const SingleActivator(LogicalKeyboardKey.minus): () => canvas?.zoomBy(0.8),
      const SingleActivator(LogicalKeyboardKey.digit0): () => canvas?.fitToScreen(),
      const SingleActivator(LogicalKeyboardKey.digit1): () => canvas?.actualSize(),
    };
    for (final t in tools) {
      map[SingleActivator(LogicalKeyboardKey(t.shortcut.toLowerCase().codeUnitAt(0)))] =
          () => c.tool = t.tool;
    }
    // Both Ctrl (Linux/Windows/Android) and Cmd (Apple) modifiers.
    for (final meta in [true, false]) {
      SingleActivator k(LogicalKeyboardKey key, {bool shift = false}) =>
          SingleActivator(key, meta: meta, control: !meta, shift: shift);
      map.addAll({
        k(LogicalKeyboardKey.keyZ): c.undo,
        k(LogicalKeyboardKey.keyZ, shift: true): c.redo,
        k(LogicalKeyboardKey.keyY): c.redo,
        k(LogicalKeyboardKey.keyA): c.selectAll,
        k(LogicalKeyboardKey.keyD): c.duplicateSelection,
        k(LogicalKeyboardKey.keyG): c.groupSelection,
        k(LogicalKeyboardKey.keyG, shift: true): c.ungroupSelection,
        k(LogicalKeyboardKey.bracketRight, shift: true): c.bringToFront,
        k(LogicalKeyboardKey.bracketLeft, shift: true): c.sendToBack,
        k(LogicalKeyboardKey.digit7): c.makeMask,
        k(LogicalKeyboardKey.digit7, shift: true): c.releaseMask,
        k(LogicalKeyboardKey.keyS): _saveNow,
        k(LogicalKeyboardKey.keyE): () => exportSvg(context, c.drawing, widget.info.name),
        k(LogicalKeyboardKey.keyP, shift: true): _placeImage,
      });
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return CallbackShortcuts(
          bindings: _shortcuts,
          child: Focus(
            autofocus: true,
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final canvasWidget = DrawingCanvas(key: canvasKey, controller: controller);
              return Scaffold(
                appBar: _appBar(context, wide),
                body: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _toolRail(vertical: true),
                          const VerticalDivider(width: 1),
                          Expanded(child: canvasWidget),
                          const VerticalDivider(width: 1),
                          SizedBox(width: 300, child: Inspector(controller: controller)),
                        ],
                      )
                    : canvasWidget,
                bottomNavigationBar: wide ? null : SafeArea(child: _toolRail(vertical: false)),
              );
            }),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(BuildContext context, bool wide) {
    final c = controller;
    final hasSel = c.selection.isNotEmpty;
    return AppBar(
      title: Tooltip(
        message: 'Rename',
        child: InkWell(
          onTap: _rename,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(widget.info.name, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
      actions: [
        IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: c.canUndo ? c.undo : null),
        IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: c.canRedo ? c.redo : null),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: hasSel ? c.deleteSelection : null,
        ),
        IconButton(
          tooltip: 'Place image',
          icon: const Icon(Icons.add_photo_alternate_outlined),
          onPressed: _placeImage,
        ),
        IconButton(
          tooltip: 'Fit to screen',
          icon: const Icon(Icons.fit_screen_outlined),
          onPressed: () => canvas?.fitToScreen(),
        ),
        if (!wide)
          IconButton(
            tooltip: 'Style & layers',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => showModalBottomSheet(
              context: context,
              showDragHandle: true,
              builder: (_) => SizedBox(height: 420, child: Inspector(controller: c)),
            ),
          ),
        PopupMenuButton<VoidCallback>(
          tooltip: 'More',
          onSelected: (action) => action(),
          itemBuilder: (context) => [
            PopupMenuItem(value: _rename, child: const Text('Rename…')),
            PopupMenuItem(value: _placeImage, child: const Text('Place image…')),
            PopupMenuItem(value: _placeSvg, child: const Text('Place SVG…')),
            PopupMenuItem(
                value: () => exportSvg(context, c.drawing, widget.info.name), child: const Text('Export SVG…')),
            PopupMenuItem(
                value: () => exportInkpad(context, c.drawing, widget.info.name),
                child: const Text('Export .inkpad…')),
            PopupMenuItem(value: () => copySvg(context, c.drawing), child: const Text('Copy SVG')),
            const PopupMenuDivider(),
            PopupMenuItem(value: c.selectAll, child: const Text('Select all')),
            PopupMenuItem(enabled: hasSel, value: c.duplicateSelection, child: const Text('Duplicate')),
            PopupMenuItem(enabled: c.selection.length > 1, value: c.groupSelection, child: const Text('Group')),
            PopupMenuItem(enabled: hasSel, value: c.ungroupSelection, child: const Text('Ungroup')),
            PopupMenuItem(enabled: hasSel, value: c.bringToFront, child: const Text('Bring to front')),
            PopupMenuItem(enabled: hasSel, value: c.sendToBack, child: const Text('Send to back')),
            const PopupMenuDivider(),
            PopupMenuItem(enabled: c.canMakeMask, value: c.makeMask, child: const Text('Make clipping mask')),
            PopupMenuItem(enabled: c.canReleaseMask, value: c.releaseMask, child: const Text('Release clipping mask')),
          ],
        ),
      ],
    );
  }

  Widget _toolRail({required bool vertical}) {
    final buttons = [
      for (final t in tools)
        IconButton(
          tooltip: '${t.tool.name} (${t.shortcut})',
          isSelected: identical(controller.tool, t.tool),
          icon: Icon(t.icon),
          style: IconButton.styleFrom(
            backgroundColor: identical(controller.tool, t.tool)
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
          ),
          onPressed: () => controller.tool = t.tool,
        ),
    ];
    return vertical
        ? SizedBox(
            width: 56,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(spacing: 4, children: buttons),
            ),
          )
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(spacing: 4, children: buttons),
          );
  }
}
