import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/admission_category.dart';
import '../../../core/omr/exam_score.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/qtm_result.dart';
import '../../../models/local_batch.dart';

/// Presentation-only summary of one scanned sheet's result, sized to sit
/// inside the existing result cards.
///
/// It FORMATS — it never computes — the result it is given:
///  * a persisted [LocalScanResult] ([result]) is the source of truth and
///    is preferred whenever available;
///  * a live [ScoredResult] ([live]) is used only on the post-scan screen
///    before persistence.
///
/// For the Admission Test's official `/72` percentage on the live path it
/// calls the existing pure [computeExamScoreForCode] helper. It never
/// writes data, touches a repository / Firebase / Supabase / sync / the
/// scanner / answer keys, changes [LocalScanResult] / [LocalBatch] /
/// `ExamScore`, or recomputes a persisted TAT breakdown.
class ScanResultSummary extends StatelessWidget {
  const ScanResultSummary({
    super.key,
    required this.examCode,
    this.result,
    this.live,
  });

  /// The batch's exam code (`AT` / `QTM` / `TAT`). Taken from the batch,
  /// never inferred from [ScoredResult.examCode].
  final String examCode;

  /// The persisted result, when available. Preferred over [live].
  final LocalScanResult? result;

  /// The live, pre-persistence scored result (post-scan screen only).
  final ScoredResult? live;

  bool get _isGraded {
    final r = result;
    if (r != null) return r.isGraded;
    final l = live;
    if (l != null) return l.totalGraded > 0;
    return false;
  }

  int? get _rawScore {
    final r = result;
    if (r != null) return r.rawScore;
    return live?.rawScore;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isGraded) return _ungradedPill();
    switch (examCode) {
      case 'AT':
        return _buildAdmissionTest();
      case 'QTM':
        return _buildQtm();
      case 'TAT':
        return _buildTat();
      default:
        return _buildUnknown();
    }
  }

  // --- Admission Test -----------------------------------------------------

  Widget _buildAdmissionTest() {
    final raw = _rawScore;
    final pct = _admissionPercentage();
    final category = raw == null ? null : admissionCategory(raw);
    return _block([
      _row('Score', raw == null ? '—' : '$raw / 72'),
      if (pct != null) _row('Percentage', '${pct.toStringAsFixed(0)}%'),
      if (raw != null)
        _row(
          'Category',
          _categoryLabel(category),
          valueColor: _categoryColor(category),
        ),
    ]);
  }

  /// The official Admission Test percentage (fixed 72 denominator).
  /// Persisted results already store it; for a live result the pure
  /// exam-aware helper is asked for it. Scoring is not modified.
  double? _admissionPercentage() {
    final r = result;
    if (r != null) return r.percentage;
    final l = live;
    if (l == null) return null;
    final examScore = computeExamScoreForCode(l);
    if (examScore != null && examScore.hasOfficialPercentage) {
      return examScore.percentage;
    }
    return null;
  }

  static String _categoryLabel(AdmissionCategory? c) => switch (c) {
        AdmissionCategory.a => 'A',
        AdmissionCategory.b => 'B',
        AdmissionCategory.c => 'C',
        AdmissionCategory.d => 'D',
        null => 'Not classified',
      };

  static Color _categoryColor(AdmissionCategory? c) => switch (c) {
        AdmissionCategory.a => AppColors.catA,
        AdmissionCategory.b => AppColors.catB,
        AdmissionCategory.c => AppColors.catC,
        AdmissionCategory.d => AppColors.catD,
        null => AppColors.catCutoff,
      };

  static String _qtmEligibilityLabel(QtmEligibility? e) => switch (e) {
        QtmEligibility.allCoursesIncludingBscs =>
          'All QTM-required courses, incl. BSCS',
        QtmEligibility.allCoursesExceptBscs =>
          'All QTM-required courses, except BSCS',
        QtmEligibility.notEligible => 'Does not meet the QTM requirement',
        null => '—',
      };

  static Color _qtmEligibilityColor(QtmEligibility? e) => switch (e) {
        QtmEligibility.allCoursesIncludingBscs => AppColors.catC,
        QtmEligibility.allCoursesExceptBscs => AppColors.catB,
        QtmEligibility.notEligible => AppColors.catA,
        null => AppColors.catCutoff,
      };

  // --- QTM --------------------------------------------------------------

  /// Official QTM presentation: raw `/ 60`, the official percentage
  /// (`raw / 60 * 100` via [qtmPercentage] — never the legacy
  /// `LocalScanResult.percentage`), and the course-eligibility band
  /// ([qtmEligibility]). Unreachable for an ungraded result — `build()`
  /// returns the "Ungraded" pill before this runs.
  Widget _buildQtm() {
    final raw = _rawScore;
    final percentage = raw == null ? null : qtmPercentage(raw);
    final eligibility = raw == null ? null : qtmEligibility(raw);
    return _block([
      _row('Score', raw == null ? '—' : '$raw / 60'),
      if (percentage != null)
        _row('Percentage', '${percentage.toStringAsFixed(2)}%'),
      if (eligibility != null)
        _row(
          'Eligibility',
          _qtmEligibilityLabel(eligibility),
          valueColor: _qtmEligibilityColor(eligibility),
        ),
    ]);
  }

  // --- TAT -------------------------------------------------------------

  Widget _buildTat() {
    final r = result;
    if (r == null || !r.hasTatBreakdown) {
      return _tatUnavailable(
        r == null
            ? 'Save the scan to view the breakdown'
            : 'Rescan to refresh',
      );
    }
    final t1c = r.tatTest1Correct ?? 0;
    final t1s = r.tatTest1Score ?? 0;
    final t2c = r.tatTest2Correct ?? 0;
    final t2w = r.tatTest2Wrong ?? 0;
    final t2s = r.tatTest2Score ?? 0;
    final t3c = r.tatTest3Correct ?? 0;
    final t3w = r.tatTest3Wrong ?? 0;
    final t3s = r.tatTest3Score ?? 0;
    final total = r.tatTotal ?? 0;
    return _block([
      _row('Test 1', '$t1c correct × 2 = $t1s / 60'),
      _row('Test 2', '$t2c correct − $t2w wrong = $t2s / 80'),
      _row('Test 3', '$t3c correct − $t3w wrong = $t3s / 20'),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, color: AppColors.cardBorder),
      ),
      _row('TAT Total', '$total / 160', valueColor: AppColors.darkNavy),
    ]);
  }

  Widget _tatUnavailable(String hint) {
    return _block([
      Text(
        'TAT breakdown unavailable',
        style: AppTextStyles.body(
          size: 10,
          weight: FontWeight.w700,
          color: const Color(0xFF92400E),
        ),
      ),
      const SizedBox(height: 2),
      Text(hint, style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
    ]);
  }

  // --- Unknown / unexpected exam code ----------------------------------

  Widget _buildUnknown() {
    final raw = _rawScore;
    final items = result?.totalItems ?? live?.items.length;
    final value = raw == null
        ? 'Result recorded'
        : (items == null || items <= 0)
            ? '$raw'
            : '$raw / $items';
    return _block([_row('Score', value)]);
  }

  // --- shared bits ---------------------------------------------------------

  Widget _block(List<Widget> children) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );

  Widget _row(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: AppTextStyles.body(
                size: 9,
                color: AppColors.textGray,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body(
                size: 10,
                weight: FontWeight.w800,
                color: valueColor ?? AppColors.textDark,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ungradedPill() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'Ungraded',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            color: Color(0xFF92400E),
          ),
        ),
      ),
    );
  }
}
