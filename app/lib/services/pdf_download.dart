import 'dart:typed_data';

import 'pdf_download_io.dart' if (dart.library.html) 'pdf_download_web.dart'
    as platform;

/// Cross-platform PDF download. On web triggers a browser download; on
/// native it'll plug into share/save (TODO when we ship).
Future<void> downloadPdf(Uint8List bytes, String filename) =>
    platform.downloadPdf(bytes, filename);
