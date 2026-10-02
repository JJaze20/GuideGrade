import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_crypto_service.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// Test-only crypto (the real one needs a platform channel) — same fake the
/// other repository tests use.
class _FakeBatchCryptoService extends BatchCryptoService {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> decrypt(Uint8List packed) async => Uint8List.fromList(packed);
}

const _decoded = OmrScanResult(
  examCode: 'AT',
  items: [
    OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: 'B', isAmbiguous: false),
    OmrItemResult(sectionName: 'Section 1', itemNumber: 2, markedChoice: null, isAmbiguous: false),
  ],
);

LocalScanResult _result(int raw) => LocalScanResult(
      rawScore: raw,
      totalGraded: 72,
      totalItems: 72,
      percentage: raw / 72 * 100,
      status: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'scanner',
      processedByName: 'Scanner',
    );

AnswerCorrection _correction({String id = 'c1', int revision = 0, String scanId = 's'}) => AnswerCorrection(
      id: id,
      scanId: scanId,
      sectionName: 'Section 1',
      itemNumber: 1,
      captureRevision: revision,
      action: CorrectionAction.set,
      original: const CorrectedAnswer.choice('B'),
      corrected: const CorrectedAnswer.choice('A'),
      editorUid: 'u1',
      editorName: 'Officer',
      correctedAt: DateTime.utc(2026, 2, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalBatchRepository repo;

  LocalBatchRepository newRepo() => LocalBatchRepository(
        rootOverride: Directory('${tempDir.path}/batches'),
        crypto: _FakeBatchCryptoService(),
      );

  Future<LocalBatch> create({int expected = 10}) => repo.createBatch(
        batchCode: 'B-1',
        examCode: 'AT',
        examTitle: 'Aptitude',
        description: '',
        expectedCount: expected,
        createdByUid: 'u',
        createdByName: 'Officer',
      );

  Future<LocalBatch> withScan(LocalBatch b) {
    final src = File('${tempDir.path}/src.jpg')..writeAsBytesSync(const [1, 2, 3]);
    return repo.addScan(batchId: b.id, decoded: _decoded, sourceImage: src, result: _result(0));
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_batch_corrections_test_');
    repo = newRepo();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('derived batch status', () {
    test('a complete batch is Active, an incomplete one Draft', () async {
      expect((await create()).status, 'Active');
      final draft = await repo.createBatch(
        batchCode: 'B-2',
        examCode: 'AT',
        examTitle: 'Aptitude',
        description: '',
        expectedCount: 0,
        createdByUid: 'u',
        createdByName: 'Officer',
      );
      expect(draft.status, 'Draft');
    });

    test('updateBatch ignores the caller-supplied status and re-derives it', () async {
      final b = await create();
      final forced = await repo.updateBatch(b.copyWith(status: 'Archived', expectedCount: 0));
      expect(forced.status, 'Draft', reason: 'a required field is invalid');
      final fixed = await repo.updateBatch(forced.copyWith(status: 'Draft', expectedCount: 5));
      expect(fixed.status, 'Active');
    });

    test('untagged scans and an empty description never keep a batch in Draft', () async {
      final b = await withScan(await create());
      expect(b.status, 'Active');
      expect(b.untaggedScanCount, 1);
    });

    test('every save moves updatedAt strictly forward, even in the same tick', () async {
      var b = await create();
      final seen = <DateTime>[b.updatedAt];
      for (var i = 0; i < 5; i++) {
        b = await repo.updateBatch(b.copyWith(description: 'd$i'));
        seen.add(b.updatedAt);
      }
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].isAfter(seen[i - 1]), isTrue);
      }
    });

    test('archives only for the exact revision the cloud confirmed', () async {
      final b = await create();
      expect(await repo.confirmBatchArchived(b.id, b.updatedAt.subtract(const Duration(seconds: 1))), isFalse);
      expect((await repo.getBatchById(b.id))!.status, 'Active');

      expect(await repo.confirmBatchArchived(b.id, b.updatedAt), isTrue);
      final archived = (await repo.getBatchById(b.id))!;
      expect(archived.status, 'Archived');
      expect(archived.updatedAt, b.updatedAt, reason: 'archiving is not a new edit');
      expect(await repo.confirmBatchArchived(b.id, b.updatedAt), isFalse, reason: 'already archived');
    });

    test('a stale acknowledgement can not archive newer changes', () async {
      final b = await create();
      final edited = await repo.updateBatch(b.copyWith(description: 'changed'));
      expect(await repo.confirmBatchArchived(b.id, b.updatedAt), isFalse);
      expect((await repo.getBatchById(b.id))!.status, 'Active');
      expect(await repo.confirmBatchArchived(b.id, edited.updatedAt), isTrue);
    });

    test('an incomplete batch can not be archived', () async {
      final b = await create();
      final draft = await repo.updateBatch(b.copyWith(expectedCount: 0));
      expect(await repo.confirmBatchArchived(b.id, draft.updatedAt), isFalse);
    });

    test('editing or scanning into an Archived batch re-evaluates it (Active) and keeps its scans', () async {
      var b = await withScan(await create());
      await repo.confirmBatchArchived(b.id, b.updatedAt);
      b = (await repo.getBatchById(b.id))!;
      expect(b.status, 'Archived');

      final edited = await repo.updateBatch(b.copyWith(description: 'late fix'));
      expect(edited.status, 'Active');
      expect(edited.scans, hasLength(1), reason: 'archiving/editing never deletes local scans');

      await repo.confirmBatchArchived(b.id, edited.updatedAt);
      final again = await withScan((await repo.getBatchById(b.id))!);
      expect(again.status, 'Active');
      expect(again.scans, hasLength(2));
    });

    test('a legacy Archived batch stays Archived until it is edited', () async {
      final b = await create();
      // Simulate a record written by an older build.
      await repo.upsertBatchFromCloud(b.copyWith(status: 'Archived', updatedAt: b.updatedAt.add(const Duration(days: 1))));
      final loaded = (await repo.getBatchById(b.id))!;
      expect(loaded.status, 'Archived');
    });
  });

  group('answer corrections', () {
    test('are persisted with the recalculated result and survive a restart', () async {
      var b = await withScan(await create());
      final scanId = b.scans.single.id;
      final updated = await repo.updateScanCorrections(
        batchId: b.id,
        scanId: scanId,
        corrections: [_correction(scanId: scanId)],
        result: _result(1),
      );
      expect(updated.scans.single.result!.rawScore, 1);
      expect(updated.updatedAt.isAfter(b.updatedAt), isTrue, reason: 'a correction is a new revision to sync');

      // "Restart": a brand-new repository reading the same folder.
      final reloaded = (await newRepo().getBatchById(b.id))!.scans.single;
      expect(reloaded.corrections, hasLength(1));
      expect(reloaded.result!.rawScore, 1);
      expect(reloaded.decoded.items.first.markedChoice, 'B', reason: 'detected answer is never overwritten');
      expect(reloaded.effectiveDecoded.items.first.markedChoice, 'A');
    });

    test('a repeated or duplicate request records nothing and does not bump the revision', () async {
      final b = await withScan(await create());
      final scanId = b.scans.single.id;
      final once = await repo.updateScanCorrections(
        batchId: b.id,
        scanId: scanId,
        corrections: [_correction(scanId: scanId)],
        result: _result(1),
      );
      final twice = await repo.updateScanCorrections(
        batchId: b.id,
        scanId: scanId,
        corrections: [_correction(scanId: scanId)],
        result: _result(1),
      );
      expect(twice.scans.single.corrections, hasLength(1));
      expect(twice.updatedAt, once.updatedAt);
    });

    test('history is append-only: a write that omits stored entries does not drop them', () async {
      final b = await withScan(await create());
      final scanId = b.scans.single.id;
      await repo.updateScanCorrections(
        batchId: b.id,
        scanId: scanId,
        corrections: [_correction(id: 'a', scanId: scanId)],
        result: _result(1),
      );
      final after = await repo.updateScanCorrections(
        batchId: b.id,
        scanId: scanId,
        corrections: [_correction(id: 'b', scanId: scanId)],
        result: _result(1),
      );
      expect(after.scans.single.corrections.map((c) => c.id), containsAll(['a', 'b']));
    });

    test('a correction made against an older capture is refused', () async {
      final b = await withScan(await create());
      final scanId = b.scans.single.id;
      expect(
        () => repo.updateScanCorrections(
          batchId: b.id,
          scanId: scanId,
          corrections: [_correction(scanId: scanId, revision: 7)],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a rescan keeps the history, bumps the capture revision and applies nothing silently', () async {
      var b = await withScan(await create());
      final scanId = b.scans.single.id;
      await repo.updateScanCorrections(
        batchId: b.id,
        scanId: scanId,
        corrections: [_correction(scanId: scanId)],
        result: _result(1),
      );
      final src = File('${tempDir.path}/re.jpg')..writeAsBytesSync(const [4, 5, 6]);
      b = await repo.replaceScan(batchId: b.id, scanId: scanId, decoded: _decoded, sourceImage: src, result: _result(0));
      final scan = b.scans.single;
      expect(scan.captureRevision, 1);
      expect(scan.corrections, hasLength(1), reason: 'history preserved');
      expect(scan.activeCorrections, isEmpty, reason: 'old correction not applied to the new capture');
      expect(scan.correctionsNeedingReview, hasLength(1));
    });

    test('correcting an answer never touches the student details or the batch fields', () async {
      var b = await withScan(await create());
      final scanId = b.scans.single.id;
      b = await repo.setScanExaminee(
        batchId: b.id,
        scanId: scanId,
        examinee: ExamineeInfo(
          firstName: 'Ana',
          lastName: 'Cruz',
          examineeNumber: '7',
          birthDate: DateTime(2010, 3, 4),
          lastSchool: 'NDMU High',
        ),
      );
      final after = await repo.updateScanCorrections(
        batchId: b.id,
        scanId: scanId,
        corrections: [_correction(scanId: scanId)],
        result: _result(1),
      );
      final e = after.scans.single.examinee!;
      expect(e.lastName, 'Cruz');
      expect(e.birthDate, DateTime(2010, 3, 4));
      expect(e.lastSchool, 'NDMU High');
      expect(after.expectedCount, b.expectedCount);
    });
  });

  group('student details persistence', () {
    test('birth date, age-only and last school round-trip through the manifest', () async {
      var b = await withScan(await create());
      final scanId = b.scans.single.id;
      await repo.setScanExaminee(
        batchId: b.id,
        scanId: scanId,
        examinee: ExamineeInfo(
          firstName: '',
          lastName: '',
          examineeNumber: '',
          birthDate: DateTime(2009, 12, 31),
          lastSchool: 'Some School',
        ),
      );
      var e = (await newRepo().getBatchById(b.id))!.scans.single.examinee!;
      expect(e.birthDate, DateTime(2009, 12, 31));
      expect(e.lastSchool, 'Some School');

      await repo.setScanExaminee(
        batchId: b.id,
        scanId: scanId,
        examinee: const ExamineeInfo(firstName: 'A', lastName: 'B', examineeNumber: '1', manualAge: 16),
      );
      e = (await newRepo().getBatchById(b.id))!.scans.single.examinee!;
      expect(e.manualAge, 16);
      expect(e.birthDate, isNull);
    });
  });
}
