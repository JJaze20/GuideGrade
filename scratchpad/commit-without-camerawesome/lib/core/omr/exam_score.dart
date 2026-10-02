import 'omr_scorer.dart';
import 'omr_templates.dart';

/// Which official GuideGrade scoring family produced an [ExamScore].
enum ExamScoringModel {
  /// One point per correct answer; wrong / blank / ambiguous score 0.
  /// Used by the Admission Test and QTM.
  raw,

  /// The three-part TAT rule: Test 1 = correct x 2; Test 2 and Test 3 =
  /// `max(0, correct - wrong)`; TAT total = the sum of the three.
  tat,
}

/// The official exam-aware score for one scanned sheet.
///
/// Pure value object. Built by [computeExamScore] from the per-item
/// correctness that [scoreOmrResult] already produced ([ScoredResult] /
/// [ScoredItem]) plus the sheet's [OmrExamTemplate]. No I/O, no database,
/// no Supabase, no Firebase, no UI — deterministic and trivially testable.
///
/// This layer sits *around* the existing scorer; it does not modify the
/// decoder, the templates, or [ScoredItem]'s per-item logic.
class ExamScore {
  const ExamScore({
    required this.examCode,
    required this.model,
    required this.rawScore,
    required this.totalItems,
    required this.totalGraded,
    required this.percentage,
    required this.isGraded,
    this.tatTest1Correct,
    this.tatTest1Wrong,
    this.tatTest1Score,
    this.tatTest2Correct,
    this.tatTest2Wrong,
    this.tatTest2Score,
    this.tatTest3Correct,
    this.tatTest3Wrong,
    this.tatTest3Score,
    this.tatTotal,
  });

  /// The exam this score is for (e.g. `AT`, `QTM`, `TAT`).
  final String examCode;

  /// The scoring family that was applied.
  final ExamScoringModel model;

  /// A single headline score:
  ///  * [ExamScoringModel.raw] (AT / QTM): the number of correct answers,
  ///    `0..totalItems`.
  ///  * [ExamScoringModel.tat]: the 160-point [tatTotal], so a caller that
  ///    only wants one number still gets the official TAT score.
  final int rawScore;

  /// The exam's fixed itemization total, summed from the exam template's
  /// section item counts: AT = 72, QTM = 60, TAT = 130 (30 + 80 + 20).
  ///
  /// This is *always* the sheet's fixed item count — never answer-key
  /// coverage and never the number of answered items.
  final int totalItems;

  /// How many items on this sheet the answer key actually covers (has a
  /// correct choice for). Kept only for the Graded / Ungraded decision and
  /// for backward compatibility with existing consumers. It is **never**
  /// used as a percentage denominator.
  final int totalGraded;

  /// Percentage on the official denominator, or `0.0` when the exam has no
  /// official percentage.
  ///
  ///  * **Admission Test:** `rawScore / 72 * 100` — always on the fixed
  ///    72-item denominator (per the official specification), regardless of
  ///    how many answer-key entries were graded.
  ///  * **QTM:** `0.0`. The specification defines no official QTM
  ///    percentage, so none is invented here. See [hasOfficialPercentage].
  ///  * **TAT:** `0.0`. The specification defines no TAT percentage; use
  ///    the per-test scores and [tatTotal] instead.
  final double percentage;

  /// Whether the answer key covered at least one item on this sheet
  /// (`totalGraded > 0`). Mirrors the existing "Graded / Ungraded" rule.
  final bool isGraded;

  // --- TAT breakdown. All null unless [model] == [ExamScoringModel.tat]. ---

  /// TAT Test 1 — correct answers, definite wrong answers, and the score
  /// (`correct * 2`, max 60).
  final int? tatTest1Correct;
  final int? tatTest1Wrong;
  final int? tatTest1Score;

  /// TAT Test 2 — correct, definite wrong, and the score
  /// (`max(0, correct - wrong)`, max 80).
  final int? tatTest2Correct;
  final int? tatTest2Wrong;
  final int? tatTest2Score;

  /// TAT Test 3 — correct, definite wrong, and the score
  /// (`max(0, correct - wrong)`, max 20).
  final int? tatTest3Correct;
  final int? tatTest3Wrong;
  final int? tatTest3Score;

  /// TAT total = Test 1 + Test 2 + Test 3 (max 160). Equal to [rawScore]
  /// for a TAT sheet.
  final int? tatTotal;

  /// True for the three-part TAT rule.
  bool get isTat => model == ExamScoringModel.tat;

  /// True only when [percentage] carries an officially-specified value
  /// (Admission Test only). For every other exam [percentage] is `0.0` and
  /// must not be surfaced as a result.
  bool get hasOfficialPercentage => model == ExamScoringModel.raw && examCode == _atCode;
}

/// The exam code whose official scoring includes a percentage.
const String _atCode = 'AT';

/// The exam code scored with the three-part TAT rule.
const String _tatCode = 'TAT';

/// Computes the official [ExamScore] for [scored] using [template] for the
/// fixed itemization and, for TAT, the section order.
///
/// Preserves the existing per-item correctness in [ScoredItem]:
///  * **correct** = `item.isCorrect == true` (already `!isAmbiguous &&
///    markedChoice == correctChoice`).
///  * **definite wrong** (TAT Test 2 / Test 3 only) = `correctChoice != null
///    && markedChoice != null && !isAmbiguous && markedChoice !=
///    correctChoice`. Blank and ambiguous answers never count as wrong.
///
/// For TAT the three tests are taken in template section order: the first
/// section is the `correct * 2` test, the second and third are the
/// `max(0, correct - wrong)` tests.
ExamScore computeExamScore(ScoredResult scored, OmrExamTemplate template) {
  final totalItems =
      template.sections.fold<int>(0, (sum, s) => sum + s.itemCount);
  final totalGraded =
      scored.items.where((i) => i.correctChoice != null).length;
  final isGraded = totalGraded > 0;

  if (scored.examCode == _tatCode) {
    final sections = template.sections;
    final c1 = _sectionCounts(scored, sections, 0);
    final c2 = _sectionCounts(scored, sections, 1);
    final c3 = _sectionCounts(scored, sections, 2);

    final s1 = c1.correct * 2; // Test 1: correct x 2
    final s2 = _atLeastZero(c2.correct - c2.wrong); // Test 2: max(0, C - W)
    final s3 = _atLeastZero(c3.correct - c3.wrong); // Test 3: max(0, C - W)
    final total = s1 + s2 + s3;

    return ExamScore(
      examCode: _tatCode,
      model: ExamScoringModel.tat,
      rawScore: total,
      totalItems: totalItems,
      totalGraded: totalGraded,
      percentage: 0,
      isGraded: isGraded,
      tatTest1Correct: c1.correct,
      tatTest1Wrong: c1.wrong,
      tatTest1Score: s1,
      tatTest2Correct: c2.correct,
      tatTest2Wrong: c2.wrong,
      tatTest2Score: s2,
      tatTest3Correct: c3.correct,
      tatTest3Wrong: c3.wrong,
      tatTest3Score: s3,
      tatTotal: total,
    );
  }

  // Admission Test / QTM (and any other single-family raw-scored exam):
  // one point per correct answer.
  final rawScore = scored.items.where((i) => i.isCorrect == true).length;
  final percentage = (scored.examCode == _atCode && totalItems > 0)
      ? rawScore / totalItems * 100
      : 0.0;

  return ExamScore(
    examCode: scored.examCode,
    model: ExamScoringModel.raw,
    rawScore: rawScore,
    totalItems: totalItems,
    totalGraded: totalGraded,
    percentage: percentage,
    isGraded: isGraded,
  );
}

/// Convenience wrapper that resolves the template from [omrTemplates] by
/// `scored.examCode`. Returns null when no template is registered for that
/// exam (the caller then keeps whatever handling it already has).
ExamScore? computeExamScoreForCode(ScoredResult scored) {
  final template = omrTemplates[scored.examCode];
  if (template == null) return null;
  return computeExamScore(scored, template);
}

/// Correct / definite-wrong counts for the section at [index] in
/// [sections], or a zero pair when the template has no such section.
_SectionCounts _sectionCounts(
  ScoredResult scored,
  List<OmrSection> sections,
  int index,
) {
  if (index >= sections.length) return const _SectionCounts(0, 0);
  final name = sections[index].name;
  var correct = 0;
  var wrong = 0;
  for (final item in scored.items) {
    if (item.sectionName != name) continue;
    if (item.isCorrect == true) {
      correct++;
    } else if (item.correctChoice != null &&
        item.markedChoice != null &&
        !item.isAmbiguous &&
        item.markedChoice != item.correctChoice) {
      wrong++;
    }
  }
  return _SectionCounts(correct, wrong);
}

int _atLeastZero(int value) => value < 0 ? 0 : value;

class _SectionCounts {
  const _SectionCounts(this.correct, this.wrong);
  final int correct;
  final int wrong;
}
