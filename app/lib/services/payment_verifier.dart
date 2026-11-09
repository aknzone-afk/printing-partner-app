import 'package:flutter/foundation.dart';

import 'backend_api.dart';

/// Result of a UPI payment-screenshot check. The SERVER decides; this is the
/// app-side view of its answer.
class PaymentCheck {
  final bool verified;
  final String reason; // customer-facing message
  final double? amountRead; // rupees the server read from the screenshot
  final String? utr; // UTR / UPI reference / transaction id
  final String? payee; // receiver name or VPA read
  /// One-shot payment token issued by the server; present ONLY when
  /// [verified] is true. Pass it to the order ingest call.
  final String? token;

  const PaymentCheck({
    required this.verified,
    required this.reason,
    this.amountRead,
    this.utr,
    this.payee,
    this.token,
  });
}

/// Sends the UPI payment screenshot to our backend (`/verify-payment`), which
/// reads it with Gemini and checks it paid the expected amount to our account.
/// No AI key ships in the app and the app never decides "paid" on its own.
class PaymentVerifier {
  PaymentVerifier._();
  static final PaymentVerifier instance = PaymentVerifier._();

  /// Verify [screenshotJpg] paid [expectedRupees] to [ourUpiId] / [ourName].
  /// Never throws. [ourName] is kept for signature compatibility; the server
  /// matches on the UPI id.
  Future<PaymentCheck> verify({
    required Uint8List screenshotJpg,
    required double expectedRupees,
    String? ourUpiId,
    String? ourName,
  }) async {
    try {
      final res = await BackendApi.verifyPayment(
        screenshotJpg: screenshotJpg,
        amountRupees: expectedRupees,
        ourUpiId: ourUpiId,
      );

      final status = res['httpStatus'] is int ? res['httpStatus'] as int : 0;
      final verified = status == 200 && res['verified'] == true;
      final reason = _str(res['reason']) ??
          (verified
              ? 'Payment of ₹${expectedRupees.toStringAsFixed(0)} confirmed.'
              : "Couldn't verify the payment right now. Check your internet "
                  'and try again.');

      final amount = res['amount'] is num
          ? (res['amount'] as num).toDouble()
          : double.tryParse('${res['amount'] ?? ''}');
      final token = _str(res['token']);

      // 503 ai_unconfigured (and any other non-200): the server reason is shown
      // verbatim and the payment is NEVER treated as paid.
      if (!verified) {
        if (status == 503) {
          debugPrint('[PaymentVerifier] server ai_unconfigured: $reason');
        }
        return PaymentCheck(
          verified: false,
          reason: reason,
          amountRead: amount,
          utr: _str(res['utr']),
          payee: _str(res['payee']),
        );
      }

      if (token == null) {
        // Defensive: a verified answer without a token can't be filed, so do
        // not let the customer proceed on it.
        debugPrint('[PaymentVerifier] verified but no token in response');
        return PaymentCheck(
          verified: false,
          reason: "Couldn't confirm the payment right now. Please try again.",
          amountRead: amount,
          utr: _str(res['utr']),
          payee: _str(res['payee']),
        );
      }

      return PaymentCheck(
        verified: true,
        reason: reason,
        amountRead: amount,
        utr: _str(res['utr']),
        payee: _str(res['payee']),
        token: token,
      );
    } catch (e) {
      debugPrint('[PaymentVerifier] verify failed: $e');
      return const PaymentCheck(
        verified: false,
        reason:
            "Couldn't verify the payment right now. Check your internet and try again.",
      );
    }
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }
}
