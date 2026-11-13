/// Values the backend can push to the app at runtime (via GET /health), so the
/// owner can rotate them WITHOUT shipping a new build / waiting for store
/// review: the UPI payee and the shop's WhatsApp number.
///
/// Everything here is best-effort and optional — until the backend sends a
/// field (or if it never does), callers fall back to the compiled-in default,
/// so the app behaves exactly as before. [BackendApi.health] calls
/// [applyFromHealth] with the decoded /health body on every health check.
class RemoteConfig {
  RemoteConfig._();

  static String? _upiId;
  static String? _upiName;
  static String? _whatsapp;

  /// Pull the optional config fields out of a decoded /health body. Accepts a
  /// few key spellings so the backend side is free to use snake_case. A blank
  /// or missing value never clears a previously-good one.
  static void applyFromHealth(Map<String, dynamic> body) {
    final upi = _str(body['upi_id']) ?? _str(body['upiId']);
    final name = _str(body['upi_name']) ?? _str(body['merchant_name']);
    final wa = _str(body['whatsapp']) ?? _str(body['shop_whatsapp']);
    if (upi != null) _upiId = upi;
    if (name != null) _upiName = name;
    if (wa != null) _whatsapp = wa;
  }

  /// Live UPI payee VPA, or null if the backend hasn't sent one.
  static String? get upiId => _upiId;

  /// Live UPI payee display name, or null.
  static String? get upiName => _upiName;

  /// Live shop WhatsApp number, or null.
  static String? get whatsapp => _whatsapp;

  static String? _str(Object? v) {
    if (v is String) {
      final t = v.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }
}
