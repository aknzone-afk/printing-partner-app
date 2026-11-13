import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../models/order_record.dart';
import '../models/orders_store.dart';
import '../services/pending_upload.dart';
import '../services/sheet_pdf.dart';
import '../services/merchant_gate.dart';
import '../services/shop_contact.dart';
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

  /// A paid order whose photos never reached us (screen left / app killed
  /// mid-upload). Surfaced as a top card so it is not invisible after a
  /// relaunch; tapping it resumes the upload in checkout — NOT a new payment.
  PendingUpload? _pending;

  @override
  void initState() {
    super.initState();
    _loadPending();
    // Pull the live status if we land straight on the Orders tab.
    if (_tabIndex == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<OrdersStore>().refreshFromCloud();
      });
    }
  }

  Future<void> _loadPending() async {
    final p = await PendingUpload.load();
    if (mounted) setState(() => _pending = p);
  }

  /// Opens checkout, which detects the pending record and resumes the upload.
  /// On return we re-check: a finished (or expired) record clears the card.
  Future<void> _resumePendingUpload() async {
    await context.push('/checkout');
    if (!mounted) return;
    _loadPending();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        // Long-press the title to open the merchant dashboard (no URL bar on a
        // phone) — but only behind a PIN, so a customer can't reach the shop's
        // order list by accident.
        title: GestureDetector(
          onLongPress: () async {
            if (await MerchantGate.verify(context)) {
              if (context.mounted) context.push('/merchant');
            }
          },
          child: _tabIndex == 0
              ? const PPLogoLockup(height: 30)
              : Text(_titles[_tabIndex]),
        ),
        elevation: 0,
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _HomeTab(pending: _pending, onResume: _resumePendingUpload),
          const _OrdersTab(),
          _ProfileTab(onViewOrders: () => setState(() => _tabIndex = 1)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) {
          setState(() => _tabIndex = i);
          // Reading the Orders tab pulls each order's live status from the
          // cloud so it is not the frozen value saved at checkout.
          if (i == 1) context.read<OrdersStore>().refreshFromCloud();
        },
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
  const _HomeTab({this.pending, required this.onResume});

  /// A paid-but-not-uploaded order, or null. When set, a resume card is shown
  /// at the top of the home tab.
  final PendingUpload? pending;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    final pending = this.pending;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pending != null) ...[
              _PendingUploadCard(
                orderNumber: pending.orderNumber,
                onTap: onResume,
              ),
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 8),
            _ProductCard(
              title: 'Snaps',
              ctaLabel: 'Print Now',
              bgColor: AppColors.lavender,
              accentColor: AppColors.primaryDark,
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
              accentColor: AppColors.primaryDark,
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

/// A paid order whose photos have not reached the shop yet (upload interrupted
/// by leaving the screen or an app kill). Shown at the top of the home tab so
/// the order is never invisible after a relaunch. Tapping it resumes the upload
/// — it never re-shows the pay QR.
class _PendingUploadCard extends StatelessWidget {
  const _PendingUploadCard({required this.orderNumber, required this.onTap});

  final String orderNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFFF4E5),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: 'Order number $orderNumber is paid but your photos have not '
              'reached us yet. Tap to finish.',
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.cloud_upload_rounded, color: Color(0xFFB26A00)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Order #$orderNumber is paid',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF8A5300),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Your photos have not reached us yet — tap to finish.',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF8A5300)),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFFB26A00)),
              ],
            ),
          ),
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
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.receipt_long_outlined,
                    size: 80, color: AppColors.textSecondary),
                const SizedBox(height: 16),
                const Text('No orders yet',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                  'Orders are kept on the phone they were placed from. If you '
                  'reinstalled the app or switched to a new phone, your older '
                  'orders won\'t show here — message the shop with the mobile '
                  'number you used at checkout and we\'ll help you track them.',
                  style: TextStyle(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                if (ShopContact.note.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    ShopContact.note,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                ],
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
                // Expanded (not Spacer) so a long id + the status chip never
                // overflow at 1.3x text scale; dark purple for small text.
                Expanded(
                  child: Text(
                    order.displayId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryDark,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
                Expanded(
                  child: Text(
                    order.totalLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(child: _customerDownloadButton(order)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () =>
                    context.push('/order-chat', extra: order.id),
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: const Text('Chat about this order'),
              ),
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
        // 48-dp minimum tap target; labelled for screen readers; the text
        // shrinks with an ellipsis instead of overflowing at 1.3x scale.
        return Semantics(
          button: true,
          enabled: !_busy,
          label: _busy ? 'Downloading PDF' : 'Download PDF, $mb megabytes',
          child: Tooltip(
            message: 'Download print-sheet PDF',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Material(
                color: AppColors.primaryDark,
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
                        Flexible(
                          child: Text(
                            'PDF · $mb MB',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.primaryDark),
              ),
              SizedBox(width: 6),
              Flexible(
                child: Text('Preparing PDF…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryDark)),
              ),
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
        // Sheet PDFs are gone from the customer flow (the backend files the
        // individual cropped photos), so a fresh order must not show a grey
        // "Archived" badge.
        return const SizedBox.shrink();
    }
  }
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab({required this.onViewOrders});

  /// Switches the host to the Orders tab (the ListTile is inside an
  /// IndexedStack, so pushing `/home?tab=orders` would land on the same route
  /// and do nothing — the parent flips the tab index instead).
  final VoidCallback onViewOrders;

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
                          color: AppColors.primaryDark),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text('No login needed',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
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
            onTap: onViewOrders,
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
        // Semantics on the InkWell: one named button per card for TalkBack /
        // VoiceOver; the visual on the right is decorative and excluded.
        child: Semantics(
          button: true,
          label: '$title. $ctaLabel',
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
                          Flexible(
                            child: Text(
                              ctaLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: accentColor,
                              ),
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
                  child: ExcludeSemantics(
                    child: _ProductVisual(
                      variant: variant,
                      imageIds: imageIds,
                      accentColor: accentColor,
                    ),
                  ),
                ),
              ],
            ),
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
