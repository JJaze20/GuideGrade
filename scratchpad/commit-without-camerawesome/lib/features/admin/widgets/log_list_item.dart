import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/log_entry.dart';

/// Reusable widget for displaying a single log entry in the System Logs
/// list. Read-only by construction -- there is no edit/delete affordance
/// anywhere on this widget or its tap target (which only opens a read-only
/// detail dialog).
class LogListItem extends StatelessWidget {
  final LogEntry log;
  final VoidCallback onTap;

  const LogListItem({
    super.key,
    required this.log,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: log.severity == LogSeverity.warning ? const Color(0xFFFCD34D) : AppColors.cardBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    log.description,
                    style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                _buildSeverityChip(),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildCategoryChip(),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _formatTimestamp(log.timestamp),
                    style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              log.actorEmail,
              style: AppTextStyles.body(size: 9, color: AppColors.textGray),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.lightBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        log.category,
        style: AppTextStyles.body(size: 8.5, weight: FontWeight.w700, color: AppColors.textGray),
      ),
    );
  }

  Widget _buildSeverityChip() {
    final isWarning = log.severity == LogSeverity.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isWarning ? const Color(0xFFFEF3C7) : AppColors.emerald100,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        log.severity,
        style: AppTextStyles.body(
          size: 9,
          weight: FontWeight.w700,
          color: isWarning ? const Color(0xFF92400E) : const Color(0xFF065F46),
        ),
      ),
    );
  }

  static String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return 'Just now';
    final local = timestamp.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}
