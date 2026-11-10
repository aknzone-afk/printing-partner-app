// Unit tests for the print export (lib/services/photo_export.dart):
// every pack aspect, rotation direction, white-pad vs cover, the crop
// screen's pan + zoom, the size cap, ordering and error reporting.
//
// Photos are synthetic 4-quadrant images (RED top-left, GREEN top-right,
// BLUE bottom-left, YELLOW bottom-right) so "which part of the photo printed"
// is readable from the output pixels.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:printing_partner/models/cart.dart';
import 'package:printing_partner/models/print_packages.dart';
import 'package:printing_partner/services/photo_bytes.dart';
import 'package:printing_partner/services/photo_export.dart';

import 'support/screen_model.dart';
import 'support/test_images.dart';

/// Every distinct print size in the catalogue (12: 6 photo, 3 polaroid,
/// 3 snapbook).
List<PrintSize> allSizes() {
  final seen = <PrintSize>[];
  for (final p in allPacks) {
    if (!seen.any((s) => identical(s, p.size))) seen.add(p.size);
  }
  return seen;
}

PrintPack packLabelled(PrintCategory c, String label) =>
    allPacks.firstWhere((p) => p.size.category == c && p.size.label == label);

const CropEdit autoCrop = CropEdit.cropped(offsetX: 0, offsetY: 0, scale: 1);

/// A crop-screen Save: viewer matrix `view = scale * scene + (tx, ty)` in a
/// crop frame of [fw] x [fh] logical px.
CropEdit saved(double scale, double tx, double ty, double fw, double fh,
        {int rot = 0}) =>
    CropEdit.cropped(
      offsetX: tx,
      offsetY: ty,
      scale: scale,
      rotationSteps: rot,
      viewWidth: fw,
      viewHeight: fh,
    );

Cart cartOf(PrintPack pack, List<String> paths, List<CropEdit?> edits) {
  final cart = Cart()
    ..selectPack(pack)
    ..addPhotos(paths);
  expect(cart.itemCount, paths.length,
      reason: 'test set-up: the pack must hold all the test photos');
  for (var i = 0; i < edits.length; i++) {
    final e = edits[i];
    if (e != null) cart.setCrop(cart.items[i].id, e);
  }
  return cart;
}

Future<List<img.Image>> render(Cart cart, {int? maxLongSide}) async {
  final jpgs = await renderCroppedJpegs(cart, maxLongSide: maxLongSide);
  return [for (final j in jpgs) decodeJpg(j)];
}

/// Corner colours [TL, TR, BL, BR] of the print, sampled well inside.
List<Q> corners(img.Image im) => [
      colourAt(im, 0.12, 0.12),
      colourAt(im, 0.88, 0.12),
      colourAt(im, 0.12, 0.88),
      colourAt(im, 0.88, 0.88),
    ];

/// The quadrant layout [TL, TR, BL, BR] after [turns] CLOCKWISE quarter
/// turns of the upright test photo (one turn moves TL->TR->BR->BL->TL).
List<Q> layoutAfter(int turns) {
  var l = <Q>[Q.red, Q.green, Q.blue, Q.yellow];
  for (var i = 0; i < turns % 4; i++) {
    l = <Q>[l[2], l[0], l[3], l[1]];
  }
  return l;
}

/// Like [expectPrintMatchesScreen] but without a minimum number of judged
/// points (a random framing may be mostly on a colour boundary).
void _expectMatchesWhereJudgeable(
  img.Image out, {
  required double frameW,
  required double frameH,
  required int photoW,
  required int photoH,
  required int turns,
  required double scale,
  required double tx,
  required double ty,
  required String label,
}) {
  const grid = 11;
  final problems = <String>[];
  for (var j = 0; j < grid; j++) {
    for (var i = 0; i < grid; i++) {
      final px = (i + 0.5) / grid;
      final py = (j + 0.5) / grid;
      final want = screenColourAt(
        px: px,
        py: py,
        frameW: frameW,
        frameH: frameH,
        photoW: photoW,
        photoH: photoH,
        turns: turns,
        scale: scale,
        tx: tx,
        ty: ty,
      );
      if (want == null) continue;
      final got = colourAt(out, px, py);
      if (got != want) {
        problems.add('(${px.toStringAsFixed(2)},${py.toStringAsFixed(2)}): '
            'screen ${want.name}, print ${got.name}');
      }
    }
  }
  expect(problems, isEmpty,
      reason: '$label: print ${out.width}x${out.height} differs from the '
          'crop screen');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TempPhotos tmp;
  final DebugPrintCallback realDebugPrint = debugPrint;
  setUpAll(() {
    tmp = TempPhotos();
    debugPrint = (String? message, {int? wrapWidth}) {};
  });
  tearDownAll(() {
    debugPrint = realDebugPrint;
    tmp.dispose();
  });

  group('cropFrameRect (crop-screen frame -> photo rect)', () {
    test('identity view on a photo of the frame aspect is the whole photo', () {
      final r = cropFrameRect(
          frameAspect: 0.75, photoAspect: 0.75, scale: 1, fx: 0, fy: 0)!;
      expect(r[0], closeTo(0, 1e-9));
      expect(r[1], closeTo(0, 1e-9));
      expect(r[2], closeTo(1, 1e-9));
      expect(r[3], closeTo(1, 1e-9));
    });

    test('2x at the origin is the top-left quarter; 2x fully panned is the '
        'bottom-right quarter', () {
      final tl = cropFrameRect(
          frameAspect: 1, photoAspect: 1, scale: 2, fx: 0, fy: 0)!;
      expect(tl, [0.0, 0.0, 0.5, 0.5]);
      final br = cropFrameRect(
          frameAspect: 1, photoAspect: 1, scale: 2, fx: -1, fy: -1)!;
      expect(br, [0.5, 0.5, 1.0, 1.0]);
    });

    test('the rect always has the frame aspect in real photo pixels', () {
      for (final a in [2 / 3, 0.75, 4 / 4.5, 1.0]) {
        for (final r in [0.5, 2 / 3, 1.0, 1.5, 2.0]) {
          for (final s in [0.5, 1.0, 2.0, 3.7]) {
            final rect = cropFrameRect(
                frameAspect: a,
                photoAspect: r,
                scale: s,
                fx: -0.31,
                fy: 0.17)!;
            // photo is r x 1 (units of its height)
            final w = (rect[2] - rect[0]) * r;
            final h = rect[3] - rect[1];
            expect(w / h, closeTo(a, 1e-9),
                reason: 'frame $a photo $r scale $s');
          }
        }
      }
    });

    test('inputs that cannot describe a frame give null (never NaN rects)', () {
      expect(
          cropFrameRect(
              frameAspect: 1, photoAspect: 1, scale: 0, fx: 0, fy: 0),
          isNull);
      expect(
          cropFrameRect(
              frameAspect: 1,
              photoAspect: 1,
              scale: double.nan,
              fx: 0,
              fy: 0),
          isNull);
      expect(
          cropFrameRect(
              frameAspect: 1,
              photoAspect: 1,
              scale: 1,
              fx: double.infinity,
              fy: 0),
          isNull);
      expect(
          cropFrameRect(
              frameAspect: 0, photoAspect: 1, scale: 1, fx: 0, fy: 0),
          isNull);
    });

    test('CropEdit.hasView: only a non-skipped edit with a real frame size',
        () {
      expect(saved(2, -10, -20, 300, 400).hasView, isTrue);
      expect(autoCrop.hasView, isFalse, reason: 'no frame size = Auto crop');
      expect(const CropEdit.skipped().hasView, isFalse);
      expect(saved(double.nan, 0, 0, 300, 400).hasView, isFalse);
      expect(saved(1, double.infinity, 0, 300, 400).hasView, isFalse);
      expect(saved(0, 0, 0, 300, 400).hasView, isFalse);
    });
  });

  group('every pack aspect', () {
    const shapes = <List<int>>[
      [600, 400], // landscape
      [400, 600], // portrait
      [500, 500], // square
    ];

    for (final size in allSizes()) {
      final name = '${size.category.slug} "${size.label}" '
          '(image ${size.imageWidthInches}x${size.imageHeightInches} in)';

      test('$name: skipped = white-padded contain, cropped = cover, both '
          'exactly the image aspect', () async {
        final pack = packsFor(size).first;
        final aspect = size.imageAspectWxH;
        final paths = [
          for (final s in shapes) tmp.writePng(quadrantImage(s[0], s[1]))
        ];
        final cart = cartOf(pack, [
          ...paths,
          ...paths
        ], [
          const CropEdit.skipped(),
          const CropEdit.skipped(),
          const CropEdit.skipped(),
          autoCrop,
          autoCrop,
          autoCrop,
        ]);
        final outs = await render(cart);
        expect(outs.length, 6);

        for (var i = 0; i < shapes.length; i++) {
          final w = shapes[i][0];
          final h = shapes[i][1];
          final srcAspect = w / h;
          final tag = '$name, photo ${w}x$h';

          // --- skipped: the WHOLE photo on a white canvas of the pack aspect
          final pad = outs[i];
          expect(aspectWithin1px(pad.width, pad.height, aspect), isTrue,
              reason: '$tag skipped: ${pad.width}x${pad.height} is not '
                  'aspect $aspect');
          if (srcAspect > aspect) {
            expect(pad.width, w, reason: '$tag skipped: never rescaled');
            expect(pad.height, closeTo(w / aspect, 1.0));
          } else {
            expect(pad.height, h, reason: '$tag skipped: never rescaled');
            expect(pad.width, closeTo(h * aspect, 1.0));
          }
          final seen = expectPrintMatchesScreen(pad,
              frameW: aspect * 1000,
              frameH: 1000,
              photoW: w,
              photoH: h,
              turns: 0,
              scale: 1,
              tx: 0,
              ty: 0,
              grid: 15,
              label: '$tag skipped');
          expect(seen, containsAll([Q.red, Q.green, Q.blue, Q.yellow]),
              reason: '$tag skipped: the whole photo must be on the print');
          if ((srcAspect / aspect - 1).abs() > 0.2) {
            expect(seen, contains(Q.white),
                reason: '$tag skipped: padding must be white');
          }

          // --- cropped (Auto crop): centre cover, no white anywhere
          final cov = outs[i + 3];
          expect(aspectWithin1px(cov.width, cov.height, aspect), isTrue,
              reason: '$tag cover: ${cov.width}x${cov.height} is not '
                  'aspect $aspect');
          if (srcAspect > aspect) {
            expect(cov.height, h, reason: '$tag cover keeps the full height');
            expect(cov.width, closeTo(h * aspect, 1.0));
          } else {
            expect(cov.width, w, reason: '$tag cover keeps the full width');
            expect(cov.height, closeTo(w / aspect, 1.0));
          }
          const n = 11;
          for (var gy = 0; gy < n; gy++) {
            for (var gx = 0; gx < n; gx++) {
              final px = (gx + 0.5) / n;
              final py = (gy + 0.5) / n;
              final got = colourAt(cov, px, py);
              expect(got, isNot(Q.white),
                  reason: '$tag cover: white at ($px,$py)');
              if ((px - 0.5).abs() > 0.05 && (py - 0.5).abs() > 0.05) {
                expect(got, quadrantAt(px, py),
                    reason: '$tag cover: centre crop keeps the photo centre '
                        'in the middle of the print ($px,$py)');
              }
            }
          }
        }
      });

      test('$name: 2x zoom panned onto the photo\'s top-left corner prints '
          'that corner', () async {
        final pack = packsFor(size).first;
        final aspect = size.imageAspectWxH;
        const pw = 400, ph = 600;
        const fh = 600.0;
        final fw = fh * aspect;
        // Contain-fit of the photo in the frame (what the screen shows at 1x).
        final k = math.min(fw / pw, fh / ph);
        final ox = (fw - pw * k) / 2;
        final oy = (fh - ph * k) / 2;
        // 2x, photo's top-left corner at the frame's top-left corner.
        final tx = -2 * ox;
        final ty = -2 * oy;
        final cart = cartOf(pack, [tmp.writePng(quadrantImage(pw, ph))],
            [saved(2, tx, ty, fw, fh)]);
        final out = (await render(cart)).single;
        expect(aspectWithin1px(out.width, out.height, aspect), isTrue,
            reason: '$name: ${out.width}x${out.height}');
        final seen = expectPrintMatchesScreen(out,
            frameW: fw,
            frameH: fh,
            photoW: pw,
            photoH: ph,
            turns: 0,
            scale: 2,
            tx: tx,
            ty: ty,
            grid: 13,
            label: '$name top-left 2x');
        expect(colourAt(out, 0.1, 0.1), Q.red);
        expect(seen, contains(Q.red));
        expect(seen, isNot(contains(Q.yellow)),
            reason: 'the bottom-right quadrant is outside a top-left 2x crop');
        expect(seen, isNot(contains(Q.white)),
            reason: 'the frame is entirely inside the photo');
        // Half the frame in each direction: never larger than the source.
        expect(out.width, lessThanOrEqualTo(pw));
        expect(out.height, lessThanOrEqualTo(ph));
      });
    }
  });

  group('rotation is CLOCKWISE, like the crop screen\'s RotatedBox', () {
    final polaroid = packLabelled(PrintCategory.polaroid, 'Vintage Mini');
    final regular = packLabelled(PrintCategory.photos, 'Regular'); // 2:3

    for (var turns = 0; turns < 4; turns++) {
      test('rotationSteps $turns: skipped, auto-crop and saved view agree',
          () async {
        final path = tmp.writePng(quadrantImage(400, 400));
        final cart = cartOf(polaroid, [
          path,
          path,
          path,
          path
        ], [
          CropEdit.skipped(rotationSteps: turns),
          CropEdit.cropped(
              offsetX: 0, offsetY: 0, scale: 1, rotationSteps: turns),
          saved(1, 0, 0, 300, 300, rot: turns),
          saved(2, 0, 0, 300, 300, rot: turns), // top-left corner at 2x
        ]);
        final outs = await render(cart);
        final want = layoutAfter(turns);
        expect(corners(outs[0]), want, reason: 'skipped, $turns turn(s)');
        expect(corners(outs[1]), want, reason: 'auto crop, $turns turn(s)');
        expect(corners(outs[2]), want, reason: 'saved 1x, $turns turn(s)');
        expect(corners(outs[3]), List.filled(4, want[0]),
            reason: '2x top-left after $turns clockwise turn(s) shows only '
                'the quadrant that is top-left ON SCREEN');
      });

      test('rotationSteps $turns on a 600x300 photo in a 4x6 frame: rotated '
          'size, padding and cover', () async {
        final path = tmp.writePng(quadrantImage(600, 300));
        final cart = cartOf(regular, [
          path,
          path
        ], [
          CropEdit.skipped(rotationSteps: turns),
          CropEdit.cropped(
              offsetX: 0, offsetY: 0, scale: 1, rotationSteps: turns),
        ]);
        final outs = await render(cart);
        final pad = outs[0];
        final cov = outs[1];
        if (turns.isOdd) {
          // rotated photo is 300x600 (1:2) -> canvas 400x600, white L + R
          expect([pad.width, pad.height], [400, 600]);
          // cover of 300x600 at 2:3 -> 300x450
          expect([cov.width, cov.height], [300, 450]);
        } else {
          // 600x300 (2:1) -> canvas 600x900, white above + below
          expect([pad.width, pad.height], [600, 900]);
          // cover of 600x300 at 2:3 -> 200x300
          expect([cov.width, cov.height], [200, 300]);
        }
        final seen = expectPrintMatchesScreen(pad,
            frameW: 400,
            frameH: 600,
            photoW: 600,
            photoH: 300,
            turns: turns,
            scale: 1,
            tx: 0,
            ty: 0,
            grid: 15,
            label: 'skipped rot $turns');
        expect(seen, containsAll([Q.red, Q.green, Q.blue, Q.yellow, Q.white]));
        expect(corners(cov), layoutAfter(turns),
            reason: 'cover after $turns clockwise turn(s)');
      });
    }

    test('rotationSteps outside 0..3 wrap (5 = 1 turn, -1 = 3 turns)',
        () async {
      final path = tmp.writePng(quadrantImage(400, 400));
      final cart = cartOf(polaroid, [
        path,
        path
      ], [
        const CropEdit.skipped(rotationSteps: 5),
        const CropEdit.skipped(rotationSteps: -1),
      ]);
      final outs = await render(cart);
      expect(corners(outs[0]), layoutAfter(1));
      expect(corners(outs[1]), layoutAfter(3));
    });
  });

  group('the crop OFFSET and SCALE chosen on the crop screen are honoured', () {
    final polaroid = packLabelled(PrintCategory.polaroid, 'Vintage Mini');
    final regular = packLabelled(PrintCategory.photos, 'Regular'); // 2:3

    test('2x zoom panned to each corner prints exactly that quadrant',
        () async {
      final path = tmp.writePng(quadrantImage(400, 400));
      const f = 300.0; // crop frame, logical px
      final cart = cartOf(polaroid, [
        path,
        path,
        path,
        path
      ], [
        saved(2, 0, 0, f, f), // top-left
        saved(2, -f, 0, f, f), // top-right
        saved(2, 0, -f, f, f), // bottom-left
        saved(2, -f, -f, f, f), // bottom-right
      ]);
      final outs = await render(cart);
      final want = [Q.red, Q.green, Q.blue, Q.yellow];
      for (var i = 0; i < 4; i++) {
        expect(corners(outs[i]), List.filled(4, want[i]),
            reason: 'corner $i must print only ${want[i].name}');
        expect(colourAt(outs[i], 0.5, 0.5), want[i]);
        // A quarter of a 400 px photo: 200 px, never upscaled.
        expect(outs[i].width, inInclusiveRange(199, 201));
        expect(outs[i].height, inInclusiveRange(199, 201));
      }
    });

    test('scale changes the print: 1x = whole photo, 2x centred = middle '
        'half, 4x centred on the red quadrant = red only', () async {
      final path = tmp.writePng(quadrantImage(400, 400));
      const f = 320.0;
      final cart = cartOf(polaroid, [
        path,
        path,
        path
      ], [
        saved(1, 0, 0, f, f),
        saved(2, -f / 2, -f / 2, f, f),
        // 4x with scene point (f/4, f/4) (centre of the red quadrant) at the
        // frame centre: t = f/2 - 4 * f/4 = -f/2.
        saved(4, -f / 2, -f / 2, f, f),
      ]);
      final outs = await render(cart);
      expect([outs[0].width, outs[0].height], [400, 400]);
      expect(corners(outs[0]), layoutAfter(0));
      expect(outs[1].width, inInclusiveRange(199, 201));
      expect(corners(outs[1]), layoutAfter(0));
      expect(outs[2].width, inInclusiveRange(99, 101));
      expect(corners(outs[2]), List.filled(4, Q.red));
    });

    test('the pan is measured in the frame it was saved in: the same framing '
        'on a small and a large screen prints the same', () async {
      final path = tmp.writePng(quadrantImage(500, 700));
      CropEdit framing(double fw) {
        final fh = fw * 1.5; // 4x6 frame
        return saved(3, -0.4 * fw, -1.36 * fh, fw, fh);
      }

      final cart = cartOf(
          regular, [path, path], [framing(240), framing(1040)]);
      final outs = await render(cart);
      expect([outs[0].width, outs[0].height],
          [outs[1].width, outs[1].height]);
      for (final o in outs) {
        expectPrintMatchesScreen(o,
            frameW: 240,
            frameH: 360,
            photoW: 500,
            photoH: 700,
            turns: 0,
            scale: 3,
            tx: -0.4 * 240,
            ty: -1.36 * 360,
            label: 'screen-size independence');
      }
    });

    test('a frame that reaches past the photo prints WHITE there (zoomed out '
        'and panned), never a stretched or shifted photo', () async {
      const pw = 600, ph = 300;
      const fw = 400.0, fh = 600.0;
      final path = tmp.writePng(quadrantImage(pw, ph));
      final cart = cartOf(regular, [
        path,
        path
      ], [
        // 2x, photo's top-left at the frame's top-left: the photo (contained
        // 400x200 at y=200) fills the top 2/3 of the frame, white below.
        saved(2, 0, -400, fw, fh),
        // zoomed OUT to 0.5x, centred
        saved(0.5, fw / 4, fh / 4, fw, fh),
      ]);
      final outs = await render(cart);
      final a = outs[0];
      expect(aspectWithin1px(a.width, a.height, 2 / 3), isTrue);
      expectPrintMatchesScreen(a,
          frameW: fw,
          frameH: fh,
          photoW: pw,
          photoH: ph,
          turns: 0,
          scale: 2,
          tx: 0,
          ty: -400,
          grid: 15,
          label: 'pan with white');
      expect(colourAt(a, 0.5, 0.15), Q.red);
      expect(colourAt(a, 0.5, 0.5), Q.blue);
      expect(colourAt(a, 0.5, 0.85), Q.white);

      final b = outs[1];
      expect(aspectWithin1px(b.width, b.height, 2 / 3), isTrue);
      final seen = expectPrintMatchesScreen(b,
          frameW: fw,
          frameH: fh,
          photoW: pw,
          photoH: ph,
          turns: 0,
          scale: 0.5,
          tx: fw / 4,
          ty: fh / 4,
          grid: 21,
          label: 'zoomed out');
      expect(seen, containsAll([Q.red, Q.green, Q.blue, Q.yellow, Q.white]));
      expect(corners(b), List.filled(4, Q.white));
    });

    test('offset combined with rotation: 2x bottom-right after one clockwise '
        'turn prints what is bottom-right on screen', () async {
      const fw = 400.0, fh = 600.0;
      final path = tmp.writePng(quadrantImage(400, 600));
      // After 1 turn the photo is 600x400, contained 400x266.67 in the frame
      // at y = 166.67. 2x with the photo's bottom-right corner (scene
      // 400, 433.33) on the frame's bottom-right corner (400, 600):
      // t = (400 - 2*400, 600 - 2*433.33).
      final edit = saved(2, -400, 600 - 2 * (600 + 800 / 3) / 2, fw, fh, rot: 1);
      final cart = cartOf(regular, [path], [edit]);
      final out = (await render(cart)).single;
      expect(aspectWithin1px(out.width, out.height, 2 / 3), isTrue);
      final seen = expectPrintMatchesScreen(out,
          frameW: fw,
          frameH: fh,
          photoW: 400,
          photoH: 600,
          turns: 1,
          scale: 2,
          tx: edit.offsetX,
          ty: edit.offsetY,
          grid: 15,
          label: 'rot 1 + pan');
      // On screen (1 clockwise turn) the layout is BLUE RED / YELLOW GREEN:
      // the right half is RED over GREEN, bottom-right GREEN.
      expect(colourAt(out, 0.5, 0.9), Q.green);
      expect(seen, containsAll([Q.red, Q.green]));
      expect(seen, isNot(contains(Q.blue)));
      expect(seen, isNot(contains(Q.yellow)));
    });

    test('legacy edits stay usable: offset/scale without a frame size = '
        'centre cover; an explicit normalised crop rect is printed as given',
        () async {
      final path = tmp.writePng(quadrantImage(600, 400));
      final cart = cartOf(polaroid, [
        path,
        path,
        path
      ], [
        // Saved by a build that did not record the frame size.
        const CropEdit.cropped(offsetX: -120, offsetY: -80, scale: 2),
        // Explicit rect normalised to the photo: a 200x200 px square inside
        // its top-left (red) quadrant.
        const CropEdit.cropped(
            offsetX: 0,
            offsetY: 0,
            scale: 1,
            crop: Rect.fromLTRB(0, 0, 1 / 3, 0.5)),
        null, // never reviewed -> white-pad
      ]);
      final outs = await render(cart);
      expect([outs[0].width, outs[0].height], [400, 400]);
      expect(corners(outs[0]), layoutAfter(0));
      expect([outs[1].width, outs[1].height], [200, 200]);
      expect(corners(outs[1]), List.filled(4, Q.red));
      // No CropEdit at all = skipped (contain on white): 600x600 canvas.
      expect([outs[2].width, outs[2].height], [600, 600]);
      expect(colourAt(outs[2], 0.5, 0.05), Q.white);
      expect(colourAt(outs[2], 0.25, 0.4), Q.red);
    });
  });

  test('60 random framings (any pack, photo shape, rotation, zoom, pan): the '
      'print always has the pack aspect and shows what the screen showed',
      () async {
    final rnd = math.Random(20261110);
    final sizes = allSizes();
    const dims = [601, 640, 733, 800, 955, 1024];
    for (var n = 0; n < 60; n++) {
      final size = sizes[rnd.nextInt(sizes.length)];
      final aspect = size.imageAspectWxH;
      final pw = dims[rnd.nextInt(dims.length)];
      final ph = dims[rnd.nextInt(dims.length)];
      final turns = rnd.nextInt(4);
      final scale = [0.5, 0.8, 1.0, 1.25, 1.5625, 2.0, 3.0][rnd.nextInt(7)];
      final fh = 300.0 + rnd.nextInt(500);
      final fw = fh * aspect;
      // Any pan that keeps part of the scene in the frame.
      final tx = -(scale * fw) * rnd.nextDouble() + fw * 0.6 * rnd.nextDouble();
      final ty = -(scale * fh) * rnd.nextDouble() + fh * 0.6 * rnd.nextDouble();
      final label = 'case $n: ${size.label} photo ${pw}x$ph turns $turns '
          'scale $scale t=(${tx.toStringAsFixed(1)},${ty.toStringAsFixed(1)}) '
          'frame ${fw.toStringAsFixed(1)}x$fh';
      final cart = cartOf(packsFor(size).first,
          [tmp.writePng(quadrantImage(pw, ph))],
          [saved(scale, tx, ty, fw, fh, rot: turns)]);
      final out = (await render(cart)).single;
      expect(aspectWithin1px(out.width, out.height, aspect), isTrue,
          reason: '$label -> ${out.width}x${out.height}');
      expect(math.max(out.width, out.height),
          lessThanOrEqualTo(printLongSideFor(size)),
          reason: label);
      // Never upscaled: one frame pixel is at most one photo pixel... i.e.
      // the print is no larger than the framed region in photo pixels.
      final rw = turns.isOdd ? ph : pw;
      final rh = turns.isOdd ? pw : ph;
      final k = math.min(fw / rw, fh / rh); // screen px per photo px at 1x
      expect(out.width, lessThanOrEqualTo((fw / (k * scale)).ceil() + 1),
          reason: '$label: upscaled');
      // Compare with the screen wherever the print is large enough to judge.
      if (math.min(out.width, out.height) >= 150) {
        _expectMatchesWhereJudgeable(out,
            frameW: fw,
            frameH: fh,
            photoW: pw,
            photoH: ph,
            turns: turns,
            scale: scale,
            tx: tx,
            ty: ty,
            label: label);
      }
    }
  });

  group('output size: capped, never upscaled', () {
    final polaroid = packLabelled(PrintCategory.polaroid, 'Vintage Mini');
    final regular = packLabelled(PrintCategory.photos, 'Regular');
    final xl = packLabelled(PrintCategory.photos, 'Regular Xtra-Large');

    test('the default budget is 1800..4000 px for every size, 4000 for the '
        'largest print', () {
      for (final s in allSizes()) {
        final n = printLongSideFor(s);
        expect(n, inInclusiveRange(1800, 4000), reason: s.label);
      }
      expect(printLongSideFor(xl.size), 4000);
      expect(
          printLongSideFor(
              packLabelled(PrintCategory.photos, 'Regular Mini').size),
          1800);
    });

    test('a small photo is never upscaled (cover, white-pad, zoomed in)',
        () async {
      final path = tmp.writePng(quadrantImage(300, 400));
      final cart = cartOf(xl, [
        path,
        path,
        path
      ], [
        autoCrop,
        const CropEdit.skipped(),
        saved(2, 0, 0, 300, 400),
      ]);
      final outs = await render(cart);
      expect([outs[0].width, outs[0].height], [300, 400]);
      expect([outs[1].width, outs[1].height], [300, 400]);
      expect(outs[2].width, inInclusiveRange(149, 151));
      expect(outs[2].height, inInclusiveRange(199, 201));
    });

    test('maxLongSide caps cover, white-pad and zoomed-out prints and keeps '
        'the aspect + content', () async {
      final wide = tmp.writePng(quadrantImage(1000, 800));
      final cart = cartOf(polaroid, [
        wide,
        wide,
        wide
      ], [
        autoCrop, // 800x800 -> 500x500
        const CropEdit.skipped(), // canvas 1000x1000 -> 500x500
        saved(0.5, 75, 75, 300, 300), // canvas 2000x2000 -> 500x500
      ]);
      final outs = await render(cart, maxLongSide: 500);
      for (final o in outs) {
        expect([o.width, o.height], [500, 500]);
      }
      expect(corners(outs[0]), layoutAfter(0));
      expect(colourAt(outs[1], 0.5, 0.04), Q.white);
      expect(colourAt(outs[1], 0.25, 0.3), Q.red);
      expect(colourAt(outs[1], 0.75, 0.7), Q.yellow);
      expect(corners(outs[2]), List.filled(4, Q.white));
      expect(colourAt(outs[2], 0.4, 0.45), Q.red);
      expect(colourAt(outs[2], 0.6, 0.55), Q.yellow);

      // Non-square frame: 1000x500 white-padded to 2:3 = 1000x1500 -> 400x600
      final cart2 = cartOf(regular, [tmp.writePng(quadrantImage(1000, 500))],
          [const CropEdit.skipped()]);
      final o2 = (await render(cart2, maxLongSide: 600)).single;
      expect([o2.width, o2.height], [400, 600]);
    });

    test('white-padded panoramas / very narrow photos larger than the budget '
        'keep the exact pack aspect and land exactly on the budget', () async {
      // [photo w, photo h, budget]. The canvas is mostly white padding here,
      // so rounding the shrunken photo's size must not be multiplied into it.
      const cases = <List<int>>[
        [4000, 400, 1000],
        [3000, 250, 1000],
        [2400, 500, 1000],
        [1600, 500, 1000],
        [250, 3000, 1000],
        [5000, 1040, 2700],
      ];
      for (final pack in [regular, polaroid, xl]) {
        final aspect = pack.size.imageAspectWxH;
        for (final c in cases) {
          final cart = cartOf(pack, [tmp.writePng(quadrantImage(c[0], c[1]))],
              [const CropEdit.skipped()]);
          final out = (await render(cart, maxLongSide: c[2])).single;
          final tag = '${pack.size.label}, photo ${c[0]}x${c[1]}, budget '
              '${c[2]} -> ${out.width}x${out.height}';
          expect(aspectWithin1px(out.width, out.height, aspect), isTrue,
              reason: '$tag is not aspect $aspect');
          expect(math.max(out.width, out.height), c[2], reason: tag);
          // The whole photo is there, centred, on white.
          final seen = expectPrintMatchesScreen(out,
              frameW: aspect * 1000,
              frameH: 1000,
              photoW: c[0],
              photoH: c[1],
              turns: 0,
              scale: 1,
              tx: 0,
              ty: 0,
              grid: 25,
              guard: 0.02,
              label: tag);
          expect(seen, contains(Q.white), reason: tag);
        }
      }
      // Tiny / 1-pixel-wide inputs: still the pack aspect, never a crash.
      for (final c in const [
        [3, 400],
        [400, 3],
        [1, 1],
        [2000, 2]
      ]) {
        final cart = cartOf(polaroid, [tmp.writePng(quadrantImage(c[0], c[1]))],
            [const CropEdit.skipped()]);
        final out = (await render(cart)).single;
        expect(out.width, out.height,
            reason: 'photo ${c[0]}x${c[1]} white-padded to a square came out '
                '${out.width}x${out.height}');
      }
    });

    test('with the DEFAULT budget a photo larger than the print comes out '
        'with its longest side exactly at the budget, aspect + content kept',
        () async {
      // 3x4 in (3:4) -> default budget 1800 px.
      final mini = packLabelled(PrintCategory.photos, 'Regular Mini');
      expect(printLongSideFor(mini.size), 1800);
      final path = tmp.writePng(quadrantImage(1500, 2000));
      final cart = cartOf(mini, [path, path], [autoCrop, const CropEdit.skipped()]);
      final jpgs = await renderCroppedJpegs(cart);
      for (final j in jpgs) {
        final out = decodeJpg(j);
        expect([out.width, out.height], [1350, 1800]);
        expect(corners(out), layoutAfter(0));
        expect(j.length, lessThan(11 * 1024 * 1024));
      }
    });

    test('the largest print: a 13 MP photo comes out with its longest side '
        'at exactly 4000 px, never more', () async {
      // 9x12 in (3:4) -> default budget 4000 px.
      final path = tmp.writePng(quadrantImage(3150, 4200));
      final cart = cartOf(xl, [path], [autoCrop]);
      final jpgs = await renderCroppedJpegs(cart);
      final out = decodeJpg(jpgs.single);
      expect([out.width, out.height], [3000, 4000]);
      expect(corners(out), layoutAfter(0));
      expect(jpgs.single.length, lessThan(11 * 1024 * 1024));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('count, order and file formats', () {
    final polaroid = packLabelled(PrintCategory.polaroid, 'Vintage Mini');

    test('one JPEG per photo, in cart order, with progress 1..n', () async {
      final order = [Q.red, Q.green, Q.blue, Q.yellow, Q.green, Q.red];
      final paths = [
        for (final q in order) tmp.writePng(solidImage(120, 160, q))
      ];
      final cart = cartOf(polaroid, paths,
          [autoCrop, const CropEdit.skipped(), autoCrop, null, autoCrop, null]);
      final progress = <String>[];
      final jpgs = await renderCroppedJpegs(cart,
          onProgress: (d, t) => progress.add('$d/$t'));
      expect(jpgs.length, order.length);
      for (var i = 0; i < order.length; i++) {
        expect(colourAt(decodeJpg(jpgs[i]), 0.5, 0.5), order[i],
            reason: 'output $i must be input $i');
      }
      expect(progress, ['1/6', '2/6', '3/6', '4/6', '5/6', '6/6']);
    });

    test('JPEG sources, and paths with spaces / # / % in them, are read',
        () async {
      final jpg = tmp.writeJpg(quadrantImage(400, 400));
      final odd = '${tmp.dir.path}/My Photos #1 100% done.png';
      File(odd).writeAsBytesSync(img.encodePng(quadrantImage(400, 400)));
      final cart = cartOf(polaroid, [jpg, odd], [autoCrop, autoCrop]);
      final outs = await render(cart);
      expect(corners(outs[0]), layoutAfter(0));
      expect(corners(outs[1]), layoutAfter(0));
    });

    test('a JPEG with an EXIF orientation prints the way Flutter shows it',
        () async {
      final im = quadrantImage(600, 400)..exif.imageIfd.orientation = 6;
      final bytes = Uint8List.fromList(img.encodeJpg(im, quality: 95));
      expect(img.decodeJpgExif(bytes)?.imageIfd.orientation, 6,
          reason: 'test set-up: the file must carry the orientation tag');
      final path = tmp.writeBytes(bytes, ext: 'jpg');
      final cart = cartOf(polaroid, [path], [const CropEdit.skipped()]);
      final out = (await render(cart)).single;
      // Orientation 6 = display rotated 90 deg clockwise: 400x600 upright.
      expect([out.width, out.height], [600, 600]);
      expectPrintMatchesScreen(out,
          frameW: 600,
          frameH: 600,
          photoW: 600,
          photoH: 400,
          turns: 1,
          scale: 1,
          tx: 0,
          ty: 0,
          grid: 15,
          label: 'exif 6');
    });

    test('transparent PNG areas print WHITE, not black', () async {
      final im = img.Image(width: 400, height: 400, numChannels: 4);
      img.fillRect(im,
          x1: 200,
          y1: 0,
          x2: 399,
          y2: 399,
          color: img.ColorRgba8(220, 30, 30, 255));
      final path = tmp.writePng(im);
      final cart = cartOf(polaroid, [path, path],
          [autoCrop, const CropEdit.skipped()]);
      for (final o in await render(cart)) {
        expect(colourAt(o, 0.25, 0.5), Q.white);
        expect(colourAt(o, 0.75, 0.5), Q.red);
      }
    });

    test('GREY + alpha PNGs (PNG colour type 4: black-and-white stickers, '
        'logos, signatures) also print transparent areas WHITE', () async {
      // 2 bytes per pixel: [luminance, alpha]. Left half fully transparent
      // (0,0), right half opaque mid-grey (100,255).
      const w = 400, h = 400;
      final la = Uint8List(w * h * 2);
      for (var y = 0; y < h; y++) {
        for (var x = w ~/ 2; x < w; x++) {
          la[(y * w + x) * 2] = 100;
          la[(y * w + x) * 2 + 1] = 255;
        }
      }
      final png = img.encodePng(img.Image.fromBytes(
          width: w, height: h, bytes: la.buffer, numChannels: 2));
      expect(png[25], 4, reason: 'test set-up: PNG colour type 4 = grey+alpha');
      final path = tmp.writeBytes(png);
      final cart = cartOf(polaroid, [path, path, path], [
        autoCrop,
        const CropEdit.skipped(),
        const CropEdit.skipped(rotationSteps: 2),
      ]);
      final outs = await render(cart);
      List<int> rgb(img.Image im, double fx, double fy) {
        final p = im.getPixel((fx * im.width).floor(), (fy * im.height).floor());
        return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
      }

      void expectNear(List<int> got, int want, String what) {
        for (final c in got) {
          expect(c, closeTo(want, 6), reason: '$what: got rgb$got');
        }
      }

      for (var i = 0; i < 2; i++) {
        expectNear(rgb(outs[i], 0.25, 0.5), 255,
            'output $i: the transparent half must be white');
        expectNear(rgb(outs[i], 0.75, 0.5), 100,
            'output $i: the opaque half keeps its grey');
      }
      // rotated 180: halves swap
      expectNear(rgb(outs[2], 0.75, 0.5), 255, 'rotated: transparent = white');
      expectNear(rgb(outs[2], 0.25, 0.5), 100, 'rotated: grey');

      // The print-sheet flattener (photo_bytes) shares the rule.
      final flatJpg =
          await flattenResizeEncode(Uint8List.fromList(png), 2000, 90);
      expect(flatJpg, isNotNull);
      final flat = decodeJpg(flatJpg!);
      expectNear(rgb(flat, 0.25, 0.5), 255, 'flattenResizeEncode: white');
      expectNear(rgb(flat, 0.75, 0.5), 100, 'flattenResizeEncode: grey');
    });

    test('grey, palette and 16-bit PNGs and GIFs keep their colours', () async {
      final quad = quadrantImage(400, 400);
      final grey = img.Image(width: 400, height: 400, numChannels: 1);
      img.fillRect(grey,
          x1: 0, y1: 0, x2: 199, y2: 399, color: img.ColorUint8.rgb(40, 40, 40));
      img.fillRect(grey,
          x1: 200,
          y1: 0,
          x2: 399,
          y2: 399,
          color: img.ColorUint8.rgb(220, 220, 220));
      final deep = img.Image(
          width: 400, height: 400, numChannels: 3, format: img.Format.uint16);
      for (final p in deep) {
        final q = qRgb[quadrantAt((p.x + 0.5) / 400, (p.y + 0.5) / 400)]!;
        p
          ..r = q[0] * 257
          ..g = q[1] * 257
          ..b = q[2] * 257;
      }
      final palette = img.quantize(quad, numberOfColors: 8);
      expect(palette.hasPalette, isTrue, reason: 'test set-up');

      final cart = cartOf(polaroid, [
        tmp.writeBytes(img.encodePng(palette)),
        tmp.writeBytes(img.encodePng(deep)),
        tmp.writeBytes(img.encodeGif(quad), ext: 'gif'),
        tmp.writeBytes(img.encodePng(grey)),
      ], [
        autoCrop,
        autoCrop,
        const CropEdit.skipped(),
        autoCrop
      ]);
      final outs = await render(cart);
      expect(corners(outs[0]), layoutAfter(0), reason: 'palette PNG');
      expect(corners(outs[1]), layoutAfter(0), reason: '16-bit PNG');
      expect(corners(outs[2]), layoutAfter(0), reason: 'GIF');
      final g = outs[3];
      final dark = g.getPixel(100, 200);
      final light = g.getPixel(300, 200);
      for (final c in [dark.r, dark.g, dark.b]) {
        expect(c, closeTo(40, 6), reason: 'grey PNG must stay neutral grey');
      }
      for (final c in [light.r, light.g, light.b]) {
        expect(c, closeTo(220, 6), reason: 'grey PNG must stay neutral grey');
      }
    });

    test('a file over the byte budget is re-encoded smaller, same pixels',
        () async {
      // Noise does not compress: a good worst case for the size cap.
      final rnd = math.Random(7);
      final noisy = img.Image(width: 600, height: 600, numChannels: 3);
      for (final p in noisy) {
        p
          ..r = rnd.nextInt(256)
          ..g = rnd.nextInt(256)
          ..b = rnd.nextInt(256);
      }
      final path = tmp.writePng(noisy);
      final cart = cartOf(polaroid, [path], [autoCrop]);
      final full = (await renderCroppedJpegs(cart)).single;
      final capped =
          (await renderCroppedJpegs(cart, maxBytes: full.length ~/ 2)).single;
      expect(capped.length, lessThan(full.length));
      final im = decodeJpg(capped);
      expect([im.width, im.height], [600, 600]);
    });
  });

  group('errors are reported, never a silent drop', () {
    final polaroid = packLabelled(PrintCategory.polaroid, 'Vintage Mini');

    test('no pack / no photos', () async {
      await expectLater(
          renderCroppedJpegs(Cart()),
          throwsA(isA<PhotoExportException>()
              .having((e) => e.message, 'message', contains('pack'))));
      await expectLater(
          renderCroppedJpegs(Cart()..selectPack(polaroid)),
          throwsA(isA<PhotoExportException>()
              .having((e) => e.message, 'message', contains('no photos'))));
    });

    test('a corrupt photo in the middle fails the export and names it',
        () async {
      final good = tmp.writePng(quadrantImage(200, 200));
      final garbage = tmp.writeBytes(
          List<int>.generate(4096, (i) => (i * 37 + 11) & 0xFF),
          ext: 'jpg');
      final cart = cartOf(
          polaroid, [good, garbage, good], [autoCrop, autoCrop, autoCrop]);
      Object? error;
      List<Uint8List>? result;
      try {
        result = await renderCroppedJpegs(cart);
      } catch (e) {
        error = e;
      }
      expect(result, isNull,
          reason: 'a 3-photo order must never come back as 2 files');
      expect(error, isA<PhotoExportException>());
      final msg = (error! as PhotoExportException).message;
      expect(msg, contains('Photo 2'));
      expect(msg.toLowerCase(), contains('replace'));
      expect(error.toString(), msg, reason: 'toString is customer-facing');
    });

    test('a PNG whose data is cut off / zeroed is an error too', () async {
      final png = img.encodePng(quadrantImage(300, 300));
      final headerOnly = tmp.writeBytes(png.sublist(0, 20));
      final cart = cartOf(polaroid, [headerOnly], [autoCrop]);
      await expectLater(
          renderCroppedJpegs(cart),
          throwsA(isA<PhotoExportException>()
              .having((e) => e.message, 'message', contains('Photo 1'))));
    });

    test('a photo that is gone from the device, or empty, is an error',
        () async {
      final missing = '${tmp.dir.path}/deleted_from_gallery.jpg';
      final cart = cartOf(polaroid, [missing], [autoCrop]);
      await expectLater(
          renderCroppedJpegs(cart),
          throwsA(isA<PhotoExportException>().having(
              (e) => e.message, 'message', contains('could not be read'))));

      final empty = tmp.writeBytes(const <int>[], ext: 'jpg');
      final cart2 = cartOf(polaroid, [empty], [autoCrop]);
      await expectLater(
          renderCroppedJpegs(cart2),
          throwsA(isA<PhotoExportException>()
              .having((e) => e.message, 'message', contains('Photo 1'))));
    });
  });
}
