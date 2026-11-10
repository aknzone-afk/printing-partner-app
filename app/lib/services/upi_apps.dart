import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'upi_qr.dart';

/// A UPI app the customer can pay from on THIS phone (no second phone / no QR
/// scan). Tapping a button deep-links into the app with the payee + amount
/// pre-filled, exactly like the QR but one tap.
///
/// iOS registers each app by a custom URL scheme; Android apps that register
/// their own scheme open directly too, and anything else falls back to the
/// generic `upi://pay` which brings up the system UPI-app chooser. Every scheme
/// used here is also listed in ios/Runner/Info.plist LSApplicationQueriesSchemes
/// so canLaunchUrl can see whether the app is installed.
class UpiApp {
  const UpiApp(this.label, this.scheme, this.color);

  /// Shown on the button.
  final String label;

  /// The app's deep-link prefix, e.g. `phonepe://pay`, `tez://upi/pay`.
  final String scheme;

  /// Brand-ish accent for the button.
  final Color color;

  /// The real payment link for [rupees] in THIS app's scheme.
  Uri _uri(num rupees) {
    final amount = rupees.toStringAsFixed(2);
    final q = 'pa=${UpiQr.merchantUpiId}'
        '&pn=${Uri.encodeComponent(UpiQr.merchantName)}'
        '&am=$amount&cu=INR'
        '&tn=${Uri.encodeComponent('Printing Partner order')}';
    return Uri.parse('$scheme?$q');
  }
}

/// The apps shown as buttons, in order. "Other UPI app" uses the generic
/// `upi://pay` intent (on Android that opens the chooser).
const upiApps = <UpiApp>[
  UpiApp('PhonePe', 'phonepe://pay', Color(0xFF5F259F)),
  UpiApp('Google Pay', 'tez://upi/pay', Color(0xFF1A73E8)),
  UpiApp('Paytm', 'paytmmp://pay', Color(0xFF00BAF2)),
  UpiApp('BHIM / other', 'upi://pay', Color(0xFF00836C)),
];

/// Outcome of trying to open a UPI app.
enum UpiLaunch { opened, notInstalled, failed }

/// Try to open [app] for [rupees]. Falls back to the generic `upi://pay`
/// chooser when the specific app's scheme is not available, and reports
/// notInstalled so the UI can tell the customer to scan the QR instead.
Future<UpiLaunch> launchUpiApp(UpiApp app, num rupees) async {
  final uri = app._uri(rupees);
  try {
    if (await canLaunchUrl(uri)) {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return ok ? UpiLaunch.opened : UpiLaunch.failed;
    }
    // Specific app not detected — try the generic UPI intent (Android chooser).
    if (app.scheme != 'upi://pay') {
      final generic = Uri.parse(app._uri(rupees).toString()
          .replaceFirst(app.scheme, 'upi://pay'));
      if (await canLaunchUrl(generic)) {
        final ok =
            await launchUrl(generic, mode: LaunchMode.externalApplication);
        return ok ? UpiLaunch.opened : UpiLaunch.failed;
      }
    }
    return UpiLaunch.notInstalled;
  } catch (_) {
    return UpiLaunch.failed;
  }
}
