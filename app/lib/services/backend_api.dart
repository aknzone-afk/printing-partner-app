import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Thin client for the Printing Partner backend (Flask on the owner's Oracle
/// VM). Every call is wrapped so it NEVER throws — callers get a safe, already
/// customer-friendly fallback on network / timeout / parse failure.
class BackendApi {
  BackendApi._();

  static const String baseUrl = 'https://130-210-24-18.nip.io';
  static const String appToken = '278fe826b3c836ad2310568a8bd16db7';

  static const String _netError =
      "Couldn't verify right now. Check your internet and try again.";
  static const String _chatFallback =
      "Sorry, I couldn't reach the assistant right now. Please try again in a "
      'moment, or the shop team will help you.';

  static Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// POST /verify-payment (multipart). Returns the decoded JSON body plus
  /// `httpStatus` (int). On any failure returns
  /// `{verified:false, reason:<friendly>, httpStatus:0}`.
  static Future<Map<String, dynamic>> verifyPayment({
    required Uint8List screenshotJpg,
    required double amountRupees,
    String? ourUpiId,
  }) async {
    http.Client? client;
    try {
      client = http.Client();
      final req = http.MultipartRequest('POST', _u('/verify-payment'))
        ..headers['X-App-Token'] = appToken
        ..fields['amount'] = amountRupees.toStringAsFixed(2)
        ..files.add(http.MultipartFile.fromBytes(
          'screenshot',
          screenshotJpg,
          filename: 'screenshot.jpg',
        ));
      if (ourUpiId != null && ourUpiId.trim().isNotEmpty) {
        req.fields['ourUpiId'] = ourUpiId.trim();
      }

      final streamed =
          await client.send(req).timeout(const Duration(seconds: 30));
      final res = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 30));

      final body = _decodeMap(res.body);
      body['httpStatus'] = res.statusCode;
      if (res.statusCode != 200) {
        // Server-side refusal (503 ai_unconfigured, 4xx, 5xx): never "paid".
        body['verified'] = false;
        body['reason'] = _str(body['reason']) ??
            _str(body['error']) ??
            'Payment check failed (server ${res.statusCode}). Please try again.';
        body.remove('token');
      } else {
        body['verified'] = body['verified'] == true;
        body['reason'] ??= body['verified'] == true
            ? 'Payment confirmed.'
            : "Couldn't confirm this payment. Please attach a clear "
                '"payment successful" screenshot.';
        if (body['verified'] != true) body.remove('token');
      }
      return body;
    } catch (e) {
      debugPrint('[BackendApi] verifyPayment failed: $e');
      return <String, dynamic>{
        'verified': false,
        'reason': _netError,
        'httpStatus': 0,
      };
    } finally {
      client?.close();
    }
  }

  /// POST /chat (JSON). Never throws. `ok` is true only for a real assistant
  /// answer; otherwise `reply` is the server's own customer-ready text (503
  /// "being set up", 502 "couldn't answer", 400) or a local fallback, and
  /// `code` says why (`ai_unconfigured`, `http_<status>`, `network`,
  /// `empty`). Callers must not replay a `!ok` reply as conversation history.
  static Future<({String reply, bool ok, String? code})> chat({
    required String facts,
    required String message,
    required List<Map<String, String>> history,
  }) async {
    try {
      final res = await http
          .post(
            _u('/chat'),
            headers: const {
              'Content-Type': 'application/json',
              'X-App-Token': appToken,
            },
            body: jsonEncode({
              'facts': facts,
              'message': message,
              'history': history
                  .map((m) => {
                        'role': m['role'] ?? 'user',
                        'text': m['text'] ?? '',
                      })
                  .toList(),
            }),
          )
          .timeout(const Duration(seconds: 30));
      final body = _decodeMap(res.body);
      final reply = _str(body['reply']);
      if (res.statusCode != 200) {
        debugPrint('[BackendApi] chat HTTP ${res.statusCode}: ${res.body}');
        // The server sends customer-ready text on 503/502/400 — surface it.
        return (
          reply: reply ?? _chatFallback,
          ok: false,
          code: res.statusCode == 503
              ? 'ai_unconfigured'
              : 'http_${res.statusCode}',
        );
      }
      if (reply == null) {
        return (reply: _chatFallback, ok: false, code: 'empty');
      }
      return (reply: reply, ok: true, code: null);
    } catch (e) {
      debugPrint('[BackendApi] chat failed: $e');
      return (reply: _chatFallback, ok: false, code: 'network');
    }
  }

  /// Upload timeout for a multipart body of [totalBytes]: a 90 s floor plus
  /// ~25 s per MB (a 40 KB/s uplink floor), so a 36-photo order on slow mobile
  /// data is never cut off mid-body only to be retried as a UTR reuse.
  static Duration ingestTimeoutFor(int totalBytes) =>
      Duration(seconds: 90 + totalBytes ~/ (40 * 1024));

  /// POST /ingest (multipart): order JSON + payment token + one JPEG per
  /// cropped photo under the repeated field "photos". Never throws.
  /// `status` is the HTTP status (0 = network / timeout / client error).
  /// `duplicate` is true when the server had already filed THIS order (an
  /// idempotent retry after a lost response) — still a success. On 409
  /// `orderNumber` is the order that consumed the UTR, when the server says.
  static Future<
      ({
        bool ok,
        int status,
        String? error,
        bool duplicate,
        String? orderNumber,
      })> ingest({
    required Map<String, dynamic> order,
    required String token,
    required List<Uint8List> photosJpg,
  }) async {
    http.Client? client;
    try {
      client = http.Client();
      final req = http.MultipartRequest('POST', _u('/ingest'))
        ..headers['X-App-Token'] = appToken
        ..fields['order'] = jsonEncode(order)
        ..fields['token'] = token;
      var totalBytes = 0;
      for (var i = 0; i < photosJpg.length; i++) {
        totalBytes += photosJpg[i].length;
        req.files.add(http.MultipartFile.fromBytes(
          'photos',
          photosJpg[i],
          filename: 'photo_${(i + 1).toString().padLeft(3, '0')}.jpg',
        ));
      }
      final timeout = ingestTimeoutFor(totalBytes);

      final streamed = await client.send(req).timeout(timeout);
      final res = await http.Response.fromStream(streamed).timeout(timeout);

      final body = _decodeMap(res.body);
      final ok = res.statusCode == 200 && body['ok'] == true;
      final orderNumber = _str(body['orderNumber']);
      if (ok) {
        return (
          ok: true,
          status: res.statusCode,
          error: null,
          duplicate: body['duplicate'] == true,
          orderNumber: orderNumber,
        );
      }

      final err = _str(body['error']) ??
          _str(body['code']) ??
          _str(body['reason']) ??
          _ingestDefault(res.statusCode);
      return (
        ok: false,
        status: res.statusCode,
        error: err,
        duplicate: false,
        orderNumber: orderNumber,
      );
    } catch (e) {
      debugPrint('[BackendApi] ingest failed: $e');
      return (
        ok: false,
        status: 0,
        error: "Couldn't upload the order right now. Check your internet "
            'and try again.',
        duplicate: false,
        orderNumber: null,
      );
    } finally {
      client?.close();
    }
  }

  // ---------------------------------------------------------------- helpers

  static String _ingestDefault(int status) {
    switch (status) {
      case 402:
        return 'payment_required';
      case 409:
        return 'utr_reused';
      case 413:
        return 'too large';
      default:
        return 'server_error_$status';
    }
  }

  static Map<String, dynamic> _decodeMap(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {
      // Non-JSON body (proxy error page etc.) — fall through.
    }
    return <String, dynamic>{};
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }
}
