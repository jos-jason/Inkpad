import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'font_file.dart';
import 'font_library.dart';

FontSource createFontSource() => IoFontSource();

/// Fonts on desktop and mobile: bundled assets, the system's font folders,
/// and user-added fonts copied into the app's support folder.
class IoFontSource implements FontSource {
  static const assetPrefix = 'asset:';

  /// Where to look for installed fonts, per platform.
  static List<String> systemFontDirs() {
    var home = Platform.environment['HOME'] ?? '';
    // A sandboxed Mac app's HOME is its container; the user's own fonts
    // are in the real home folder above it.
    final container = home.indexOf('/Library/Containers/');
    if (container > 0) home = home.substring(0, container);
    if (Platform.isMacOS || Platform.isIOS) {
      return ['/System/Library/Fonts', '/Library/Fonts', '$home/Library/Fonts'];
    }
    if (Platform.isLinux) {
      return ['/usr/share/fonts', '/usr/local/share/fonts', '$home/.fonts', '$home/.local/share/fonts'];
    }
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      return [r'C:\Windows\Fonts', if (local != null) '$local\\Microsoft\\Windows\\Fonts'];
    }
    if (Platform.isAndroid) return ['/system/fonts', '/product/fonts'];
    return [];
  }

  @override
  List<String> get bundled => const [
        '${assetPrefix}assets/fonts/Lato-Regular.ttf',
        '${assetPrefix}assets/fonts/Lato-Bold.ttf',
        '${assetPrefix}assets/fonts/Lato-Italic.ttf',
        '${assetPrefix}assets/fonts/Lato-BoldItalic.ttf',
      ];

  Future<Directory> _importDir() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/fonts');
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<Uint8List?> read(String source) async {
    if (source.startsWith(assetPrefix)) {
      final data = await rootBundle.load(source.substring(assetPrefix.length));
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    final file = File(source);
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<List<FontFaceInfo>> scanSystem() async {
    final dirs = systemFontDirs();
    File? cacheFile;
    try {
      cacheFile = File('${(await getApplicationSupportDirectory()).path}/font-catalog.json');
    } catch (_) {
      // No support folder (e.g. in tests); scan without caching.
    }
    final cachePath = cacheFile?.path;
    try {
      return await Isolate.run(() => scanFontDirs(dirs, cachePath));
    } catch (e) {
      debugPrint('Font scan failed: $e');
      return [];
    }
  }

  @override
  Future<List<FontFaceInfo>> imported() async {
    try {
      final dir = await _importDir();
      return [
        for (final f in dir.listSync().whereType<File>())
          ...readFontFaces(await f.readAsBytes(), f.path),
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<String> storeImported(Uint8List bytes, String fileName) async {
    final dir = await _importDir();
    // Name by content so re-adding the same font doesn't duplicate it.
    final ext = fileName.contains('.') ? fileName.substring(fileName.lastIndexOf('.')) : '.ttf';
    final file = File('${dir.path}/${sha1.convert(bytes).toString().substring(0, 16)}$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

/// Reads every font in [dirs] (recursively). Results are cached in
/// [cachePath] by file path, size and modification time, so later launches
/// only read new or changed files. Runs in a background isolate.
List<FontFaceInfo> scanFontDirs(List<String> dirs, String? cachePath) {
  final cache = <String, dynamic>{};
  if (cachePath != null) {
    try {
      cache.addAll(jsonDecode(File(cachePath).readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {}
  }
  final fresh = <String, dynamic>{};
  final faces = <FontFaceInfo>[];
  final fontFile = RegExp(r'\.(ttf|otf|ttc|otc)$', caseSensitive: false);
  for (final dir in dirs) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    List<FileSystemEntity> entries;
    try {
      entries = d.listSync(recursive: true, followLinks: false);
    } catch (_) {
      continue; // not readable (e.g. sandboxed)
    }
    for (final e in entries) {
      if (e is! File || !fontFile.hasMatch(e.path)) continue;
      try {
        final stat = e.statSync();
        final stamp = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
        final cached = cache[e.path];
        List<FontFaceInfo> found;
        if (cached is Map && cached['stamp'] == stamp) {
          found = [for (final j in cached['faces'] as List) FontFaceInfo.fromJson(j)];
        } else {
          found = readFontFaces(e.readAsBytesSync(), e.path);
        }
        fresh[e.path] = {'stamp': stamp, 'faces': [for (final f in found) f.toJson()]};
        faces.addAll(found);
      } catch (_) {
        // Unreadable file: skip.
      }
    }
  }
  if (cachePath != null) {
    try {
      File(cachePath).writeAsStringSync(jsonEncode(fresh));
    } catch (_) {}
  }
  return faces;
}
