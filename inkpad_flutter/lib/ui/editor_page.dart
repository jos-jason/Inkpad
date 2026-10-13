import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/drawing_controller.dart';
import '../library/drawing_store.dart';
import '../library/library_controller.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../geometry/pathfinder.dart';
import '../model/style.dart';
import '../tools/tool.dart';
import 'ai/ai_panel.dart';
import 'chrome/chrome.dart';
import 'make/cut_panel.dart';
import 'make/dimension_overlay.dart';
import 'make/gcode_dialog.dart';
import 'make/make_dialogs.dart';
import 'make/numbers_bar.dart';
import 'chrome/color_editor.dart';
import 'chrome/rulers.dart';
import 'chrome/tool_icons.dart';
import 'chrome/tool_palette.dart';
import 'drawing_canvas.dart';
import 'file_actions.dart';
import 'panels/color_adjust_panels.dart';
import 'panels/fill_panel.dart';
import 'panels/layers_panel.dart';
import 'panels/misc_panels.dart';
import 'panels/shadow_panel.dart';
import 'panels/stroke_panel.dart';
import 'panels/text_panel.dart';
import 'text_editor_overlay.dart';

/// The drawing editor: a full-screen canvas with rulers and floating
/// panels, modelled on Inkpad's iPad interface (WDCanvasController).
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
  final view = CanvasView();

  // Autosave: edits are written to the library shortly after they happen,
  // when leaving the editor, and when the app is backgrounded.
  static const _autosaveDelay = Duration(milliseconds: 800);
  Timer? _autosave;
  late String _lastSaved;
  late final AppLifecycleListener _lifecycle;

  // ---- Tools ---------------------------------------------------------------

  late final _select = controller.tool;
  final _direct = DirectSelectTool();
  final _pen = PenTool();
  final _anchor = AnchorTool();
  final _rect = ShapeTool(ShapeKind.rectangle);
  final _oval = ShapeTool(ShapeKind.oval);
  final _star = ShapeTool(ShapeKind.star);
  final _polygon = ShapeTool(ShapeKind.polygon);
  final _line = ShapeTool(ShapeKind.line);
  final _spiral = ShapeTool(ShapeKind.spiral);
  final _freehand = FreehandTool(closeShape: true);
  final _brush = FreehandTool(closeShape: false);
  final _eraser = EraserTool();
  final _scissors = ScissorsTool();
  final _eyedropper = EyedropperTool();
  final _scale = ScaleTool();
  final _rotate = RotateTool();
  final _text = TextTool();
  final _measure = MeasureTool();
  final _joinery = JoineryTool();
  final _hand = HandTool();

  late final _shapes = PaletteGroup([
    PaletteTool('Rectangle', const Icon(Icons.crop_square), _rect, shortcut: 'R'),
    PaletteTool('Oval', const Icon(Icons.circle_outlined), _oval, shortcut: 'E'),
    PaletteTool('Star', const Icon(Icons.star_outline), _star, shortcut: 'S'),
    PaletteTool('Polygon', const Icon(Icons.pentagon_outlined), _polygon, shortcut: 'G'),
    PaletteTool('Spiral', const ToolIcon(ToolIcon.spiral), _spiral),
    PaletteTool('Line', const ToolIcon(ToolIcon.line), _line, shortcut: 'L'),
  ]);

  late final _freehandGroup = PaletteGroup([
    PaletteTool('Brush', const Icon(Icons.brush), _brush, shortcut: 'B'),
    PaletteTool('Freehand', const ToolIcon(ToolIcon.blob), _freehand, shortcut: 'F'),
  ])
    ..current = 1;

  late final List<Object> _palette = [
    PaletteTool('Select', const ToolIcon(ToolIcon.arrow), _select, shortcut: 'V'),
    PaletteTool('Direct Select', const ToolIcon(ToolIcon.directSelect), _direct, shortcut: 'A'),
    PaletteTool('Pen', const ToolIcon(ToolIcon.pen), _pen, shortcut: 'P'),
    PaletteTool('Add/Delete Point', const ToolIcon(ToolIcon.addAnchor), _anchor, shortcut: 'N'),
    PaletteTool('Scissors', const Icon(Icons.content_cut), _scissors, shortcut: 'C'),
    _freehandGroup,
    PaletteTool('Eraser', const ToolIcon(ToolIcon.eraser), _eraser, shortcut: '⇧E'),
    _shapes,
    PaletteTool('Text', const ToolIcon(ToolIcon.text), _text, shortcut: 'T'),
    PaletteTool('Eyedropper', const Icon(Icons.colorize), _eyedropper, shortcut: 'I'),
    PaletteTool('Measure', const Icon(Icons.straighten), _measure, shortcut: 'M'),
    PaletteTool('Joinery', const Icon(Icons.extension_outlined), _joinery, shortcut: 'J'),
    PaletteTool('Scale', const ToolIcon(ToolIcon.scale), _scale, shortcut: 'K'),
    PaletteTool('Rotate', const ToolIcon(ToolIcon.rotate), _rotate, shortcut: 'O'),
  ];

  DrawingCanvasState? get canvas => canvasKey.currentState;

  // Keyboard shortcuts listen here; it gets the keyboard back after typing.
  final _keys = FocusNode(debugLabel: 'editor shortcuts');
  bool _wasEditing = false;

  void _askJoint() {
    final target = controller.jointRequest.value;
    if (target == null || !mounted) return;
    controller.jointRequest.value = null;
    showJointDialog(context, controller, target);
  }

  void _showHint() {
    final message = controller.hint.value;
    if (message == null || !mounted) return;
    controller.hint.value = null;
    showSnack(context, message);
  }

  void _onEditingChanged() {
    final editing = controller.editingText != null;
    if (_wasEditing && !editing) {
      // After the text field has gone, so it can't take the focus with it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.editingText == null) _keys.requestFocus();
      });
    }
    _wasEditing = editing;
  }

  @override
  void initState() {
    super.initState();
    _lastSaved = controller.drawing.encode(includeImages: false);
    controller.addListener(_scheduleAutosave);
    controller.addListener(_onEditingChanged);
    controller.hint.addListener(_showHint);
    controller.jointRequest.addListener(_askJoint);
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
    view.dispose();
    _keys.dispose();
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

  void _setTool(Tool t) {
    for (final group in [_shapes, _freehandGroup]) {
      for (final (i, v) in group.variants.indexed) {
        if (identical(v.tool, t)) group.current = i;
      }
    }
    controller.tool = t;
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final c = controller;
    // Typing text: letters are text, not tool shortcuts.
    if (c.editingText != null) return const {};
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
    final shortcutTools = <String, Tool>{
      'V': _select, 'A': _direct, 'P': _pen, 'N': _anchor, 'R': _rect, 'E': _oval, 'S': _star, 'G': _polygon, 'L': _line,
      'K': _scale, 'O': _rotate, 'H': _hand, 'C': _scissors, 'B': _brush, 'F': _freehand, 'I': _eyedropper, 'T': _text, 'M': _measure, 'J': _joinery,
    };
    map[const SingleActivator(LogicalKeyboardKey.keyE, shift: true)] = () => _setTool(_eraser);
    for (final MapEntry(key: letter, value: tool) in shortcutTools.entries) {
      map[SingleActivator(LogicalKeyboardKey(letter.toLowerCase().codeUnitAt(0)))] = () => _setTool(tool);
    }
    // Both Ctrl (Linux/Windows/Android) and Cmd (Apple) modifiers.
    for (final meta in [true, false]) {
      SingleActivator k(LogicalKeyboardKey key, {bool shift = false, bool alt = false}) =>
          SingleActivator(key, meta: meta, control: !meta, shift: shift, alt: alt);
      map.addAll({
        k(LogicalKeyboardKey.keyZ): c.undo,
        k(LogicalKeyboardKey.keyZ, shift: true): c.redo,
        k(LogicalKeyboardKey.keyY): c.redo,
        k(LogicalKeyboardKey.keyA): c.selectAll,
        k(LogicalKeyboardKey.keyA, shift: true): c.selectNone,
        k(LogicalKeyboardKey.keyX): c.cutSelection,
        k(LogicalKeyboardKey.keyC): c.copySelection,
        k(LogicalKeyboardKey.keyV): c.paste,
        k(LogicalKeyboardKey.keyD): c.duplicateSelection,
        k(LogicalKeyboardKey.keyD, shift: true): c.duplicateAndTransformAgain,
        k(LogicalKeyboardKey.keyT, shift: true): c.transformAgain,
        k(LogicalKeyboardKey.keyG): c.groupSelection,
        k(LogicalKeyboardKey.keyG, shift: true): c.ungroupSelection,
        k(LogicalKeyboardKey.bracketRight): c.bringForward,
        k(LogicalKeyboardKey.bracketLeft): c.sendBackward,
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

  // ---- Menus (ported from Inkpad's Edit / Arrange / Path menus) -----------

  List<MenuEntry> _editMenu() {
    final c = controller;
    final sel = c.selection.isNotEmpty;
    final again = sel && c.lastTransform != null;
    return [
      MenuAction('Select All', c.selectAll),
      MenuAction('Select All in Layer', c.selectAllInLayer),
      MenuAction('Deselect All', sel ? c.selectNone : null),
      const MenuDivider(),
      MenuAction('Cut', sel ? c.cutSelection : null),
      MenuAction('Copy', sel ? c.copySelection : null),
      MenuAction('Paste', c.canPaste ? c.paste : null),
      const MenuDivider(),
      MenuAction('Duplicate', sel ? c.duplicateSelection : null),
      MenuAction('Duplicate in Place', sel ? c.duplicateInPlace : null),
      const MenuDivider(),
      MenuAction('Transform Again', again ? c.transformAgain : null),
      MenuAction('Duplicate and Transform Again', again ? c.duplicateAndTransformAgain : null),
      MenuAction('Repeat…', sel ? () => showRepeatDialog(context, c) : null),
      const MenuDivider(),
      MenuAction('Delete', sel ? c.deleteSelection : null),
    ];
  }

  List<MenuEntry> _arrangeMenu() {
    final c = controller;
    final sel = c.selection.isNotEmpty;
    MenuAction align(String label, AlignEdge edge, IconData icon) =>
        MenuAction(label, sel ? () => c.align(edge) : null, trailing: Icon(icon));
    return [
      MenuAction('Bring Forward', sel ? c.bringForward : null),
      MenuAction('Bring to Front', sel ? c.bringToFront : null),
      MenuAction('Send Backward', sel ? c.sendBackward : null),
      MenuAction('Send to Back', sel ? c.sendToBack : null),
      const MenuDivider(),
      MenuAction('Flip Horizontally', sel ? () => c.flipSelection(horizontal: true) : null),
      MenuAction('Flip Vertically', sel ? () => c.flipSelection(horizontal: false) : null),
      MenuAction('Rotate 90° Left', sel ? () => c.rotateSelection(-90) : null),
      MenuAction('Rotate 90° Right', sel ? () => c.rotateSelection(90) : null),
      const MenuDivider(),
      MenuAction('Distribute Horizontally', c.selection.length > 2 ? () => c.distribute(horizontal: true) : null),
      MenuAction('Distribute Vertically', c.selection.length > 2 ? () => c.distribute(horizontal: false) : null),
      const MenuDivider(),
      MenuAction('Group', c.selection.length > 1 ? c.groupSelection : null),
      MenuAction('Ungroup', c.selection.any((e) => e is InkGroup) ? c.ungroupSelection : null),
      const MenuDivider(),
      align('Align Left', AlignEdge.left, Icons.align_horizontal_left),
      align('Align Center', AlignEdge.center, Icons.align_horizontal_center),
      align('Align Right', AlignEdge.right, Icons.align_horizontal_right),
      const MenuDivider(),
      align('Align Top', AlignEdge.top, Icons.align_vertical_top),
      align('Align Middle', AlignEdge.middle, Icons.align_vertical_center),
      align('Align Bottom', AlignEdge.bottom, Icons.align_vertical_bottom),
    ];
  }

  List<MenuEntry> _pathMenu() {
    final c = controller;
    MenuAction shapes(String label, BooleanOp op) => MenuAction(label, c.canCombineShapes ? () => _combine(op) : null);
    return [
      if (c.drawing.makeMode || c.canConvertToPaths) ...[
        MenuAction('Convert to Path', c.canConvertToPaths ? c.convertToPaths : null),
        const MenuDivider(),
      ],
      MenuAction('Offset Path…', c.canOffsetPaths ? () => showOffsetDialog(context, c) : null),
      if (c.drawing.makeMode) ...[
        MenuAction('Add Dogbones', c.canAddDogbones ? c.addDogbones : null),
        MenuAction('Add T-bones', c.canAddDogbones ? () => c.addDogbones(tBone: true) : null),
        MenuAction('Box Maker…', () => showBoxMakerDialog(context, c)),
      ],
      const MenuDivider(),
      MenuAction('Add Anchor Points', c.canAddAnchors ? c.addAnchorPoints : null),
      MenuAction('Delete Anchor Points', c.canDeleteAnchors ? c.deleteSelectedAnchors : null),
      MenuAction('Join Paths', c.canJoinPaths ? c.joinPaths : null),
      MenuAction('Outline Stroke', c.canOutlineStroke ? c.outlineStroke : null),
      const MenuDivider(),
      MenuAction('Combine Paths', c.canCombinePaths ? c.combinePaths : null),
      MenuAction('Separate Paths', c.canSeparatePaths ? c.separatePaths : null),
      MenuAction('Reverse Path Direction', c.canReversePaths ? c.reversePaths : null),
      const MenuDivider(),
      shapes('Unite', BooleanOp.unite),
      shapes('Intersect', BooleanOp.intersect),
      shapes('Subtract Front', BooleanOp.subtractFront),
      shapes('Exclude', BooleanOp.exclude),
      const MenuDivider(),
      MenuAction('Mask', c.canMakeMask ? c.makeMask : null),
      MenuAction('Unmask', c.canReleaseMask ? c.releaseMask : null),
      const MenuDivider(),
      MenuAction('Create Outlines from Text', c.canCreateOutlines ? c.createOutlines : null),
      MenuAction('Place Text on Path', c.canPlaceTextOnPath ? c.placeTextOnPath : null),
    ];
  }

  /// Ported from Inkpad's color menu (WDCanvasController showColorMenu:).
  List<MenuEntry> _colorMenu() {
    final c = controller;
    MenuAction blend(String label, ColorBlend d) => MenuAction(label, c.canBlendColors(d) ? () => c.blendColors(d) : null);
    void adjust(Widget panel) => WidgetsBinding.instance.addPostFrameCallback((_) {
          // After the menu closes, from the same button.
          if (mounted) _panel(_colorButton.currentContext ?? context, panel, width: 420);
        });
    return [
      blend('Blend Back to Front', ColorBlend.backToFront),
      blend('Blend Horizontally', ColorBlend.horizontally),
      blend('Blend Vertically', ColorBlend.vertically),
      const MenuDivider(),
      MenuAction('Color Balance…', c.canAdjustColors ? () => adjust(ColorBalancePanel(controller: c)) : null),
      MenuAction('Hue and Saturation…', c.canAdjustColors ? () => adjust(HueSaturationPanel(controller: c)) : null),
      const MenuDivider(),
      MenuAction('Desaturate', c.canAdjustColors ? c.desaturate : null),
      MenuAction('Invert', c.canAdjustColors ? c.invertColors : null),
    ];
  }

  final _colorButton = GlobalKey();

  void _combine(BooleanOp op) {
    final before = controller.selection.length;
    controller.combineShapes(op);
    if (before > 1 && controller.selection.isEmpty && mounted) {
      showSnack(context, 'Nothing was left after that operation');
    }
  }

  void _menu(BuildContext anchor, List<MenuEntry> Function() entries, {PopoverSide side = PopoverSide.above}) =>
      showPopover<void>(anchor: anchor, width: 340, side: side, builder: (_) => MenuPanel(entries()));

  void _panel(BuildContext anchor, Widget panel, {double width = 440, PopoverSide side = PopoverSide.above}) =>
      showPopover<void>(anchor: anchor, width: width, side: side, builder: (_) => panel);

  // ---- Layout ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final compact = isCompact(context);
        final rulers = controller.drawing.showRulers;
        final padding = MediaQuery.paddingOf(context);
        final canvasWidget = DrawingCanvas(
          key: canvasKey,
          controller: controller,
          view: view,
          fitPadding: EdgeInsets.fromLTRB(compact ? 70 : 80, 60 + padding.top, 12, 76 + padding.bottom),
        );
        return CallbackShortcuts(
          bindings: _shortcuts,
          child: Focus(
            focusNode: _keys,
            autofocus: true,
            child: Scaffold(
              body: Stack(children: [
                Positioned.fill(
                  child: Column(children: [
                    if (rulers)
                      Row(children: [
                        Container(
                          width: Ruler.thickness,
                          height: Ruler.thickness,
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        ),
                        Expanded(child: Ruler(view: view, drawing: controller.drawing, axis: Axis.horizontal)),
                      ]),
                    Expanded(
                      child: Row(children: [
                        if (rulers) Ruler(view: view, drawing: controller.drawing, axis: Axis.vertical),
                        Expanded(child: canvasWidget),
                      ]),
                    ),
                  ]),
                ),
                if (controller.drawing.makeMode)
                  Positioned.fill(
                    child: DimensionOverlay(
                      controller: controller,
                      view: view,
                      origin: rulers ? const Offset(Ruler.thickness, Ruler.thickness) : Offset.zero,
                    ),
                  ),
                if (controller.editingText != null)
                  Positioned.fill(
                    child: TextEditorOverlay(
                      key: ObjectKey(controller.editingText),
                      controller: controller,
                      view: view,
                      origin: rulers ? const Offset(Ruler.thickness, Ruler.thickness) : Offset.zero,
                    ),
                  ),
                SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(rulers ? 30 : 12, 12, 12, 12),
                    child: Stack(children: [
                      if (compact)
                        // Phones: the top bar shares the width instead of overlapping.
                        Align(
                          alignment: Alignment.topCenter,
                          child: Row(children: [
                            _galleryButton(compact),
                            const SizedBox(width: 8),
                            Flexible(child: Align(alignment: Alignment.centerLeft, heightFactor: 1, child: _titlePill(compact))),
                            const SizedBox(width: 8),
                            _compactTopRight(),
                          ]),
                        )
                      else ...[
                        Align(alignment: Alignment.topLeft, child: _galleryButton(compact)),
                        Align(alignment: Alignment.topCenter, child: _titlePill(compact)),
                        Align(alignment: Alignment.topRight, child: _topRight()),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 64),
                          child: ToolPalette(controller: controller, items: _palette),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 72),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            _toolOptions(),
                            if (controller.drawing.makeMode && controller.selection.isNotEmpty && controller.editingText == null)
                              Padding(padding: const EdgeInsets.only(top: 8), child: NumbersBar(controller: controller)),
                          ]),
                        ),
                      ),
                      if (compact)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: _menusPill(compact))),
                            const SizedBox(width: 8),
                            Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: _stylePill(compact))),
                          ]),
                        )
                      else
                        // Undo stays centered; the side pills shrink if the
                        // window is too narrow for all three.
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomLeft,
                                child: FittedBox(fit: BoxFit.scaleDown, child: _menusPill(compact)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _undoPill(),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomRight,
                                child: FittedBox(fit: BoxFit.scaleDown, child: _stylePill(compact)),
                              ),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _galleryButton(bool compact) => Pill(
        child: compact
            ? IconButton(tooltip: 'Gallery', icon: const Icon(Icons.arrow_back_ios_new), onPressed: () => Navigator.of(context).pop())
            : PillTextButton('Gallery', onPressed: () => Navigator.of(context).pop()),
      );

  Widget _titlePill(bool compact) => Pill(
        child: ListenableBuilder(
          listenable: view,
          builder: (context, _) => Tooltip(
            message: 'Rename drawing',
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: _rename,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? double.infinity : 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  // The name is tappable: the pencil says so.
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                      child: Text(
                        '${widget.info.name} @ ${(view.scale * 100).round()}%',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.edit_outlined, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );

  List<MenuEntry> _zoomMenu() => [
        MenuAction('Fit to Screen', () => canvas?.fitToScreen()),
        MenuAction('Actual Size', () => canvas?.actualSize()),
        MenuAction('Zoom In', () => canvas?.zoomBy(1.25)),
        MenuAction('Zoom Out', () => canvas?.zoomBy(0.8)),
      ];

  List<MenuEntry> _placeMenu() => [
        MenuAction('Place Image…', _placeImage),
        MenuAction('Place SVG or DXF…', _placeSvg),
      ];

  List<MenuEntry> _shareMenu() => [
        MenuAction('Export SVG…', () => exportSvg(context, controller.drawing, widget.info.name)),
        MenuAction('Export PNG…', () => exportPng(context, controller.drawing, widget.info.name)),
        MenuAction('Export PDF…', () => exportPdf(context, controller.drawing, widget.info.name)),
        MenuAction('Export DXF…', () => exportDxf(context, controller.drawing, widget.info.name)),
        if (controller.drawing.makeMode)
          MenuAction('Export G-code…', () => showGcodeDialog(context, controller.drawing, widget.info.name)),
        MenuAction('Export .inkpad…', () => exportInkpad(context, controller.drawing, widget.info.name)),
        MenuAction('Copy SVG', () => copySvg(context, controller.drawing)),
      ];

  Widget _topRight() => Pill(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Builder(builder: (b) => IconButton(tooltip: 'Zoom', icon: const Icon(Icons.zoom_in), onPressed: () => _menu(b, _zoomMenu, side: PopoverSide.below))),
          Builder(builder: (b) => IconButton(tooltip: 'Place image', icon: const Icon(Icons.image_outlined), onPressed: () => _menu(b, _placeMenu, side: PopoverSide.below))),
          Builder(builder: (b) => IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => _panel(b, SettingsPanel(controller: controller), width: 400, side: PopoverSide.below))),
          Builder(builder: (b) => IconButton(tooltip: 'Share', icon: const Icon(Icons.ios_share), onPressed: () => _menu(b, _shareMenu, side: PopoverSide.below))),
        ]),
      );

  Widget _compactTopRight() => Pill(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: controller.canUndo ? controller.undo : null),
          IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: controller.canRedo ? controller.redo : null),
          Builder(
            builder: (b) => IconButton(
              tooltip: 'More',
              icon: const Icon(Icons.more_horiz),
              onPressed: () => _menu(b, () => [
                    ..._zoomMenu(),
                    const MenuDivider(),
                    ..._placeMenu(),
                    const MenuDivider(),
                    MenuAction('Settings…', () => _panel(context, SettingsPanel(controller: controller))),
                    ..._shareMenu(),
                  ], side: PopoverSide.below),
            ),
          ),
        ]),
      );

  Widget _menusPill(bool compact) => Pill(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Builder(builder: (b) => PillTextButton('Edit', onPressed: () => _menu(b, _editMenu))),
          Builder(builder: (b) => PillTextButton('Arrange', onPressed: () => _menu(b, _arrangeMenu))),
          Builder(builder: (b) => PillTextButton('Path', onPressed: () => _menu(b, _pathMenu))),
          Builder(
            key: _colorButton,
            builder: (b) => IconButton(
              tooltip: 'Color',
              icon: const _ColorWheel(),
              onPressed: () => _menu(b, _colorMenu),
            ),
          ),
        ]),
      );

  Widget _undoPill() => Pill(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: controller.canUndo ? controller.undo : null),
          IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: controller.canRedo ? controller.redo : null),
        ]),
      );

  Widget _stylePill(bool compact) {
    final c = controller;
    return Pill(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!compact)
          Builder(
            builder: (b) => IconButton(
              tooltip: 'Text',
              icon: const Icon(Icons.text_fields),
              onPressed: () => _panel(b, TextPanel(controller: c), width: 380),
            ),
          ),
        if (c.drawing.makeMode)
          Builder(
            builder: (b) => IconButton(
              tooltip: 'Cut',
              icon: const Icon(Icons.carpenter_outlined),
              onPressed: () => _panel(b, CutPanel(controller: c), width: 400),
            ),
          ),
        Builder(
          builder: (b) => IconButton(
            tooltip: 'Shadow & opacity',
            icon: const ToolIcon(ToolIcon.shadow, size: 30),
            onPressed: () => _panel(b, ShadowPanel(controller: c), width: 420),
          ),
        ),
        Builder(
          builder: (b) => IconButton(
            tooltip: 'Stroke',
            icon: _StrokeSwatch(stroke: c.strokeStyle),
            onPressed: () => _panel(b, StrokePanel(controller: c)),
          ),
        ),
        Builder(
          builder: (b) => IconButton(
            tooltip: 'Fill',
            icon: _FillSwatch(fill: c.fillPaint),
            onPressed: () => _panel(b, FillPanel(controller: c), width: 460),
          ),
        ),
        Builder(
          builder: (b) => IconButton(
            tooltip: 'AI',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => _panel(b, AiPanel(controller: c), width: 440),
          ),
        ),
        Builder(
          builder: (b) => compact
              ? IconButton(tooltip: 'Layers', icon: const Icon(Icons.layers_outlined), onPressed: () => _panel(b, LayersPanel(controller: c)))
              : PillTextButton('Layers', onPressed: () => _panel(b, LayersPanel(controller: c), width: 460)),
        ),
      ]),
    );
  }

  /// Options for the current tool (Inkpad's shape tool options).
  Widget _toolOptions() {
    final t = controller.tool;
    void update(void Function() change) => setState(change);
    if (t is EraserTool) {
      return _optionsPanel([
        SteppedSlider(
          label: 'Eraser Size',
          value: t.size,
          min: 1,
          max: 100,
          step: 1,
          format: (v) => '${v.round()} pt',
          onChanged: (v) => update(() => t.size = v.roundToDouble()),
        ),
      ]);
    }
    if (t is! ShapeTool || t.kind == ShapeKind.oval || t.kind == ShapeKind.line) return const SizedBox.shrink();
    final sliders = switch (t.kind) {
      ShapeKind.rectangle => [
          SteppedSlider(
            label: 'Corner Radius',
            value: t.cornerRadius,
            min: 0,
            max: 200,
            step: 1,
            format: (v) => '${v.round()} pt',
            onChanged: (v) => update(() => t.cornerRadius = v.roundToDouble()),
          ),
        ],
      ShapeKind.star => [
          SteppedSlider(
            label: 'Points',
            value: t.starPoints.toDouble(),
            min: 3,
            max: 24,
            step: 1,
            format: (v) => '${v.round()}',
            onChanged: (v) => update(() => t.starPoints = v.round()),
          ),
          SteppedSlider(
            label: 'Inner Radius',
            value: t.starInnerRatio * 100,
            min: 5,
            max: 95,
            step: 1,
            format: (v) => '${v.round()}%',
            onChanged: (v) => update(() => t.starInnerRatio = v.roundToDouble() / 100),
          ),
        ],
      ShapeKind.spiral => [
          SteppedSlider(
            label: 'Decay',
            value: t.spiralDecay,
            min: 10,
            max: 99,
            step: 1,
            format: (v) => '${v.round()}%',
            onChanged: (v) => update(() => t.spiralDecay = v.roundToDouble()),
          ),
        ],
      _ => [
          SteppedSlider(
            label: 'Sides',
            value: t.polygonSides.toDouble(),
            min: 3,
            max: 24,
            step: 1,
            format: (v) => '${v.round()}',
            onChanged: (v) => update(() => t.polygonSides = v.round()),
          ),
        ],
    };
    return _optionsPanel(sliders);
  }

  Widget _optionsPanel(List<Widget> sliders) => SizedBox(
        width: 400,
        child: Pill(
          radius: 18,
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: sliders),
        ),
      );
}

/// The stroke button: a square outline in the stroke color (a red slash
/// for none), as in Inkpad's bottom bar.
class _StrokeSwatch extends StatelessWidget {
  final StrokeStyle? stroke;

  const _StrokeSwatch({required this.stroke});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 30,
        child: CustomPaint(
          painter: _SwatchPainter((canvas, r) {
            final s = stroke;
            if (s == null) {
              canvas.drawRect(r.deflate(4), Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = Colors.black54);
              _noneSlash(canvas, r);
            } else {
              final paint = Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 6
                ..color = s.color.withAlpha(1).toColor();
              final g = s.gradient;
              if (g != null) {
                // Its colors across the swatch, fully opaque.
                final shader = g
                    .copyWith(
                      type: GradientType.linear,
                      stops: [for (final st in g.stops) GradientStop(st.offset, st.color.withAlpha(1))],
                      clearGeometry: true,
                    )
                    .shader(r, 1);
                if (shader != null) paint.shader = shader;
              }
              canvas.drawRect(r.deflate(4), paint);
            }
          }),
        ),
      );
}

class _FillSwatch extends StatelessWidget {
  final InkPaint? fill;

  const _FillSwatch({required this.fill});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 30,
        child: CustomPaint(
          painter: _SwatchPainter((canvas, r) {
            final f = fill;
            final box = r.deflate(1);
            if (f == null) {
              canvas.drawRect(box, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = Colors.black54);
              _noneSlash(canvas, r);
            } else if (f is InkGradient) {
              paintChecker(canvas, box, cell: 5);
              canvas.drawRect(box, Paint()..shader = f.copyWith(clearGeometry: true).shader(box, 1));
            } else {
              canvas.drawRect(box, Paint()..color = (f as InkColor).withAlpha(1).toColor());
            }
          }),
        ),
      );
}

void _noneSlash(Canvas canvas, Rect r) =>
    canvas.drawLine(r.bottomLeft, r.topRight, Paint()..strokeWidth = 2..color = Colors.red);

class _SwatchPainter extends CustomPainter {
  final void Function(Canvas canvas, Rect rect) draw;

  _SwatchPainter(this.draw);

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, Offset.zero & size);

  @override
  bool shouldRepaint(_SwatchPainter old) => true;
}

/// The rainbow wheel button (bottom-left).
class _ColorWheel extends StatelessWidget {
  const _ColorWheel();

  @override
  Widget build(BuildContext context) => Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(colors: [
            Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Color(0xFFFF00FF), Colors.red,
          ]),
        ),
        child: Center(
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Colors.white, Colors.white.withValues(alpha: 0)])),
          ),
        ),
      );
}
