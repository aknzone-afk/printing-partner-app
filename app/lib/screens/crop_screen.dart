import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../models/cart.dart';
import '../models/photo_item.dart';
import '../services/photo_export.dart';
import '../theme.dart';
import '../widgets/photo_thumb.dart';

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
  // Per-photo orientation probe, cached so bulk actions can AWAIT it (every
  // photo's auto-rotation must be known before a crop is written for it).
  final Map<String, Future<void>> _orientFutures = {};
  // Oriented source size per photo, cached from the probe — the Fill toggle
  // needs it to compute the cover-zoom factor.
  final Map<String, Size> _sizes = {};
  // Which mode the customer last tapped on the Fit/Fill toggle: 0 = Fit (whole
  // photo, white edges), 1 = Fill (crop edges). Null = they then hand-adjusted.
  final Map<String, int?> _fitFill = {};
  final GlobalKey _viewerKey = GlobalKey();

  /// True when this screen was opened to edit ONE photo from the cart
  /// (`/crop?i=N`) rather than to review the whole set. Back / Save then return
  /// to the cart instead of stepping through the other photos.
  bool _single = false;
  bool _didInit = false;

  /// Seeds the viewer matrix from a previously-saved crop so re-opening a photo
  /// shows exactly what the customer framed (not the default fit).
  TransformationController _ctrlFor(String id) {
    return _controllers.putIfAbsent(id, () {
      final ctrl = TransformationController();
      final edit = context.read<Cart>().cropFor(id);
      if (edit != null && !edit.skipped && edit.hasView) {
        ctrl.value = Matrix4.identity()
          ..translate(edit.offsetX, edit.offsetY)
          ..scale(edit.scale, edit.scale);
      }
      return ctrl;
    });
  }

  int _rotFor(String id) => _rotations[id] ?? 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    // Restore the saved rotation for every already-cropped photo BEFORE the
    // first build, so the seeded viewer matrix (captured relative to the
    // rotated photo) agrees with the rotation shown. Without this, a photo the
    // customer manually rotated re-opens at rotation 0 with a matrix that means
    // a different frame — showing, and on Save storing, the wrong crop.
    final seedCart = context.read<Cart>();
    for (final it in seedCart.items) {
      final e = seedCart.cropFor(it.id);
      if (e != null && !e.skipped && e.rotationSteps != 0) {
        _rotations[it.id] = e.rotationSteps;
      }
    }
    bool hasI;
    try {
      hasI = GoRouterState.of(context).uri.queryParameters['i'] != null;
    } catch (_) {
      hasI = widget.startIndex > 0;
    }
    _single = hasI;
    if (hasI) {
      _index = widget.startIndex;
      return;
    }
    // Whole-set review: open the FIRST photo that has no crop yet, so the
    // customer resumes where they left off instead of always at photo 1.
    final cart = context.read<Cart>();
    for (var i = 0; i < cart.items.length; i++) {
      if (cart.cropFor(cart.items[i].id) == null) {
        _index = i;
        return;
      }
    }
    _index = 0;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _back() {
    if (_single) {
      context.canPop() ? context.pop() : context.go('/cart');
      return;
    }
    if (_index == 0) {
      context.canPop() ? context.pop() : context.go('/photos');
      return;
    }
    setState(() => _index--);
  }

  void _save() {
    final cart = context.read<Cart>();
    final item = cart.items[_index];
    // Record EXACTLY what is on screen right now — the viewer matrix (pan +
    // zoom), the frame it applies to, and the rotation the customer is looking
    // at. The orientation probe only auto-rotates on LOAD; by the time Save is
    // tapped whatever rotation is applied IS what was seen, so we must not wait
    // for the probe (that would block Save) nor let it change the rotation
    // afterwards — the print must match the screen the customer saved from.
    final m = _ctrlFor(item.id).value;
    final rotation = _rotFor(item.id);
    // The frame the customer is looking at = the viewer matrix plus the size of
    // the frame it applies to. The export replays exactly that against the
    // photo's true pixel size (cropFrameRect).
    final box = _viewerKey.currentContext?.findRenderObject() as RenderBox?;
    final frame = (box != null && box.hasSize) ? box.size : Size.zero;
    if (frame.width <= 0 || frame.height <= 0) {
      // Frame size still unknown (viewer not laid out yet): fall back to
      // white-pad (BoxFit.contain), which is what the screen was showing —
      // never a surprise centre-cover.
      cart.setCrop(item.id, CropEdit.skipped(rotationSteps: rotation));
    } else {
      cart.setCrop(
        item.id,
        CropEdit.cropped(
          offsetX: m.getTranslation().x,
          offsetY: m.getTranslation().y,
          scale: m.getMaxScaleOnAxis(),
          rotationSteps: rotation,
          viewWidth: frame.width,
          viewHeight: frame.height,
        ),
      );
    }
    _advance();
  }


  void _advance() {
    // Editing a single photo (from the cart or the preview page): one Save,
    // pop back to wherever it was opened from.
    if (_single) {
      context.canPop() ? context.pop() : context.go('/preview');
      return;
    }
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
    context.go('/preview');
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
      _fitFill[id] = 0; // back to whole-photo fit
    });
  }

  /// "Fit": show the WHOLE photo (white edges where it doesn't fill) — just the
  /// identity viewer matrix on the BoxFit.contain child.
  void _applyFit(String id) {
    setState(() {
      _ctrlFor(id).value = Matrix4.identity();
      _fitFill[id] = 0;
    });
  }

  /// "Reset": undo all zoom / pan / rotation back to the whole photo centred —
  /// the escape hatch if the customer pans the photo off the canvas.
  void _resetCrop(String id) {
    setState(() {
      _ctrlFor(id).value = Matrix4.identity();
      _rotations[id] = 0;
      _fitFill[id] = 0;
    });
  }

  /// "Fill": zoom the photo so it covers the whole print (crops the long edges),
  /// centred — the customer then just drags to position. Needs the photo's
  /// oriented aspect to know how much to scale up from the contain fit.
  Future<void> _applyFill(PhotoItem item, double frameAspect) async {
    final id = item.id;
    var size = _sizes[id];
    if (size == null) {
      try {
        size = await resolveImageSize(item.localPath);
        _sizes[id] = size;
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    // Account for 90°/270° rotation swapping the photo's width/height.
    var photoAspect = size.width / size.height;
    if (_rotFor(id) % 2 == 1) photoAspect = 1 / photoAspect;
    // cover / contain scale ratio (always >= 1).
    final factor = photoAspect > frameAspect
        ? photoAspect / frameAspect
        : frameAspect / photoAspect;
    final ctrl = _ctrlFor(id);
    ctrl.value = Matrix4.identity();
    _scaleAroundCenter(ctrl, factor);
    setState(() => _fitFill[id] = 1);
  }

  /// Scale the viewer by [factor] around the viewport centre (so the photo
  /// grows from the middle, not the top-left corner).
  void _scaleAroundCenter(TransformationController ctrl, double factor) {
    final cur = ctrl.value.clone();
    final box = _viewerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      cur.scale(factor, factor);
      ctrl.value = cur;
      return;
    }
    final size = box.size;
    final center = Vector3(size.width / 2, size.height / 2, 0);
    final scene = Matrix4.inverted(cur).transform3(center);
    cur.translate(scene.x, scene.y);
    cur.scale(factor, factor);
    cur.translate(-scene.x, -scene.y);
    ctrl.value = cur;
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

  /// Probes a photo's orientation ONCE (cached), so both the on-screen auto-
  /// orient and the bulk actions can await the same work. The shared
  /// [resolveImageSize] reads only the (EXIF-oriented) dimensions at a tiny
  /// decode size — never a full-resolution bitmap.
  Future<void> _autoOrientIfNeeded(PhotoItem item, double frameAspect) {
    // A photo the customer has already reviewed carries its own saved rotation;
    // never let the auto-orient probe override it (it would clobber a restored
    // rotation and silently change the print).
    if (context.read<Cart>().cropFor(item.id) != null) {
      return Future<void>.value();
    }
    return _orientFutures.putIfAbsent(
        item.id, () => _probeAndOrient(item, frameAspect));
  }

  Future<void> _probeAndOrient(PhotoItem item, double frameAspect) async {
    try {
      final size = await resolveImageSize(item.localPath);
      _sizes[item.id] = size;
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

    return PopScope(
      // Android system Back must not close the app (losing the just-picked
      // photos) when the crop screen was auto-opened from the picker. Route it
      // through the same logic as the app-bar Back instead.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _back();
      },
      child: Scaffold(
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
                              // The moment the customer pans/zooms by hand, it's
                              // no longer a clean Fit/Fill — clear the pill so
                              // the Fit/Fill highlight (and Save's white-pad
                              // detection) reflect reality.
                              onInteractionStart: (_) {
                                if (_fitFill[item.id] != null) {
                                  setState(() => _fitFill[item.id] = null);
                                }
                              },
                              // Room to pan the photo once it's zoomed out
                              // below 1× (and to pinch back below 1×) instead
                              // of it locking in place.
                              boundaryMargin: const EdgeInsets.all(160),
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
                        onReset: () => _resetCrop(item.id),
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  // One-tap framing: "Fit whole photo" shows everything with
                  // white edges; "Fill print" zooms to crop the edges, centred,
                  // and the customer just drags to position. They can still
                  // pinch / drag freely afterwards.
                  _FitFillToggle(
                    mode: _fitFill[item.id],
                    onFit: () => _applyFit(item.id),
                    onFill: () => _applyFill(item, aspect),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.check_rounded, size: 20),
                      label: const Text('Save crop',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        minimumSize: const Size(0, 54),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// A two-segment pill: "Fit whole photo" (white edges) | "Fill print" (crop
/// edges). The active segment is highlighted; tapping either applies that
/// framing instantly.
class _FitFillToggle extends StatelessWidget {
  const _FitFillToggle({
    required this.mode,
    required this.onFit,
    required this.onFill,
  });

  /// 0 = Fit selected, 1 = Fill selected, null = neither (hand-adjusted).
  final int? mode;
  final VoidCallback onFit;
  final VoidCallback onFill;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.lavender,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          _seg(
            label: 'Fit whole photo',
            icon: Icons.fit_screen_rounded,
            selected: mode == 0,
            onTap: onFit,
          ),
          _seg(
            label: 'Fill print',
            icon: Icons.crop_free_rounded,
            selected: mode == 1,
            onTap: onFill,
          ),
        ],
      ),
    );
  }

  Widget _seg({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: selected ? AppColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 16,
                    color: selected ? Colors.white : AppColors.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: selected ? Colors.white : AppColors.primary,
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

class _CropControls extends StatelessWidget {
  const _CropControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRotate,
    required this.onReset,
  });
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRotate;
  final VoidCallback onReset;

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
          const SizedBox(height: 4),
          _RoundIconBtn(icon: Icons.restart_alt_rounded, onTap: onReset),
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
              'Drag, zoom in/out or rotate to frame $dimensions, then Save.',
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
  // Draw each segment as a BLACK line over a thin WHITE halo, so the grid is
  // visible on ANY background: the photo, OR the white padding around a
  // contained photo (where a plain white grid was invisible).
  void _strokeAll(Canvas canvas, List<List<Offset>> segs, Paint halo,
      Paint line) {
    for (final s in segs) {
      canvas.drawLine(s[0], s[1], halo);
    }
    for (final s in segs) {
      canvas.drawLine(s[0], s[1], line);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Rule-of-thirds grid.
    _strokeAll(
      canvas,
      <List<Offset>>[
        [Offset(w / 3, 0), Offset(w / 3, h)],
        [Offset(2 * w / 3, 0), Offset(2 * w / 3, h)],
        [Offset(0, h / 3), Offset(w, h / 3)],
        [Offset(0, 2 * h / 3), Offset(w, 2 * h / 3)],
      ],
      Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );

    // Corner brackets.
    const c = 18.0;
    _strokeAll(
      canvas,
      <List<Offset>>[
        [const Offset(0, 0), const Offset(c, 0)],
        [const Offset(0, 0), const Offset(0, c)],
        [Offset(w, 0), Offset(w - c, 0)],
        [Offset(w, 0), Offset(w, c)],
        [Offset(0, h), Offset(c, h)],
        [Offset(0, h), Offset(0, h - c)],
        [Offset(w, h), Offset(w - c, h)],
        [Offset(w, h), Offset(w, h - c)],
      ],
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = 4.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
      Paint()
        ..color = Colors.black
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
