import 'package:flutter/material.dart';

import 'library/drawing_store.dart';
import 'library/library_controller.dart';
import 'ui/library_page.dart';

void main() => runApp(InkpadApp(library: LibraryController(DrawingStore())));

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
