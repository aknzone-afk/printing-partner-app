import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../models/order_record.dart';
import '../services/sheet_pdf.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

/// Build the print-ready PDF from the cart, show progress %, then navigate
/// to /address. The PDF bytes are stored on the cart and re-used when the
/// order is placed at checkout — no rebuilding.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  bool _started = false;
  bool _failed = false;
  String? _errorMsg;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runIfNeeded());
  }

  Future<void> _runIfNeeded() async {
    final cart = context.read<Cart>();
    if (cart.pdfReady) {
      // PDF was already built (e.g. user backed out and re-entered /upload).
      // Skip the rebuild but still forward them to the next step — otherwise
      // we'd sit at "100% Done" forever.
      if (!mounted) return;
      context.go('/address');
      return;
    }
    if (_started) return;
    _started = true;
    await _build();
  }

  Future<void> _build() async {
    final cart = context.read<Cart>();
    final pack = cart.selectedPack;
    if (pack == null) {
      setState(() {
        _failed = true;
        _errorMsg = 'No pack selected.';
      });
      return;
    }

    _startedAt = DateTime.now();
    cart.setPdfProgress(0, 'Starting…');

    // Temp order record so we can reuse the existing build pipeline.
    final tempOrder = OrderRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      placedAt: DateTime.now(),
      customerName: cart.customerName.isEmpty ? 'Customer' : cart.customerName,
      customerPhone:
          cart.customerPhone.isEmpty ? '' : '+91 ${cart.customerPhone}',
      address: cart.fullAddress,
      productTitle: pack.size.category.title,
      sizeLabel: pack.size.label,
      sizeDimensions: pack.size.dimensions,
      snapCount: pack.snapCount,
      sheetsNeeded: pack.sheetsNeeded,
      totalPaise: cart.totalPaise,
      photoPaths: cart.items.map((i) => i.localPath).toList(),
      status: OrderStatus.received,
    );

    try {
      final bytes = await SheetPdfService.buildBytes(
        order: tempOrder,
        size: pack.size,
        onProgress: (pct, stage) {
          if (mounted) cart.setPdfProgress(pct, stage);
        },
      );
      if (!mounted) return;
      cart.setPdfBytes(bytes);
      // Brief pause so user sees 100% before navigating.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      context.go('/address');
    } catch (e) {
      debugPrint('[Upload] failed: $e');
      if (!mounted) return;
      setState(() {
        _failed = true;
        _errorMsg = e.toString();
      });
    }
  }

  Future<void> _retry() async {
    setState(() {
      _failed = false;
      _errorMsg = null;
      _started = false;
    });
    await _runIfNeeded();
  }

  String? _etaLabel(double progress) {
    if (_startedAt == null) return null;
    if (progress < 0.05 || progress >= 1.0) return null;
    final elapsedSec =
        DateTime.now().difference(_startedAt!).inMilliseconds / 1000.0;
    if (elapsedSec < 0.5) return null;
    final totalEst = elapsedSec / progress;
    final remaining = (totalEst - elapsedSec).clamp(1, 600).round();
    if (remaining < 60) return '≈ $remaining sec left';
    final mins = (remaining / 60).round();
    return '≈ $mins min left';
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    final progress = cart.pdfProgress;
    final stage = cart.pdfStage;
    final pct = (progress * 100).clamp(0, 100).round();
    final eta = _failed ? null : _etaLabel(progress);

    return Scaffold(
      appBar: AppBar(
        title: const Text('PREPARING ORDER'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.go('/cart'),
        ),
      ),
      body: SafeArea(
        // Center the whole progress card and keep it fitting any screen —
        // scrolls only if a small screen can't fit it.
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
              Container(
                width: 120,
                height: 120,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: _failed
                    ? const Icon(Icons.error_outline_rounded,
                        size: 56, color: AppColors.error)
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 90,
                            height: 90,
                            child: CircularProgressIndicator(
                              value: progress == 0 ? null : progress,
                              strokeWidth: 6,
                              backgroundColor:
                                  AppColors.primary.withValues(alpha: 0.15),
                              valueColor: const AlwaysStoppedAnimation(
                                  AppColors.primary),
                            ),
                          ),
                          Text(
                            '$pct%',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 24),
              Text(
                _failed
                    ? 'Upload failed'
                    : 'Preparing your order',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                _failed
                    ? (_errorMsg ?? 'Something went wrong.')
                    : (stage.isEmpty ? 'Starting…' : stage),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary, height: 1.4),
              ),
              if (eta != null) ...[
                const SizedBox(height: 6),
                Text(
                  eta,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (!_failed) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.lavender,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Please don\'t close this page.',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary),
                  ),
                ),
              ],
              if (_failed) ...[
                const SizedBox(height: 24),
                PrimaryButton(
                  label: 'Retry upload',
                  icon: Icons.refresh_rounded,
                  onPressed: _retry,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => context.go('/cart'),
                  child: const Text('Back to cart'),
                ),
              ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
