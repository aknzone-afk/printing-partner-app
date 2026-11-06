import 'package:flutter/material.dart';

/// Brand palette for the Printing Partner logo (matches branding/ masters).
class _PPBrand {
  static const coralTop = Color(0xFFFF8D6D);
  static const coralBottom = Color(0xFFFF4E6D);
  static const skyTop = Color(0xFF87CEFA);
  static const skyBottom = Color(0xFFE0F6FF);
  static const sun = Color(0xFFFFD166);
  static const hillBack = Color(0xFF7CB069);
  static const hillFront = Color(0xFF5C9454);
}

/// The "P mark" — the letter P built from a polaroid print, drawn as vector
/// so it stays crisp at every size (app bar, splash, watermark).
class PPLogoMark extends StatelessWidget {
  const PPLogoMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size * (94 / 128), size),
      painter: _PPMarkPainter(),
    );
  }
}

class _PPMarkPainter extends CustomPainter {
  // Design space taken from branding/B-p-monogram/mark.svg:
  // P path spans x 34..128, y 12..140 (94 × 128 units).
  static const _w = 94.0;
  static const _h = 128.0;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / _h;
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-34, -12);

    // Letter body: stem + bowl.
    final p = Path()
      ..moveTo(34, 12)
      ..lineTo(82, 12)
      ..arcToPoint(const Offset(82, 104),
          radius: const Radius.circular(46), clockwise: true)
      ..lineTo(58, 104)
      ..lineTo(58, 140)
      ..lineTo(34, 140)
      ..close();
    final coral = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_PPBrand.coralTop, _PPBrand.coralBottom],
      ).createShader(const Rect.fromLTWH(34, 12, _w, _h));
    canvas.drawPath(p, coral);

    // Polaroid frame inside the bowl.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(60, 34, 46, 56), const Radius.circular(5)),
      Paint()..color = Colors.white,
    );

    // Photo window with the brand landscape.
    const win = Rect.fromLTWH(66, 40, 34, 34);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(win, const Radius.circular(3)));
    canvas.drawRect(
      win,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_PPBrand.skyTop, _PPBrand.skyBottom],
        ).createShader(win),
    );
    canvas.drawCircle(
        const Offset(91, 49), 4.5, Paint()..color = _PPBrand.sun);
    canvas.drawOval(Rect.fromCenter(center: const Offset(73, 74), width: 32, height: 20),
        Paint()..color = _PPBrand.hillBack);
    canvas.drawOval(Rect.fromCenter(center: const Offset(94, 77), width: 34, height: 22),
        Paint()..color = _PPBrand.hillFront);
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Horizontal lockup: P mark + "Printing Partner" wordmark. Sized by [height];
/// text color follows the theme unless [textColor] is given ("Partner" is
/// always brand coral).
class PPLogoLockup extends StatelessWidget {
  const PPLogoLockup({super.key, this.height = 30, this.textColor});
  final double height;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final ink = textColor ??
        Theme.of(context).textTheme.titleLarge?.color ??
        const Color(0xFF2B2B2B);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        PPLogoMark(size: height),
        SizedBox(width: height * 0.32),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: 'Printing ', style: TextStyle(color: ink)),
            const TextSpan(
                text: 'Partner',
                style: TextStyle(color: _PPBrand.coralBottom)),
          ]),
          style: TextStyle(
            fontSize: height * 0.62,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}
