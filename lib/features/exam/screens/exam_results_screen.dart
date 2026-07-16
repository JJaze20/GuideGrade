import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/primary_button.dart';

/// Exam Results — mirrors SCREENS.AT_RESULTS.
/// Renders a numeric score table for Admission-type exams (AT/TAT/QTM)
/// or a 16-factor style personality profile list when the active exam
/// code is 'PT', matching the branch in the prototype's `setScreen`.
class ExamResultsScreen extends StatelessWidget {
  const ExamResultsScreen({super.key});

  static const List<Map<String, dynamic>> _admissionResults = [
    {'name': 'ANDULANA, ROBERT P.', 'raw': 45, 'max': 50, 'pct': 90, 'cat': 'Category D', 'color': AppColors.catD},
    {'name': 'DELA CRUZ, JUAN S.', 'raw': 39, 'max': 50, 'pct': 78, 'cat': 'Category C', 'color': AppColors.catC},
    {'name': 'ALVAREZ, MARIA FE G.', 'raw': 32, 'max': 50, 'pct': 64, 'cat': 'Category B', 'color': AppColors.catB},
  ];

  static const List<Map<String, String>> _primaryFactors = [
    {'code': 'A', 'name': 'Warmth', 'left': 'Reserved, Impersonal', 'right': 'Warm, Outgoing'},
    {'code': 'B', 'name': 'Reasoning', 'left': 'Concrete', 'right': 'Abstract'},
    {'code': 'C', 'name': 'Emotional Stability', 'left': 'Reactive, Changeable', 'right': 'Stable, Mature'},
    {'code': 'E', 'name': 'Dominance', 'left': 'Deferential, Cooperative', 'right': 'Dominant, Forceful'},
    {'code': 'F', 'name': 'Liveliness', 'left': 'Serious, Restrained', 'right': 'Lively, Animated'},
    {'code': 'G', 'name': 'Rule-Consciousness', 'left': 'Expedient, Nonconforming', 'right': 'Conscious, Dutiful'},
    {'code': 'H', 'name': 'Social Boldness', 'left': 'Shy, Timid', 'right': 'Bold, Venturesome'},
    {'code': 'I', 'name': 'Sensitivity', 'left': 'Utilitarian, Objective', 'right': 'Sensitive, Aesthetic'},
  ];

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final isPersonality = appState.activeExamCode == 'PT';

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text(
          isPersonality ? 'Personality Profile' : 'Exam Results',
          style: AppTextStyles.heading(size: 13),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: isPersonality ? _buildPersonalityView(context) : _buildAdmissionView(context),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: PrimaryButton(
                label: 'RETURN HOME',
                color: AppColors.darkNavy,
                onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (r) => false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdmissionView(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Row(
            children: [
              const FaIcon(FontAwesomeIcons.chartSimple, color: AppColors.primaryGreen, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Batch Score Summary', style: AppTextStyles.heading(size: 13)),
                    Text(
                      '${_admissionResults.length} examinees processed',
                      style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ..._admissionResults.map((r) {
          final color = r['color'] as Color;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: color.withOpacity(0.12), shape: BoxShape.circle),
                  child: Text(
                    '${r['pct']}%',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r['name'] as String, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        'Raw Score: ${r['raw']}/${r['max']}',
                        style: AppTextStyles.body(size: 9.5, color: AppColors.textGray),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    r['cat'] as String,
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildPersonalityView(BuildContext context) {
    final sampleName = _admissionResults.first['name'] as String;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Row(
            children: [
              const FaIcon(FontAwesomeIcons.brain, color: Color(0xFF2563EB), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sampleName, style: AppTextStyles.heading(size: 13)),
                    Text('16-Factor primary trait breakdown', style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ..._primaryFactors.map((f) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: Color(0xFFEFF6FF), shape: BoxShape.circle),
                        child: Text(
                          f['code']!,
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF2563EB)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(f['name']!, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(f['left']!, style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
                      ),
                      Expanded(
                        child: Text(
                          f['right']!,
                          textAlign: TextAlign.right,
                          style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: 0.5,
                      minHeight: 6,
                      backgroundColor: const Color(0xFFE2E8F0),
                      valueColor: const AlwaysStoppedAnimation(Color(0xFF2563EB)),
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}
