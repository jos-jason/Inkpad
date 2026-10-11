import 'package:flutter/services.dart';

import 'font_file.dart';
import 'font_library.dart';

FontSource createFontSource() => WebFontSource();

/// Fonts on the web: browsers don't expose installed font files, so only the
/// bundled fonts and fonts added during this session are available.
class WebFontSource implements FontSource {
  static const assetPrefix = 'asset:';
  final Map<String, Uint8List> _added = {};

  @override
  List<String> get bundled => const [
        '${assetPrefix}assets/fonts/Lato-Regular.ttf',
        '${assetPrefix}assets/fonts/Lato-Bold.ttf',
        '${assetPrefix}assets/fonts/Lato-Italic.ttf',
        '${assetPrefix}assets/fonts/Lato-BoldItalic.ttf',
      ];

  @override
  Future<Uint8List?> read(String source) async {
    if (source.startsWith(assetPrefix)) {
      final data = await rootBundle.load(source.substring(assetPrefix.length));
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    return _added[source];
  }

  @override
  Future<List<FontFaceInfo>> scanSystem() async => [];

  @override
  Future<List<FontFaceInfo>> imported() async => [];

  @override
  Future<String> storeImported(Uint8List bytes, String fileName) async {
    final source = 'added:${_added.length}:$fileName';
    _added[source] = bytes;
    return source;
  }
}
