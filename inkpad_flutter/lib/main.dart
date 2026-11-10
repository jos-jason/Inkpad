import 'dart:async';

import 'package:flutter/material.dart';

import 'library/drawing_store.dart';
import 'library/library_controller.dart';
import 'sync/inkpad_sync.dart';
import 'text/font_library.dart';
import 'ui/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled fonts load first; installed fonts are found in the background.
  await FontLibrary.instance.init();
  final inner = DrawingStore();
  final store = SyncingDrawingStore(inner);
  final library = LibraryController(store);
  final sync = InkpadSync(library: library, inner: inner, settings: DeviceSyncSettingsStore());
  store.sync = sync;
  InkpadSync.instance = sync;
  runApp(InkpadApp(library: library));
  // Starts once the gallery has loaded the drawings on this device.
  unawaited(sync.init());
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
