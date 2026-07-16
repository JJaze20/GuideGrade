import 'package:flutter/material.dart';

/// Central color palette for Guide Grade.
/// Mirrors the Tailwind color tokens defined in the HTML prototype
/// (primaryGreen, accentYellowGreen, warmRedOrange, darkNavy, etc.)
class AppColors {
  AppColors._();

  static const Color primaryGreen = Color(0xFF2E7D32);
  static const Color accentYellowGreen = Color(0xFF8BC34A);
  static const Color warmRedOrange = Color(0xFFE53935);
  static const Color darkNavy = Color(0xFF1A237E);
  static const Color lightBg = Color(0xFFF5F5F5);
  static const Color textDark = Color(0xFF212121);
  static const Color textGray = Color(0xFF757575);
  static const Color fileCardGray = Color(0xFFEEEEEE);

  // Category colors (used for exam result bands)
  static const Color catD = Color(0xFF1565C0);
  static const Color catC = Color(0xFF2E7D32);
  static const Color catB = Color(0xFFF9A825);
  static const Color catA = Color(0xFFE53935);
  static const Color catCutoff = Color(0xFF757575);

  // Extra neutrals used across cards / borders
  static const Color cardBorder = Color(0xFFF1F1F4);
  static const Color amber100 = Color(0xFFFFECB3);
  static const Color amber800 = Color(0xFF8D6E00);
  static const Color amber50 = Color(0xFFFFF8E1);
  static const Color emerald100 = Color(0xFFD1FAE5);
  static const Color emerald600 = Color(0xFF059669);
  static const Color slate900 = Color(0xFF0F172A);
  static const Color slate950 = Color(0xFF020617);
  static const Color slate800 = Color(0xFF1E293B);
}
