// App Review demo (Apple Guideline 2.1): walks the typical customer flow on
// the iOS simulator while the CI job (ios-review-video.yml) screen-records it:
//   launch -> home (three print products) -> open each product's packages ->
//   back -> Orders tab -> Profile tab.
// No login, no OTP: the app opens straight onto the storefront (sample photos
// are bundled in the APK so the screens render with zero network). No order is
// placed and no payment is made (that needs the native gallery + a real UPI
// payment, neither of which exists on a simulator).
//
// Run: flutter test integration_test/review_flow_test.dart -d <simulator>
//
// Requires the integration_test dev-dependency (see STORE_SUBMISSION.md).
import 'package:printing_partner/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App Review flow', (tester) async {
    Future<void> idle(double s) async {
      final end = DateTime.now().add(Duration(milliseconds: (s * 1000).round()));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<bool> waitFor(Finder f, {double secs = 30}) async {
      final end = DateTime.now().add(Duration(milliseconds: (secs * 1000).round()));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 200));
        if (f.evaluate().isNotEmpty) return true;
      }
      debugPrint('REVIEW-FLOW: not found: $f');
      return false;
    }

    Future<void> tapIt(Finder f, {double after = 2}) async {
      if (!await waitFor(f)) return;
      await tester.ensureVisible(f.first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(f.first, warnIfMissed: false);
      await idle(after);
    }

    // Navigate the way the app's own router does (some screens have no bottom
    // bar, so drive GoRouter from a live Scaffold context).
    Future<void> goTo(String route, {double after = 3}) async {
      final scaffold = find.byType(Scaffold);
      if (scaffold.evaluate().isEmpty) return;
      final ctx = tester.element(scaffold.last);
      GoRouter.of(ctx).go(route);
      await idle(after);
    }

    app.main();
    await idle(5); // launch + Firebase init (caught if offline) + first frame

    // 1. Home: the three print products.
    await waitFor(find.text('Snaps'), secs: 40);
    await idle(2);
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 2; i++) {
      await tester.drag(scroll, const Offset(0, -220));
      await idle(1.2);
    }
    for (var i = 0; i < 2; i++) {
      await tester.drag(scroll, const Offset(0, 220));
      await idle(0.8);
    }

    // 2. Open each product's package picker, then back home.
    for (final route in const ['/photo-packages', '/polaroid-packages', '/snapbook-packages']) {
      await goTo(route, after: 4);
      await idle(2);
      await goTo('/home', after: 2);
    }

    // 3. Bottom nav: Orders tab, then Profile tab.
    await tapIt(find.text('Orders'), after: 4);
    await idle(2);
    await tapIt(find.text('Profile'), after: 4);
    await idle(2);
    await tapIt(find.text('Home'), after: 3);
    await idle(3);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
