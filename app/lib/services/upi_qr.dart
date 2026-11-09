/// Printing Partner's own UPI QR, with the order AMOUNT written into it, so the
/// customer only scans and pays — ₹0, no payment gateway (same approach as the
/// B.B Synthetics app). A pay *link* to a merchant UPI id is refused by
/// PhonePe/GPay; a scanned QR is not.
///
/// [_base] is the shop's printed BharatQR / Vyapar QR with its CRC (tag 63)
/// REMOVED. Owner 9-Nov-2026: a SEPARATE Printing Partner account — paste that
/// QR's decoded string here (minus the trailing `6304XXXX`). Until then
/// [configured] is false and the payment screen shows a "setup pending" note
/// instead of a broken QR, so money can never be misrouted.
class UpiQr {
  // TODO(owner QR): paste Printing Partner's decoded UPI QR string here with the
  // final CRC tag (63) stripped. Leave empty until then.
  static const _base = '';

  /// Human-readable payee, shown under the QR and used (softly) to match the
  /// payment screenshot's receiver. Fill from the QR's tag 59 when set.
  static const merchantName = 'Printing Partner';

  /// Payee VPA (UPI id), used to softly match the screenshot's receiver.
  /// Fill from the QR's VPA tag when set (e.g. 'name@bank').
  static const merchantUpiId = '';

  /// True once the real shop QR has been pasted into [_base].
  static bool get configured => _base.isNotEmpty;

  /// EMV payload with tag 54 = [rupees] and a "dynamic" point of initiation
  /// (tag 01 = 12), followed by a freshly computed CRC.
  static String withAmount(num rupees) {
    if (!configured) {
      throw StateError('UpiQr not configured: paste the Printing Partner QR.');
    }
    final tags = <MapEntry<String, String>>[];
    var i = 0;
    while (i + 4 <= _base.length) {
      final id = _base.substring(i, i + 2);
      final n = int.parse(_base.substring(i + 2, i + 4));
      tags.add(MapEntry(id, _base.substring(i + 4, i + 4 + n)));
      i += 4 + n;
    }
    final amount = rupees.toStringAsFixed(2);
    final out = <MapEntry<String, String>>[];
    for (final t in tags) {
      if (t.key == '54') continue; // drop any existing amount
      out.add(t.key == '01' ? const MapEntry('01', '12') : t);
      if (t.key == '53') out.add(MapEntry('54', amount)); // amount after currency
    }
    final b = StringBuffer();
    for (final t in out) {
      b
        ..write(t.key)
        ..write(t.value.length.toString().padLeft(2, '0'))
        ..write(t.value);
    }
    b.write('6304');
    return '$b${_crc(b.toString())}';
  }

  /// CRC-16/CCITT-FALSE, as the EMV QR spec requires.
  static String _crc(String s) {
    var c = 0xFFFF;
    for (final ch in s.codeUnits) {
      c ^= ch << 8;
      for (var k = 0; k < 8; k++) {
        c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
      }
    }
    return c.toRadixString(16).toUpperCase().padLeft(4, '0');
  }
}
