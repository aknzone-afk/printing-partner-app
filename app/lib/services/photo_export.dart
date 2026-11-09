import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../models/cart.dart';
import '../models/print_packages.dart';
import 'photo_bytes.dart';

/// Renders every cart photo as ONE print-ready JPEG with its crop applied —
/// the per-photo files the backend's `/ingest` files to the shop's disk
/// (`Printing Partner/{date}/{category}/{size}/Order N{A,B,C…}.jpg`). The
/// sheet-PDF / OneDrive path is retired; this replaces it.
///
/// Crop semantics (what the customer saw on the crop screen is what prints):
///  * `rotationSteps`  → the photo is rotated 90° clockwise that many times
///                        (same as the crop screen's RotatedBox).
///  * `crop != null`    → the frame the customer saved, normalised to the
///                        rotated photo ((0,0)-(1,1) = whole photo; parts
///                        outside 0..1 print WHITE). Pan/zoom reproduced.
///  * `skipped == true` → "white-pad": the whole photo is letterboxed onto a
///                        white canvas of the print's image aspect
///                        (BoxFit.contain).
///  * otherwise         → "cropped" without a rect (legacy / "Auto crop"):
///                        centre-cropped to the print's image aspect
///                        (BoxFit.cover).
///  * no CropEdit at all → treated as skipped (see Cart._edits doc).
/// All four cases reduce to ONE crop rect (`_effectiveCrop`) and one code
/// path, so the Dart-image and browser renderers cannot drift apart.
///
/// The target aspect is `pack.size.imageAspectWxH` — the IMAGE area (a square
/// for polaroids); the white polaroid frame is added by the printer, not here.
///
/// Memory: the raw photo is bounded BEFORE it reaches Dart. On iOS/Android the
/// native codec resizes straight from the file (`compressFileForPrintNative`,
/// EXIF applied, HEIC handled); only transparency-capable formats (PNG/WebP/
/// GIF) take the pure-Dart path so they land on white. A 50 MP phone JPEG
/// therefore never becomes a 150 MB bitmap in the worker isolate — the pattern
/// that got earlier builds killed by iOS's memory watchdog. On web the browser
/// codec decodes at a bounded size (`ui.instantiateImageCodec`), the crop is
/// drawn on a `ui.Canvas`, and only the small JPEG encode runs in Dart, so the
/// page is not frozen for seconds per photo (web has no isolates).
///
/// Output: longest side capped at [maxLongSide] px (default: sized for the
/// print at 300 DPI with headroom, see [printLongSideFor]), JPEG quality
/// [jpegQuality], every file re-encoded lower if it would exceed [maxBytes]
/// (the backend's 12 MB per-photo limit must never be reachable by a payload
/// a retry cannot change).
Future<List<Uint8List>> renderCroppedJpegs(
  Cart cart, {
  void Function(int done, int total)? onProgress,
  int? maxLongSide,
  int jpegQuality = 88,
  int maxBytes = 11 * 1024 * 1024,
}) async {
  final pack = cart.selectedPack;
  if (pack == null) {
    throw const PhotoExportException('No print pack selected.');
  }
  final items = cart.items;
  if (items.isEmpty) {
    throw const PhotoExportException('There are no photos to export.');
  }
  final aspect = pack.size.imageAspectWxH;
  final longSide = maxLongSide ?? printLongSideFor(pack.size);
  final out = <Uint8List>[];

  // ONE photo at a time, each already bounded by the native codec, so the
  // worker isolate holds at most one small decode + its crop.
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final edit = cart.cropFor(item.id) ?? const CropEdit.skipped();
    final crop = edit.crop;

    final source = await _sourceBytes(item.localPath, longSide);
    if (source == null || source.isEmpty) {
      throw PhotoExportException(
          'Photo ${i + 1} could not be read from your device.');
    }

    var job = _RenderJob(
      bytes: source,
      aspect: aspect,
      skipped: edit.skipped,
      rotationSteps: edit.rotationSteps,
      crop: crop == null
          ? null
          : <double>[crop.left, crop.top, crop.right, crop.bottom],
      maxLongSide: longSide,
      quality: jpegQuality,
    );
    Uint8List? jpg = await _render(job);

    if (jpg == null) {
      // Neither decoder could read this format — almost always an iPhone
      // HEIC/HEIF that reached the Dart path. Transcode with the platform
      // codec (native only; null on web) and run the crop once more.
      final transcoded =
          await compressForPrintNative(source, longSide, 95) ??
              await transcodeToJpeg(source);
      if (transcoded != null && transcoded.isNotEmpty) {
        job = job.withBytes(transcoded);
        jpg = await _render(job);
      }
    }
    if (jpg == null) {
      throw PhotoExportException(
          'Photo ${i + 1} is in a format we could not read. Please replace it.');
    }

    // Byte cap: step the quality down until the file fits. The server's
    // per-photo 413 must never be reachable with bytes a retry re-sends.
    var result = jpg;
    var q = jpegQuality;
    while (result.length > maxBytes && q > 50) {
      q -= 12;
      final smaller = await _render(job.withQuality(q));
      if (smaller == null) break;
      result = smaller;
    }

    debugPrint('[PhotoExport] ${i + 1}/${items.length}: '
        '${result.length ~/ 1024} KB ('
        '${crop != null ? 'crop ${crop.left.toStringAsFixed(2)},${crop.top.toStringAsFixed(2)}-${crop.right.toStringAsFixed(2)},${crop.bottom.toStringAsFixed(2)}' : edit.skipped ? 'white-pad' : 'centre-cover'}, '
        'rot ${edit.rotationSteps * 90}°, q$q)');
    out.add(result);
    onProgress?.call(i + 1, items.length);
    // Let the progress label paint between photos (matters on web, where the
    // JPEG encode shares the UI thread).
    await Future<void>.delayed(Duration.zero);
  }
  return out;
}

/// Longest-side pixel budget for a photo printed into [size]'s image area:
/// 300 DPI with 1.5× headroom (a customer who zooms in on the crop screen
/// prints a SUB-rectangle of this), clamped to 1800–4000 px. A 3×4 print gets
/// 1800 px (~400–600 KB at q88) instead of 4000 px (3–6 MB), so a 54-snap
/// pack uploads as ~25 MB rather than 150–300 MB.
int printLongSideFor(PrintSize size) {
  final inches = math.max(size.imageWidthInches, size.imageHeightInches);
  return (300 * inches * 1.5).ceil().clamp(1800, 4000);
}

/// Thrown when a photo cannot be rendered; the message is customer-facing.
class PhotoExportException implements Exception {
  const PhotoExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything a renderer needs, in one message so `compute` ships it to the
/// worker isolate in a single copy.
class _RenderJob {
  const _RenderJob({
    required this.bytes,
    required this.aspect,
    required this.skipped,
    required this.rotationSteps,
    required this.crop,
    required this.maxLongSide,
    required this.quality,
  });

  final Uint8List bytes;
  final double aspect; // target image aspect, width / height
  final bool skipped;
  final int rotationSteps; // 90° clockwise turns, 0..3
  final List<double>? crop; // [left, top, right, bottom], normalised
  final int maxLongSide;
  final int quality;

  _RenderJob withBytes(Uint8List b) => _RenderJob(
        bytes: b,
        aspect: aspect,
        skipped: skipped,
        rotationSteps: rotationSteps,
        crop: crop,
        maxLongSide: maxLongSide,
        quality: quality,
      );

  _RenderJob withQuality(int q) => _RenderJob(
        bytes: bytes,
        aspect: aspect,
        skipped: skipped,
        rotationSteps: rotationSteps,
        crop: crop,
        maxLongSide: maxLongSide,
        quality: q,
      );
}

/// Picks the renderer: browser codec + canvas on web (bounded, async, no
/// isolates there), pure-Dart `image` on a background isolate elsewhere.
Future<Uint8List?> _render(_RenderJob job) async {
  if (kIsWeb) {
    final viaBrowser = await _renderOneWeb(job);
    if (viaBrowser != null) return viaBrowser;
  }
  return compute(_renderOne, job, debugLabel: 'photo_export');
}

/// Reads a photo's bytes already bounded for printing:
///  • local JPEG/HEIC → NATIVE codec straight from the file path (resize +
///    EXIF + JPEG; the raw photo never enters Dart memory);
///  • local PNG/WebP/GIF (may carry alpha) → raw bytes, flattened on white by
///    the Dart renderer;
///  • blob:/http(s) URL (web) → network fetch (the browser codec bounds it).
Future<Uint8List?> _sourceBytes(String path, int longSide) async {
  final uri = Uri.tryParse(path);
  final isLocal = uri == null || !uri.hasScheme || uri.scheme == 'file';
  if (!isLocal) {
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (e) {
      debugPrint('[PhotoExport] fetch failed for $path: $e');
      return null;
    }
  }
  final localPath =
      (uri != null && uri.scheme == 'file') ? uri.toFilePath() : path;
  final header = await readFileHeader(localPath, 16);
  if (header == null || !_mayHaveAlpha(header)) {
    final native = await compressFileForPrintNative(localPath, longSide, 95);
    if (native != null && native.isNotEmpty) return native;
  }
  return readLocalBytes(localPath);
}

/// True if [b] starts like a transparency-capable format (PNG/WebP/GIF).
/// Photos (JPEG/HEIC) never carry alpha and return false.
bool _mayHaveAlpha(Uint8List b) {
  if (b.length < 12) return false;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return true; // PNG
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
    return true; // GIF8
  }
  if (b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true; // RIFF....WEBP
  }
  return false;
}

/// The crop rect ([left, top, right, bottom], normalised to the rotated
/// photo of [w]×[h]) every edit reduces to: the saved frame, else BoxFit
/// contain (skipped) or BoxFit cover (legacy cropped) of the target aspect.
List<double> _effectiveCrop(
    int w, int h, double aspect, bool skipped, List<double>? crop) {
  if (crop != null && crop.length == 4) return crop;
  final srcAspect = w / h;
  if (skipped) {
    if (srcAspect > aspect) {
      final ch = w / aspect; // taller canvas, white above + below
      final top = -(ch - h) / 2 / h;
      return <double>[0, top, 1, 1 - top];
    }
    final cw = h * aspect; // wider canvas, white left + right
    final left = -(cw - w) / 2 / w;
    return <double>[left, 0, 1 - left, 1];
  }
  if (srcAspect > aspect) {
    final cw = h * aspect; // trim the sides
    final left = (w - cw) / 2 / w;
    return <double>[left, 0, 1 - left, 1];
  }
  final ch = w / aspect; // trim top + bottom
  final top = (h - ch) / 2 / h;
  return <double>[0, top, 1, 1 - top];
}

/// Pure-Dart decode → orient → rotate → crop onto white → cap → JPEG.
/// Top-level so `compute` can run it on a background isolate. Returns null
/// when the bytes cannot be decoded (caller tries the native transcode).
Uint8List? _renderOne(_RenderJob job) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(job.bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) return null;
  var image = decoded;
  decoded = null; // only `image` keeps the bitmap reachable from here on

  // Flutter displays photos with their EXIF orientation applied; bake it so
  // the pixels match what the customer saw. bakeOrientation ALWAYS clones the
  // full bitmap, so only call it when there is something to bake.
  final ifd = image.exif.imageIfd;
  if (ifd.hasOrientation && ifd.orientation != 1) {
    image = img.bakeOrientation(image);
  }

  // Transparent stickers / PNG graphics must land on WHITE, never black.
  if (image.hasAlpha) {
    final flat =
        img.Image(width: image.width, height: image.height, numChannels: 3);
    img.fill(flat, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, image);
    image = flat;
  } else if (image.numChannels != 3) {
    image = image.convert(numChannels: 3);
  }

  // Rotation: the crop screen's RotatedBox(quarterTurns) = 90° clockwise each.
  final turns = ((job.rotationSteps % 4) + 4) % 4;
  if (turns != 0) {
    image = img.copyRotate(image,
        angle: 90 * turns, interpolation: img.Interpolation.nearest);
  }

  final rect =
      _effectiveCrop(image.width, image.height, job.aspect, job.skipped, job.crop);

  // If the frame (which may extend into white margin) would be larger than
  // the output budget, shrink the SOURCE first so the canvas is never huge
  // (a zoomed-out crop of a 4000 px photo could otherwise be 8000 px).
  var cw = ((rect[2] - rect[0]) * image.width).round();
  var ch = ((rect[3] - rect[1]) * image.height).round();
  final longest = math.max(cw, ch);
  if (longest > job.maxLongSide && longest > 0) {
    final f = job.maxLongSide / longest;
    image = img.copyResize(image,
        width: math.max(1, (image.width * f).round()),
        height: math.max(1, (image.height * f).round()),
        interpolation: img.Interpolation.cubic);
  }

  image = _applyCrop(image, rect);

  // Cap the longest side (never upscale) — keeps every file well inside the
  // backend's 12 MB per-photo limit while preserving print detail.
  final outLongest = math.max(image.width, image.height);
  if (outLongest > job.maxLongSide) {
    image = image.width >= image.height
        ? img.copyResize(image,
            width: job.maxLongSide, interpolation: img.Interpolation.cubic)
        : img.copyResize(image,
            height: job.maxLongSide, interpolation: img.Interpolation.cubic);
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: job.quality));
}

/// Crops [image] to [rect] (normalised, may extend past the photo): the part
/// outside the photo is WHITE, exactly like the crop screen's white frame.
img.Image _applyCrop(img.Image image, List<double> rect) {
  final w = image.width;
  final h = image.height;
  final x0 = (rect[0] * w).round();
  final y0 = (rect[1] * h).round();
  final x1 = (rect[2] * w).round();
  final y1 = (rect[3] * h).round();
  final cw = x1 - x0;
  final ch = y1 - y0;
  if (cw < 1 || ch < 1) return image; // degenerate rect: print as-is
  if (x0 == 0 && y0 == 0 && x1 == w && y1 == h) return image;

  // The part of the photo that is inside the frame.
  final sx = math.max(0, x0);
  final sy = math.max(0, y0);
  final ex = math.min(w, x1);
  final ey = math.min(h, y1);
  final hasPixels = ex > sx && ey > sy;

  if (hasPixels && sx == x0 && sy == y0 && ex == x1 && ey == y1) {
    // Frame entirely inside the photo: a plain crop, no white needed.
    return img.copyCrop(image, x: sx, y: sy, width: cw, height: ch);
  }

  final canvas = img.Image(width: cw, height: ch, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  if (hasPixels) {
    final piece = (sx == 0 && sy == 0 && ex == w && ey == h)
        ? image
        : img.copyCrop(image, x: sx, y: sy, width: ex - sx, height: ey - sy);
    img.compositeImage(canvas, piece, dstX: sx - x0, dstY: sy - y0);
  }
  return canvas;
}

/// Web renderer: browser codec (bounded, async, EXIF applied) → ui.Canvas
/// (rotate + crop + white) → raw RGBA → JPEG. Returns null when the browser
/// cannot decode the bytes (caller falls back to the Dart decoder).
Future<Uint8List?> _renderOneWeb(_RenderJob job) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? frame;
  ui.Image? out;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(job.bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final dw = descriptor.width;
    final dh = descriptor.height;
    if (dw <= 0 || dh <= 0) return null;
    // Bounded decode: never materialise more than the print needs.
    final cap = job.maxLongSide;
    codec = math.max(dw, dh) > cap
        ? await descriptor.instantiateCodec(
            targetWidth: dw >= dh ? cap : null,
            targetHeight: dh > dw ? cap : null,
          )
        : await descriptor.instantiateCodec();
    frame = (await codec.getNextFrame()).image;
    final iw = frame.width;
    final ih = frame.height;

    final turns = ((job.rotationSteps % 4) + 4) % 4;
    final odd = turns.isOdd;
    final rw = odd ? ih : iw; // rotated size
    final rh = odd ? iw : ih;
    final rect = _effectiveCrop(rw, rh, job.aspect, job.skipped, job.crop);
    final x0 = rect[0] * rw;
    final y0 = rect[1] * rh;
    final cw = (rect[2] - rect[0]) * rw;
    final ch = (rect[3] - rect[1]) * rh;
    if (cw < 1 || ch < 1) return null;
    final f = math.max(cw, ch) > job.maxLongSide
        ? job.maxLongSide / math.max(cw, ch)
        : 1.0;
    final outW = math.max(1, (cw * f).round());
    final outH = math.max(1, (ch * f).round());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    canvas.scale(f, f);
    canvas.translate(-x0, -y0);
    // Rotate about the centre of the rotated box, then draw the upright frame.
    canvas.translate(rw / 2, rh / 2);
    canvas.rotate(turns * math.pi / 2);
    canvas.translate(-iw / 2, -ih / 2);
    canvas.drawImage(
      frame,
      ui.Offset.zero,
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final picture = recorder.endRecording();
    try {
      out = await picture.toImage(outW, outH);
    } finally {
      picture.dispose();
    }
    final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final rgba =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return await encodeRgbaJpg(outW, outH, rgba, job.quality);
  } catch (e) {
    debugPrint('[PhotoExport] browser render failed: $e');
    return null;
  } finally {
    out?.dispose();
    frame?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
