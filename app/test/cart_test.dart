// The cart model (lib/models/cart.dart): pack selection, the photo-count
// rules the server enforces after payment, crop bookkeeping, cache
// invalidation and totals.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:printing_partner/models/cart.dart';
import 'package:printing_partner/models/print_packages.dart';

PrintPack pack(PrintCategory c, String label, int count) =>
    allPacks.firstWhere((p) =>
        p.size.category == c && p.size.label == label && p.snapCount == count);

List<String> paths(int n, [String prefix = 'p']) =>
    [for (var i = 0; i < n; i++) '/photos/$prefix$i.jpg'];

final Uint8List pdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);

void main() {
  final xl6 = pack(PrintCategory.photos, 'Regular Xtra-Large', 6); // Rs 200
  final reg18 = pack(PrintCategory.photos, 'Regular', 18); // Rs 175
  final book = pack(PrintCategory.snapbook, '6 × 9 Snapbook', 16); // Rs 301

  group('empty cart', () {
    test('has no pack, no photos, costs nothing and is not ready', () {
      final cart = Cart();
      expect(cart.isEmpty, isTrue);
      expect(cart.itemCount, 0);
      expect(cart.totalPrints, 0);
      expect(cart.selectedPack, isNull);
      expect(cart.targetSnapCount, 0);
      expect(cart.sheetsNeeded, 0);
      expect(cart.subtotalPaise, 0);
      expect(cart.shippingPaise, 0);
      expect(cart.totalPaise, 0);
      expect(cart.allPhotosReady, isFalse);
      expect(cart.pdfReady, isFalse);
      expect(cart.fullAddress, '');
    });
  });

  group('totals', () {
    test('the price is the pack\'s flat price, shipping is free, whatever the '
        'number of photos picked so far', () {
      for (final p in allPacks) {
        final cart = Cart()..selectPack(p);
        expect(cart.subtotalPaise, p.priceInPaise);
        expect(cart.shippingPaise, 0);
        expect(cart.totalPaise, p.priceInPaise);
        expect(cart.targetSnapCount, p.snapCount);
        expect(cart.sheetsNeeded, p.sheetsNeeded);
        cart.addPhotos(paths(3));
        expect(cart.totalPaise, p.priceInPaise,
            reason: 'adding photos never changes a pack price');
        expect(cart.paiseToRupees(cart.totalPaise), p.priceLabel);
      }
    });

    test('paiseToRupees', () {
      final cart = Cart();
      expect(cart.paiseToRupees(15000), '₹150');
      expect(cart.paiseToRupees(30100), '₹301');
      expect(cart.paiseToRupees(0), '₹0');
    });

    test('totalPrints counts quantities', () {
      final cart = Cart()
        ..selectPack(reg18)
        ..addPhotos(paths(3));
      expect(cart.totalPrints, 3);
      cart.items[1].quantity = 4;
      expect(cart.totalPrints, 6);
      expect(cart.itemCount, 3);
    });
  });

  group('photo count vs pack.snapCount', () {
    test('a pack never holds more photos than its snapCount (the server '
        'refuses the extra ones AFTER payment)', () {
      final cart = Cart()..selectPack(xl6);
      cart.addPhotos(paths(4, 'a'));
      expect(cart.itemCount, 4);
      cart.addPhotos(paths(5, 'b')); // only 2 fit
      expect(cart.itemCount, 6);
      expect(cart.items.map((i) => i.localPath).toList(), [
        '/photos/a0.jpg',
        '/photos/a1.jpg',
        '/photos/a2.jpg',
        '/photos/a3.jpg',
        '/photos/b0.jpg',
        '/photos/b1.jpg',
      ], reason: 'kept in pick order; the overflow is dropped from the end');
      cart.addPhotos(paths(3, 'c'));
      expect(cart.itemCount, 6);
    });

    test('removing a photo frees a slot again', () {
      final cart = Cart()
        ..selectPack(xl6)
        ..addPhotos(paths(6));
      cart.remove(cart.items[2].id);
      expect(cart.itemCount, 5);
      cart.addPhotos(['/photos/new.jpg', '/photos/overflow.jpg']);
      expect(cart.itemCount, 6);
      expect(cart.items.last.localPath, '/photos/new.jpg');
    });

    test('every pack: exactly snapCount photos can be added', () {
      for (final p in allPacks) {
        final cart = Cart()
          ..selectPack(p)
          ..addPhotos(paths(p.snapCount + 7));
        expect(cart.itemCount, p.snapCount,
            reason: '${p.size.label} x${p.snapCount}');
      }
    });

    test('ready with a pack, at least one photo, and every photo reviewed — a '
        'PARTIAL pack is allowed (pays the pack price for fewer prints)', () {
      final cart = Cart();
      cart.addPhotos(paths(2));
      expect(cart.allPhotosReady, isFalse, reason: 'no pack selected');

      cart.selectPack(xl6);
      expect(cart.itemCount, 0, reason: 'selecting a pack starts it empty');
      cart.addPhotos(paths(5));
      for (final i in cart.items.take(4)) {
        cart.setCrop(i.id, const CropEdit.skipped());
      }
      expect(cart.allPhotosReady, isFalse,
          reason: 'the 5th photo has not been reviewed');

      cart.setCrop(cart.items[4].id, const CropEdit.skipped());
      expect(cart.allPhotosReady, isTrue,
          reason: 'a partial pack (5 of 6), every photo reviewed, is ready');

      cart.addPhotos(paths(1, 'last'));
      expect(cart.allPhotosReady, isFalse,
          reason: 'the new photo has not been reviewed');

      cart.setCrop(
          cart.items.last.id,
          const CropEdit.cropped(
              offsetX: 0, offsetY: 0, scale: 1, rotationSteps: 1));
      expect(cart.allPhotosReady, isTrue);

      cart.remove(cart.items.first.id);
      expect(cart.allPhotosReady, isTrue,
          reason: 'still ready: a partial pack with every photo reviewed');

      for (final i in [...cart.items]) {
        cart.remove(i.id);
      }
      expect(cart.allPhotosReady, isFalse, reason: 'no photos left');
    });
  });

  group('photo ids and crops', () {
    test('ids are unique, even for the same path added twice in one call and '
        'across rapid calls', () {
      final cart = Cart()..selectPack(pack(PrintCategory.photos, 'Regular Mini', 54));
      cart.addPhotos(['/a.jpg', '/a.jpg', '/a.jpg']);
      for (var i = 0; i < 10; i++) {
        cart.addPhotos(['/a.jpg']);
      }
      final ids = cart.items.map((i) => i.id).toList();
      expect(ids.length, 13);
      expect(ids.toSet().length, 13);
    });

    test('setCrop / cropFor are per photo; remove drops only that photo and '
        'its crop', () {
      final cart = Cart()
        ..selectPack(reg18)
        ..addPhotos(paths(3));
      final a = cart.items[0].id, b = cart.items[1].id, c = cart.items[2].id;
      expect(cart.cropFor(a), isNull);

      const edit = CropEdit.cropped(
          offsetX: -12.5,
          offsetY: 30,
          scale: 2.5,
          rotationSteps: 3,
          viewWidth: 320,
          viewHeight: 480);
      cart.setCrop(a, edit);
      cart.setCrop(b, const CropEdit.skipped(rotationSteps: 1));

      final got = cart.cropFor(a)!;
      expect(got.skipped, isFalse);
      expect(got.offsetX, -12.5);
      expect(got.offsetY, 30);
      expect(got.scale, 2.5);
      expect(got.rotationSteps, 3);
      expect(got.viewWidth, 320);
      expect(got.viewHeight, 480);
      expect(got.hasView, isTrue);
      expect(cart.cropFor(b)!.skipped, isTrue);
      expect(cart.cropFor(b)!.rotationSteps, 1);
      expect(cart.cropFor(c), isNull);

      cart.remove(a);
      expect(cart.items.map((i) => i.id).toList(), [b, c]);
      expect(cart.cropFor(a), isNull);
      expect(cart.cropFor(b)!.skipped, isTrue);

      // A re-edit replaces the previous crop.
      cart.setCrop(b, edit);
      expect(cart.cropFor(b)!.skipped, isFalse);

      cart.remove('no-such-id');
      expect(cart.itemCount, 2);
    });

    test('items cannot be modified from outside', () {
      final cart = Cart()
        ..selectPack(reg18)
        ..addPhotos(paths(2));
      expect(() => cart.items.clear(), throwsUnsupportedError);
      expect(() => cart.items.removeAt(0), throwsUnsupportedError);
      expect(cart.itemCount, 2);
    });

    test('CropEdit defaults', () {
      const s = CropEdit.skipped();
      expect(s.skipped, isTrue);
      expect(s.rotationSteps, 0);
      expect(s.scale, 1);
      expect(s.crop, isNull);
      const c = CropEdit.cropped(offsetX: 1, offsetY: 2, scale: 3);
      expect(c.skipped, isFalse);
      expect(c.rotationSteps, 0);
      expect(c.viewWidth, 0);
      expect(c.hasView, isFalse);
    });
  });

  group('a cached print file is invalidated by every change to the order', () {
    Cart ready() {
      final cart = Cart()
        ..selectPack(xl6)
        ..addPhotos(paths(4));
      cart.setPdfProgress(0.4, 'Rendering');
      expect(cart.pdfProgress, 0.4);
      expect(cart.pdfStage, 'Rendering');
      cart.setPdfBytes(pdf);
      expect(cart.pdfReady, isTrue);
      expect(cart.pdfBytes, pdf);
      expect(cart.pdfProgress, 1.0);
      expect(cart.pdfStage, 'Done');
      return cart;
    }

    void expectInvalidated(Cart cart, String what) {
      expect(cart.pdfReady, isFalse, reason: '$what must drop the cached file');
      expect(cart.pdfBytes, isNull, reason: what);
      expect(cart.pdfProgress, 0.0, reason: what);
      expect(cart.pdfStage, '', reason: what);
    }

    test('addPhotos', () {
      final cart = ready()..addPhotos(['/photos/extra.jpg']);
      expectInvalidated(cart, 'addPhotos');
    });

    test('remove', () {
      final cart = ready();
      cart.remove(cart.items.first.id);
      expectInvalidated(cart, 'remove');
    });

    test('setCrop', () {
      final cart = ready();
      cart.setCrop(cart.items.first.id, const CropEdit.skipped());
      expectInvalidated(cart, 'setCrop');
    });

    test('selectPack / clearPack / clear / resetPdf', () {
      expectInvalidated(ready()..selectPack(reg18), 'selectPack');
      expectInvalidated(ready()..clearPack(), 'clearPack');
      expectInvalidated(ready()..clear(), 'clear');
      expectInvalidated(ready()..resetPdf(), 'resetPdf');
    });
  });

  group('pack changes and clearing', () {
    test('selecting another pack drops the photos and crops of the old one',
        () {
      final cart = Cart()
        ..selectPack(xl6)
        ..addPhotos(paths(6));
      final oldId = cart.items.first.id;
      cart.setCrop(oldId, const CropEdit.skipped());
      cart.selectPack(book);
      expect(cart.selectedPack, same(book));
      expect(cart.isEmpty, isTrue);
      expect(cart.cropFor(oldId), isNull);
      expect(cart.totalPaise, 30100);
      expect(cart.targetSnapCount, 16);
    });

    test('clearPack keeps the customer details; clear wipes everything', () {
      final cart = Cart()
        ..selectPack(xl6)
        ..addPhotos(paths(2))
        ..setCustomer(
          name: 'Asha',
          phone: '9876543210',
          line1: '12 MG Road',
          line2: '',
          city: 'Surat',
          state: 'Gujarat',
          pincode: '395003',
        );
      expect(cart.fullAddress, '12 MG Road\nSurat, Gujarat, 395003');

      cart.clearPack();
      expect(cart.selectedPack, isNull);
      expect(cart.isEmpty, isTrue);
      expect(cart.totalPaise, 0);
      expect(cart.customerName, 'Asha');

      cart
        ..selectPack(reg18)
        ..addPhotos(paths(2))
        ..clear();
      expect(cart.selectedPack, isNull);
      expect(cart.isEmpty, isTrue);
      expect(cart.customerName, '');
      expect(cart.customerPhone, '');
      expect(cart.fullAddress, '');
    });

    test('fullAddress skips empty parts', () {
      final cart = Cart()
        ..setCustomer(
          name: 'A',
          phone: '9',
          line1: 'Flat 4',
          line2: 'Near Station',
          city: '',
          state: 'Gujarat',
          pincode: '',
        );
      expect(cart.fullAddress, 'Flat 4\nNear Station\nGujarat');
    });
  });

  test('every mutation notifies listeners (the screens rebuild from them)',
      () {
    final cart = Cart();
    var n = 0;
    cart.addListener(() => n++);
    void expectNotified(String what, void Function() action) {
      final before = n;
      action();
      expect(n, greaterThan(before), reason: '$what did not notify');
    }

    expectNotified('selectPack', () => cart.selectPack(xl6));
    expectNotified('addPhotos', () => cart.addPhotos(paths(2)));
    expectNotified('setCrop',
        () => cart.setCrop(cart.items.first.id, const CropEdit.skipped()));
    expectNotified('setPdfProgress', () => cart.setPdfProgress(0.5, 'x'));
    expectNotified('setPdfBytes', () => cart.setPdfBytes(pdf));
    expectNotified('resetPdf', () => cart.resetPdf());
    expectNotified('remove', () => cart.remove(cart.items.first.id));
    expectNotified(
        'setCustomer',
        () => cart.setCustomer(
            name: 'A',
            phone: '9',
            line1: 'x',
            line2: '',
            city: 'c',
            state: 's',
            pincode: '1'));
    expectNotified('clearPack', () => cart.clearPack());
    expectNotified('clear', () => cart.clear());
  });
}
