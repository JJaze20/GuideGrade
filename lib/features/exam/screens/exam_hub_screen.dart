import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/app_bottom_nav.dart';
import '../../../shared/widgets/app_header_bar.dart';
import '../widgets/exam_category_card.dart';

/// Exam Hub — mirrors SCREENS.EXAM_HUB. Lets the user pick an
/// assessment framework blueprint, then proceeds to Exam Setup.
class ExamHubScreen extends StatelessWidget {
  const ExamHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);

    void selectAndGo(String code) {
      appState.setActiveExamCode(code);
      Navigator.of(context).pushNamed(AppRoutes.examSetup);
    }

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: const AppHeaderBar(title: 'EXAMS'),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('Start scanning', style: AppTextStyles.heading(size: 28)),
                const SizedBox(height: 8),
                Text(
                  'Choose the exam printed on your answer sheets.',
                  style: AppTextStyles.body(size: 15, color: AppColors.textGray),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF4EC),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '1. Choose an exam\n'
                    '2. Select a batch\n'
                    '3. Add/Verify Answer Key\n'
                    '4. Scan sheets',
                    style: AppTextStyles.body(size: 14, color: AppColors.primaryGreen),
                  ),
                ),
                const SizedBox(height: 24),
                for (final entry in examCatalog)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: ExamCategoryCard(
                      icon: entry.examCode == 'AT'
                          ? FontAwesomeIcons.graduationCap
                          : entry.examCode == 'TAT'
                              ? FontAwesomeIcons.chalkboardUser
                              : FontAwesomeIcons.calculator,
                      label: '${entry.title} (${entry.examCode})',
                      iconColor: AppColors.primaryGreen,
                      iconBg: const Color(0xFFEAF4EC),
                      onTap: () => selectAndGo(entry.examCode),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'sheet'),
    );
  }
}
