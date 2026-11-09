import 'package:flutter/material.dart';

/// Web thumbnail. image_picker returns blob: URLs on web, which
/// `Image.network` can load; `cacheWidth` wraps the provider in a
/// [ResizeImage] so the browser-decoded bitmap is down-scaled before it is
/// uploaded as a texture.
Widget buildThumb(
  String path,
  double? width,
  double? height,
  BoxFit fit,
  int cacheWidth,
  String? semanticLabel,
) {
  return Image.network(
    path,
    width: width,
    height: height,
    fit: fit,
    cacheWidth: cacheWidth,
    filterQuality: FilterQuality.medium,
    gaplessPlayback: true,
    semanticLabel: semanticLabel,
    errorBuilder: (context, error, stackTrace) => const ColoredBox(
      color: Color(0xFFF3F4F6),
      child: Center(
        child: Icon(Icons.broken_image_outlined, color: Color(0xFF6B7280)),
      ),
    ),
  );
}
