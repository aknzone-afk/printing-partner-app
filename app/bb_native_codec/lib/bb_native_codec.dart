import 'package:flutter/services.dart';

/// Thin async wrappers over Android's native image codec (Skia /
/// libjpeg-turbo — the same engine the camera and gallery use). 20-40x
/// faster than the pure-Dart `image` package on big images.
///
/// EVERY method returns null on ANY failure (desktop, channel missing,
/// corrupt input) — callers must keep the pure-Dart path as fallback.
class BbNativeCodec {
  static const MethodChannel _ch = MethodChannel('bb_native_codec');

  /// Raw RGBA -> JPEG at [quality].
  static Future<Uint8List?> encodeRgbaJpeg({
    required int width,
    required int height,
    required Uint8List rgba,
    required int quality,
  }) async {
    try {
      return await _ch.invokeMethod<Uint8List>('encodeRgba', {
        'width': width,
        'height': height,
        'rgba': rgba,
        'quality': quality,
      });
    } catch (e) {
      // ignore: avoid_print
      print('BBCODEC encodeRgba error: $e');
      return null;
    }
  }

  /// Encoded image (JPEG/PNG/...) -> raw RGBA + dimensions.
  static Future<({int width, int height, Uint8List rgba})?> decodeRgba(
      Uint8List src) async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('decodeRgba', {
        'src': src,
      });
      if (m == null) return null;
      return (
        width: (m['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
        rgba: m['rgba'] as Uint8List,
      );
    } catch (e) {
      // ignore: avoid_print
      print('BBCODEC decodeRgba error: $e');
      return null;
    }
  }

  /// File-based twin of [encodeRgbaJpeg] for huge buffers (the 106 MB
  /// sheet canvas): raw RGBA is read from [rgbaPath], the JPEG lands at
  /// [outPath]. Keeps the giant pixels out of the Java heap entirely.
  /// Returns the JPEG byte size, or null on failure.
  static Future<int?> encodeRgbaJpegFile({
    required int width,
    required int height,
    required String rgbaPath,
    required String outPath,
    required int quality,
  }) async {
    try {
      return await _ch.invokeMethod<int>('encodeRgbaFile', {
        'width': width,
        'height': height,
        'rgbaPath': rgbaPath,
        'outPath': outPath,
        'quality': quality,
      });
    } catch (e) {
      // ignore: avoid_print
      print('BBCODEC encodeRgbaFile error: $e');
      return null;
    }
  }

  /// File-based twin of [decodeRgba]: decodes the image at [srcPath] and
  /// writes raw RGBA to [outPath]. With fitW/fitH > 0 the pixels are also
  /// natively scaled (up or down, aspect kept) to fit that box. Returns
  /// the final dimensions, or null on failure.
  static Future<({int width, int height})?> decodeRgbaToFile({
    required String srcPath,
    required String outPath,
    int fitW = 0,
    int fitH = 0,
  }) async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('decodeRgbaFile', {
        'srcPath': srcPath,
        'outPath': outPath,
        'fitW': fitW,
        'fitH': fitH,
      });
      if (m == null) return null;
      return (
        width: (m['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
      );
    } catch (e) {
      // ignore: avoid_print
      print('BBCODEC decodeRgbaFile error: $e');
      return null;
    }
  }

  /// Encoded image -> JPEG downscaled (if needed) to fit within
  /// [maxW] x [maxH], aspect preserved. Never upscales.
  static Future<Uint8List?> transcodeFitJpeg({
    required Uint8List src,
    required int maxW,
    required int maxH,
    required int quality,
  }) async {
    try {
      return await _ch.invokeMethod<Uint8List>('transcodeFit', {
        'src': src,
        'maxW': maxW,
        'maxH': maxH,
        'quality': quality,
      });
    } catch (e) {
      // ignore: avoid_print
      print('BBCODEC transcodeFit error: $e');
      return null;
    }
  }
}
