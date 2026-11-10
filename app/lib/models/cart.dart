import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'photo_item.dart';
import 'print_packages.dart';

class Cart extends ChangeNotifier {
  Cart() {
    _restore();
  }

  /// SharedPreferences key for the persisted cart (pack + photos + crops +
  /// address). An app kill while paying / uploading must not lose a paid
  /// customer's order, so every mutation is mirrored to disk and restored on
  /// construction.
  static const _storageKey = 'pp_cart_v1';
  bool _restored = false;
  bool get isRestored => _restored;

  final List<PhotoItem> _items = [];
  PrintPack? _selectedPack;

  /// Running counter for photo ids: two addPhotos calls inside the same
  /// millisecond must never mint the same id (crops/removal are keyed by it).
  int _idSeq = 0;
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
    _invalidatePdf();
    notifyListeners();
  }

  /// Any change to the photo set or crops invalidates a pre-built print PDF, so
  /// checkout can never upload a STALE one (the old photos). Called from
  /// addPhotos / remove / setCrop.
  void _invalidatePdf() {
    _pdfBytes = null;
    _pdfProgress = 0.0;
    _pdfStage = '';
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
    _persist();
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
    _invalidatePdf();
    _persist();
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
    _persist();
    notifyListeners();
  }

  /// Switch to a DIFFERENT pack of the SAME size (a different count), keeping
  /// the already-picked photos and their crops. If the new pack holds fewer
  /// snaps, the extra photos (and their edits) are dropped. Unlike
  /// [selectPack], this never wipes the selection the customer already made.
  void changePack(PrintPack pack) {
    _selectedPack = pack;
    final cap = pack.snapCount;
    if (cap > 0 && _items.length > cap) {
      final removed = _items.sublist(cap);
      _items.removeRange(cap, _items.length);
      for (final it in removed) {
        _edits.remove(it.id);
      }
    }
    _invalidatePdf();
    _persist();
    notifyListeners();
  }

  void clearPack() {
    _selectedPack = null;
    _items.clear();
    _edits.clear();
    _pdfBytes = null;
    _pdfProgress = 0.0;
    _pdfStage = '';
    _persist();
    notifyListeners();
  }

  /// Remove every photo but KEEP the chosen pack — for the cart "Clear all".
  void clearPhotos() {
    _items.clear();
    _edits.clear();
    _pdfBytes = null;
    _pdfProgress = 0.0;
    _pdfStage = '';
    _persist();
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
    // A pack holds exactly snapCount photos: the server refuses an order with
    // more (400 too_many_photos) AFTER the customer has paid, so the cart
    // itself never grows past the pack.
    final cap = _selectedPack?.snapCount;
    for (final path in localPaths) {
      if (cap != null && _items.length >= cap) break;
      _items.add(PhotoItem(
        id: '$now-${_idSeq++}',
        localPath: path,
      ));
    }
    _invalidatePdf();
    _persist();
    notifyListeners();
  }

  void remove(String id) {
    _items.removeWhere((item) => item.id == id);
    _edits.remove(id);
    _invalidatePdf();
    _persist();
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
    _persist();
    notifyListeners();
  }

  // ─── Persistence ───────────────────────────────────────────────
  /// Mirror the cart (pack + photos + every crop + address) to disk. Called
  /// after every mutation; failures are swallowed (persistence is best-effort,
  /// the in-memory cart stays authoritative). The session-only print PDF is
  /// deliberately NOT persisted.
  Future<void> _persist() async {
    try {
      final pack = _selectedPack;
      final data = <String, dynamic>{
        'pack': pack == null
            ? null
            : <String, dynamic>{
                'slug': pack.size.category.slug,
                'label': pack.size.label,
                'snapCount': pack.snapCount,
                'priceInPaise': pack.priceInPaise,
              },
        'items': _items
            .map((i) => <String, dynamic>{
                  'id': i.id,
                  'path': i.localPath,
                  'quantity': i.quantity,
                })
            .toList(),
        'edits':
            _edits.map((k, v) => MapEntry(k, v.toJson())),
        'idSeq': _idSeq,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'addressLine1': addressLine1,
        'addressLine2': addressLine2,
        'city': city,
        'state': state,
        'pincode': pincode,
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(data));
    } catch (e) {
      debugPrint('[Cart] persist failed: $e');
    }
  }

  /// Restore a persisted cart on construction. Never clobbers a cart the user
  /// already started during the async startup gap.
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      // The user may have picked a pack before this async load returned — don't
      // overwrite a live selection.
      if (_selectedPack != null || _items.isNotEmpty) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;

      final packJson = data['pack'];
      if (packJson is Map) {
        final slug = packJson['slug'];
        final label = packJson['label'];
        final snap = (packJson['snapCount'] as num?)?.toInt();
        final paise = (packJson['priceInPaise'] as num?)?.toInt();
        for (final p in allPacks) {
          if (p.size.category.slug == slug &&
              p.size.label == label &&
              p.snapCount == snap &&
              p.priceInPaise == paise) {
            _selectedPack = p;
            break;
          }
        }
      }

      final items = data['items'];
      if (items is List) {
        for (final it in items) {
          if (it is Map) {
            final id = it['id'];
            final path = it['path'];
            if (id is String && path is String) {
              _items.add(PhotoItem(
                id: id,
                localPath: path,
                quantity: (it['quantity'] as num?)?.toInt() ?? 1,
              ));
            }
          }
        }
      }

      final edits = data['edits'];
      if (edits is Map) {
        edits.forEach((k, v) {
          if (k is String && v is Map) {
            _edits[k] = CropEdit.fromJson(v.cast<String, dynamic>());
          }
        });
      }

      _idSeq = (data['idSeq'] as num?)?.toInt() ?? _idSeq;
      customerName = data['customerName'] as String? ?? '';
      customerPhone = data['customerPhone'] as String? ?? '';
      addressLine1 = data['addressLine1'] as String? ?? '';
      addressLine2 = data['addressLine2'] as String? ?? '';
      city = data['city'] as String? ?? '';
      state = data['state'] as String? ?? '';
      pincode = data['pincode'] as String? ?? '';
    } catch (e) {
      debugPrint('[Cart] restore failed: $e');
    } finally {
      _restored = true;
      notifyListeners();
    }
  }
}

/// User's crop choice for a single photo.
/// - [skipped] = customer chose to skip cropping; renderer should letterbox
///   (white-pad) the photo to fit the target aspect.
/// - [crop] = the frame the customer actually saw, as a rect NORMALISED to the
///   (rotated, EXIF-upright) photo: (0,0)-(1,1) is the whole photo; values
///   outside 0..1 are white margin the customer zoomed out into. This is what
///   the export prints. Null = legacy centre-cover ("Auto crop").
/// - [offsetX], [offsetY], [scale] are the crop viewer's matrix (translation
///   in logical px + zoom) and [viewWidth] x [viewHeight] the size of the crop
///   frame it was captured in. Together they say exactly which part of the
///   photo the customer framed, independent of the photo's pixel size — the
///   export rebuilds the frame from them with the photo's TRUE dimensions
///   (see [cropFrameRect]). A view size of 0 means "no viewer state" (Auto
///   crop / legacy edits).
/// - [rotationSteps] = number of 90° clockwise rotations applied (0..3).
class CropEdit {
  const CropEdit({
    required this.skipped,
    this.offsetX = 0,
    this.offsetY = 0,
    this.scale = 1,
    this.rotationSteps = 0,
    this.crop,
    this.viewWidth = 0,
    this.viewHeight = 0,
  });

  const CropEdit.skipped({int rotationSteps = 0})
      : this(skipped: true, rotationSteps: rotationSteps);
  const CropEdit.cropped({
    required double offsetX,
    required double offsetY,
    required double scale,
    int rotationSteps = 0,
    Rect? crop,
    double viewWidth = 0,
    double viewHeight = 0,
  }) : this(
          skipped: false,
          offsetX: offsetX,
          offsetY: offsetY,
          scale: scale,
          rotationSteps: rotationSteps,
          crop: crop,
          viewWidth: viewWidth,
          viewHeight: viewHeight,
        );

  /// Round-trips every field through SharedPreferences so a restored cart
  /// shows the exact crop the customer saved.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'skipped': skipped,
        'offsetX': offsetX,
        'offsetY': offsetY,
        'scale': scale,
        'rotationSteps': rotationSteps,
        if (crop != null)
          'crop': <double>[crop!.left, crop!.top, crop!.right, crop!.bottom],
        'viewWidth': viewWidth,
        'viewHeight': viewHeight,
      };

  factory CropEdit.fromJson(Map<String, dynamic> j) {
    final c = j['crop'];
    Rect? rect;
    if (c is List && c.length == 4) {
      rect = Rect.fromLTRB(
        (c[0] as num).toDouble(),
        (c[1] as num).toDouble(),
        (c[2] as num).toDouble(),
        (c[3] as num).toDouble(),
      );
    }
    return CropEdit(
      skipped: j['skipped'] == true,
      offsetX: (j['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (j['offsetY'] as num?)?.toDouble() ?? 0,
      scale: (j['scale'] as num?)?.toDouble() ?? 1,
      rotationSteps: (j['rotationSteps'] as num?)?.toInt() ?? 0,
      crop: rect,
      viewWidth: (j['viewWidth'] as num?)?.toDouble() ?? 0,
      viewHeight: (j['viewHeight'] as num?)?.toDouble() ?? 0,
    );
  }

  final bool skipped;
  final double offsetX;
  final double offsetY;
  final double scale;
  final int rotationSteps;
  final Rect? crop;

  /// Size (logical px) of the crop frame [offsetX]/[offsetY] were measured in.
  final double viewWidth;
  final double viewHeight;

  /// True when this edit carries a usable viewer state (pan + zoom + the frame
  /// size they refer to), i.e. the customer pressed Save on the crop screen.
  bool get hasView =>
      !skipped &&
      viewWidth.isFinite &&
      viewHeight.isFinite &&
      viewWidth > 0 &&
      viewHeight > 0 &&
      scale.isFinite &&
      scale > 0 &&
      offsetX.isFinite &&
      offsetY.isFinite;
}

/// The crop-screen frame expressed in the ROTATED photo's normalised
/// coordinates, as `[left, top, right, bottom]`: (0,0)-(1,1) is the whole
/// photo, values outside 0..1 are the white margin around it.
///
/// The crop screen shows the (rotated) photo BoxFit.contain inside a frame of
/// aspect [frameAspect] (width / height) and lets the customer pan/zoom it
/// with an InteractiveViewer whose matrix is `view = scale * scene + offset`.
/// [fx] / [fy] are that offset as a FRACTION of the frame's width / height,
/// so the result does not depend on the screen size, and [photoAspect] is the
/// rotated photo's true width / height — so the rect always has exactly the
/// frame's aspect when applied to the real pixels.
///
/// Pure (no Flutter types) so the export isolate and the unit tests share it.
/// Null when the inputs cannot describe a frame.
List<double>? cropFrameRect({
  required double frameAspect,
  required double photoAspect,
  required double scale,
  required double fx,
  required double fy,
}) {
  if (!frameAspect.isFinite ||
      !photoAspect.isFinite ||
      !scale.isFinite ||
      !fx.isFinite ||
      !fy.isFinite ||
      frameAspect <= 0 ||
      photoAspect <= 0 ||
      scale <= 0) {
    return null;
  }
  // Work in units of the frame's height: the frame is frameAspect x 1.
  final a = frameAspect;
  final r = photoAspect;
  // The contain-fitted photo box inside the frame (centred).
  final cw = r > a ? a : r;
  final ch = r > a ? a / r : 1.0;
  final ox = (a - cw) / 2;
  final oy = (1 - ch) / 2;
  // Invert the viewer matrix at the frame's corners -> visible scene rect.
  final left = (0 - fx * a) / scale;
  final top = (0 - fy) / scale;
  final right = (a - fx * a) / scale;
  final bottom = (1 - fy) / scale;
  return <double>[
    (left - ox) / cw,
    (top - oy) / ch,
    (right - ox) / cw,
    (bottom - oy) / ch,
  ];
}
