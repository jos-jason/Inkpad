import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/drawing_controller.dart';
import '../model/drawing.dart';

/// Native document extension (JSON). Inkpad's own format was an
/// NSKeyedArchiver blob, which isn't portable, so we use JSON instead.
const inkpadExtension = 'inkpad';

Future<void> exportSvg(BuildContext context, DrawingController c) async {
  final svg = c.drawing.toSvg();
  await _save(context, 'drawing.svg', utf8.encode(svg), 'image/svg+xml', 'svg');
}

Future<void> saveDrawing(BuildContext context, DrawingController c) async {
  await _save(context, 'drawing.$inkpadExtension', utf8.encode(c.drawing.encode()),
      'application/json', inkpadExtension);
}

Future<void> openDrawing(BuildContext context, DrawingController c) async {
  try {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [inkpadExtension, 'json'],
    );
    if (files.isEmpty) return;
    final text = await files.first.xFile.readAsString();
    c.loadDrawing(InkDrawing.decode(text));
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not open file: $e');
  }
}

Future<void> copySvg(BuildContext context, DrawingController c) async {
  await Clipboard.setData(ClipboardData(text: c.drawing.toSvg()));
  if (context.mounted) _snack(context, 'SVG copied to clipboard');
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
    if (uri != null && context.mounted) _snack(context, 'Saved');
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not save: $e');
  }
}

void _snack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
