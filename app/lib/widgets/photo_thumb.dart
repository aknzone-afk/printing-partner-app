import 'package:flutter/material.dart';

import 'photo_thumb_io.dart'
    if (dart.library.html) 'photo_thumb_web.dart'
    as platform;

/// Thumbnail of a picked photo (filesystem path on iOS/Android, blob: URL on
/// web).
///
/// The image is decoded DOWN-SCALED, never at full resolution: the decode
/// width is ~2x the physical pixels the widget occupies (quantised to 64-px
/// steps so a 1-px layout jitter does not trigger a re-decode), capped at
/// [maxDecodeWidth]. A 12 MP gallery photo decoded at full size is ~48 MB of
/// texture; a 3-column grid of 20 such photos blew the memory budget and
/// stuttered on scroll. Under the hood `Image.file` / `Image.network` wrap the
/// provider in a [ResizeImage] when `cacheWidth` is given.
class PhotoThumb extends StatelessWidget {
  const PhotoThumb({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.semanticLabel = 'Photo',
  });

  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Explicit decode width in physical pixels. When null it is derived from
  /// the layout width and the device pixel ratio (see [decodeWidthFor]).
  final int? cacheWidth;

  /// Read out by screen readers; pass something specific (e.g. "Photo 3 of
  /// 12") when the caller knows it.
  final String? semanticLabel;

  /// Largest decode width we ever ask for. A full-width crop viewer on a 3x
  /// phone lands here (~2 MP), which is plenty for a 6x pinch-zoom preview.
  static const int maxDecodeWidth = 2048;
  static const int minDecodeWidth = 128;
  static const int _step = 64;

  /// ~2x the physical pixels of [logicalWidth], rounded up to a 64-px step and
  /// clamped to [minDecodeWidth]..[maxDecodeWidth].
  static int decodeWidthFor(double logicalWidth, double devicePixelRatio) {
    if (!logicalWidth.isFinite || logicalWidth <= 0) return maxDecodeWidth;
    final px = logicalWidth * devicePixelRatio * 2;
    final quantised = (px / _step).ceil() * _step;
    return quantised.clamp(minDecodeWidth, maxDecodeWidth);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final logical =
            width ??
            (constraints.hasBoundedWidth
                ? constraints.maxWidth
                : double.infinity);
        final decodeWidth = cacheWidth ?? decodeWidthFor(logical, dpr);
        return platform.buildThumb(
          path,
          width,
          height,
          fit,
          decodeWidth,
          semanticLabel,
        );
      },
    );
  }
}
