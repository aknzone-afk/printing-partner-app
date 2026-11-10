// Shared helpers for the photo-export tests: synthetic 4-quadrant photos,
// temp files, and an INDEPENDENT forward model of what the crop screen shows.
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The four quadrant colours of the synthetic test photo, plus white (the
/// crop frame's background / padding).
enum Q { red, green, blue, yellow, white }

const Map<Q, List<int>> qRgb = {
  Q.red: [220, 30, 30],
  Q.green: [30, 170, 30],
  Q.blue: [30, 30, 220],
  Q.yellow: [235, 220, 30],
  Q.white: [255, 255, 255],
};

/// Upright layout of the test photo: top-left RED, top-right GREEN,
/// bottom-left BLUE, bottom-right YELLOW.
Q quadrantAt(double x, double y) {
  if (y < 0.5) return x < 0.5 ? Q.red : Q.green;
  return x < 0.5 ? Q.blue : Q.yellow;
}

img.Image quadrantImage(int w, int h, {int channels = 3}) {
  final im = img.Image(width: w, height: h, numChannels: channels);
  void rect(int x1, int y1, int x2, int y2, Q q) {
    final c = qRgb[q]!;
    img.fillRect(im,
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        color: img.ColorRgb8(c[0], c[1], c[2]));
  }

  final mx = w ~/ 2;
  final my = h ~/ 2;
  rect(0, 0, mx - 1, my - 1, Q.red);
  rect(mx, 0, w - 1, my - 1, Q.green);
  rect(0, my, mx - 1, h - 1, Q.blue);
  rect(mx, my, w - 1, h - 1, Q.yellow);
  return im;
}

img.Image solidImage(int w, int h, Q q) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  final c = qRgb[q]!;
  img.fill(im, color: img.ColorRgb8(c[0], c[1], c[2]));
  return im;
}

/// A scratch directory that is deleted when the test file finishes.
///
/// It is addressed by a RELATIVE, forward-slash path (under the git-ignored
/// `build/`): on the phones the app runs on, picked photos are POSIX paths
/// (`/var/mobile/...`), which the export treats as local files. An absolute
/// Windows path (`C:\...`) parses as a URI with scheme `c`, which the export
/// would try to fetch over HTTP - a dev-host artefact, not an app path.
class TempPhotos {
  TempPhotos() : dir = _make();
  final Directory dir;
  int _n = 0;

  static Directory _make() {
    final base = Directory('build/test_tmp')..createSync(recursive: true);
    final made = base.createTempSync('pp_');
    final name = made.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    return Directory('build/test_tmp/$name');
  }

  String writeBytes(List<int> bytes, {String ext = 'png'}) {
    final f = File('${dir.path}/p${_n++}.$ext');
    f.writeAsBytesSync(bytes, flush: true);
    return f.path;
  }

  String writePng(img.Image im) => writeBytes(img.encodePng(im, level: 1));
  String writeJpg(img.Image im, {int quality = 95}) =>
      writeBytes(img.encodeJpg(im, quality: quality), ext: 'jpg');

  void dispose() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

img.Image decodeJpg(Uint8List bytes) {
  // JPEG magic: the export must hand the backend real JPEG files.
  if (bytes.length < 3 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw StateError('export output is not a JPEG');
  }
  final im = img.decodeJpg(bytes);
  if (im == null) throw StateError('export output did not decode');
  return im;
}

/// Nearest named colour of the pixel at fractional position ([fx], [fy]) of
/// [im] (JPEG is lossy, so match by distance, not equality).
Q colourAt(img.Image im, double fx, double fy) {
  final x = (fx * im.width).floor().clamp(0, im.width - 1);
  final y = (fy * im.height).floor().clamp(0, im.height - 1);
  final p = im.getPixel(x, y);
  Q best = Q.white;
  var bestD = 1 << 30;
  for (final e in qRgb.entries) {
    final dr = p.r.toInt() - e.value[0];
    final dg = p.g.toInt() - e.value[1];
    final db = p.b.toInt() - e.value[2];
    final d = dr * dr + dg * dg + db * db;
    if (d < bestD) {
      bestD = d;
      best = e.key;
    }
  }
  return best;
}

/// |W/H - aspect| within one pixel on either side.
bool aspectWithin1px(int w, int h, double aspect) =>
    (w - h * aspect).abs() <= 1.0 + 1e-9 ||
    (h - w / aspect).abs() <= 1.0 + 1e-9;

/// INDEPENDENT forward model of the crop screen, point by point.
///
/// The screen draws a white frame of [frameW]×[frameH]; inside it an
/// InteractiveViewer (matrix: view = [scale]·scene + ([tx],[ty])) whose child
/// is `RotatedBox(quarterTurns: turns)` around the photo shown
/// `BoxFit.contain`. For the frame point at fraction ([px],[py]) this returns
/// the colour the customer sees there — or null when the point is too close
/// (< [guard] of a side) to a colour boundary to be judged after JPEG
/// compression + pixel rounding.
///
/// [photoW]×[photoH] is the UPRIGHT (unrotated) quadrant test photo.
Q? screenColourAt({
  required double px,
  required double py,
  required double frameW,
  required double frameH,
  required int photoW,
  required int photoH,
  required int turns,
  required double scale,
  required double tx,
  required double ty,
  double guard = 0.035,
}) {
  final odd = turns.isOdd;
  final rw = (odd ? photoH : photoW).toDouble();
  final rh = (odd ? photoW : photoH).toDouble();
  // Contain-fit of the rotated photo in the frame.
  final k = (frameW / rw) < (frameH / rh) ? frameW / rw : frameH / rh;
  final bw = rw * k;
  final bh = rh * k;
  final ox = (frameW - bw) / 2;
  final oy = (frameH - bh) / 2;
  // Frame point -> scene point (inverse of the viewer matrix).
  final sx = (px * frameW - tx) / scale;
  final sy = (py * frameH - ty) / scale;
  // Scene point -> rotated-photo normalised coordinates.
  final u = (sx - ox) / bw;
  final v = (sy - oy) / bh;
  // Guard band, measured in FRAME fractions, around every boundary.
  final gu = guard * frameW / (bw * scale);
  final gv = guard * frameH / (bh * scale);
  bool near(double a, double edge, double g) => (a - edge).abs() < g;
  if (near(u, 0, gu) || near(u, 1, gu) || near(v, 0, gv) || near(v, 1, gv)) {
    return null;
  }
  if (u < 0 || u > 1 || v < 0 || v > 1) return Q.white;
  if (near(u, 0.5, gu) || near(v, 0.5, gv)) return null;
  // Rotated (u,v) -> upright photo (x,y) for `turns` CLOCKWISE quarter turns.
  double x, y;
  switch (((turns % 4) + 4) % 4) {
    case 1:
      x = v;
      y = 1 - u;
      break;
    case 2:
      x = 1 - u;
      y = 1 - v;
      break;
    case 3:
      x = 1 - v;
      y = u;
      break;
    default:
      x = u;
      y = v;
  }
  return quadrantAt(x, y);
}
