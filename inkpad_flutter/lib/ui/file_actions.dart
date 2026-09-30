import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/drawing.dart';

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

/// Lets the user pick `.inkpad` files; returns (name, drawing) pairs.
Future<List<(String, InkDrawing)>> pickInkpadFiles(BuildContext context) async {
  final result = <(String, InkDrawing)>[];
  try {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [inkpadExtension, 'json'],
    );
    for (final f in files) {
      final text = await f.xFile.readAsString();
      final dot = f.name.lastIndexOf('.');
      result.add((dot > 0 ? f.name.substring(0, dot) : f.name, InkDrawing.decode(text)));
    }
  } catch (e) {
    if (context.mounted) showSnack(context, 'Could not open file: $e');
  }
  return result;
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

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
