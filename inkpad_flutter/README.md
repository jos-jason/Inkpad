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
| `lib/svg/` | `Inkpad-Core/SVG/*` |
| `lib/library/`, `lib/ui/library_page.dart` | `WDDrawingManager`, `WDBrowserController` |

## Status

Done:
- Document model: layers, paths, compound paths (shapes with holes), groups,
  fill, stroke (incl. dashes), opacity
- Gradients (linear and radial, any number of stops, pad/reflect/repeat):
  Solid / Linear / Radial fill picker, tap a stop to recolor it, add/remove/
  reverse stops, drag the start/end handles on the canvas with the select tool
- Images (port of WDImage/WDImageData): Place image… (Shift+Ctrl/Cmd+P, or the
  photo button; the photo library on phones). PNG, JPEG (EXIF rotation
  honoured), GIF, WebP, BMP. Placed centered and scaled down to fit, stored
  once per drawing however often they're used, and can be clipped by masks
- Scale handles: drag a selection corner with the select tool to resize
  (proportional; Shift for free, Alt from the center)
- Rotation: the knob above a selection (select tool), or the Rotate tool
  (port of WDRotateTool: tap to move the pivot, drag to rotate; O). Shift
  snaps to 15°. Rotate 90° left/right and Flip horizontally/vertically
  (as in Inkpad) in the menu
- Clipping masks, as in Inkpad: select shapes, then Make clipping mask
  (Ctrl/Cmd+7); the topmost shape clips the rest. Release clipping mask
  (Shift+Ctrl/Cmd+7) puts them back
- Tools: select / move / scale / rotate / node & handle editing (double-click
  or double-tap a point to add or remove its handles), pen, add/delete point
  (Alt-click converts corner/smooth), rectangle, oval, star,
  polygon, line, hand
- Pan & zoom: pinch, trackpad, ctrl/cmd + scroll wheel, space-drag, middle mouse
- Undo/redo, duplicate, group/ungroup, arrange, layers (add, delete, hide, lock)
- Library of drawings (like Inkpad's gallery): thumbnails, newest first,
  new / open / rename / duplicate / delete, import `.svg` and `.inkpad` files.
  Drawings autosave as you edit. Stored as `.inkpad` files in the app's
  support folder (browser storage on the web).
- SVG and `.inkpad` export, copy SVG to clipboard
- SVG import (`lib/svg/`): paths (all commands incl. arcs), basic shapes,
  groups, `use`/`symbol`, transforms, inherited styles, CSS `<style>` rules
  (tag, class, id, descendant and child selectors), fill rules, units.
  Top-level groups become layers, as in Inkpad (Inkscape layers too).
  Gradients and clip paths import as real gradients and clipping masks;
  embedded images are imported (with preserveAspectRatio);
  solid masks become clipping masks, soft masks (fades) are approximated with
  even transparency; gradient outlines become a solid color; linked (not
  embedded) images and text are skipped. Anything approximated is reported after import.
  Tested against ~3,000 real-world SVGs. "Place SVG…" in the editor adds an
  SVG to the open drawing.
- Responsive layout (side panels on desktop/tablet, bottom bar on phones)

To port next (roughly in priority order):
- Releasing compound paths; gradient outlines (strokes)
- Boolean path operations (`WDPathfinder` / livarot). Note: livarot comes from
  Inkscape; check its license before porting it rather than reimplementing.
- Freehand tool with curve fitting (`CurveFit`), scissors, eraser
- Text and text-on-path (and SVG text import), shadows, arrowheads, dash patterns UI
- Snapping (grid, points, edges), rulers, PDF/PNG export
- Full color picker

## Keyboard shortcuts

V select · O rotate · P pen · A add/delete point · R rect · E oval · S star · G polygon · L line · H hand ·
Ctrl/Cmd+Z undo · Shift+Ctrl/Cmd+Z redo · Ctrl/Cmd+D duplicate ·
Ctrl/Cmd+G group · Shift+Ctrl/Cmd+G ungroup · Ctrl/Cmd+S save now ·
Ctrl/Cmd+E export SVG · Ctrl/Cmd+7 make clipping mask ·
Shift+Ctrl/Cmd+7 release clipping mask · Delete remove · Esc/Enter finish path ·
+/- zoom · 0 fit · 1 actual size

Modifiers while dragging: Shift constrains, Alt/Option draws shapes from the
center or breaks handle symmetry.

## License

Mozilla Public License 2.0, same as the original Inkpad.
