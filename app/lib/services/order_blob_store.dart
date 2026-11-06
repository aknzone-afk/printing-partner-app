import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';
import 'package:idb_shim/idb_browser.dart';

/// IndexedDB-backed cache for print-ready PDF bytes. Survives page refresh
/// and is shared across browser tabs of the same origin — so the merchant
/// tab can download a PDF that the customer tab generated.
///
/// Why not localStorage? localStorage caps at ~5 MB per origin and a
/// multi-sheet PDF easily exceeds that. IndexedDB has gigabytes available
/// and stores binary data directly without base64 overhead.
class OrderBlobStore {
  static const _dbName = 'pp_blobs_v1';
  static const _store = 'pdfs';
  static const _dbVersion = 1;

  static Future<Database> _open() async {
    final factory = getIdbFactory();
    if (factory == null) {
      throw StateError('No IndexedDB factory available on this platform.');
    }
    return factory.open(
      _dbName,
      version: _dbVersion,
      onUpgradeNeeded: (e) {
        final db = e.database;
        if (!db.objectStoreNames.contains(_store)) {
          db.createObjectStore(_store);
        }
      },
    );
  }

  static Future<void> save(String orderId, Uint8List bytes) async {
    try {
      final db = await _open();
      final txn = db.transaction(_store, idbModeReadWrite);
      await txn.objectStore(_store).put(bytes, orderId);
      await txn.completed;
      db.close();
    } catch (e) {
      debugPrint('[OrderBlobStore] save($orderId) failed: $e');
    }
  }

  static Future<Uint8List?> load(String orderId) async {
    try {
      final db = await _open();
      final txn = db.transaction(_store, idbModeReadOnly);
      final result = await txn.objectStore(_store).getObject(orderId);
      await txn.completed;
      db.close();
      if (result == null) return null;
      // IndexedDB may hand back a `List<int>` rather than `Uint8List`.
      if (result is Uint8List) return result;
      if (result is List<int>) return Uint8List.fromList(result);
      return null;
    } catch (e) {
      debugPrint('[OrderBlobStore] load($orderId) failed: $e');
      return null;
    }
  }

  static Future<void> delete(String orderId) async {
    try {
      final db = await _open();
      final txn = db.transaction(_store, idbModeReadWrite);
      await txn.objectStore(_store).delete(orderId);
      await txn.completed;
      db.close();
    } catch (e) {
      debugPrint('[OrderBlobStore] delete($orderId) failed: $e');
    }
  }

  static Future<void> clear() async {
    try {
      final db = await _open();
      final txn = db.transaction(_store, idbModeReadWrite);
      await txn.objectStore(_store).clear();
      await txn.completed;
      db.close();
    } catch (e) {
      debugPrint('[OrderBlobStore] clear failed: $e');
    }
  }
}
