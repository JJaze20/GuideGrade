import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_tokens.dart';

/// The single source of truth for component styling. Anything a screen can get
/// "for free" from the theme (buttons, dialogs, snackbars, inputs, chips,
/// tooltips, dividers, progress) lives here so pages stop restyling it.
class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primaryGreen,
      primary: AppColors.primaryGreen,
      secondary: AppColors.darkNavy,
      error: AppColors.dangerFg,
      surface: AppColors.surface,
    );

    OutlineInputBorder inputBorder(Color color, double width) => OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: color, width: width),
        );

    final buttonShape = RoundedRectangleBorder(borderRadius: AppRadius.mdAll);
    const buttonText = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);

    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.lightBg,
      primaryColor: AppColors.primaryGreen,
      colorScheme: colorScheme,
      // Use default fonts for web to avoid loading issues
      textTheme: ThemeData.light().textTheme,
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.primaryGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: inputBorder(AppColors.borderStrong, 1.2),
        enabledBorder: inputBorder(AppColors.borderStrong, 1.2),
        focusedBorder: inputBorder(AppColors.primaryGreen, 2),
        errorBorder: inputBorder(AppColors.dangerFg, 1.6),
        focusedErrorBorder: inputBorder(AppColors.dangerFg, 2),
        disabledBorder: inputBorder(AppColors.border, 1.2),
        helperStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        errorStyle: const TextStyle(
          fontSize: 12,
          color: AppColors.dangerFg,
          fontWeight: FontWeight.w600,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryGreen,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, AppHit.minTarget),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, AppHit.minTarget),
          shape: buttonShape,
          side: const BorderSide(color: AppColors.borderStrong),
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: AppColors.textDark,
        ),
        contentTextStyle: const TextStyle(
          fontSize: 14,
          height: 1.45,
          color: AppColors.textDark,
        ),
      ),
      // Not floating on purpose: a floating SnackBar asserts when the Scaffold
      // is too short and hides under bottom navigation on phones.
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.slate900,
        contentTextStyle: const TextStyle(fontSize: 13.5, color: Colors.white),
        actionTextColor: AppColors.accentYellowGreen,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.neutralBg,
        selectedColor: AppColors.successBg,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.pillAll),
        labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: AppColors.slate800,
          borderRadius: AppRadius.smAll,
        ),
        textStyle: const TextStyle(fontSize: 12, color: Colors.white),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primaryGreen,
        circularTrackColor: AppColors.border,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.successBg,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? AppColors.primaryGreen
                : AppColors.textMuted,
          ),
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: AppColors.primaryGreen,
      ),
    );
  }
}
