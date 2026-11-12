import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/print_packages.dart';
import '../theme.dart';
import 'polaroid_frame.dart';

/// Renders a photo's ACTUAL print result — the small JPEG produced by
/// `renderCroppedJpegs` — the way it physically prints: a white Polaroid card
/// (the shared [PolaroidFrame]) for Polaroid sizes, a glossy white-bordered
/// print at the print's own aspect for Photo / Snapbook.
///
/// Shared by the preview page AND the cart's "Your selection" grid so the two
/// look identical. [jpg] null = still rendering / unavailable → a neutral
/// placeholder (the caller keeps the tile tappable to re-crop).
class PrintResultView extends StatelessWidget {
  const PrintResultView({
    super.key,
    required this.jpg,
    required this.size,
    this.elevation = 10,
    this.warn = false,
  });

  final Uint8List? jpg;
  final PrintSize size;
  final double elevation;

  /// True when this photo will print with white edges (it doesn't fill the
  /// print shape and hasn't been cropped) — the frame turns red to prompt a crop.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    if (size.hasPolaroidStrip) {
      // The SAME white Polaroid card the packages/preview screens show, so the
      // cart matches exactly. rotationDeg:0 — any tilt is applied by the caller.
      return PolaroidFrame.forSize(
        size: size,
        rotationDeg: 0,
        elevation: elevation,
        child: _image(),
      );
    }
    // Photo / Snapbook: a slim DARK frame hugging the print — NO white mat, so
    // the only white the customer sees is the print's OWN (what actually
    // prints), never a frame border that looks like extra white around it.
    return Center(
      child: AspectRatio(
        aspectRatio: size.imageAspectWxH,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: warn ? AppColors.error : const Color(0xFF26262B),
                width: warn ? 2.5 : 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: elevation + 4,
                offset: Offset(0, elevation / 2),
              ),
              const BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: _image(),
          ),
        ),
      ),
    );
  }

  Widget _image() {
    final bytes = jpg;
    if (bytes == null) {
      return Container(
        color: const Color(0xFFF1EEF8),
        alignment: Alignment.center,
        child: const Icon(Icons.hourglass_bottom_rounded,
            color: AppColors.primary, size: 20),
      );
    }
    // contain, never cover: show the ENTIRE print (incl. its white edges)
    // exactly as it will print — cover would crop the white / content off.
    return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
  }
}
