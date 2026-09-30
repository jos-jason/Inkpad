import 'package:flutter/material.dart';

import 'ui/editor_page.dart';

void main() => runApp(const InkpadApp());

class InkpadApp extends StatelessWidget {
  const InkpadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Inkpad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0A84FF)),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF0A84FF), brightness: Brightness.dark),
      home: const EditorPage(),
    );
  }
}
