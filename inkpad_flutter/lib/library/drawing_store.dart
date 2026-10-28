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

  /// The portfolio it's in (null: loose in the gallery).
  String? portfolio;

  DrawingInfo({
    required this.id,
    required this.name,
    required this.modified,
    required this.drawing,
    this.portfolio,
  });

  /// File contents: the drawing JSON with library metadata alongside.
  String encode() => jsonEncode({
        ...drawing.toJson(),
        'name': name,
        'modified': modified.toIso8601String(),
        if (portfolio != null) 'portfolio': portfolio,
      });

  factory DrawingInfo.decode(String id, String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    return DrawingInfo(
      id: id,
      name: j['name'] as String? ?? 'Untitled',
      modified: DateTime.tryParse(j['modified'] as String? ?? '') ?? DateTime.now(),
      drawing: InkDrawing.fromJson(j),
      portfolio: j['portfolio'] as String?,
    );
  }
}

/// A named group of drawings in the gallery (like a folder).
class PortfolioInfo {
  final String id;
  String name;
  final DateTime created;

  PortfolioInfo({required this.id, required this.name, required this.created});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'created': created.toIso8601String()};

  factory PortfolioInfo.fromJson(Map<String, dynamic> j) => PortfolioInfo(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Portfolio',
        created: DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.now(),
      );

  static String encodeAll(List<PortfolioInfo> all) => jsonEncode([for (final p in all) p.toJson()]);

  static List<PortfolioInfo> decodeAll(String? text) {
    if (text == null || text.isEmpty) return [];
    return [for (final j in jsonDecode(text) as List) PortfolioInfo.fromJson(j as Map<String, dynamic>)];
  }
}

/// Persistent storage for the library. Files on desktop/mobile,
/// browser storage on the web.
abstract class DrawingStore {
  Future<List<DrawingInfo>> loadAll();
  Future<void> save(DrawingInfo info);
  Future<void> delete(String id);

  Future<List<PortfolioInfo>> loadPortfolios();
  Future<void> savePortfolios(List<PortfolioInfo> portfolios);

  factory DrawingStore() => platform.createStore();
}

/// Non-persistent store, used by tests.
class MemoryDrawingStore implements DrawingStore {
  final Map<String, String> files = {};
  String? portfolios;

  @override
  Future<List<PortfolioInfo>> loadPortfolios() async => PortfolioInfo.decodeAll(portfolios);

  @override
  Future<void> savePortfolios(List<PortfolioInfo> all) async => portfolios = PortfolioInfo.encodeAll(all);

  @override
  Future<List<DrawingInfo>> loadAll() async =>
      [for (final e in files.entries) DrawingInfo.decode(e.key, e.value)];

  @override
  Future<void> save(DrawingInfo info) async => files[info.id] = info.encode();

  @override
  Future<void> delete(String id) async => files.remove(id);
}
