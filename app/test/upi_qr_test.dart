// The UPI QR payload (lib/services/upi_qr.dart). A wrong payee or amount
// here sends the customer's money to the wrong place, so every part of the
// URI is pinned.
import 'package:flutter_test/flutter_test.dart';

import 'package:printing_partner/models/print_packages.dart';
import 'package:printing_partner/services/upi_qr.dart';

void main() {
  test('payee is the shop\'s account', () {
    expect(UpiQr.merchantUpiId, '8094804784@ptyes');
    expect(UpiQr.merchantName, 'Priyasha Akshay Nahata');
    expect(UpiQr.configured, isTrue);
  });

  test('exact URI for Rs 150', () {
    expect(
      UpiQr.withAmount(150),
      'upi://pay?pa=8094804784@ptyes&pn=Priyasha%20Akshay%20Nahata'
      '&am=150.00&cu=INR&tn=Printing%20Partner%20order',
    );
  });

  test('parses back with Uri.parse: scheme, host and every parameter', () {
    final raw = UpiQr.withAmount(301);
    final uri = Uri.parse(raw);
    expect(uri.scheme, 'upi');
    expect(uri.host, 'pay');
    expect(uri.queryParameters, {
      'pa': '8094804784@ptyes',
      'pn': 'Priyasha Akshay Nahata',
      'am': '301.00',
      'cu': 'INR',
      'tn': 'Printing Partner order',
    });
    // Each key appears exactly once (a duplicated pa/am is ambiguous).
    for (final k in ['pa', 'pn', 'am', 'cu', 'tn']) {
      expect(uri.queryParametersAll[k], hasLength(1), reason: k);
    }
  });

  test('pn / tn are percent-encoded: no raw spaces, "+", or stray separators',
      () {
    final raw = UpiQr.withAmount(175);
    expect(raw, isNot(contains(' ')));
    expect(raw, isNot(contains('+')),
        reason: 'UPI apps show "+" literally; spaces must be %20');
    expect('?'.allMatches(raw).length, 1);
    expect('&'.allMatches(raw).length, 4);
    expect('='.allMatches(raw).length, 5);
    expect(raw, contains('pn=${Uri.encodeComponent(UpiQr.merchantName)}'));
    expect(raw, contains('pa=8094804784@ptyes&'),
        reason: 'the VPA is sent as-is ("@" is not escaped)');
  });

  test('am always has exactly 2 decimals, no grouping, no exponent', () {
    final cases = <num, String>{
      150: '150.00',
      175.0: '175.00',
      301: '301.00',
      199.5: '199.50',
      149.999: '150.00',
      1499: '1499.00',
      0.1: '0.10',
      100000: '100000.00',
    };
    cases.forEach((rupees, want) {
      final am = Uri.parse(UpiQr.withAmount(rupees)).queryParameters['am'];
      expect(am, want, reason: 'rupees $rupees');
      expect(RegExp(r'^\d+\.\d{2}$').hasMatch(am!), isTrue);
    });
  });

  test('every pack price (as checkout passes it: paise / 100.0) is an exact '
      '2-decimal amount', () {
    for (final p in allPacks) {
      final am = Uri.parse(UpiQr.withAmount(p.priceInPaise / 100.0))
          .queryParameters['am']!;
      expect((double.parse(am) * 100).round(), p.priceInPaise,
          reason: '${p.size.label} x${p.snapCount}');
      expect(am, '${p.priceInPaise ~/ 100}.'
          '${(p.priceInPaise % 100).toString().padLeft(2, '0')}');
    }
  });
}
