import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';

/// Shared, clearly-outlined input decoration for forms where every field must
/// be findable at a glance: a visible border in EVERY state (resting, focused,
/// disabled and error), a white (or, disabled, tinted) fill, and a required
/// marker on the label.
///
/// Border colors are chosen for contrast on the app's light background: the
/// resting slate border is well above the 3:1 non-text contrast guideline
/// against white, focus adds a thicker primary-green border, and error uses a
/// thick red border so the state never depends on the helper text alone.
/// Every outline is 12px rounded; idle is 1.5px, focused and error are 2px.
class FormFieldStyle {
  const FormFieldStyle._();

  static const Color restingBorder = Color(0xFF64748B);
  static const Color disabledBorder = Color(0xFFB6BFCC);
  static const Color focusedBorder = AppColors.primaryGreen;
  static const Color errorBorder = Color(0xFFB91C1C);
  static const Color fill = Colors.white;
  static const Color disabledFill = Color(0xFFEEF1F5);

  static const double radius = 12;
  static const double restingWidth = 1.5;
  static const double focusedWidth = 2;
  static const double errorWidth = 2;

  static OutlineInputBorder _border(Color color, double width) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide(color: color, width: width),
      );
  /// The five outlines every field state uses (idle, focused, disabled, error,
  /// focused-error), so search fields, dropdowns and forms cannot drift apart.
  static InputDecoration _outlines(InputDecoration base) => base.copyWith(
        border: _border(restingBorder, restingWidth),
        enabledBorder: _border(restingBorder, restingWidth),
        focusedBorder: _border(focusedBorder, focusedWidth),
        disabledBorder: _border(disabledBorder, restingWidth),
        errorBorder: _border(errorBorder, errorWidth),
        focusedErrorBorder: _border(errorBorder, errorWidth),
        helperStyle: const TextStyle(fontSize: 11, color: AppColors.textGray),
        errorStyle: const TextStyle(fontSize: 11.5, color: errorBorder, fontWeight: FontWeight.w600),
      );

  /// Outline-only decoration for fields whose label is drawn outside the field
  /// (Create Batch), search bars and dropdowns: same borders, fill and error
  /// look as [decoration], without a floating label. A disabled field keeps a
  /// visible outline on a tinted fill.
  static InputDecoration outlined({
    String? hint,
    Widget? prefixIcon,
    Widget? suffixIcon,
    bool enabled = true,
    bool alignLabelWithHint = false,
    EdgeInsetsGeometry contentPadding = const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
  }) {
    return _outlines(InputDecoration(
      hintText: hint,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      errorMaxLines: 3,
      alignLabelWithHint: alignLabelWithHint,
      isDense: true,
      filled: true,
      fillColor: enabled ? fill : disabledFill,
      contentPadding: contentPadding,
    ));
  }

  /// [required] appends a red asterisk to the label. [helper] shows under the
  /// field while there is no error (validation messages replace it).
  static InputDecoration decoration({
    required String label,
    bool required = false,
    String? hint,
    String? helper,
    Widget? suffixIcon,
    String? counterText,
    Widget? prefixIcon,
  }) {
    return _outlines(InputDecoration(
      label: required
          ? Text.rich(
              TextSpan(
                text: label,
                children: const [
                  TextSpan(text: ' *', style: TextStyle(color: errorBorder, fontWeight: FontWeight.w800)),
                ],
              ),
            )
          : Text(label),
      hintText: hint,
      helperText: helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
      counterText: counterText,
      suffixIcon: suffixIcon,
      prefixIcon: prefixIcon,
      isDense: true,
      filled: true,
      fillColor: fill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    ));
  }

  /// The same decoration for a disabled/read-only field (tinted fill, lighter
  /// outline that is still visible).
  static InputDecoration disabled({required String label, String? helper, bool required = false}) =>
      decoration(label: label, helper: helper, required: required).copyWith(
        fillColor: disabledFill,
        border: _border(disabledBorder, restingWidth),
        enabledBorder: _border(disabledBorder, restingWidth),
      );
}
