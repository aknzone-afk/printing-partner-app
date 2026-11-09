import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The checkout "resume tuple": everything needed to finish sending an
/// already-PAID, already-CREATED order's photos to the backend after the
/// checkout screen was left (back button, app kill, iOS jetsam) before
/// `/ingest` answered.
///
/// Written right after `createOrder` commits, read back in the checkout
/// screen's initState (which then opens directly in "Retry upload" mode when
/// the same cart is still on the device), and cleared when the backend
/// answers 200 (filed) or with a real 402/409 rejection. Without it the
/// resume state lived only in widget State, and a fresh CheckoutScreen would
/// re-verify the same screenshot and mint a SECOND order.
///
/// The record expires with the backend's token TTL (24 h). `token` is null
/// once the server said the pass expired (402 token_expired): the order is
/// kept and the customer re-attaches the same screenshot to get a new one.
class PendingUpload {
  const PendingUpload({
    required this.orderId,
    required this.orderNumber,
    required this.placedAtIso,
    required this.token,
    required this.uid,
    required this.packKey,
    required this.photoCount,
    required this.amountPaise,
    required this.ingestAttempted,
    required this.savedAtMs,
  });

  static const String _prefsKey = 'pp_pending_upload_v1';
  static const Duration maxAge = Duration(hours: 24);

  /// Firestore `orders/{orderId}` document id (client-chosen, stable).
  final String orderId;
  final String orderNumber;
  final String placedAtIso;

  /// Backend payment token; null when it expired and must be re-issued.
  final String? token;
  final String uid;

  /// `category|size|snapCount` of the pack this order was placed for, plus
  /// the photo count — the record is only resumed for the SAME cart.
  final String packKey;
  final int photoCount;

  /// Catalog price the customer paid (paise), for the re-attach amount check.
  final int amountPaise;

  /// True once `/ingest` has been attempted at least once for this token, so
  /// a later 409 without an orderNumber can be read as "filed on the earlier
  /// attempt" rather than "used for another order".
  final bool ingestAttempted;
  final int savedAtMs;

  PendingUpload copyWith({
    String? token,
    bool clearToken = false,
    bool? ingestAttempted,
  }) =>
      PendingUpload(
        orderId: orderId,
        orderNumber: orderNumber,
        placedAtIso: placedAtIso,
        token: clearToken ? null : (token ?? this.token),
        uid: uid,
        packKey: packKey,
        photoCount: photoCount,
        amountPaise: amountPaise,
        ingestAttempted: ingestAttempted ?? this.ingestAttempted,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'orderId': orderId,
        'orderNumber': orderNumber,
        'placedAtIso': placedAtIso,
        'token': token,
        'uid': uid,
        'packKey': packKey,
        'photoCount': photoCount,
        'amountPaise': amountPaise,
        'ingestAttempted': ingestAttempted,
        'savedAtMs': savedAtMs,
      };

  static PendingUpload? _fromJson(Map<String, dynamic> j) {
    final orderId = (j['orderId'] ?? '').toString();
    final orderNumber = (j['orderNumber'] ?? '').toString();
    if (orderId.isEmpty || orderNumber.isEmpty) return null;
    final token = j['token'];
    return PendingUpload(
      orderId: orderId,
      orderNumber: orderNumber,
      placedAtIso: (j['placedAtIso'] ?? '').toString(),
      token: token is String && token.isNotEmpty ? token : null,
      uid: (j['uid'] ?? '').toString(),
      packKey: (j['packKey'] ?? '').toString(),
      photoCount: j['photoCount'] is num ? (j['photoCount'] as num).toInt() : 0,
      amountPaise:
          j['amountPaise'] is num ? (j['amountPaise'] as num).toInt() : 0,
      ingestAttempted: j['ingestAttempted'] == true,
      savedAtMs: j['savedAtMs'] is num ? (j['savedAtMs'] as num).toInt() : 0,
    );
  }

  /// The stored record, or null when there is none, it is unreadable, or it
  /// is older than [maxAge] (then it is also removed).
  static Future<PendingUpload?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final rec = _fromJson(Map<String, dynamic>.from(decoded));
      if (rec == null) return null;
      final age = DateTime.now().millisecondsSinceEpoch - rec.savedAtMs;
      if (age > maxAge.inMilliseconds) {
        debugPrint('[PendingUpload] record for #${rec.orderNumber} expired');
        await prefs.remove(_prefsKey);
        return null;
      }
      return rec;
    } catch (e) {
      debugPrint('[PendingUpload] load failed: $e');
      return null;
    }
  }

  /// Persists [rec]. Never throws — a failed save must not break checkout.
  static Future<void> save(PendingUpload rec) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(rec.toJson()));
    } catch (e) {
      debugPrint('[PendingUpload] save failed: $e');
    }
  }

  /// Removes the record (order filed or definitively rejected). Never throws.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (e) {
      debugPrint('[PendingUpload] clear failed: $e');
    }
  }
}
