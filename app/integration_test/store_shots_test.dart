// Printing Partner store screenshots: the real app on an Android emulator,
// photographing the main screens for the App Store + Play listings. Sample
// photos are bundled in the APK so every screen renders with zero network.
// No order is placed.
//
// Run by the "Store screenshots" workflow:
//   flutter drive --driver=test_driver/shots.dart --target=integration_test/store_shots_test.dart --profile
//
// Requires the integration_test dev-dependency (see STORE_SUBMISSION.md).
import 'package:printing_partner/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screenshots', (t) async {
    Future<void> wait(double s) async {
      final end = DateTime.now().add(Duration(milliseconds: (s * 1000).round()));
      while (DateTime.now().isBefore(end)) {
        await t.pump(const Duration(milliseconds: 200));
      }
    }

    Future<bool> waitFor(Finder f, {double secs = 30}) async {
      final end = DateTime.now().add(Duration(milliseconds: (secs * 1000).round()));
      while (DateTime.now().isBefore(end)) {
        await t.pump(const Duration(milliseconds: 200));
        if (f.evaluate().isNotEmpty) return true;
      }
      return false;
    }

    Future<void> shot(String name, {double settle = 6}) async {
      await wait(settle);
      await binding.takeScreenshot(name);
    }

    // Navigate via the app's own router from a live Scaffold context.
    Future<void> goTo(String route, {double after = 3}) async {
      final scaffold = find.byType(Scaffold);
      if (scaffold.evaluate().isEmpty) return;
      final ctx = t.element(scaffold.last);
      GoRouter.of(ctx).go(route);
      await wait(after);
    }

    app.main();
    await wait(4);
    await binding.convertFlutterSurfaceToImage();

    // 1. Home — the three print products.
    await waitFor(find.text('Snaps'), secs: 60);
    await shot('01_home', settle: 8);

    // 2. Photo (Snaps) packages.
    await goTo('/photo-packages', after: 4);
    await shot('02_photo_packages', settle: 8);

    // 3. Polaroid packages.
    await goTo('/polaroid-packages', after: 4);
    await shot('03_polaroid_packages', settle: 8);

    // 4. SnapBook packages.
    await goTo('/snapbook-packages', after: 4);
    await shot('04_snapbook_packages', settle: 8);

    // 5. Orders tab (empty-state card explaining how orders are kept).
    await goTo('/home?tab=orders', after: 4);
    await shot('05_orders', settle: 6);

    // 6. Profile tab ("no login needed").
    await goTo('/home?tab=profile', after: 4);
    await shot('06_profile', settle: 6);
  }, timeout: const Timeout(Duration(minutes: 30)));
}
