import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../models/omr_scan_result.dart';
import '../../../shared/widgets/primary_button.dart';

/// Exam Results — mirrors SCREENS.AT_RESULTS.
/// Shows what the OMR decoder read off each scanned sheet in this session
/// (AppState.scannedResults) — the marked choice per item, or a
/// blank/double-mark flag. When an answer key has been entered for the
/// exam (AnswerKeyEntryScreen), also shows a score and colors each item by
/// correctness; without one, items are colored by marked/blank/ambiguous
/// only, same as before. PT/TAT-specific norm-table scoring is still out
/// of scope — this is simple right/wrong-key comparison.
class ExamResultsScreen extends StatelessWidget {
  const ExamResultsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final results = appState.scannedResults;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Scan Results — ${appState.activeExamCode}', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: results.isEmpty ? _buildEmptyState() : _buildResultsList(results, appState),
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

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaIcon(FontAwesomeIcons.fileCircleQuestion, color: AppColors.textGray, size: 28),
            const SizedBox(height: 12),
            Text('No decoded sheets to show.', style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsList(List<OmrScanResult> results, AppState appState) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      itemBuilder: (context, sheetIndex) {
        final result = results[sheetIndex];
        final scored = scoreOmrResult(result, appState.answerKeys[result.examCode]);
        return _buildSheetCard(sheetIndex, scored);
      },
    );
  }

  Widget _buildSheetCard(int sheetIndex, ScoredResult scored) {
    final blankCount = scored.items.where((i) => i.isBlank).length;
    final ambiguousCount = scored.items.where((i) => i.isAmbiguous).length;
    final isGraded = scored.totalGraded > 0;

    final bySection = <String, List<ScoredItem>>{};
    for (final item in scored.items) {
      bySection.putIfAbsent(item.sectionName, () => []).add(item);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const FaIcon(FontAwesomeIcons.fileLines, color: AppColors.primaryGreen, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Sheet ${sheetIndex + 1}', style: AppTextStyles.heading(size: 13)),
              ),
              if (isGraded)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.emerald100, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    '${scored.rawScore}/${scored.totalGraded} · ${scored.percentage.toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF065F46)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${scored.items.length} items · $blankCount blank · $ambiguousCount flagged',
            style: AppTextStyles.body(size: 9, color: AppColors.textGray),
          ),
          const SizedBox(height: 12),
          ...bySection.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.key, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: entry.value.map(_buildItemChip).toList(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemChip(ScoredItem item) {
    final Color background;
    final Color foreground;
    final String label;
    if (item.isAmbiguous) {
      background = const Color(0xFFFEF3C7);
      foreground = const Color(0xFF92400E);
      label = '${item.itemNumber}: ⚠';
    } else if (item.isBlank) {
      background = const Color(0xFFF1F5F9);
      foreground = AppColors.textGray;
      label = '${item.itemNumber}: —';
    } else if (item.isCorrect == false) {
      background = const Color(0xFFFEE2E2);
      foreground = const Color(0xFF991B1B);
      label = '${item.itemNumber}: ${item.markedChoice}';
    } else {
      background = AppColors.emerald100;
      foreground = const Color(0xFF065F46);
      label = '${item.itemNumber}: ${item.markedChoice}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: foreground)),
    );
  }
}
