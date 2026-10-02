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

  static TextStyle logo({
    double size = 26,
    Color color = AppColors.warmRedOrange,
  }) =>
      GoogleFonts.pacifico(fontSize: size, color: color);
}
