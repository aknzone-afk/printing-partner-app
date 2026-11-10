// How the app reads the backend's answers (lib/services/backend_api.dart and
// lib/services/payment_verifier.dart). The response bodies below are the ones
// backend/app.py really sends.
//
// The HTTP layer is replaced with package:http's MockClient through
// `http.runWithClient` — BackendApi builds its clients with `http.Client()` /
// `http.post`, which honour that zone override, so no production code changes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:printing_partner/services/backend_api.dart';
import 'package:printing_partner/services/payment_verifier.dart';
import 'package:printing_partner/services/upi_qr.dart';

typedef Handler = FutureOr<http.Response> Function(http.Request request);

Future<T> withBackend<T>(Handler handler, Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient((r) async => handler(r)));

/// A Flask `jsonify` answer (UTF-8 JSON, `Content-Type: application/json`).
http.Response json(int status, Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json'},
    );

/// A proxy / framework error page (Caddy 502, Flask abort(401), 413 ...).
http.Response html(int status, String title) => http.Response(
      '<!doctype html><html><title>$title</title><h1>$title</h1></html>',
      status,
      headers: const {'content-type': 'text/html; charset=utf-8'},
    );

class Part {
  Part(this.name, this.filename, this.bytes);
  final String name;
  final String? filename;
  final Uint8List bytes;
  String get text => utf8.decode(bytes);
}

/// Minimal multipart/form-data reader for asserting what the app sent.
List<Part> multipartParts(http.Request request) {
  final ct = request.headers['content-type'] ?? '';
  final m = RegExp(r'boundary=("?)([^";]+)\1').firstMatch(ct);
  if (m == null) fail('not a multipart request: "$ct"');
  final body = latin1.decode(request.bodyBytes);
  final parts = <Part>[];
  for (final chunk in body.split('--${m.group(2)}')) {
    final sep = chunk.indexOf('\r\n\r\n');
    if (sep < 0) continue; // preamble / closing "--"
    final head = chunk.substring(0, sep);
    var content = chunk.substring(sep + 4);
    if (content.endsWith('\r\n')) {
      content = content.substring(0, content.length - 2);
    }
    final name = RegExp(r'name="([^"]*)"').firstMatch(head)?.group(1) ?? '';
    final filename = RegExp(r'filename="([^"]*)"').firstMatch(head)?.group(1);
    parts.add(Part(name, filename, Uint8List.fromList(latin1.encode(content))));
  }
  return parts;
}

final Uint8List shot =
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0, 13, 10, 255, 0xD9]);

const okVerify = <String, dynamic>{
  'verified': true,
  'amount': 150.0,
  'utr': '431234567890',
  'payee': '8094804784@ptyes',
  'reason': 'Payment of ₹150 confirmed. ✅',
  'token': 'eyJhbW91bnQiOjE1MC4wfQ==.0123456789abcdef0123456789abcdef',
};

Future<PaymentCheck> verifyWith(Handler handler, {double rupees = 150}) =>
    withBackend(
      handler,
      () => PaymentVerifier.instance.verify(
        screenshotJpg: shot,
        expectedRupees: rupees,
        ourUpiId: UpiQr.merchantUpiId,
        ourName: UpiQr.merchantName,
      ),
    );

typedef Ingest = ({
  bool ok,
  int status,
  String? error,
  bool duplicate,
  String? orderNumber,
});

const order = <String, dynamic>{
  'orderNumber': '1042',
  'category': 'photos',
  'size': 'Regular',
  'snapCount': 18,
  'amountRupees': 175.0,
  'placedAt': '2026-11-10T05:00:00.000Z',
};

Future<Ingest> ingestWith(Handler handler, {List<Uint8List>? photos}) =>
    withBackend(
      handler,
      () => BackendApi.ingest(
        order: order,
        token: 'tok.sig',
        photosJpg: photos ?? [shot],
      ),
    );

void main() {
  group('/verify-payment -> PaymentCheck', () {
    test('200 verified + token = verified, with every field passed through',
        () async {
      late http.Request seen;
      final c = await verifyWith((r) {
        seen = r;
        return json(200, okVerify);
      });
      expect(c.verified, isTrue);
      expect(c.token, okVerify['token']);
      expect(c.amountRead, 150.0);
      expect(c.utr, '431234567890');
      expect(c.payee, '8094804784@ptyes');
      expect(c.reason, 'Payment of ₹150 confirmed. ✅',
          reason: 'the rupee sign must survive the UTF-8 JSON round trip');

      // What the app sent.
      expect(seen.method, 'POST');
      expect(seen.url.toString(), '${BackendApi.baseUrl}/verify-payment');
      expect(seen.url.scheme, 'https');
      expect(seen.headers['X-App-Token'], BackendApi.appToken);
      final parts = multipartParts(seen);
      String field(String n) => parts.singleWhere((p) => p.name == n).text;
      expect(field('amount'), '150.00');
      expect(field('ourUpiId'), '8094804784@ptyes');
      final file = parts.singleWhere((p) => p.name == 'screenshot');
      expect(file.filename, isNotEmpty);
      expect(file.bytes, shot, reason: 'the screenshot bytes are sent intact');
    });

    test('the amount is sent with exactly 2 decimals', () async {
      for (final e in {150.0: '150.00', 301.0: '301.00', 199.5: '199.50'}
          .entries) {
        late http.Request seen;
        await verifyWith((r) {
          seen = r;
          return json(200, okVerify);
        }, rupees: e.key);
        expect(
            multipartParts(seen).singleWhere((p) => p.name == 'amount').text,
            e.value);
      }
    });

    test('200 verified WITHOUT a token is NOT verified', () async {
      for (final token in <Object?>[null, '', '   ']) {
        final body = Map<String, dynamic>.from(okVerify)..remove('token');
        if (token != null) body['token'] = token;
        final c = await verifyWith((_) => json(200, body));
        expect(c.verified, isFalse, reason: 'token ${jsonEncode(token)}');
        expect(c.token, isNull);
        expect(c.reason, isNotEmpty);
        expect(c.reason.toLowerCase(), isNot(contains('confirmed')),
            reason: 'must not show the server\'s "confirmed" text');
      }
    });

    test('200 with a non-boolean "verified" is NOT verified, token dropped',
        () async {
      for (final v in <Object?>['true', 1, 'yes', null]) {
        final body = Map<String, dynamic>.from(okVerify)..['verified'] = v;
        final c = await verifyWith((_) => json(200, body));
        expect(c.verified, isFalse, reason: 'verified=${jsonEncode(v)}');
        expect(c.token, isNull);
      }
    });

    test('200 verified:false shows the server reason and what was read',
        () async {
      const reason =
          'The screenshot shows ₹100 but your order is ₹150. Please pay the '
          'exact amount.';
      final c = await verifyWith((_) => json(200, {
            'verified': false,
            'amount': 100.0,
            'utr': '431234567890',
            'payee': 'someone@upi',
            'reason': reason,
            'token': 'must-be-ignored',
          }));
      expect(c.verified, isFalse);
      expect(c.reason, reason);
      expect(c.amountRead, 100.0);
      expect(c.utr, '431234567890');
      expect(c.token, isNull);
    });

    test('503 ai_unconfigured = not verified, server reason shown verbatim',
        () async {
      const reason =
          'Payment verification is being set up. Please try again shortly.';
      final c = await verifyWith((_) => json(503,
          {'verified': false, 'reason': reason, 'code': 'ai_unconfigured'}));
      expect(c.verified, isFalse);
      expect(c.reason, reason);
      expect(c.token, isNull);
    });

    test('a non-200 can never verify, even if its body claims so', () async {
      for (final status in [201, 400, 401, 402, 500, 502, 503]) {
        final c = await verifyWith((_) => json(status, okVerify));
        expect(c.verified, isFalse, reason: 'HTTP $status');
        expect(c.token, isNull, reason: 'HTTP $status');
      }
    });

    test('error pages (401 wrong app token, 502 from the proxy) give a '
        'readable reason, not HTML', () async {
      for (final status in [401, 413, 502]) {
        final c = await verifyWith((_) => html(status, 'Error $status'));
        expect(c.verified, isFalse);
        expect(c.reason, isNot(contains('<')));
        expect(c.reason, contains('$status'));
        expect(c.reason.toLowerCase(), contains('try again'));
      }
    });

    test('200 with a body that is not a JSON object is not verified',
        () async {
      for (final body in ['', 'OK', '[true]', '"verified"', '{"verified":']) {
        final c = await verifyWith((_) => http.Response(body, 200,
            headers: const {'content-type': 'application/json'}));
        expect(c.verified, isFalse, reason: 'body: $body');
        expect(c.token, isNull);
        expect(c.reason, isNotEmpty);
      }
    });

    test('network error = not verified, asks to check the internet', () async {
      for (final Object error in [
        const SocketException('Failed host lookup: 130-210-24-18.nip.io'),
        http.ClientException('Connection closed before full header'),
        const HandshakeException('bad certificate'),
      ]) {
        final c = await verifyWith((_) => throw error);
        expect(c.verified, isFalse, reason: '$error');
        expect(c.token, isNull);
        expect(c.reason.toLowerCase(), contains('internet'));
        expect(c.reason, isNot(contains('Exception')),
            reason: 'no raw exception text for the customer');
      }
    });

    testWidgets('a server that never answers times out after 30 s as "not '
        'verified"', (tester) async {
      PaymentCheck? out;
      unawaited(verifyWith((_) => Completer<http.Response>().future)
          .then((v) => out = v));
      await tester.pump(const Duration(seconds: 29));
      expect(out, isNull, reason: 'still waiting inside the timeout');
      await tester.pump(const Duration(seconds: 2));
      expect(out, isNotNull, reason: 'must give up after 30 s');
      expect(out!.verified, isFalse);
      expect(out!.token, isNull);
      expect(out!.reason.toLowerCase(), contains('internet'));
    });

    test('amount sent as a string is still read', () async {
      final body = Map<String, dynamic>.from(okVerify)..['amount'] = '150.00';
      final c = await verifyWith((_) => json(200, body));
      expect(c.verified, isTrue);
      expect(c.amountRead, 150.0);
    });

    test('BackendApi.verifyPayment reports httpStatus (0 = no answer)',
        () async {
      final ok = await withBackend(
          (_) => json(200, okVerify),
          () => BackendApi.verifyPayment(
              screenshotJpg: shot, amountRupees: 150));
      expect(ok['httpStatus'], 200);
      expect(ok['verified'], isTrue);
      final unavailable = await withBackend(
          (_) => json(503, {'verified': false, 'reason': 'x'}),
          () => BackendApi.verifyPayment(
              screenshotJpg: shot, amountRupees: 150));
      expect(unavailable['httpStatus'], 503);
      final down = await withBackend(
          (_) => throw const SocketException('down'),
          () => BackendApi.verifyPayment(
              screenshotJpg: shot, amountRupees: 150));
      expect(down['httpStatus'], 0);
      expect(down['verified'], isFalse);
    });
  });

  group('/ingest outcomes', () {
    test('200 ok = filed; the request carries the order, the token and every '
        'photo in order', () async {
      final photos = [
        for (var i = 0; i < 5; i++)
          Uint8List.fromList([0xFF, 0xD8, i, i, 13, 10, 45, 45, i, 0xFF, 0xD9])
      ];
      late http.Request seen;
      final r = await ingestWith((req) {
        seen = req;
        return json(200, {'ok': true, 'filed': 5});
      }, photos: photos);
      expect(r.ok, isTrue);
      expect(r.status, 200);
      expect(r.duplicate, isFalse);
      expect(r.error, isNull);

      expect(seen.method, 'POST');
      expect(seen.url.toString(), '${BackendApi.baseUrl}/ingest');
      expect(seen.headers['X-App-Token'], BackendApi.appToken);
      final parts = multipartParts(seen);
      expect(jsonDecode(parts.singleWhere((p) => p.name == 'order').text),
          order);
      expect(parts.singleWhere((p) => p.name == 'token').text, 'tok.sig');
      final files = parts.where((p) => p.name == 'photos').toList();
      expect(files.length, photos.length);
      for (var i = 0; i < photos.length; i++) {
        expect(files[i].bytes, photos[i], reason: 'photo $i order / bytes');
      }
      expect(files.map((f) => f.filename).toList(), [
        'photo_001.jpg',
        'photo_002.jpg',
        'photo_003.jpg',
        'photo_004.jpg',
        'photo_005.jpg'
      ]);
    });

    test('200 duplicate:true (already filed on a lost-answer attempt) = ok',
        () async {
      final r = await ingestWith((_) => json(200,
          {'ok': true, 'filed': 18, 'duplicate': true, 'orderNumber': '1042'}));
      expect(r.ok, isTrue);
      expect(r.duplicate, isTrue);
      expect(r.orderNumber, '1042');
      expect(r.error, isNull);
    });

    test('200 without ok:true is not a success', () async {
      for (final http.Response res in [
        json(200, {'ok': false, 'error': 'filing_failed'}),
        json(200, {'filed': 3}),
        http.Response('', 200),
        html(200, 'Welcome to Caddy'),
      ]) {
        final r = await ingestWith((_) => res);
        expect(r.ok, isFalse, reason: res.body);
        expect(r.duplicate, isFalse);
        expect(r.error, isNotEmpty);
      }
    });

    test('402 token_expired, 402 amount_mismatch, 402 payment_required, 409, '
        '413 and "no answer" are all told apart', () async {
      final tokenExpired = await ingestWith((_) => json(402, {
            'ok': false,
            'error': 'token_expired',
            'reason':
                'Your upload pass expired. Please re-attach the payment screenshot.',
          }));
      final amountMismatch = await ingestWith((_) => json(402, {
            'ok': false,
            'error': 'amount_mismatch',
            'reason': 'Paid ₹150 but this pack costs ₹175. Please pay the full '
                'amount.',
          }));
      final paymentRequired = await ingestWith((_) => json(402, {
            'ok': false,
            'error': 'payment_required',
            'reason': 'Payment not verified.',
          }));
      final utrReused = await ingestWith((_) => json(
          409, {'ok': false, 'error': 'utr_reused', 'orderNumber': '1017'}));
      final tooLarge = await ingestWith(
          (_) => json(413, {'ok': false, 'error': 'photo too large'}));
      final proxyTooLarge =
          await ingestWith((_) => html(413, 'Request Entity Too Large'));
      final offline =
          await ingestWith((_) => throw const SocketException('offline'));

      // The exact values checkout_screen.dart branches on.
      expect((tokenExpired.status, tokenExpired.error), (402, 'token_expired'));
      expect((amountMismatch.status, amountMismatch.error),
          (402, 'amount_mismatch'));
      expect((paymentRequired.status, paymentRequired.error),
          (402, 'payment_required'));
      expect((utrReused.status, utrReused.error), (409, 'utr_reused'));
      expect(utrReused.orderNumber, '1017',
          reason: 'which order consumed the payment');
      expect(tooLarge.status, 413);
      expect(tooLarge.error, 'photo too large');
      expect(proxyTooLarge.status, 413);
      expect(proxyTooLarge.error, isNot(contains('<')));
      expect(proxyTooLarge.error, isNotEmpty);
      expect(offline.status, 0);
      expect(offline.error!.toLowerCase(), contains('internet'));

      final all = [
        tokenExpired,
        amountMismatch,
        paymentRequired,
        utrReused,
        tooLarge,
        offline
      ];
      for (final r in all) {
        expect(r.ok, isFalse);
        expect(r.duplicate, isFalse);
        expect(r.error, isNotNull);
        expect(r.error, isNotEmpty);
      }
      expect({for (final r in all) '${r.status}|${r.error}'}.length, all.length,
          reason: 'every failure must be distinguishable by (status, error)');
    });

    test('409 without an order number reports orderNumber null (so checkout '
        'can fall back to "was this token already sent?")', () async {
      for (final body in <Map<String, dynamic>>[
        {'ok': false, 'error': 'utr_reused', 'orderNumber': ''},
        {'ok': false, 'error': 'utr_reused'},
      ]) {
        final r = await ingestWith((_) => json(409, body));
        expect(r.status, 409);
        expect(r.orderNumber, isNull);
        expect(r.error, 'utr_reused');
      }
      final bare = await ingestWith((_) => html(409, 'Conflict'));
      expect((bare.status, bare.error), (409, 'utr_reused'));
    });

    test('400 / 5xx keep the server code; error pages get a status-based one',
        () async {
      final unknown = await ingestWith((_) => json(400, {
            'ok': false,
            'error': 'unknown_pack',
            'reason': 'This print pack is not in the catalog.'
          }));
      expect((unknown.status, unknown.error), (400, 'unknown_pack'));
      final filing =
          await ingestWith((_) => json(500, {'ok': false, 'error': 'filing_failed'}));
      expect((filing.status, filing.error), (500, 'filing_failed'));
      final gateway = await ingestWith((_) => html(502, 'Bad Gateway'));
      expect(gateway.status, 502);
      expect(gateway.error, contains('502'));
      final denied = await ingestWith((_) => html(401, 'Unauthorized'));
      expect(denied.status, 401);
      expect(denied.ok, isFalse);
    });

    test('the upload timeout grows with the payload (90 s floor, 40 KB/s)',
        () {
      expect(BackendApi.ingestTimeoutFor(0), const Duration(seconds: 90));
      expect(BackendApi.ingestTimeoutFor(40 * 1024),
          const Duration(seconds: 91));
      expect(BackendApi.ingestTimeoutFor(25 * 1024 * 1024),
          const Duration(seconds: 90 + 640));
      var last = Duration.zero;
      for (final mb in [0, 1, 5, 25, 100, 300]) {
        final t = BackendApi.ingestTimeoutFor(mb * 1024 * 1024);
        expect(t, greaterThanOrEqualTo(last));
        last = t;
      }
    });

    testWidgets('a server that never answers times out (status 0) instead of '
        'hanging the checkout', (tester) async {
      Ingest? out;
      unawaited(ingestWith((_) => Completer<http.Response>().future)
          .then((v) => out = v));
      await tester.pump(const Duration(seconds: 89));
      expect(out, isNull, reason: 'inside the 90 s floor');
      await tester.pump(const Duration(seconds: 2));
      expect(out, isNotNull, reason: 'must give up after the timeout');
      expect(out!.ok, isFalse);
      expect(out!.status, 0);
      expect(out!.duplicate, isFalse);
      expect(out!.error!.toLowerCase(), contains('internet'));
    });
  });

  group('/chat', () {
    Future<({String reply, bool ok, String? code})> chatWith(Handler h) =>
        withBackend(
            h,
            () => BackendApi.chat(
                  facts: 'Order #1042, 18 photos',
                  message: 'Where is my order?',
                  history: const [
                    {'role': 'user', 'text': 'hi'},
                    {'role': 'model', 'text': 'Hello!'},
                  ],
                ));

    test('200 with a reply = ok; the request is JSON with facts + history',
        () async {
      late http.Request seen;
      final r = await chatWith((req) {
        seen = req;
        return json(200, {'reply': 'It is being printed.'});
      });
      expect(r, (reply: 'It is being printed.', ok: true, code: null));
      expect(seen.url.toString(), '${BackendApi.baseUrl}/chat');
      expect(seen.headers['X-App-Token'], BackendApi.appToken);
      final sent = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(sent['message'], 'Where is my order?');
      expect(sent['facts'], 'Order #1042, 18 photos');
      expect(sent['history'], [
        {'role': 'user', 'text': 'hi'},
        {'role': 'model', 'text': 'Hello!'},
      ]);
    });

    test('503 / 502 / empty / offline are never "ok" and always have text',
        () async {
      final setup = await chatWith((_) => json(503, {
            'reply': 'The order assistant is being set up. Please try again '
                'shortly.',
            'code': 'ai_unconfigured'
          }));
      expect(setup.ok, isFalse);
      expect(setup.code, 'ai_unconfigured');
      expect(setup.reply, startsWith('The order assistant is being set up'));

      final busy = await chatWith((_) => json(502,
          {'reply': "I couldn't answer right now. Please try again shortly."}));
      expect((busy.ok, busy.code), (false, 'http_502'));
      expect(busy.reply, contains("couldn't answer"));

      final empty = await chatWith((_) => json(200, {'reply': '  '}));
      expect((empty.ok, empty.code), (false, 'empty'));
      expect(empty.reply, isNotEmpty);

      final page = await chatWith((_) => html(502, 'Bad Gateway'));
      expect(page.ok, isFalse);
      expect(page.reply, isNot(contains('<')));

      final offline =
          await chatWith((_) => throw const SocketException('offline'));
      expect((offline.ok, offline.code), (false, 'network'));
      expect(offline.reply, isNotEmpty);
    });
  });
}
