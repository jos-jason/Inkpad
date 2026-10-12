import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdf/pdf.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import '../geometry/pathfinder.dart';
import '../model/drawing.dart';
import '../model/element.dart';
import '../model/geometry.dart';
import '../model/style.dart';
import 'raster_export.dart';

/// The drawing as a one-page vector PDF, the size of the page. Ported in
/// spirit from -[WDDrawing PDFRepresentation], which drew the drawing
/// into a PDF context.
///
/// Shapes, outlines, dashes, arrowheads, gradients, clipping masks,
/// opacity and blend modes stay vector (gradient outlines as filled
/// shapes); images are embedded at full
/// resolution; text is drawn as its letter shapes (so it looks the same
/// everywhere, but can't be selected as text). Shadows are embedded as
/// images under their shapes. Approximated: group opacity applies to each
/// member, reflected/repeated gradients pad, and see-through gradient
/// stops use one average opacity.
/// [compress] false keeps the page readable (for tests).
Future<Uint8List> drawingToPdf(InkDrawing d, {bool compress = true}) async {
  await prepareForExport(d);
  final doc = PdfDocument(compress: compress);
  PdfInfo(doc, creator: 'Inkpad', producer: 'Inkpad (Flutter)'); // registers itself
  final page = PdfPage(doc, pageFormat: PdfPageFormat(d.width, d.height));
  final g = page.getGraphics();
  final writer = _PdfWriter(doc, g);
  // PDF's y axis points up; flip so drawing coordinates work as they are.
  g.setTransform(_matrix(Affine(1, 0, 0, -1, 0, d.height)));
  for (final layer in d.layers) {
    if (!layer.visible) continue;
    for (final e in layer.elements) {
      await writer.element(e, layer.opacity, InkBlendMode.normal);
    }
  }
  return doc.save();
}

Matrix4 _matrix(Affine t) => Matrix4(t.a, t.b, 0, 0, t.c, t.d, 0, 0, 0, 0, 1, 0, t.tx, t.ty, 0, 1);

class _PdfWriter {
  final PdfDocument doc;
  final PdfGraphics g;
  final Map<String, PdfImage> _images = {};

  _PdfWriter(this.doc, this.g);

  static PdfColor _color(InkColor c) => PdfColor(c.red, c.green, c.blue);

  void _state(double fill, double stroke, InkBlendMode mode) => g.setGraphicState(PdfGraphicState(
        fillOpacity: fill.clamp(0.0, 1.0),
        strokeOpacity: stroke.clamp(0.0, 1.0),
        blendMode: mode == InkBlendMode.normal ? null : PdfBlendMode.values.byName(mode.name),
      ));

  void _addPath(InkPath p) {
    if (p.nodes.isEmpty) return;
    final a = p.nodes.first.anchorPoint;
    g.moveTo(a.dx, a.dy);
    for (final s in p.segments) {
      if (s.isStraight) {
        g.lineTo(s.b.dx, s.b.dy);
      } else {
        g.curveTo(s.outA.dx, s.outA.dy, s.inB.dx, s.inB.dy, s.b.dx, s.b.dy);
      }
    }
    if (p.closed) g.closePath();
  }

  void _addPaths(Iterable<InkPath> paths) => paths.forEach(_addPath);

  /// The shapes that make up [e]'s outline.
  static List<InkPath> _contours(InkStylable e) => switch (e) {
        InkPath p => [p],
        InkCompoundPath c => c.subpaths,
        InkTypography t => t.outlines,
        _ => const [],
      };

  Future<void> element(InkElement e, double alpha, InkBlendMode inherited) async {
    final a = alpha * e.opacity;
    final mode = e.blendMode == InkBlendMode.normal ? inherited : e.blendMode;
    final shadow = e.shadow;
    if (shadow != null) await _shadow(e, alpha, mode);
    switch (e) {
      case InkGroup group:
        for (final child in group.elements) {
          await element(child, a, mode);
        }
      case InkImage image:
        await _image(image, a, mode);
      case InkStylable s:
        await _stylable(s, a, mode);
      default:
        break;
    }
  }

  Future<void> _stylable(InkStylable e, double a, InkBlendMode mode) async {
    final contours = _contours(e);
    if (contours.isEmpty) return;
    final evenOdd = e.fillRule == FillRule.evenOdd;
    // Text may have letters in their own colors.
    final groups = e is InkTypography ? e.paintGroups : [(e.fill, contours)];
    for (final (fill, paths) in groups) {
      if (fill is InkColor) {
        g.saveContext();
        _state(fill.alpha * a, 1, mode);
        g.setFillColor(_color(fill));
        _addPaths(paths);
        g.fillPath(evenOdd: evenOdd);
        g.restoreContext();
      } else if (fill is InkGradient) {
        _gradient(fill, e.bounds, paths, evenOdd, a, mode);
      }
    }
    if (e.isMasking) {
      g.saveContext();
      _addPaths(contours);
      g.clipPath(evenOdd: evenOdd);
      for (final m in e.maskedElements) {
        await element(m, a, mode);
      }
      g.restoreContext();
    }
    final s = e.stroke;
    if (s != null && s.willRender) _stroke(e, s, contours, a, mode);
  }

  void _stroke(InkStylable e, StrokeStyle s, List<InkPath> contours, double a, InkBlendMode mode) {
    final g0 = s.gradient;
    if (g0 != null) {
      // PDF can't paint a gradient along a line: fill the outline's shape.
      final outline = Pathfinder.outlineStroke(e);
      if (outline != null) {
        _gradient(g0.copyWith(geometry: g0.fitted(e.bounds)), e.bounds, _contours(outline), false, a, mode);
      }
      return;
    }
    final arrows = e is InkPath ? e.arrowLayout : null;
    g.saveContext();
    _state(s.color.alpha * a, s.color.alpha * a, mode);
    g.setStrokeColor(_color(s.color));
    g.setFillColor(_color(s.color));
    g.setLineWidth(s.width);
    g.setLineCap(switch (s.cap) { LineCap.butt => PdfLineCap.butt, LineCap.round => PdfLineCap.round, LineCap.square => PdfLineCap.square });
    g.setLineJoin(switch (s.join) { LineJoin.miter => PdfLineJoin.miter, LineJoin.round => PdfLineJoin.round, LineJoin.bevel => PdfLineJoin.bevel });
    g.setMiterLimit(4);
    if (s.dashPattern.isNotEmpty) g.setLineDashPattern(s.dashPattern);
    final merged = arrows != null && s.color.alpha * a < 1 ? Pathfinder.outlineStroke(e) : null;
    if (merged != null) {
      // See-through: line and arrows as one shape, so they don't overlap.
      _addPaths(_contours(merged));
      g.fillPath();
    } else if (arrows != null) {
      _addPath(InkPath(nodes: arrows.line));
      g.strokePath();
      g.setLineDashPattern();
      _addPaths(arrows.arrowOutlines(s));
      g.fillPath(evenOdd: true);
    } else {
      _addPaths(contours);
      g.strokePath();
    }
    g.restoreContext();
  }

  /// A gradient: clip to the shape, then paint the shading across it.
  void _gradient(InkGradient fill, ui.Rect bounds, List<InkPath> contours, bool evenOdd, double a, InkBlendMode mode) {
    final geo = fill.fitted(bounds);
    final stops = fill.stops;
    final averageAlpha = stops.map((s) => s.color.alpha).reduce((x, y) => x + y) / stops.length;
    final function = PdfBaseFunction.colorsAndStops(
      doc,
      [for (final s in stops) _color(s.color)],
      [for (final s in stops) s.offset.clamp(0.0, 1.0)],
    );
    final radius = (geo.end - geo.start).distance;
    final focal = geo.focal ?? geo.start;
    final shading = fill.type == GradientType.linear
        ? PdfShading(
            doc,
            shadingType: PdfShadingType.axial,
            function: function,
            start: PdfPoint(geo.start.dx, geo.start.dy),
            end: PdfPoint(geo.end.dx, geo.end.dy),
            extendStart: true,
            extendEnd: true,
          )
        : PdfShading(
            doc,
            shadingType: PdfShadingType.radial,
            function: function,
            start: PdfPoint(focal.dx, focal.dy),
            end: PdfPoint(geo.start.dx, geo.start.dy),
            radius0: 0,
            radius1: radius,
            extendStart: true,
            extendEnd: true,
          );
    g.saveContext();
    _state(averageAlpha * a, 1, mode);
    _addPaths(contours);
    g.clipPath(evenOdd: evenOdd);
    // Shading geometry is in gradient space.
    g.setTransform(_matrix(geo.transform));
    g.applyShader(shading);
    g.restoreContext();
  }

  Future<void> _image(InkImage e, double a, InkBlendMode mode) async {
    final data = e.data;
    final img = _images[data.id] ??= await _pdfImage(data);
    g.saveContext();
    _state(a, a, mode);
    // Placement maps the image's pixel rectangle into the drawing; PDF
    // draws images upright in a unit square, so flip it back.
    g.setTransform(_matrix(e.placement));
    g.setTransform(_matrix(Affine(1, 0, 0, -1, 0, data.height.toDouble())));
    g.drawImage(img, 0, 0, data.width.toDouble(), data.height.toDouble());
    g.restoreContext();
  }

  Future<PdfImage> _pdfImage(ImageData data) async {
    // JPEGs go in as they are; other formats as pixels.
    if (data.mimeType == 'image/jpeg') {
      try {
        return PdfImage.jpeg(doc, image: data.bytes);
      } catch (_) {
        // Unusual JPEG: fall back to pixels.
      }
    }
    final image = await data.fullResolution();
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final result = PdfImage(doc, image: rgba!.buffer.asUint8List(), width: image.width, height: image.height);
    image.dispose();
    return result;
  }

  /// Shadows have no PDF equivalent: render each as a picture (at twice
  /// the page resolution) and place it under the element.
  Future<void> _shadow(InkElement e, double alpha, InkBlendMode mode) async {
    final shadow = e.shadow!;
    final area = e.paintBounds.inflate(2);
    const scale = 2.0;
    final w = math.max(1, (area.width * scale).ceil()), h = math.max(1, (area.height * scale).ceil());
    if (w * h > 8000 * 8000) return;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.scale(scale);
    canvas.translate(-area.left, -area.top);
    shadow.paint(canvas, e.styleBounds, () => e.renderElement(canvas));
    final image = await rec.endRecording().toImage(w, h);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    final img = PdfImage(doc, image: rgba!.buffer.asUint8List(), width: w, height: h);
    g.saveContext();
    _state(alpha, alpha, mode);
    g.setTransform(_matrix(Affine(1, 0, 0, -1, area.left, area.bottom)));
    g.drawImage(img, 0, 0, area.width, area.height);
    g.restoreContext();
  }
}
