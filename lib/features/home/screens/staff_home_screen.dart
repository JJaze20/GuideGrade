import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/app_bottom_nav.dart';
import '../widgets/activity_card.dart';
import '../widgets/create_batch_sheet.dart';

/// Staff Home / Dashboard — mirrors SCREENS.STAFF_HOME in the prototype.
/// Shows a welcome card, "Create New Batch" CTA, and the registry list
/// of diagnostic batches (Pending -> Exam Setup, Done -> Exam Results).
class StaffHomeScreen extends StatelessWidget {
  const StaffHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      body: SafeArea(
        child: Column(
          children: [
            // Green header bar
            Container(
              color: AppColors.primaryGreen,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text('G', style: AppTextStyles.logo(size: 20, color: Colors.amber.shade300)),
                      const SizedBox(width: 6),
                      Text(
                        'GUIDE GRADE',
                        style: AppTextStyles.heading(size: 12, color: Colors.white, weight: FontWeight.w800)
                            .copyWith(letterSpacing: 1.1),
                      ),
                    ],
                  ),
                  InkWell(
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.profile),
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0xFF1B5E20), shape: BoxShape.circle),
                      child: const FaIcon(FontAwesomeIcons.userTie, size: 12, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListenableBuilder(
                listenable: appState,
                builder: (context, _) {
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Welcome card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'WELCOME BACK',
                                  style: AppTextStyles.body(size: 9.5, weight: FontWeight.w800, color: AppColors.primaryGreen)
                                      .copyWith(letterSpacing: 0.6),
                                ),
                                Text('NDMU Staff Officer', style: AppTextStyles.heading(size: 13)),
                              ],
                            ),
                            Text('Marbel, PH', style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Create new batch CTA
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => CreateBatchSheet.show(context),
                          icon: const FaIcon(FontAwesomeIcons.folderPlus, size: 14, color: Colors.amber),
                          label: const Text('CREATE NEW BATCH'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.darkNavy,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),

                      Row(
                        children: [
                          const FaIcon(FontAwesomeIcons.layerGroup, size: 12, color: AppColors.primaryGreen),
                          const SizedBox(width: 6),
                          Text('Diagnostic Batches & Results Registry', style: AppTextStyles.heading(size: 12)),
                        ],
                      ),
                      const SizedBox(height: 10),

                      ...appState.recentActivities.map(
                            (activity) => ActivityCard(
                          activity: activity,
                          onTap: () {
                            appState.setActiveExamCode(activity.examCode);
                            if (activity.status == 'Pending') {
                              Navigator.of(context).pushNamed(AppRoutes.examSetup);
                            } else {
                              Navigator.of(context).pushNamed(AppRoutes.examResults);
                            }
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'home'),
    );
  }
}