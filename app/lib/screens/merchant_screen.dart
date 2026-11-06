import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/order_record.dart';
import '../models/orders_store.dart';
import '../models/print_packages.dart';
import '../services/pdf_download.dart';
import '../services/sheet_pdf.dart';
import '../services/share_files.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

/// Merchant dashboard — tabbed interface for the printer.
/// • Orders — paginated list, filter by status, sort, tap to drill in
/// • Print Queue — orders grouped by product+size; bulk-download combined PDF
/// • Stats — revenue + counts at a glance
class MerchantScreen extends StatefulWidget {
  const MerchantScreen({super.key});

  @override
  State<MerchantScreen> createState() => _MerchantScreenState();
}

class _MerchantScreenState extends State<MerchantScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('MERCHANT DASHBOARD'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        actions: [
          IconButton(
            tooltip: 'Cloud sync (OneDrive)',
            icon: const Icon(Icons.cloud_sync_rounded),
            onPressed: () => context.push('/merchant/cloud'),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          tabs: const [
            Tab(icon: Icon(Icons.receipt_long_rounded), text: 'Orders'),
            Tab(icon: Icon(Icons.print_rounded), text: 'Print Queue'),
            Tab(icon: Icon(Icons.bar_chart_rounded), text: 'Stats'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _OrdersTab(),
          _PrintQueueTab(),
          _StatsTab(),
        ],
      ),
    );
  }
}

// ─── Orders tab ────────────────────────────────────────────────────────
class _OrdersTab extends StatefulWidget {
  const _OrdersTab();
  @override
  State<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<_OrdersTab> {
  OrderStatus? _filter;

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersStore>().all;
    final filtered =
        _filter == null ? orders : orders.where((o) => o.status == _filter).toList();
    return Column(
      children: [
        _StatusFilterBar(
          selected: _filter,
          onSelect: (s) => setState(() => _filter = s),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const _EmptyOrders()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _OrderTile(order: filtered[i]),
                ),
        ),
      ],
    );
  }
}

class _StatusFilterBar extends StatelessWidget {
  const _StatusFilterBar({required this.selected, required this.onSelect});
  final OrderStatus? selected;
  final void Function(OrderStatus?) onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          _Chip(
            label: 'All',
            selected: selected == null,
            color: AppColors.primary,
            onTap: () => onSelect(null),
          ),
          for (final s in OrderStatus.values)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _Chip(
                label: s.label,
                selected: selected == s,
                color: Color(s.color),
                onTap: () => onSelect(s),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? color : color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : color,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyOrders extends StatelessWidget {
  const _EmptyOrders();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.inbox_outlined,
                size: 56, color: AppColors.textSecondary),
            SizedBox(height: 8),
            Text('No orders match this filter.',
                style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});
  final OrderRecord order;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM, h:mm a');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/merchant/order/${order.id}'),
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
                  _StatusChip(status: order.status),
                ],
              ),
              const SizedBox(height: 6),
              Text(order.customerName,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
              Text(order.customerPhone,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${order.productTitle} · ${order.sizeDimensions} · ${order.snapCount} snaps',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Text(
                    order.totalLabel,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.print_outlined,
                      size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    '${order.sheetsLabel} · placed ${fmt.format(order.placedAt)}',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                  const Spacer(),
                  _SheetStatusChip(status: order.pdfStatus),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final OrderStatus status;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Color(status.color).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status.label.toUpperCase(),
        style: TextStyle(
          color: Color(status.color),
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _SheetStatusChip extends StatelessWidget {
  const _SheetStatusChip({required this.status});
  final SheetPdfStatus status;
  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    String label;
    switch (status) {
      case SheetPdfStatus.ready:
        bg = AppColors.success.withValues(alpha: 0.15);
        fg = AppColors.success;
        label = 'PDF READY';
        break;
      case SheetPdfStatus.generating:
        bg = AppColors.primary.withValues(alpha: 0.12);
        fg = AppColors.primary;
        label = 'BUILDING…';
        break;
      case SheetPdfStatus.failed:
        bg = AppColors.error.withValues(alpha: 0.12);
        fg = AppColors.error;
        label = 'FAILED';
        break;
      case SheetPdfStatus.archived:
        bg = AppColors.textSecondary.withValues(alpha: 0.12);
        fg = AppColors.textSecondary;
        label = 'ARCHIVED';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: fg,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ─── Print Queue tab — bulk download by category+size ─────────────────
class _PrintQueueTab extends StatelessWidget {
  const _PrintQueueTab();
  @override
  Widget build(BuildContext context) {
    final groups = context.watch<OrdersStore>().groupedByCategorySize();
    if (groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.print_disabled_rounded,
                  size: 56, color: AppColors.textSecondary),
              SizedBox(height: 8),
              Text(
                'Nothing pending. New orders will queue up here automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    final keys = groups.keys.toList();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: keys.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final key = keys[i];
        return _GroupCard(groupKey: key, orders: groups[key]!);
      },
    );
  }
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({required this.groupKey, required this.orders});
  final String groupKey;
  final List<OrderRecord> orders;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _busy = false;
  double _progress = 0;
  String _stage = '';

  PrintSize? _resolveSize() {
    final first = widget.orders.first;
    for (final p in allPacks) {
      if (p.size.category.title == first.productTitle &&
          p.size.label == first.sizeLabel) {
        return p.size;
      }
    }
    return null;
  }

  Future<void> _bulkDownload() async {
    final size = _resolveSize();
    if (size == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not resolve print size.')),
      );
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _stage = 'Starting…';
    });
    try {
      final bytes = await SheetPdfService.buildBytesForGroup(
        orders: widget.orders,
        size: size,
        onProgress: (pct, stage) {
          if (!mounted) return;
          setState(() {
            _progress = pct;
            _stage = stage;
          });
        },
      );
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final filename =
          'print_queue_${widget.orders.first.groupSlug}_$today.pdf';
      await downloadPdf(bytes, filename);
      if (!mounted) return;
      final mb =
          (bytes.length / (1024 * 1024)).toStringAsFixed(2);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded $mb MB')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bulk download failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = widget.orders;
    final totalSnaps =
        orders.fold<int>(0, (s, o) => s + o.snapCount);
    final size = _resolveSize();
    final perSheet = size?.perSheet ?? 1;
    final totalSheets = (totalSnaps / perSheet).ceil();
    final ordersIndividualSheets =
        orders.fold<int>(0, (s, o) => s + o.sheetsNeeded);
    final saved = ordersIndividualSheets - totalSheets;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.layers_rounded,
                      color: AppColors.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.groupKey,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '${orders.length} customer${orders.length == 1 ? '' : 's'} · $totalSnaps snaps',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.lavender,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.print_outlined,
                          color: AppColors.primary, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'Combined: $totalSheets sheet${totalSheets == 1 ? '' : 's'} (12×18)',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  if (saved > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Saves $saved sheet${saved == 1 ? '' : 's'} vs printing each customer separately.',
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.success,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Customer list
            ...orders.take(4).map((o) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      const Icon(Icons.person_outline,
                          size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          o.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Text(
                        '${o.snapCount} snaps',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                )),
            if (orders.length > 4)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '+ ${orders.length - 4} more customer${orders.length - 4 == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
            const SizedBox(height: 12),
            if (_busy) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                  minHeight: 6,
                  backgroundColor:
                      AppColors.primary.withValues(alpha: 0.12),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${(_progress * 100).round()}% · $_stage',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
            ],
            PrimaryButton(
              label: 'Download combined PDF',
              icon: Icons.download_rounded,
              loading: _busy,
              onPressed: _bulkDownload,
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '$totalSheets page${totalSheets == 1 ? '' : 's'} in one file · each page ≤ 6 MB',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Stats tab ─────────────────────────────────────────────────────────
class _StatsTab extends StatelessWidget {
  const _StatsTab();
  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersStore>();
    final byStatus = <OrderStatus, int>{};
    for (final s in OrderStatus.values) {
      byStatus[s] = orders.all.where((o) => o.status == s).length;
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Total orders',
                value: '${orders.count}',
                icon: Icons.receipt_long_rounded,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: 'Revenue',
                value:
                    '₹${(orders.totalRevenuePaise / 100).toStringAsFixed(0)}',
                icon: Icons.currency_rupee_rounded,
                color: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _StatCard(
          label: 'Sheets pending',
          value: '${orders.pendingSheets} master sheets',
          icon: Icons.print_rounded,
          color: AppColors.accent,
          fullWidth: true,
        ),
        const SizedBox(height: 24),
        const _SectionTitle('By status'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (final s in OrderStatus.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Color(s.color),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(s.label,
                                style: const TextStyle(fontSize: 13))),
                        Text(
                          '${byStatus[s]}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.fullWidth = false,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Order detail (unchanged from before) ─────────────────────────────
class MerchantOrderDetailScreen extends StatelessWidget {
  const MerchantOrderDetailScreen({super.key, required this.orderId});
  final String orderId;

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersStore>();
    final order = orders.findById(orderId);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(order?.displayId ?? 'ORDER'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/merchant'),
        ),
      ),
      body: order == null
          ? const Center(child: Text('Order not found.'))
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _StatusPipeline(order: order, store: orders),
                  const SizedBox(height: 16),
                  const _SectionTitle('Customer'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(order.customerName,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(order.customerPhone,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary)),
                          const SizedBox(height: 12),
                          Text(order.address,
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _SectionTitle('Order'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _kv('Product', order.productTitle),
                          _kv('Size', order.sizeDimensions),
                          _kv('Snaps', '${order.snapCount}'),
                          _kv('Sheets to print',
                              '${order.sheetsLabel}  (12×18 master)'),
                          const Divider(),
                          _kv('Total paid', order.totalLabel, bold: true),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _SectionTitle('Print sheets'),
                  ...List.generate(order.sheetsNeeded, (i) {
                    return _SheetPreview(
                      order: order,
                      sheetIndex: i + 1,
                    );
                  }),
                  const SizedBox(height: 16),
                  _DownloadPdfButton(order: order),
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      '12×18 master sheets · 300 GSM · each page ≤ 6 MB',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _kv(String k, String v, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: bold ? 14 : 13,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              )),
          Text(v,
              style: TextStyle(
                fontSize: bold ? 16 : 13,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(label,
          style:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
    );
  }
}

class _StatusPipeline extends StatelessWidget {
  const _StatusPipeline({required this.order, required this.store});
  final OrderRecord order;
  final OrdersStore store;

  @override
  Widget build(BuildContext context) {
    final stages = OrderStatus.values;
    final currentIdx = stages.indexOf(order.status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        child: Column(
          children: [
            Row(
              children: List.generate(stages.length, (i) {
                final reached = i <= currentIdx;
                final color =
                    reached ? Color(stages[i].color) : AppColors.border;
                return Expanded(
                  child: Row(
                    children: [
                      Column(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                            child: reached
                                ? const Icon(Icons.check,
                                    color: Colors.white, size: 14)
                                : null,
                          ),
                          const SizedBox(height: 4),
                          Text(stages[i].label,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: reached
                                    ? Color(stages[i].color)
                                    : AppColors.textSecondary,
                              )),
                        ],
                      ),
                      if (i != stages.length - 1)
                        Expanded(
                          child: Container(
                            height: 2,
                            margin: const EdgeInsets.only(bottom: 18),
                            color: i < currentIdx
                                ? Color(stages[i].color)
                                : AppColors.border,
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: stages
                  .where((s) => s.index > currentIdx)
                  .map((s) => OutlinedButton(
                        onPressed: () => store.updateStatus(order.id, s),
                        child: Text('Mark ${s.label}'),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetPreview extends StatelessWidget {
  const _SheetPreview({required this.order, required this.sheetIndex});
  final OrderRecord order;
  final int sheetIndex;

  String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();

  @override
  Widget build(BuildContext context) {
    final customer = _sanitize(order.customerName);
    final category = _sanitize(order.productTitle);
    final label =
        '${customer}_${category}  ·  $sheetIndex of ${order.sheetsNeeded}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 90,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Center(
                  child: Icon(Icons.grid_view_rounded,
                      color: AppColors.textSecondary, size: 22),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '12 × 18 inches · 300 GSM',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              _SheetStatusChip(status: order.pdfStatus),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadPdfButton extends StatefulWidget {
  const _DownloadPdfButton({required this.order});
  final OrderRecord order;
  @override
  State<_DownloadPdfButton> createState() => _DownloadPdfButtonState();
}

class _DownloadPdfButtonState extends State<_DownloadPdfButton> {
  bool _busy = false;
  bool _busyJpg = false;

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

  /// Rasterise the order's print sheets to 300 DPI JPGs and open the share
  /// sheet. Files are named to preview the final scheme, e.g.
  /// `PP-000123 (1 of 3).jpg` — the same names the OneDrive filing will use.
  Future<void> _downloadJpgs() async {
    final order =
        context.read<OrdersStore>().findById(widget.order.id) ?? widget.order;
    final bytes = order.pdfBytes;
    if (bytes == null) return;
    setState(() => _busyJpg = true);
    try {
      final jpgs = await SheetPdfService.rasterizeToJpgs(bytes);
      final n = jpgs.length;
      final id = order.displayId;
      final names = <String>[
        for (var i = 0; i < n; i++) '$id (${i + 1} of $n).jpg',
      ];
      await shareNamedFiles(names, jpgs, subject: 'Order $id — print sheets');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('JPG export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busyJpg = false);
    }
  }

  Future<void> _retry() async {
    final size = SheetPdfService.resolveSize(widget.order);
    if (size == null) return;
    final store = context.read<OrdersStore>();
    store.markPdfGenerating(widget.order.id);
    setState(() => _busy = true);
    try {
      final bytes = await SheetPdfService.buildBytes(
          order: widget.order, size: size);
      store.setPdf(widget.order.id, bytes);
    } catch (_) {
      store.markPdfFailed(widget.order.id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = context.watch<OrdersStore>().findById(widget.order.id) ??
        widget.order;
    switch (order.pdfStatus) {
      case SheetPdfStatus.ready:
        final mb = order.pdfBytes == null
            ? '?'
            : (order.pdfBytes!.length / (1024 * 1024)).toStringAsFixed(2);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PrimaryButton(
              label: 'Download all sheets · $mb MB',
              icon: Icons.download_rounded,
              loading: _busy,
              onPressed: _download,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busyJpg ? null : _downloadJpgs,
              icon: _busyJpg
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.image_outlined),
              label: Text(
                _busyJpg ? 'Rendering JPGs…' : 'Save sheets as JPG (300 DPI)',
              ),
            ),
          ],
        );
      case SheetPdfStatus.generating:
        return const PrimaryButton(
          label: 'Preparing print sheet…',
          icon: Icons.hourglass_empty_rounded,
          loading: true,
          onPressed: null,
        );
      case SheetPdfStatus.failed:
        return PrimaryButton(
          label: 'Retry generating sheet',
          icon: Icons.refresh_rounded,
          loading: _busy,
          onPressed: _retry,
        );
      case SheetPdfStatus.archived:
        return const PrimaryButton(
          label: 'Photos archived — re-request from customer',
          icon: Icons.archive_outlined,
          onPressed: null,
        );
    }
  }
}
