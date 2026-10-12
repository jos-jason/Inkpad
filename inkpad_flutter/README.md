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
| `lib/model/text.dart`, `lib/text/` | `WDText`, `WDTextPath`, `WDFontManager` |

## Status

Interface: modelled on Inkpad's iPad layout — a full-screen canvas with
rulers and floating panels: Gallery / title & zoom / zoom, place, settings,
share along the top; a tool palette with fly-outs on the left (with tool
options such as corner radius, star points, polygon sides); Edit / Arrange /
Path menus, undo/redo, and shadow & opacity, stroke, fill and Layers popovers
along the bottom. On phones the same panels share the width and popovers
open as bottom sheets. Items not built yet are shown greyed out.

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
- Direct Select tool (A): select points on any path (including inside
  groups, compound paths and masks) by clicking, Shift-clicking or dragging a
  marquee; drag to move them, drag a selected point's handles, double-click
  to add/remove handles, Delete to remove points
- Path menu (ported from Inkpad's): add / delete anchor points, join paths,
  outline stroke (keeps any fill beneath), combine / separate paths, reverse
  direction, unite / intersect / subtract front / exclude, mask / unmask.
  Shape operations (`lib/geometry/`) flatten curves, combine the polygons with
  Clipper2, then refit beziers — as Inkpad's livarot engine did — keeping
  corners and crossing points sharp and straight edges straight
- Freehand (F, closed filled shapes) and Brush (B, open lines), smoothed with
  Schneider curve fitting as Inkpad's WDCurveFit did
- Eraser (Shift+E, size 1–100 pt): erases the selection, or everything when
  nothing is selected; shapes lose the area, lines are cut into pieces
- Scissors (C): cut a line or point; open paths split in two, closed ones open
- Eyedropper (I): copy a shape's fill, stroke and opacity onto the selection
  and the current style (or a photo's pixel color as the fill)
- Spiral shape with Decay option (10–99%)
- Text (T), as in Inkpad: drag a box for wrapping text, tap for point text,
  tap existing text (or double-click it with the select tool) to edit it.
  The Text panel (Tt) sets font, style, size and alignment for the selection
  and new text. Path menu: Create Outlines from Text, and Place Text on Path
  (drag the start handle to slide the text along). Letters are drawn from
  the font's own outlines, so the screen, SVG export and outlines match.
- Fonts: the fonts installed on the device (macOS, Linux, Windows, Android;
  scanned in the background and cached) plus Lato, bundled. "Add Font…" in
  the Text panel adds a .ttf/.otf/.ttc to the app without installing it
  system-wide. Browsers don't expose installed fonts, so the web version has
  Lato plus fonts added during the session. Text whose font is missing is
  drawn with Lato and keeps its font name, so it comes back on a device
  that has the font
- Edit menu: select all / in layer, deselect, cut, copy, paste, duplicate,
  duplicate in place, transform again, duplicate & transform again, delete
- Arrange menu: forward/backward one step, front/back, flip, rotate 90°,
  distribute, group/ungroup, align left/center/right/top/middle/bottom
- Stroke panel: HSB/alpha/hex color, caps, joins, width, dash & gap pairs,
  and arrowheads (Inkpad's 10: arrows, bar, circles, squares, diamonds;
  plus three chubby, rounded ones: arrow, notched arrow, open arrow; start
  and end chosen separately, Swap). Ported from WDArrowhead: the line
  is trimmed so it meets the arrow cleanly, arrows follow the path's
  direction and scale with the stroke width; reversing a path keeps them in
  place, Outline Stroke includes them, and SVG export/import keeps them
- Fill panel: none / color / gradient, draggable gradient stops
- Layers panel: add, duplicate, delete, rename, show/hide, lock, highlight
  color, drag to reorder, opacity
- Shadow & opacity panel (port of WDShadowController): drop shadow with
  HSB/alpha/hex color, angle dial, offset and blur (0–50 pt); opacity; and
  Inkpad's 16 blend modes (multiply, screen, overlay…). New shapes take the
  current settings. Exported to SVG as `feDropShadow` filters and
  `mix-blend-mode`; drop shadows (including the blur + offset recipe) and
  blend modes import back
- Color menu (the color wheel; port of Inkpad's color actions): blend
  colors back to front, horizontally or vertically across three or more
  shapes; Color Balance… and Hue and Saturation… with live preview (Cancel
  puts the colors back); Desaturate; Invert. Adjustments reach fills,
  gradient stops, outlines and shadows, inside groups and masks too (images
  are left as they are, as in Inkpad)
- Snapping (Settings), ported from Inkpad: Snap to Points, Snap to Edges
  (including the page edges), Snap to Grid, Show Grid and Grid Spacing.
  Shapes, lines, pen points and handles, text boxes, dragged points and
  moved or scaled selections snap; a marker shows what was snapped to
- Rulers in in/cm/mm/pt/px (Settings)
- Scale tool (port of WDScaleTool), alongside the scale handles
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
- PNG export (1×–4×, white or transparent background) and vector PDF export
  (Share menu). The PDF keeps shapes, outlines, dashes, arrowheads,
  gradients, clipping masks, opacity and blend modes as vectors and embeds
  images at full resolution; text is drawn as letter shapes, shadows as
  images. Approximated: group opacity applies per member, reflected or
  repeated gradients pad, see-through gradient stops use one opacity
- SVG import (`lib/svg/`): paths (all commands incl. arcs), basic shapes,
  groups, `use`/`symbol`, transforms, inherited styles, CSS `<style>` rules
  (tag, class, id, descendant and child selectors), fill rules, units.
  Top-level groups become layers, as in Inkpad (Inkscape layers too).
  Gradients and clip paths import as real gradients and clipping masks;
  embedded images are imported (with preserveAspectRatio);
  solid masks become clipping masks, soft masks (fades) are approximated with
  even transparency; gradient outlines become a solid color; linked (not
  embedded) images are skipped. Text and text on a path import as editable
  text (one font per text object). Anything approximated is reported after import.
  Tested against ~3,000 real-world SVGs. "Place SVG…" in the editor adds an
  SVG to the open drawing.
- Responsive layout (side panels on desktop/tablet, bottom bar on phones)

To port next (roughly in priority order; greyed out in the UI):
- AI edit (placeholder button for now)
- Per-letter styling (mixed fonts/colors within one text)
- Releasing compound paths; gradient outlines (strokes)
- Full color picker

## Keyboard shortcuts

V select · A direct select · O rotate · K scale · P pen · N add/delete point ·
C scissors · B brush · F freehand · Shift+E eraser · I eyedropper · T text · R rect · E oval · S star · G polygon · L line · H hand ·
Ctrl/Cmd+Z undo · Shift+Ctrl/Cmd+Z redo · Ctrl/Cmd+D duplicate ·
Ctrl/Cmd+G group · Shift+Ctrl/Cmd+G ungroup · Ctrl/Cmd+S save now ·
Ctrl/Cmd+E export SVG · Ctrl/Cmd+7 make clipping mask ·
Shift+Ctrl/Cmd+7 release clipping mask · Delete remove · Esc/Enter finish path ·
+/- zoom · 0 fit · 1 actual size

Modifiers while dragging: Shift constrains, Alt/Option draws shapes from the
center or breaks handle symmetry.

## Third-party code

- [Clipper2](https://pub.dev/packages/clipper2) (polygon boolean operations
  and offsetting) — Boost Software License 1.0
- [glyph_path](https://pub.dev/packages/glyph_path) (reading TrueType/OpenType
  outlines, kerning and ligatures) — BSD 3-Clause
- [pdf](https://pub.dev/packages/pdf) (writing PDF files) — Apache License 2.0
- [Lato](https://fonts.google.com/specimen/Lato) (bundled fallback font) —
  SIL Open Font License 1.1 (`assets/fonts/Lato-OFL.txt`)

## License

Mozilla Public License 2.0, same as the original Inkpad.
