import 'dart:convert';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';

/// Result of reading a UPI payment screenshot with Gemini.
class PaymentCheck {
  final bool verified;
  final String reason; // customer-facing message
  final double? amountRead; // rupees Gemini read from the screenshot
  final String? utr; // UTR / UPI reference / transaction id
  final String? payee; // receiver name or VPA read

  const PaymentCheck({
    required this.verified,
    required this.reason,
    this.amountRead,
    this.utr,
    this.payee,
  });
}

/// Reads an Indian UPI payment screenshot with Gemini (Firebase AI Logic — the
/// Gemini Developer API, free on the Spark plan, no key shipped in the app) and
/// checks it paid the expected amount to our account. This is a first-pass
/// confirmation for the customer; the shop still sees the UTR to reconcile.
class PaymentVerifier {
  PaymentVerifier._();
  static final PaymentVerifier instance = PaymentVerifier._();

  GenerativeModel? _model;
  GenerativeModel get _m =>
      _model ??= FirebaseAI.googleAI().generativeModel(model: 'gemini-2.5-flash');

  static const _prompt = '''
You are verifying an Indian UPI payment screenshot (GPay, PhonePe, Paytm, BHIM or a bank app).
Return ONLY one compact JSON object, no markdown fences, with exactly these keys:
{"status":"success|failed|pending|unknown","amount":<number of rupees or null>,"utr":"<UTR / UPI reference / transaction id or empty>","payeeName":"<money receiver's name or empty>","payeeUpiId":"<receiver UPI id / VPA or empty>"}
Rules:
- "amount" is a plain number of rupees (e.g. "₹1,499.00" -> 1499).
- "status" is "success" only if the screen clearly shows the payment completed/paid.
- If it is not a UPI payment screenshot at all, use "unknown".
''';

  /// Verify [screenshotJpg] paid [expectedRupees] to [ourUpiId] / [ourName]
  /// (payee match is soft — many apps hide the receiver VPA). ±₹1 tolerance.
  Future<PaymentCheck> verify({
    required Uint8List screenshotJpg,
    required double expectedRupees,
    String? ourUpiId,
    String? ourName,
  }) async {
    try {
      final res = await _m.generateContent([
        Content.multi([
          TextPart(_prompt),
          InlineDataPart('image/jpeg', screenshotJpg),
        ]),
      ]);
      final map = jsonDecode(_extractJson((res.text ?? '').trim()))
          as Map<String, dynamic>;

      final status = '${map['status'] ?? 'unknown'}'.toLowerCase();
      final amount = map['amount'] is num
          ? (map['amount'] as num).toDouble()
          : double.tryParse('${map['amount']}');
      final utr = '${map['utr'] ?? ''}'.trim();
      final payeeName = '${map['payeeName'] ?? ''}'.trim();
      final payeeUpi = '${map['payeeUpiId'] ?? ''}'.trim();
      final payee = payeeUpi.isNotEmpty ? payeeUpi : payeeName;
      String? nn(String s) => s.isEmpty ? null : s;

      if (status != 'success') {
        return PaymentCheck(
          verified: false,
          reason: status == 'failed'
              ? 'That screenshot shows the payment FAILED. Please pay again and re-attach.'
              : 'Couldn\'t read a successful payment. Please attach a clear "payment successful" screenshot.',
          amountRead: amount,
          utr: nn(utr),
          payee: nn(payee),
        );
      }
      if (amount == null) {
        return PaymentCheck(
          verified: false,
          reason: 'Couldn\'t read the amount. Please attach a clearer screenshot.',
          utr: nn(utr),
          payee: nn(payee),
        );
      }
      if ((amount - expectedRupees).abs() > 1.0) {
        return PaymentCheck(
          verified: false,
          reason:
              'The screenshot shows ₹${amount.toStringAsFixed(0)} but your order is ₹${expectedRupees.toStringAsFixed(0)}. Please pay the exact amount.',
          amountRead: amount,
          utr: nn(utr),
          payee: nn(payee),
        );
      }
      final match = _payeeMatches(payeeUpi, payeeName, ourUpiId, ourName);
      if (match.known && !match.ok) {
        return PaymentCheck(
          verified: false,
          reason:
              'This payment went to a different account. Please scan the QR shown here and pay again.',
          amountRead: amount,
          utr: nn(utr),
          payee: nn(payee),
        );
      }
      return PaymentCheck(
        verified: true,
        reason: 'Payment of ₹${amount.toStringAsFixed(0)} confirmed. ✅',
        amountRead: amount,
        utr: nn(utr),
        payee: nn(payee),
      );
    } catch (e) {
      debugPrint('[PaymentVerifier] verify failed: $e');
      return const PaymentCheck(
        verified: false,
        reason:
            'Couldn\'t verify the payment right now. Check your internet and try again.',
      );
    }
  }

  /// Soft payee check: returns (ok) only meaningful when (known) — i.e. we both
  /// know our own id/name AND read one off the screenshot.
  ({bool ok, bool known}) _payeeMatches(
      String vpa, String name, String? ourUpi, String? ourName) {
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9@._]'), '');
    final v = n(vpa), nm = n(name);
    final ou = ourUpi == null ? '' : n(ourUpi);
    final on = ourName == null ? '' : n(ourName);
    if ((ou.isEmpty && on.isEmpty) || (v.isEmpty && nm.isEmpty)) {
      return (ok: true, known: false); // nothing to compare
    }
    if (ou.isNotEmpty && v.isNotEmpty && (v == ou || v.contains(ou) || ou.contains(v))) {
      return (ok: true, known: true);
    }
    if (on.isNotEmpty && nm.isNotEmpty && (nm.contains(on) || on.contains(nm))) {
      return (ok: true, known: true);
    }
    return (ok: false, known: true);
  }

  String _extractJson(String s) {
    final i = s.indexOf('{');
    final j = s.lastIndexOf('}');
    return (i >= 0 && j > i) ? s.substring(i, j + 1) : s;
  }
}
