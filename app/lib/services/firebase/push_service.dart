import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// Background / terminated message handler. Must be a top-level function marked
/// with @pragma('vm:entry-point'). We do no heavy work here — the OS renders the
/// `notification` payload the backend sends; tapping it routes via
/// [FirebaseMessaging.onMessageOpenedApp] once the app is foregrounded.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {}

/// Order-status push notifications for the CUSTOMER ("your order is printing /
/// shipped / delivered"). This is the RECEIVE + token-registration half:
///
///  - asks permission, gets the FCM token, and stores it in `pushTokens/{uid}`
///    (keyed by the customer's anonymous auth uid — the same uid written on the
///    order doc), so the sender can look up which device to notify;
///  - re-saves on token refresh;
///  - routes to My Orders when a notification is tapped.
///
/// Everything is best-effort and wrapped: a messaging / permission / rules
/// failure must NEVER break app startup or order placement. iOS delivery also
/// needs the APNs auth key uploaded to Firebase and the Push Notifications
/// capability in the Xcode project; until then iOS simply gets no token (Android
/// works as soon as a sender exists).
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final FirebaseMessaging _fm = FirebaseMessaging.instance;
  void Function()? _onOpenOrder;
  bool _started = false;

  Future<void> init({void Function()? onOpenOrder}) async {
    if (_started) return;
    _started = true;
    _onOpenOrder = onOpenOrder;
    try {
      // Register the background/terminated handler so the OS can deliver while
      // the app isn't running.
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      await _fm.requestPermission(alert: true, badge: true, sound: true);
      // iOS: still show the banner when a push lands with the app foregrounded.
      await _fm.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      await _saveToken();
      _fm.onTokenRefresh.listen((t) => _saveToken(token: t));
      // If the first sign-in hadn't completed (offline launch), _saveToken
      // above had no uid. Re-save once the anonymous uid actually arrives.
      FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user != null) _saveToken();
      });
      FirebaseMessaging.onMessageOpenedApp
          .listen((_) => _onOpenOrder?.call());
      final initial = await _fm.getInitialMessage();
      if (initial != null) _onOpenOrder?.call();
    } catch (e) {
      debugPrint('[Push] init failed: $e');
    }
  }

  Future<void> _saveToken({String? token}) async {
    try {
      final uid = AuthService.instance.uid;
      if (uid == null) return;
      final t = token ?? await _fm.getToken();
      if (t == null || t.isEmpty) return;
      await FirebaseFirestore.instance.collection('pushTokens').doc(uid).set({
        'token': t,
        'platform': defaultTargetPlatform.name,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      // Most likely a Firestore rule that doesn't allow pushTokens yet — fail
      // quietly; nothing else depends on this write.
      debugPrint('[Push] saveToken failed: $e');
    }
  }
}
