import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Color, Offset, Paint, PaintingStyle, Rect;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'element.dart';
import 'geometry.dart';

/// The bytes of an image file plus what we know about it without decoding.
/// Ported from WDImageData: images are content-addressed (by SHA-1, as in
/// Inkpad) so a picture placed several times is stored once.
class ImageData {
  final String id;
  final Uint8List bytes;
  final String mimeType;

  /// Size in pixels, upright (EXIF rotation already applied).
  final int width, height;

  ImageData._(this.id, this.bytes, this.mimeType, this.width, this.height);

  static final Map<String, ImageData> _registry = {};

  /// Bumped whenever an image finishes decoding, so views can repaint.
  static final ValueNotifier<int> decodes = ValueNotifier(0);

  /// Registers image file [bytes]; returns null if the format isn't
  /// recognised (PNG, JPEG, GIF, WebP and BMP are).
  static ImageData? register(Uint8List bytes) {
    final info = sniffImage(bytes);
    if (info == null) return null;
    final id = sha1.convert(bytes).toString();
    return _registry.putIfAbsent(id, () => ImageData._(id, bytes, info.mimeType, info.width, info.height));
  }

  static ImageData? lookup(String id) => _registry[id];

  String get dataUri => 'data:$mimeType;base64,${base64Encode(bytes)}';

  // ---- Decoding, for display ---------------------------------------------

  /// Large images are decoded at no more than this many pixels per side for
  /// display (Inkpad downsampled placed photos similarly); the file keeps
  /// the full-resolution original.
  static const maxDisplaySide = 4096;

  ui.Image? _decoded;
  bool _decoding = false;
  bool decodeFailed = false;

  /// The decoded image, or null while it's still decoding (decoding starts
  /// on first request).
  ui.Image? get decoded {
    if (_decoded == null && !_decoding && !decodeFailed) _decode();
    return _decoded;
  }

  ByteData? _pixels;
  bool _loadingPixels = false;

  /// Starts reading the decoded pixels (for the eyedropper).
  void loadPixels() {
    final img = decoded;
    if (img == null || _pixels != null || _loadingPixels) return;
    _loadingPixels = true;
    img.toByteData(format: ui.ImageByteFormat.rawStraightRgba).then((b) {
      _pixels = b;
      _loadingPixels = false;
      decodes.value++;
    });
  }

  /// The color at [natural] (in the image's own pixel coordinates), once
  /// [loadPixels] has finished; null otherwise or outside the image.
  (double, double, double, double)? pixelAt(Offset natural) {
    final img = _decoded, bytes = _pixels;
    if (img == null || bytes == null) return null;
    final x = (natural.dx / width * img.width).floor(), y = (natural.dy / height * img.height).floor();
    if (x < 0 || y < 0 || x >= img.width || y >= img.height) return null;
    final i = (y * img.width + x) * 4;
    return (bytes.getUint8(i) / 255, bytes.getUint8(i + 1) / 255, bytes.getUint8(i + 2) / 255, bytes.getUint8(i + 3) / 255);
  }

  Future<void> _decode() async {
    _decoding = true;
    try {
      final scale = math.min(1.0, maxDisplaySide / math.max(width, height));
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: scale < 1 ? (width * scale).round() : null,
        targetHeight: scale < 1 ? (height * scale).round() : null,
      );
      _decoded = (await codec.getNextFrame()).image;
    } catch (e) {
      decodeFailed = true;
      debugPrint('Could not decode image $id: $e');
    }
    _decoding = false;
    decodes.value++;
  }
}

/// A placed bitmap image. Ported from WDImage.
class InkImage extends InkElement {
  final ImageData data;

  /// Maps image pixel space (0..width, 0..height) into the document.
  Affine placement;

  InkImage(this.data, {this.placement = Affine.identity, super.opacity});

  Rect get naturalRect => Rect.fromLTWH(0, 0, data.width.toDouble(), data.height.toDouble());

  /// Corners in document space: top-left, top-right, bottom-right, bottom-left.
  List<Offset> get corners {
    final r = naturalRect;
    return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map(placement.apply).toList();
  }

  @override
  Rect get bounds {
    final c = corners;
    return c.skip(1).fold(Rect.fromPoints(c[0], c[0]), (r, p) => r.expandToInclude(Rect.fromPoints(p, p)));
  }

  @override
  void renderElement(Canvas canvas) {
    canvas.save();
    canvas.transform(Float64List.fromList(placement.toMatrix4()));
    final r = naturalRect;
    final img = data.decoded;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        r,
        Paint()
          ..filterQuality = ui.FilterQuality.medium
          ..color = Color.fromRGBO(0, 0, 0, opacity),
      );
    } else {
      // Placeholder while decoding (or if the image can't be read): a box
      // with an X, like Inkpad's outline view of images.
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / placement.scaleFactor
        ..color = const Color(0x66000000);
      canvas.drawRect(r, Paint()..color = const Color(0x11000000));
      canvas.drawRect(r, line);
      canvas.drawLine(r.topLeft, r.bottomRight, line);
      canvas.drawLine(r.topRight, r.bottomLeft, line);
    }
    canvas.restore();
  }

  @override
  void transform(Affine t) => placement = placement.then(t);

  @override
  bool hitTest(Offset pt, double tolerance) {
    final local = placement.inverted().apply(pt);
    return naturalRect.inflate(tolerance / placement.scaleFactor).contains(local);
  }

  @override
  String elementSvg(SvgWriter w) {
    final id = w.image(data);
    final t = placement;
    final m = [t.a, t.b, t.c, t.d, t.tx, t.ty].map(fmt).join(' ');
    return '<use xlink:href="#$id" transform="matrix($m)"${opacityAttr()}/>';
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'image': data.id,
        'placement': placement.toJson(),
        ...effectsJson(),
      };

  factory InkImage.fromJson(Map<String, dynamic> j) {
    final data = ImageData.lookup(j['image'] as String);
    if (data == null) throw FormatException('Missing image data ${j['image']}');
    return InkImage(data, placement: Affine.fromJson(j['placement']))..readEffectsJson(j);
  }
}

/// Format and pixel size read from an image file's header.
typedef ImageInfo = ({String mimeType, int width, int height});

/// Reads the format and size of a PNG, JPEG (honouring EXIF rotation),
/// GIF, WebP or BMP file without decoding it.
ImageInfo? sniffImage(Uint8List b) {
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int be32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  int le32(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
  bool starts(List<int> sig, [int at = 0]) {
    if (b.length < at + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[at + i] != sig[i]) return false;
    }
    return true;
  }

  try {
    if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) && b.length >= 24) {
      return (mimeType: 'image/png', width: be32(16), height: be32(20));
    }
    if (starts('GIF8'.codeUnits) && b.length >= 10) {
      return (mimeType: 'image/gif', width: le16(6), height: le16(8));
    }
    if (starts('BM'.codeUnits) && b.length >= 26) {
      return (mimeType: 'image/bmp', width: le32(18), height: le32(22).toSigned(32).abs());
    }
    if (starts('RIFF'.codeUnits) && starts('WEBP'.codeUnits, 8) && b.length >= 30) {
      final chunk = String.fromCharCodes(b.sublist(12, 16));
      final (w, h) = switch (chunk) {
        'VP8 ' => (le16(26) & 0x3FFF, le16(28) & 0x3FFF),
        'VP8L' => (
            1 + (((b[22] & 0x3F) << 8) | b[21]),
            1 + (((b[24] & 0x0F) << 10) | (b[23] << 2) | ((b[22] & 0xC0) >> 6)),
          ),
        'VP8X' => (1 + (b[24] | (b[25] << 8) | (b[26] << 16)), 1 + (b[27] | (b[28] << 8) | (b[29] << 16))),
        _ => (0, 0),
      };
      return w > 0 && h > 0 ? (mimeType: 'image/webp', width: w, height: h) : null;
    }
    if (starts([0xFF, 0xD8])) {
      var i = 2, orientation = 1;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker == 0xFF) {
          i++; // fill byte
          continue;
        }
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2; // markers without a length
          continue;
        }
        final length = be16(i + 2);
        if (marker == 0xE1) orientation = _exifOrientation(b, i + 4, length - 2) ?? orientation;
        final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
        if (isSof) {
          final h = be16(i + 5), w = be16(i + 7);
          // Orientations 5-8 rotate by 90°, swapping width and height.
          final swap = orientation >= 5 && orientation <= 8;
          return (mimeType: 'image/jpeg', width: swap ? h : w, height: swap ? w : h);
        }
        i += 2 + length;
      }
    }
  } on RangeError {
    // Truncated header.
  }
  return null;
}

/// The EXIF orientation tag (1-8) from an APP1 segment, if present.
int? _exifOrientation(Uint8List b, int start, int length) {
  if (length < 14 || String.fromCharCodes(b.sublist(start, start + 4)) != 'Exif') return null;
  final tiff = start + 6;
  final little = b[tiff] == 0x49; // "II" = little-endian, "MM" = big-endian
  int u16(int i) => little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1];
  int u32(int i) => little
      ? b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
      : (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  final ifd = tiff + u32(tiff + 4);
  final count = u16(ifd);
  for (var e = 0; e < count; e++) {
    final entry = ifd + 2 + e * 12;
    if (u16(entry) == 0x0112) return u16(entry + 8);
  }
  return null;
}
