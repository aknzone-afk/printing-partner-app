import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../models/print_packages.dart';
import '../services/photo_export.dart';
import '../theme.dart';
import '../widgets/polaroid_frame.dart';
import '../widgets/primary_button.dart';

/// "How your prints will look" — the result page the customer sees right after
/// Auto-crop / cropping, BEFORE the cart. Every photo is run through the REAL
/// print export ([renderCroppedJpegs]) at a small preview size, so what shows
/// here is pixel-for-pixel what the shop will print (the exact crop, rotation,
/// white-pad and — for Polaroids — the white frame + caption strip). Tapping a
/// print re-opens it in the crop screen; Continue goes to the cart.
///
/// The render is small ([_previewLongSide] px) and runs on the native codec, so
/// it is quick; a progress bar shows while it works. A render that fails on one
/// photo never blanks the page — that card shows a "couldn't preview" tile and
/// the rest still render (the real order still validates every photo at upload).
class PreviewScreen extends StatefulWidget {
  const PreviewScreen({super.key});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  // Sized for the on-screen card (a ~180-dp tile at 3x ≈ 540 px), not for
  // print — small so a 54-photo set renders quickly instead of feeling hung.
  static const int _previewLongSide = 560;

  /// One preview JPEG per cart photo, in cart order (null = that photo could
  /// not be rendered). Empty until the first render completes.
  List<Uint8List?>? _previews;
  int _done = 0;
  int _total = 0;
  String? _error;
  // Guards against a stale render (cart changed while rendering) overwriting a
  // fresh one, and against setState after dispose.
  String _sig = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _render());
  }

  String _signatureOf(Cart cart) {
    final b = StringBuffer(cart.selectedPack?.size.label ?? '-');
    for (final it in cart.items) {
      b
        ..write(it.id)
        ..write(cart.cropFor(it.id)?.hashCode ?? 0);
    }
    return b.toString();
  }

  Future<void> _render() async {
    final cart = context.read<Cart>();
    if (cart.selectedPack == null || cart.isEmpty) return;
    final sig = _signatureOf(cart);
    setState(() {
      _sig = sig;
      _error = null;
      _previews = null;
      _done = 0;
      _total = cart.items.length;
    });
    try {
      final jpgs = await renderCroppedJpegs(
        cart,
        maxLongSide: _previewLongSide,
        jpegQuality: 86,
        onProgress: (done, total) {
          if (mounted && _sig == sig) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      if (!mounted || _sig != sig) return;
      setState(() => _previews = List<Uint8List?>.from(jpgs));
    } catch (e) {
      // Every photo is validated as decodable at pick time, so a render failure
      // here is rare; show a graceful "continue to cart" rather than a blank.
      if (!mounted || _sig != sig) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    final pack = cart.selectedPack;
    if (pack == null || cart.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('PREVIEW')),
        body: const Center(child: Text('No photos to preview.')),
      );
    }
    // The cart changed under us (re-crop, add/remove) — re-render.
    if (_previews != null && _sig != _signatureOf(cart)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _render();
      });
    }

    final previews = _previews;
    return Scaffold(
      appBar: AppBar(
        title: const Text('YOUR PRINTS'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/photos'),
        ),
        actions: [
          TextButton(
            onPressed: () => context.go('/cart'),
            child: const Text('Cart'),
          ),
        ],
      ),
      body: SafeArea(
        child: previews == null
            ? _RenderingView(done: _done, total: _total, error: _error)
            : _ResultGrid(cart: cart, pack: pack, previews: previews),
      ),
      bottomNavigationBar: previews == null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: PrimaryButton(
                label: 'Looks good · Continue',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => context.go('/cart'),
              ),
            ),
    );
  }
}

class _RenderingView extends StatelessWidget {
  const _RenderingView({required this.done, required this.total, this.error});
  final int done;
  final int total;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_not_supported_outlined,
                  size: 40, color: AppColors.primary),
              const SizedBox(height: 12),
              Text('Could not build the preview.\n$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => GoRouter.of(context).go('/cart'),
                child: const Text('Continue to cart'),
              ),
            ],
          ),
        ),
      );
    }
    final frac = total == 0 ? null : done / total;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome_rounded,
                size: 40, color: AppColors.primary),
            const SizedBox(height: 16),
            const Text('Getting your prints ready…',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('$done of $total',
                style: const TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 16),
            SizedBox(
              width: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: frac,
                  minHeight: 8,
                  backgroundColor: AppColors.lavender,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultGrid extends StatelessWidget {
  const _ResultGrid({
    required this.cart,
    required this.pack,
    required this.previews,
  });
  final Cart cart;
  final PrintPack pack;
  final List<Uint8List?> previews;

  @override
  Widget build(BuildContext context) {
    final items = cart.items;
    final count = items.length;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            width: double.infinity,
            color: AppColors.lavender,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Here’s how your $count ${count == 1 ? 'print' : 'prints'} '
                    'will come out 🖼️',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary)),
                const SizedBox(height: 3),
                Text(
                    '${pack.size.category.title} · ${pack.size.label} '
                    '(${pack.size.dimensions}).  Tap a print to re-crop it.',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.primary)),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 18,
              crossAxisSpacing: 18,
              childAspectRatio: 0.72,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _PrintCard(
                index: i,
                total: count,
                pack: pack,
                jpg: previews.length > i ? previews[i] : null,
                onTap: () => context.push('/crop?i=$i'),
              ),
              childCount: count,
            ),
          ),
        ),
      ],
    );
  }
}

/// One photo shown the way it will physically print: a bordered glossy print
/// for Photos/Snapbook, a white-framed square for Polaroids. A slight alternat-
/// ing tilt + soft shadow makes the grid read like real prints laid on a table.
class _PrintCard extends StatelessWidget {
  const _PrintCard({
    required this.index,
    required this.total,
    required this.pack,
    required this.jpg,
    required this.onTap,
  });
  final int index;
  final int total;
  final PrintPack pack;
  final Uint8List? jpg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tilt = (index.isEven ? -1.0 : 1.0) * 0.012; // ±~0.7°
    return GestureDetector(
      onTap: onTap,
      child: Transform.rotate(
        angle: tilt,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Stack(
                children: [
                  _print(),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${index + 1}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800)),
                    ),
                  ),
                  // Visible "Edit" affordance so it's obvious every photo can be
                  // re-cropped / auto-cropped / zoomed. Tapping anywhere on the
                  // tile (or this pill) opens the crop screen for this photo.
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.crop_rotate_rounded,
                              size: 13, color: Colors.white),
                          SizedBox(width: 4),
                          Text('Edit',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _print() {
    final isPolaroid = pack.size.hasPolaroidStrip;
    final shadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.18),
        blurRadius: 10,
        offset: const Offset(0, 5),
      ),
    ];

    if (isPolaroid) {
      // The SAME white Polaroid card the packages screen shows (shared
      // PolaroidFrame.forSize), so the result here matches what the customer
      // picked from. The outer Transform.rotate applies the tilt, so the frame
      // itself stays upright (rotationDeg: 0).
      return PolaroidFrame.forSize(
        size: pack.size,
        rotationDeg: 0,
        elevation: 10,
        child: _image(BoxFit.cover),
      );
    }

    // Photos / Snapbook: a glossy print with a thin white border, edge-to-edge
    // image at the print's own aspect.
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: Colors.white, boxShadow: shadow),
      child: AspectRatio(
        aspectRatio: pack.size.imageAspectWxH,
        child: _image(BoxFit.cover),
      ),
    );
  }

  Widget _image(BoxFit fit) {
    final bytes = jpg;
    if (bytes == null) {
      return Container(
        color: const Color(0xFFF1EEF8),
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                color: AppColors.primary, size: 22),
            SizedBox(height: 4),
            Text('tap to re-crop',
                style: TextStyle(fontSize: 10, color: AppColors.primary)),
          ],
        ),
      );
    }
    return Image.memory(bytes, fit: fit, gaplessPlayback: true);
  }
}
