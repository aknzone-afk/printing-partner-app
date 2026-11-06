import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'photo_item.dart';
import 'print_packages.dart';

class Cart extends ChangeNotifier {
  final List<PhotoItem> _items = [];
  PrintPack? _selectedPack;
  // Per-photo crop state: id -> CropEdit. If absent, the photo will be
  // letterboxed (white-padded) to match the size's image aspect ratio.
  final Map<String, CropEdit> _edits = {};

  // Pre-built print sheet PDF (combined, one page per master sheet).
  Uint8List? _pdfBytes;
  double _pdfProgress = 0.0;
  String _pdfStage = '';

  Uint8List? get pdfBytes => _pdfBytes;
  double get pdfProgress => _pdfProgress;
  String get pdfStage => _pdfStage;
  bool get pdfReady => _pdfBytes != null;

  void setPdfProgress(double p, String stage) {
    _pdfProgress = p;
    _pdfStage = stage;
    notifyListeners();
  }

  void setPdfBytes(Uint8List bytes) {
    _pdfBytes = bytes;
    _pdfProgress = 1.0;
    _pdfStage = 'Done';
    notifyListeners();
  }

  void resetPdf() {
    _pdfBytes = null;
    _pdfProgress = 0.0;
    _pdfStage = '';
    notifyListeners();
  }

  // Customer's delivery info captured on /address before /checkout.
  String customerName = '';
  String customerPhone = '';
  String addressLine1 = '';
  String addressLine2 = '';
  String city = '';
  String state = '';
  String pincode = '';

  String get fullAddress {
    final parts = <String>[
      if (addressLine1.isNotEmpty) addressLine1,
      if (addressLine2.isNotEmpty) addressLine2,
      if (city.isNotEmpty || state.isNotEmpty || pincode.isNotEmpty)
        [city, state, pincode].where((s) => s.isNotEmpty).join(', '),
    ];
    return parts.join('\n');
  }

  void setCustomer({
    required String name,
    required String phone,
    required String line1,
    required String line2,
    required String city,
    required String state,
    required String pincode,
  }) {
    customerName = name;
    customerPhone = phone;
    addressLine1 = line1;
    addressLine2 = line2;
    this.city = city;
    this.state = state;
    this.pincode = pincode;
    notifyListeners();
  }

  List<PhotoItem> get items => List.unmodifiable(_items);
  int get itemCount => _items.length;
  int get totalPrints =>
      _items.fold<int>(0, (sum, item) => sum + item.quantity);
  bool get isEmpty => _items.isEmpty;

  PrintPack? get selectedPack => _selectedPack;
  int get targetSnapCount => _selectedPack?.snapCount ?? 0;

  /// How many 12×18 master sheets the merchant needs to print this order.
  int get sheetsNeeded {
    final pack = _selectedPack;
    if (pack == null) return 0;
    final perSheet = pack.size.perSheet;
    if (perSheet <= 0) return 0;
    return (pack.snapCount / perSheet).ceil();
  }

  CropEdit? cropFor(String id) => _edits[id];

  /// Mark a photo's crop as user-edited (vs auto letterbox).
  void setCrop(String id, CropEdit edit) {
    _edits[id] = edit;
    notifyListeners();
  }

  /// True when every photo has been reviewed (either cropped or explicitly
  /// accepted with auto white padding).
  bool get allPhotosReady {
    if (_selectedPack == null) return false;
    if (_items.length < _selectedPack!.snapCount) return false;
    return _items.every((p) => _edits.containsKey(p.id));
  }

  void selectPack(PrintPack pack) {
    _selectedPack = pack;
    _items.clear();
    _edits.clear();
    _pdfBytes = null;
    _pdfProgress = 0.0;
    _pdfStage = '';
    notifyListeners();
  }

  void clearPack() {
    _selectedPack = null;
    _items.clear();
    _edits.clear();
    _pdfBytes = null;
    _pdfProgress = 0.0;
    _pdfStage = '';
    notifyListeners();
  }

  int get subtotalPaise {
    // If a pack is active, the price is the pack's flat price (regardless of
    // how many of the picked photos repeat — user picks N photos to fill the
    // N-snap pack).
    if (_selectedPack != null) return _selectedPack!.priceInPaise;
    return 0;
  }

  /// Free shipping on every order — pricing already includes shipping cost.
  int get shippingPaise => 0;

  int get totalPaise => subtotalPaise + shippingPaise;

  String paiseToRupees(int paise) =>
      '₹${(paise / 100).toStringAsFixed(0)}';

  void addPhotos(Iterable<String> localPaths) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < localPaths.length; i++) {
      _items.add(PhotoItem(
        id: '$now-$i',
        localPath: localPaths.elementAt(i),
      ));
    }
    notifyListeners();
  }

  void remove(String id) {
    _items.removeWhere((item) => item.id == id);
    _edits.remove(id);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    _edits.clear();
    _selectedPack = null;
    _pdfBytes = null;
    _pdfProgress = 0.0;
    _pdfStage = '';
    customerName = '';
    customerPhone = '';
    addressLine1 = '';
    addressLine2 = '';
    city = '';
    state = '';
    pincode = '';
    notifyListeners();
  }
}

/// User's crop choice for a single photo.
/// - [skipped] = customer chose to skip cropping; renderer should letterbox
///   (white-pad) the photo to fit the target aspect.
/// - [offsetX], [offsetY], [scale] describe the user-edited crop position.
/// - [rotationSteps] = number of 90° clockwise rotations applied (0..3).
class CropEdit {
  const CropEdit({
    required this.skipped,
    this.offsetX = 0,
    this.offsetY = 0,
    this.scale = 1,
    this.rotationSteps = 0,
  });

  const CropEdit.skipped({int rotationSteps = 0})
      : this(skipped: true, rotationSteps: rotationSteps);
  const CropEdit.cropped({
    required double offsetX,
    required double offsetY,
    required double scale,
    int rotationSteps = 0,
  }) : this(
          skipped: false,
          offsetX: offsetX,
          offsetY: offsetY,
          scale: scale,
          rotationSteps: rotationSteps,
        );

  final bool skipped;
  final double offsetX;
  final double offsetY;
  final double scale;
  final int rotationSteps;
}
