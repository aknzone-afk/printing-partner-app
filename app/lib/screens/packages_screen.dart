import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../models/print_packages.dart';
import '../theme.dart';
import '../utils/sample_images.dart';
import '../widgets/polaroid_frame.dart';

/// Handles a pack tap without silently throwing away photos the customer has
/// already picked:
///  • same pack tapped again → keep everything, go straight to the cart;
///  • same size, different count → keep the photos + crops, just re-cap them
///    to the new count (Cart.changePack);
///  • a truly different size → start a fresh selection (Cart.selectPack).
void _onPackTapped(BuildContext context, PrintPack pack) {
  final cart = context.read<Cart>();
  final current = cart.selectedPack;
  if (!cart.isEmpty && current != null) {
    final sameSize = current.size.category == pack.size.category &&
        current.size.label == pack.size.label;
    final samePack = sameSize &&
        current.snapCount == pack.snapCount &&
        current.priceInPaise == pack.priceInPaise;
    if (samePack) {
      context.push('/cart');
      return;
    }
    if (sameSize) {
      cart.changePack(pack);
      context.push('/photos');
      return;
    }
  }
  cart.selectPack(pack);
  context.push('/photos');
}

class PackagesScreen extends StatelessWidget {
  const PackagesScreen({super.key, required this.category});

  final PrintCategory category;

  @override
  Widget build(BuildContext context) {
    final sizes = sizesFor(category);
    return Scaffold(
      appBar: AppBar(
        title: Text(category.title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            for (final size in sizes) ...[
              _SizeBlock(size: size),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 12),
            const _QualityFooter(),
          ],
        ),
      ),
    );
  }
}

class _SizeBlock extends StatelessWidget {
  const _SizeBlock({required this.size});
  final PrintSize size;

  @override
  Widget build(BuildContext context) {
    final packs = packsFor(size);
    final cols = packs.length >= 4 ? 4 : 3;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Container(
                  width: 26 * size.aspectWxH,
                  height: 26,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      size.label,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      size.dimensions,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (packs.length == 1)
            _PackBar(pack: packs.first)
          else
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: cols,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.62,
              children: [for (final p in packs) _PackPill(pack: p)],
            ),
        ],
      ),
    );
  }
}

class _PackPill extends StatelessWidget {
  const _PackPill({required this.pack});
  final PrintPack pack;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _onPackTapped(context, pack),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Sample photo at the print's actual aspect ratio.
              Expanded(
                child: Center(
                  child: _SamplePrint(pack: pack),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                pack.priceLabel,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                pack.countLabel,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SamplePrint extends StatelessWidget {
  const _SamplePrint({required this.pack});
  final PrintPack pack;

  // Distinct curated photo per pack so customers see what different print
  // sizes look like with real-photo content. Index derived from a stable hash
  // of size + price so the assignment is deterministic.
  int get _imageId {
    final key =
        '${pack.size.category.slug}|${pack.size.label}|${pack.priceInPaise}';
    final index = key.hashCode.abs() % SampleImages.all.length;
    return SampleImages.all[index];
  }

  @override
  Widget build(BuildContext context) {
    return PolaroidFrame.forSize(
      size: pack.size,
      rotationDeg: -3,
      elevation: 4,
      child: Image.asset(
        SampleImages.assetPath(_imageId),
        fit: BoxFit.cover,
        cacheWidth: 600,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => Container(
          color: AppColors.lavender,
          child: const Center(
            child: Icon(Icons.image_outlined,
                size: 18, color: AppColors.primary),
          ),
        ),
      ),
    );
  }
}

class _PackBar extends StatelessWidget {
  const _PackBar({required this.pack});
  final PrintPack pack;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _onPackTapped(context, pack),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 72,
                child: Center(child: _SamplePrint(pack: pack)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pack.priceLabel,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                    Text(
                      pack.countLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      pack.perUnitLabel,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _QualityFooter extends StatelessWidget {
  const _QualityFooter();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.star_rounded, color: AppColors.success, size: 18),
              SizedBox(width: 6),
              Text(
                "We don't compromise our standards.",
                style:
                    TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 8),
          _Bullet(text: '300 GSM premium photo paper (market is 180 GSM)'),
          _Bullet(text: 'Thermal fusion lamination'),
          _Bullet(text: 'High-quality printing guaranteed'),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.check_circle_rounded,
                color: AppColors.success, size: 14),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textPrimary,
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
