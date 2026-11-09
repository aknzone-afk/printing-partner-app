import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../models/order_record.dart';
import '../models/orders_store.dart';
import '../services/sheet_pdf.dart';
import '../theme.dart';
import '../utils/sample_images.dart';
import '../widgets/polaroid_frame.dart';
import '../widgets/pp_logo.dart';
import '../widgets/primary_button.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab});

  /// Optional query-param hook: deep-linking with `/home?tab=orders` lands
  /// the customer on the Orders tab (e.g. after placing an order).
  final String? initialTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tabIndex = switch (widget.initialTab) {
    'orders' => 1,
    'profile' => 2,
    _ => 0,
  };
  static const _titles = ['PRINTING PARTNER', 'MY ORDERS', 'PROFILE'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        // TODO(phase2): replace with proper 5-tap + PIN unlock for merchant.
        // For now: long-press the title to open the merchant dashboard so we
        // can demo the full flow on a physical device that has no URL bar.
        title: GestureDetector(
          onLongPress: () => context.push('/merchant'),
          child: _tabIndex == 0
              ? const PPLogoLockup(height: 30)
              : Text(_titles[_tabIndex]),
        ),
        elevation: 0,
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          const _HomeTab(),
          const _OrdersTab(),
          const _ProfileTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long_rounded),
              label: 'Orders'),
          NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile'),
        ],
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            _ProductCard(
              title: 'Snaps',
              ctaLabel: 'Print Now',
              bgColor: AppColors.lavender,
              accentColor: AppColors.primary,
              imageIds: const [1027, 1062, 64], // family / friends / portrait
              variant: _ProductVariant.scatteredPolaroids,
              onTap: () => context.push('/photo-packages'),
            ),
            const SizedBox(height: 12),
            _ProductCard(
              title: 'Polaroid',
              ctaLabel: 'Print Now',
              bgColor: AppColors.peach,
              accentColor: AppColors.accent,
              imageIds: const [342], // smiling woman
              variant: _ProductVariant.singlePolaroid,
              onTap: () => context.push('/polaroid-packages'),
            ),
            const SizedBox(height: 12),
            _ProductCard(
              title: 'SnapBook',
              ctaLabel: 'Print Now',
              bgColor: AppColors.blush,
              accentColor: AppColors.primary,
              imageIds: const [1015, 152], // mountain + ocean (book pages)
              variant: _ProductVariant.openBook,
              onTap: () => context.push('/snapbook-packages'),
            ),
            if (!cart.isEmpty) ...[
              const SizedBox(height: 24),
              PrimaryButton(
                label: 'Continue order (${cart.totalPrints} prints)',
                icon: Icons.shopping_cart_rounded,
                onPressed: () => context.push('/cart'),
              ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _OrdersTab extends StatelessWidget {
  const _OrdersTab();

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersStore>().all;
    if (orders.isEmpty) {
      return const SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.receipt_long_outlined,
                    size: 80, color: AppColors.textSecondary),
                SizedBox(height: 16),
                Text('No orders yet',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                SizedBox(height: 8),
                Text(
                  'Your past orders will appear here.',
                  style: TextStyle(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return SafeArea(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: orders.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _CustomerOrderCard(order: orders[i]),
      ),
    );
  }
}

class _CustomerOrderCard extends StatefulWidget {
  const _CustomerOrderCard({required this.order});
  final OrderRecord order;

  @override
  State<_CustomerOrderCard> createState() => _CustomerOrderCardState();
}

class _CustomerOrderCardState extends State<_CustomerOrderCard> {
  bool _busy = false;

  Future<void> _download() async {
    setState(() => _busy = true);
    try {
      await SheetPdfService.downloadPrebuilt(widget.order);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order =
        context.watch<OrdersStore>().findById(widget.order.id) ?? widget.order;
    final fmt = DateFormat('d MMM, h:mm a');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  order.displayId,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Color(order.status.color)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    order.status.label.toUpperCase(),
                    style: TextStyle(
                      color: Color(order.status.color),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${order.productTitle} · ${order.sizeDimensions}',
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              '${order.snapCount} snaps · placed ${fmt.format(order.placedAt)}',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  order.totalLabel,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                _customerDownloadButton(order),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _customerDownloadButton(OrderRecord order) {
    switch (order.pdfStatus) {
      case SheetPdfStatus.ready:
        final mb = order.pdfBytes == null
            ? '?'
            : (order.pdfBytes!.length / (1024 * 1024)).toStringAsFixed(2);
        return Material(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _busy ? null : _download,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_rounded,
                          size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    'PDF · $mb MB',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case SheetPdfStatus.generating:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
              SizedBox(width: 6),
              Text('Preparing PDF…',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
            ],
          ),
        );
      case SheetPdfStatus.failed:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.error.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text('PDF failed',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.error)),
        );
      case SheetPdfStatus.archived:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.textSecondary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text('Archived',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textSecondary)),
        );
    }
  }
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersStore>();
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            color: AppColors.primary.withValues(alpha: 0.06),
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.verified_user_outlined,
                          color: AppColors.primary),
                      SizedBox(width: 10),
                      Text('No login needed',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Your orders are saved on this phone — just order and pay by UPI. '
                    'We identify you by the mobile number you enter at checkout.',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined,
                color: AppColors.textSecondary),
            title: Text(
                '${orders.count} order${orders.count == 1 ? '' : 's'} on this phone'),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
            onTap: () => context.go('/home?tab=orders'),
          ),
        ],
      ),
    );
  }
}

enum _ProductVariant { singlePolaroid, scatteredPolaroids, openBook }

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.title,
    required this.ctaLabel,
    required this.bgColor,
    required this.accentColor,
    required this.imageIds,
    required this.variant,
    required this.onTap,
  });

  final String title;
  final String ctaLabel;
  final Color bgColor;
  final Color accentColor;
  final List<int> imageIds;
  final _ProductVariant variant;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 180,
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 16),
          child: Row(
            children: [
              // Left: title + CTA pill
              Expanded(
                flex: 4,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FittedBox keeps the title on one line — auto-shrinks
                      // longer labels like "SnapBook" to fit the column width
                      // instead of wrapping.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: accentColor,
                          height: 1.0,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          ctaLabel,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: accentColor,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_forward_rounded,
                            size: 16, color: accentColor),
                      ],
                    ),
                  ],
                ),
              ),
              // Right: visual representation of the product
              Expanded(
                flex: 5,
                child: _ProductVisual(
                  variant: variant,
                  imageIds: imageIds,
                  accentColor: accentColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductVisual extends StatelessWidget {
  const _ProductVisual({
    required this.variant,
    required this.imageIds,
    required this.accentColor,
  });
  final _ProductVariant variant;
  final List<int> imageIds;
  final Color accentColor;

  Widget _img(int id, int w, int h) => Image.asset(
        SampleImages.assetPath(id),
        fit: BoxFit.cover,
        cacheWidth: w * 2,
        filterQuality: FilterQuality.medium,
      );

  @override
  Widget build(BuildContext context) {
    switch (variant) {
      case _ProductVariant.singlePolaroid:
        final id = imageIds.first;
        // Polaroid 4×4 ratio: square image + 1" white strip = 4×5 total = 4/5
        return Center(
          child: SizedBox(
            width: 110,
            child: PolaroidFrame(
              imageAspect: 1,
              displayAspect: 4 / 5,
              rotationDeg: -4,
              child: _img(id, 300, 300),
            ),
          ),
        );
      case _ProductVariant.scatteredPolaroids:
        final ids = imageIds.length >= 3
            ? imageIds
            : [...imageIds, ...SampleImages.family];
        // Plain photo prints: square 1:1 (no white polaroid strip).
        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 4,
              left: 4,
              width: 80,
              child: PolaroidFrame(
                imageAspect: 1,
                rotationDeg: -10,
                borderWidth: 6,
                child: _img(ids[0], 200, 200),
              ),
            ),
            Positioned(
              top: 8,
              right: 0,
              width: 78,
              child: PolaroidFrame(
                imageAspect: 1,
                rotationDeg: 8,
                borderWidth: 6,
                child: _img(ids[1], 200, 200),
              ),
            ),
            Positioned(
              bottom: 6,
              left: 18,
              width: 90,
              child: PolaroidFrame(
                imageAspect: 1,
                rotationDeg: -3,
                borderWidth: 6,
                child: _img(ids[2], 200, 200),
              ),
            ),
          ],
        );
      case _ProductVariant.openBook:
        final left = imageIds.first;
        final right = imageIds.length > 1 ? imageIds[1] : imageIds.first;
        return Center(
          child: Transform.rotate(
            angle: -0.06,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 80,
                    color: Colors.white,
                    padding: const EdgeInsets.all(4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: _img(left, 200, 280),
                    ),
                  ),
                  Container(
                    width: 60,
                    height: 80,
                    color: Colors.white,
                    padding: const EdgeInsets.all(4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: _img(right, 200, 280),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }
}
