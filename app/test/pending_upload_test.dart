// The checkout "resume record" (lib/services/pending_upload.dart): it is what
// stops a paid order from being created twice after the app is killed
// mid-upload, so it must round-trip, expire, survive garbage, and only ever
// be resumed for the same cart and the same customer.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:printing_partner/services/pending_upload.dart';

const String kPackKey = 'photos|Regular|18';

PendingUpload record({
  String orderId = 'doc_AbC123',
  String orderNumber = '1042',
  String? token = 'body.sig',
  String uid = 'uid-A',
  String packKey = kPackKey,
  int photoCount = 18,
  int amountPaise = 17500,
  bool ingestAttempted = false,
  int? savedAtMs,
}) =>
    PendingUpload(
      orderId: orderId,
      orderNumber: orderNumber,
      placedAtIso: '2026-11-10T05:00:00.000Z',
      token: token,
      uid: uid,
      packKey: packKey,
      photoCount: photoCount,
      amountPaise: amountPaise,
      ingestAttempted: ingestAttempted,
      savedAtMs: savedAtMs ?? DateTime.now().millisecondsSinceEpoch,
    );

/// The single SharedPreferences key the record is stored under.
Future<String> storageKey() async {
  await PendingUpload.save(record());
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getKeys().single;
  await PendingUpload.clear();
  return key;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final DebugPrintCallback realDebugPrint = debugPrint;
  setUpAll(() => debugPrint = (String? message, {int? wrapWidth}) {});
  tearDownAll(() => debugPrint = realDebugPrint);

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('nothing stored -> null', () async {
    expect(await PendingUpload.load(), isNull);
  });

  test('save -> load round trip keeps every field; clear removes it',
      () async {
    final fresh = record(ingestAttempted: true);
    await PendingUpload.save(fresh);

    final got = await PendingUpload.load();
    expect(got, isNotNull);
    expect(got!.orderId, fresh.orderId);
    expect(got.orderNumber, fresh.orderNumber);
    expect(got.placedAtIso, fresh.placedAtIso);
    expect(got.token, fresh.token);
    expect(got.uid, fresh.uid);
    expect(got.packKey, fresh.packKey);
    expect(got.photoCount, fresh.photoCount);
    expect(got.amountPaise, fresh.amountPaise);
    expect(got.ingestAttempted, isTrue);
    expect(got.savedAtMs, fresh.savedAtMs);
    expect(got.toJson(), fresh.toJson());

    await PendingUpload.clear();
    expect(await PendingUpload.load(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('an expired upload pass (token null) round-trips as null, and an '
      'empty token is read as null', () async {
    await PendingUpload.save(record(token: null));
    expect((await PendingUpload.load())!.token, isNull);

    await PendingUpload.save(record(token: ''));
    final got = await PendingUpload.load();
    expect(got, isNotNull, reason: 'the ORDER is kept, only the pass is gone');
    expect(got!.token, isNull);
  });

  test('a newer save replaces the older record (one pending order at most)',
      () async {
    await PendingUpload.save(record(orderId: 'first', orderNumber: '1'));
    await PendingUpload.save(record(orderId: 'second', orderNumber: '2'));
    final got = await PendingUpload.load();
    expect(got!.orderId, 'second');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().length, 1);
  });

  group('expiry (24 h, the backend token TTL)', () {
    test('23 h old is still resumable', () async {
      final at = DateTime.now()
          .subtract(const Duration(hours: 23))
          .millisecondsSinceEpoch;
      await PendingUpload.save(record(savedAtMs: at));
      expect((await PendingUpload.load())?.orderNumber, '1042');
    });

    test('25 h old is dropped AND removed from storage', () async {
      final at = DateTime.now()
          .subtract(const Duration(hours: 25))
          .millisecondsSinceEpoch;
      await PendingUpload.save(record(savedAtMs: at));
      expect(await PendingUpload.load(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty,
          reason: 'an expired record must not linger');
      expect(await PendingUpload.load(), isNull);
    });

    test('maxAge is 24 hours', () {
      expect(PendingUpload.maxAge, const Duration(hours: 24));
    });

    test('a record without a timestamp counts as expired', () async {
      final key = await storageKey();
      final j = record().toJson()..remove('savedAtMs');
      SharedPreferences.setMockInitialValues({key: jsonEncode(j)});
      expect(await PendingUpload.load(), isNull);
    });

    test('copyWith keeps the order identity and can clear / replace the pass',
        () {
      final r = record(savedAtMs: 1000);
      final cleared = r.copyWith(clearToken: true, ingestAttempted: true);
      expect(cleared.token, isNull);
      expect(cleared.ingestAttempted, isTrue);
      expect(cleared.orderId, r.orderId);
      expect(cleared.orderNumber, r.orderNumber);
      expect(cleared.uid, r.uid);
      expect(cleared.packKey, r.packKey);
      expect(cleared.photoCount, r.photoCount);
      expect(cleared.amountPaise, r.amountPaise);
      final renewed = cleared.copyWith(token: 'new.sig');
      expect(renewed.token, 'new.sig');
      expect(renewed.ingestAttempted, isTrue);
    });
  });

  group('unreadable storage never throws and never resumes', () {
    final garbage = <String, String>{
      'truncated JSON': '{"orderId":"doc_AbC123","orderNumber":"10',
      'not JSON': 'hello',
      'empty': '',
      'JSON array': '[1,2,3]',
      'JSON string': '"1042"',
      'JSON null': 'null',
      'no order id': jsonEncode(record().toJson()..remove('orderId')),
      'empty order number': jsonEncode(record().toJson()..['orderNumber'] = ''),
    };
    for (final e in garbage.entries) {
      test(e.key, () async {
        final key = await storageKey();
        SharedPreferences.setMockInitialValues({key: e.value});
        expect(await PendingUpload.load(), isNull);
        // A later save still works (the bad value is simply replaced).
        await PendingUpload.save(record(orderNumber: '2001'));
        expect((await PendingUpload.load())?.orderNumber, '2001');
      });
    }

    test('a value of the wrong type under the key is tolerated', () async {
      final key = await storageKey();
      SharedPreferences.setMockInitialValues({key: 42});
      expect(await PendingUpload.load(), isNull);
      await PendingUpload.clear();
    });

    test('wrong field types fall back to safe defaults, order kept', () async {
      final key = await storageKey();
      final j = record().toJson()
        ..['photoCount'] = '18'
        ..['amountPaise'] = null
        ..['ingestAttempted'] = 'yes'
        ..['token'] = 12345
        ..['uid'] = null;
      SharedPreferences.setMockInitialValues({key: jsonEncode(j)});
      final got = await PendingUpload.load();
      expect(got, isNotNull);
      expect(got!.orderNumber, '1042');
      expect(got.photoCount, 0);
      expect(got.amountPaise, 0);
      expect(got.ingestAttempted, isFalse);
      expect(got.token, isNull);
      expect(got.uid, '');
      // photoCount 0 can never match a real cart -> not resumed.
      expect(got.isFor(uid: 'uid-A', packKey: kPackKey, photoCount: 18),
          isFalse);
    });
  });

  group('isFor: resumed only for the same cart and the same customer', () {
    final r = record();

    test('same uid + same pack + same photo count -> resume', () {
      expect(r.isFor(uid: 'uid-A', packKey: kPackKey, photoCount: 18), isTrue);
    });

    test('a different customer uid is NOT resumed', () {
      expect(
          r.isFor(uid: 'uid-B', packKey: kPackKey, photoCount: 18), isFalse);
    });

    test('a different cart key is NOT resumed (category, size or pack count)',
        () {
      for (final other in [
        'polaroid|Regular|18',
        'photos|Regular Mini|18',
        'photos|Regular|27',
        'photos|regular|18',
        '',
      ]) {
        expect(r.isFor(uid: 'uid-A', packKey: other, photoCount: 18), isFalse,
            reason: 'cart "$other"');
      }
    });

    test('a different number of photos is NOT resumed', () {
      expect(
          r.isFor(uid: 'uid-A', packKey: kPackKey, photoCount: 17), isFalse);
      expect(r.isFor(uid: 'uid-A', packKey: kPackKey, photoCount: 0), isFalse);
    });

    test('an unknown uid (not signed in yet / legacy record) is not a mismatch',
        () {
      expect(r.isFor(uid: null, packKey: kPackKey, photoCount: 18), isTrue);
      expect(r.isFor(uid: '', packKey: kPackKey, photoCount: 18), isTrue);
      final legacy = record(uid: '');
      expect(legacy.isFor(uid: 'uid-B', packKey: kPackKey, photoCount: 18),
          isTrue);
    });

    test('the match survives a save/load round trip', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await PendingUpload.save(r);
      final got = (await PendingUpload.load())!;
      expect(got.isFor(uid: 'uid-A', packKey: kPackKey, photoCount: 18),
          isTrue);
      expect(got.isFor(uid: 'uid-B', packKey: kPackKey, photoCount: 18),
          isFalse);
      expect(got.isFor(uid: 'uid-A', packKey: 'photos|Regular|27', photoCount: 18),
          isFalse);
    });
  });
}
