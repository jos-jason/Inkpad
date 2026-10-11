import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      allowedExtensions: [if (inkpad) ...[inkpadExtension, 'json'], if (svg) 'svg'],
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
      if (ext == 'svg' || (ext != inkpadExtension && text.trimLeft().startsWith('<'))) {
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
Future<String?> promptForText(BuildContext context, {required String title, required String initial}) {
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
        FilledButton(onPressed: () => Navigator.pop(context, field.text), child: const Text('OK')),
      ],
    ),
  );
}
