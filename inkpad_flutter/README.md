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
# In Xcode (iPhone, iPad): open "Inkpad Cross-Platform.xcworkspace" at
# the top of the repo and run the "Inkpad Cross-Platform" scheme.
# ("Inkpad (original 2013 iPad app).xcodeproj" beside it is the original iPad app.)
flutter test
```

TestFlight: every push to the `cross-platform` branch builds the iOS app on
a GitHub Mac and uploads it to TestFlight
([.github/workflows/testflight.yml](../.github/workflows/testflight.yml)),
once the App Store Connect API key secrets described there are added.

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
- Multi-Select tool (A, the arrow with a plus; Inkpad's group select):
  every tap adds to the selection, and a tap on something already
  selected takes it away. Tap objects to add them; drag any selected one
  to move them all. Selected objects show their points: tap points to add
  them (on any path, including inside groups, compound paths and masks),
  drag a selected point to move all the selected points (with several
  objects selected, any drag moves the objects whole), drag a selected
  point's handles, double-tap a point to add/remove its handles or a
  handle to remove just that one; drag on empty space
  to add the points in a rectangle, tap it to select nothing; Delete
  removes the selected points
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
- Per-letter styling (beyond Inkpad): while typing, select letters and
  change the font, style or size in the Text panel, or the color in the
  Fill panel, for just those letters. Lines wrap across styles and grow to
  fit their biggest letters; new letters take the style before them.
  Kept in `.inkpad` files, SVG (nested tspans, read back exactly), PDF and
  Create Outlines (one shape per color); styled tspans from other apps'
  SVGs come in as styled letters
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
- Stroke panel: None / Color / Gradient (gradient outlines go beyond
  Inkpad: linear or radial along the shape, turning with it; kept in SVG
  import/export, Outline Stroke, the color menu and PDF), caps, joins,
  width, dash & gap pairs,
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
- Settings → Canvas size…: any width and height (in any unit), presets
  (paper, screen and sheet-goods sizes), which part of the page the
  artwork stays with, or fit the page to the artwork with a margin
- Rulers in in/cm/mm/pt/px (Settings)
- Scale tool (port of WDScaleTool, K): tap to move the pivot, drag to scale
  (proportional; Shift for free). As in Inkpad, the select tool has no
  scale handles or rotation knob
- Rotation: the Rotate tool
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
  Drawings autosave as you edit. Search (by name, portfolio, or any text in
  a drawing). Portfolios group drawings like folders: create, rename,
  delete (keeping or deleting their drawings), "Move to Portfolio…", or
  press and hold a drawing and drop it on a portfolio. New drawings ask
  for a name first. Rename a drawing
  from inside it by tapping its name at the top. Stored as `.inkpad` files in the app's
  support folder (browser storage on the web).
- SVG and `.inkpad` export, copy SVG to clipboard
- Copy and paste between drawings: Copy in one, open another, Paste (in
  place; shapes that would land off a smaller page go in its middle).
  Copied shapes also go on the system clipboard, so they paste with
  everything kept (live shapes, cuts, text, images) after a restart or on
  another device through Universal Clipboard, and paste into other apps as
  SVG; SVG copied from other apps pastes in too
- Make mode (Settings → Make mode), for CNC routers such as the Shaper
  Origin, laser cutters and other cutting tools, inspired by Shaper Studio:
  - Exact sizes in mm (to 0.001 mm), cm or inches (decimal, or fractions
    to 1/64″). Lengths can be typed in any unit and as sums: `1 3/8"`,
    `1-3/8"`, `2' 6"`, `25.4mm`, `300-2*12`.
  - Shapes keep their dimensions ("live" shapes): rectangles (with corner
    radius), ellipses, polygons, stars and lines stay editable by number
    through moves, rotations and resizing, until Path → Convert to Path.
  - The selection's overall width and height are drawn as dimension lines
    on the canvas; tap a number to type a new size. A numbers bar shows
    X, Y, width, height (with a proportion lock), angle, corner radius,
    sides.
  - Cuts: each shape is an Exterior, Interior, On line, Pocket or Guide
    cut (Shaper Origin's types, in its colors), with its own depth and
    offset; material thickness, bit diameter and default depth in
    Settings.
  - SVG export at true size (mm or in) with Shaper's `shaper:cutDepth`
    and letters as outlines; Shaper files open in Make mode with their
    cut types read from their colors.
  - Cut preview (Settings): the bit's path at its real width, and the area
    pockets clear, so rounded inside corners show before cutting.
  - Path → Add Dogbones / Add T-bones: corner relief for the bit (ears past
    a hole's corners, notches in a part's inside corners; T-bones past a
    slot's ends). Path → Box Maker…: a finger-jointed box (outside or
    inside sizes, material thickness, finger width, fit clearance, lid,
    dogbones) laid out flat as cut-through panels.
  - Path → Offset Path… (grow or shrink by a distance, round or sharp
    corners); Edit → Repeat… (grids by center-to-center spacing, or copies
    around a center).
  - Snapping also finds midpoints, centers of live shapes and where edges
    cross; the Measure tool (M) shows distance, across, down and angle.
  - DXF export (R12, for CAD/CAM and laser software) at true size: live
    circles as circles, rounded corners as true arcs, a layer per cut type
    named with its depth (e.g. POCKET_D6MM).
  - DXF import (gallery import and Place): lines, polylines with arcs,
    circles, arcs, ellipses, splines and blocks; touching pieces joined
    into outlines; true size from the file's units.
  - Joinery tool (J): click a part's straight edge for fingers or tabs, or
    a straight line for matching slots (tab-and-slot), with fit clearance
    and dogbones.
  - Export G-code… (GRBL and similar routers): profiles offset by the bit,
    pockets cleared in rings, depth passes, holding tabs on through-cuts,
    conventional or climb milling, pockets and holes before parts; a
    preview to play the job through, with cut length and time.
  - Measurements (Path → Measurements…, or Settings): named sizes such as
    `thickness = 12` or `inner = width - 2*thickness` (lengths, or plain
    numbers for counts). Any size box takes them by name
    (`width/2 - thickness`, `2 thickness + 3mm`); sizes and positions typed
    that way are kept as formulas (marked ƒ), so shapes follow when a
    measurement changes. Renaming one renames it everywhere.
  - Arrange → Pin to Shape…: keeps the selected shapes in place on the
    largest one (a distance from its left/right/top/bottom edge, or
    centred), so holes and slots follow a panel when it's moved or resized.
    Moving a pinned shape by hand sets its new distance; distances can use
    measurements.
  - Constraints tool (D), a CAD-style sketch solver: coincident (and point
    on line or circle), horizontal, vertical, parallel, perpendicular,
    collinear, equal, tangent, concentric, midpoint, symmetric and fix, on
    shapes' corners, centres, edges and circles; dimensions (length,
    distance, across, up/down, angle, radius, diameter) that drive the
    geometry, typed as numbers or with measurements, or kept as references.
    Shapes being dragged or resized stay where you put them and the rest
    follow; conflicting or redundant constraints are refused. While the
    tool is on, fully constrained shapes show green and the bar counts the
    degrees of freedom left. Click a mark to pick it (Delete removes it);
    double-click a dimension to change it.
- AI (the ✨ button), with your own account: Claude (Anthropic), any
  OpenAI-compatible service (OpenAI, OpenRouter, Groq, LM Studio, Gemini's
  compatible endpoint…), or Ollama on your computer or network. Set it up
  in Settings → AI services: address, API key (kept in the device's secure
  storage), a quick model for edits and a drawing model. **Edit** describes
  a change ("make the title red and bigger", "align these"); the quick
  model answers with operations Inkpad checks and applies (fills,
  gradients, strokes and arrowheads, opacity, shadows, moving, resizing,
  rotating, aligning, arranging, grouping, text and fonts, new shapes).
  **Draw** describes new artwork; the drawing model answers with SVG,
  placed in the middle of the page or in the selected area. Results show
  on the canvas at once: Keep, Undo, or say what to change. Models that
  can see get a picture of the drawing; models without tool calling
  answer in JSON instead. Requests go straight from the device to the
  service, only when you ask (`lib/ai/`)
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
  even transparency; linked (not
  embedded) images are skipped. Text and text on a path import as editable
  text (styled tspans become styled letters). Anything approximated is reported after import.
  Tested against ~3,000 real-world SVGs. "Place SVG…" in the editor adds an
  SVG to the open drawing.
- Responsive layout (side panels on desktop/tablet, bottom bar on phones)

To port next (roughly in priority order; greyed out in the UI):
- Full color picker

## Keyboard shortcuts

V select · A multi-select · O rotate · K scale · P pen · N add/delete point ·
C scissors · B brush · F freehand · Shift+E eraser · I eyedropper · T text · M measure · J joinery · D constraints · R rect · E oval · S star · G polygon · L line · H hand ·
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
- [http](https://pub.dev/packages/http) — BSD 3-Clause;
  [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) — BSD 3-Clause
- [Lato](https://fonts.google.com/specimen/Lato) (bundled fallback font) —
  SIL Open Font License 1.1 (`assets/fonts/Lato-OFL.txt`)

## License

Mozilla Public License 2.0, same as the original Inkpad.
