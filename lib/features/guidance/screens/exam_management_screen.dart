import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/routes/app_routes.dart';

/// Exam Management screen for Guidance Council users.
///
/// Exam designs aren't finalized yet, so this only lets staff pick one of
/// the three predefined exams (AT/QTM/TAT) and preview/print/export its
/// official answer sheet -- no creating, editing, or otherwise modifying
/// exams or answer keys.
class ExamManagementScreen extends StatelessWidget {
  const ExamManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Exam Management', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Select an exam to preview and print its official answer sheet.',
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
            const SizedBox(height: 16),
            ...examCatalog.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ExamCatalogCard(
                  entry: entry,
                  onTap: () => Navigator.of(context).pushNamed(
                    AppRoutes.examSheetPreview,
                    arguments: entry,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExamCatalogCard extends StatelessWidget {
  final ExamCatalogEntry entry;
  final VoidCallback onTap;

  const _ExamCatalogCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const FaIcon(FontAwesomeIcons.fileLines, size: 18, color: AppColors.primaryGreen),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title, style: AppTextStyles.heading(size: 13)),
                  const SizedBox(height: 2),
                  Text(
                    entry.examCode,
                    style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                  ),
                ],
              ),
            ),
            const FaIcon(FontAwesomeIcons.chevronRight, size: 14, color: AppColors.textGray),
          ],
        ),
      ),
    );
  }
}
