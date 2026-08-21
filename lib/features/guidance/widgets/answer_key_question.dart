import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';

/// Reusable widget for displaying/editing a single question's answer.
class AnswerKeyQuestion extends StatelessWidget {
  final int questionNumber;
  final String? selectedAnswer;
  final List<String> allowedChoices;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  const AnswerKeyQuestion({
    super.key,
    required this.questionNumber,
    this.selectedAnswer,
    required this.allowedChoices,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          // Question number
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primaryGreen,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                '$questionNumber',
                style: AppTextStyles.body(
                  size: 12,
                  weight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Answer dropdown
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: selectedAnswer,
              decoration: InputDecoration(
                hintText: 'Select answer',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.cardBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.primaryGreen),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.cardBorder.withOpacity(0.5)),
                ),
                filled: !enabled,
                fillColor: !enabled ? AppColors.lightBg.withOpacity(0.5) : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              items: allowedChoices.map((choice) {
                return DropdownMenuItem(
                  value: choice,
                  child: Text(
                    choice,
                    style: AppTextStyles.body(size: 11),
                  ),
                );
              }).toList(),
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ],
      ),
    );
  }
}
