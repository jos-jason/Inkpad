import 'dart:convert';

import '../model/drawing.dart';
import 'store_io.dart' if (dart.library.js_interop) 'store_web.dart' as platform;

/// A drawing in the library, plus its metadata.
/// Plays the role of Inkpad's WDDocument / gallery entry.
class DrawingInfo {
  final String id;
  String name;
  DateTime modified;
  InkDrawing drawing;

  DrawingInfo({
    required this.id,
    required this.name,
    required this.modified,
    required this.drawing,
  });

  /// File contents: the drawing JSON with library metadata alongside.
  String encode() => jsonEncode({
        ...drawing.toJson(),
        'name': name,
        'modified': modified.toIso8601String(),
      });

  factory DrawingInfo.decode(String id, String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    return DrawingInfo(
      id: id,
      name: j['name'] as String? ?? 'Untitled',
      modified: DateTime.tryParse(j['modified'] as String? ?? '') ?? DateTime.now(),
      drawing: InkDrawing.fromJson(j),
    );
  }
}

/// Persistent storage for the library. Files on desktop/mobile,
/// browser storage on the web.
abstract class DrawingStore {
  Future<List<DrawingInfo>> loadAll();
  Future<void> save(DrawingInfo info);
  Future<void> delete(String id);

  factory DrawingStore() => platform.createStore();
}

/// Non-persistent store, used by tests.
class MemoryDrawingStore implements DrawingStore {
  final Map<String, String> files = {};

  @override
  Future<List<DrawingInfo>> loadAll() async =>
      [for (final e in files.entries) DrawingInfo.decode(e.key, e.value)];

  @override
  Future<void> save(DrawingInfo info) async => files[info.id] = info.encode();

  @override
  Future<void> delete(String id) async => files.remove(id);
}
