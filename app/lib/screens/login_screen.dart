import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../services/firebase/auth_service.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';
import 'otp_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.redirectTo});

  /// Where to land after sign-in (e.g. '/checkout'). Defaults to /home.
  final String? redirectTo;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _onContinue() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    final phone = '+91${_phoneController.text}';
    await AuthService.instance.sendOtp(
      phoneE164: phone,
      onCodeSent: (verificationId, resendToken) {
        if (!mounted) return;
        setState(() => _submitting = false);
        context.push('/otp',
            extra: OtpArgs(
              phoneNumber: phone,
              verificationId: verificationId,
              resendToken: resendToken,
              redirectTo: widget.redirectTo,
            ));
      },
      onAutoVerified: () {
        // Android instant verification: already signed in, skip the OTP UI.
        if (!mounted) return;
        setState(() => _submitting = false);
        context.go(widget.redirectTo ?? '/home');
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _submitting = false);
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
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                const Text(
                  'Login or Sign up',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "We'll send a 6-digit code to verify your number.",
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(10),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Mobile number',
                    prefixText: '+91  ',
                    hintText: '98765 43210',
                  ),
                  validator: (value) {
                    if (value == null || value.length != 10) {
                      return 'Enter a 10-digit Indian mobile number';
                    }
                    if (!RegExp(r'^[6-9]').hasMatch(value)) {
                      return 'Indian mobile numbers start with 6, 7, 8 or 9';
                    }
                    return null;
                  },
                ),
                const Spacer(),
                PrimaryButton(
                  label: 'Continue',
                  loading: _submitting,
                  onPressed: _onContinue,
                ),
                const SizedBox(height: 12),
                const Text(
                  'By continuing, you agree to our Terms & Privacy Policy.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
