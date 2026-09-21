import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import 'exam_score.dart';
import 'omr_scorer.dart';

/// Builds the [LocalScanResult] persisted for one scanned sheet from the
/// exam-aware [ExamScore] the official scoring layer produces.
///
/// Used by every persistence path that produces a result (a fresh capture, a
/// rescan, and a manual answer correction — see [rescoreScan]) so they all
/// persist an identically-computed result; there is no path left on the old
/// generic scorer. (Moved here from app_state.dart, which still re-exports
/// it, so this pure scoring glue can be exercised without Flutter.)
///
///  * [examScore] is `computeExamScoreForCode(scored)`. It is null only
///    when no exam template is registered for `scored.examCode`; in that
///    case the pre-exam-aware generic values are kept so an unrecognised
///    exam still persists something.
///  * `rawScore` / `totalItems` / the `tat*` breakdown come straight from
///    [ExamScore]. For TAT, `rawScore` is the 160-point total and
///    `totalItems` is 130; for AT / QTM `rawScore` is the correct-answer
///    count and `totalItems` is the fixed 72 / 60.
///  * `percentage` is the Admission Test's official `rawScore / 72 * 100`
///    when [ExamScore.hasOfficialPercentage]. QTM and TAT have no official
///    percentage, so to avoid changing the meaning of the non-nullable
///    `LocalScanResult.percentage` field (and its result-screen / archive /
///    batch-average consumers) in this local-persistence-only phase, they
///    keep the existing generic `scored.percentage`. This is a documented
///    compatibility shim, not an invented rule; per-exam percentage
///    semantics are for the Result UI / Supabase phases.
///  * `status` keeps the existing answer-key-availability rule
///    ([ExamScore.isGraded] is `totalGraded > 0`).
LocalScanResult buildLocalScanResult(
  ScoredResult scored,
  ExamScore? examScore, {
  required String processedByUid,
  required String processedByName,
  DateTime? scannedAt,
}) {
  final now = scannedAt ?? DateTime.now();

  if (examScore == null) {
    final graded = scored.totalGraded > 0;
    return LocalScanResult(
      rawScore: scored.rawScore,
      totalGraded: scored.totalGraded,
      totalItems: scored.items.length,
      percentage: scored.percentage,
      status: graded ? 'Graded' : 'Ungraded',
      scannedAt: now,
      processedByUid: processedByUid,
      processedByName: processedByName,
    );
  }

  final percentage = examScore.hasOfficialPercentage
      ? examScore.percentage
      : scored.percentage;

  return LocalScanResult(
    rawScore: examScore.rawScore,
    totalGraded: examScore.totalGraded,
    totalItems: examScore.totalItems,
    percentage: percentage,
    status: examScore.isGraded ? 'Graded' : 'Ungraded',
    scannedAt: now,
    processedByUid: processedByUid,
    processedByName: processedByName,
    tatTest1Correct: examScore.tatTest1Correct,
    tatTest1Wrong: examScore.tatTest1Wrong,
    tatTest1Score: examScore.tatTest1Score,
    tatTest2Correct: examScore.tatTest2Correct,
    tatTest2Wrong: examScore.tatTest2Wrong,
    tatTest2Score: examScore.tatTest2Score,
    tatTest3Correct: examScore.tatTest3Correct,
    tatTest3Wrong: examScore.tatTest3Wrong,
    tatTest3Score: examScore.tatTest3Score,
    tatTotal: examScore.tatTotal,
  );
}

/// Recalculates [scan]'s stored result from what it CURRENTLY reads as — the
/// machine-detected answers with this capture's active manual corrections
/// applied ([LocalScan.effectiveDecoded]) — through the unchanged
/// exam-specific scoring rules (AT/QTM one point per correct answer; TAT
/// Test I × 2 and Tests II/III `max(0, correct − wrong)`, with the same
/// section order and weights). Nothing about how a score is computed is
/// duplicated or altered here: it only feeds different answers into
/// [scoreOmrResult] / [computeExamScoreForCode].
///
/// Returns:
///  * the new [LocalScanResult], keeping the original scan's `scannedAt` and
///    the account that scanned it (a correction does not change who scanned
///    the sheet — who corrected it is recorded on the correction itself);
///  * the scan's existing result unchanged (possibly null) when there is no
///    [answerKey] for the exam — with no key there is nothing to grade
///    against, exactly as at scan time; the correction is still kept and
///    the score is recalculated once a key exists.
LocalScanResult? rescoreScan({
  required LocalScan scan,
  required AnswerKey? answerKey,
  String editorUid = '',
  String editorName = '',
}) {
  if (answerKey == null) return scan.result;
  final scored = scoreOmrResult(scan.effectiveDecoded, answerKey);
  final previous = scan.result;
  return buildLocalScanResult(
    scored,
    computeExamScoreForCode(scored),
    processedByUid: previous?.processedByUid ?? editorUid,
    processedByName: previous?.processedByName ?? editorName,
    scannedAt: previous?.scannedAt ?? scan.capturedAt,
  );
}
