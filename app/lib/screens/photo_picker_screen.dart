import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
// PhotoManager / PermissionState come through this package's re-export.
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../models/cart.dart';
import '../models/photo_item.dart';
import '../services/photo_export.dart';
import '../theme.dart';
import '../widgets/photo_thumb.dart';
import '../widgets/primary_button.dart';

class PhotoPickerScreen extends StatefulWidget {
  const PhotoPickerScreen({super.key, this.autoOpen = false});

  /// True when opened from the cart's "Add N more" — jump straight into the
  /// phone gallery and, once it closes, pop back to the cart without ever
  /// showing this intermediate "select photos" page.
  final bool autoOpen;

  @override
  State<PhotoPickerScreen> createState() => _PhotoPickerScreenState();
}

class _PhotoPickerScreenState extends State<PhotoPickerScreen> {
  bool _picking = false;
  bool _autoOpened = false;

  int get _target => context.read<Cart>().targetSnapCount;
  int get _picked => context.read<Cart>().totalPrints;
  int get _remaining => (_target - _picked).clamp(0, _target);

  @override
  void initState() {
    super.initState();
    // Open the asset picker immediately — either from a pack-pill tap on an
    // empty cart (skip the intro state), or from the cart's "Add N more"
    // (widget.autoOpen) so the gallery opens with no in-between page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _autoOpened) return;
      final cart = context.read<Cart>();
      if (widget.autoOpen || (cart.selectedPack != null && cart.isEmpty)) {
        _autoOpened = true;
        _pickFromGallery();
      }
    });
  }

  Future<void> _pickFromGallery() async {
    if (_picking) return; // a picker is already open — ignore a double-tap
    final wasAutoOpen = _autoOpened && context.read<Cart>().isEmpty;
    // Opened from the cart's "Add N more": once the gallery closes (photos
    // added OR cancelled), pop straight back to the cart — never render this
    // page. (Pack-becomes-complete still goes forward to the preview below.)
    final returnToCaller = widget.autoOpen;
    setState(() => _picking = true);
    try {
      // Ask for photo access first, so a denial shows a way forward (Settings)
      // instead of a raw error from deep inside the picker.
      final ps = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;
      if (!ps.hasAccess) {
        setState(() => _picking = false);
        await _showPermissionDialog();
        if ((wasAutoOpen || returnToCaller) && mounted && context.canPop()) {
          context.pop();
        }
        return;
      }

      // wechat_assets_picker enforces maxAssets at the UI level — the user
      // physically cannot select more than the pack allows. The picker
      // displays a live "X / Y" counter and disables further checkmarks
      // once the cap is hit.
      final maxAssets = _remaining > 0 ? _remaining : 99;
      final List<AssetEntity>? result = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          maxAssets: maxAssets,
          requestType: RequestType.image,
          themeColor: AppColors.primary,
          gridCount: 4,
          pageSize: 80,
          // Tap a photo = select it instantly (no full-screen preview step),
          // so picking many photos is just tap, tap, tap, then Done.
          specialPickerType: SpecialPickerType.noPreview,
        ),
      );
      if (!mounted) return;
      if (result != null && result.isNotEmpty) {
        // Resolve each AssetEntity to a file AND validate it's decodable, all
        // BEFORE the customer ever pays (a corrupt / still-in-iCloud photo is
        // caught here, not after payment). Done concurrently in small batches
        // of 4 so a 50-photo pick doesn't crawl one slow fetch at a time, while
        // still bounding IO. One bad asset never drops the rest of the pick.
        final good = <String>[];
        var failed = 0; // file couldn't load (e.g. still in iCloud)
        var bad = 0; // loaded but not a decodable image
        const batchSize = 4;
        for (var start = 0; start < result.length; start += batchSize) {
          final end = (start + batchSize) < result.length
              ? start + batchSize
              : result.length;
          final outcomes = await Future.wait(
            result.sublist(start, end).map((asset) async {
              try {
                final file = await asset.originFile;
                if (file == null) return (path: null as String?, kind: 'failed');
                final ok = await canDecodeImage(file.path);
                return (path: ok ? file.path : null, kind: ok ? 'good' : 'bad');
              } catch (_) {
                return (path: null as String?, kind: 'failed');
              }
            }),
          );
          for (final o in outcomes) {
            if (o.kind == 'good') {
              good.add(o.path!);
            } else if (o.kind == 'failed') {
              failed++;
            } else {
              bad++;
            }
          }
        }
        if (!mounted) return;

        final cart = context.read<Cart>();
        if (good.isNotEmpty) {
          cart.addPhotos(good);
          // Auto cover-crop the newly picked photos so the preview shows them
          // already fitted to the print (the customer edits only if they want).
          cart.autoFillCrops();
        }
        if (failed > 0 || bad > 0) _showSkippedMessage(failed, bad);

        if (_target > 0 &&
            cart.totalPrints >= _target &&
            good.isNotEmpty &&
            mounted) {
          // push (not go): Android system Back on the auto-opened crop screen
          // must return here, keeping the picked photos, not close the app.
          context.push('/preview');
          return;
        }
        // Came from the cart to add more (or the empty-cart auto-open with
        // nothing added) → go straight back instead of showing this page.
        if ((returnToCaller || (good.isEmpty && wasAutoOpen)) &&
            mounted &&
            context.canPop()) {
          context.pop();
          return;
        }
      } else if ((wasAutoOpen || returnToCaller) && mounted) {
        // Gallery cancelled with nothing picked → return to where we came from.
        if (context.canPop()) {
          context.pop();
        }
        return;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not pick photos: $e')),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _showPermissionDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Photo access needed'),
        content: const Text(
          'Printing Partner needs permission to open your photos. Enable photo '
          'access in Settings, then tap Open Gallery again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              PhotoManager.openSetting();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _showSkippedMessage(int failed, int bad) {
    if (!mounted) return;
    final parts = <String>[];
    if (failed > 0) {
      parts.add('$failed photo${failed == 1 ? '' : 's'} could not be loaded '
          '(they may be in iCloud) — pick ${failed == 1 ? 'it' : 'them'} '
          'again');
    }
    if (bad > 0) {
      parts.add('$bad photo${bad == 1 ? '' : 's'} could not be opened and '
          '${bad == 1 ? 'was' : 'were'} skipped');
    }
    if (parts.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${parts.join('. ')}.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    final pack = cart.selectedPack;
    final target = pack?.snapCount ?? 0;
    final picked = cart.totalPrints;
    final remaining = (target - picked).clamp(0, target);
    final complete = target > 0 && picked >= target;

    // While the OS picker is open, render a minimal loader instead of the full
    // page — both for the empty-cart auto-open AND the cart's "Add more"
    // (widget.autoOpen), so this intermediate page never flashes behind it.
    final showPickerOverlay = _picking && (cart.isEmpty || widget.autoOpen);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SELECT PHOTOS'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: SafeArea(
        child: showPickerOverlay
            ? const _OpeningGalleryView()
            : Column(
                children: [
                  if (pack != null) _PackHeader(cart: cart),
                  Expanded(
                    child: cart.isEmpty
                        ? _EmptyState(target: target)
                        : Padding(
                            padding: const EdgeInsets.all(16),
                            child: _PreviewGrid(
                              items: cart.items,
                              aspectWxH: pack?.size.imageAspectWxH ?? 1,
                              onRemove: (id) => cart.remove(id),
                            ),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      children: [
                        // Gallery button only when pack isn't full yet.
                        if (!complete) ...[
                          PrimaryButton(
                            label: picked == 0
                                ? 'Open Gallery'
                                : 'Add ${remaining > 0 ? remaining : ""} more',
                            icon: Icons.photo_library_rounded,
                            loading: _picking,
                            onPressed: _pickFromGallery,
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (target > 0)
                          // Preview is reachable as soon as there's one photo —
                          // the customer can review a partial pack and add the
                          // rest later (or order it as-is for the pack price).
                          PrimaryButton(
                            label: complete
                                ? 'See preview  →'
                                : 'Preview $picked of $target  →',
                            icon: Icons.arrow_forward_rounded,
                            onPressed: cart.isEmpty
                                ? null
                                : () => context.push('/preview'),
                          )
                        else if (!cart.isEmpty)
                          PrimaryButton(
                            label: 'Continue →',
                            onPressed: () => context.push('/preview'),
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

class _OpeningGalleryView extends StatelessWidget {
  const _OpeningGalleryView();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Opening gallery…',
            style: TextStyle(
                fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _PackHeader extends StatelessWidget {
  const _PackHeader({required this.cart});
  final Cart cart;

  @override
  Widget build(BuildContext context) {
    final pack = cart.selectedPack!;
    final picked = cart.totalPrints;
    final target = pack.snapCount;
    final progress = target == 0 ? 0.0 : (picked / target).clamp(0.0, 1.0);
    final complete = picked >= target;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: complete
              ? [AppColors.success, AppColors.success]
              : [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${pack.size.label} · ${pack.size.dimensions}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$picked / $target ${pack.size.category.unit} selected',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      complete
                          ? 'Pack complete — tap Crop & review'
                          : 'Max $target — picker will stop at this limit',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                pack.priceLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.25),
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.target});
  final int target;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              height: 120,
              width: 120,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.add_photo_alternate_outlined,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              target > 0
                  ? 'Pick $target photos for your pack'
                  : 'Pick the photos you want printed',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'You can pick multiple photos at once.\nWe support JPG, PNG and HEIC formats.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, color: AppColors.textSecondary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewGrid extends StatelessWidget {
  const _PreviewGrid({
    required this.items,
    required this.aspectWxH,
    required this.onRemove,
  });
  final List<PhotoItem> items;
  final double aspectWxH;
  final void Function(String id) onRemove;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Stack(
          fit: StackFit.expand,
          children: [
            // Uncropped: letterbox-fit on white so customer sees the full
            // original photo and knows cropping hasn't happened yet.
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: PhotoThumb(
                  path: item.localPath,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: InkWell(
                onTap: () => onRemove(item.id),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close,
                      size: 14, color: Colors.white),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
