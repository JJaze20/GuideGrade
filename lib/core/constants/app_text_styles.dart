import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// Typography tokens matching the prototype's font stack:
/// - Poppins  -> default body/sans font
/// - Nunito   -> headings (font-heading, bold/extra-bold)
/// - Pacifico -> logo wordmark ("Guide" / "Grade")
class AppTextStyles {
  AppTextStyles._();

  static TextStyle body({
    double size = 13,
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.textDark,
  }) =>
      GoogleFonts.poppins(fontSize: size, fontWeight: weight, color: color);

  static TextStyle heading({
    double size = 16,
    FontWeight weight = FontWeight.w800,
    Color color = AppColors.darkNavy,
  }) =>
      GoogleFonts.nunito(fontSize: size, fontWeight: weight, color: color);

  // -----------------------------------------------------------------
  // Type scale for new / refactored UI. Body copy never goes below 12;
  // captions and table headers never below 11.5 (the older screens still
  // use 9-11 and are being migrated gradually).
  // -----------------------------------------------------------------

  /// Page / screen title.
  static TextStyle title({Color color = AppColors.darkNavy}) =>
      heading(size: 20, weight: FontWeight.w800, color: color);

  /// Section / card heading.
  static TextStyle subtitle({Color color = AppColors.textDark}) =>
      body(size: 14, weight: FontWeight.w700, color: color);

  /// Default readable body text.
  static TextStyle text({
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.textDark,
  }) =>
      body(size: 13, weight: weight, color: color);

  /// Secondary / helper text.
  static TextStyle caption({
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.textMuted,
  }) =>
      body(size: 12, weight: weight, color: color);

  /// Small uppercase-style labels (table headers, badges).
  static TextStyle label({Color color = AppColors.textMuted}) =>
      body(size: 11.5, weight: FontWeight.w700, color: color)
          .copyWith(letterSpacing: 0.4);

  static TextStyle logo({
    double size = 26,
    Color color = AppColors.warmRedOrange,
  }) =>
      GoogleFonts.pacifico(fontSize: size, color: color);
}
