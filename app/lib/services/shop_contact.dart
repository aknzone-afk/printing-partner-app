/// The shop's public contact, shown to customers wherever the app says
/// "contact the shop". It is intentionally EMPTY until the owner fills in the
/// real number — we never ship a placeholder or fake number. Every caller must
/// render [note] (or [whatsapp]) ONLY when it is non-empty.
class ShopContact {
  const ShopContact._();

  /// The shop's WhatsApp / phone number, e.g. "+91 98765 43210".
  /// Leave empty until the owner provides the real one.
  static const String whatsapp = '';

  /// A ready-to-show line, empty when no number is set. Uses `== ''` (not
  /// `.isEmpty`, which a const expression can't evaluate) so it stays const.
  static const String note = whatsapp == '' ? '' : 'WhatsApp/call $whatsapp';
}
