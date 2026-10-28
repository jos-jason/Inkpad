import 'package:flutter/material.dart';

import 'library/drawing_store.dart';
import 'library/library_controller.dart';
import 'text/font_library.dart';
import 'ui/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled fonts load first; installed fonts are found in the background.
  await FontLibrary.instance.init();
  runApp(InkpadApp(library: LibraryController(DrawingStore())));
}

class InkpadApp extends StatelessWidget {
  final LibraryController library;

  const InkpadApp({super.key, required this.library});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Inkpad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0A84FF)),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF0A84FF), brightness: Brightness.dark),
      home: LibraryPage(library: library),
    );
  }
}
