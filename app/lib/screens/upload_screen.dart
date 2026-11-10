import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The 12×18 sheet-PDF step is retired: it was built from the UNCROPPED
/// originals and nothing in the order flow consumed it (the real upload sends
/// the INDIVIDUAL cropped JPEGs from checkout). This screen is now only a
/// pass-through — the cart's "Upload" button lands here and is forwarded
/// straight to the address step.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go('/address');
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
