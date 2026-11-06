import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'onedrive_auth.dart';

/// Uploads files into the merchant's OneDrive via Microsoft Graph.
/// Small files use the simple PUT; >4 MB uses an upload session (chunked,
/// multiples of 320 KiB as Graph requires). Folders are created implicitly.
class OneDriveClient {
  OneDriveClient._();
  static final OneDriveClient instance = OneDriveClient._();

  static const _graph = 'https://graph.microsoft.com/v1.0';
  static const _simpleMax = 4 * 1024 * 1024 - 1;
  static const _chunk = 327680 * 16; // 5 MiB, multiple of 320 KiB

  String _encodePath(String drivePath) =>
      drivePath.split('/').map(Uri.encodeComponent).join('/');

  /// Uploads [bytes] to [drivePath] (relative to the drive root, e.g.
  /// "PrintingPartner/Orders of 10-6-2026/Photo/1 (1 of 2).jpg").
  /// Overwrites if the file already exists (safe re-delivery).
  Future<void> upload(String drivePath, Uint8List bytes,
      {String contentType = 'image/jpeg'}) async {
    final token = await OneDriveAuth.instance.accessToken();
    final encoded = _encodePath(drivePath);

    if (bytes.length <= _simpleMax) {
      final res = await http.put(
        Uri.parse(
            '$_graph/me/drive/root:/$encoded:/content?@microsoft.graph.conflictBehavior=replace'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': contentType,
        },
        body: bytes,
      );
      if (res.statusCode >= 300) {
        throw StateError(
            'OneDrive upload failed (${res.statusCode}) for $drivePath: ${res.body}');
      }
      return;
    }

    // Large file: upload session.
    final sess = await http.post(
      Uri.parse('$_graph/me/drive/root:/$encoded:/createUploadSession'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'item': {'@microsoft.graph.conflictBehavior': 'replace'}
      }),
    );
    if (sess.statusCode >= 300) {
      throw StateError(
          'OneDrive session failed (${sess.statusCode}) for $drivePath: ${sess.body}');
    }
    final uploadUrl =
        (jsonDecode(sess.body) as Map<String, dynamic>)['uploadUrl'] as String;

    for (var start = 0; start < bytes.length; start += _chunk) {
      final end = (start + _chunk > bytes.length) ? bytes.length : start + _chunk;
      final res = await http.put(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Range': 'bytes $start-${end - 1}/${bytes.length}',
        },
        body: bytes.sublist(start, end),
      );
      if (res.statusCode >= 300 && res.statusCode != 202) {
        throw StateError(
            'OneDrive chunk failed (${res.statusCode}) at $start for $drivePath: ${res.body}');
      }
    }
  }
}
