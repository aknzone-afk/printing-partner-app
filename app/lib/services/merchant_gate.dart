import 'package:flutter/material.dart';

/// A PIN gate for owner-only surfaces — opening the merchant dashboard and
/// disconnecting the OneDrive store. Without it, anyone who long-presses the
/// logo could reach the shop's order list or unlink its storage.
///
/// The PIN is set at build time with `--dart-define=PP_MERCHANT_PIN=…`; the
/// default keeps the current on-device demo working. A real deployment should
/// pass its own PIN so the default is never the live one.
class MerchantGate {
  MerchantGate._();

  static const String _pin = String.fromEnvironment(
    'PP_MERCHANT_PIN',
    defaultValue: '4001',
  );

  /// Prompts for the PIN and returns true only when it matches. A customer who
  /// stumbles onto the gate (or cancels) never gets in.
  static Future<bool> verify(BuildContext context, {String? title}) async {
    final controller = TextEditingController();
    bool matches() => controller.text.trim() == _pin;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title ?? 'Enter merchant PIN'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 8,
          decoration: const InputDecoration(hintText: 'PIN', counterText: ''),
          onSubmitted: (_) => Navigator.pop(ctx, matches()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, matches()),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
