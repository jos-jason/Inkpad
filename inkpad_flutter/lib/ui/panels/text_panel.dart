import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../controller/drawing_controller.dart';
import '../../model/text.dart';
import '../../text/font_library.dart';
import '../chrome/chrome.dart';
import '../file_actions.dart';

/// Font, style, size and alignment for new text and the selected text.
/// Ported in spirit from Inkpad's WDFontController and WDTextController.
class TextPanel extends StatefulWidget {
  final DrawingController controller;

  const TextPanel({super.key, required this.controller});

  @override
  State<TextPanel> createState() => _TextPanelState();
}

class _TextPanelState extends State<TextPanel> {
  final _search = TextEditingController();
  final _list = ScrollController();
  bool _scrolled = false;

  static const _rowHeight = 40.0;

  DrawingController get c => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    _list.dispose();
    super.dispose();
  }

  Future<void> _addFont() async {
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf', 'ttc', 'otc']);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not open the file picker: $e');
      return;
    }
    final added = <String>{};
    for (final f in files) {
      try {
        final faces = await FontLibrary.instance.importFont(await f.xFile.readAsBytes(), f.name);
        if (faces.isEmpty && mounted) showSnack(context, '"${f.name}" isn\'t a font Inkpad can use');
        added.addAll(faces.map((face) => face.family));
      } catch (e) {
        if (mounted) showSnack(context, 'Could not add "${f.name}": $e');
      }
    }
    if (added.isNotEmpty) {
      c.setTextStyle(family: added.first);
      _scrolled = false;
      if (mounted) showSnack(context, added.length == 1 ? 'Added ${added.first}' : 'Added ${added.length} fonts');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, FontLibrary.instance, _search]),
      builder: (context, _) {
        final library = FontLibrary.instance;
        final query = _search.text.trim().toLowerCase();
        final families = [for (final f in library.families) if (f.toLowerCase().contains(query)) f];
        final styles = library.stylesOf(c.fontFamily);
        final scheme = Theme.of(context).colorScheme;
        // Show the current family when the panel opens.
        if (!_scrolled && query.isEmpty) {
          _scrolled = true;
          final i = families.indexOf(c.fontFamily);
          if (i > 2) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_list.hasClients) _list.jumpTo(((i - 2) * _rowHeight).clamp(0, _list.position.maxScrollExtent));
            });
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PopoverHeader(
              'Text',
              trailing: TextButton.icon(onPressed: _addFont, icon: const Icon(Icons.add), label: const Text('Add Font…')),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search fonts',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (!library.has(c.fontFamily))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  '${c.fontFamily} isn\'t on this device; showing ${FontLibrary.fallbackFamily} instead.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            SizedBox(
              height: _rowHeight * 6,
              child: families.isEmpty
                  ? Center(child: Text(library.systemScanned || query.isNotEmpty ? 'No fonts found' : 'Finding fonts…'))
                  : ListView.builder(
                      controller: _list,
                      itemExtent: _rowHeight,
                      itemCount: families.length,
                      itemBuilder: (context, i) {
                        final f = families[i];
                        final selected = f == c.fontFamily;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          title: Text(f, overflow: TextOverflow.ellipsis),
                          trailing: selected ? const Icon(Icons.check, size: 18) : null,
                          onTap: () => c.setTextStyle(family: f),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            if (styles.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: DropdownButtonFormField<String>(
                  key: ValueKey(c.fontFamily),
                  initialValue: styles.any((s) => s.style == c.fontStyle) ? c.fontStyle : styles.first.style,
                  isDense: true,
                  decoration: const InputDecoration(labelText: 'Style', border: OutlineInputBorder(), isDense: true),
                  items: [for (final s in styles) DropdownMenuItem(value: s.style, child: Text(s.style))],
                  onChanged: (s) => c.setTextStyle(style: s),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: SteppedSlider(
                label: 'Size',
                value: c.fontSize.clamp(4, 288),
                min: 4,
                max: 288,
                step: 1,
                format: (v) => '${v.round()} pt',
                onChangeStart: c.selectedTexts.isEmpty ? null : c.checkpoint,
                onChanged: (v) => c.setTextStyle(size: v.roundToDouble(), record: false),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
              child: SegmentedButton<TextAlignment>(
                segments: const [
                  ButtonSegment(value: TextAlignment.left, icon: Icon(Icons.format_align_left), tooltip: 'Align left'),
                  ButtonSegment(value: TextAlignment.center, icon: Icon(Icons.format_align_center), tooltip: 'Center'),
                  ButtonSegment(value: TextAlignment.right, icon: Icon(Icons.format_align_right), tooltip: 'Align right'),
                ],
                selected: {c.textAlignment},
                showSelectedIcon: false,
                onSelectionChanged: (s) => c.setTextStyle(alignment: s.single),
              ),
            ),
          ],
        );
      },
    );
  }
}
