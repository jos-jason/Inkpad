import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'drawing_store.dart';

DrawingStore createStore() => FileDrawingStore();

/// Stores each drawing as `<id>.inkpad` in the app's support directory
/// (or [directory], if given).
class FileDrawingStore implements DrawingStore {
  static const extension = '.inkpad';

  final Directory? _explicitDir;
  Directory? _dir;

  FileDrawingStore([this._explicitDir]);

  Future<Directory> get dir async {
    if (_dir != null) return _dir!;
    final base = _explicitDir ?? Directory('${(await getApplicationSupportDirectory()).path}/drawings');
    await base.create(recursive: true);
    return _dir = base;
  }

  File _file(Directory d, String id) => File('${d.path}/$id$extension');

  @override
  Future<List<DrawingInfo>> loadAll() async {
    final d = await dir;
    final result = <DrawingInfo>[];
    await for (final f in d.list()) {
      if (f is! File || !f.path.endsWith(extension)) continue;
      final name = f.uri.pathSegments.last;
      final id = name.substring(0, name.length - extension.length);
      try {
        result.add(DrawingInfo.decode(id, await f.readAsString()));
      } catch (e) {
        // Skip unreadable files rather than hiding the whole library.
        debugPrint('Skipping unreadable drawing ${f.path}: $e');
      }
    }
    return result;
  }

  @override
  Future<void> save(DrawingInfo info) async {
    final d = await dir;
    // Write to a temp file and rename, so a crash can't truncate a drawing.
    final tmp = File('${d.path}/${info.id}.tmp');
    await tmp.writeAsString(info.encode(), flush: true);
    await tmp.rename(_file(d, info.id).path);
  }

  @override
  Future<void> delete(String id) async {
    final f = _file(await dir, id);
    if (await f.exists()) await f.delete();
  }
}
