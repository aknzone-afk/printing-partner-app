import 'package:flutter/material.dart';

/// Brand palette.
///
/// Contrast rules (WCAG AA, 4.5:1 for body text) against our light surfaces
/// (white, [background], [lavender], [peach], [blush]):
///  * [primary] is a FILL colour (buttons, gradients, chips). It is only
///    4.0:1 on white, so it is never used for text below ~24 px — small
///    purple text uses [primaryDark] (5.1:1 on lavender, 6.0:1 on white).
///  * [accent], [success] and [error] are used as TEXT and icons on light
///    cards, so they are the darker shades of their hues: accent 4.9:1 on
///    lavender, success 4.6:1 on lavender, error 4.8:1 on lavender; all are
///    >= 5.4:1 on white. The soft 10–15 % tints of them stay readable.
class AppColors {
  // Snapstore-inspired palette: purple primary, coral accent, soft pastels
  static const primary = Color(0xFF7B6CF0); // signature purple (fills only)
  static const primaryDark = Color(0xFF5A4ED8); // purple for text / small UI
  static const accent = Color(0xFFBE3036); // deep coral — readable as text
  static const lavender = Color(0xFFEFEAFF); // soft purple bg for cards
  static const blush = Color(0xFFFFE5E5); // soft pink
  static const peach = Color(0xFFFFEFE0); // soft peach
  static const background = Color(0xFFF8F7FB);
  static const surface = Colors.white;
  static const textPrimary = Color(0xFF1A1F36);
  static const textSecondary = Color(0xFF5B6370); // 6.1:1 white, 5.1:1 blush
  static const success = Color(0xFF0F7A3A); // 5.4:1 on white, 4.6:1 lavender
  static const error = Color(0xFFC62828); // 5.6:1 on white, 4.8:1 lavender
  static const border = Color(0xFFE5E7EB);
  static const polaroidBorder = Colors.white; // white polaroid frame
}

ThemeData buildAppTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.error,
    ),
    scaffoldBackgroundColor: AppColors.background,
    // Standard density everywhere (the adaptive default shrinks IconButtons
    // to 40 dp on web/desktop); padded tap targets keep every tappable at
    // >= 48 dp even when its visual is smaller.
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    // Body/display text defaults to the dark ink, not M3's grey-ish onSurface
    // variant, so unstyled small text always clears 4.5:1 on our pastels.
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    iconTheme: const IconThemeData(color: AppColors.textPrimary),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        minimumSize: const Size(double.infinity, 52),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primaryDark,
        minimumSize: const Size(48, 48),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primaryDark,
        minimumSize: const Size(48, 48),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
  );
}
