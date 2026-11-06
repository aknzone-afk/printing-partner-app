import 'dart:typed_data';

/// One placed order. In-memory mock until Firebase is wired in Week 2.
class OrderRecord {
  OrderRecord({
    required this.id,
    required this.placedAt,
    required this.customerName,
    required this.customerPhone,
    required this.address,
    required this.productTitle,
    required this.sizeLabel,
    required this.sizeDimensions,
    required this.snapCount,
    required this.sheetsNeeded,
    required this.totalPaise,
    required this.photoPaths,
    required this.status,
    this.pdfStatus = SheetPdfStatus.generating,
    this.pdfBytes,
  });

  final String id;
  final DateTime placedAt;
  final String customerName;
  final String customerPhone;
  final String address;
  final String productTitle;
  final String sizeLabel;
  final String sizeDimensions;
  final int snapCount;
  final int sheetsNeeded;
  final int totalPaise;
  final List<String> photoPaths;
  OrderStatus status;

  /// Pre-built print sheet PDF — single combined file with one page per
  /// 12×18 master sheet. Each page's content stays under the 6 MB budget
  /// thanks to per-photo compression.
  SheetPdfStatus pdfStatus;
  Uint8List? pdfBytes;

  String get totalLabel => '₹${(totalPaise / 100).toStringAsFixed(0)}';
  String get sheetsLabel =>
      '$sheetsNeeded sheet${sheetsNeeded == 1 ? '' : 's'}';
  String get displayId => '#${id.substring(0, 6).toUpperCase()}';
  String get pdfFilename {
    String s(String x) =>
        x.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();
    return '${s(customerName)}_${s(productTitle)}.pdf';
  }

  /// Stable key used to group orders by product+size for bulk printing.
  /// Example: "Photo · Regular Mini · 3 × 4 inches"
  String get groupKey => '$productTitle · $sizeLabel · $sizeDimensions';
  String get groupSlug {
    String s(String x) =>
        x.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();
    return '${s(productTitle)}_${s(sizeLabel)}';
  }

  /// Serialise to a JSON-safe map. Excludes `pdfBytes` (too large for
  /// localStorage) — after restore the PDF is marked as archived and the
  /// merchant must re-request it from the customer.
  Map<String, dynamic> toJson() => {
        'id': id,
        'placedAt': placedAt.toIso8601String(),
        'customerName': customerName,
        'customerPhone': customerPhone,
        'address': address,
        'productTitle': productTitle,
        'sizeLabel': sizeLabel,
        'sizeDimensions': sizeDimensions,
        'snapCount': snapCount,
        'sheetsNeeded': sheetsNeeded,
        'totalPaise': totalPaise,
        'photoPaths': photoPaths,
        'status': status.name,
        // Don't persist pdfStatus or pdfBytes — both are session-scoped.
      };

  /// Defensive against older saved entries that may be missing fields.
  factory OrderRecord.fromJson(Map<String, dynamic> json) {
    String s(String key, [String fallback = '']) =>
        json[key]?.toString() ?? fallback;
    int i(String key, [int fallback = 0]) {
      final v = json[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return fallback;
    }

    OrderStatus parseStatus() {
      final raw = json['status'];
      if (raw is String) {
        for (final v in OrderStatus.values) {
          if (v.name == raw) return v;
        }
      }
      return OrderStatus.received;
    }

    return OrderRecord(
      id: s('id', DateTime.now().millisecondsSinceEpoch.toString()),
      placedAt: DateTime.tryParse(s('placedAt')) ?? DateTime.now(),
      customerName: s('customerName', 'Customer'),
      customerPhone: s('customerPhone'),
      address: s('address'),
      productTitle: s('productTitle', 'Photo'),
      sizeLabel: s('sizeLabel'),
      sizeDimensions: s('sizeDimensions'),
      snapCount: i('snapCount'),
      sheetsNeeded: i('sheetsNeeded', 1),
      totalPaise: i('totalPaise'),
      photoPaths: (json['photoPaths'] is List)
          ? List<String>.from(
              (json['photoPaths'] as List).map((e) => e.toString()))
          : <String>[],
      status: parseStatus(),
      // Restored orders may not have PDF bytes cached — caller (OrdersStore)
      // tries IndexedDB and upgrades to `ready` if a PDF is found.
      pdfStatus: SheetPdfStatus.archived,
    );
  }
}

enum SheetPdfStatus {
  generating(label: 'Preparing…'),
  ready(label: 'PDF ready'),
  failed(label: 'PDF failed — retry'),
  archived(label: 'Archived (re-request photos)');

  const SheetPdfStatus({required this.label});
  final String label;
}

enum OrderStatus {
  received(label: 'Received', color: 0xFF7B6CF0),
  printing(label: 'Printing', color: 0xFFF59E0B),
  shipped(label: 'Shipped', color: 0xFF3B82F6),
  delivered(label: 'Delivered', color: 0xFF22C55E);

  const OrderStatus({required this.label, required this.color});
  final String label;
  final int color;
}
