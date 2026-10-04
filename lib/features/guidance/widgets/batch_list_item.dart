import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/needs_review_badge.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/surface_card.dart';

/// Reusable widget for displaying a single local batch in the list.
class BatchListItem extends StatelessWidget {
  final LocalBatch batch;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const BatchListItem({
    super.key,
    required this.batch,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      batch.description.isNotEmpty ? batch.description : 'Batch ${batch.batchCode}',
                      style: AppTextStyles.subtitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(batch.batchCode, style: AppTextStyles.caption()),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              BatchStatusBadge(status: batch.status),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.dangerFg),
                tooltip: 'Delete batch',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              StatusBadge(label: '${batch.examTitle} (${batch.examCode})'),
              StatusBadge(
                label: '${batch.scanCount}/${batch.expectedCount} sheets',
                tone: batch.isFull ? StatusTone.info : StatusTone.neutral,
              ),
              if (batch.isFull) const StatusBadge(label: 'FULL', tone: StatusTone.info),
              if (batch.resultsAvailable) const StatusBadge(label: 'Results ✓', tone: StatusTone.success),
              if (batch.needsReview) NeedsReviewChip(count: batch.needsReviewCount),
            ],
          ),
        ],
      ),
    );
  }
}
