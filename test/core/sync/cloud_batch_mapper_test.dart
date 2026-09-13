import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/cloud_batch_mapper.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

CloudBatchRow _batchRow({
  String id = 'b1',
  DateTime? createdAt,
  DateTime? updatedAt,
}) =>
    CloudBatchRow(
      id: id,
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: 'd',
      expectedCount: 10,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
    );

CloudScanRow _scanRow({
  String id = 's1',
  String examCode = 'AT',
  Map<String, dynamic>? decoded,
  int? rawScore,
  int? totalGraded,
  int? totalItems,
  String? resultStatus,
  String? firstName,
  String? lastName,
  String? examineeNumber,
  String? rectifiedImagePath,
}) =>
    CloudScanRow(
      id: id,
      batchId: 'b1',
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: decoded ?? {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: rawScore,
      totalGraded: totalGraded,
      totalItems: totalItems,
      resultStatus: resultStatus,
      scannedAt: resultStatus == null ? null : DateTime.utc(2026, 1, 2),
      processedByUid: resultStatus == null ? null : 'uid',
      processedByName: resultStatus == null ? null : 'Officer',
      firstName: firstName,
      lastName: lastName,
      examineeNumber: examineeNumber,
      rectifiedImagePath: rectifiedImagePath,
    );

void main() {
  group('mapCloudBatch', () {
    test('maps every field verbatim and always starts with no scans', () {
      final row = _batchRow();
      final batch = mapCloudBatch(row);

      expect(batch.id, row.id);
      expect(batch.batchCode, row.batchCode);
      expect(batch.examCode, row.examCode);
      expect(batch.examTitle, row.examTitle);
      expect(batch.description, row.description);
      expect(batch.expectedCount, row.expectedCount);
      expect(batch.status, row.status);
      expect(batch.createdByUid, row.createdByUid);
      expect(batch.createdByName, row.createdByName);
      expect(batch.createdAt, row.createdAt);
      expect(batch.updatedAt, row.updatedAt);
      expect(batch.scans, isEmpty);
    });
  });

  group('mapCloudScan — identity and image paths', () {
    test('derives the deterministic local image filenames from the scan id', () {
      final scan = mapCloudScan(_scanRow(id: 's_42', rectifiedImagePath: 'batches/b1/scans/s_42/rectified.jpg'));
      expect(scan.id, 's_42');
      expect(scan.imageFileName, 'images/s_42.enc');
      expect(scan.rectifiedImageFileName, 'images/s_42_rectified.enc');
    });

    test('no rectified path -> no local rectified filename', () {
      final scan = mapCloudScan(_scanRow(rectifiedImagePath: null));
      expect(scan.rectifiedImageFileName, isNull);
    });

    test('OCR guesses are always null; middleName is always blank', () {
      final scan = mapCloudScan(_scanRow(
        firstName: 'Juan',
        lastName: 'Dela Cruz',
        examineeNumber: 'X-1',
      ));
      expect(scan.ocrLastNameGuess, isNull);
      expect(scan.ocrFirstNameGuess, isNull);
      expect(scan.ocrMiddleNameGuess, isNull);
      expect(scan.examinee!.middleName, '');
    });

    test('examinee trio is all-or-nothing: a partial trio maps to null, never invented', () {
      final scan = mapCloudScan(_scanRow(firstName: 'Juan', lastName: null, examineeNumber: 'X-1'));
      expect(scan.examinee, isNull);
    });

    test('an ungraded row (no resultStatus) has no result', () {
      final scan = mapCloudScan(_scanRow(resultStatus: null));
      expect(scan.result, isNull);
    });
  });

  group('mapCloudScan — Admission Test', () {
    test('percentage is always recomputed as rawScore/72*100, never left at a legacy value', () {
      final scan = mapCloudScan(_scanRow(
        examCode: 'AT',
        rawScore: 54,
        totalGraded: 72,
        totalItems: 72,
        resultStatus: 'Graded',
      ));
      expect(scan.result!.rawScore, 54);
      expect(scan.result!.percentage, closeTo(75.0, 0.0001)); // 54/72*100
    });
  });

  group('mapCloudScan — QTM', () {
    test('percentage uses the official qtmPercentage formula, never a cloud column', () {
      final scan = mapCloudScan(_scanRow(
        examCode: 'QTM',
        rawScore: 18,
        totalGraded: 60,
        totalItems: 60,
        resultStatus: 'Graded',
      ));
      expect(scan.result!.rawScore, 18);
      expect(scan.result!.percentage, closeTo(30.0, 0.0001)); // 18/60*100
    });
  });

  group('mapCloudScan — TAT', () {
    final tatAnswerKey = AnswerKey(examCode: 'TAT', correctChoices: {
      'Test I|1': 'A',
      'Test I|2': 'A',
      'Test II|1': 'B',
      'Test III|1': 'C',
    });

    Map<String, dynamic> tatDecoded() => const OmrScanResult(examCode: 'TAT', items: [
          OmrItemResult(sectionName: 'Test I', itemNumber: 1, markedChoice: 'A'), // correct
          OmrItemResult(sectionName: 'Test I', itemNumber: 2, markedChoice: 'B'), // wrong
          OmrItemResult(sectionName: 'Test II', itemNumber: 1, markedChoice: 'B'), // correct
          OmrItemResult(sectionName: 'Test III', itemNumber: 1, markedChoice: 'X'), // wrong
        ]).toJson();

    test('rawScore/totalGraded/totalItems are taken directly from the cloud row', () {
      final scan = mapCloudScan(_scanRow(
        examCode: 'TAT',
        decoded: tatDecoded(),
        rawScore: 48,
        totalGraded: 130,
        totalItems: 130,
        resultStatus: 'Graded',
      ), answerKey: tatAnswerKey);

      expect(scan.result!.rawScore, 48);
      expect(scan.result!.totalGraded, 130);
      expect(scan.result!.totalItems, 130);
      // percentage recomputed from the authoritative rawScore, not copied.
      expect(scan.result!.percentage, closeTo(48 / 160 * 100, 0.0001));
    });

    test('breakdown is recomputed via the real scorer when an answer key is available', () {
      final scan = mapCloudScan(_scanRow(
        examCode: 'TAT',
        decoded: tatDecoded(),
        rawScore: 48,
        totalGraded: 130,
        totalItems: 130,
        resultStatus: 'Graded',
      ), answerKey: tatAnswerKey);

      // Test I: 1 correct * 2 = 2. Test II: max(0, 1-0) = 1. Test III: max(0, 0-1)=0.
      expect(scan.result!.tatTest1Correct, 1);
      expect(scan.result!.tatTest1Score, 2);
      expect(scan.result!.tatTest2Correct, 1);
      expect(scan.result!.tatTest2Score, 1);
      expect(scan.result!.tatTest3Correct, 0);
      expect(scan.result!.tatTest3Score, 0);
      expect(scan.result!.tatTotal, 3);
      expect(scan.result!.hasTatBreakdown, isTrue);
    });

    test('no answer key available -> breakdown fields stay null (documented limitation), rawScore still authoritative', () {
      final scan = mapCloudScan(_scanRow(
        examCode: 'TAT',
        decoded: tatDecoded(),
        rawScore: 48,
        totalGraded: 130,
        totalItems: 130,
        resultStatus: 'Graded',
      ));

      expect(scan.result!.rawScore, 48);
      expect(scan.result!.hasTatBreakdown, isFalse);
      expect(scan.result!.tatTest1Correct, isNull);
    });
  });
}
