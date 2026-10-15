import 'dart:io';
import 'dart:typed_data';

import 'package:inkpad/text/font_file.dart';
import 'package:inkpad/text/font_library.dart';

/// Bundled fonts read straight from the assets folder (no asset bundle in
/// unit tests), no system scan, and in-memory "imported" fonts.
class TestFontSource implements FontSource {
  final Map<String, Uint8List> _added = {};

  @override
  List<String> get bundled => const [
        'assets/fonts/Lato-Regular.ttf',
        'assets/fonts/Lato-Bold.ttf',
        'assets/fonts/Lato-Italic.ttf',
        'assets/fonts/Lato-BoldItalic.ttf',
      ];

  @override
  Future<Uint8List?> read(String source) async => _added[source] ?? File(source).readAsBytesSync();

  @override
  Future<List<FontFaceInfo>> scanSystem() async => [];

  @override
  Future<List<FontFaceInfo>> imported() async => [];

  @override
  Future<String> storeImported(Uint8List bytes, String fileName) async {
    final key = 'added:$fileName';
    _added[key] = bytes;
    return key;
  }
}

Future<void> initTestFonts() async {
  FontLibrary.instance = FontLibrary(TestFontSource());
  await FontLibrary.instance.init(scanSystem: false);
}
