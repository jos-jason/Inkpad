import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:glyph_path/glyph_path.dart' as gp;

import 'font_file.dart';
import 'font_source_io.dart' if (dart.library.js_interop) 'font_source_web.dart' as platform;

/// Where font files come from: the app's bundled fonts, the system's font
/// folders, and fonts the user added to the app.
abstract class FontSource {
  /// Bundled faces' sources (asset keys), always available.
  List<String> get bundled;

  /// Reads a font file by its source.
  Future<Uint8List?> read(String source);

  /// Faces installed on this device (may be slow; runs once in the background).
  Future<List<FontFaceInfo>> scanSystem();

  /// Faces the user added earlier.
  Future<List<FontFaceInfo>> imported();

  /// Keeps a user-added font file; returns its source.
  Future<String> storeImported(Uint8List bytes, String fileName);

  factory FontSource() => platform.createFontSource();
}

/// A face ready for drawing.
class LoadedFace {
  final FontFaceInfo info;
  final gp.Font font;

  LoadedFace(this.info, this.font);
}

/// The fonts the app can use, and their parsed outlines. Fonts load
/// lazily: drawing code asks for a face and gets the fallback (Lato) until
/// the real one has loaded, then views repaint.
class FontLibrary extends ChangeNotifier {
  static FontLibrary instance = FontLibrary(FontSource());

  /// Inkpad's defaults: Helvetica, 24 pt. Lato stands in where Helvetica
  /// isn't installed.
  static const preferredDefaultFamily = 'Helvetica';
  static const fallbackFamily = 'Lato';
  static const defaultSize = 24.0;

  final FontSource source;
  final List<FontFaceInfo> _faces = [];
  final Map<String, LoadedFace> _loaded = {};
  final Set<String> _loading = {};
  LoadedFace? _fallback;
  bool systemScanned = false;

  FontLibrary(this.source);

  /// Loads the bundled fonts, then scans the system in the background.
  Future<void> init({bool scanSystem = true}) async {
    for (final s in source.bundled) {
      final bytes = await source.read(s);
      if (bytes == null) continue;
      for (final info in readFontFaces(bytes, s)) {
        _faces.add(info);
        _loaded[_key(info)] = LoadedFace(info, gp.Font.parse(extractFace(bytes, info.index)));
      }
    }
    _fallback = _loaded.values.where((f) => f.info.family == fallbackFamily && !f.info.italic && f.info.weight == 400).firstOrNull ??
        _loaded.values.firstOrNull;
    _faces.addAll(await source.imported());
    notifyListeners();
    if (scanSystem) {
      unawaited(source.scanSystem().then((system) {
        _faces.addAll(system);
        systemScanned = true;
        notifyListeners();
      }));
    }
  }

  static String _key(FontFaceInfo f) => '${f.source}#${f.index}';

  LoadedFace get fallback => _fallback!;

  /// All faces, de-duplicated by family and style (first source wins:
  /// bundled, then the user's, then the system's).
  List<FontFaceInfo> get faces {
    final seen = <String>{};
    return [for (final f in _faces) if (seen.add('${f.family}\u0000${f.style}')) f];
  }

  List<String> get families => {for (final f in faces) f.family}.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  /// A family's styles, regular weights first.
  List<FontFaceInfo> stylesOf(String family) => faces.where((f) => f.family == family).toList()
    ..sort((a, b) {
      // Regular first, then by weight; each upright before its italic.
      final w = (a.weight - 400).abs().compareTo((b.weight - 400).abs());
      if (w != 0) return w;
      if (a.weight != b.weight) return a.weight.compareTo(b.weight);
      return a.italic == b.italic ? 0 : (a.italic ? 1 : -1);
    });

  String get defaultFamily => faces.any((f) => f.family == preferredDefaultFamily) ? preferredDefaultFamily : fallbackFamily;

  /// The face for [family]/[style]: that exact style, else the family's
  /// regular, else null (not available on this device).
  FontFaceInfo? find(String family, String style) {
    final styles = stylesOf(family);
    return styles.where((f) => f.style == style).firstOrNull ?? styles.firstOrNull;
  }

  /// The loaded face for [family]/[style] if ready; otherwise starts
  /// loading it and returns null (draw with [fallback] meanwhile).
  LoadedFace? face(String family, String style) {
    final info = find(family, style);
    if (info == null) return null;
    final loaded = _loaded[_key(info)];
    if (loaded != null) return loaded;
    _load(info);
    return null;
  }

  /// Like [face], but waits for loading.
  Future<LoadedFace?> loadFace(String family, String style) async {
    final info = find(family, style);
    if (info == null) return null;
    return _loaded[_key(info)] ?? await _load(info);
  }

  /// Whether [family] exists on this device (else the fallback is used).
  bool has(String family) => faces.any((f) => f.family == family);

  Future<LoadedFace?> _load(FontFaceInfo info) async {
    final key = _key(info);
    if (!_loading.add(key)) return null;
    try {
      final bytes = await source.read(info.source);
      if (bytes == null) return null;
      final face = LoadedFace(info, gp.Font.parse(extractFace(bytes, info.index)));
      _loaded[key] = face;
      notifyListeners();
      return face;
    } catch (e) {
      debugPrint('Could not load font $info: $e');
      return null;
    } finally {
      _loading.remove(key);
    }
  }

  /// Adds a font file to the app's font list without installing it on the
  /// system. Returns the faces added (empty if the file isn't a usable font).
  Future<List<FontFaceInfo>> importFont(Uint8List bytes, String fileName) async {
    if (readFontFaces(bytes, fileName).isEmpty) return [];
    final stored = await source.storeImported(bytes, fileName);
    final faces = readFontFaces(bytes, stored);
    // Imported fonts take priority over same-named system fonts.
    _faces.insertAll(source.bundled.length.clamp(0, _faces.length), faces);
    notifyListeners();
    return faces;
  }
}
