import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../models/order_record.dart';
import '../models/orders_store.dart';
import '../services/firebase/auth_service.dart';
import '../services/firebase/order_repository.dart';
import '../services/sheet_pdf.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _processing = false;
  String _stage = '';

  void _setStage(String s) {
    if (mounted) setState(() => _stage = s);
  }

  Future<void> _placeOrder() async {
    final cart = context.read<Cart>();
    final orders = context.read<OrdersStore>();
    final pack = cart.selectedPack;
    if (pack == null) return;

    // Real orders need a signed-in customer (the backend enforces this too).
    if (!AuthService.instance.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Login with your mobile number to place the order.')));
      context.push('/login', extra: '/checkout');
      return;
    }

    setState(() => _processing = true);
    final cachedBytes = cart.pdfBytes; // built at /upload, before address

    try {
      // 1. Create the order in Firestore (mints the global order number;
      //    pricing is validated server-side by the security rules).
      _setStage('Placing order…');
      final created = await OrderRepository.instance.createOrder(
        uid: AuthService.instance.uid!,
        pack: pack,
        customerName:
            cart.customerName.isEmpty ? 'Customer' : cart.customerName,
        customerPhone: AuthService.instance.currentUser?.phoneNumber ??
            '+91${cart.customerPhone}',
        address: (
          line1: cart.addressLine1,
          line2: cart.addressLine2,
          city: cart.city,
          state: cart.state,
          pincode: cart.pincode,
        ),
        photoCount: cart.itemCount,
      );

      // 2. Turn the print PDF into per-sheet 300-DPI JPGs and upload them —
      //    this is what reaches the merchant's OneDrive print queue.
      if (cachedBytes != null) {
        _setStage('Preparing print sheets…');
        final jpgs = await SheetPdfService.rasterizeToJpgs(cachedBytes);
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

      // 3. Keep the local record too (offline "My orders" view + merchant
      //    demo screens), using the Firestore id + number.
      final order = OrderRecord(
        id: created.orderId,
        placedAt: DateTime.now(),
        customerName:
            cart.customerName.isEmpty ? 'Customer' : cart.customerName,
        customerPhone: cart.customerPhone.isEmpty
            ? (AuthService.instance.currentUser?.phoneNumber ?? '—')
            : '+91 ${cart.customerPhone}',
        address: cart.fullAddress.isEmpty ? '—' : cart.fullAddress,
        productTitle: pack.size.category.title,
        sizeLabel: pack.size.label,
        sizeDimensions: pack.size.dimensions,
        snapCount: pack.snapCount,
        sheetsNeeded: pack.sheetsNeeded,
        totalPaise: cart.totalPaise,
        photoPaths: cart.items.map((i) => i.localPath).toList(),
        status: OrderStatus.received,
        pdfStatus: cachedBytes != null
            ? SheetPdfStatus.ready
            : SheetPdfStatus.generating,
        pdfBytes: cachedBytes,
      );
      orders.place(order);
      if (cachedBytes == null) {
        _buildSheetsForOrder(orders, order, pack.size);
      }

      if (!mounted) return;
      cart.clear();
      context.go('/order-placed', extra: created.orderId);
    } catch (e) {
      debugPrint('[Checkout] order failed: $e');
      if (!mounted) return;
      setState(() {
        _processing = false;
        _stage = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not place the order: '
              '${e is StateError ? e.message : 'check your connection and retry.'}')));
    }
  }

  /// Background PDF generation fallback (used only if /upload was skipped).
  static Future<void> _buildSheetsForOrder(
    OrdersStore store,
    OrderRecord order,
    dynamic size,
  ) async {
    try {
      final bytes = await SheetPdfService.buildBytes(
        order: order,
        size: size,
      );
      store.setPdf(order.id, bytes);
    } catch (e) {
      debugPrint('[Checkout] background PDF build failed: $e');
      store.markPdfFailed(order.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _SectionHeader(title: 'Order summary'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _SummaryRow(
                      label:
                          '${cart.selectedPack?.snapCount ?? cart.itemCount} ${cart.selectedPack?.size.category.unit ?? "prints"}',
                      value: cart.paiseToRupees(cart.subtotalPaise),
                    ),
                    const Divider(height: 24),
                    _SummaryRow(
                      label: 'Total',
                      value: cart.paiseToRupees(cart.totalPaise),
                      bold: true,
                    ),
                    const SizedBox(height: 4),
                    const Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'Free shipping included.',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            _SectionHeader(title: 'Payment method'),
            Card(
              child: _PaymentOption(
                icon: Icons.account_balance_wallet_rounded,
                title: 'UPI',
                subtitle: 'GPay · PhonePe · Paytm · BHIM',
                selected: true,
              ),
            ),
            const SizedBox(height: 32),
            PrimaryButton(
              label: 'Pay ${cart.paiseToRupees(cart.totalPaise)}',
              icon: Icons.lock_outline_rounded,
              loading: _processing,
              onPressed: _placeOrder,
            ),
            if (_processing && _stage.isNotEmpty) ...[
              const SizedBox(height: 10),
              Center(
                child: Text(
                  _stage,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary),
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Center(
              child: Text(
                '🔒 Secure checkout via Razorpay',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(title,
          style:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(
      {required this.label, required this.value, this.bold = false});
  final String label;
  final String value;
  final bool bold;
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: bold ? 17 : 14,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label, style: style), Text(value, style: style)],
    );
  }
}

class _PaymentOption extends StatelessWidget {
  const _PaymentOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon,
              color: enabled ? AppColors.primary : AppColors.textSecondary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    )),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (selected)
            const Icon(Icons.check_circle, color: AppColors.success),
        ],
      ),
    );
  }
}
