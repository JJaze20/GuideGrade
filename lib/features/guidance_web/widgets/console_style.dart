import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Green visual language of the Guidance Council Web Console (the University's
/// green). Only the web console uses these; the mobile app and the System
/// Administrator console keep their own look.
class ConsoleColors {
  ConsoleColors._();

  /// Top bar.
  static const Color headerGreen = Color(0xFF083D2E);

  /// Sidebar rail.
  static const Color railGreen = Color(0xFF0A4A37);
  static const Color railGreenDeep = Color(0xFF07382A);

  /// Selected / hovered sidebar item.
  static const Color railSelected = Color(0xFF0F6149);

  /// Hero banner gradient.
  static const Color bannerStart = Color(0xFF0A4F38);
  static const Color bannerEnd = Color(0xFF0F7A4F);

  /// Active-page marker and small highlights.
  static const Color gold = Color(0xFFF2C14E);
  static const Color mint = Color(0xFF99E2B0);

  /// Page background gradient (soft cream-green).
  static const Color pageTop = Color(0xFFF3F6F2);
  static const Color pageEdge = Color(0xFFF8F4E8);

  /// Text.
  static const Color eyebrow = Color(0xFF0B6B45);
  static const Color ink = Color(0xFF10261C);
  static const Color muted = Color(0xFF5B6B63);
  static const Color onGreen = Colors.white;
  static const Color onGreenMuted = Color(0xFFCDE5D8);
}

/// Console typography: a serif for page titles, with the app's usual sans
/// serif (Poppins) for everything else.
class ConsoleText {
  ConsoleText._();

  /// Large page / banner title.
  static TextStyle serifTitle({
    double size = 38,
    Color color = ConsoleColors.ink,
  }) => GoogleFonts.sourceSerif4(
    fontSize: size,
    fontWeight: FontWeight.w500,
    color: color,
    height: 1.12,
  );

  /// Small spaced-out green label above a title, e.g. "GUIDANCE WORKSPACE".
  static TextStyle eyebrow({Color color = ConsoleColors.eyebrow}) =>
      GoogleFonts.poppins(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 2.0,
        color: color,
      );

  static TextStyle body({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color color = ConsoleColors.ink,
  }) => GoogleFonts.poppins(fontSize: size, fontWeight: weight, color: color);
}

/// The soft cream-green background used behind every console page.
const BoxDecoration consolePageBackground = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ConsoleColors.pageTop, ConsoleColors.pageEdge],
  ),
);
