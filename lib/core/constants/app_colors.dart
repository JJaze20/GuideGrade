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

  // ---------------------------------------------------------------------
  // Semantic palette. Use these (via StatusBadge / StateView / theme) instead
  // of re-typing amber/red/green hex values per screen. Every foreground is
  // at least WCAG AA (4.5:1) against its own background and against white.
  // ---------------------------------------------------------------------

  // Success
  static const Color successFg = Color(0xFF065F46);
  static const Color successBg = Color(0xFFD1FAE5);
  static const Color successBorder = Color(0xFF6EE7B7);

  // Warning / needs attention
  static const Color warningFg = Color(0xFF92400E);
  static const Color warningBg = Color(0xFFFEF3C7);
  static const Color warningBorder = Color(0xFFFCD34D);

  // Danger / destructive / error (text-safe red; brand [warmRedOrange] stays
  // for large accents only -- it is only ~4:1 on white)
  static const Color dangerFg = Color(0xFFB91C1C);
  static const Color dangerBg = Color(0xFFFEE2E2);
  static const Color dangerBorder = Color(0xFFFCA5A5);

  // Informational
  static const Color infoFg = Color(0xFF1E40AF);
  static const Color infoBg = Color(0xFFDBEAFE);
  static const Color infoBorder = Color(0xFF93C5FD);

  // Neutral
  static const Color neutralFg = Color(0xFF475569);
  static const Color neutralBg = Color(0xFFF1F5F9);
  static const Color neutralBorder = Color(0xFFCBD5E1);

  // Surfaces and lines shared by cards, tables, inputs and dividers.
  static const Color surface = Colors.white;
  static const Color border = Color(0xFFE2E8F0);
  static const Color borderStrong = Color(0xFFCBD5E1);

  /// Secondary text that still meets AA on white (the older [textGray] is
  /// ~4.6:1 and is kept as-is for existing screens).
  static const Color textMuted = Color(0xFF64748B);
}
