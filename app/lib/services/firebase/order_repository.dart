import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../models/print_packages.dart';

/// Creates real orders in Firestore — SPARK MODE (no Cloud Functions/Storage).
/// Everything here is shaped to pass the Firestore security rules exactly:
///
///  - the order's money/quantity fields are copied FROM the catalog doc the
///    rules validate against (see isPricedFromCatalog in firestore.rules);
///  - the global order number is minted in a transaction on counters/orders
///    (rules allow only exact +1 increments).
///
/// The photos themselves no longer travel through Firestore: after the order
/// doc exists, checkout uploads each INDIVIDUAL cropped JPEG to the shop's
/// backend (`BackendApi.ingest`) and records the outcome on the order doc via
/// [markBackend] (`delivery.backendStatus`: pending_upload → filed /
/// upload_failed / rejected). The state lives INSIDE the `delivery` map because
/// the deployed rules (isOwnerProgressUpdate) let the owner touch only
/// `delivery` + `updatedAt` — a top-level `backendStatus` write is denied.
/// The old `orders/{id}/sheets` chunk subcollection is retired.
class OrderRepository {
  OrderRepository._();
  static final OrderRepository instance = OrderRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Finds the catalog doc matching the app-side [pack]. Matches on
  /// (category slug, label, snapCount) — these are identical in
  /// print_packages.dart and the seeded catalog.
  Future<({String packId, Map<String, dynamic> data})> _findCatalogPack(
      PrintPack pack) async {
    final q = await _db
        .collection('catalog')
        .where('category', isEqualTo: pack.size.category.slug)
        .where('label', isEqualTo: pack.size.label)
        .where('snapCount', isEqualTo: pack.snapCount)
        .limit(1)
        .get();
    if (q.docs.isEmpty) {
      throw StateError(
          'No catalog pack for ${pack.size.category.slug}/${pack.size.label}/${pack.snapCount}');
    }
    return (packId: q.docs.first.id, data: q.docs.first.data());
  }

  /// The authoritative price (in paise) the security rules will book for
  /// [pack], read from the catalog doc. Checkout uses THIS as the single
  /// source of truth for the UPI QR amount and the screenshot amount-check, so
  /// the customer can never pay an amount the order would then be rejected for
  /// (client print_packages price vs seeded catalog price could drift).
  Future<int> catalogPriceInPaise(PrintPack pack) async {
    final cat = await _findCatalogPack(pack);
    return (cat.data['priceInPaise'] as num).toInt();
  }

  /// A fresh, client-chosen order document id. Checkout mints ONE per checkout
  /// attempt and passes it to [createOrder], so a transaction that committed
  /// server-side but whose acknowledgement was lost is found again on the
  /// retry instead of minting a second order (+ second number).
  String newOrderId() => _db.collection('orders').doc().id;

  /// Creates the Firestore order (minting the next global order number) and
  /// returns its id + number. Throws on rules rejection / network failure.
  ///
  /// Idempotent per [orderId]: if `orders/{orderId}` already exists (a previous
  /// call committed but the client never got the answer) its number is
  /// returned and nothing is written.
  ///
  /// The doc is created with `delivery.backendStatus: "pending_upload"`;
  /// checkout flips it with [markBackend] once the photos reach the backend.
  Future<({String orderId, String orderNumber, int totalPaise})> createOrder({
    required String orderId,
    required String uid,
    required PrintPack pack,
    required String customerName,
    required String customerPhone,
    required ({
      String line1,
      String line2,
      String city,
      String state,
      String pincode
    }) address,
    required int photoCount,
    /// UPI payment confirmed by the screenshot check (utr, amount, payee…), or
    /// null. Written as an ADDITIVE field so the rules-validated `payment` map
    /// is left exactly as the security rules expect. The backend payment
    /// `token` is NEVER persisted — it is stripped here even if passed.
    Map<String, dynamic>? upiProof,
  }) async {
    final cat = await _findCatalogPack(pack);
    final d = cat.data;
    final perSheet = (d['perSheet'] as num).toInt();
    final snapCount = (d['snapCount'] as num).toInt();
    final sheetsNeeded =
        perSheet > 0 ? ((snapCount + perSheet - 1) ~/ perSheet) : 1;

    // Defensive: the payment token is a bearer credential for /ingest and
    // must never land in Firestore, whatever the caller handed us.
    final Map<String, dynamic>? proof = upiProof == null
        ? null
        : (Map<String, dynamic>.of(upiProof)
          ..remove('token')
          ..remove('paymentToken'));

    final orderRef = _db.collection('orders').doc(orderId);
    final counterRef = _db.collection('counters').doc('orders');

    // Ack-lost retry: the doc may already exist from a committed transaction.
    // Reading a NON-existent doc is denied by the rules (resource is null), so
    // a permission error here simply means "not created yet".
    try {
      final existing = await orderRef.get();
      if (existing.exists) {
        final data = existing.data();
        final number = (data?['orderNumber'] ?? '').toString();
        if (number.isNotEmpty) {
          debugPrint('[OrderRepository] $orderId already exists (#$number) — '
              'reusing, no second order');
          return (
            orderId: orderId,
            orderNumber: number,
            totalPaise: (d['priceInPaise'] as num).toInt(),
          );
        }
      }
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
    }

    final orderNumber = await _db.runTransaction<String>((txn) async {
      final counterSnap = await txn.get(counterRef);
      final current =
          counterSnap.exists ? (counterSnap.get('count') as num).toInt() : 0;
      final next = current + 1;
      if (counterSnap.exists) {
        txn.update(counterRef, {'count': next});
      } else {
        txn.set(counterRef, {'count': next}); // rules allow create at 1
      }

      txn.set(orderRef, {
        'uid': uid,
        'orderNumber': '$next',
        'packId': cat.packId,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'address': {
          'line1': address.line1,
          'line2': address.line2,
          'city': address.city,
          'state': address.state,
          'pincode': address.pincode,
        },
        // Copied from the catalog doc so the rules' equality checks pass.
        'category': d['category'],
        'sizeLabel': d['sizeLabel'],
        'totalPaise': d['priceInPaise'],
        'snapCount': snapCount,
        'sheetsNeeded': sheetsNeeded,
        // Extra display fields (rules don't restrict additional keys).
        'categoryTitle': d['categoryTitle'],
        'productTitle': d['label'],
        'sizeDimensions': d['dimensions'],
        'photoCount': photoCount,
        'currency': 'INR',
        'status': 'received',
        'statusHistory': [
          {'status': 'received', 'at': Timestamp.now()},
        ],
        'payment': {
          'status': 'pending',
          'provider': null,
          'razorpayOrderId': null,
          'razorpayPaymentId': null,
          'amountPaise': d['priceInPaise'],
        },
        'delivery': {
          'status': 'pending',
          'sheetsUploaded': 0,
          // Backend (VM) filing state for the individual cropped photos:
          // pending_upload → filed | upload_failed | rejected (markBackend).
          // Inside `delivery` so the owner's later update passes the rules.
          'backendStatus': 'pending_upload',
          'backendError': null,
        },
        // Additive (not inside the rules-validated `payment` map): the UPI
        // payment the customer made + the screenshot read (utr, amount,
        // payee). The shop reconciles the UTR against the bank;
        // `payment.status` is left for the backend phase to flip.
        if (proof != null) 'upiProof': {...proof, 'at': Timestamp.now()},
        'placedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return '$next';
    });

    return (
      orderId: orderRef.id,
      orderNumber: orderNumber,
      totalPaise: (d['priceInPaise'] as num).toInt(),
    );
  }

  /// Records the backend filing outcome on the order doc (owner-allowed
  /// update). [status] is one of `pending_upload`, `filed`, `upload_failed`,
  /// `rejected`; [error] carries the backend's reason / exception text when
  /// something went wrong (written as null otherwise, clearing an old one).
  ///
  /// Written as `delivery.backendStatus` etc.: the deployed rules allow the
  /// owner to change only the `delivery` map and `updatedAt`, so this is the
  /// one shape that is not answered with permission-denied.
  Future<void> markBackend(String orderId, String status,
      {String? error}) async {
    await _db.collection('orders').doc(orderId).update({
      'delivery.backendStatus': status,
      'delivery.backendError':
          error == null ? null : (error.length > 480 ? error.substring(0, 480) : error),
      'delivery.backendUpdatedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    debugPrint('[OrderRepository] $orderId: backendStatus=$status'
        '${error == null ? '' : ' ($error)'}');
  }
}
