import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'models/cart.dart';
import 'services/firebase/firebase_options.dart';
import 'models/orders_store.dart';
import 'models/print_packages.dart';
import 'screens/address_screen.dart';
import 'screens/cart_screen.dart';
import 'screens/checkout_screen.dart';
import 'screens/crop_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/merchant_cloud_screen.dart';
import 'screens/merchant_screen.dart';
import 'screens/order_placed_screen.dart';
import 'screens/otp_screen.dart';
import 'screens/packages_screen.dart';
import 'screens/photo_picker_screen.dart';
import 'screens/upload_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const PrintingPartnerApp());
}

final GoRouter _router = GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/', redirect: (_, __) => '/home'),
    GoRoute(
        path: '/login',
        builder: (_, state) =>
            LoginScreen(redirectTo: state.extra as String?)),
    GoRoute(
      path: '/otp',
      redirect: (_, state) => state.extra is OtpArgs ? null : '/login',
      builder: (_, state) => OtpScreen(args: state.extra as OtpArgs),
    ),
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
