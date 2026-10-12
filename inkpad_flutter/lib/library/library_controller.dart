import 'dart:math';

import 'package:flutter/foundation.dart';

import '../model/drawing.dart';
import '../model/element.dart';
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

  List<PortfolioInfo> _portfolios = [];

  /// Portfolios, most recently changed first.
  List<PortfolioInfo> get portfolios =>
      [..._portfolios]..sort((a, b) => lastChange(b).compareTo(lastChange(a)));

  PortfolioInfo? portfolioById(String? id) => id == null ? null : _portfolios.where((p) => p.id == id).firstOrNull;

  /// The drawings in [portfolio] (null: those not in any portfolio).
  List<DrawingInfo> drawingsIn(String? portfolio) => [for (final d in _drawings) if (d.portfolio == portfolio) d];

  /// When a portfolio last changed: its newest drawing, or its creation.
  DateTime lastChange(PortfolioInfo p) {
    final newest = _drawings.where((d) => d.portfolio == p.id).map((d) => d.modified);
    return newest.fold(p.created, (a, b) => b.isAfter(a) ? b : a);
  }

  Future<void> load() async {
    try {
      _drawings = await store.loadAll();
      _portfolios = await store.loadPortfolios();
      // Drawings whose portfolio was lost go back to the gallery.
      final ids = {for (final p in _portfolios) p.id};
      for (final d in _drawings) {
        if (d.portfolio != null && !ids.contains(d.portfolio)) d.portfolio = null;
      }
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

  Future<DrawingInfo> create({InkDrawing? drawing, String? name, String? portfolio}) async {
    final info = DrawingInfo(
      id: newId(),
      name: uniqueName(name ?? 'Untitled'),
      modified: DateTime.now(),
      drawing: drawing ?? InkDrawing(),
      portfolio: portfolio,
    );
    _drawings.insert(0, info);
    notifyListeners();
    await _persist(info);
    return info;
  }

  Future<DrawingInfo> duplicate(DrawingInfo source) => create(
        drawing: InkDrawing.decode(source.drawing.encode(includeImages: false)),
        name: '${source.name} copy',
        portfolio: source.portfolio,
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

  // ---- Portfolios ----------------------------------------------------------

  /// "Portfolio", "Portfolio 2", … avoiding names already used.
  String uniquePortfolioName([String base = 'Portfolio']) {
    final names = _portfolios.map((p) => p.name).toSet();
    if (!names.contains(base)) return base;
    var i = 2;
    while (names.contains('$base $i')) {
      i++;
    }
    return '$base $i';
  }

  Future<PortfolioInfo> createPortfolio([String? name]) async {
    final trimmed = name?.trim();
    final p = PortfolioInfo(
      id: newId(),
      name: trimmed == null || trimmed.isEmpty ? uniquePortfolioName() : trimmed,
      created: DateTime.now(),
    );
    _portfolios.add(p);
    notifyListeners();
    await _persistPortfolios();
    return p;
  }

  Future<void> renamePortfolio(PortfolioInfo p, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == p.name) return;
    p.name = trimmed;
    notifyListeners();
    await _persistPortfolios();
  }

  /// Removes a portfolio; its drawings go back to the gallery, or are
  /// deleted too if [deleteDrawings].
  Future<void> deletePortfolio(PortfolioInfo p, {bool deleteDrawings = false}) async {
    final members = drawingsIn(p.id);
    _portfolios.remove(p);
    for (final d in members) {
      if (deleteDrawings) {
        await delete(d);
      } else {
        d.portfolio = null;
        await _persist(d);
      }
    }
    notifyListeners();
    await _persistPortfolios();
  }

  /// Puts drawings in [portfolio] (null: back to the gallery).
  Future<void> move(Iterable<DrawingInfo> drawings, String? portfolio) async {
    final moving = [for (final d in drawings) if (d.portfolio != portfolio) d];
    for (final d in moving) {
      d.portfolio = portfolio;
    }
    notifyListeners();
    for (final d in moving) {
      await _persist(d);
    }
  }

  Future<void> _persistPortfolios() async {
    try {
      await store.savePortfolios(_portfolios);
    } catch (e) {
      error = 'Could not save your portfolios: $e';
      notifyListeners();
    }
  }

  // ---- Search ----------------------------------------------------------------

  /// Drawings matching [query]: every word must appear in the drawing's
  /// name, its portfolio's name, or text in the drawing.
  List<DrawingInfo> search(String query, {String? within, bool everywhere = false}) {
    final words = _words(query);
    if (words.isEmpty) return everywhere ? drawings : drawingsIn(within);
    return [
      for (final d in _drawings)
        if ((everywhere || d.portfolio == within) && words.every(_haystack(d).contains)) d,
    ];
  }

  /// Portfolios whose name matches every word of [query].
  List<PortfolioInfo> searchPortfolios(String query) {
    final words = _words(query);
    return [for (final p in portfolios) if (words.every(p.name.toLowerCase().contains)) p];
  }

  static List<String> _words(String q) => q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  String _haystack(DrawingInfo d) {
    final text = [
      for (final e in d.drawing.allElements)
        for (final x in e.selfAndDescendants)
          if (x is InkText) x.text else if (x is InkTextPath) x.text,
    ];
    return [d.name, portfolioById(d.portfolio)?.name ?? '', ...text].join('\n').toLowerCase();
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
