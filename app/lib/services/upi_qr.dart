/// Printing Partner's UPI QR. The customer scans it with any UPI app and the
/// amount is pre-filled — ₹0, no payment gateway. A *scanned* UPI QR to a
/// personal VPA works even where a tapped `upi://` link would be blocked.
///
/// Owner 9-Nov-2026: pay to the Paytm account below (Priyasha Akshay Nahata,
/// Punjab National Bank).
class UpiQr {
  /// Payee VPA (UPI id) and name — used to build the QR and to softly match
  /// the payment screenshot's receiver in PaymentVerifier.
  static const merchantUpiId = '8094804784@ptyes';
  static const merchantName = 'Priyasha Akshay Nahata';

  static bool get configured => merchantUpiId.isNotEmpty;

  /// A standard UPI intent string with the amount filled in, e.g.
  /// `upi://pay?pa=8094804784@ptyes&pn=Priyasha%20Akshay%20Nahata&am=1499.00&cu=INR`.
  /// Rendered as a QR by the checkout screen; the customer scans it to pay.
  static String withAmount(num rupees) {
    final amount = rupees.toStringAsFixed(2);
    final pn = Uri.encodeComponent(merchantName);
    final tn = Uri.encodeComponent('Printing Partner order');
    return 'upi://pay?pa=$merchantUpiId&pn=$pn&am=$amount&cu=INR&tn=$tn';
  }
}
