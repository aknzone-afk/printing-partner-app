import 'dart:typed_data';

import 'photo_bytes_io.dart' if (dart.library.html) 'photo_bytes_web.dart'
    as platform;

/// True only under `flutter test` (native codec unreachable from a `compute`
/// isolate there); always false in the real app and on web.
bool get isFlutterTest => platform.isFlutterTest;

/// Reads a local image file from the device filesystem (native only).
/// Returns null on web or on read failure.
Future<Uint8List?> readLocalBytes(String path) => platform.readLocalBytes(path);

/// Transcodes arbitrary image bytes (including iOS HEIC/HEIF) to JPEG using
/// the platform's native codec. Returns null on web or on failure.
Future<Uint8List?> transcodeToJpeg(Uint8List bytes) =>
    platform.transcodeToJpeg(bytes);

/// Resizes to [maxDim] longest-side and JPEG-encodes at [quality] using the
/// platform's native codec on a background thread (keeps the UI responsive).
/// Returns null on web or on failure → caller falls back to the Dart path.
Future<Uint8List?> compressForPrintNative(
        Uint8List bytes, int maxDim, int quality) =>
    platform.compressForPrintNative(bytes, maxDim, quality);

/// Flattens a transparent image onto WHITE, resizes to [maxDim], and encodes
/// JPEG at [quality] with 4:4:4 chroma, off the UI isolate. For PNG/WebP/GIF
/// stickers & graphics so transparency doesn't turn black. Returns null on web.
Future<Uint8List?> flattenResizeEncode(
        Uint8List bytes, int maxDim, int quality) =>
    platform.flattenResizeEncode(bytes, maxDim, quality);

/// Compresses an image straight from a FILE PATH with the native codec — the
/// raw photo never enters Dart memory (low-memory path for gallery photos).
/// Returns null on web or failure → caller falls back to byte-based paths.
Future<Uint8List?> compressFileForPrintNative(
        String path, int maxDim, int quality) =>
    platform.compressFileForPrintNative(path, maxDim, quality);

/// Reads the first [n] bytes of a file for format sniffing (null on web).
Future<Uint8List?> readFileHeader(String path, int n) =>
    platform.readFileHeader(path, n);

/// Encodes raw RGBA pixels (a rasterised print-sheet PDF page) to JPEG at
/// [quality], off the UI isolate on native. Turns 12×18 sheet pages into
/// print-ready JPGs.
Future<Uint8List> encodeRgbaJpg(
        int width, int height, Uint8List rgba, int quality) =>
    platform.encodeRgbaJpg(width, height, rgba, quality);
