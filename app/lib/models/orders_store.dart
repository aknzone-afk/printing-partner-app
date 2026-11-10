import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/order_blob_store.dart';
import 'order_record.dart';

/// Orders list with localStorage-backed persistence (web) or SharedPreferences
/// (Android). Only metadata is persisted — PDF bytes and the underlying photo
/// blobs are session-scoped, so a restored order shows as `archived` and the
/// merchant must re-request the original photos to reprint.
class OrdersStore extends ChangeNotifier {
  OrdersStore() {
    _restore();
  }

  static const _storageKey = 'pp_orders_v1';

  final List<OrderRecord> _orders = [];
  bool _restored = false;
  bool get isRestored => _restored;

  List<OrderRecord> get all => List.unmodifiable(_orders.reversed);
  int get count => _orders.length;
  int get totalRevenuePaise =>
      _orders.fold<int>(0, (sum, o) => sum + o.totalPaise);
  int get pendingSheets => _orders
      .where((o) => o.status != OrderStatus.delivered)
      .fold<int>(0, (sum, o) => sum + o.sheetsNeeded);

  void place(OrderRecord order) {
    _orders.add(order);
    _save();
    notifyListeners();
  }

  void updateStatus(String id, OrderStatus status) {
    final idx = _orders.indexWhere((o) => o.id == id);
    if (idx == -1) return;
    _orders[idx].status = status;
    _save();
    notifyListeners();
  }

  void setPdf(String id, Uint8List bytes) {
    final idx = _orders.indexWhere((o) => o.id == id);
    if (idx == -1) return;
    _orders[idx].pdfBytes = bytes;
    _orders[idx].pdfStatus = SheetPdfStatus.ready;
    // Persist the PDF to IndexedDB so it survives refresh / shows in other tabs.
    OrderBlobStore.save(id, bytes);
    notifyListeners();
  }

  void markPdfFailed(String id) {
    final idx = _orders.indexWhere((o) => o.id == id);
    if (idx == -1) return;
    _orders[idx].pdfStatus = SheetPdfStatus.failed;
    notifyListeners();
  }

  void markPdfGenerating(String id) {
    final idx = _orders.indexWhere((o) => o.id == id);
    if (idx == -1) return;
    _orders[idx].pdfStatus = SheetPdfStatus.generating;
    notifyListeners();
  }

  OrderRecord? findById(String id) {
    try {
      return _orders.firstWhere((o) => o.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Re-reads each order's live `status` from Firestore so My Orders reflects
  /// the shop's real progress (received → printing → shipped → delivered)
  /// instead of the value frozen at checkout. Offline-safe: a failure on one
  /// order (no network, Firebase not ready, rules) is swallowed and leaves that
  /// record untouched. Notifies (and persists) only if something actually
  /// changed.
  Future<void> refreshFromCloud() async {
    if (_orders.isEmpty) return;
    var changed = false;
    for (final o in List<OrderRecord>.of(_orders)) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('orders')
            .doc(o.id)
            .get();
        final data = snap.data();
        if (data == null) continue;
        final raw = (data['status'] ?? '').toString();
        OrderStatus? next;
        for (final v in OrderStatus.values) {
          if (v.name == raw) {
            next = v;
            break;
          }
        }
        if (next != null && next != o.status) {
          o.status = next;
          changed = true;
        }
      } catch (e) {
        debugPrint('[OrdersStore] refresh ${o.id} failed: $e');
      }
    }
    if (changed) {
      _save();
      notifyListeners();
    }
  }

  /// Wipe everything (testing utility).
  Future<void> clearAll() async {
    _orders.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    await OrderBlobStore.clear();
    notifyListeners();
  }

  /// Groups orders by `groupKey` (product + size + dimensions). Used for the
  /// merchant's "Print Queue" view — print all orders of one size together.
  Map<String, List<OrderRecord>> groupedByCategorySize({
    bool excludeDelivered = true,
  }) {
    final groups = <String, List<OrderRecord>>{};
    for (final o in _orders) {
      if (excludeDelivered && o.status == OrderStatus.delivered) continue;
      groups.putIfAbsent(o.groupKey, () => []).add(o);
    }
    return groups;
  }

  // ─── Persistence ───────────────────────────────────────────────
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        // MERGE by id (don't clear+addAll): an order placed via place() during
        // this async startup gap must not be wiped by the restore. Restored
        // records fill in only ids not already present. They are inserted at
        // the FRONT in their saved (oldest-first) order, BEFORE anything placed
        // during the gap — `all` reverses this, so the newest order stays on
        // top and the list no longer flips oldest-first each launch.
        final have = _orders.map((o) => o.id).toSet();
        final restored = [
          for (final rec in list.map(OrderRecord.fromJson))
            if (!have.contains(rec.id)) rec
        ];
        _orders.insertAll(0, restored);
        debugPrint('[OrdersStore] restored ${_orders.length} orders');
        // For each restored order, try to hydrate its PDF from IndexedDB.
        // If found → flip status to ready and attach bytes.
        for (final o in _orders) {
          final bytes = await OrderBlobStore.load(o.id);
          if (bytes != null) {
            o.pdfBytes = bytes;
            o.pdfStatus = SheetPdfStatus.ready;
            debugPrint(
                '[OrdersStore] hydrated PDF for ${o.displayId} (${(bytes.length / 1024).round()} KB)');
          }
        }
      }
    } catch (e) {
      debugPrint('[OrdersStore] restore failed: $e');
    } finally {
      _restored = true;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_orders.map((o) => o.toJson()).toList());
      await prefs.setString(_storageKey, raw);
    } catch (e) {
      debugPrint('[OrdersStore] save failed: $e');
    }
  }
}
