import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/examinee.dart';

/// Reusable widget for displaying a single examinee in the list.
class ExamineeListItem extends StatelessWidget {
  final ExamineeModel examinee;
  final VoidCallback onTap;

  const ExamineeListItem({
    super.key,
    required this.examinee,
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
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        examinee.fullName,
                        style: AppTextStyles.body(
                          size: 12,
                          weight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        examinee.studentNumber,
                        style: AppTextStyles.body(
                          size: 10,
                          color: AppColors.textGray,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _buildSexChip(),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildInfoChip(examinee.course),
                const SizedBox(width: 8),
                if (examinee.yearLevel.isNotEmpty)
                  _buildInfoChip(examinee.yearLevel),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSexChip() {
    Color backgroundColor;
    Color textColor;
    String label;

    if (examinee.isMale) {
      backgroundColor = const Color(0xFFDBEAFE);
      textColor = const Color(0xFF1E40AF);
      label = 'M';
    } else {
      backgroundColor = const Color(0xFFFCE7F3);
      textColor = const Color(0xFF9D174D);
      label = 'F';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: AppTextStyles.body(
          size: 10,
          weight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
  }

  Widget _buildInfoChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.lightBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: AppTextStyles.body(
          size: 9.5,
          color: AppColors.textGray,
        ),
      ),
    );
  }
}
