import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../onedrive/onedrive_auth.dart';
import '../onedrive/onedrive_client.dart';

/// The merchant-device fulfilment worker (SPARK MODE — replaces the Cloud
/// Function). Finds orders whose sheets are fully uploaded, reassembles the
/// JPGs from their Firestore chunks, files them into the merchant's OneDrive
/// as:
///
///     PrintingPartner/Orders of 10-6-2026/{Photo|Polaroid|Snapbook}/
///         {orderNumber} ({i} of {n}).jpg
///
/// then marks the order delivered and deletes the transport chunks (keeping
/// the free-tier Firestore storage a small rolling buffer).
class MerchantSyncService {
  MerchantSyncService._();
  static final MerchantSyncService instance = MerchantSyncService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  bool _running = false;

  /// Orders waiting to be filed (sheets uploaded, not yet delivered).
  Stream<QuerySnapshot<Map<String, dynamic>>> pendingOrders() => _db
      .collection('orders')
      .where('delivery.status', isEqualTo: 'uploaded')
      .snapshots();

  /// Files every waiting order. Returns a human-readable summary.
  /// [onProgress] receives step descriptions for the UI.
  Future<String> syncNow({void Function(String stage)? onProgress}) async {
    if (_running) return 'Already syncing.';
    if (!await OneDriveAuth.instance.isConnected) {
      return 'Connect OneDrive first.';
    }
    _running = true;
    var filed = 0, failed = 0;
    try {
      final batch = await _db
          .collection('orders')
          .where('delivery.status', isEqualTo: 'uploaded')
          .get();
      if (batch.docs.isEmpty) return 'Nothing to file — all caught up.';

      // Oldest first so folder ordering matches order numbers.
      final docs = [...batch.docs]..sort((a, b) {
          final ta = a.data()['placedAt'];
          final tb = b.data()['placedAt'];
          if (ta is Timestamp && tb is Timestamp) return ta.compareTo(tb);
          return 0;
        });

      // PAYMENT GATE: when config/app.deliverUnpaidOrders is false (set it
      // once Razorpay ships), only paid/COD orders are punched into the
      // OneDrive print queue — unpaid ones wait.
      final cfg = await _db.collection('config').doc('app').get();
      final deliverUnpaid =
          (cfg.data()?['deliverUnpaidOrders'] as bool?) ?? true;

      var skippedUnpaid = 0;
      for (final doc in docs) {
        final payStatus =
            (doc.data()['payment'] as Map?)?['status'] as String? ?? 'pending';
        if (!deliverUnpaid && payStatus != 'paid' && payStatus != 'cod') {
          skippedUnpaid++;
          continue;
        }
        try {
          onProgress?.call('Filing order #${doc.data()['orderNumber']}…');
          await _deliverOrder(doc.id, doc.data(), onProgress);
          filed++;
        } catch (e) {
          failed++;
          debugPrint('[MerchantSync] order ${doc.id} failed: $e');
          await _db.collection('orders').doc(doc.id).update({
            'delivery.error': e.toString(),
            'updatedAt': FieldValue.serverTimestamp(),
          }).catchError((_) {});
        }
      }
      final unpaidNote =
          skippedUnpaid > 0 ? ' ($skippedUnpaid awaiting payment)' : '';
      return failed == 0
          ? 'Filed $filed order${filed == 1 ? '' : 's'} to OneDrive.$unpaidNote'
          : 'Filed $filed, failed $failed — check connection and retry.$unpaidNote';
    } finally {
      _running = false;
    }
  }

  Future<void> _deliverOrder(
    String orderId,
    Map<String, dynamic> order,
    void Function(String stage)? onProgress,
  ) async {
    // 1. Pull and reassemble the sheet chunks.
    final chunkSnap = await _db
        .collection('orders')
        .doc(orderId)
        .collection('sheets')
        .get();
    if (chunkSnap.docs.isEmpty) {
      throw StateError('no sheet chunks found');
    }

    final bySheet = <int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final d in chunkSnap.docs) {
      bySheet.putIfAbsent((d.data()['sheet'] as num).toInt(), () => []).add(d);
    }
    final sheetNumbers = bySheet.keys.toList()..sort();
    final jpgs = <Uint8List>[];
    for (final s in sheetNumbers) {
      final chunks = bySheet[s]!
        ..sort((a, b) => ((a.data()['chunk'] as num))
            .compareTo((b.data()['chunk'] as num)));
      final expected = (chunks.first.data()['of'] as num).toInt();
      if (chunks.length != expected) {
        throw StateError('sheet $s has ${chunks.length}/$expected chunks');
      }
      final builder = BytesBuilder(copy: false);
      for (final c in chunks) {
        builder.add((c.data()['bytes'] as Blob).bytes);
      }
      jpgs.add(builder.takeBytes());
    }

    // 2. Build the OneDrive paths: date folder from placedAt (device local
    //    time == merchant's IST), category folder, global order number.
    final placedAt = order['placedAt'];
    final when =
        placedAt is Timestamp ? placedAt.toDate().toLocal() : DateTime.now();
    final dateFolder = 'Orders of ${when.day}-${when.month}-${when.year}';
    final category = (order['categoryTitle'] as String?) ??
        _categoryTitle(order['category'] as String? ?? '');
    final no = order['orderNumber']?.toString() ?? orderId;
    final n = jpgs.length;

    final written = <String>[];
    for (var i = 0; i < n; i++) {
      final path =
          'PrintingPartner/$dateFolder/$category/$no (${i + 1} of $n).jpg';
      onProgress?.call('Uploading $no (${i + 1} of $n)…');
      await OneDriveClient.instance.upload(path, jpgs[i]);
      written.add(path);
    }

    // 3. Mark delivered (merchant-allowed update), then delete the chunks.
    await _db.collection('orders').doc(orderId).update({
      'delivery.status': 'delivered',
      'delivery.files': written,
      'delivery.deliveredAt': FieldValue.serverTimestamp(),
      'delivery.error': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    for (final d in chunkSnap.docs) {
      await d.reference.delete();
    }
    debugPrint('[MerchantSync] order $no filed: ${written.join(', ')}');
  }

  static String _categoryTitle(String slug) => switch (slug) {
        'photos' => 'Photo',
        'polaroid' => 'Polaroid',
        'snapbook' => 'Snapbook',
        _ => 'Other',
      };
}
