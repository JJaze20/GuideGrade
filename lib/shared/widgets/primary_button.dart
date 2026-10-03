import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_tokens.dart';

const TextStyle _buttonLabel = TextStyle(fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 0.3);

/// Reusable full-width primary action button matching the prototype's
/// bold CTA buttons (e.g. LOGIN, Launch OMR Scanner Loop). Set [loading] while
/// the action runs: the button disables itself (so it cannot be double
/// submitted) and shows a progress indicator in place of the icon.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final FaIconData? icon;
  final Color color;
  final Color textColor;
  final bool loading;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = AppColors.primaryGreen,
    this.textColor = Colors.white,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          disabledBackgroundColor: loading ? color.withValues(alpha: 0.7) : null,
          disabledForegroundColor: loading ? textColor : null,
          minimumSize: const Size(64, AppHit.minTarget),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          elevation: 1,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading) ...[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: textColor),
              ),
              const SizedBox(width: 8),
            ] else if (icon != null) ...[
              FaIcon(icon!, size: 15),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(label, style: _buttonLabel, textAlign: TextAlign.center)),
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
          side: const BorderSide(color: AppColors.borderStrong),
          minimumSize: const Size(64, AppHit.minTarget),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              FaIcon(icon!, size: 15),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(label, style: _buttonLabel, textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
  }
}
