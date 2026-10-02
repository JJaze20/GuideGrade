import 'package:flutter/material.dart';

import '../../core/constants/app_text_styles.dart';

const Color _amberBg = Color(0xFFFEF3C7);
const Color _amberFg = Color(0xFF92400E);

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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: _amberBg, borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 13, color: _amberFg),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.body(size: 9.5, weight: FontWeight.w700, color: _amberFg)),
        ],
      ),
    );
  }
}

/// Batch-level explanation: how many sheets need a look and which ones.
/// [sheetLabels] are the display names of the affected sheets, in batch
/// order. A sheet lands here either because it holds scanner-flagged answers
/// nobody has reviewed, or because it was accepted only after the mesh
/// straightened a bent photo (see `LocalScan.needsReview`) — so the wording
/// names both, not just double marks.
class NeedsReviewBanner extends StatelessWidget {
  final List<String> sheetLabels;
  const NeedsReviewBanner({super.key, required this.sheetLabels});

  @override
  Widget build(BuildContext context) {
    final n = sheetLabels.length;
    return Container(
      key: const ValueKey('needs-review-banner'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _amberBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFCD34D)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: _amberFg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$n sheet${n == 1 ? '' : 's'} need${n == 1 ? 's' : ''} review — the scanner either could not '
              'read some answers clearly (double or unclear marks), or accepted the sheet only after '
              'straightening a bent photo: ${sheetLabels.join(', ')}. '
              'Open each sheet and confirm the answers.',
              style: AppTextStyles.body(size: 9.5, weight: FontWeight.w600, color: _amberFg),
            ),
          ),
        ],
      ),
    );
  }
}
