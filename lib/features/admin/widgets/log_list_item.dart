import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../models/log_entry.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/surface_card.dart';

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
    final isWarning = log.severity == LogSeverity.warning;
    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadius.lgAll,
        // A warning gets a visible amber outline in addition to its badge.
        border: isWarning ? Border.all(color: AppColors.warningBorder, width: 1.5) : null,
      ),
      child: SurfaceCard(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    log.description,
                    style: AppTextStyles.subtitle(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                StatusBadge(
                  label: log.severity,
                  tone: isWarning ? StatusTone.warning : StatusTone.success,
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusBadge(label: log.category, tone: StatusTone.neutral),
                Text(_formatTimestamp(log.timestamp), style: AppTextStyles.caption()),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              log.actorEmail,
              style: AppTextStyles.caption(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
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
