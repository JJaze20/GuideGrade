import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../core/constants/app_colors.dart';

/// Reusable pill-shaped primary action button matching the prototype's
/// bold, uppercase-ish CTA buttons (e.g. LOGIN, Launch OMR Scanner Loop).
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final FaIconData? icon;
  final Color color;
  final Color textColor;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = AppColors.primaryGreen,
    this.textColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 1,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              FaIcon(icon!, size: 15),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, letterSpacing: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Secondary / outline style button (e.g. CANCEL, Dismiss).
class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final FaIconData? icon;
  final Color foregroundColor;

  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.foregroundColor = AppColors.textGray,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: foregroundColor,
          side: const BorderSide(color: Color(0xFFCBD5E1)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              FaIcon(icon!, size: 15),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, letterSpacing: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}
