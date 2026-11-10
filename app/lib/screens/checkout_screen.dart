import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/cart.dart';
import '../models/order_record.dart';
import '../models/orders_store.dart';
import '../models/print_packages.dart';
import '../services/backend_api.dart';
import '../services/firebase/auth_service.dart';
import '../services/firebase/order_repository.dart';
import '../services/payment_verifier.dart';
import '../services/pending_upload.dart';
import '../services/photo_export.dart';
import '../services/shop_contact.dart';
import '../services/upi_qr.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

/// UPI payment: the customer scans our QR (amount baked in), pays in their UPI
/// app, and attaches the payment screenshot. The backend reads it, matches the
/// amount, and hands back a one-time payment token. Only then is the order
/// placed and every INDIVIDUAL cropped photo uploaded to the shop's backend
/// (`/ingest`). ₹0 — no payment gateway, no Firestore blobs.
///
/// Outcomes of `/ingest` and what the screen does:
///  * 200 (incl. `duplicate:true` = already filed on an earlier attempt whose
///    answer was lost) → order complete, local record written, cart cleared.
///  * 409 for THIS order number → same as 200 (filed earlier); 409 for a
///    different order → real rejection (UTR used elsewhere), no retry.
///  * 402 `token_expired` → the order is KEPT; the customer re-attaches the
///    same screenshot to get a fresh pass and the upload resumes for it.
///  * 402 anything else (forged / amount mismatch) → rejection, no retry.
///  * network / 5xx / 413 → "Retry upload" with the same order + token.
/// The resume tuple is persisted ([PendingUpload]) so leaving the screen or
/// an app kill mid-upload never mints a second order.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _busy = false;
  String _stage = '';
  String? _error;

  /// The authoritative price (paise) read from the catalog — the amount the
  /// order will actually book. Used for the QR + the screenshot amount-check so
  /// the customer never pays a value the order would then be rejected for.
  /// Null until loaded; there is NO fallback to the client-side price (that
  /// would let a catalog/print_packages drift book a different amount than
  /// was paid), only a Retry.
  int? _authoritativePaise;
  bool _priceError = false;

  /// Backend readiness from GET /health. Null while unknown/checking; true only
  /// when the server is up AND Gemini is configured AND the catalog is loaded.
  /// The QR + attach button stay hidden until this is true, so a customer can
  /// never pay while the server cannot actually verify the payment (no Gemini)
  /// or would reject every order (empty catalog).
  bool? _backendReady;
  bool _healthChecking = false;

  /// Client-chosen Firestore id for this checkout attempt. Minted once and
  /// reused, so a createOrder whose commit succeeded but whose answer was lost
  /// is found again instead of producing a second order + number.
  String? _orderDocId;

  /// Set once the order exists in Firestore, so a retry after a failed photo
  /// upload RESUMES the upload instead of minting a SECOND order (honours the
  /// "never create duplicate orders" rule). Mirrored to [PendingUpload] so the
  /// same holds across a back-press or an app kill.
  String? _placedOrderId;
  String? _placedOrderNumber;
  String? _placedAtIso;
  String? _placedUid;

  /// The backend payment token from the verified screenshot. Never written to
  /// Firestore. Null while a kept order needs a fresh pass (402 token_expired).
  String? _placedToken;

  /// True when the backend said the pass expired: the order is kept and the
  /// next tap re-attaches the SAME screenshot for it (no new order).
  bool _needsFreshToken = false;

  /// True once /ingest has been attempted with the current token — a later
  /// 409 without an orderNumber is then read as "filed on that attempt".
  bool _ingestAttempted = false;

  /// Rendered cropped JPEGs, cached so a Retry re-runs ONLY the upload.
  List<Uint8List>? _renderedJpgs;

  /// Upload reached a terminal state: a network/server failure that can be
  /// retried, or a real 402/409 rejection that must NOT be retried.
  bool _uploadFailed = false;
  bool _rejected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkHealth();
      _loadPrice();
      _restorePending();
    });
  }

  /// Ask the backend whether it can actually take a payment right now (server
  /// up, Gemini configured, catalog loaded). Never throws.
  Future<void> _checkHealth() async {
    if (_healthChecking) return;
    if (mounted) setState(() => _healthChecking = true);
    bool ready = false;
    try {
      final h = await BackendApi.health();
      ready = h.ok && h.ai && h.catalog > 0;
    } catch (e) {
      debugPrint('[Checkout] health check failed: $e');
      ready = false;
    }
    if (mounted) {
      setState(() {
        _backendReady = ready;
        _healthChecking = false;
      });
    }
  }

  static String _packKey(PrintPack pack) =>
      '${pack.size.category.slug}|${pack.size.label}|${pack.snapCount}';

  Future<void> _loadPrice() async {
    final pack = context.read<Cart>().selectedPack;
    if (pack == null) return;
    if (_priceError) setState(() => _priceError = false);
    try {
      final paise = await OrderRepository.instance.catalogPriceInPaise(pack);
      if (mounted) setState(() => _authoritativePaise = paise);
    } catch (e) {
      debugPrint('[Checkout] catalog price failed: $e');
      // No fallback to the client-side price: the QR and the server amount
      // check must only ever use the price the order will book.
      if (mounted) setState(() => _priceError = true);
    }
  }

  /// Re-enters "Retry upload" / "Re-attach screenshot" mode for an order that
  /// was paid and created earlier but whose photos never reached the backend
  /// (screen left, app killed). Only when the SAME cart is still here.
  Future<void> _restorePending() async {
    final rec = await PendingUpload.load();
    if (!mounted || rec == null) return;
    if (_placedOrderId != null || _busy) return; // already placing here
    final cart = context.read<Cart>();
    final pack = cart.selectedPack;
    String? currentUid;
    try {
      currentUid = AuthService.instance.uid;
    } catch (_) {
      currentUid = null; // Firebase not initialised yet: uid unknown
    }
    if (pack == null ||
        cart.isEmpty ||
        !rec.isFor(
          uid: currentUid,
          packKey: _packKey(pack),
          photoCount: cart.itemCount,
        )) {
      // A different cart (new pack picked) or a different customer uid: leave
      // the record alone, it expires with the token. This checkout is a new
      // order.
      debugPrint('[Checkout] pending upload #${rec.orderNumber} does not '
          'match this cart / customer — not resumed');
      return;
    }
    setState(() {
      _orderDocId = rec.orderId;
      _placedOrderId = rec.orderId;
      _placedOrderNumber = rec.orderNumber;
      _placedAtIso = rec.placedAtIso.isEmpty ? null : rec.placedAtIso;
      _placedUid = rec.uid.isEmpty ? null : rec.uid;
      _placedToken = rec.token;
      _ingestAttempted = rec.ingestAttempted;
      _needsFreshToken = rec.token == null;
      _authoritativePaise ??= rec.amountPaise > 0 ? rec.amountPaise : null;
      _uploadFailed = true;
      _rejected = false;
      _error = _needsFreshToken
          ? 'Your upload pass expired. Tap below and re-attach the same '
              'payment screenshot — your order #${rec.orderNumber} is kept.'
          : 'Your payment is confirmed and order #${rec.orderNumber} is '
              'placed, but your photos have not reached us yet. Tap Retry '
              'upload to send them.';
    });
  }

  Future<void> _persistPending() async {
    if (!mounted) return; // needs the cart from context
    final orderId = _placedOrderId;
    final number = _placedOrderNumber;
    final cart = context.read<Cart>();
    final pack = cart.selectedPack;
    if (orderId == null || number == null || pack == null) return;
    await PendingUpload.save(PendingUpload(
      orderId: orderId,
      orderNumber: number,
      placedAtIso: _placedAtIso ?? '',
      token: _placedToken,
      uid: _placedUid ?? AuthService.instance.uid ?? '',
      packKey: _packKey(pack),
      photoCount: cart.itemCount,
      amountPaise: _authoritativePaise ?? 0,
      ingestAttempted: _ingestAttempted,
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  void _setStage(String s) {
    if (mounted) setState(() => _stage = s);
  }

  Future<void> _attachAndVerify() async {
    if (_busy) return; // re-entrancy guard (double-tap / fast re-tap)
    if (_rejected) return; // backend refused the payment: nothing to retry

    // Already paid + order created, but the photo upload failed: resume the
    // upload directly — don't make the customer re-pick / re-verify the
    // screenshot, and never create a second order.
    if (_placedOrderId != null && _placedToken != null) {
      setState(() {
        _busy = true;
        _error = null;
        _uploadFailed = false;
        _stage = 'Finishing your order…';
      });
      await _uploadToBackend();
      return;
    }

    // Fresh order, OR a kept order whose upload pass expired (re-attach the
    // same screenshot for it). Both need the catalog price for the check.
    final paise = _authoritativePaise;
    if (paise == null) {
      _showSnack('The price has not loaded yet. Tap Retry above.');
      return;
    }
    final reattach = _placedOrderId != null;

    // Claim the flow SYNCHRONOUSLY before the async gallery pick, so a fast
    // double-tap can't start two orders (NEVER-duplicate-orders rule).
    setState(() {
      _busy = true;
      _error = null;
      if (reattach) _uploadFailed = false;
    });

    final rupees = paise / 100.0;

    // 1. Pick the payment screenshot.
    final XFile? picked;
    try {
      picked = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 90);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (reattach) _uploadFailed = true;
      });
      _showSnack('Could not open your gallery: $e');
      return;
    }
    if (!mounted) return;
    if (picked == null) {
      setState(() {
        _busy = false;
        if (reattach) _uploadFailed = true;
      });
      return; // cancelled
    }
    setState(() => _stage = 'Reading your payment…');

    try {
      // 2. Compress to JPEG for the verifier.
      final jpg = await FlutterImageCompress.compressWithFile(
        picked.path,
        minWidth: 1400,
        minHeight: 1400,
        quality: 85,
        format: CompressFormat.jpeg,
      );
      final Uint8List bytes = jpg ?? await picked.readAsBytes();
      if (!mounted) return;

      // 3. Verify (amount + soft payee match + UTR capture → payment token).
      final hasPayee = UpiQr.merchantUpiId.isNotEmpty;
      final check = await PaymentVerifier.instance.verify(
        screenshotJpg: bytes,
        expectedRupees: rupees,
        ourUpiId: hasPayee ? UpiQr.merchantUpiId : null,
        ourName: hasPayee ? UpiQr.merchantName : null,
      );
      if (!mounted) return;

      if (!check.verified) {
        setState(() {
          _busy = false;
          _stage = '';
          _error = check.reason;
          if (reattach) _uploadFailed = true;
        });
        return;
      }

      // A verified check without a token cannot be filed (the backend needs
      // it on /ingest) — fail BEFORE any order is created.
      final String? token = check.token;
      if (token == null || token.isEmpty) {
        setState(() {
          _busy = false;
          _stage = '';
          _error =
              'Payment looked fine but we did not get an upload pass from the '
              'server. Please tap again to re-attach the screenshot.';
          if (reattach) _uploadFailed = true;
        });
        return;
      }

      if (reattach) {
        // 4a. Fresh pass for the KEPT order: resume its upload, no new order.
        _placedToken = token;
        _needsFreshToken = false;
        await _persistPending();
        if (!mounted) return;
        await _uploadToBackend();
        return;
      }

      // 4b. Payment confirmed → place the order + upload the photos.
      //     (The token is deliberately NOT part of the proof written to
      //     Firestore — it stays in memory + the local pending record only.)
      await _placeOrder(
        upiProof: {
          'method': 'upi',
          'amountRupees': check.amountRead ?? rupees,
          'utr': check.utr ?? '',
          'payee': check.payee ?? '',
          'geminiVerified': true,
        },
        token: token,
      );
    } catch (e) {
      debugPrint('[Checkout] verify/place failed: $e');
      if (mounted) {
        setState(() {
          _busy = false;
          _stage = '';
          _error = _placedOrderId == null
              ? 'Something went wrong: $e'
              : 'Your payment was accepted and the order is placed — we\'re '
                  'still sending your photos. Tap Retry upload to finish.';
          if (_placedOrderId != null) _uploadFailed = true;
        });
      }
    }
  }

  Future<void> _placeOrder({
    required Map<String, dynamic> upiProof,
    required String token,
  }) async {
    final cart = context.read<Cart>();
    final pack = cart.selectedPack;
    if (pack == null) {
      setState(() {
        _busy = false;
        _stage = '';
      });
      return;
    }

    // 1. Create the order ONCE. A retry after a failed upload reuses the
    //    already-created order so a second order/number is never minted.
    if (_placedOrderId == null) {
      _setStage('Placing order…');
      final uid = await AuthService.instance.ensureSignedIn();
      if (!mounted) return;
      if (uid == null) {
        setState(() {
          _busy = false;
          _stage = '';
          _error = 'Could not reach the server. Check your internet and retry.';
        });
        return;
      }
      // Stable per checkout attempt: an ack-lost commit is found on re-tap.
      _orderDocId ??= OrderRepository.instance.newOrderId();
      final created = await OrderRepository.instance.createOrder(
        orderId: _orderDocId!,
        uid: uid,
        pack: pack,
        customerName:
            cart.customerName.isEmpty ? 'Customer' : cart.customerName,
        customerPhone: '+91${cart.customerPhone}',
        address: (
          line1: cart.addressLine1,
          line2: cart.addressLine2,
          city: cart.city,
          state: cart.state,
          pincode: cart.pincode,
        ),
        photoCount: cart.itemCount,
        upiProof: upiProof,
      );
      // Survive a later upload failure (no second order, same token) — in
      // memory AND on disk, so a back-press / app kill resumes this order.
      _placedOrderId = created.orderId;
      _placedOrderNumber = created.orderNumber;
      _placedAtIso = DateTime.now().toUtc().toIso8601String();
      _placedUid = uid;
      _placedToken = token;
      _ingestAttempted = false;
      if (!mounted) {
        // The State is gone, but the order exists: record it for resume.
        await PendingUpload.save(PendingUpload(
          orderId: created.orderId,
          orderNumber: created.orderNumber,
          placedAtIso: _placedAtIso ?? '',
          token: token,
          uid: uid,
          packKey: _packKey(pack),
          photoCount: cart.itemCount,
          amountPaise: _authoritativePaise ?? 0,
          ingestAttempted: false,
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ));
        return;
      }
      await _persistPending();
      if (!mounted) return;
    }

    // 2. Render the cropped photos + upload them to the backend. The local
    //    OrdersStore record is written only once the backend has FILED the
    //    photos, so a refused payment never shows up as a "received" order.
    await _uploadToBackend();
  }

  /// Renders (once, cached) and uploads the cropped photos for the already
  /// created order. Safe to call again after a failure: same orderId, same
  /// token, same JPEGs — only the upload is repeated.
  Future<void> _uploadToBackend() async {
    final orderId = _placedOrderId;
    final token = _placedToken;
    if (orderId == null || token == null) return;

    final cart = context.read<Cart>();
    final pack = cart.selectedPack;
    try {
      if (_renderedJpgs == null) {
        if (pack == null || cart.isEmpty) {
          throw const PhotoExportException(
              'Your photos are no longer in the cart on this device.');
        }
        final total = cart.itemCount;
        _setStage('Preparing photo 1 of $total…');
        final jpgs = await renderCroppedJpegs(
          cart,
          onProgress: (done, t) {
            if (done < t) _setStage('Preparing photo ${done + 1} of $t…');
          },
        );
        if (!mounted) return;
        _renderedJpgs = jpgs;
      }
      final jpgs = _renderedJpgs!;
      final mb = jpgs.fold<int>(0, (s, b) => s + b.length) / (1024 * 1024);
      _setStage(
          'Uploading ${jpgs.length} photo${jpgs.length == 1 ? '' : 's'} '
          '(${mb.toStringAsFixed(1)} MB)…');

      // Remember that THIS token has been sent once: if the answer is lost
      // and the retry gets 409, that is "already filed", not "used elsewhere".
      final attemptedBefore = _ingestAttempted;
      _ingestAttempted = true;
      await _persistPending();
      if (!mounted) return;

      final paise = _authoritativePaise;
      final res = await BackendApi.ingest(
        order: <String, dynamic>{
          'orderNumber': _placedOrderNumber ?? '',
          'category': pack?.size.category.slug ?? '',
          'size': pack?.size.label ?? '',
          // The server's price table is authoritative; these are the pack
          // this order claims to be, so it can tie the paid amount to it.
          'snapCount': pack?.snapCount ?? 0,
          if (paise != null) 'amountRupees': paise / 100.0,
          'placedAt': _placedAtIso ?? DateTime.now().toUtc().toIso8601String(),
          // So the merchant receives WHO the order is for (the server writes
          // these next to the photos); the server length-caps them.
          'customerName': cart.customerName,
          'customerPhone':
              cart.customerPhone.isEmpty ? '' : '+91${cart.customerPhone}',
          'address': cart.fullAddress,
        },
        token: token,
        photosJpg: jpgs,
      );
      if (!mounted) return;

      if (res.ok) {
        // Includes duplicate:true — the server had already filed this order.
        await _finishFiled(orderId,
            note: res.duplicate ? 'duplicate: filed on an earlier attempt' : null);
        return;
      }

      if (res.status == 409) {
        // The UTR is in the server ledger. For THIS order number that means a
        // retry after a lost response — the photos are filed. Only a
        // DIFFERENT order number is a real "used for another order".
        final sameOrder = (res.orderNumber != null &&
                res.orderNumber == _placedOrderNumber) ||
            (res.orderNumber == null && attemptedBefore);
        if (sameOrder) {
          await _finishFiled(orderId,
              note: '409 after retry — filed on an earlier attempt');
          return;
        }
        await _reject(orderId, '${res.status}: ${res.error ?? ''}',
            'This payment (UTR) was already used for another order'
            '${res.orderNumber == null ? '' : ' (#${res.orderNumber})'}, so '
            'the photos were not sent. Order #${_placedOrderNumber ?? ''} is '
            'saved — please contact us before paying again.');
        return;
      }

      if (res.status == 402) {
        if (res.error == 'token_expired') {
          // Authentic but stale pass: the UTR is NOT burnt (the ledger is
          // written only on a successful filing), so the same screenshot
          // re-verifies. Keep the order; ask for a re-attach, no new order.
          await _safeMark(orderId, 'upload_failed',
              error: '402: payment token expired — re-attach');
          _placedToken = null;
          _needsFreshToken = true;
          await _persistPending();
          if (!mounted) return;
          setState(() {
            _busy = false;
            _stage = '';
            _uploadFailed = true;
            _error = 'Your upload pass expired. Tap below and re-attach the '
                'same payment screenshot — your order '
                '#${_placedOrderNumber ?? ''} is kept.';
          });
          return;
        }
        // Forged / missing token, or the paid amount does not cover this pack.
        await _reject(orderId, '${res.status}: ${res.error ?? ''}',
            'The server could not confirm this payment, so the photos were '
            'not sent. Order #${_placedOrderNumber ?? ''} is saved — please '
            'contact us; do not pay again.');
        return;
      }

      if (res.status == 400) {
        // A 400 from /ingest is a permanent content problem (pack not in the
        // catalog — e.g. catalog.json not deployed — amount/pack mismatch,
        // order number already taken, empty photo). Retrying the same photos
        // will always fail, so reject with a clear message instead of looping
        // on "Retry upload".
        final detail = (res.error == null || res.error!.isEmpty)
            ? 'the order details did not match our catalogue'
            : res.error == 'unknown_pack'
                ? 'this print pack is not set up on the server yet'
                : res.error!;
        await _reject(orderId, '${res.status}: ${res.error ?? ''}',
            'We could not file this order ($detail), so your photos were not '
            'sent. Payment for order #${_placedOrderNumber ?? ''} is saved — '
            'please contact the shop; do not pay again.');
        return;
      }

      throw _IngestFailure(res.status, res.error);
    } catch (e) {
      debugPrint('[Checkout] upload failed: $e');
      await _safeMark(orderId, 'upload_failed', error: '$e');
      if (!mounted) return;
      final reason = e is PhotoExportException
          ? e.message
          : e is _IngestFailure
              ? e.message
              : 'Check your internet connection.';
      setState(() {
        _busy = false;
        _stage = '';
        _uploadFailed = true;
        _error = 'Your payment is confirmed and order '
            '#${_placedOrderNumber ?? ''} is placed, but your photos could not '
            'be sent yet. $reason Tap Retry upload to send them again.';
      });
    }
  }

  /// The backend has the photos: record the order locally, drop the resume
  /// record, clear the cart and show the order-placed screen.
  Future<void> _finishFiled(String orderId, {String? note}) async {
    _setStage('Done!');
    await _safeMark(orderId, 'filed', error: note);
    if (!mounted) return;
    final cart = context.read<Cart>();
    final orders = context.read<OrdersStore>();
    final pack = cart.selectedPack;
    if (pack != null && orders.findById(orderId) == null) {
      orders.place(OrderRecord(
        id: orderId,
        orderNumber: _placedOrderNumber ?? '',
        placedAt: DateTime.tryParse(_placedAtIso ?? '')?.toLocal() ??
            DateTime.now(),
        customerName:
            cart.customerName.isEmpty ? 'Customer' : cart.customerName,
        customerPhone:
            cart.customerPhone.isEmpty ? '—' : '+91 ${cart.customerPhone}',
        address: cart.fullAddress.isEmpty ? '—' : cart.fullAddress,
        productTitle: pack.size.category.title,
        sizeLabel: pack.size.label,
        sizeDimensions: pack.size.dimensions,
        snapCount: pack.snapCount,
        sheetsNeeded: pack.sheetsNeeded,
        totalPaise: _authoritativePaise ?? pack.priceInPaise,
        photoPaths: cart.items.map((i) => i.localPath).toList(),
        status: OrderStatus.received,
        // No sheet PDF any more — photos are filed by the backend.
        pdfStatus: SheetPdfStatus.archived,
      ));
    }
    await PendingUpload.clear();
    if (!mounted) return;
    _renderedJpgs = null;
    cart.clear();
    context.go('/order-placed', extra: orderId);
  }

  /// A real refusal (UTR used by another order, forged token, amount short):
  /// the order doc is marked, never retried, and never shown as placed.
  Future<void> _reject(String orderId, String backendError, String msg) async {
    await _safeMark(orderId, 'rejected', error: backendError);
    await PendingUpload.clear();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stage = '';
      _rejected = true;
      _uploadFailed = false;
      _needsFreshToken = false;
      _error = msg;
    });
  }

  /// markBackend must never turn a finished upload into a visible failure.
  Future<void> _safeMark(String orderId, String status,
      {String? error}) async {
    try {
      await OrderRepository.instance
          .markBackend(orderId, status, error: error);
    } catch (e) {
      debugPrint('[Checkout] markBackend($status) failed: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    final paise = _authoritativePaise;
    final amountLabel = paise == null ? '…' : cart.paiseToRupees(paise);
    final priceLoading = paise == null && !_priceError;
    final retryMode = _placedOrderId != null &&
        _placedToken != null &&
        _uploadFailed &&
        !_rejected;
    final reattachMode =
        _placedOrderId != null && _needsFreshToken && !_rejected;
    final canPay = retryMode || (paise != null && !_busy);
    // Gate only a FRESH payment on backend readiness: an order that is already
    // placed must still be able to finish its upload even while a health probe
    // is pending or failed.
    final showSetup = _placedOrderId == null && _backendReady != true;

    return PopScope(
      // Never leave while an order is being created / sent: the resume state
      // would otherwise be abandoned mid-flight. Leaving in retry mode is
      // fine — the pending record brings the order back on return.
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _showSnack('Please wait — your order is being sent.');
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Pay & place order')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Amount to pay',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      Text(amountLabel,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
              if (_priceError && paise == null) ...[
                const SizedBox(height: 12),
                _PriceError(onRetry: _loadPrice),
              ],
              const SizedBox(height: 20),
              if (showSetup)
                _BackendNotReady(
                    checking: _healthChecking, onRetry: _checkHealth)
              else if (!UpiQr.configured)
                _SetupPending()
              else ...[
                Center(
                  child: Column(
                    children: [
                      const Text('Scan & pay with any UPI app',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      const Text('GPay · PhonePe · Paytm · BHIM',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: AppColors.textSecondary
                                  .withValues(alpha: 0.2)),
                        ),
                        child: paise == null
                            ? SizedBox(
                                width: 230,
                                height: 230,
                                child: Center(
                                  child: priceLoading
                                      ? const CircularProgressIndicator()
                                      : const Icon(Icons.qr_code_2_rounded,
                                          size: 72,
                                          color: AppColors.textSecondary),
                                ),
                              )
                            : QrImageView(
                                data: UpiQr.withAmount(paise / 100.0),
                                size: 230,
                                backgroundColor: Colors.white,
                              ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                          paise == null
                              ? 'The QR appears once the price has loaded.'
                              : 'Pay exactly $amountLabel to ${UpiQr.merchantName}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                      const SizedBox(height: 14),
                      _UpiIdRow(
                        upiId: UpiQr.merchantUpiId,
                        onCopied: () => _showSnack('UPI id copied'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _Steps(amountLabel: amountLabel),
                const SizedBox(height: 24),
                if (_busy && _stage.isNotEmpty) ...[
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(_stage,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary)),
                  ),
                ] else ...[
                  if (!_rejected)
                    PrimaryButton(
                      label: retryMode
                          ? 'Retry upload'
                          : reattachMode
                              ? 'Re-attach screenshot'
                              : priceLoading
                                  ? 'Loading…'
                                  : 'I\'ve paid — attach screenshot',
                      icon: retryMode
                          ? Icons.cloud_upload_rounded
                          : Icons.verified_rounded,
                      onPressed: canPay ? _attachAndVerify : null,
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFDECEA),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.info_outline,
                                  color: Color(0xFFC0392B), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_error!,
                                    style: const TextStyle(
                                        fontSize: 13, color: Color(0xFFC0392B))),
                              ),
                            ],
                          ),
                          if (ShopContact.whatsapp.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            _ContactRow(
                              whatsapp: ShopContact.whatsapp,
                              onCopied: () => _showSnack('Number copied'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 14),
                const Center(
                  child: Text(
                    '🔒 We read your screenshot only to confirm the amount.',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A non-2xx /ingest response other than a handled 402/409 (retryable).
class _IngestFailure implements Exception {
  const _IngestFailure(this.status, this.error);
  final int status;
  final String? error;

  String get message {
    if (status == 413) {
      return 'The photos are too large for the server in one go.';
    }
    if (status == 0) return 'Check your internet connection.';
    return 'The server replied $status${error == null ? '' : ' ($error)'}.';
  }

  @override
  String toString() => 'ingest $status: ${error ?? ''}';
}

class _PriceError extends StatelessWidget {
  const _PriceError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off_rounded,
              color: Color(0xFFC0392B), size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Could not load the price. Check your internet and tap Retry.',
              style: TextStyle(fontSize: 13, color: Color(0xFFC0392B)),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.amountLabel});
  final String amountLabel;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 13, color: AppColors.textSecondary);
    Widget row(String n, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: AppColors.primary,
                child: Text(n,
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(t, style: style)),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('1',
            'Pay $amountLabel. From another phone, scan the QR above with GPay '
            '/ PhonePe / Paytm. On this phone, screenshot the QR and open it in '
            'your UPI app, or tap Copy and pay the UPI id above.'),
        row('2', 'Take a screenshot of the "payment successful" screen.'),
        row('3',
            'Tap below and attach that screenshot — we confirm it instantly.'),
      ],
    );
  }
}

class _SetupPending extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.hourglass_bottom_rounded, color: Color(0xFFB26A00)),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Payment is being set up — the UPI QR will appear here shortly. '
              'Please check back in a little while.',
              style: TextStyle(fontSize: 13, color: Color(0xFF8A5300)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of the QR + attach button when the backend cannot yet take a
/// payment (health probe unknown/failed, Gemini off, or empty catalog). Lets
/// the customer re-check without leaving the screen, so no one pays blind.
class _BackendNotReady extends StatelessWidget {
  const _BackendNotReady({required this.checking, required this.onRetry});
  final bool checking;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.hourglass_bottom_rounded, color: Color(0xFFB26A00)),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Payments are being set up, please try again shortly.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF8A5300)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: checking
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The merchant's UPI id under the QR, so a customer paying from the same phone
/// (who cannot scan the QR on their own screen) can copy it and pay.
class _UpiIdRow extends StatelessWidget {
  const _UpiIdRow({required this.upiId, required this.onCopied});
  final String upiId;
  final VoidCallback onCopied;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('UPI id: ',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        Flexible(
          child: SelectableText(
            upiId,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy_rounded, size: 18),
          tooltip: 'Copy UPI id',
          visualDensity: VisualDensity.compact,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: upiId));
            onCopied();
          },
        ),
      ],
    );
  }
}

/// The shop's WhatsApp number inside an error box, so "contact the shop" is
/// actionable: selectable + one-tap copy.
class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.whatsapp, required this.onCopied});
  final String whatsapp;
  final VoidCallback onCopied;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFC0392B);
    return Row(
      children: [
        const Icon(Icons.chat_rounded, size: 16, color: red),
        const SizedBox(width: 6),
        const Text('WhatsApp: ', style: TextStyle(fontSize: 13, color: red)),
        Flexible(
          child: SelectableText(
            whatsapp,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: red),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy_rounded, size: 18, color: red),
          tooltip: 'Copy number',
          visualDensity: VisualDensity.compact,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: whatsapp));
            onCopied();
          },
        ),
      ],
    );
  }
}
