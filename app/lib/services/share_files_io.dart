import 'dart:io';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Native (iOS/Android): write each blob to a temp file under its exact name so
/// the share sheet shows the real filename, then open the system share sheet.
Future<void> shareNamedFiles(
  List<String> names,
  List<Uint8List> bytes, {
  String? subject,
}) async {
  final dir = await Directory.systemTemp.createTemp('pp_share_');
  final files = <XFile>[];
  for (var i = 0; i < names.length; i++) {
    final path = '${dir.path}/${names[i]}';
    await File(path).writeAsBytes(bytes[i], flush: true);
    files.add(XFile(path, mimeType: _mimeFor(names[i]), name: names[i]));
  }
  await SharePlus.instance.share(ShareParams(files: files, subject: subject));
}

String _mimeFor(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.pdf')) return 'application/pdf';
  return 'application/octet-stream';
}
