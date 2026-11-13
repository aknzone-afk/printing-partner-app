import 'remote_config.dart';

/// The shop's public contact, shown to customers wherever the app says
/// "contact the shop". The backend can push the real number at runtime (via
/// GET /health → [RemoteConfig]); until it does, this stays EMPTY — we never
/// ship a placeholder or fake number. Every caller must render [note] (or
/// [whatsapp]) ONLY when it is non-empty.
class ShopContact {
  const ShopContact._();

  /// Compiled-in fallback WhatsApp / phone number. Left empty on purpose so
  /// nothing fake ever ships; the live value comes from [RemoteConfig].
  static const String _fallback = '';

  /// The shop's WhatsApp / phone number, e.g. "+91 98765 43210". Prefers the
  /// live value the backend sent; empty until a real number exists.
  static String get whatsapp => RemoteConfig.whatsapp ?? _fallback;

  /// A ready-to-show line, empty when no number is set.
  static String get note =>
      whatsapp.isEmpty ? '' : 'WhatsApp/call $whatsapp';
}
