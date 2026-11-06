import 'dart:typed_data';

import 'share_files_io.dart' if (dart.library.html) 'share_files_web.dart'
    as platform;

/// Opens the native share sheet (Save to Files, AirDrop, print, mail…) with the
/// given [bytes] presented under [names] — parallel lists, one name per blob.
/// Names are preserved exactly, e.g. `PP-000123 (1 of 3).jpg`.
Future<void> shareNamedFiles(
  List<String> names,
  List<Uint8List> bytes, {
  String? subject,
}) =>
    platform.shareNamedFiles(names, bytes, subject: subject);
