// END-TO-END "what the customer framed is what prints":
// pumps the REAL CropScreen, drives its InteractiveViewer exactly like a
// pan / pinch would (through the TransformationController), presses the real
// Save button, then runs the real export on the CropEdit the screen stored
// and compares the print with an independent model of what was on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'package:printing_partner/models/cart.dart';
import 'package:printing_partner/models/print_packages.dart';
import 'package:printing_partner/screens/crop_screen.dart';
import 'package:printing_partner/services/photo_export.dart';

import 'support/screen_model.dart';
import 'support/test_images.dart';

PrintPack packLabelled(PrintCategory c, String label) =>
    allPacks.firstWhere((p) => p.size.category == c && p.size.label == label);

/// view = scale * scene + (tx, ty)   (column-major Matrix4). The z axis is
/// scaled too, exactly as InteractiveViewer's pinch and the screen's own
/// +/- buttons build their matrices.
Matrix4 viewMatrix(double scale, double tx, double ty) => Matrix4(
      scale, 0, 0, 0, //
      0, scale, 0, 0, //
      0, 0, scale, 0, //
      tx, ty, 0, 1,
    );

class Shot {
  Shot(this.out, this.edit, this.frame, this.turnsOnScreen);
  final img.Image out;
  final CropEdit edit;
  final Size frame;
  final int turnsOnScreen;
}

void main() {
  late TempPhotos tmp;
  setUpAll(() => tmp = TempPhotos());
  tearDownAll(() => tmp.dispose());

  /// Opens the crop screen on a one-photo cart, optionally lets the size
  /// probe finish, taps Rotate [rotateTaps] times, applies the viewer matrix
  /// built by [matrixFor] (given the frame size), presses Save and exports.
  Future<Shot> frameAndPrint(
    WidgetTester tester, {
    required PrintPack pack,
    required int photoW,
    required int photoH,
    required Matrix4 Function(Size frame) matrixFor,
    int rotateTaps = 0,
    bool letProbeFinish = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final path = tmp.writePng(quadrantImage(photoW, photoH));
    final cart = Cart()
      ..selectPack(pack)
      ..addPhotos([path]);
    final id = cart.items.single.id;

    final router = GoRouter(
      initialLocation: '/crop',
      routes: [
        GoRoute(path: '/crop', builder: (_, _) => const CropScreen()),
        GoRoute(
            path: '/cart',
            builder: (_, _) => const Scaffold(body: Text('CART PAGE'))),
        GoRoute(
            path: '/preview',
            builder: (_, _) => const Scaffold(body: Text('PREVIEW PAGE'))),
        GoRoute(
            path: '/photos',
            builder: (_, _) => const Scaffold(body: Text('PHOTOS PAGE'))),
      ],
    );
    await tester.pumpWidget(ChangeNotifierProvider<Cart>.value(
      value: cart,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    if (letProbeFinish) {
      // The orientation probe is real file I/O + a real codec, several
      // awaits deep: give each step real time, then flush its continuation.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump();
      }
    }
    for (var i = 0; i < rotateTaps; i++) {
      await tester.tap(find.byIcon(Icons.rotate_right_rounded));
      await tester.pump();
    }

    final viewerFinder = find.byType(InteractiveViewer);
    expect(viewerFinder, findsOneWidget);
    final frame = tester.getSize(viewerFinder);
    // The frame must have the print's image aspect.
    expect(frame.width / frame.height,
        closeTo(pack.size.imageAspectWxH, 0.01));
    final turnsOnScreen = tester
        .widget<RotatedBox>(find.descendant(
            of: viewerFinder, matching: find.byType(RotatedBox)))
        .quarterTurns;

    final viewer = tester.widget<InteractiveViewer>(viewerFinder);
    viewer.transformationController!.value = matrixFor(frame);
    await tester.pump();

    await tester.tap(find.text('Save crop'));
    await tester.pump();
    await tester.pump();
    expect(find.text('PREVIEW PAGE'), findsOneWidget,
        reason: 'Save on the last photo goes to the print-preview page');

    final edit = cart.cropFor(id);
    expect(edit, isNotNull, reason: 'Save must record a crop for the photo');
    expect(edit!.skipped, isFalse);
    expect(edit.rotationSteps, turnsOnScreen,
        reason: 'the saved rotation is the one that was on screen');

    final jpgs = await tester.runAsync(() => renderCroppedJpegs(cart));
    expect(jpgs, isNotNull);
    expect(jpgs!.length, 1);
    final out = decodeJpg(jpgs.single);
    expect(aspectWithin1px(out.width, out.height, pack.size.imageAspectWxH),
        isTrue,
        reason: 'print ${out.width}x${out.height} must have the pack image '
            'aspect ${pack.size.imageAspectWxH}');
    return Shot(out, edit, frame, turnsOnScreen);
  }

  final polaroid = packLabelled(PrintCategory.polaroid, 'Vintage Mini'); // 1:1
  final regular = packLabelled(PrintCategory.photos, 'Regular'); // 4x6
  final xl = packLabelled(PrintCategory.photos, 'Regular Xtra-Large'); // 9x12

  for (final probe in [false, true]) {
    final tag = probe ? 'size probe finished' : 'Save before the size probe';

    testWidgets(
        '2x zoom panned to the TOP-LEFT corner prints that corner ($tag)',
        (tester) async {
      final s = await frameAndPrint(
        tester,
        pack: polaroid,
        photoW: 400,
        photoH: 400,
        letProbeFinish: probe,
        matrixFor: (_) => viewMatrix(2, 0, 0),
      );
      final seen = expectPrintMatchesScreen(s.out,
          frameW: s.frame.width,
          frameH: s.frame.height,
          photoW: 400,
          photoH: 400,
          turns: s.turnsOnScreen,
          scale: 2,
          tx: 0,
          ty: 0,
          label: 'top-left 2x');
      expect(seen, {Q.red}, reason: 'only the top-left quadrant is framed');
      // Half the photo in each direction, never upscaled.
      expect(s.out.width, inInclusiveRange(199, 201));
      expect(s.out.height, inInclusiveRange(199, 201));
    });

    testWidgets(
        '2x zoom panned to the BOTTOM-RIGHT corner prints that corner ($tag)',
        (tester) async {
      late Size f;
      final s = await frameAndPrint(
        tester,
        pack: polaroid,
        photoW: 400,
        photoH: 400,
        letProbeFinish: probe,
        matrixFor: (frame) {
          f = frame;
          return viewMatrix(2, -frame.width, -frame.height);
        },
      );
      final seen = expectPrintMatchesScreen(s.out,
          frameW: f.width,
          frameH: f.height,
          photoW: 400,
          photoH: 400,
          turns: s.turnsOnScreen,
          scale: 2,
          tx: -f.width,
          ty: -f.height,
          label: 'bottom-right 2x');
      expect(seen, {Q.yellow});
    });

    testWidgets(
        'untouched Save (identity view) prints the letterboxed photo the '
        'customer saw, not a centre-crop ($tag)', (tester) async {
      // Landscape photo in a portrait 4x6 frame. The screen may auto-rotate
      // it once the probe finishes; either way the print must match.
      final s = await frameAndPrint(
        tester,
        pack: regular,
        photoW: 600,
        photoH: 300,
        letProbeFinish: probe,
        matrixFor: (_) => viewMatrix(1, 0, 0),
      );
      final seen = expectPrintMatchesScreen(s.out,
          frameW: s.frame.width,
          frameH: s.frame.height,
          photoW: 600,
          photoH: 300,
          turns: s.turnsOnScreen,
          scale: 1,
          tx: 0,
          ty: 0,
          label: 'identity');
      expect(seen, containsAll([Q.red, Q.green, Q.blue, Q.yellow, Q.white]),
          reason: 'whole photo + white bars');
    });

    testWidgets(
        'off-centre pan at 3x on a non-square photo prints the framed region '
        '($tag)', (tester) async {
      late Size f;
      late double tx, ty;
      final s = await frameAndPrint(
        tester,
        pack: xl,
        photoW: 500,
        photoH: 700,
        letProbeFinish: probe,
        matrixFor: (frame) {
          f = frame;
          // Look at the region around 30% / 62% of the frame.
          tx = -(0.30 * frame.width * 3 - frame.width / 2);
          ty = -(0.62 * frame.height * 3 - frame.height / 2);
          return viewMatrix(3, tx, ty);
        },
      );
      expectPrintMatchesScreen(s.out,
          frameW: f.width,
          frameH: f.height,
          photoW: 500,
          photoH: 700,
          turns: s.turnsOnScreen,
          scale: 3,
          tx: tx,
          ty: ty,
          label: 'off-centre 3x');
    });

    testWidgets('zoomed OUT to 0.5x prints the small photo on white ($tag)',
        (tester) async {
      late Size f;
      final s = await frameAndPrint(
        tester,
        pack: regular,
        photoW: 400,
        photoH: 600,
        letProbeFinish: probe,
        matrixFor: (frame) {
          f = frame;
          return viewMatrix(0.5, frame.width / 4, frame.height / 4);
        },
      );
      final seen = expectPrintMatchesScreen(s.out,
          frameW: f.width,
          frameH: f.height,
          photoW: 400,
          photoH: 600,
          turns: s.turnsOnScreen,
          scale: 0.5,
          tx: f.width / 4,
          ty: f.height / 4,
          label: 'zoom out');
      expect(seen, containsAll([Q.red, Q.green, Q.blue, Q.yellow, Q.white]));
    });
  }

  for (var taps = 1; taps <= 3; taps++) {
    testWidgets(
        'Rotate tapped ${taps}x then zoomed to the top-left corner: the print '
        'shows what the rotated screen showed (clockwise)', (tester) async {
      final s = await frameAndPrint(
        tester,
        pack: polaroid,
        photoW: 400,
        photoH: 400,
        rotateTaps: taps,
        matrixFor: (_) => viewMatrix(2, 0, 0),
      );
      expect(s.turnsOnScreen, taps,
          reason: 'each tap is one clockwise quarter turn (RotatedBox)');
      final seen = expectPrintMatchesScreen(s.out,
          frameW: s.frame.width,
          frameH: s.frame.height,
          photoW: 400,
          photoH: 400,
          turns: taps,
          scale: 2,
          tx: 0,
          ty: 0,
          label: 'rotate x$taps');
      // Clockwise: after 1 turn the old bottom-left (blue) is top-left, after
      // 2 the old bottom-right (yellow), after 3 the old top-right (green).
      expect(seen, {
        [Q.blue, Q.yellow, Q.green][taps - 1]
      });
    });
  }
}
