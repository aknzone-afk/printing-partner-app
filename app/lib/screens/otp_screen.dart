import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../services/firebase/auth_service.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

/// Navigation payload for /otp — produced by the login screen after
/// FirebaseAuth sends the SMS.
class OtpArgs {
  const OtpArgs({
    required this.phoneNumber,
    required this.verificationId,
    this.resendToken,
    this.redirectTo,
  });
  final String phoneNumber;
  final String verificationId;
  final int? resendToken;

  /// Where to land after successful sign-in (defaults to /home). Lets the
  /// checkout flow bounce through login and come straight back.
  final String? redirectTo;
}

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.args});

  final OtpArgs args;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _otpController = TextEditingController();
  bool _submitting = false;
  int _resendSeconds = 30;
  late String _verificationId;
  int? _resendToken;

  @override
  void initState() {
    super.initState();
    _verificationId = widget.args.verificationId;
    _resendToken = widget.args.resendToken;
    _startResendTimer();
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  void _startResendTimer() async {
    while (_resendSeconds > 0 && mounted) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() => _resendSeconds--);
    }
  }

  Future<void> _verifyOtp() async {
    if (_otpController.text.length != 6 || _submitting) return;
    setState(() => _submitting = true);
    final error = await AuthService.instance.verifyOtp(
      verificationId: _verificationId,
      smsCode: _otpController.text,
    );
    if (!mounted) return;
    if (error == null) {
      context.go(widget.args.redirectTo ?? '/home');
    } else {
      setState(() => _submitting = false);
      _otpController.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _resend() async {
    setState(() => _resendSeconds = 30);
    _startResendTimer();
    await AuthService.instance.sendOtp(
      phoneE164: widget.args.phoneNumber,
      resendToken: _resendToken,
      onCodeSent: (verificationId, resendToken) {
        if (!mounted) return;
        setState(() {
          _verificationId = verificationId;
          _resendToken = resendToken;
        });
      },
      onAutoVerified: () {
        if (!mounted) return;
        context.go(widget.args.redirectTo ?? '/home');
      },
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.canPop() ? context.pop() : context.go('/login'),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const Text(
                'Enter verification code',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sent to ${widget.args.phoneNumber}',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                autofocus: true,
                autofillHints: const [AutofillHints.oneTimeCode],
                style: const TextStyle(
                  fontSize: 24,
                  letterSpacing: 12,
                  fontWeight: FontWeight.w600,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: const InputDecoration(
                  hintText: '••••••',
                  counterText: '',
                ),
                onChanged: (value) {
                  setState(() {}); // refresh the button enabled state
                  if (value.length == 6) _verifyOtp();
                },
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: _resendSeconds > 0 ? null : _resend,
                  child: Text(
                    _resendSeconds > 0
                        ? 'Resend code in ${_resendSeconds}s'
                        : 'Resend code',
                  ),
                ),
              ),
              const Spacer(),
              PrimaryButton(
                label: 'Verify & continue',
                loading: _submitting,
                onPressed: _otpController.text.length == 6 ? _verifyOtp : null,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
