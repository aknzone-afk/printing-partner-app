import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'test_images.dart';

/// Asserts that the exported print [out] shows, at every judgeable point of a
/// [grid]x[grid] lattice, exactly the colour the crop screen showed the
/// customer at the same place of the crop frame (see [screenColourAt]).
/// Returns the set of colours that were checked, so callers can also assert
/// WHICH part of the photo ended up in the print.
Set<Q> expectPrintMatchesScreen(
  img.Image out, {
  required double frameW,
  required double frameH,
  required int photoW,
  required int photoH,
  required int turns,
  required double scale,
  required double tx,
  required double ty,
  int grid = 9,
  double guard = 0.035,
  int? minJudged,
  String label = '',
}) {
  final seen = <Q>{};
  var judged = 0;
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
        guard: guard,
      );
      if (want == null) continue;
      judged++;
      seen.add(want);
      final got = colourAt(out, px, py);
      if (got != want) {
        problems.add('(${px.toStringAsFixed(2)},${py.toStringAsFixed(2)}): '
            'screen ${want.name}, print ${got.name}');
      }
    }
  }
  expect(judged, greaterThan(minJudged ?? grid * grid ~/ 3),
      reason: '$label: too few judgeable sample points ($judged)');
  expect(problems, isEmpty,
      reason: '$label: print (${out.width}x${out.height}) differs from what '
          'the crop screen showed (frame ${frameW}x$frameH, photo '
          '${photoW}x$photoH, turns $turns, scale $scale, t=($tx,$ty))');
  return seen;
}
