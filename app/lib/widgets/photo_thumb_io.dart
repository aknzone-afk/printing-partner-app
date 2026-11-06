import 'dart:io';

import 'package:flutter/material.dart';

Widget buildThumb(String path, double? width, double? height, BoxFit fit) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
  );
}
