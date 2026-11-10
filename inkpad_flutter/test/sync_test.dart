// Library sync against a real PocketBase made from ~/Work/nas-sync/server
// (users alice and bob). Skipped unless NAS_SYNC_TEST_URL is set, e.g.
//   NAS_SYNC_TEST_URL=http://127.0.0.1:18090 flutter test test/sync_test.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/library/drawing_store.dart';
import 'package:inkpad/library/library_controller.dart';
import 'package:inkpad/model/drawing.dart';
import 'package:inkpad/sync/inkpad_sync.dart';
import 'package:nas_sync/nas_sync.dart';

final url = Platform.environment['NAS_SYNC_TEST_URL'];

class Device {
  final inner = MemoryDrawingStore();
  late final store = SyncingDrawingStore(inner);
  late final lib = LibraryController(store);
  late final InkpadSync sync;

  static Future<Device> start(String app, String name, {String? user}) async {
    final d = Device();
    d.sync = InkpadSync(
      library: d.lib,
      inner: d.inner,
      settings: MemorySyncSettingsStore(),
      device: name,
      debounce: const Duration(hours: 1),
      appName: app,
    );
    d.store.sync = d.sync;
    await d.lib.load();
    await d.sync.init(background: false);
    if (user != null) await d.signIn(user);
    return d;
  }

  Future<void> signIn(String user) => sync.signIn(url!, '$user@test.local', 'pw-$user-12345');

  List<String> get names => [for (final x in lib.drawings) x.name]..sort();

  DrawingInfo named(String n) => lib.drawings.firstWhere((x) => x.name == n);
}

/// Distinct edit times on a fast machine.
Future<void> later() => Future.delayed(const Duration(milliseconds: 5));

void main() {
  if (url == null) {
    test('library sync', () {}, skip: 'set NAS_SYNC_TEST_URL to a test PocketBase');
    return;
  }
  late String app;
  setUp(() => app = 'inkpadtest${Random().nextInt(1 << 32)}');

  test('drawings and portfolios made before signing in reach another device', () async {
    final a = await Device.start(app, 'A');
    final folder = await a.lib.createPortfolio('Logos');
    await a.lib.create(name: 'Star', portfolio: folder.id);
    await a.lib.create(name: 'Loose');
    await a.signIn('alice');
    expect(a.sync.status, SyncStatus.idle);

    final b = await Device.start(app, 'B', user: 'alice');
    expect(b.names, ['Loose', 'Star']);
    expect(b.lib.portfolios.single.name, 'Logos');
    expect(b.named('Star').portfolio, folder.id);
    // Written to B's own storage too, not just shown.
    expect(b.inner.files.length, 2);
    // B's store didn't send them back as its own changes.
    expect(await b.sync.engine.hasPending, isFalse);
  });

  test('edits, renames and deletes follow', () async {
    final a = await Device.start(app, 'A', user: 'alice');
    final b = await Device.start(app, 'B', user: 'alice');
    final d = await a.lib.create(name: 'Draft');
    await a.sync.syncNow();
    await b.sync.syncNow();

    await b.lib.rename(b.named('Draft'), 'Final');
    await b.sync.syncNow();
    await a.sync.syncNow();
    expect(a.names, ['Final']);
    expect(identical(a.lib.byId(d.id), d), isTrue, reason: 'updated in place for an open editor');

    await a.lib.delete(d);
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(b.names, isEmpty);
    expect(b.inner.files, isEmpty);
  });

  test('both edited offline: newer wins, older kept as a conflicted copy on both', () async {
    final a = await Device.start(app, 'A', user: 'alice');
    final b = await Device.start(app, 'B', user: 'alice');
    await a.lib.create(name: 'Shared');
    await a.sync.syncNow();
    await b.sync.syncNow();

    await a.lib.saveEdits(a.named('Shared'), InkDrawing(width: 111));
    await later();
    await b.lib.saveEdits(b.named('Shared'), InkDrawing(width: 222));
    await a.sync.syncNow(); // older edit first
    await b.sync.syncNow(); // finds the conflict; its newer edit wins
    await a.sync.syncNow();
    await b.sync.syncNow();

    for (final dev in [a, b]) {
      expect(dev.names, ['Shared', 'Shared (conflicted copy)']);
      expect(dev.named('Shared').drawing.width, 222);
      expect(dev.named('Shared (conflicted copy)').drawing.width, 111);
    }
  });

  test('portfolios made on two devices are both kept', () async {
    final a = await Device.start(app, 'A', user: 'alice');
    final b = await Device.start(app, 'B', user: 'alice');
    await a.lib.createPortfolio('From A');
    await b.lib.createPortfolio('From B');
    await a.sync.syncNow();
    await b.sync.syncNow();
    await a.sync.syncNow();
    for (final dev in [a, b]) {
      expect({for (final p in dev.lib.portfolios) p.name}, {'From A', 'From B'});
    }
  });

  test('wrong password is reported, and nothing is saved', () async {
    final a = await Device.start(app, 'A');
    await expectLater(a.sync.signIn(url!, 'alice@test.local', 'wrong'), throwsA(isA<PbException>()));
    expect(a.sync.signedIn, isFalse);
    expect(a.sync.url, isNull);
  });

  test('offline: drawings stay local and go up once the server is back', () async {
    final a = await Device.start(app, 'A', user: 'alice');
    final real = a.sync.engine.client;
    a.sync.engine.client = PbClient('http://127.0.0.1:9', auth: real.auth); // nothing listens there
    await a.lib.create(name: 'On the plane');
    await a.sync.syncNow();
    expect(a.sync.status, SyncStatus.offline);

    a.sync.engine.client = real;
    await a.sync.syncNow();
    expect(a.sync.status, SyncStatus.idle);
    final b = await Device.start(app, 'B', user: 'alice');
    expect(b.names, ['On the plane']);
  });

  test("bob doesn't get alice's drawings", () async {
    final a = await Device.start(app, 'A', user: 'alice');
    await a.lib.create(name: 'Private');
    await a.sync.syncNow();
    final bob = await Device.start(app, 'B', user: 'bob');
    expect(bob.names, isEmpty);
  });
}
