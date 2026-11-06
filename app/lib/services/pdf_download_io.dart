import 'dart:typed_data';

import 'package:printing/printing.dart';

/// Native (Android / iOS / desktop) PDF export. Opens the system share sheet
/// so the user can save to Files, AirDrop, email, or send to a printer.
Future<void> downloadPdf(Uint8List bytes, String filename) async {
  await Printing.sharePdf(bytes: bytes, filename: filename);
}
