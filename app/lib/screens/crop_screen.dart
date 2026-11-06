import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../models/cart.dart';
import '../models/photo_item.dart';
import '../theme.dart';
import '../widgets/photo_thumb.dart';
import '../widgets/primary_button.dart';

/// Per-photo crop screen.
/// • Drag to pan (within zoomed view).
/// • + / − buttons (or pinch / scroll) to zoom.
/// • Rotate button rotates 90° clockwise.
/// • On load each photo auto-orients to whichever 0/90° rotation covers more
///   of the crop frame — minimizes white space.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, this.startIndex = 0});

  /// Photo index to start at (used when re-editing a single photo from cart).
  final int startIndex;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late int _index = widget.startIndex;
  final Map<String, TransformationController> _controllers = {};
  final Map<String, int> _rotations = {}; // 0..3 (× 90°)
  final Set<String> _autoOriented = {};
  final GlobalKey _viewerKey = GlobalKey();

  TransformationController _ctrlFor(String id) =>
      _controllers.putIfAbsent(id, () => TransformationController());

  int _rotFor(String id) => _rotations[id] ?? 0;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _back() {
    if (_index == 0) {
      context.canPop() ? context.pop() : context.go('/photos');
      return;
    }
    setState(() => _index--);
  }

  void _save() {
    final cart = context.read<Cart>();
    final item = cart.items[_index];
    final m = _ctrlFor(item.id).value;
    cart.setCrop(
      item.id,
      CropEdit.cropped(
        offsetX: m.getTranslation().x,
        offsetY: m.getTranslation().y,
        scale: m.getMaxScaleOnAxis(),
        rotationSteps: _rotFor(item.id),
      ),
    );
    _advance();
  }

  /// Mark every remaining photo as skipped (white-pad) and jump to cart.
  void _skipAll() {
    final cart = context.read<Cart>();
    for (var i = _index; i < cart.items.length; i++) {
      final item = cart.items[i];
      cart.setCrop(
          item.id, CropEdit.skipped(rotationSteps: _rotFor(item.id)));
    }
    context.go('/cart');
  }

  /// Auto-crop every remaining photo: center, fill the frame, no white space.
  void _autoCropAll() {
    final cart = context.read<Cart>();
    for (var i = _index; i < cart.items.length; i++) {
      final item = cart.items[i];
      cart.setCrop(
        item.id,
        CropEdit.cropped(
          offsetX: 0,
          offsetY: 0,
          scale: 1,
          rotationSteps: _rotFor(item.id),
        ),
      );
    }
    context.go('/cart');
  }

  void _advance() {
    final cart = context.read<Cart>();
    // Go to the next UNREVIEWED photo. If none exists, return to cart.
    // This makes the button work for both first-time flow and cart re-edits.
    for (var i = _index + 1; i < cart.items.length; i++) {
      if (cart.cropFor(cart.items[i].id) == null) {
        setState(() => _index = i);
        return;
      }
    }
    // Wrap around: also check earlier photos that might be unreviewed.
    for (var i = 0; i < _index; i++) {
      if (cart.cropFor(cart.items[i].id) == null) {
        setState(() => _index = i);
        return;
      }
    }
    context.go('/cart');
  }

  void _zoomBy(double factor) {
    final cart = context.read<Cart>();
    final ctrl = _ctrlFor(cart.items[_index].id);
    final cur = ctrl.value.clone();
    final newScale = cur.getMaxScaleOnAxis() * factor;
    if (newScale < 0.5 || newScale > 6) return;

    // Zoom around the CENTER of the viewport, not the top-left corner.
    final renderBox =
        _viewerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      cur.scale(factor, factor);
      ctrl.value = cur;
      return;
    }
    final size = renderBox.size;
    final viewportCenter = Vector3(size.width / 2, size.height / 2, 0);

    // Find the scene-space point currently under the viewport center.
    final inverse = Matrix4.inverted(cur);
    final sceneCenter = inverse.transform3(viewportCenter);

    // Compose: translate to sceneCenter, scale, translate back.
    cur.translate(sceneCenter.x, sceneCenter.y);
    cur.scale(factor, factor);
    cur.translate(-sceneCenter.x, -sceneCenter.y);

    ctrl.value = cur;
  }

  void _rotate90() {
    final cart = context.read<Cart>();
    final id = cart.items[_index].id;
    setState(() {
      _rotations[id] = (_rotFor(id) + 1) % 4;
      // Reset zoom/pan when rotation changes so the auto-fit takes hold.
      _ctrlFor(id).value = Matrix4.identity();
    });
  }

  /// Best-fit rotation calculator: 0° or 90° depending on which gives more
  /// frame coverage (less white space) for the given photo size.
  int _bestRotation(Size photo, double frameAspect) {
    double coverage(double pw, double ph) {
      const fw = 1.0;
      final fh = 1 / frameAspect;
      final scale = math.min(fw / pw, fh / ph);
      return (pw * ph * scale * scale) / (fw * fh);
    }
    final original = coverage(photo.width, photo.height);
    final rotated = coverage(photo.height, photo.width);
    return rotated > original ? 1 : 0;
  }

  Future<void> _autoOrientIfNeeded(PhotoItem item, double frameAspect) async {
    if (_autoOriented.contains(item.id)) return;
    _autoOriented.add(item.id);
    try {
      final size = await _resolveImageSize(item.localPath);
      if (!mounted) return;
      final best = _bestRotation(size, frameAspect);
      if (best != 0 && _rotFor(item.id) == 0) {
        setState(() {
          _rotations[item.id] = best;
        });
      }
    } catch (_) {
      // If size resolution fails, fall back to no rotation — that's fine.
    }
  }

  Future<Size> _resolveImageSize(String path) {
    final completer = Completer<Size>();
    final provider = CachedNetworkImageProvider(path);
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        completer.complete(Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        ));
        stream.removeListener(listener);
      },
      onError: (e, _) {
        completer.completeError(e);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    if (cart.isEmpty || cart.selectedPack == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('CROP PHOTOS')),
        body: const Center(child: Text('No photos to crop.')),
      );
    }

    final pack = cart.selectedPack!;
    final item = cart.items[_index];
    final aspect = pack.size.imageAspectWxH;
    final total = cart.items.length;
    final existing = cart.cropFor(item.id);
    final reviewed = existing != null;

    // Kick off best-rotation detection for the current photo (idempotent).
    _autoOrientIfNeeded(item, aspect);

    final rotation = _rotFor(item.id);

    return Scaffold(
      appBar: AppBar(
        title: Text('REVIEW ${_index + 1} OF $total'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _back,
        ),
        actions: [
          TextButton(
            onPressed: () => context.go('/cart'),
            child: const Text('Cart'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _Hint(dimensions: pack.size.dimensions),
            Expanded(
              child: Container(
                color: Colors.black,
                padding: const EdgeInsets.all(20),
                alignment: Alignment.center,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      key: _viewerKey,
                      aspectRatio: aspect,
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(color: Colors.white),
                            InteractiveViewer(
                              transformationController:
                                  _ctrlFor(item.id),
                              minScale: 0.5,
                              maxScale: 6,
                              // RotatedBox swaps layout dimensions for 90°/270°
                              // rotations, so BoxFit.contain re-fits the rotated
                              // photo into the frame and minimizes white space.
                              child: RotatedBox(
                                quarterTurns: rotation,
                                child: PhotoThumb(
                                  path: item.localPath,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child:
                                  CustomPaint(painter: _CropFramePainter()),
                            ),
                            if (reviewed)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: existing.skipped
                                        ? Colors.orange
                                        : AppColors.success,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    existing.skipped
                                        ? 'WHITE-PAD'
                                        : 'CROPPED',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      child: _CropControls(
                        onZoomIn: () => _zoomBy(1.25),
                        onZoomOut: () => _zoomBy(0.8),
                        onRotate: _rotate90,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _ThumbStrip(
              items: cart.items,
              currentIndex: _index,
              cart: cart,
              onTap: (i) => setState(() => _index = i),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _skipAll,
                          icon: const Icon(
                              Icons.format_color_fill_outlined,
                              size: 18),
                          label: const Text('Skip all',
                              style: TextStyle(fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _autoCropAll,
                          icon: const Icon(Icons.auto_fix_high_outlined,
                              size: 18),
                          label: const Text('Auto crop',
                              style: TextStyle(fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            minimumSize: const Size(0, 48),
                            foregroundColor: AppColors.primary,
                            side: const BorderSide(color: AppColors.primary),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  PrimaryButton(
                    label: _index >= total - 1 ? 'Save · Done' : 'Save · Next',
                    icon: Icons.check_rounded,
                    onPressed: _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropControls extends StatelessWidget {
  const _CropControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRotate,
  });
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRotate;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(28),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoundIconBtn(icon: Icons.add, onTap: onZoomIn),
          const SizedBox(height: 4),
          _RoundIconBtn(icon: Icons.remove, onTap: onZoomOut),
          const SizedBox(height: 4),
          _RoundIconBtn(icon: Icons.rotate_right_rounded, onTap: onRotate),
        ],
      ),
    );
  }
}

class _RoundIconBtn extends StatelessWidget {
  const _RoundIconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.dimensions});
  final String dimensions;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.lavender,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.crop_rounded,
              color: AppColors.primary, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Drag · zoom · rotate to fit $dimensions, or Skip for white space.',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbStrip extends StatelessWidget {
  const _ThumbStrip({
    required this.items,
    required this.currentIndex,
    required this.cart,
    required this.onTap,
  });
  final List<PhotoItem> items;
  final int currentIndex;
  final Cart cart;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      color: Colors.black.withValues(alpha: 0.04),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final isCurrent = i == currentIndex;
          final edit = cart.cropFor(items[i].id);
          final reviewed = edit != null;
          return GestureDetector(
            onTap: () => onTap(i),
            child: Container(
              width: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isCurrent
                      ? AppColors.primary
                      : (reviewed ? AppColors.success : Colors.transparent),
                  width: 2,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: PhotoThumb(
                      path: items[i].localPath,
                      fit: BoxFit.cover,
                    ),
                  ),
                  if (reviewed)
                    Positioned(
                      bottom: 1,
                      right: 1,
                      child: Container(
                        padding: const EdgeInsets.all(1),
                        decoration: const BoxDecoration(
                          color: AppColors.success,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check,
                            size: 9, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CropFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(w / 3, 0), Offset(w / 3, h), grid);
    canvas.drawLine(Offset(2 * w / 3, 0), Offset(2 * w / 3, h), grid);
    canvas.drawLine(Offset(0, h / 3), Offset(w, h / 3), grid);
    canvas.drawLine(Offset(0, 2 * h / 3), Offset(w, 2 * h / 3), grid);

    final corner = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const cornerLen = 18.0;
    canvas.drawLine(const Offset(0, 0), const Offset(cornerLen, 0), corner);
    canvas.drawLine(const Offset(0, 0), const Offset(0, cornerLen), corner);
    canvas.drawLine(Offset(w, 0), Offset(w - cornerLen, 0), corner);
    canvas.drawLine(Offset(w, 0), Offset(w, cornerLen), corner);
    canvas.drawLine(Offset(0, h), Offset(cornerLen, h), corner);
    canvas.drawLine(Offset(0, h), Offset(0, h - cornerLen), corner);
    canvas.drawLine(Offset(w, h), Offset(w - cornerLen, h), corner);
    canvas.drawLine(Offset(w, h), Offset(w, h - cornerLen), corner);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
