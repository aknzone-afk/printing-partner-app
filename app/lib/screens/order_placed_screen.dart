import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/order_record.dart';
import '../models/orders_store.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

class OrderPlacedScreen extends StatelessWidget {
  const OrderPlacedScreen({super.key, this.orderId});

  /// ID of the order that was just placed. Passed via `context.go(..., extra: id)`
  /// from the checkout flow. `null` only if the user lands here without an
  /// active order (deep link / refresh) — we still show a friendly success.
  final String? orderId;

  @override
  Widget build(BuildContext context) {
    final order = orderId == null
        ? null
        : context.watch<OrdersStore>().findById(orderId!);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Container(
                height: 96,
                width: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(48),
                ),
                child: const Icon(Icons.check_rounded,
                    size: 64, color: AppColors.success),
              ),
              const SizedBox(height: 20),
              const Text(
                'Order placed!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              ),
              if (order != null) ...[
                const SizedBox(height: 6),
                Text(
                  order.displayId,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 20),
                _OrderSummaryCard(order: order),
              ] else ...[
                const SizedBox(height: 12),
                const Text(
                  'Your prints are on the way.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 15,
                      color: AppColors.textSecondary,
                      height: 1.5),
                ),
              ],
              const SizedBox(height: 20),
              const _NextStepsCard(),
              const Spacer(),
              PrimaryButton(
                label: 'Track my order',
                icon: Icons.receipt_long_rounded,
                onPressed: () => context.go('/home?tab=orders'),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => context.go('/home'),
                child: const Text('Place another order'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderSummaryCard extends StatelessWidget {
  const _OrderSummaryCard({required this.order});
  final OrderRecord order;

  @override
  Widget build(BuildContext context) {
    final firstAddressLine =
        order.address.split('\n').firstWhere((s) => s.isNotEmpty,
            orElse: () => '');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _SummaryRow(
              label: '${order.productTitle} · ${order.sizeLabel}',
              value: order.sizeDimensions,
            ),
            const SizedBox(height: 8),
            _SummaryRow(
              label: 'Quantity',
              value: _snapCountLabel,
              dense: true,
            ),
            const Divider(height: 24),
            _SummaryRow(
              label: 'Total paid',
              value: order.totalLabel,
              bold: true,
            ),
            if (firstAddressLine.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.local_shipping_outlined,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Shipping to $firstAddressLine',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _snapCountLabel =>
      '${order.snapCount} ${order.snapCount == 1 ? _singular(order) : _pluralUnit(order)}';

  static String _pluralUnit(OrderRecord o) {
    // Use snap-count rather than category enum because OrderRecord stores titles
    // as strings; "Snapbook" packs already carry the "pages" unit in their label.
    final t = o.productTitle.toLowerCase();
    if (t.contains('snapbook')) return 'pages';
    return 'snaps';
  }

  static String _singular(OrderRecord o) {
    final p = _pluralUnit(o);
    return p.endsWith('s') ? p.substring(0, p.length - 1) : p;
  }
}

class _NextStepsCard extends StatelessWidget {
  const _NextStepsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.primary.withValues(alpha: 0.06),
      elevation: 0,
      child: const Padding(
        padding: EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Step(
              icon: Icons.print_outlined,
              text: 'We print and finish your photos with care.',
            ),
            SizedBox(height: 8),
            _Step(
              icon: Icons.local_shipping_outlined,
              text: 'Courier picks up from our print shop in 1-2 days.',
            ),
            SizedBox(height: 8),
            _Step(
              icon: Icons.home_outlined,
              text: 'Delivered to your door in 3-5 days total.',
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
                fontSize: 13, color: AppColors.textPrimary, height: 1.35),
          ),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.bold = false,
    this.dense = false,
  });

  final String label;
  final String value;
  final bool bold;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final size = dense ? 12.0 : (bold ? 16.0 : 14.0);
    final weight = bold ? FontWeight.w700 : FontWeight.w500;
    final color = dense ? AppColors.textSecondary : AppColors.textPrimary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
                fontSize: size, fontWeight: weight, color: color),
          ),
        ),
        Text(value,
            style: TextStyle(
                fontSize: size, fontWeight: weight, color: color)),
      ],
    );
  }
}
