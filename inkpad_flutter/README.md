# Inkpad (Flutter)

A cross-platform port of [Inkpad](https://github.com/sprang/Inkpad), the iPad
vector illustration app, to Flutter. Targets Android, iOS, Linux, macOS,
Windows and the web from one codebase.

The original Objective-C app lives alongside this folder and is used as the
reference implementation. Classes are ported by behaviour, not line-by-line;
each Dart class notes the Inkpad class it corresponds to.

## Running

```sh
flutter run -d macos     # or linux, windows, chrome, an Android device…
flutter test
```

## Layout

| Dart | Inkpad original |
| --- | --- |
| `lib/model/bezier_node.dart` | `WDBezierNode`, `WDBezierSegment` |
| `lib/model/element.dart` | `WDElement`, `WDPath`, `WDGroup` |
| `lib/model/drawing.dart` | `WDDrawing`, `WDLayer` |
| `lib/model/style.dart` | `WDColor`, `WDStrokeStyle` |
| `lib/controller/drawing_controller.dart` | `WDDrawingController`, `WDPropertyManager` |
| `lib/tools/` | `Inkpad-Core/Tools/*` |
| `lib/ui/drawing_canvas.dart` | `WDCanvas` |

## Status

Done:
- Document model: layers, paths, groups, fill, stroke, opacity
- Tools: select / move / node & handle editing, pen, add/delete point
  (Alt-click converts corner/smooth), rectangle, oval, star,
  polygon, line, hand
- Pan & zoom: pinch, trackpad, ctrl/cmd + scroll wheel, space-drag, middle mouse
- Undo/redo, duplicate, group/ungroup, arrange, layers (add, delete, hide, lock)
- SVG export, native save/open (`.inkpad` JSON), copy SVG to clipboard
- Responsive layout (side panels on desktop/tablet, bottom bar on phones)

To port next (roughly in priority order):
- SVG import (`Inkpad-Core/SVG`)
- Scale / rotate tools and a transform bounding box
- Compound paths, masks
- Gradients and fill transforms (`WDGradient`, `WDFillTransform`)
- Boolean path operations (`WDPathfinder` / livarot). Note: livarot comes from
  Inkscape; check its license before porting it rather than reimplementing.
- Freehand tool with curve fitting (`CurveFit`), scissors, eraser
- Text and text-on-path, images, shadows, arrowheads, dash patterns UI
- Snapping (grid, points, edges), rulers, PDF/PNG export
- Full color picker

## Keyboard shortcuts

V select · P pen · A add/delete point · R rect · E oval · S star · G polygon · L line · H hand ·
Ctrl/Cmd+Z undo · Shift+Ctrl/Cmd+Z redo · Ctrl/Cmd+D duplicate ·
Ctrl/Cmd+G group · Shift+Ctrl/Cmd+G ungroup · Ctrl/Cmd+S save · Ctrl/Cmd+O open ·
Ctrl/Cmd+E export SVG · Delete remove · Esc/Enter finish path ·
+/- zoom · 0 fit · 1 actual size

Modifiers while dragging: Shift constrains, Alt/Option draws shapes from the
center or breaks handle symmetry.

## License

Mozilla Public License 2.0, same as the original Inkpad.
