import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Web stub. On web, photos are blob:/http URLs fetched over the network, so
/// there is never a local filesystem path to read.
Future<Uint8List?> readLocalBytes(String path) async => null;

/// Web stub. Browsers decode their own image formats and the web build never
/// receives HEIC, so no native transcode is needed.
Future<Uint8List?> transcodeToJpeg(Uint8List bytes) async => null;

/// Web stub. The web build uses the pure-Dart resize path (web images are
/// small blob/network URLs and there's no native codec to call here).
Future<Uint8List?> compressForPrintNative(
        Uint8List bytes, int maxDim, int quality) async =>
    null;

/// Web stub — returns null so the caller uses its pure-Dart fallback. (The
/// transparent-sticker case is an iOS/Android concern; the web flow uses
/// blob/network images.)
Future<Uint8List?> flattenResizeEncode(
        Uint8List bytes, int maxDim, int quality) async =>
    null;

/// Web stub — no filesystem on web.
Future<Uint8List?> compressFileForPrintNative(
        String path, int maxDim, int quality) async =>
    null;

/// Web stub — no filesystem on web.
Future<Uint8List?> readFileHeader(String path, int n) async => null;

/// Web: encode raw RGBA pixels to JPEG inline (no background isolate on web).
Future<Uint8List> encodeRgbaJpg(
    int width, int height, Uint8List rgba, int quality) async {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}
