import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/constants/app_tokens.dart';

/// Semantic meaning of a [StatusBadge]. Pick the tone by what the status MEANS
/// (needs attention, done, failed...), never by which colour you want.
enum StatusTone { success, warning, danger, info, neutral }

/// Foreground / background / border for a [StatusTone], from the shared
/// semantic palette so every badge in the product matches.
class StatusPalette {
  const StatusPalette(this.fg, this.bg, this.border);

  final Color fg;
  final Color bg;
  final Color border;

  static StatusPalette of(StatusTone tone) => switch (tone) {
        StatusTone.success => const StatusPalette(
            AppColors.successFg, AppColors.successBg, AppColors.successBorder),
        StatusTone.warning => const StatusPalette(
            AppColors.warningFg, AppColors.warningBg, AppColors.warningBorder),
        StatusTone.danger => const StatusPalette(
            AppColors.dangerFg, AppColors.dangerBg, AppColors.dangerBorder),
        StatusTone.info => const StatusPalette(
            AppColors.infoFg, AppColors.infoBg, AppColors.infoBorder),
        StatusTone.neutral => const StatusPalette(
            AppColors.neutralFg, AppColors.neutralBg, AppColors.neutralBorder),
      };
}

/// A compact pill that states a status in words (never colour alone), with an
/// optional leading icon. The label is rendered verbatim, so callers keep
/// control of casing.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.tone = StatusTone.neutral,
    this.icon,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = StatusPalette.of(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: AppRadius.pillAll,
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: palette.fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.label(color: palette.fg).copyWith(letterSpacing: 0.2),
            ),
          ),
        ],
      ),
    );
  }
}

/// The batch lifecycle status (Draft / Active / Completed / Archived) as a
/// badge. One mapping for every screen that shows a batch.
class BatchStatusBadge extends StatelessWidget {
  const BatchStatusBadge({super.key, required this.status});

  final String status;

  static StatusTone toneFor(String status) => switch (status) {
        'Draft' => StatusTone.warning,
        'Active' => StatusTone.info,
        'Completed' => StatusTone.success,
        _ => StatusTone.neutral,
      };

  @override
  Widget build(BuildContext context) => StatusBadge(label: status, tone: toneFor(status));
}
