import 'dart:math';

import 'package:flutter/foundation.dart';

import '../model/drawing.dart';
import 'drawing_store.dart';

/// The list of saved drawings. Plays the role of Inkpad's WDDrawingManager.
class LibraryController extends ChangeNotifier {
  final DrawingStore store;

  List<DrawingInfo> _drawings = [];
  bool loaded = false;

  /// Set when the library couldn't be read or written.
  String? error;

  LibraryController(this.store);

  /// Most recently edited first.
  List<DrawingInfo> get drawings => _drawings;

  Future<void> load() async {
    try {
      _drawings = await store.loadAll();
      _sort();
      error = null;
    } catch (e) {
      error = 'Could not load your drawings: $e';
    }
    loaded = true;
    notifyListeners();
  }

  void _sort() => _drawings.sort((a, b) => b.modified.compareTo(a.modified));

  static final _random = Random();

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_random.nextInt(1 << 30).toRadixString(36)}';

  /// "Untitled", "Untitled 2", … avoiding names already in the library.
  String uniqueName([String base = 'Untitled']) {
    final names = _drawings.map((d) => d.name).toSet();
    if (!names.contains(base)) return base;
    var i = 2;
    while (names.contains('$base $i')) {
      i++;
    }
    return '$base $i';
  }

  Future<DrawingInfo> create({InkDrawing? drawing, String? name}) async {
    final info = DrawingInfo(
      id: newId(),
      name: uniqueName(name ?? 'Untitled'),
      modified: DateTime.now(),
      drawing: drawing ?? InkDrawing(),
    );
    _drawings.insert(0, info);
    notifyListeners();
    await _persist(info);
    return info;
  }

  Future<DrawingInfo> duplicate(DrawingInfo source) => create(
        drawing: InkDrawing.decode(source.drawing.encode()),
        name: '${source.name} copy',
      );

  Future<void> rename(DrawingInfo info, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == info.name) return;
    info.name = trimmed;
    notifyListeners();
    await _persist(info);
  }

  Future<void> delete(DrawingInfo info) async {
    _drawings.remove(info);
    notifyListeners();
    try {
      await store.delete(info.id);
    } catch (e) {
      error = 'Could not delete "${info.name}": $e';
      notifyListeners();
    }
  }

  /// Saves an edited drawing and moves it to the top of the library.
  Future<void> saveEdits(DrawingInfo info, InkDrawing drawing) async {
    info
      ..drawing = drawing
      ..modified = DateTime.now();
    _sort();
    notifyListeners();
    await _persist(info);
  }

  Future<void> _persist(DrawingInfo info) async {
    try {
      await store.save(info);
    } catch (e) {
      error = 'Could not save "${info.name}": $e';
      notifyListeners();
    }
  }
}
