import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/needs_review_badge.dart';

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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.cardBorder),
        ),
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
                        style: AppTextStyles.body(size: 12.5, weight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        batch.batchCode,
                        style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildStatusChip(),
                const SizedBox(width: 2),
                IconButton(
                  onPressed: onDelete,
                  icon: const FaIcon(FontAwesomeIcons.trashCan, size: 14, color: Color(0xFF991B1B)),
                  tooltip: 'Delete batch',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _buildInfoChip('${batch.examTitle} (${batch.examCode})'),
                _buildInfoChip(
                  '${batch.scanCount}/${batch.expectedCount} sheets',
                  emphasized: batch.isFull,
                ),
                if (batch.isFull) _buildInfoChip('FULL', emphasized: true),
                if (batch.resultsAvailable) _buildInfoChip('Results ✓'),
                if (batch.needsReview) NeedsReviewChip(count: batch.needsReviewCount),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    Color backgroundColor;
    Color textColor;
    String label;

    switch (batch.status) {
      case 'Draft':
        backgroundColor = const Color(0xFFFEF3C7);
        textColor = const Color(0xFF92400E);
        label = 'Draft';
        break;
      case 'Active':
        backgroundColor = const Color(0xFFDBEAFE);
        textColor = const Color(0xFF1E40AF);
        label = 'Active';
        break;
      case 'Completed':
        backgroundColor = const Color(0xFFD1FAE5);
        textColor = const Color(0xFF065F46);
        label = 'Completed';
        break;
      case 'Archived':
        backgroundColor = const Color(0xFFF3F4F6);
        textColor = const Color(0xFF374151);
        label = 'Archived';
        break;
      default:
        backgroundColor = const Color(0xFFF3F4F6);
        textColor = const Color(0xFF374151);
        label = batch.status;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: AppTextStyles.body(size: 9.5, weight: FontWeight.w600, color: textColor),
      ),
    );
  }

  Widget _buildInfoChip(String label, {bool emphasized = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: emphasized ? const Color(0xFFFEE2E2) : AppColors.lightBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: AppTextStyles.body(
          size: 9.5,
          weight: emphasized ? FontWeight.w700 : FontWeight.w400,
          color: emphasized ? const Color(0xFF991B1B) : AppColors.textGray,
        ),
      ),
    );
  }
}
