import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/cart.dart';
import '../models/order_record.dart';
import '../models/orders_store.dart';
import '../services/firebase/auth_service.dart';
import '../services/firebase/order_repository.dart';
import '../services/payment_verifier.dart';
import '../services/sheet_pdf.dart';
import '../services/upi_qr.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

/// UPI payment: the customer scans our QR (amount baked in), pays in their UPI
/// app, and attaches the payment screenshot. Gemini reads it in-app, matches
/// the amount, and only then is the order placed. ₹0 — no payment gateway.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _busy = false;
  String _stage = '';
  String? _error;

  void _setStage(String s) {
    if (mounted) setState(() => _stage = s);
  }

  Future<void> _attachAndVerify() async {
    final cart = context.read<Cart>();
    final rupees = cart.totalPaise / 100.0;

    // 1. Pick the payment screenshot.
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );
    } catch (e) {
      _showError('Could not open your gallery: $e');
      return;
    }
    if (picked == null) return; // cancelled

    setState(() {
      _busy = true;
      _error = null;
      _stage = 'Reading your payment…';
    });

    try {
      // 2. Compress to JPEG for Gemini.
      Uint8List bytes;
      final jpg = await FlutterImageCompress.compressWithFile(
        picked.path,
        minWidth: 1400,
        minHeight: 1400,
        quality: 85,
        format: CompressFormat.jpeg,
      );
      bytes = jpg ?? await picked.readAsBytes();

      // 3. Verify with Gemini (amount + soft payee match).
      final hasPayee = UpiQr.merchantUpiId.isNotEmpty;
      final check = await PaymentVerifier.instance.verify(
        screenshotJpg: bytes,
        expectedRupees: rupees,
        ourUpiId: hasPayee ? UpiQr.merchantUpiId : null,
        ourName: hasPayee ? UpiQr.merchantName : null,
      );

      if (!check.verified) {
        setState(() {
          _busy = false;
          _stage = '';
          _error = check.reason;
        });
        return;
      }

      // 4. Payment confirmed → place the order.
      await _placeOrder(upiProof: {
        'method': 'upi',
        'amountRupees': check.amountRead ?? rupees,
        'utr': check.utr ?? '',
        'payee': check.payee ?? '',
        'geminiVerified': true,
      });
    } catch (e) {
      debugPrint('[Checkout] verify/place failed: $e');
      setState(() {
        _busy = false;
        _stage = '';
        _error = 'Something went wrong: $e';
      });
    }
  }

  Future<void> _placeOrder({required Map<String, dynamic> upiProof}) async {
    final cart = context.read<Cart>();
    final orders = context.read<OrdersStore>();
    final pack = cart.selectedPack;
    if (pack == null) return;

    final cachedBytes = cart.pdfBytes; // built at /upload

    _setStage('Placing order…');
    final uid = await AuthService.instance.ensureSignedIn();
    if (uid == null) {
      setState(() {
        _busy = false;
        _stage = '';
        _error = 'Could not reach the server. Check your internet and retry.';
      });
      return;
    }

    final created = await OrderRepository.instance.createOrder(
      uid: uid,
      pack: pack,
      customerName: cart.customerName.isEmpty ? 'Customer' : cart.customerName,
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

    // Turn the print PDF into per-sheet 300-DPI JPGs and upload them.
    if (cachedBytes != null) {
      _setStage('Preparing print sheets…');
      final jpgs = await SheetPdfService.rasterizeToJpgs(
        cachedBytes,
        pageCount: pack.sheetsNeeded,
      );
      var lastPct = -1;
      await OrderRepository.instance.uploadSheets(
        orderId: created.orderId,
        sheetJpgs: jpgs,
        onProgress: (done, total) {
          final pct = (done * 100 ~/ total);
          if (pct != lastPct) {
            lastPct = pct;
            _setStage('Uploading sheets…  $pct%');
          }
        },
      );
    }

    final order = OrderRecord(
      id: created.orderId,
      placedAt: DateTime.now(),
      customerName: cart.customerName.isEmpty ? 'Customer' : cart.customerName,
      customerPhone: cart.customerPhone.isEmpty ? '—' : '+91 ${cart.customerPhone}',
      address: cart.fullAddress.isEmpty ? '—' : cart.fullAddress,
      productTitle: pack.size.category.title,
      sizeLabel: pack.size.label,
      sizeDimensions: pack.size.dimensions,
      snapCount: pack.snapCount,
      sheetsNeeded: pack.sheetsNeeded,
      totalPaise: cart.totalPaise,
      photoPaths: cart.items.map((i) => i.localPath).toList(),
      status: OrderStatus.received,
      pdfStatus:
          cachedBytes != null ? SheetPdfStatus.ready : SheetPdfStatus.generating,
      pdfBytes: cachedBytes,
    );
    orders.place(order);
    if (cachedBytes == null) {
      _buildSheetsForOrder(orders, order, pack.size);
    }

    if (!mounted) return;
    cart.clear();
    context.go('/order-placed', extra: created.orderId);
  }

  static Future<void> _buildSheetsForOrder(
      OrdersStore store, OrderRecord order, dynamic size) async {
    try {
      final bytes = await SheetPdfService.buildBytes(order: order, size: size);
      store.setPdf(order.id, bytes);
    } catch (e) {
      debugPrint('[Checkout] background PDF build failed: $e');
      store.markPdfFailed(order.id);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    final rupees = cart.totalPaise / 100.0;
    final amountLabel = cart.paiseToRupees(cart.totalPaise);

    return Scaffold(
      appBar: AppBar(title: const Text('Pay & place order')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Amount
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
            const SizedBox(height: 20),

            if (!UpiQr.configured)
              _SetupPending()
            else ...[
              // QR to scan
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
                        border:
                            Border.all(color: AppColors.textSecondary.withValues(alpha: 0.2)),
                      ),
                      child: QrImageView(
                        data: UpiQr.withAmount(rupees),
                        size: 230,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('Pay exactly $amountLabel to ${UpiQr.merchantName}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSecondary)),
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
                PrimaryButton(
                  label: 'I\'ve paid — attach screenshot',
                  icon: Icons.verified_rounded,
                  onPressed: _attachAndVerify,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFDECEA),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
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
                  ),
                ],
              ],
              const SizedBox(height: 14),
              const Center(
                child: Text(
                  '🔒 We read your screenshot only to confirm the amount.',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
            ],
          ],
        ),
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
        row('1', 'Scan the QR above with GPay / PhonePe / Paytm and pay $amountLabel.'),
        row('2', 'Take a screenshot of the "payment successful" screen.'),
        row('3', 'Tap below and attach that screenshot — we confirm it instantly.'),
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
