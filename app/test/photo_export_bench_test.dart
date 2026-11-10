// A throughput benchmark for the print export (lib/services/photo_export.dart).
//
// It renders N synthetic photos through [renderCroppedJpegs] and PRINTS the
// elapsed milliseconds, once with the concurrent worker pool and once forced
// to one-photo-at-a-time, so the parallel speed-up is measurable and a future
// regression (e.g. the pool accidentally serialising again) is visible in the
// test log. There is NO fixed-time assertion — timings vary by machine — only
// a generous ceiling plus a correctness check that every photo renders.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:printing_partner/models/cart.dart';
import 'package:printing_partner/models/print_packages.dart';
import 'package:printing_partner/services/photo_export.dart';

import 'support/test_images.dart';

PrintPack _packLabelled(PrintCategory c, String label) =>
    allPacks.firstWhere((p) => p.size.category == c && p.size.label == label);

Cart _cartOf(PrintPack pack, List<String> paths) {
  final cart = Cart()
    ..selectPack(pack)
    ..addPhotos(paths);
  for (final item in cart.items) {
    cart.setCrop(item.id, const CropEdit.skipped());
  }
  return cart;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TempPhotos tmp;
  final DebugPrintCallback realDebugPrint = debugPrint;
  setUpAll(() {
    tmp = TempPhotos();
    debugPrint = (String? message, {int? wrapWidth}) {};
  });
  tearDownAll(() {
    debugPrint = realDebugPrint;
    tmp.dispose();
  });

  test('renderCroppedJpegs throughput: worker pool vs one-at-a-time', () async {
    // A realistic small order of full-ish phone photos, so the per-photo
    // decode + encode (not file I/O) dominates and the pool actually helps.
    const n = 12;
    final pack = _packLabelled(PrintCategory.photos, 'Regular'); // 4x6
    final paths = <String>[
      for (var i = 0; i < n; i++) tmp.writeJpg(quadrantImage(2400, 1800))
    ];

    Future<int> run(int concurrency) async {
      final cart = _cartOf(pack, paths);
      final sw = Stopwatch()..start();
      final jpgs = await renderCroppedJpegs(cart, concurrency: concurrency);
      sw.stop();
      expect(jpgs.length, n, reason: 'every photo must render');
      for (final j in jpgs) {
        expect(j, isNotEmpty, reason: 'each output is a non-empty JPEG');
      }
      return sw.elapsedMilliseconds;
    }

    // Warm up (first isolate spawn / JIT) so the two measured runs compare
    // like for like.
    await run(3);

    final serialMs = await run(1);
    final poolMs = await run(3);

    // ignore: avoid_print
    print('[bench] renderCroppedJpegs $n photos @2400x1800: '
        'serial(1)=${serialMs}ms  pool(3)=${poolMs}ms  '
        'speedup=${(serialMs / poolMs).toStringAsFixed(2)}x');

    // Generous ceiling only — proves it completes, never asserts a fixed time.
    expect(poolMs, lessThan(300000));
    expect(serialMs, lessThan(300000));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
