import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../models/print_packages.dart';

/// Creates real orders in Firestore and uploads print-sheet JPGs — SPARK MODE
/// (no Cloud Functions/Storage). Everything here is shaped to pass the
/// Firestore security rules exactly:
///
///  - the order's money/quantity fields are copied FROM the catalog doc the
///    rules validate against (see isPricedFromCatalog in firestore.rules);
///  - the global order number is minted in a transaction on counters/orders
///    (rules allow only exact +1 increments);
///  - sheets travel as <=700 KB Blob chunks in orders/{id}/sheets, each doc
///    exactly {sheet, chunk, of, bytes, expireAt}.
class OrderRepository {
  OrderRepository._();
  static final OrderRepository instance = OrderRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const int _chunkBytes = 700 * 1024;
  static const Duration _sheetTtl = Duration(days: 30);

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

  /// Creates the Firestore order (minting the next global order number) and
  /// returns its id + number. Throws on rules rejection / network failure.
  Future<({String orderId, String orderNumber, int totalPaise})> createOrder({
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
    /// UPI payment confirmed by the in-app Gemini screenshot check, or null.
    /// Written as an ADDITIVE field so the rules-validated `payment` map is
    /// left exactly as the security rules expect.
    Map<String, dynamic>? upiProof,
  }) async {
    final cat = await _findCatalogPack(pack);
    final d = cat.data;
    final perSheet = (d['perSheet'] as num).toInt();
    final snapCount = (d['snapCount'] as num).toInt();
    final sheetsNeeded =
        perSheet > 0 ? ((snapCount + perSheet - 1) ~/ perSheet) : 1;

    final orderRef = _db.collection('orders').doc();
    final counterRef = _db.collection('counters').doc('orders');

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
        },
        // Additive (not inside the rules-validated `payment` map): the UPI
        // payment the customer made + Gemini's read of their screenshot. The
        // shop reconciles the UTR against the bank; `payment.status` is left
        // for the backend phase to flip.
        if (upiProof != null) 'upiProof': {...upiProof, 'at': Timestamp.now()},
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

  /// Uploads the order's print-sheet JPGs as Blob chunks. [onProgress] gets
  /// (chunksDone, chunksTotal). Marks delivery.status='uploaded' when done.
  Future<void> uploadSheets({
    required String orderId,
    required List<Uint8List> sheetJpgs,
    void Function(int done, int total)? onProgress,
  }) async {
    final expireAt =
        Timestamp.fromDate(DateTime.now().add(_sheetTtl));
    final sheetsCol =
        _db.collection('orders').doc(orderId).collection('sheets');

    var total = 0;
    for (final jpg in sheetJpgs) {
      total += (jpg.length / _chunkBytes).ceil();
    }
    var done = 0;

    for (var s = 0; s < sheetJpgs.length; s++) {
      final jpg = sheetJpgs[s];
      final of = (jpg.length / _chunkBytes).ceil();
      for (var c = 0; c < of; c++) {
        final start = c * _chunkBytes;
        final end =
            (start + _chunkBytes) > jpg.length ? jpg.length : start + _chunkBytes;
        await sheetsCol.doc('${s + 1}_$c').set({
          'sheet': s + 1,
          'chunk': c,
          'of': of,
          'bytes': Blob(jpg.sublist(start, end)),
          'expireAt': expireAt,
        });
        done++;
        onProgress?.call(done, total);
      }
      // Track per-sheet progress on the order (owner-allowed update).
      await _db.collection('orders').doc(orderId).update({
        'delivery.sheetsUploaded': s + 1,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    await _db.collection('orders').doc(orderId).update({
      'delivery.status': 'uploaded',
      'updatedAt': FieldValue.serverTimestamp(),
    });
    debugPrint('[OrderRepository] $orderId: ${sheetJpgs.length} sheets '
        '($done chunks) uploaded');
  }
}
