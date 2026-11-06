import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'photo_thumb_io.dart' if (dart.library.html) 'photo_thumb_web.dart'
    as platform;

class PhotoThumb extends StatelessWidget {
  const PhotoThumb({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return platform.buildThumb(path, width, height, fit);
    }
    return platform.buildThumb(path, width, height, fit);
  }
}
