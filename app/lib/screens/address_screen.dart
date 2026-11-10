import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

class AddressScreen extends StatefulWidget {
  const AddressScreen({super.key});

  @override
  State<AddressScreen> createState() => _AddressScreenState();
}

class _AddressScreenState extends State<AddressScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _line1 = TextEditingController();
  final _line2 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pincode = TextEditingController();

  Timer? _debounce;
  bool _pincodeLoading = false;
  bool _pincodeOk = false;

  @override
  void initState() {
    super.initState();
    _pincode.addListener(_onPincodeChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pincode.removeListener(_onPincodeChanged);
    for (final c in [_name, _phone, _line1, _line2, _city, _state, _pincode]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onPincodeChanged() {
    final value = _pincode.text;
    setState(() => _pincodeOk = false);
    if (value.length != 6) {
      _city.clear();
      _state.clear();
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _lookupPincode(value);
    });
  }

  Future<void> _lookupPincode(String pin) async {
    setState(() => _pincodeLoading = true);
    // worldpostallocations.com — valid HTTPS, covers all Indian pincodes.
    // (The earlier `api.postalpincode.in` endpoint went down with an
    // expired/mismatched SSL cert.)
    final url = Uri.parse(
        'https://api.worldpostallocations.com/pincode?postalcode=$pin&countrycode=IN');
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final result = body['result'] as List?;
      // The lookup is only a convenience to auto-fill city/state. On ANY
      // failure (unknown pincode, API down, no city/state) we stay silent —
      // never a red error — and leave the fields for the customer or the shop
      // to fill from the pincode. A 6-digit pincode is all that's required.
      if (body['status'] != true || result == null || result.isEmpty) {
        setState(() => _pincodeLoading = false);
        return;
      }
      final office = result.first as Map<String, dynamic>;
      final district = (office['district'] ?? office['province'] ?? '').toString();
      final state = (office['state'] ?? '').toString();
      if (district.isNotEmpty) _city.text = district;
      if (state.isNotEmpty) _state.text = state;
      setState(() {
        _pincodeLoading = false;
        _pincodeOk = district.isNotEmpty && state.isNotEmpty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _pincodeLoading = false);
    }
  }

  void _onContinue() {
    // Only name, mobile, address lines and a 6-digit pincode are required.
    // City/State are a convenience (auto-filled from the pincode); if the
    // lookup can't reach them the shop fills them from the pincode, so they
    // never block the order.
    if (!_formKey.currentState!.validate()) return;
    context.read<Cart>().setCustomer(
          name: _name.text.trim(),
          phone: _phone.text.trim(),
          line1: _line1.text.trim(),
          line2: _line2.text.trim(),
          city: _city.text.trim(),
          state: _state.text.trim(),
          pincode: _pincode.text.trim(),
        );
    context.push('/checkout');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DELIVERY ADDRESS'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/cart'),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _Field(
                controller: _name,
                label: 'Full name',
                textCapitalization: TextCapitalization.words,
                validator: (v) => (v == null || v.trim().length < 2)
                    ? 'Enter your full name'
                    : null,
              ),
              _Field(
                controller: _phone,
                label: 'Mobile number',
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
                prefix: const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Text('+91 ',
                      style: TextStyle(
                          fontSize: 14, color: AppColors.textSecondary)),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Mobile number required';
                  if (v.length != 10) return 'Enter 10 digits';
                  if (!RegExp(r'^[6-9]').hasMatch(v)) {
                    return 'Must start with 6, 7, 8 or 9';
                  }
                  return null;
                },
              ),
              _Field(
                controller: _line1,
                label: 'House / Flat / Building',
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              _Field(
                controller: _line2,
                label: 'Area / Street / Landmark',
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              _Field(
                controller: _pincode,
                label: 'Pincode',
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                suffix: _pincodeLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      )
                    : (_pincodeOk
                        ? const Icon(Icons.check_circle,
                            color: AppColors.success, size: 20)
                        : null),
                // The pincode NEVER shows a red lookup error. City/State are
                // auto-filled when the lookup succeeds and stay optional
                // otherwise — the shop fills them from the pincode. The only
                // check is that the pincode is 6 digits, and only on Continue.
                validator: (v) {
                  if (v == null || v.length != 6) return '6-digit pincode';
                  return null;
                },
              ),
              // Fields lock when no pincode error (initial / loading / lookup
              // succeeded), unlock when the lookup failed so the user has a
              // way forward.
              Builder(builder: (_) {
                // City/State stay EDITABLE after a successful lookup so a wrong
                // auto-filled district can be corrected; locked only while the
                // lookup is in flight.
                final hint = _pincodeLoading
                    ? 'Looking up…'
                    : 'Optional — from pincode';
                return Row(
                  children: [
                    Expanded(
                      child: _Field(
                        controller: _city,
                        label: 'City (optional)',
                        readOnly: _pincodeLoading,
                        enabled: !_pincodeLoading,
                        textCapitalization: TextCapitalization.words,
                        hintText: hint,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Field(
                        controller: _state,
                        label: 'State (optional)',
                        readOnly: _pincodeLoading,
                        enabled: !_pincodeLoading,
                        textCapitalization: TextCapitalization.words,
                        hintText: hint,
                      ),
                    ),
                  ],
                );
              }),
              const SizedBox(height: 24),
              PrimaryButton(
                label: 'Continue to payment →',
                onPressed: _onContinue,
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  'We deliver across India in 3-5 days.',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.validator,
    this.keyboardType,
    this.inputFormatters,
    this.readOnly = false,
    this.enabled = true,
    this.hintText,
    this.suffix,
    this.prefix,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool readOnly;
  final bool enabled;
  final String? hintText;
  final Widget? suffix;
  final Widget? prefix;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        validator: validator,
        readOnly: readOnly,
        enabled: enabled,
        textCapitalization: textCapitalization,
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText,
          suffixIcon: suffix == null
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: suffix,
                ),
          prefixIcon: prefix == null
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
                  child: prefix,
                ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
        ),
      ),
    );
  }
}
