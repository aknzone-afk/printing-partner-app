// The print catalogue (lib/models/print_packages.dart) against the backend's
// price table (backend/catalog.json). /ingest ties the PAID amount to the
// exact (category, size, snapCount) row of catalog.json — a mismatch between
// the two files means the server refuses an order the customer has already
// paid for (400 unknown_pack / 402 amount_mismatch).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:printing_partner/models/print_packages.dart';

/// backend/catalog.json, found from the app directory the tests run in.
File catalogFile() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 4; i++) {
    final f = File('${dir.path}/backend/catalog.json');
    if (f.existsSync()) return f;
    dir = dir.parent;
  }
  fail('backend/catalog.json not found above ${Directory.current.path}');
}

List<Map<String, dynamic>> loadCatalog() {
  final decoded = jsonDecode(catalogFile().readAsStringSync(encoding: utf8))
      as Map<String, dynamic>;
  return [
    for (final p in decoded['packs'] as List)
      Map<String, dynamic>.from(p as Map)
  ];
}

/// Port of backend/app.py `_norm`.
String norm(Object? s) => (s ?? '')
    .toString()
    .toLowerCase()
    .replaceAll('×', 'x')
    .replaceAll('inches', '')
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty)
    .join(' ');

/// Port of backend/app.py `price_for` (the exact-pack price the server
/// charges against the payment token), returning every matching row.
List<Map<String, dynamic>> serverRowsFor(List<Map<String, dynamic>> catalog,
    String category, String size, int snapCount) {
  const aliases = {
    'photo': 'photos',
    'photos': 'photos',
    'polaroid': 'polaroid',
    'snapbook': 'snapbook',
  };
  final cat = aliases[norm(category)];
  final sz = norm(size);
  if (cat == null || sz.isEmpty || snapCount <= 0) return const [];
  return [
    for (final p in catalog)
      if (p['category'] == cat &&
          (p['count'] as num).toInt() == snapCount &&
          (norm(p['size']) == sz || norm(p['dimensions']) == sz))
        p
  ];
}

String key(String slug, String label, int count, num rupees) =>
    '$slug | $label | $count | ${rupees.toStringAsFixed(2)}';

void main() {
  final sizes = <PrintSize>[];
  for (final p in allPacks) {
    if (!sizes.any((s) => identical(s, p.size))) sizes.add(p.size);
  }

  group('print_packages.dart', () {
    test('there are packs, and every pack has a positive count and price',
        () {
      expect(allPacks, isNotEmpty);
      for (final p in allPacks) {
        final id = '${p.size.category.slug}/${p.size.label} x${p.snapCount}';
        expect(p.snapCount, greaterThan(0), reason: id);
        expect(p.priceInPaise, greaterThan(0), reason: id);
        expect(p.priceInPaise % 100, 0,
            reason: '$id: UPI amount + "₹" labels assume whole rupees');
      }
    });

    test('every size fits the 12x18 sheet: perSheet > 0 and sheetsNeeded > 0 '
        'and exactly enough', () {
      for (final p in allPacks) {
        final id = '${p.size.category.slug}/${p.size.label} x${p.snapCount}';
        final per = p.size.perSheet;
        expect(per, greaterThan(0), reason: '$id perSheet');
        expect(p.sheetsNeeded, greaterThan(0), reason: '$id sheetsNeeded');
        expect(p.sheetsNeeded * per, greaterThanOrEqualTo(p.snapCount),
            reason: '$id: the sheets must hold every print');
        expect((p.sheetsNeeded - 1) * per, lessThan(p.snapCount),
            reason: '$id: no wasted extra sheet');
        expect(p.sheetsLabel, p.sheetsNeeded == 1 ? '1 sheet' : '${p.sheetsNeeded} sheets');
      }
    });

    test('perSheet is the denser of the two orientations on 12x18', () {
      const want = <String, int>{
        'photos|Regular Mini': 18, // 3x4 rotated: 3 x 6
        'photos|Classic Mini': 12, // 4x4.5: 3 x 4
        'photos|Regular': 9, // 4x6: 3 x 3
        'photos|Classic Large': 6, // 6x6: 2 x 3
        'photos|Regular Large': 4, // 6x9: 2 x 2
        'photos|Regular Xtra-Large': 2, // 9x12 rotated: 1 x 2
        'polaroid|Vintage Mini': 18,
        'polaroid|Vintage': 12,
        'polaroid|Vintage Large': 6, // 5.7x6: 2 x 3
        'snapbook|4 × 6 Snapbook': 9,
        'snapbook|6 × 6 Snapbook': 6,
        'snapbook|6 × 9 Snapbook': 4,
      };
      final got = {
        for (final s in sizes) '${s.category.slug}|${s.label}': s.perSheet
      };
      expect(got, want);
      // A print larger than the sheet fits zero times (never negative / NaN).
      const huge = PrintSize(
          category: PrintCategory.photos,
          label: 'x',
          widthInches: 13,
          heightInches: 19);
      expect(huge.perSheet, 0);
      expect(
          const PrintPack(size: huge, priceInPaise: 100, snapCount: 4)
              .sheetsNeeded,
          0);
    });

    test('image areas: plain prints are edge to edge, polaroids are a square '
        'inside the card with a caption strip below', () {
      for (final s in sizes) {
        final id = '${s.category.slug}/${s.label}';
        expect(s.imageWidthInches, greaterThan(0), reason: id);
        expect(s.imageHeightInches, greaterThan(0), reason: id);
        expect(s.imageAspectWxH.isFinite && s.imageAspectWxH > 0, isTrue,
            reason: id);
        if (s.category == PrintCategory.polaroid) {
          expect(s.hasPolaroidStrip, isTrue, reason: id);
          expect(s.imageAspectWxH, 1.0, reason: '$id: square image');
          expect(s.sideMarginInches, greaterThan(0), reason: id);
          expect(s.bottomStripInches, greaterThan(s.topMarginInches),
              reason: '$id: the caption strip is the wide margin');
          expect(
              s.topMarginInches + s.imageHeightInches + s.bottomStripInches,
              closeTo(s.heightInches, 1e-9),
              reason: id);
          expect(s.imageWidthInches + 2 * s.sideMarginInches,
              closeTo(s.widthInches, 1e-9),
              reason: id);
        } else {
          expect(s.hasPolaroidStrip, isFalse, reason: id);
          expect(s.imageAspectWxH, s.aspectWxH, reason: id);
        }
      }
    });

    test('no two packs share (category, size, count); sizesFor / packsFor '
        'partition the list', () {
      final keys = [
        for (final p in allPacks)
          '${p.size.category.slug}|${p.size.label}|${p.snapCount}'
      ];
      expect(keys.toSet().length, keys.length, reason: 'duplicate pack');

      var total = 0;
      for (final c in PrintCategory.values) {
        final ss = sizesFor(c);
        expect(ss, isNotEmpty, reason: '${c.slug} has no sizes');
        expect(ss.map((s) => s.label).toSet().length, ss.length);
        for (final s in ss) {
          expect(s.category, c);
          final ps = packsFor(s);
          expect(ps, isNotEmpty, reason: '${c.slug}/${s.label} has no packs');
          total += ps.length;
          for (var i = 1; i < ps.length; i++) {
            expect(ps[i].snapCount, greaterThan(ps[i - 1].snapCount),
                reason: '${s.label}: packs listed smallest first');
            expect(ps[i].priceInPaise, greaterThan(ps[i - 1].priceInPaise),
                reason: '${s.label}: a bigger pack must cost more (the server '
                    'floor is "cheapest pack that holds the photos")');
          }
        }
      }
      expect(total, allPacks.length);
    });

    test('labels', () {
      final p = allPacks.firstWhere((p) =>
          p.size.category == PrintCategory.photos &&
          p.size.label == 'Regular' &&
          p.snapCount == 18);
      expect(p.priceLabel, '₹175');
      expect(p.countLabel, '18 snaps');
      expect(p.perUnitLabel, '₹9.72/snap');
      expect(p.size.dimensions, '4 × 6 inches');
      final book = allPacks
          .firstWhere((p) => p.size.category == PrintCategory.snapbook);
      expect(book.countLabel, endsWith(' pages'));
      expect(book.perUnitLabel, endsWith('/page'));
    });
  });

  group('app catalogue == backend/catalog.json', () {
    late List<Map<String, dynamic>> catalog;
    setUpAll(() => catalog = loadCatalog());

    test('catalog.json is well formed', () {
      expect(catalog, isNotEmpty);
      for (final row in catalog) {
        expect(row['category'], isA<String>(), reason: '$row');
        expect(row['size'], isA<String>(), reason: '$row');
        expect(row['dimensions'], isA<String>(), reason: '$row');
        expect(row['count'], isA<int>(), reason: '$row');
        expect(row['rupees'], isA<num>(), reason: '$row');
        expect(row['count'] as int, greaterThan(0), reason: '$row');
        expect(row['rupees'] as num, greaterThan(0), reason: '$row');
      }
    });

    test('category slugs are exactly the backend\'s categories', () {
      expect({for (final c in PrintCategory.values) c.slug},
          {for (final row in catalog) row['category'] as String});
      expect({for (final c in PrintCategory.values) c.slug},
          {'photos', 'polaroid', 'snapbook'});
    });

    test('every (slug, label, snapCount, rupees) matches, BOTH ways', () {
      final app = {
        for (final p in allPacks)
          key(p.size.category.slug, p.size.label, p.snapCount,
              p.priceInPaise / 100)
      };
      final server = {
        for (final row in catalog)
          key(row['category'] as String, row['size'] as String,
              row['count'] as int, row['rupees'] as num)
      };
      expect(app.length, allPacks.length);
      expect(server.length, catalog.length,
          reason: 'duplicate rows in catalog.json');
      expect(app.difference(server), isEmpty,
          reason: 'packs the app sells that the server does not know (or '
              'prices differently): a paid order would be refused');
      expect(server.difference(app), isEmpty,
          reason: 'catalog.json rows the app does not sell');
      expect(catalog.length, allPacks.length);
    });

    test('the "dimensions" text matches too (the server also accepts it as a '
        'size name)', () {
      for (final p in allPacks) {
        final rows = catalog.where((r) =>
            r['category'] == p.size.category.slug &&
            r['size'] == p.size.label &&
            r['count'] == p.snapCount);
        expect(rows.length, 1,
            reason: '${p.size.label} x${p.snapCount}: exactly one row');
        expect(rows.single['dimensions'], p.size.dimensions,
            reason: '${p.size.label} x${p.snapCount}');
      }
    });

    test('what checkout sends resolves, with the server\'s own matching '
        'rules, to exactly one row at exactly the app price', () {
      for (final p in allPacks) {
        // checkout_screen.dart: category = slug, size = label, snapCount.
        final rows = serverRowsFor(
            catalog, p.size.category.slug, p.size.label, p.snapCount);
        final id = '${p.size.category.slug}/${p.size.label} x${p.snapCount}';
        expect(rows.length, 1,
            reason: '$id must resolve to ONE server row (0 = unknown_pack, '
                '>1 = ambiguous price)');
        expect(((rows.single['rupees'] as num) * 100).round(), p.priceInPaise,
            reason: '$id: the server would answer 402 amount_mismatch');
      }
    });

    test('server size matching cannot confuse two sizes of one category', () {
      // _norm(size) is compared against BOTH the size name and the
      // dimensions text; within a category no name may collide with another
      // size's name or dimensions.
      for (final c in PrintCategory.values) {
        final names = <String, String>{}; // normalised text -> size label
        for (final s in sizesFor(c)) {
          for (final text in {norm(s.label), norm(s.dimensions)}) {
            final prev = names[text];
            expect(prev == null || prev == s.label, isTrue,
                reason: '${c.slug}: "$text" names both "$prev" and '
                    '"${s.label}"');
            names[text] = s.label;
          }
        }
      }
    });
  });
}
