import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../models/print_packages.dart';
import '../services/photo_export.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';
import '../widgets/print_result_view.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('YOUR CART'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: cart.isEmpty && cart.selectedPack == null
          ? const _EmptyCart()
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      children: [
                        if (cart.selectedPack != null)
                          _PackBanner(cart: cart),
                        const SizedBox(height: 12),
                        _PhotoGrid(cart: cart),
                      ],
                    ),
                  ),
                  _CartSummary(cart: cart),
                ],
              ),
            ),
    );
  }
}

class _PackBanner extends StatelessWidget {
  const _PackBanner({required this.cart});
  final Cart cart;
  @override
  Widget build(BuildContext context) {
    final pack = cart.selectedPack!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pack.size.category.title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${pack.size.label} · ${pack.size.dimensions}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${cart.itemCount} / ${pack.snapCount} ${pack.size.category.unit} ready',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Shrinks (never clips) when large text scaling squeezes the row.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                pack.priceLabel,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The cart's "Your selection" grid. Each tile is the photo's ACTUAL print
/// result (same `renderCroppedJpegs` + `PrintResultView` the preview page uses,
/// so it looks identical) with a remove (✕) button and an Edit button that
/// opens the crop screen (crop / Auto crop / zoom / rotate) for that photo.
class _PhotoGrid extends StatefulWidget {
  const _PhotoGrid({required this.cart});
  final Cart cart;

  @override
  State<_PhotoGrid> createState() => _PhotoGridState();
}

class _PhotoGridState extends State<_PhotoGrid> {
  /// One preview JPEG per cart photo, in cart order (null = not rendered yet).
  List<Uint8List?>? _previews;
  // Only the photo SET (ids), NOT the crops: a re-crop refreshes just its own
  // tile (see [_editTile]); only add / remove triggers a full render.
  String _sig = '';
  // Indices currently re-rendering after an edit — a spinner shows ON that tile
  // (there is no top loading line).
  final Set<int> _busy = <int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _render());
  }

  String _signatureOf(Cart cart) {
    final b = StringBuffer(cart.selectedPack?.size.label ?? '-');
    for (final it in cart.items) {
      b.write(it.id);
    }
    return b.toString();
  }

  Future<void> _render() async {
    final cart = widget.cart;
    final sig = _signatureOf(cart);
    if (cart.selectedPack == null || cart.isEmpty) {
      if (mounted) setState(() => _sig = sig);
      return;
    }
    setState(() => _sig = sig);
    try {
      final jpgs = await renderCroppedJpegs(
        cart,
        maxLongSide: 560,
        jpegQuality: 84,
      );
      if (!mounted || _sig != sig) return;
      setState(() => _previews = List<Uint8List?>.from(jpgs));
    } catch (_) {
      // Leave placeholders; tiles stay editable and the order still validates
      // every photo at upload.
    }
  }

  /// Open ONE photo in the crop screen, then re-render ONLY that tile when it
  /// returns — a spinner shows on the tile while it renders; the rest of the
  /// grid never re-renders (no top loading line).
  Future<void> _editTile(int i) async {
    await context.push('/crop?i=$i');
    if (!mounted) return;
    final cart = widget.cart;
    if (i < 0 || i >= cart.items.length) return;
    setState(() => _busy.add(i));
    final jpg =
        await renderOneCroppedJpeg(cart, i, maxLongSide: 560, jpegQuality: 84);
    if (!mounted) return;
    setState(() {
      final list = _previews;
      if (list != null && i < list.length) list[i] = jpg;
      _busy.remove(i);
      _sig = _signatureOf(cart);
    });
  }

  Future<void> _confirmClearAll(BuildContext context, Cart cart) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all photos?'),
        content: Text(
            'This removes all ${cart.items.length} photos from your cart. '
            'Your pack stays selected so you can add new ones.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep them')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok == true) cart.clearPhotos();
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    if (cart.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            const Icon(Icons.photo_library_outlined,
                color: AppColors.textSecondary, size: 48),
            const SizedBox(height: 8),
            const Text('No photos added yet',
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.push('/photos'),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add photos'),
            ),
          ],
        ),
      );
    }

    // Re-render the previews if the cart changed under us (add / remove /
    // re-crop) — the signature no longer matches what we last rendered.
    if (_sig != _signatureOf(cart)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _render();
      });
    }
    final pack = cart.selectedPack!;
    final previews = _previews;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Flexible(
              child: Text(
                'Your selection',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Builder(builder: (_) {
                  final cap = cart.selectedPack?.snapCount ?? 0;
                  final more = cap - cart.items.length;
                  return TextButton.icon(
                    onPressed: () => context.push('/photos'),
                    icon: const Icon(Icons.add_photo_alternate_outlined,
                        size: 16),
                    label: Text(more > 0 ? 'Add $more more' : 'Add photos'),
                  );
                }),
                TextButton.icon(
                  onPressed: () => _confirmClearAll(context, cart),
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('Clear all'),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.error),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
            childAspectRatio: 0.72,
          ),
          itemCount: cart.items.length,
          itemBuilder: (context, index) {
            final item = cart.items[index];
            final jpg = (previews != null && previews.length > index)
                ? previews[index]
                : null;
            final position = 'Photo ${index + 1} of ${cart.items.length}';
            final tilt = (index.isEven ? -1.0 : 1.0) * 0.012;
            return _SelectionTile(
              jpg: jpg,
              size: pack.size,
              position: position,
              tilt: tilt,
              busy: _busy.contains(index),
              onEdit: () => _editTile(index),
              onRemove: () => cart.remove(item.id),
            );
          },
        ),
      ],
    );
  }
}

/// One cart-selection tile: the photo's real print result ([PrintResultView])
/// with a remove (✕) button and an Edit button that opens the crop screen
/// (crop / Auto crop / zoom / rotate). Tapping anywhere on the tile edits.
class _SelectionTile extends StatelessWidget {
  const _SelectionTile({
    required this.jpg,
    required this.size,
    required this.position,
    required this.tilt,
    required this.busy,
    required this.onEdit,
    required this.onRemove,
  });
  final Uint8List? jpg;
  final PrintSize size;
  final String position;
  final double tilt;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onEdit,
      child: Transform.rotate(
        angle: tilt,
        child: SizedBox.expand(
          child: Stack(
            children: [
              Positioned.fill(
                child: PrintResultView(jpg: jpg, size: size),
              ),
              // While this one photo re-renders after an edit (or on first
              // load), a spinner sits ON the tile — no top loading line.
              if (busy || jpg == null)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.white.withValues(alpha: 0.55),
                    child: const Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor:
                              AlwaysStoppedAnimation(AppColors.primary),
                        ),
                      ),
                    ),
                  ),
                ),
              // Edit pill (bottom-right) — crop / Auto crop / zoom / rotate.
              Positioned(
                right: 8,
                bottom: 8,
                child: GestureDetector(
                  onTap: onEdit,
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
              ),
              // Remove (✕) — 44-dp hit area, 26-dp visible badge, top-right.
              Positioned(
                top: 0,
                right: 0,
                child: Semantics(
                  button: true,
                  label: 'Remove $position',
                  child: Tooltip(
                    message: 'Remove photo',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onRemove,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Align(
                            alignment: const Alignment(0.75, -0.75),
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.2),
                                      blurRadius: 3),
                                ],
                              ),
                              child: const Icon(Icons.close,
                                  size: 16, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.shopping_cart_outlined,
                  size: 80, color: AppColors.textSecondary),
              const SizedBox(height: 16),
              const Text('Your cart is empty',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 24),
              PrimaryButton(
                label: 'Browse products',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => context.go('/home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartSummary extends StatelessWidget {
  const _CartSummary({required this.cart});
  final Cart cart;

  @override
  Widget build(BuildContext context) {
    final pack = cart.selectedPack;
    // Checkout no longer forces the pack to be full — the customer pays the
    // pack price and prints however many photos they added (the "Add N more"
    // prompt at the top of the list reminds them how many more fit). We only
    // need at least one photo and every photo reviewed.
    final hasPhotos = pack != null && cart.itemCount >= 1;
    final allReviewed = cart.allPhotosReady;
    final canCheckout = hasPhotos && allReviewed;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 8),
            PrimaryButton(
              label: canCheckout
                  ? (cart.pdfReady
                      ? 'Continue to address →'
                      : 'Upload  ↑')
                  : !hasPhotos
                      ? 'Add photos'
                      : !allReviewed
                          ? 'Review crops'
                          : 'Select a product',
              icon: canCheckout && !cart.pdfReady
                  ? Icons.cloud_upload_outlined
                  : null,
              onPressed: canCheckout
                  ? (cart.pdfReady
                      ? () => context.push('/address')
                      : () => context.push('/upload'))
                  : !hasPhotos
                      ? () => context.push('/photos')
                      : !allReviewed
                          ? () => context.push('/crop')
                          : () => context.go('/home'),
            ),
          ],
        ),
      ),
    );
  }
}
