import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Web: share in-memory blobs directly (falls back to browser downloads).
Future<void> shareNamedFiles(
  List<String> names,
  List<Uint8List> bytes, {
  String? subject,
}) async {
  final files = <XFile>[
    for (var i = 0; i < names.length; i++)
      XFile.fromData(bytes[i], mimeType: _mimeFor(names[i]), name: names[i]),
  ];
  await SharePlus.instance.share(
    ShareParams(files: files, fileNameOverrides: names, subject: subject),
  );
}

String _mimeFor(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.pdf')) return 'application/pdf';
  return 'application/octet-stream';
}
