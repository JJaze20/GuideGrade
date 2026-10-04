import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/constants/app_tokens.dart';

/// Short "Needs review" pill with a warning icon. [count] adds the number of
/// affected sheets ("Needs review · 3"); omit it for a per-sheet marker.
class NeedsReviewChip extends StatelessWidget {
  final int? count;
  const NeedsReviewChip({super.key, this.count});

  @override
  Widget build(BuildContext context) {
    final label = count == null ? 'Needs review' : 'Needs review · $count';
    return Container(
      key: const ValueKey('needs-review-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: AppRadius.pillAll,
        border: Border.all(color: AppColors.warningBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.warningFg),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.label(color: AppColors.warningFg).copyWith(letterSpacing: 0.2)),
        ],
      ),
    );
  }
}

/// Batch-level explanation: how many sheets hold scanner-flagged answers that
/// nobody has reviewed yet, and which ones. [sheetLabels] are the display
/// names of the affected sheets, in batch order.
class NeedsReviewBanner extends StatelessWidget {
  final List<String> sheetLabels;
  const NeedsReviewBanner({super.key, required this.sheetLabels});

  @override
  Widget build(BuildContext context) {
    final n = sheetLabels.length;
    return Container(
      key: const ValueKey('needs-review-banner'),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: AppColors.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warningFg),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              '$n sheet${n == 1 ? '' : 's'} need${n == 1 ? 's' : ''} review — the scanner could not '
              'read some answers clearly (double or unclear marks): ${sheetLabels.join(', ')}. '
              'Open each sheet and confirm those answers.',
              style: AppTextStyles.body(size: 12, weight: FontWeight.w600, color: AppColors.warningFg),
            ),
          ),
        ],
      ),
    );
  }
}
