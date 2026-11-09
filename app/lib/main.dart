import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'models/cart.dart';
import 'services/firebase/auth_service.dart';
import 'services/firebase/firebase_options.dart';
import 'models/orders_store.dart';
import 'models/print_packages.dart';
import 'screens/address_screen.dart';
import 'screens/cart_screen.dart';
import 'screens/checkout_screen.dart';
import 'screens/crop_screen.dart';
import 'screens/home_screen.dart';
import 'screens/merchant_cloud_screen.dart';
import 'screens/merchant_screen.dart';
import 'screens/order_chat_screen.dart';
import 'screens/order_placed_screen.dart';
import 'screens/packages_screen.dart';
import 'screens/photo_picker_screen.dart';
import 'screens/upload_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Never white-screen on a slow / offline launch: if Firebase can't start we
  // still run the app, and order placement retries sign-in with a friendly
  // error. (Before, an uncaught init failure here killed the whole app.)
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // App Check authorises Firebase AI Logic (Gemini screenshot-verify + order
    // chatbot) and protects it from abuse. Release/TestFlight uses Apple's App
    // Attest; debug/simulator uses the debug provider (App Attest can't issue a
    // token on the simulator, which would block Firestore + Gemini in dev).
    // NOTE: keep App Check UNENFORCED (monitor mode) on Firestore + AI Logic in
    // the console until the installed base can attest, or ordering breaks.
    await FirebaseAppCheck.instance.activate(
      appleProvider:
          kDebugMode ? AppleProvider.debug : AppleProvider.appAttest,
    );
    // No OTP — a silent anonymous sign-in gives the customer a uid for the
    // Firestore order (real identity = the mobile typed at checkout).
    await AuthService.instance.ensureSignedIn();
  } catch (e, st) {
    debugPrint('[main] Firebase init / sign-in failed: $e\n$st');
  }
  runApp(const PrintingPartnerApp());
}

final GoRouter _router = GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/', redirect: (_, __) => '/home'),
    GoRoute(
      path: '/home',
      builder: (_, state) => HomeScreen(
        initialTab: state.uri.queryParameters['tab'],
      ),
    ),
    GoRoute(
        path: '/photo-packages',
        builder: (_, __) =>
            const PackagesScreen(category: PrintCategory.photos)),
    GoRoute(
        path: '/polaroid-packages',
        builder: (_, __) =>
            const PackagesScreen(category: PrintCategory.polaroid)),
    GoRoute(
        path: '/snapbook-packages',
        builder: (_, __) =>
            const PackagesScreen(category: PrintCategory.snapbook)),
    GoRoute(path: '/photos', builder: (_, __) => const PhotoPickerScreen()),
    GoRoute(
      path: '/crop',
      builder: (_, state) => CropScreen(
        startIndex:
            int.tryParse(state.uri.queryParameters['i'] ?? '') ?? 0,
      ),
    ),
    GoRoute(path: '/cart', builder: (_, __) => const CartScreen()),
    GoRoute(path: '/upload', builder: (_, __) => const UploadScreen()),
    GoRoute(path: '/address', builder: (_, __) => const AddressScreen()),
    GoRoute(path: '/checkout', builder: (_, __) => const CheckoutScreen()),
    GoRoute(
        path: '/order-placed',
        builder: (_, state) => OrderPlacedScreen(
              orderId: state.extra as String?,
            )),
    GoRoute(
        path: '/order-chat',
        builder: (_, state) =>
            OrderChatScreen(orderId: state.extra as String? ?? '')),
    GoRoute(path: '/merchant', builder: (_, __) => const MerchantScreen()),
    GoRoute(
        path: '/merchant/cloud',
        builder: (_, __) => const MerchantCloudScreen()),
    GoRoute(
      path: '/merchant/order/:id',
      builder: (_, state) => MerchantOrderDetailScreen(
        orderId: state.pathParameters['id'] ?? '',
      ),
    ),
  ],
);

class PrintingPartnerApp extends StatelessWidget {
  const PrintingPartnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => Cart()),
        ChangeNotifierProvider(create: (_) => OrdersStore()),
      ],
      child: MaterialApp.router(
        title: 'Printing Partner',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        routerConfig: _router,
      ),
    );
  }
}
