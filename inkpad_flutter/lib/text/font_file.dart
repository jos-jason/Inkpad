import 'dart:convert';
import 'dart:typed_data';

/// What we need to know about one font face, read from its 'name' and
/// 'OS/2' tables.
class FontFaceInfo {
  final String family;
  final String style;
  final String postScriptName;

  /// 100 (thin) … 400 (regular) … 900 (black).
  final int weight;
  final bool italic;

  /// Where the face lives: a file path (or asset key / imported id), and its
  /// index inside a font collection (.ttc).
  final String source;
  final int index;

  const FontFaceInfo({
    required this.family,
    required this.style,
    required this.postScriptName,
    required this.weight,
    required this.italic,
    required this.source,
    this.index = 0,
  });

  Map<String, dynamic> toJson() => {
        'family': family,
        'style': style,
        'ps': postScriptName,
        'weight': weight,
        'italic': italic,
        'source': source,
        'index': index,
      };

  factory FontFaceInfo.fromJson(Map<String, dynamic> j) => FontFaceInfo(
        family: j['family'],
        style: j['style'],
        postScriptName: j['ps'],
        weight: j['weight'],
        italic: j['italic'],
        source: j['source'],
        index: j['index'],
      );

  @override
  String toString() => '$family $style';
}

/// The faces in a font file (several for a .ttc collection), or an empty
/// list if the data isn't a font we can read.
List<FontFaceInfo> readFontFaces(Uint8List bytes, String source) {
  try {
    if (_tag(bytes, 0) == 'ttcf') {
      final count = _u32(bytes, 8);
      return [
        for (var i = 0; i < count && i < 256; i++)
          ?_faceInfo(bytes, _u32(bytes, 12 + i * 4), source, i),
      ];
    }
    final info = _faceInfo(bytes, 0, source, 0);
    return info == null ? [] : [info];
  } on RangeError {
    return [];
  }
}

/// A standalone font file for face [index] of [bytes]: the face itself for
/// a single font, or the face copied out of a .ttc collection (the font
/// parser only reads single fonts).
Uint8List extractFace(Uint8List bytes, int index) {
  if (_tag(bytes, 0) != 'ttcf') return bytes;
  final offset = _u32(bytes, 12 + index * 4);
  final numTables = _u16(bytes, offset + 4);
  final tables = [
    for (var i = 0; i < numTables; i++)
      (
        record: offset + 12 + i * 16,
        start: _u32(bytes, offset + 12 + i * 16 + 8),
        length: _u32(bytes, offset + 12 + i * 16 + 12),
      ),
  ];
  final headerSize = 12 + numTables * 16;
  var size = headerSize;
  for (final t in tables) {
    size += (t.length + 3) & ~3;
  }
  final out = Uint8List(size);
  out.setRange(0, 12, bytes, offset); // sfnt version, numTables, search fields
  final data = ByteData.sublistView(out);
  var cursor = headerSize;
  for (final (i, t) in tables.indexed) {
    final rec = 12 + i * 16;
    out.setRange(rec, rec + 16, bytes, t.record);
    data.setUint32(rec + 8, cursor); // tables are re-packed after the header
    out.setRange(cursor, cursor + t.length, bytes, t.start);
    cursor += (t.length + 3) & ~3;
  }
  return out;
}

FontFaceInfo? _faceInfo(Uint8List b, int offset, String source, int index) {
  final version = _tag(b, offset);
  if (!const ['\x00\x01\x00\x00', 'true', 'OTTO'].contains(version)) return null;
  final numTables = _u16(b, offset + 4);
  final tables = <String, (int, int)>{};
  for (var i = 0; i < numTables; i++) {
    final rec = offset + 12 + i * 16;
    tables[_tag(b, rec)] = (_u32(b, rec + 8), _u32(b, rec + 12));
  }
  // Outlines are needed to draw; skip bitmap-only fonts (e.g. emoji).
  if (!tables.containsKey('glyf') && !tables.containsKey('CFF ')) return null;
  final names = tables['name'] == null ? <int, String>{} : _names(b, tables['name']!.$1, tables['name']!.$2);
  final family = names[16] ?? names[1];
  if (family == null || family.startsWith('.')) return null; // hidden system faces
  final style = names[17] ?? names[2] ?? 'Regular';

  var weight = 400;
  var italic = false;
  final os2 = tables['OS/2'];
  if (os2 != null && os2.$2 >= 64) {
    weight = _u16(b, os2.$1 + 4).clamp(1, 1000);
    italic = (_u16(b, os2.$1 + 62) & 0x201) != 0; // ITALIC or OBLIQUE
  }
  // Some fonts don't set the flag; trust the style name too.
  italic = italic || style.toLowerCase().contains('italic') || style.toLowerCase().contains('oblique');
  return FontFaceInfo(
    family: family,
    style: style,
    postScriptName: names[6] ?? '$family-$style'.replaceAll(' ', ''),
    weight: weight,
    italic: italic,
    source: source,
    index: index,
  );
}

/// Name records by ID, preferring Windows Unicode English, then Mac Roman.
Map<int, String> _names(Uint8List b, int offset, int length) {
  final count = _u16(b, offset + 2);
  final strings = offset + _u16(b, offset + 4);
  final best = <int, (int, String)>{}; // id -> (priority, value)
  for (var i = 0; i < count; i++) {
    final r = offset + 6 + i * 12;
    final platform = _u16(b, r), encoding = _u16(b, r + 2), language = _u16(b, r + 4);
    final id = _u16(b, r + 6), len = _u16(b, r + 8), at = strings + _u16(b, r + 10);
    if (![1, 2, 4, 6, 16, 17].contains(id) || at + len > b.length) continue;
    int priority;
    String value;
    if (platform == 3 && (encoding == 1 || encoding == 10)) {
      priority = language == 0x409 ? 3 : 2;
      final units = [for (var k = 0; k + 1 < len; k += 2) (b[at + k] << 8) | b[at + k + 1]];
      value = String.fromCharCodes(units);
    } else if (platform == 0) {
      priority = 2;
      final units = [for (var k = 0; k + 1 < len; k += 2) (b[at + k] << 8) | b[at + k + 1]];
      value = String.fromCharCodes(units);
    } else if (platform == 1 && encoding == 0 && language == 0) {
      priority = 1;
      value = latin1.decode(b.sublist(at, at + len), allowInvalid: true);
    } else {
      continue;
    }
    value = value.trim();
    if (value.isEmpty) continue;
    if ((best[id]?.$1 ?? 0) < priority) best[id] = (priority, value);
  }
  return {for (final e in best.entries) e.key: e.value.$2};
}

String _tag(Uint8List b, int at) => String.fromCharCodes(b.sublist(at, at + 4));
int _u16(Uint8List b, int at) => (b[at] << 8) | b[at + 1];
int _u32(Uint8List b, int at) => ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) & 0xFFFFFFFF;
