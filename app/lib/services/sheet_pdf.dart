import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/order_record.dart';
import '../models/print_packages.dart';
import 'pdf_download.dart';
import 'photo_bytes.dart';

/// Builds the print-ready 12×18 collage PDFs for an order and triggers a
/// browser download / native share. One PDF per `download` call; one page
/// per master sheet.
class SheetPdfService {
  static const _sheetWidthInches = 12.0;
  static const _sheetHeightInches = 18.0;

  /// Build the print-ready PDF for an order — one combined file with one
  /// PAGE per 12×18 master sheet. Per-photo compression keeps each page's
  /// content well under 6 MB.
  ///
  /// [onProgress] is called with (percent: 0..1, stage: human label).
  static Future<Uint8List> buildBytes({
    required OrderRecord order,
    required PrintSize size,
    void Function(double percent, String stage)? onProgress,
  }) async {
    debugPrint('[SheetPdf] starting for order ${order.displayId}, '
        '${order.photoPaths.length} photos, ${order.sheetsNeeded} sheets');
    onProgress?.call(0.02, 'Preparing photos…');

    final perSheet = size.perSheet;
    final n = order.photoPaths.length;
    // Paginate by the ACTUAL photo count, not the catalog snapCount. The cart
    // allows photos >= snapCount, so using snapCount would silently DROP the
    // extras (customer paid, never printed); and if photos < snapCount,
    // sublist(start,…) could run past the list and throw. buildBytesForGroup
    // already paginates this way.
    final totalSheets = perSheet > 0 ? (n / perSheet).ceil() : 1;

    // ONE photo at a time, straight from disk through the native codec.
    // The previous two-phase design (fetch ALL raw bytes, then compress ALL)
    // held 15–20 full-resolution photos in memory at once and iOS's memory
    // watchdog killed the app mid-order. Peak memory is now ~one photo.
    final maxDim = _maxDimFor(size);
    var compressed = <Uint8List?>[];
    for (var i = 0; i < n; i++) {
      Uint8List? b;
      try {
        b = await _printReadyPhoto(order.photoPaths[i], maxDim)
            .timeout(const Duration(seconds: 25));
      } catch (e) {
        debugPrint('[SheetPdf] photo ${i + 1} failed: $e — using placeholder');
      }
      compressed.add(b);
      onProgress?.call(
          0.02 + 0.88 * (i + 1) / n, 'Preparing photos…  ${i + 1}/$n');
      // Yield so the progress ring paints between photos.
      await Future<void>.delayed(Duration.zero);
    }

    // Polaroids in landscape orientation on the sheet: pre-rotate each
    // image 90° CCW so when the merchant cuts the cell and rotates 90° CW
    // to its portrait polaroid orientation, the photo comes out upright.
    final fitPortrait = _fit(_sheetWidthInches, _sheetHeightInches,
        size.widthInches, size.heightInches);
    final fitLandscape = _fit(_sheetWidthInches, _sheetHeightInches,
        size.heightInches, size.widthInches);
    final usePortrait = fitPortrait.cells >= fitLandscape.cells;
    if (size.hasPolaroidStrip && !usePortrait) {
      onProgress?.call(0.91, 'Rotating photos for polaroid layout…');
      compressed = await _rotateAllCcw90(compressed);
    }

    onProgress?.call(0.92, 'Building print sheets…');
    final pdf = pw.Document();
    for (var s = 0; s < totalSheets; s++) {
      final start = s * perSheet;
      final end = ((s + 1) * perSheet).clamp(0, n);
      final pagePhotos = compressed.sublist(start, end);
      pdf.addPage(_sheetPage(
        order: order,
        size: size,
        pagePhotos: pagePhotos,
        sheetIndex: s + 1,
        totalSheets: totalSheets,
      ));
    }

    onProgress?.call(0.98, 'Finalising PDF…');
    final bytes = await pdf.save();
    final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(2);
    debugPrint('[SheetPdf] built ${order.pdfFilename} ($mb MB, $totalSheets pages)');
    onProgress?.call(1.0, 'Done — $mb MB');
    return bytes;
  }

  /// Rasterises a built print-sheet [pdfBytes] into one JPG per master sheet
  /// (PDF page) at [dpi]. At 300 DPI a 12×18 sheet becomes 3600×5400 px — the
  /// print-ready image the merchant files into their drive (and, later, that we
  /// upload for the automatic OneDrive filing).
  ///
  /// Layout comes straight from the same PDF `buildBytes` produced, so the JPGs
  /// are pixel-identical to the print sheets. The native rasteriser and the
  /// JPEG encode both run off the UI isolate. Returns one JPG per page, in
  /// order. [onProgress] reports the number of sheets done so far.
  static Future<List<Uint8List>> rasterizeToJpgs(
    Uint8List pdfBytes, {
    double dpi = 300,
    int quality = 92,
    int? pageCount,
    void Function(int done)? onProgress,
  }) async {
    final jpgs = <Uint8List>[];
    if (pageCount != null && pageCount > 0) {
      // Raster ONE sheet at a time. Each 12×18 sheet at 300 DPI is a
      // 3600×5400 px / ~78 MB RGBA bitmap; letting the all-pages stream hold
      // several of these at once (plus the photos already in memory) tripped
      // iOS's memory watchdog and crashed the app right after "Pay". Driving
      // the rasteriser page-by-page caps peak memory at a single sheet.
      for (var i = 0; i < pageCount; i++) {
        await for (final page
            in Printing.raster(pdfBytes, pages: [i], dpi: dpi)) {
          jpgs.add(await encodeRgbaJpg(
              page.width, page.height, page.pixels, quality));
          onProgress?.call(jpgs.length);
          await Future<void>.delayed(Duration.zero);
        }
      }
    } else {
      await for (final page in Printing.raster(pdfBytes, dpi: dpi)) {
        jpgs.add(await encodeRgbaJpg(
            page.width, page.height, page.pixels, quality));
        onProgress?.call(jpgs.length);
        // Yield so progress paints between (large) sheets.
        await Future<void>.delayed(Duration.zero);
      }
    }
    debugPrint('[SheetPdf] rasterised ${jpgs.length} sheet JPG(s) @ ${dpi.toInt()} DPI');
    return jpgs;
  }

  /// Rotates every non-null image 90° counterclockwise. Used for landscape-
  /// packed polaroids so the printed product reads upright after cutting.
  static Future<List<Uint8List?>> _rotateAllCcw90(
      List<Uint8List?> bytesList) async {
    final out = <Uint8List?>[];
    for (final b in bytesList) {
      if (b == null) {
        out.add(null);
        continue;
      }
      try {
        // Decode/rotate/encode of a ~3000 px photo is pure-Dart and heavy, so
        // run it on a BACKGROUND ISOLATE (like the sibling flattenResizeEncode)
        // — doing it on the UI isolate janked / risked an ANR for landscape
        // polaroid orders with many photos.
        final rotated = await Isolate.run<Uint8List?>(() {
          final decoded = img.decodeImage(b);
          if (decoded == null) return null;
          final r = img.copyRotate(decoded, angle: -90);
          return Uint8List.fromList(
              img.encodeJpg(r, quality: _printJpegQuality));
        });
        out.add(rotated ?? b); // undecodable → keep the original
      } catch (e) {
        debugPrint('[SheetPdf] rotate failed: $e — keeping unrotated');
        out.add(b);
      }
    }
    return out;
  }

  /// Produces the print-ready JPEG for a single photo, choosing the cheapest
  /// safe route:
  ///  • web URLs (blob:/http) → network fetch, then byte-based compress;
  ///  • local PNG/WebP/GIF (screenshots, stickers) → read bytes, white-flatten
  ///    path (transparency must not turn black);
  ///  • local photos (JPEG/HEIC) → NATIVE codec straight from the file path,
  ///    so the raw photo never enters Dart memory.
  static Future<Uint8List?> _printReadyPhoto(String path, int maxDim) async {
    final uri = Uri.parse(path);
    final isLocal = !uri.hasScheme || uri.scheme == 'file';
    if (!isLocal) {
      final bytes = await _fetchBytes(path);
      return _compressForPrint(bytes, maxDim);
    }
    final localPath = uri.scheme == 'file' ? uri.toFilePath() : path;
    final header = await readFileHeader(localPath, 16);
    if (header != null && _mayHaveAlpha(header)) {
      final bytes = await readLocalBytes(localPath);
      return _compressForPrint(bytes, maxDim);
    }
    final out =
        await compressFileForPrintNative(localPath, maxDim, _printJpegQuality);
    if (out != null && out.isNotEmpty) return out;
    // Fallback (odd formats, unreadable header): byte-based pipeline.
    final bytes = await readLocalBytes(localPath);
    return _compressForPrint(bytes, maxDim);
  }

  /// Resolve a [PrintSize] for an order based on its category + label.
  static PrintSize? resolveSize(OrderRecord order) {
    for (final p in allPacks) {
      if (p.size.category.title == order.productTitle &&
          p.size.label == order.sizeLabel) {
        return p.size;
      }
    }
    return null;
  }

  /// Trigger a download for the order's pre-built combined PDF.
  static Future<void> downloadPrebuilt(OrderRecord order) async {
    final bytes = order.pdfBytes;
    if (bytes == null) {
      throw StateError('Order ${order.displayId} has no pre-built PDF.');
    }
    await downloadPdf(bytes, order.pdfFilename);
  }

  /// Build the print-ready PDF for an entire print queue group (all orders
  /// of the same product + size) — single combined file with one page per
  /// 12×18 master sheet.
  static Future<Uint8List> buildBytesForGroup({
    required List<OrderRecord> orders,
    required PrintSize size,
    void Function(double percent, String stage)? onProgress,
  }) async {
    if (orders.isEmpty) {
      throw ArgumentError('orders list is empty');
    }
    onProgress?.call(0.02, 'Fetching photos…');

    // Build a flat list of (orderRef, photoBytes) pairs in order.
    final flat = <_GroupSlot>[];
    for (final o in orders) {
      for (final p in o.photoPaths) {
        flat.add(_GroupSlot(order: o, path: p));
      }
    }
    final n = flat.length;
    // Sequential per-photo pipeline — same low-memory approach as buildBytes
    // (the old parallel fetch of every photo at once was a memory bomb for
    // large merchant batches).
    final maxDim = _maxDimFor(size);
    final compressed = <Uint8List?>[];
    for (var i = 0; i < n; i++) {
      Uint8List? b;
      try {
        b = await _printReadyPhoto(flat[i].path, maxDim)
            .timeout(const Duration(seconds: 25));
      } catch (e) {
        debugPrint('[SheetPdf] group photo ${i + 1} failed: $e — placeholder');
      }
      compressed.add(b);
      onProgress?.call(
          0.02 + 0.88 * (i + 1) / n, 'Preparing photos…  ${i + 1}/$n');
      await Future<void>.delayed(Duration.zero);
    }

    // Landscape-packed polaroids: pre-rotate each photo 90° CCW.
    final qFitP = _fit(_sheetWidthInches, _sheetHeightInches,
        size.widthInches, size.heightInches);
    final qFitL = _fit(_sheetWidthInches, _sheetHeightInches,
        size.heightInches, size.widthInches);
    final qUsePortrait = qFitP.cells >= qFitL.cells;
    final List<Uint8List?> packed = (size.hasPolaroidStrip && !qUsePortrait)
        ? await _rotateAllCcw90(compressed)
        : compressed;

    onProgress?.call(0.92, 'Building combined sheets…');
    final perSheet = size.perSheet;
    final totalSheets = perSheet > 0 ? (n / perSheet).ceil() : 1;
    final pdf = pw.Document();
    for (var s = 0; s < totalSheets; s++) {
      final start = s * perSheet;
      final end = ((s + 1) * perSheet).clamp(0, n);
      final pagePhotos = packed.sublist(start, end);
      final pageOwners = flat.sublist(start, end);
      pdf.addPage(_groupSheetPage(
        size: size,
        pagePhotos: pagePhotos,
        owners: pageOwners,
        sheetIndex: s + 1,
        totalSheets: totalSheets,
      ));
    }

    onProgress?.call(0.98, 'Finalising PDF…');
    final bytes = await pdf.save();
    final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(2);
    debugPrint('[SheetPdf] group built ($mb MB, $totalSheets pages)');
    onProgress?.call(1.0, 'Done — $mb MB');
    return bytes;
  }

  static pw.Page _groupSheetPage({
    required PrintSize size,
    required List<Uint8List?> pagePhotos,
    required List<_GroupSlot> owners,
    required int sheetIndex,
    required int totalSheets,
  }) {
    const dpi = 72.0;
    final pageFormat = PdfPageFormat(
      _sheetWidthInches * dpi,
      _sheetHeightInches * dpi,
      marginAll: 0,
    );
    return pw.Page(
      pageFormat: pageFormat,
      build: (context) {
        final fitPortrait = _fit(_sheetWidthInches, _sheetHeightInches,
            size.widthInches, size.heightInches);
        final fitLandscape = _fit(_sheetWidthInches, _sheetHeightInches,
            size.heightInches, size.widthInches);
        final usePortrait = fitPortrait.cells >= fitLandscape.cells;
        final fit = usePortrait ? fitPortrait : fitLandscape;
        final photoCellW =
            usePortrait ? size.widthInches : size.heightInches;
        final photoCellH =
            usePortrait ? size.heightInches : size.widthInches;
        final hasStrip = size.hasPolaroidStrip;
        final sideInches =
            usePortrait ? size.sideMarginInches : size.topMarginInches;
        final topInches =
            usePortrait ? size.topMarginInches : size.sideMarginInches;
        final imageWInches = usePortrait
            ? size.imageWidthInches
            : size.imageHeightInches;
        final imageHInches = usePortrait
            ? size.imageHeightInches
            : size.imageWidthInches;

        return pw.Stack(
          children: [
            pw.GridView(
              crossAxisCount: fit.cols,
              crossAxisSpacing: 0,
              mainAxisSpacing: 0,
              childAspectRatio: photoCellW / photoCellH,
              children: List.generate(fit.cols * fit.rows, (i) {
                if (i >= pagePhotos.length) return pw.Container();
                final bytes = pagePhotos[i];
                final owner = owners[i];
                return pw.Stack(
                  fit: pw.StackFit.expand,
                  children: [
                    _polaroidAwareCell(
                      bytes: bytes,
                      photoNumber: i + 1,
                      cellWInches: photoCellW,
                      cellHInches: photoCellH,
                      hasStrip: hasStrip,
                      sideInches: sideInches,
                      topInches: topInches,
                      imageWInches: imageWInches,
                      imageHInches: imageHInches,
                    ),
                    // Tiny customer label so merchant knows whose snap is whose.
                    pw.Positioned(
                      left: 4,
                      bottom: 4,
                      child: pw.Container(
                        padding: const pw.EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        color: PdfColors.white,
                        child: pw.Text(
                          owner.order.customerName,
                          style: const pw.TextStyle(fontSize: 5),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
            // Crop marks at the sheet edges.
            ..._cropMarks(
              cols: fit.cols,
              rows: fit.rows,
              cellW: photoCellW,
              cellH: photoCellH,
            ),
            pw.Positioned(
              bottom: 6,
              right: 8,
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 6, vertical: 3),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  border:
                      pw.Border.all(color: PdfColors.grey400, width: 0.5),
                ),
                child: pw.Text(
                  'Print Queue · ${size.label} · ${size.dimensions} · Sheet $sheetIndex/$totalSheets',
                  style: const pw.TextStyle(
                      fontSize: 7, color: PdfColors.grey800),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Print-quality target. Photo labs expect ~300 DPI; below ~200 the print
  /// looks soft and clients reject it. Each photo is resized so its printed
  /// image area lands at [_printDpi], then JPEG-encoded at high quality.
  /// (The previous 500 px / quality-25 budget was a lightweight WEB-PREVIEW
  /// setting and produced unacceptably blurry prints.)
  static const int _printDpi = 300;
  static const int _printJpegQuality = 92;

  /// Longest-side pixel budget for a photo printed into [size]'s image area
  /// at [_printDpi] — e.g. a 4×6 print → 1800 px, a 9×12 print → 3600 px.
  ///
  /// Floored at 3000 px: when an image's aspect doesn't match its cell (most
  /// importantly tall text screenshots / documents), it prints LARGER than its
  /// nominal edge on the 12×18 sheet, so a nominal-sized resize lands well
  /// under 300 DPI and text goes soft/unreadable. 3000 px ≈ 300 DPI at 10
  /// inches, covering any realistic single-cell placement on the sheet.
  /// Sources are never upscaled, so this only PRESERVES detail the original
  /// already has (a full-res phone screenshot is ~2500 px on its long side —
  /// we were needlessly shrinking it to 1200).
  static int _maxDimFor(PrintSize size) {
    final longestInches = size.imageWidthInches > size.imageHeightInches
        ? size.imageWidthInches
        : size.imageHeightInches;
    final nominal = (longestInches * _printDpi).ceil();
    return nominal < 3000 ? 3000 : nominal;
  }

  /// True if [b] is a transparency-capable format (PNG/WebP/GIF). Photos
  /// (JPEG/HEIC) never carry alpha and return false.
  static bool _mayHaveAlpha(Uint8List b) {
    if (b.length < 12) return false;
    // PNG: 89 50 4E 47
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true;
    }
    // GIF: "GIF8"
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
      return true;
    }
    // WebP: "RIFF"...."WEBP"
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true;
    }
    return false;
  }

  static Future<Uint8List?> _compressForPrint(Uint8List? bytes, int maxDim) async {
    if (bytes == null) return null;

    // Transparency-capable formats (PNG/WebP/GIF — stickers, logos, quote
    // cards) must be flattened onto WHITE before JPEG, or transparent areas
    // turn BLACK and dark text on them becomes unreadable. Route those through
    // the Dart compositor (on a background isolate). Photos skip this.
    if (_mayHaveAlpha(bytes)) {
      final flat = await flattenResizeEncode(bytes, maxDim, _printJpegQuality);
      if (flat != null && flat.isNotEmpty) return flat;
    }

    // Fast path (iOS/Android): resize + JPEG-encode with the platform's NATIVE
    // codec, which runs on a background thread and reads HEIC directly. The
    // pure-Dart `image` path below did a cubic resize of full-resolution
    // photos on the UI isolate, which froze the app — so native is primary.
    // Returns null on web → falls through to the Dart path.
    final native = await compressForPrintNative(bytes, maxDim, _printJpegQuality);
    if (native != null && native.isNotEmpty) return native;

    var working = bytes;
    try {
      img.Image? decoded = img.decodeImage(working);
      if (decoded == null) {
        // The pure-Dart `image` package can't decode this format — most
        // commonly HEIC/HEIF from an iPhone. Transcode to JPEG via the native
        // codec (a no-op on web) and try once more.
        final jpeg = await transcodeToJpeg(working);
        if (jpeg != null && jpeg.isNotEmpty) {
          working = jpeg;
          decoded = img.decodeImage(working);
        }
      }
      if (decoded == null) {
        // Still undecodable: return null so the cell renders a "Photo N"
        // placeholder. Never hand raw/undecodable bytes to pw.MemoryImage —
        // it throws and would fail the entire PDF build.
        debugPrint(
            '[SheetPdf] undecodable image (${working.length ~/ 1024}KB) — using placeholder');
        return null;
      }

      // Downscale to the print-resolution budget — never upscale (that only
      // bloats the file without adding detail). Cubic interpolation keeps
      // edges smooth instead of the blocky nearest-neighbour we used before.
      img.Image resized = decoded;
      if (decoded.width > maxDim || decoded.height > maxDim) {
        if (decoded.width >= decoded.height) {
          resized = img.copyResize(
            decoded,
            width: maxDim,
            interpolation: img.Interpolation.cubic,
          );
        } else {
          resized = img.copyResize(
            decoded,
            height: maxDim,
            interpolation: img.Interpolation.cubic,
          );
        }
      }

      final out = img.encodeJpg(resized, quality: _printJpegQuality);
      debugPrint(
          '[SheetPdf] print ${decoded.width}x${decoded.height} → ${resized.width}x${resized.height}, ${out.length ~/ 1024}KB @ q$_printJpegQuality');
      return Uint8List.fromList(out);
    } catch (e) {
      debugPrint('[SheetPdf] compress failed: $e — using placeholder');
      // Never return undecodable/raw bytes: pw.MemoryImage throws on bytes it
      // can't decode and would fail the whole PDF build. A placeholder cell is
      // safer than a broken export.
      return null;
    }
  }

  // ─── PDF building ────────────────────────────────────────────────
  static pw.Page _sheetPage({
    required OrderRecord order,
    required PrintSize size,
    required List<Uint8List?> pagePhotos,
    required int sheetIndex,
    required int totalSheets,
  }) {
    // Use a custom page format = 12×18 inches at 72 dpi.
    const dpi = 72.0;
    final pageFormat = PdfPageFormat(
      _sheetWidthInches * dpi,
      _sheetHeightInches * dpi,
      marginAll: 0,
    );

    return pw.Page(
      pageFormat: pageFormat,
      build: (context) {
        // Pick the orientation that packs more prints onto the sheet.
        final fitPortrait = _fit(_sheetWidthInches, _sheetHeightInches,
            size.widthInches, size.heightInches);
        final fitLandscape = _fit(_sheetWidthInches, _sheetHeightInches,
            size.heightInches, size.widthInches);
        final usePortrait = fitPortrait.cells >= fitLandscape.cells;
        final fit = usePortrait ? fitPortrait : fitLandscape;

        final photoCellW = (usePortrait ? size.widthInches : size.heightInches);
        final photoCellH = (usePortrait ? size.heightInches : size.widthInches);

        // For polaroids, the photo doesn't fill the whole card — there's a
        // white top + side margin and a wider white strip below. We rotate
        // the margins to match the chosen orientation.
        final hasStrip = size.hasPolaroidStrip;
        final sideInches = usePortrait
            ? size.sideMarginInches
            : size.topMarginInches; // landscape swaps roles
        final topInches = usePortrait
            ? size.topMarginInches
            : size.sideMarginInches;
        final imageWInches = usePortrait
            ? size.imageWidthInches
            : size.imageHeightInches;
        final imageHInches = usePortrait
            ? size.imageHeightInches
            : size.imageWidthInches;

        return pw.Stack(
          children: [
            // Photo grid
            pw.Padding(
              padding: const pw.EdgeInsets.all(0),
              child: pw.GridView(
                crossAxisCount: fit.cols,
                crossAxisSpacing: 0,
                mainAxisSpacing: 0,
                childAspectRatio: photoCellW / photoCellH,
                children: List.generate(fit.cols * fit.rows, (i) {
                  final photoIdx = i;
                  if (photoIdx >= pagePhotos.length) {
                    return pw.Container(); // Empty slot
                  }
                  final bytes = pagePhotos[photoIdx];
                  return _polaroidAwareCell(
                    bytes: bytes,
                    photoNumber: photoIdx + 1,
                    cellWInches: photoCellW,
                    cellHInches: photoCellH,
                    hasStrip: hasStrip,
                    sideInches: sideInches,
                    topInches: topInches,
                    imageWInches: imageWInches,
                    imageHInches: imageHInches,
                  );
                }),
              ),
            ),
            // Crop marks at the sheet edges so the merchant knows where to cut.
            ..._cropMarks(
              cols: fit.cols,
              rows: fit.rows,
              cellW: photoCellW,
              cellH: photoCellH,
            ),
            // Bottom-right overlay: customer name + sheet info
            pw.Positioned(
              bottom: 6,
              right: 8,
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 6, vertical: 3),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
                ),
                child: pw.Text(
                  '${order.customerName}  ·  ${order.productTitle}  ·  $sheetIndex of $totalSheets',
                  style: const pw.TextStyle(
                      fontSize: 7, color: PdfColors.grey800),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Small light-grey tick marks at the sheet edges that show where each
  /// horizontal and vertical cut starts and ends. The body of each cut line
  /// stays white so the printed sheet looks clean.
  static List<pw.Widget> _cropMarks({
    required int cols,
    required int rows,
    required double cellW,
    required double cellH,
  }) {
    const dpi = 72.0;
    const tickInches = 0.10; // about 2.5 mm — half the previous length
    final sheetW = _sheetWidthInches * dpi;
    final sheetH = _sheetHeightInches * dpi;
    final tickPx = tickInches * dpi;
    const stroke = 0.4;
    final color = PdfColors.grey300; // lighter tone

    final widgets = <pw.Widget>[];

    // Horizontal cuts — between rows. Tick on left + right edges. The tick
    // is offset by half its own stroke so its CENTRE line aligns exactly
    // with the cell boundary (i.e. the centre of the white cut gap).
    final gridH = rows * cellH * dpi;
    final rMax = gridH < sheetH - 0.5 ? rows + 1 : rows;
    for (var r = 1; r < rMax; r++) {
      final y = r * cellH * dpi - stroke / 2;
      widgets.add(pw.Positioned(
        left: 0,
        top: y,
        child: pw.Container(width: tickPx, height: stroke, color: color),
      ));
      widgets.add(pw.Positioned(
        left: sheetW - tickPx,
        top: y,
        child: pw.Container(width: tickPx, height: stroke, color: color),
      ));
    }

    // Vertical cuts — between columns. Tick on top + bottom edges. Includes
    // the right edge of the last column when the grid doesn't fill the sheet
    // (e.g. 5.7 x 6 polaroid leaves a 0.6" strip on the right of the 12"
    // sheet — the merchant cuts that off using these marks).
    final gridW = cols * cellW * dpi;
    final cMax = gridW < sheetW - 0.5 ? cols + 1 : cols;
    for (var c = 1; c < cMax; c++) {
      final x = c * cellW * dpi - stroke / 2;
      widgets.add(pw.Positioned(
        left: x,
        top: 0,
        child: pw.Container(width: stroke, height: tickPx, color: color),
      ));
      widgets.add(pw.Positioned(
        left: x,
        top: sheetH - tickPx,
        child: pw.Container(width: stroke, height: tickPx, color: color),
      ));
    }

    return widgets;
  }

  /// Renders one product cell on the master sheet. For plain photos the
  /// image fills the whole cell. For polaroids the image is positioned with
  /// white margins on top + sides and a wider white strip below — proper
  /// polaroid look.
  static pw.Widget _polaroidAwareCell({
    required Uint8List? bytes,
    required int photoNumber,
    required double cellWInches,
    required double cellHInches,
    required bool hasStrip,
    required double sideInches,
    required double topInches,
    required double imageWInches,
    required double imageHInches,
  }) {
    if (!hasStrip) {
      // Plain photo: edge-to-edge with a thin WHITE border on every side.
      // The border is invisible against the white paper but physically eats
      // ~0.5 pt of photo so the merchant always cuts through clean white
      // space — no grey or photo edge artifact on the customer's print.
      return pw.Container(
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.white, width: 1.0),
        ),
        child: bytes == null
            ? pw.Center(
                child: pw.Text('Photo $photoNumber',
                    style: const pw.TextStyle(
                        color: PdfColors.grey, fontSize: 10)),
              )
            : pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.cover),
      );
    }
    // Polaroid: render as fractional layout inside the cell.
    final sideFrac = sideInches / cellWInches;
    final topFrac = topInches / cellHInches;
    final imgWFrac = imageWInches / cellWInches;
    final imgHFrac = imageHInches / cellHInches;
    return pw.LayoutBuilder(builder: (ctx, constraints) {
      final w = constraints!.maxWidth;
      final h = constraints.maxHeight;
      return pw.Container(
        decoration: pw.BoxDecoration(
          color: PdfColors.white,
          border: pw.Border.all(color: PdfColors.white, width: 1.0),
        ),
        child: pw.Stack(
          children: [
            pw.Positioned(
              left: sideFrac * w,
              top: topFrac * h,
              child: pw.Container(
                width: imgWFrac * w,
                height: imgHFrac * h,
                child: bytes == null
                    ? pw.Center(
                        child: pw.Text('Photo $photoNumber',
                            style: const pw.TextStyle(
                                color: PdfColors.grey, fontSize: 10)),
                      )
                    : pw.Image(pw.MemoryImage(bytes),
                        fit: pw.BoxFit.cover),
              ),
            ),
          ],
        ),
      );
    });
  }

  // ─── Layout math ────────────────────────────────────────────────
  static _GridFit _fit(double sheetW, double sheetH, double pw, double ph) {
    final cols = (sheetW ~/ pw);
    final rows = (sheetH ~/ ph);
    return _GridFit(cols, rows);
  }

  // ─── Image fetching (web blob: URLs + http URLs) ────────────────
  static Future<Uint8List?> _fetchBytes(String path) async {
    final uri = Uri.parse(path);
    // Native (iOS/Android) image pickers hand back a local filesystem path
    // with no URL scheme (or a file:// URL); read those straight from disk.
    // Web paths are blob:/http(s) URLs and fall through to the network fetch.
    if (!uri.hasScheme || uri.scheme == 'file') {
      final localPath = uri.scheme == 'file' ? uri.toFilePath() : path;
      return readLocalBytes(localPath);
    }
    final res = await http
        .get(uri)
        .timeout(const Duration(milliseconds: 1500), onTimeout: () {
      throw TimeoutException('Photo fetch timed out: $path');
    });
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode} for $path');
    }
    return res.bodyBytes;
  }

}

class _GridFit {
  const _GridFit(this.cols, this.rows);
  final int cols;
  final int rows;
  int get cells => cols * rows;
}

class _GroupSlot {
  const _GroupSlot({required this.order, required this.path});
  final OrderRecord order;
  final String path;
}
