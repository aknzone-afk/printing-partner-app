import 'package:flutter/material.dart';

Widget buildThumb(String path, double? width, double? height, BoxFit fit) {
  // On web, image_picker returns blob: URLs that can be loaded with Image.network.
  return Image.network(
    path,
    width: width,
    height: height,
    fit: fit,
  );
}
