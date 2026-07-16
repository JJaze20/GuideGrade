import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
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
      appBar: const AppHeaderBar(title: 'GUIDE GRADE'),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Select Exam Category', style: AppTextStyles.heading(size: 15)),
              const SizedBox(height: 2),
              Text(
                'Choose an assessment framework layout blueprint:',
                style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 1.35,
                  children: [
                    ExamCategoryCard(
                      icon: FontAwesomeIcons.graduationCap,
                      label: 'Admission Exam',
                      iconColor: AppColors.primaryGreen,
                      iconBg: const Color(0xFFECFDF5),
                      onTap: () => selectAndGo('AT'),
                    ),
                    ExamCategoryCard(
                      icon: FontAwesomeIcons.brain,
                      label: 'Personality Profile',
                      iconColor: const Color(0xFF2563EB),
                      iconBg: const Color(0xFFEFF6FF),
                      onTap: () => selectAndGo('PT'),
                    ),
                    ExamCategoryCard(
                      icon: FontAwesomeIcons.chalkboardUser,
                      label: 'TAT Test',
                      iconColor: const Color(0xFFD97706),
                      iconBg: const Color(0xFFFFFBEB),
                      onTap: () => selectAndGo('TAT'),
                    ),
                    ExamCategoryCard(
                      icon: FontAwesomeIcons.calculator,
                      label: 'QTM Test',
                      iconColor: const Color(0xFF7C3AED),
                      iconBg: const Color(0xFFF5F3FF),
                      onTap: () => selectAndGo('QTM'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'sheet'),
    );
  }
}
