import 'package:shared_preferences/shared_preferences.dart';

import 'drawing_store.dart';

DrawingStore createStore() => PrefsDrawingStore();

/// Web storage: one browser-storage entry per drawing.
class PrefsDrawingStore implements DrawingStore {
  static const _prefix = 'drawing:';

  final _prefs = SharedPreferencesAsync();

  @override
  Future<List<DrawingInfo>> loadAll() async {
    final all = await _prefs.getAll();
    return [
      for (final e in all.entries)
        if (e.key.startsWith(_prefix) && e.value is String)
          DrawingInfo.decode(e.key.substring(_prefix.length), e.value as String),
    ];
  }

  @override
  Future<void> save(DrawingInfo info) => _prefs.setString('$_prefix${info.id}', info.encode());

  @override
  Future<void> delete(String id) => _prefs.remove('$_prefix$id');

  @override
  Future<List<PortfolioInfo>> loadPortfolios() async => PortfolioInfo.decodeAll(await _prefs.getString('portfolios'));

  @override
  Future<void> savePortfolios(List<PortfolioInfo> all) => _prefs.setString('portfolios', PortfolioInfo.encodeAll(all));
}
