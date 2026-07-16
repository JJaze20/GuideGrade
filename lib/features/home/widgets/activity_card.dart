import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/activity_model.dart';

/// A single row in the "Diagnostic Batches & Results Registry" list on
/// the Staff Home screen. Tapping a 'Pending' batch routes to Exam Setup;
/// tapping a 'Done' batch routes to Exam Results (handled by the caller).
class ActivityCard extends StatelessWidget {
  final ActivityModel activity;
  final VoidCallback onTap;

  const ActivityCard({super.key, required this.activity, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDone = activity.isDone;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isDone ? Colors.white : const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isDone ? AppColors.cardBorder : const Color(0xFFFCD34D)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activity.type.toUpperCase(),
                    style: AppTextStyles.body(
                      size: 8.5,
                      weight: FontWeight.w800,
                      color: AppColors.primaryGreen,
                    ).copyWith(letterSpacing: 0.6),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(activity.batch, style: AppTextStyles.body(size: 12.5, weight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      if (isDone)
                        const FaIcon(FontAwesomeIcons.circleCheck, size: 12, color: AppColors.primaryGreen)
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'UN-TESTED',
                            style: TextStyle(fontSize: 8, color: Color(0xFF92400E), fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const FaIcon(FontAwesomeIcons.solidCalendar, size: 9, color: AppColors.textGray),
                      const SizedBox(width: 4),
                      Text(
                        isDone ? 'Results Out' : 'Assigned • Calibration pending',
                        style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const FaIcon(FontAwesomeIcons.chevronRight, size: 12, color: Color(0xFFCBD5E1)),
          ],
        ),
      ),
    );
  }
}
