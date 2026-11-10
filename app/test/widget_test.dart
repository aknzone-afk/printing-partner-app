// The customer app opens straight on the home shell — there is no "Get
// Started" / Welcome page any more. This test pins the ONE thing that is
// structurally stable: the bottom navigation (Home / Orders / Profile).
//
// It pumps HomeScreen directly (wrapped in the same providers main() gives it)
// rather than the whole PrintingPartnerApp, for two reasons:
//   1. main() needs Firebase.initializeApp() + an anonymous sign-in; a unit
//      test must not need a live Firebase. Building HomeScreen under a plain
//      MaterialApp skips all of that (the providers below construct cleanly
//      offline — OrdersStore just restores from SharedPreferences).
//   2. It keeps the test off the checkout/upload import graph, so an unrelated
//      screen does not decide whether the home shell "renders".
//
// pump (a couple of short frames), never pumpAndSettle: the product cards
// decode bundled images and the shell can hold progress indicators, so
// settling could spin forever.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:printing_partner/models/cart.dart';
import 'package:printing_partner/models/orders_store.dart';
import 'package:printing_partner/screens/home_screen.dart';

void main() {
  testWidgets('home shell shows the bottom navigation and the product cards',
      (WidgetTester tester) async {
    // OrdersStore.restore() reads SharedPreferences on construction.
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => Cart()),
          ChangeNotifierProvider(create: (_) => OrdersStore()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The stable skeleton: one bottom nav with the three customer tabs.
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final tab in const ['Home', 'Orders', 'Profile']) {
      expect(find.text(tab), findsOneWidget, reason: 'nav tab "$tab"');
    }

    // The home tab offers the three products to start an order from. These are
    // the app's product names (not marketing copy); one card each.
    for (final product in const ['Snaps', 'Polaroid', 'SnapBook']) {
      expect(find.text(product), findsOneWidget, reason: 'product "$product"');
    }

    // Nothing threw while laying the shell out (e.g. a missing asset).
    expect(tester.takeException(), isNull);
  });
}
