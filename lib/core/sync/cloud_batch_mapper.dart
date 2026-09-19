/// Pure cloud row -> local model conversion for cloud retrieval
/// ([CloudRestoreService]). No I/O, no Supabase, no Firebase, no filesystem
/// -- deterministic and unit-testable, matching the style of
/// `lib/core/omr/exam_score.dart`.
///
/// The one rule every function here enforces: a percentage is always
/// recomputed via the exam's own official formula, never copied from a
/// cloud column (the cloud `scans` row doesn't even expose one -- see
/// [CloudScanRow]'s doc comment). `rawScore` / `totalGraded` / `totalItems`
/// are the one exception -- they ARE authoritative cloud columns (the
/// numbers the original grading actually produced) and are taken as-is.
library;

import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import '../omr/exam_score.dart';
import '../omr/omr_scorer.dart';
import '../omr/qtm_result.dart';
import '../omr/tat_result.dart';
import 'sync_client.dart';

/// The Admission Test's fixed itemization -- the denominator of its
/// official percentage, same value `exam_score.dart` uses.
const int _atItemCount = 72;

/// Converts one [CloudBatchRow] into a [LocalBatch] with **no scans** --
/// scans are reconciled one at a time via [mapCloudScan] and
/// `BatchRepository.upsertScanFromCloud`, never carried by this call.
LocalBatch mapCloudBatch(CloudBatchRow row) => LocalBatch(
      id: row.id,
      batchCode: row.batchCode,
      examCode: row.examCode,
      examTitle: row.examTitle,
      description: row.description,
      expectedCount: row.expectedCount,
      status: row.status,
      createdByUid: row.createdByUid,
      createdByName: row.createdByName,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      scans: const [],
    );

/// Converts one [CloudScanRow] into a [LocalScan].
///
/// [answerKey] is the CURRENT local/cloud answer key for the scan's exam
/// code, needed only to recompute the TAT per-test breakdown (see
/// [_buildRestoredResult]) -- null simply skips that recomputation, leaving
/// the `tatTest*`/`tatTotal` fields null. See `CloudRestoreService`'s doc
/// comment for the accepted limitation this implies when the answer key has
/// changed since the scan was originally graded.
///
/// `nameCropLastFileName` / `nameCropFirstFileName` / `nameCropMiddleFileName`
/// are always null (the name-crop images are a device-local convenience,
/// never uploaded, so a restored scan simply has no crop to show — same as
/// any other older scan that predates the feature) and
/// `ExamineeInfo.middleName` is always `''` (the cloud never carries it,
/// per `SupabaseSyncClient.pushScan`'s `'middle_name': null`) -- neither is
/// invented here.
LocalScan mapCloudScan(CloudScanRow row, {AnswerKey? answerKey}) {
  final decoded = OmrScanResult.fromJson(row.decoded);
  return LocalScan(
    id: row.id,
    imageFileName: 'images/${row.id}.enc',
    rectifiedImageFileName:
        row.rectifiedImagePath != null ? 'images/${row.id}_rectified.enc' : null,
    capturedAt: row.capturedAt,
    decoded: decoded,
    result: row.resultStatus == null
        ? null
        : _buildRestoredResult(row, decoded, answerKey),
    examinee: _mapExaminee(row),
  );
}

/// The examinee trio, all-or-nothing (mirrors the cloud's own
/// `examinee_all_or_nothing` CHECK) -- `null` unless all three of
/// first/last/number are present and non-blank.
ExamineeInfo? _mapExaminee(CloudScanRow row) {
  final first = row.firstName;
  final last = row.lastName;
  final number = row.examineeNumber;
  if (first == null || last == null || number == null) return null;
  if (first.trim().isEmpty || last.trim().isEmpty || number.trim().isEmpty) {
    return null;
  }
  return ExamineeInfo(firstName: first, lastName: last, examineeNumber: number);
}

/// `rawScore` / `totalGraded` / `totalItems` / `status` / `scannedAt` /
/// `processedByUid` / `processedByName` are taken directly from [row] --
/// they are the cloud's authoritative record of what the original grading
/// produced. `percentage` is always recomputed via the exam's own official
/// formula (never copied -- there is no cloud column for it). The TAT
/// per-test breakdown has no cloud representation at all and is
/// recomputed, when [answerKey] is available, via the same
/// [scoreOmrResult] / [computeExamScoreForCode] pipeline a live TAT scan
/// already uses.
LocalScanResult _buildRestoredResult(
  CloudScanRow row,
  OmrScanResult decoded,
  AnswerKey? answerKey,
) {
  final rawScore = row.rawScore ?? 0;
  final totalGraded = row.totalGraded ?? 0;
  final totalItems = row.totalItems ?? 0;

  ExamScore? tatBreakdown;
  if (row.examCode == 'TAT' && answerKey != null) {
    final scored = scoreOmrResult(decoded, answerKey);
    final examScore = computeExamScoreForCode(scored);
    if (examScore != null && examScore.isTat) tatBreakdown = examScore;
  }

  return LocalScanResult(
    rawScore: rawScore,
    totalGraded: totalGraded,
    totalItems: totalItems,
    percentage: _officialPercentage(row.examCode, rawScore, totalItems),
    status: row.resultStatus ?? 'Ungraded',
    scannedAt: row.scannedAt ?? row.capturedAt,
    processedByUid: row.processedByUid ?? '',
    processedByName: row.processedByName ?? 'Unknown',
    tatTest1Correct: tatBreakdown?.tatTest1Correct,
    tatTest1Wrong: tatBreakdown?.tatTest1Wrong,
    tatTest1Score: tatBreakdown?.tatTest1Score,
    tatTest2Correct: tatBreakdown?.tatTest2Correct,
    tatTest2Wrong: tatBreakdown?.tatTest2Wrong,
    tatTest2Score: tatBreakdown?.tatTest2Score,
    tatTest3Correct: tatBreakdown?.tatTest3Correct,
    tatTest3Wrong: tatBreakdown?.tatTest3Wrong,
    tatTest3Score: tatBreakdown?.tatTest3Score,
    tatTotal: tatBreakdown?.tatTotal,
  );
}

/// The exam's own official percentage, computed from the authoritative
/// [rawScore] -- never from a cloud percentage column (none exists; see
/// [CloudScanRow]'s doc comment).
double _officialPercentage(String examCode, int rawScore, int totalItems) {
  switch (examCode) {
    case 'AT':
      final items = totalItems > 0 ? totalItems : _atItemCount;
      return rawScore / items * 100;
    case 'QTM':
      return qtmPercentage(rawScore) ?? 0;
    case 'TAT':
      return tatPercentage(rawScore) ?? 0;
    default:
      return 0;
  }
}
