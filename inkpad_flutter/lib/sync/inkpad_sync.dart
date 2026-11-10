import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nas_sync/nas_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../library/drawing_store.dart';
import '../library/library_controller.dart';

/// Sync items: each drawing is one item (its `.inkpad` file as the blob);
/// the portfolio list is one more.
const drawingKind = 'drawing';
const portfoliosKind = 'portfolios';
const portfoliosKey = 'all';

// ---- Settings ------------------------------------------------------------------

/// Where sync keeps its settings (preferences) and login (secure storage).
abstract class SyncSettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
  Future<String?> readSecret(String key);
  Future<void> writeSecret(String key, String? value);
}

/// Preferences, plus the login in the Keychain / Keystore / system keyring.
class DeviceSyncSettingsStore implements SyncSettingsStore {
  final _prefs = SharedPreferencesAsync();
  static const _secure = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  @override
  Future<String?> read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) => value == null ? _prefs.remove(key) : _prefs.setString(key, value);

  @override
  Future<String?> readSecret(String key) => _secure.read(key: key);

  @override
  Future<void> writeSecret(String key, String? value) =>
      value == null ? _secure.delete(key: key) : _secure.write(key: key, value: value);
}

/// For tests.
class MemorySyncSettingsStore implements SyncSettingsStore {
  final Map<String, String> values = {};
  final Map<String, String> secrets = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async => value == null ? values.remove(key) : values[key] = value;

  @override
  Future<String?> readSecret(String key) async => secrets[key];

  @override
  Future<void> writeSecret(String key, String? value) async => value == null ? secrets.remove(key) : secrets[key] = value;
}

class _StateStorage implements SyncStateStorage {
  final SyncSettingsStore settings;
  _StateStorage(this.settings);

  @override
  Future<String?> read() => settings.read('sync.state');

  @override
  Future<void> write(String text) => settings.write('sync.state', text);
}

// ---- Store wrapper -----------------------------------------------------------------

/// The library's store, with every save and delete noted for sync.
/// Sync writes versions from other devices to [inner] directly, so those
/// aren't sent back.
class SyncingDrawingStore implements DrawingStore {
  final DrawingStore inner;
  InkpadSync? sync;

  SyncingDrawingStore(this.inner);

  @override
  Future<List<DrawingInfo>> loadAll() => inner.loadAll();

  @override
  Future<List<PortfolioInfo>> loadPortfolios() => inner.loadPortfolios();

  @override
  Future<void> save(DrawingInfo info) async {
    await inner.save(info);
    // Stamped now, not with info.modified: renames and moves don't touch
    // that, but they still need to win over older edits elsewhere.
    await sync?.changed(drawingKind, info.id);
  }

  @override
  Future<void> delete(String id) async {
    await inner.delete(id);
    await sync?.changed(drawingKind, id, deleted: true);
  }

  @override
  Future<void> savePortfolios(List<PortfolioInfo> portfolios) async {
    await inner.savePortfolios(portfolios);
    await sync?.changed(portfoliosKind, portfoliosKey);
  }
}

// ---- The library as a sync source --------------------------------------------------

class LibrarySyncSource extends SyncSource {
  final LibraryController library;
  final DrawingStore inner;

  LibrarySyncSource(this.library, this.inner);

  @override
  Future<SyncItem?> read(String kind, String key) async {
    switch (kind) {
      case drawingKind:
        final d = library.byId(key);
        if (d == null) return null;
        return SyncItem(
          kind: kind,
          key: key,
          modified: d.modified.millisecondsSinceEpoch,
          data: {'name': d.name},
          blob: Uint8List.fromList(utf8.encode(d.encode())),
        );
      case portfoliosKind:
        return SyncItem(
          kind: kind,
          key: key,
          modified: DateTime.now().millisecondsSinceEpoch,
          data: {'list': jsonDecode(PortfolioInfo.encodeAll(library.portfolios))},
        );
    }
    return null;
  }

  @override
  Future<void> apply(SyncItem item) async {
    switch (item.kind) {
      case drawingKind:
        if (item.deleted || item.blob == null) {
          await inner.delete(item.key);
          library.removeRemote(item.key);
        } else {
          final info = DrawingInfo.decode(item.key, utf8.decode(item.blob!));
          await inner.save(info);
          library.applyRemote(info);
        }
      case portfoliosKind:
        if (item.deleted) return;
        final list = _portfolios(item);
        await inner.savePortfolios(list);
        library.applyRemotePortfolios(list);
    }
  }

  static List<PortfolioInfo> _portfolios(SyncItem item) =>
      PortfolioInfo.decodeAll(jsonEncode(item.data?['list'] ?? const []));

  /// The losing drawing becomes a separate "conflicted copy", so no work is lost.
  @override
  Future<void> keepLoser(SyncItem loser, SyncItem winner) async {
    if (loser.kind != drawingKind || loser.blob == null) return;
    final lost = DrawingInfo.decode(loser.key, utf8.decode(loser.blob!));
    await library.create(
      drawing: lost.drawing,
      name: '${lost.name} (conflicted copy)',
      portfolio: lost.portfolio,
    );
  }

  /// Portfolio lists merge: every portfolio from either side is kept, so a
  /// drawing never loses the portfolio it was put in.
  @override
  Future<SyncItem?> merge(SyncItem local, SyncItem remote) async {
    if (local.kind != portfoliosKind) return null;
    final byId = {for (final p in _portfolios(local)) p.id: p, for (final p in _portfolios(remote)) p.id: p};
    return SyncItem(
      kind: portfoliosKind,
      key: portfoliosKey,
      modified: local.modified > remote.modified ? local.modified : remote.modified,
      data: {'list': jsonDecode(PortfolioInfo.encodeAll(byId.values.toList()))},
    );
  }
}

// ---- The controller the UI talks to ------------------------------------------------

enum SyncStatus {
  /// Not signed in.
  off,
  idle,
  syncing,

  /// The server couldn't be reached (no Tailscale, no network...).
  offline,
  error,
}

/// Inkpad's sync with the NAS: sign-in, status, and when to sync.
class InkpadSync extends ChangeNotifier {
  static InkpadSync? instance;

  /// The app name the server files Inkpad's items under.
  static const app = 'inkpad';

  final LibraryController library;
  final SyncSettingsStore settings;
  final Duration debounce;
  final Duration period;
  final String appName;
  late final NasSync engine;

  String? url;
  SyncStatus status = SyncStatus.off;

  /// What went wrong, or a problem from the last sync.
  String? message;
  DateTime? lastSynced;

  Timer? _debounceTimer;
  Timer? _periodic;
  AppLifecycleListener? _lifecycle;

  InkpadSync({
    required this.library,
    required DrawingStore inner,
    required this.settings,
    String? device,
    this.debounce = const Duration(seconds: 5),
    this.period = const Duration(minutes: 5),
    this.appName = app,
  }) {
    engine = NasSync(
      client: PbClient('http://localhost/'),
      app: appName,
      device: device ?? (kIsWeb ? 'web' : defaultTargetPlatform.name),
      source: LibrarySyncSource(library, inner),
      storage: _StateStorage(settings),
    );
  }

  bool get signedIn => engine.client.auth != null;
  String? get email => engine.client.auth?.email;

  /// Restores a saved login and starts syncing. Call once at startup.
  Future<void> init({bool background = true}) async {
    await _libraryLoaded();
    url = await settings.read('sync.url');
    final saved = await settings.readSecret('sync.auth');
    if (url != null && saved != null) {
      engine.client = PbClient(url!, auth: PbAuth.fromJson(jsonDecode(saved) as Map<String, dynamic>));
      status = SyncStatus.idle;
      notifyListeners();
    }
    if (background) {
      _periodic = Timer.periodic(period, (_) => syncNow());
      _lifecycle = AppLifecycleListener(onResume: syncNow);
    }
    if (signedIn) {
      try {
        await _remember(await engine.client.refresh());
      } on PbException catch (e) {
        if (e.isAuth) return _lostLogin();
      } catch (_) {
        // Offline: keep the saved login and try again on the next sync.
      }
      await syncNow();
    }
  }

  /// Waits for the gallery to read this device's drawings (the page loads them).
  Future<void> _libraryLoaded() async {
    if (library.loaded) return;
    final done = Completer<void>();
    void check() {
      if (library.loaded && !done.isCompleted) done.complete();
    }

    library.addListener(check);
    await done.future;
    library.removeListener(check);
  }

  Future<void> _remember(PbAuth auth) => settings.writeSecret('sync.auth', jsonEncode(auth.toJson()));

  /// Signs in with an account from the NAS admin page. Throws [PbException]
  /// (wrong password) or a network error (server not reachable).
  Future<void> signIn(String serverUrl, String email, String password) async {
    final cleaned = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = PbClient(cleaned);
    await _remember(await client.signIn(email.trim(), password));
    await settings.write('sync.url', cleaned);
    url = cleaned;
    engine.client = client;
    status = SyncStatus.idle;
    message = null;
    notifyListeners();
    await syncNow();
  }

  /// Stops syncing on this device. Drawings stay here, and on the server.
  Future<void> signOut() async {
    engine.client.auth = null;
    await settings.writeSecret('sync.auth', null);
    status = SyncStatus.off;
    message = null;
    notifyListeners();
  }

  Future<void> _lostLogin() async {
    await signOut();
    status = SyncStatus.error;
    message = 'Your sign-in expired or was removed. Sign in again to keep syncing.';
    notifyListeners();
  }

  /// Notes a local change and syncs soon after.
  Future<void> changed(String kind, String key, {bool deleted = false, int? modified}) async {
    await engine.markChanged(kind, key, deleted: deleted, modified: modified);
    if (!signedIn) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, syncNow);
  }

  /// Syncs now (no-op when signed out).
  Future<void> syncNow() async {
    if (!signedIn || !library.loaded) return;
    _debounceTimer?.cancel();
    status = SyncStatus.syncing;
    notifyListeners();
    try {
      await engine.adopt([
        for (final d in library.drawings) (kind: drawingKind, key: d.id, modified: d.modified.millisecondsSinceEpoch),
        if (library.portfolios.isNotEmpty) (kind: portfoliosKind, key: portfoliosKey, modified: 0),
      ]);
      final report = await engine.sync();
      status = SyncStatus.idle;
      lastSynced = DateTime.now();
      message = report.problems.isEmpty ? null : 'Some drawings could not be sent: ${report.problems.join('; ')}';
    } on PbException catch (e) {
      if (e.isAuth) return _lostLogin();
      status = SyncStatus.error;
      message = e.message;
    } on StateError {
      status = SyncStatus.off;
    } catch (e) {
      // Socket, TLS and timeout errors: most likely Tailscale is off or the NAS is down.
      status = SyncStatus.offline;
      message = 'Could not reach the server. Is Tailscale on?';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _periodic?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}
