enum PrintCategory {
  photos(slug: 'photos', title: 'Photo', unit: 'snaps'),
  polaroid(slug: 'polaroid', title: 'Polaroid', unit: 'snaps'),
  snapbook(slug: 'snapbook', title: 'Snapbook', unit: 'pages');

  const PrintCategory(
      {required this.slug, required this.title, required this.unit});
  final String slug;
  final String title;
  final String unit;
}

class PrintSize {
  const PrintSize({
    required this.category,
    required this.label,
    required this.widthInches,
    required this.heightInches,
    double? imageWidthInches,
    double? imageHeightInches,
  })  : imageWidthInches = imageWidthInches ?? widthInches,
        imageHeightInches = imageHeightInches ?? heightInches;

  final PrintCategory category;
  final String label;

  /// Physical printed dimensions in inches (width × height).
  /// For Polaroid 3×3: 3 × 4 (square photo + 1" white strip below).
  /// For Photos 4×6: 4 × 6 (edge to edge).
  final double widthInches;
  final double heightInches;

  /// Image area dimensions (where the photo actually prints).
  /// For Polaroid 3×3: 3 × 3. For Photos 4×6: 4 × 6.
  final double imageWidthInches;
  final double imageHeightInches;

  String get dimensions => '${_dim(widthInches)} × ${_dim(heightInches)} inches';
  double get aspectWxH => widthInches / heightInches;
  double get imageAspectWxH => imageWidthInches / imageHeightInches;
  bool get hasPolaroidStrip =>
      imageWidthInches != widthInches || imageHeightInches != heightInches;

  /// Polaroid layout margins (inches). Image is centered horizontally with
  /// equal side margins; top margin equals the side margin; the remaining
  /// space below the image is the white caption strip.
  double get sideMarginInches => (widthInches - imageWidthInches) / 2;
  double get topMarginInches => sideMarginInches;
  double get bottomStripInches =>
      heightInches - topMarginInches - imageHeightInches;

  /// How many of this print fit on a master sheet of [sheetW] × [sheetH]
  /// inches. Tries both orientations and returns the denser fit. For
  /// polaroids, the image inside the cell is rotated 90° CCW at render time
  /// so the printed product still reads as portrait after cutting.
  int perSheetOn(double sheetW, double sheetH) {
    int fit(double pw, double ph) {
      if (pw > sheetW || ph > sheetH) return 0;
      return (sheetW ~/ pw) * (sheetH ~/ ph);
    }
    final a = fit(widthInches, heightInches);
    final b = fit(heightInches, widthInches);
    return a > b ? a : b;
  }

  /// How many fit on the standard 12×18 master sheet we print on.
  int get perSheet => perSheetOn(12, 18);

  static String _dim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class PrintPack {
  const PrintPack({
    required this.size,
    required this.priceInPaise,
    required this.snapCount,
  });

  final PrintSize size;
  final int priceInPaise;
  final int snapCount;

  String get priceLabel => '₹${(priceInPaise / 100).toStringAsFixed(0)}';
  String get countLabel => '$snapCount ${size.category.unit}';
  String get perUnitLabel {
    final unit = size.category.unit;
    final singular = unit.endsWith('s') ? unit.substring(0, unit.length - 1) : unit;
    return '₹${(priceInPaise / snapCount / 100).toStringAsFixed(2)}/$singular';
  }

  /// Number of 12×18 master sheets the merchant prints for this pack.
  int get sheetsNeeded {
    final per = size.perSheet;
    if (per <= 0) return 0;
    return (snapCount / per).ceil();
  }

  String get sheetsLabel =>
      '$sheetsNeeded sheet${sheetsNeeded == 1 ? '' : 's'}';
}

// ─── Photo sizes ────────────────────────────────────────────────────
// perSheet auto-computed by PrintSize.perSheet from physical dimensions.
const _photoRegularMini = PrintSize(
  category: PrintCategory.photos,
  label: 'Regular Mini',
  widthInches: 3,
  heightInches: 4,
);
const _photoClassicMini = PrintSize(
  category: PrintCategory.photos,
  label: 'Classic Mini',
  widthInches: 4,
  heightInches: 4.5,
);
const _photoRegular = PrintSize(
  category: PrintCategory.photos,
  label: 'Regular',
  widthInches: 4,
  heightInches: 6,
);
const _photoClassicLarge = PrintSize(
  category: PrintCategory.photos,
  label: 'Classic Large',
  widthInches: 6,
  heightInches: 6,
);
const _photoRegularLarge = PrintSize(
  category: PrintCategory.photos,
  label: 'Regular Large',
  widthInches: 6,
  heightInches: 9,
);
const _photoRegularXL = PrintSize(
  category: PrintCategory.photos,
  label: 'Regular Xtra-Large',
  widthInches: 9,
  heightInches: 12,
);

// ─── Polaroid sizes ─────────────────────────────────────────────────
// Polaroid physical print = square image area + white strip at bottom.
// Polaroid card → square image area with white border on top + both sides
// and a wider white strip below for the polaroid caption look.
//   3 × 4    card  →  2.7 × 2.7 image  (0.15" side+top margin, 1.15" bottom strip)
//   4 × 4.5  card  →  3.7 × 3.7 image  (0.15" side+top margin, 0.65" bottom strip)
//   5 × 6    card  →  4.6 × 4.6 image  (0.20" side+top margin, 1.20" bottom strip)
const _polaroidVintageMini = PrintSize(
  category: PrintCategory.polaroid,
  label: 'Vintage Mini',
  widthInches: 3,
  heightInches: 4,
  imageWidthInches: 2.7,
  imageHeightInches: 2.7,
);
const _polaroidVintage = PrintSize(
  category: PrintCategory.polaroid,
  label: 'Vintage',
  widthInches: 4,
  heightInches: 4.5,
  imageWidthInches: 3.55,
  imageHeightInches: 3.55,
);
const _polaroidVintageLarge = PrintSize(
  category: PrintCategory.polaroid,
  label: 'Vintage Large',
  widthInches: 5.7,
  heightInches: 6,
  imageWidthInches: 5.1,
  imageHeightInches: 5.1,
);

// ─── Snapbook sizes ─────────────────────────────────────────────────
// Snapbook is bound as a book — sheet packing is "pages on the printer
// sheet" before binding. Same packing as plain photos of the same size.
const _snapbook4x6 = PrintSize(
  category: PrintCategory.snapbook,
  label: '4 × 6 Snapbook',
  widthInches: 4,
  heightInches: 6,
);
const _snapbook6x6 = PrintSize(
  category: PrintCategory.snapbook,
  label: '6 × 6 Snapbook',
  widthInches: 6,
  heightInches: 6,
);
const _snapbook6x9 = PrintSize(
  category: PrintCategory.snapbook,
  label: '6 × 9 Snapbook',
  widthInches: 6,
  heightInches: 9,
);

// ─── All packs ──────────────────────────────────────────────────────
// Note: every pack price has +₹75 (7500 paise) baked in over the original
// vendor list — see commit history if you need the raw vendor prices.
const allPacks = <PrintPack>[
  // Photos: 3×4 Regular Mini
  PrintPack(size: _photoRegularMini, priceInPaise: 15000, snapCount: 18),
  PrintPack(size: _photoRegularMini, priceInPaise: 17500, snapCount: 36),
  PrintPack(size: _photoRegularMini, priceInPaise: 20000, snapCount: 54),
  // Photos: 4×4.5 Classic Mini
  PrintPack(size: _photoClassicMini, priceInPaise: 15000, snapCount: 12),
  PrintPack(size: _photoClassicMini, priceInPaise: 17500, snapCount: 24),
  PrintPack(size: _photoClassicMini, priceInPaise: 20000, snapCount: 36),
  // Photos: 4×6 Regular
  PrintPack(size: _photoRegular, priceInPaise: 17500, snapCount: 18),
  PrintPack(size: _photoRegular, priceInPaise: 20000, snapCount: 27),
  PrintPack(size: _photoRegular, priceInPaise: 22500, snapCount: 36),
  // Photos: 6×6 Classic Large
  PrintPack(size: _photoClassicLarge, priceInPaise: 17500, snapCount: 12),
  PrintPack(size: _photoClassicLarge, priceInPaise: 20000, snapCount: 18),
  PrintPack(size: _photoClassicLarge, priceInPaise: 22500, snapCount: 24),
  // Photos: 6×9 Regular Large
  PrintPack(size: _photoRegularLarge, priceInPaise: 17500, snapCount: 8),
  PrintPack(size: _photoRegularLarge, priceInPaise: 20000, snapCount: 12),
  PrintPack(size: _photoRegularLarge, priceInPaise: 22500, snapCount: 16),
  PrintPack(size: _photoRegularLarge, priceInPaise: 27500, snapCount: 24),
  // Photos: 9×12 Regular Xtra-Large
  PrintPack(size: _photoRegularXL, priceInPaise: 20000, snapCount: 6),
  PrintPack(size: _photoRegularXL, priceInPaise: 22500, snapCount: 8),
  PrintPack(size: _photoRegularXL, priceInPaise: 27500, snapCount: 10),

  // Polaroid: 3×3 Vintage Mini
  PrintPack(size: _polaroidVintageMini, priceInPaise: 15000, snapCount: 18),
  PrintPack(size: _polaroidVintageMini, priceInPaise: 17500, snapCount: 36),
  PrintPack(size: _polaroidVintageMini, priceInPaise: 20000, snapCount: 54),
  // Polaroid: 4×4 Vintage
  PrintPack(size: _polaroidVintage, priceInPaise: 15000, snapCount: 12),
  PrintPack(size: _polaroidVintage, priceInPaise: 17500, snapCount: 24),
  PrintPack(size: _polaroidVintage, priceInPaise: 20000, snapCount: 36),
  // Polaroid: 5×5 Vintage Large
  PrintPack(size: _polaroidVintageLarge, priceInPaise: 17500, snapCount: 12),
  PrintPack(size: _polaroidVintageLarge, priceInPaise: 20000, snapCount: 18),
  PrintPack(size: _polaroidVintageLarge, priceInPaise: 22500, snapCount: 24),

  // Snapbook (₹226 + ₹75 = ₹301 each, page count varies by size)
  PrintPack(size: _snapbook4x6, priceInPaise: 30100, snapCount: 36),
  PrintPack(size: _snapbook6x6, priceInPaise: 30100, snapCount: 24),
  PrintPack(size: _snapbook6x9, priceInPaise: 30100, snapCount: 16),
];

List<PrintSize> sizesFor(PrintCategory category) {
  final seen = <String>{};
  final result = <PrintSize>[];
  for (final pack in allPacks) {
    if (pack.size.category != category) continue;
    if (seen.add(pack.size.label)) {
      result.add(pack.size);
    }
  }
  return result;
}

List<PrintPack> packsFor(PrintSize size) =>
    allPacks.where((p) => p.size == size).toList();
