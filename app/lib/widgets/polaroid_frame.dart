import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/print_packages.dart';

/// A polaroid-style frame: white card with the image positioned in a square
/// area near the top, white border on top + sides, wider white strip below
/// (the polaroid caption area), slight rotation, drop shadow.
///
/// Two ways to use it:
///
/// **1) Bound to a printable polaroid size (preferred):**
/// ```dart
/// PolaroidFrame.forSize(size: pack.size, child: ...)
/// ```
/// All margins come from the [PrintSize] (`widthInches`, `heightInches`,
/// `imageWidthInches`, `imageHeightInches`) so the on-screen preview matches
/// the printed product 1:1.
///
/// **2) Loose mode** (sample art on the home page, where we just want the
/// vibe — no real product behind it):
/// ```dart
/// PolaroidFrame(imageAspect: 1, displayAspect: 3 / 4, child: ...)
/// ```
class PolaroidFrame extends StatelessWidget {
  /// Loose mode: image stretches to the inner width; bottom strip = whatever
  /// space remains after the image + the top/side border (borderWidth in
  /// logical pixels, equal on every side).
  const PolaroidFrame({
    super.key,
    required this.child,
    required this.imageAspect,
    double? displayAspect,
    this.rotationDeg = -2,
    this.borderWidth = 6,
    this.elevation = 6,
  })  : displayAspect = displayAspect ?? imageAspect,
        cardWidthInches = null,
        cardHeightInches = null,
        imageWidthInches = null,
        imageHeightInches = null;

  /// Print-size bound mode: every margin is computed from real inches.
  PolaroidFrame.forSize({
    super.key,
    required PrintSize size,
    required this.child,
    this.rotationDeg = -2,
    this.elevation = 6,
  })  : imageAspect = size.imageAspectWxH,
        displayAspect = size.aspectWxH,
        cardWidthInches = size.widthInches,
        cardHeightInches = size.heightInches,
        imageWidthInches = size.imageWidthInches,
        imageHeightInches = size.imageHeightInches,
        borderWidth = 0; // unused in size-bound mode

  final Widget child;
  final double imageAspect;
  final double displayAspect;
  final double rotationDeg;
  final double borderWidth;
  final double elevation;

  // Only set in size-bound mode.
  final double? cardWidthInches;
  final double? cardHeightInches;
  final double? imageWidthInches;
  final double? imageHeightInches;

  bool get _hasSizeInfo => cardWidthInches != null;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: rotationDeg * math.pi / 180,
      child: AspectRatio(
        aspectRatio: displayAspect,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: elevation,
                offset: Offset(0, elevation / 2),
              ),
            ],
          ),
          child: _hasSizeInfo ? _buildSizeBound() : _buildLoose(),
        ),
      ),
    );
  }

  // ─── Size-bound mode: white card → image positioned by real inches ───
  Widget _buildSizeBound() {
    final cw = cardWidthInches!;
    final ch = cardHeightInches!;
    final iw = imageWidthInches!;
    final ih = imageHeightInches!;
    final sideFrac = ((cw - iw) / 2) / cw;
    final topFrac = sideFrac * (cw / ch); // top margin in inches = side margin
    final imgWFrac = iw / cw;
    final imgHFrac = ih / ch;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = c.maxHeight;
      return Stack(
        children: [
          Positioned(
            left: sideFrac * w,
            top: topFrac * h,
            width: imgWFrac * w,
            height: imgHFrac * h,
            child: ClipRect(child: child),
          ),
        ],
      );
    });
  }

  // ─── Loose mode: pixel-padding border, image fills inner width ───────
  Widget _buildLoose() {
    return Padding(
      padding: EdgeInsets.all(borderWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(aspectRatio: imageAspect, child: child),
          const Expanded(child: SizedBox.shrink()),
        ],
      ),
    );
  }
}
