import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../export/dxf_export.dart';
import '../import/dxf_import.dart';
import '../export/pdf_export.dart';
import '../export/raster_export.dart';
import '../model/drawing.dart';
import '../svg/svg_importer.dart';

/// Native document extension (JSON). Inkpad's own format was an
/// NSKeyedArchiver blob, which isn't portable, so we use JSON instead.
const inkpadExtension = 'inkpad';

/// Turns a drawing name into a safe file name.
String _fileName(String name, String ext) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').trim();
  return '${safe.isEmpty ? 'drawing' : safe}.$ext';
}

Future<void> exportSvg(BuildContext context, InkDrawing drawing, String name) =>
    _save(context, _fileName(name, 'svg'), utf8.encode(drawing.toSvg()), 'image/svg+xml', 'svg');

/// PNG export options, remembered for next time.
double _pngScale = 2;
bool _pngTransparent = false;

/// Asks for the size and background, then saves the page as a PNG.
Future<void> exportPng(BuildContext context, InkDrawing drawing, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final px = (drawing.width * _pngScale).round(), py = (drawing.height * _pngScale).round();
        return AlertDialog(
          title: const Text('Export PNG'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SegmentedButton<double>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('1×')),
                ButtonSegment(value: 2, label: Text('2×')),
                ButtonSegment(value: 3, label: Text('3×')),
                ButtonSegment(value: 4, label: Text('4×')),
              ],
              selected: {_pngScale},
              onSelectionChanged: (s) => setState(() => _pngScale = s.single),
            ),
            const SizedBox(height: 8),
            Text('$px × $py pixels', style: Theme.of(context).textTheme.bodySmall),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Transparent background'),
              value: _pngTransparent,
              onChanged: (v) => setState(() => _pngTransparent = v ?? false),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Export')),
          ],
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final png = await drawingToPng(drawing, scale: _pngScale, transparent: _pngTransparent);
    if (context.mounted) await _save(context, _fileName(name, 'png'), png, 'image/png', 'png');
  } catch (e) {
    if (context.mounted) showSnack(context, 'Could not make the PNG: $e');
  }
}

/// Saves the drawing as DXF, for CAD/CAM programs and laser cutters.
Future<void> exportDxf(BuildContext context, InkDrawing drawing, String name) =>
    _save(context, _fileName(name, 'dxf'), drawingToDxf(drawing), 'image/vnd.dxf', 'dxf');

/// Saves the page as a vector PDF.
Future<void> exportPdf(BuildContext context, InkDrawing drawing, String name) async {
  try {
    final pdf = await drawingToPdf(drawing);
    if (context.mounted) await _save(context, _fileName(name, 'pdf'), pdf, 'application/pdf', 'pdf');
  } catch (e) {
    if (context.mounted) showSnack(context, 'Could not make the PDF: $e');
  }
}

Future<void> exportInkpad(BuildContext context, InkDrawing drawing, String name) => _save(
    context, _fileName(name, inkpadExtension), utf8.encode(drawing.encode()), 'application/json', inkpadExtension);

/// A drawing read from a file, with notes about anything not imported.
typedef ImportedFile = ({String name, InkDrawing drawing, List<String> warnings});

/// Lets the user pick `.inkpad` and/or `.svg` files and reads them.
/// Files that can't be read are reported and skipped.
Future<List<ImportedFile>> pickDrawingFiles(BuildContext context, {bool inkpad = true, bool svg = true}) async {
  final result = <ImportedFile>[];
  final List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [if (inkpad) ...[inkpadExtension, 'json'], if (svg) ...['svg', 'dxf']],
    );
  } catch (e) {
    if (context.mounted) showSnack(context, 'Could not open the file picker: $e');
    return result;
  }
  for (final f in files) {
    final dot = f.name.lastIndexOf('.');
    final name = dot > 0 ? f.name.substring(0, dot) : f.name;
    final ext = dot > 0 ? f.name.substring(dot + 1).toLowerCase() : '';
    try {
      final text = await f.xFile.readAsString();
      if (ext == 'dxf') {
        final r = importDxf(text);
        result.add((name: name, drawing: r.drawing, warnings: r.warnings));
      } else if (ext == 'svg' || (ext != inkpadExtension && text.trimLeft().startsWith('<'))) {
        final r = importSvg(text);
        result.add((name: name, drawing: r.drawing, warnings: r.warnings));
      } else {
        result.add((name: name, drawing: InkDrawing.decode(text), warnings: const []));
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Could not open "${f.name}": $e');
    }
  }
  return result;
}

/// Lets the user pick image files (the photo library on phones).
/// Returns (file name, bytes) pairs.
Future<List<(String, Uint8List)>> pickImageFiles(BuildContext context) async {
  try {
    final files = await FilePicker.pickFiles(type: FileType.image);
    return [for (final f in files) (f.name, await f.xFile.readAsBytes())];
  } catch (e) {
    if (context.mounted) showSnack(context, 'Could not open the image: $e');
    return [];
  }
}

/// Shows what an import left out, if anything.
void reportImport(BuildContext context, List<ImportedFile> files) {
  if (files.isEmpty) return;
  final summary = files.length == 1 ? 'Imported "${files.single.name}"' : 'Imported ${files.length} drawings';
  final notes = [
    for (final f in files)
      for (final w in f.warnings) files.length == 1 ? w : '${f.name}: $w',
  ];
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    margin: snackMargin,
    content: Text(notes.isEmpty ? summary : '$summary, with some differences'),
    action: notes.isEmpty
        ? null
        : SnackBarAction(
            label: 'Details',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Import notes'),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final n in notes) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('• $n')),
                    ],
                  ),
                ),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              ),
            ),
          ),
  ));
}

Future<void> copySvg(BuildContext context, InkDrawing drawing) async {
  await Clipboard.setData(ClipboardData(text: drawing.toSvg()));
  if (context.mounted) showSnack(context, 'SVG copied to clipboard');
}

/// Saves [bytes] through the system's save dialog (or a download on the web).
Future<void> saveFile(BuildContext context, String name, List<int> bytes, String mime, String ext) => _save(context, name, bytes, mime, ext);

Future<void> _save(BuildContext context, String name, List<int> bytes, String mime, String ext) async {
  try {
    final uri = await FilePicker.saveFile(
      fileName: name,
      bytes: Uint8List.fromList(bytes),
      mimeType: mime,
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (uri != null && context.mounted) showSnack(context, 'Saved $name');
  } catch (e) {
    if (context.mounted) showSnack(context, 'Could not save: $e');
  }
}

void showSnack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, margin: snackMargin));

/// Floating messages sit above the editor's bottom bar rather than over it.
const snackMargin = EdgeInsets.fromLTRB(16, 0, 16, 88);

/// Simple text prompt, used for renaming.
Future<String?> promptForText(BuildContext context, {required String title, required String initial, String action = 'OK'}) {
  final field = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, field.text), child: Text(action)),
      ],
    ),
  );
}
