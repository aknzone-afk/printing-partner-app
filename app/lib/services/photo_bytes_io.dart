import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

/// Reads a local image file from the device filesystem.
///
/// The native image pickers (image_picker / wechat_assets_picker) return a
/// real filesystem path on iOS and Android — e.g.
/// `/var/mobile/Containers/Data/Application/<uuid>/tmp/.../IMG.jpg`. Returns
/// null if the file can't be read, so the caller renders a placeholder rather
/// than crashing the PDF build.
Future<Uint8List?> readLocalBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } catch (e) {
    debugPrint('[photo_bytes] readLocalBytes failed for $path: $e');
    return null;
  }
}

/// Transcodes arbitrary image bytes to JPEG using the platform's native image
/// codec. This is the escape hatch for formats the pure-Dart `image` package
/// cannot decode — most importantly HEIC/HEIF, the default iPhone capture
/// format. Returns null if the platform can't decode the input.
Future<Uint8List?> transcodeToJpeg(Uint8List bytes) async {
  try {
    final out = await FlutterImageCompress.compressWithList(
      bytes,
      format: CompressFormat.jpeg,
      quality: 90,
      minWidth: 2000,
      minHeight: 2000,
    );
    if (out.isEmpty) return null;
    return Uint8List.fromList(out);
  } catch (e) {
    debugPrint('[photo_bytes] transcodeToJpeg failed: $e');
    return null;
  }
}

/// Resizes [bytes] so its longest side is at most [maxDim] and re-encodes as
/// JPEG at [quality], using the platform's NATIVE codec on a background
/// thread. This keeps the UI responsive — the pure-Dart `image` package's
/// cubic resize froze the app on full-resolution photos — and reads HEIC/HEIF
/// directly. Never upscales. Returns null if the platform can't process it.
Future<Uint8List?> compressForPrintNative(
    Uint8List bytes, int maxDim, int quality) async {
  try {
    final out = await FlutterImageCompress.compressWithList(
      bytes,
      minWidth: maxDim,
      minHeight: maxDim,
      quality: quality,
      format: CompressFormat.jpeg,
    );
    return out.isEmpty ? null : Uint8List.fromList(out);
  } catch (e) {
    debugPrint('[photo_bytes] compressForPrintNative failed: $e');
    return null;
  }
}

/// Flattens a (possibly transparent) image onto a WHITE background, resizes it
/// to [maxDim] (longest side, never upscaling) and JPEG-encodes it at [quality]
/// with 4:4:4 chroma (sharp text/edges). Runs the pure-Dart `image` work on a
/// BACKGROUND ISOLATE so it never freezes the UI.
///
/// This is the path for stickers / logos / quote cards (PNG/WebP/GIF). Without
/// the white flatten, transparent areas become BLACK in JPEG and dark text on
/// them turns unreadable. Returns null on failure (caller falls back).
Future<Uint8List?> flattenResizeEncode(
    Uint8List bytes, int maxDim, int quality) async {
  try {
    return await Isolate.run(() {
      var decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      // Grey + alpha (PNG colour type 4): compositeImage does not blend a
      // 2-channel image — transparent pixels came out BLACK. Expand to RGBA.
      if (decoded.numChannels == 2) {
        decoded = decoded.convert(numChannels: 4);
      }

      img.Image flat = decoded;
      if (decoded.hasAlpha) {
        final bg = img.Image(
            width: decoded.width, height: decoded.height, numChannels: 3);
        img.fill(bg, color: img.ColorRgb8(255, 255, 255));
        img.compositeImage(bg, decoded); // draw image over white
        flat = bg;
      }

      img.Image resized = flat;
      if (flat.width > maxDim || flat.height > maxDim) {
        resized = flat.width >= flat.height
            ? img.copyResize(flat,
                width: maxDim, interpolation: img.Interpolation.cubic)
            : img.copyResize(flat,
                height: maxDim, interpolation: img.Interpolation.cubic);
      }
      return Uint8List.fromList(
          img.encodeJpg(resized, quality: quality, chroma: img.JpegChroma.yuv444));
    });
  } catch (e) {
    debugPrint('[photo_bytes] flattenResizeEncode failed: $e');
    return null;
  }
}

/// Compresses an image STRAIGHT FROM A FILE PATH with the native codec —
/// the raw photo never enters Dart memory. This is the low-memory path for
/// gallery photos: holding 15–20 full-resolution iPhone photos as Dart byte
/// lists (plus native decode spikes) tripped iOS's memory watchdog and the
/// app was killed mid-order. Returns null on failure (caller falls back).
Future<Uint8List?> compressFileForPrintNative(
    String path, int maxDim, int quality) async {
  try {
    final out = await FlutterImageCompress.compressWithFile(
      path,
      minWidth: maxDim,
      minHeight: maxDim,
      quality: quality,
      format: CompressFormat.jpeg,
    );
    if (out == null || out.isEmpty) return null;
    return out;
  } catch (e) {
    debugPrint('[photo_bytes] compressFileForPrintNative failed for $path: $e');
    return null;
  }
}

/// Reads just the first [n] bytes of a file — enough to sniff the image format
/// without loading a multi-megabyte photo into memory.
Future<Uint8List?> readFileHeader(String path, int n) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    return Uint8List.fromList(await f.read(n));
  } catch (_) {
    return null;
  } finally {
    await f?.close();
  }
}

/// Encodes raw RGBA pixels (a rasterised PDF page from `Printing.raster`) to
/// JPEG at [quality], on a BACKGROUND ISOLATE. A 12×18 print sheet at 300 DPI
/// is 3600×5400 px, so encoding on the UI isolate would freeze the app; this
/// keeps it responsive.
Future<Uint8List> encodeRgbaJpg(
    int width, int height, Uint8List rgba, int quality) async {
  // MOVE (not copy) the ~78 MB RGBA buffer into the background isolate.
  // `Isolate.run` captures `rgba` BY COPY, which doubled the buffer for a
  // 300-DPI 12×18 sheet (3600×5400 px = ~78 MB each). That spike tripped
  // iOS's memory watchdog and the app was killed the instant the customer
  // tapped "Pay" (crash in the "Preparing print sheets…" stage).
  // TransferableTypedData hands the bytes to the isolate with ZERO copy, so
  // only one ~78 MB buffer ever exists.
  final transfer = TransferableTypedData.fromList([rgba]);
  return Isolate.run(() {
    final moved = transfer.materialize().asUint8List();
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: moved.buffer,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  });
}
