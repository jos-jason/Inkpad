import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/main.dart';
import 'package:inkpad/model/element.dart';

final class _FakeFile extends PlatformFile {
  @override
  final String name;
  final Uint8List bytes;

  _FakeFile(this.name, String text) : bytes = Uint8List.fromList(utf8.encode(text));

  @override
  Uri get uri => Uri.parse('memory:///$name');
  @override
  XFile get xFile => XFile.fromData(bytes, name: name);
  @override
  int? lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _FakePicker extends FilePickerPlatform {
  List<PlatformFile> next = [];
  List<String>? lastExtensions;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    lastExtensions = allowedExtensions;
    return next;
  }
}

const _logo = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">'
    '<g id="Shapes"><circle cx="50" cy="50" r="40" fill="tomato"/><rect x="110" y="10" width="80" height="80"/></g>'
    '<foreignObject width="10" height="10"/></svg>';

void main() {
  late _FakePicker picker;
  setUp(() => FilePickerPlatform.instance = picker = _FakePicker());

  testWidgets('library imports SVG files and reports what was skipped', (tester) async {
    final lib = LibraryController(MemoryDrawingStore());
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();

    picker.next = [_FakeFile('Logo.svg', _logo), _FakeFile('broken.svg', '<svg')];
    await tester.tap(find.byTooltip('Import SVG or .inkpad files'));
    await tester.pumpAndSettle();

    expect(picker.lastExtensions, containsAll(['svg', 'inkpad']));
    expect(lib.drawings.single.name, 'Logo');
    final d = lib.drawings.single.drawing;
    expect(d.width, 200);
    expect(d.layers.single.name, 'Shapes');
    expect(d.allElements.length, 2);
    expect(find.text('Logo'), findsOneWidget);

    // One snackbar per outcome: the broken file, then the import summary.
    expect(find.textContaining('Could not open "broken.svg"'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Imported "Logo", with some differences'), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('• Skipped 1 embedded HTML element'), findsOneWidget);
  });

  testWidgets('Place SVG adds a selected, undoable group to the open drawing', (tester) async {
    final lib = LibraryController(MemoryDrawingStore());
    await tester.pumpWidget(InkpadApp(library: lib));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New drawing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    picker.next = [_FakeFile('Logo.svg', _logo)];
    await tester.tap(find.byTooltip('Place image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Place SVG…'));
    await tester.pumpAndSettle();

    expect(picker.lastExtensions, ['svg']);
    await tester.pump(const Duration(seconds: 1)); // autosave
    final layer = lib.drawings.single.drawing.activeLayer;
    expect(layer.elements.single, isA<InkGroup>());
    expect((layer.elements.single as InkGroup).elements.length, 2);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(lib.drawings.single.drawing.allElements, isEmpty);
  });
}
