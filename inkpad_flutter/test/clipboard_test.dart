import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/controller/drawing_controller.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/model/element.dart';

double mm(double v) => v * 72 / 25.4;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A pretend system clipboard.
  String? system;
  setUp(() {
    system = null;
    DrawingController.clearClipboard();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') system = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return system == null ? null : {'text': system};
      return null;
    });
  });

  DrawingController make({bool makeMode = true, double w = 600, double h = 400}) {
    final c = DrawingController(drawing: InkDrawing(width: mm(w), height: mm(h), units: 'mm'));
    if (makeMode) c.setMakeMode(true);
    return c;
  }

  InkPath panel() => InkPath.live(LiveShape.inRect(LiveKind.rectangle, Rect.fromLTWH(mm(20), mm(30), mm(120), mm(80)), cornerRadius: mm(5)))
    ..cut = CutSpec(CutType.exterior, depth: mm(12));

  test('copy in one drawing, paste in another', () async {
    final a = make(), b = make();
    final p = panel();
    a.addElement(p);
    a.select(p);
    a.copySelection();
    await b.paste();
    final pasted = b.drawing.allElements.single as InkPath;
    expect(pasted.live!.width, closeTo(mm(120), 1e-9));
    expect(pasted.live!.cornerRadius, closeTo(mm(5), 1e-9));
    expect(pasted.cut!.type, CutType.exterior);
    expect(pasted.bounds, p.bounds); // in place
    expect(b.selection.single, same(pasted));
  });

  test('after a restart (or from another device) the system clipboard still pastes everything', () async {
    final a = make();
    final p = panel();
    a.addElement(p);
    a.select(p);
    a.copySelection();
    await Future<void>.delayed(Duration.zero);
    expect(system, contains('<svg'));
    DrawingController.clearClipboard(); // as after quitting
    final b = make();
    await b.paste();
    final pasted = b.drawing.allElements.single as InkPath;
    expect(pasted.live!.kind, LiveKind.rectangle);
    expect(pasted.cut!.depth, closeTo(mm(12), 1e-9));
  });

  test('SVG copied in another app pastes; shapes off a smaller page land in its middle', () async {
    system = '<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="2000"><rect x="1500" y="1500" width="100" height="50" fill="red"/></svg>';
    final b = make(makeMode: false, w: 100, h: 100);
    await b.paste();
    final pasted = b.drawing.allElements.single;
    expect(pasted.bounds.size, const Size(100, 50));
    expect(pasted.bounds.center.dx, closeTo(b.drawing.width / 2, 1e-6));
  });

  test('nothing to paste', () async {
    final b = make();
    String? hint;
    b.hint.addListener(() => hint = b.hint.value);
    await b.paste();
    expect(b.drawing.allElements, isEmpty);
    expect(hint, contains('Nothing to paste'));
  });
}
