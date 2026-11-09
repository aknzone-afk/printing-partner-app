import 'dart:io';

import 'package:flutter/material.dart';

/// Native thumbnail. `cacheWidth` makes `Image.file` wrap the [FileImage] in a
/// [ResizeImage], so the JPEG is decoded down-scaled instead of at full
/// resolution (a 12 MP photo decoded for a 110-dp grid cell used to cost
/// ~48 MB of texture memory per thumb).
Widget buildThumb(
  String path,
  double? width,
  double? height,
  BoxFit fit,
  int cacheWidth,
  String? semanticLabel,
) {
  return Image.file(
    File(path),
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
