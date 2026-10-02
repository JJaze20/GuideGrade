import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_crypto_service.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// Test-only crypto implementation — see sync_manager_test.dart's identical
/// fake for why (flutter_secure_storage needs a real platform channel).
class _FakeBatchCryptoService extends BatchCryptoService {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async =>
      Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> decrypt(Uint8List packed) async =>
      Uint8List.fromList(packed);
}

LocalScan _scan(String id, {LocalScanResult? result, ExamineeInfo? examinee}) =>
    LocalScan(
      id: id,
      imageFileName: 'images/$id.enc',
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: const OmrScanResult(examCode: 'AT', items: []),
      result: result,
      examinee: examinee,
    );

LocalBatch _cloudBatch({
  String id = 'b_cloud_1',
  String batchCode = 'B-CLOUD-1',
  String examCode = 'AT',
  String examTitle = 'Aptitude',
  String description = 'from cloud',
  int expectedCount = 50,
  String status = 'Active',
  String createdByUid = 'uid-cloud',
  String createdByName = 'Cloud Officer',
  DateTime? createdAt,
  DateTime? updatedAt,
}) =>
    LocalBatch(
      id: id,
      batchCode: batchCode,
      examCode: examCode,
      examTitle: examTitle,
      description: description,
      expectedCount: expectedCount,
      status: status,
      createdByUid: createdByUid,
      createdByName: createdByName,
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalBatchRepository repo;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_batch_cloud_restore_test_');
    repo = LocalBatchRepository(
      rootOverride: Directory('${tempDir.path}/batches'),
      crypto: _FakeBatchCryptoService(),
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('upsertBatchFromCloud', () {
    test('A. creates a new local batch at the cloud id when none exists locally', () async {
      final cloud = _cloudBatch();
      final result = await repo.upsertBatchFromCloud(cloud);

      expect(result.id, cloud.id);
      expect(result.batchCode, cloud.batchCode);
      expect(result.createdByUid, cloud.createdByUid);
      expect(result.scans, isEmpty);

      final stored = await repo.getBatchById(cloud.id);
      expect(stored, isNotNull);
      expect(stored!.id, cloud.id);
    });

    test('B. cloud strictly newer merges only mutable metadata, never audit fields or scans', () async {
      final created = await repo.createBatch(
        batchCode: 'B-LOCAL',
        examCode: 'AT',
        examTitle: 'Local Title',
        description: 'local description',
        expectedCount: 10,
        createdByUid: 'uid-local',
        createdByName: 'Local Officer',
      );
      final src = File('${tempDir.path}/src.jpg')..writeAsBytesSync(const [1, 2, 3]);
      final withScan = await repo.addScan(
        batchId: created.id,
        decoded: const OmrScanResult(examCode: 'AT', items: []),
        sourceImage: src,
      );
      expect(withScan.scans, hasLength(1));

      final newerCloud = _cloudBatch(
        id: created.id,
        batchCode: 'B-CLOUD-RENAMED',
        examTitle: 'Cloud Title',
        description: 'cloud description',
        expectedCount: 999,
        status: 'Completed',
        createdByUid: 'someone-else-uid',
        createdByName: 'Someone Else',
        createdAt: DateTime.utc(2000),
        updatedAt: withScan.updatedAt.add(const Duration(minutes: 5)),
      );

      final merged = await repo.upsertBatchFromCloud(newerCloud);

      // Mutable metadata: taken from the cloud.
      expect(merged.batchCode, 'B-CLOUD-RENAMED');
      expect(merged.examTitle, 'Cloud Title');
      expect(merged.description, 'cloud description');
      expect(merged.expectedCount, 999);
      expect(merged.status, 'Completed');

      // Audit fields: never overwritten, even though the cloud row carried
      // different values.
      expect(merged.createdByUid, 'uid-local');
      expect(merged.createdByName, 'Local Officer');
      expect(merged.createdAt, created.createdAt);

      // Scans: never touched by a batch-level merge.
      expect(merged.scans, hasLength(1));
      expect(merged.scans.first.id, withScan.scans.first.id);
    });

    test('cloud not strictly newer (tie or older) leaves the local batch completely untouched', () async {
      final created = await repo.createBatch(
        batchCode: 'B-LOCAL',
        examCode: 'AT',
        examTitle: 'Local Title',
        description: 'local description',
        expectedCount: 10,
        createdByUid: 'uid-local',
        createdByName: 'Local Officer',
      );

      final tieCloud = _cloudBatch(
        id: created.id,
        batchCode: 'SHOULD-NOT-APPLY',
        updatedAt: created.updatedAt, // exact tie
      );
      final tieResult = await repo.upsertBatchFromCloud(tieCloud);
      expect(tieResult.batchCode, 'B-LOCAL');

      final olderCloud = _cloudBatch(
        id: created.id,
        batchCode: 'SHOULD-NOT-APPLY-EITHER',
        updatedAt: created.updatedAt.subtract(const Duration(days: 1)),
      );
      final olderResult = await repo.upsertBatchFromCloud(olderCloud);
      expect(olderResult.batchCode, 'B-LOCAL');
    });
  });

  group('upsertScanFromCloud', () {
    test('throws StateError when the batch does not exist locally', () async {
      expect(
        () => repo.upsertScanFromCloud(batchId: 'no-such-batch', scan: _scan('s1')),
        throwsA(isA<StateError>()),
      );
    });

    test('appends a cloud scan id that does not exist locally', () async {
      final batch = await repo.upsertBatchFromCloud(_cloudBatch());
      expect(batch.scans, isEmpty);

      final updated = await repo.upsertScanFromCloud(
        batchId: batch.id,
        scan: _scan('s_cloud_1'),
      );

      expect(updated.scans, hasLength(1));
      expect(updated.scans.first.id, 's_cloud_1');

      final reread = await repo.getBatchById(batch.id);
      expect(reread!.scans.map((s) => s.id), ['s_cloud_1']);
    });

    test('CRITICAL: an existing local scan with the same id is never overwritten or merged', () async {
      final batch = await repo.upsertBatchFromCloud(_cloudBatch());
      final src = File('${tempDir.path}/local_src.jpg')..writeAsBytesSync(const [9, 9, 9]);
      final withLocalScan = await repo.addScan(
        batchId: batch.id,
        decoded: const OmrScanResult(examCode: 'AT', items: []),
        sourceImage: src,
        examinee: const ExamineeInfo(
          firstName: 'Local',
          lastName: 'Student',
          examineeNumber: 'L-1',
        ),
      );
      final localScanId = withLocalScan.scans.single.id;
      final localScanBefore = withLocalScan.scans.single;

      // A cloud scan arrives claiming the SAME id, with completely
      // different content (different examinee, different result).
      final conflictingCloudScan = _scan(
        localScanId,
        result: LocalScanResult(
          rawScore: 999,
          totalGraded: 999,
          totalItems: 999,
          percentage: 100,
          status: 'Graded',
          scannedAt: DateTime.utc(2030),
          processedByUid: 'cloud-uid',
          processedByName: 'Cloud Person',
        ),
        examinee: const ExamineeInfo(
          firstName: 'Cloud',
          lastName: 'Impostor',
          examineeNumber: 'C-999',
        ),
      );

      final result = await repo.upsertScanFromCloud(
        batchId: batch.id,
        scan: conflictingCloudScan,
      );

      // Still exactly one scan, and it is byte-for-byte the ORIGINAL local
      // one -- not merged, not overwritten, not duplicated.
      expect(result.scans, hasLength(1));
      final survivingScan = result.scans.single;
      expect(survivingScan.id, localScanId);
      expect(survivingScan.examinee?.firstName, 'Local');
      expect(survivingScan.examinee?.lastName, 'Student');
      expect(survivingScan.result, isNull); // addScan was called with no result
      expect(survivingScan.imageFileName, localScanBefore.imageFileName);

      // Re-read from disk to make sure nothing was persisted either.
      final reread = await repo.getBatchById(batch.id);
      expect(reread!.scans, hasLength(1));
      expect(reread.scans.single.examinee?.firstName, 'Local');
    });

    test('idempotent: restoring the same cloud scan twice never duplicates it', () async {
      final batch = await repo.upsertBatchFromCloud(_cloudBatch());
      final scan = _scan('s_dup_check');

      await repo.upsertScanFromCloud(batchId: batch.id, scan: scan);
      final second = await repo.upsertScanFromCloud(batchId: batch.id, scan: scan);

      expect(second.scans.where((s) => s.id == 's_dup_check'), hasLength(1));
    });

    test('local-only scans are preserved alongside newly restored cloud scans', () async {
      final batch = await repo.upsertBatchFromCloud(_cloudBatch());
      final src = File('${tempDir.path}/local_only.jpg')..writeAsBytesSync(const [4, 5, 6]);
      final withLocalScan = await repo.addScan(
        batchId: batch.id,
        decoded: const OmrScanResult(examCode: 'AT', items: []),
        sourceImage: src,
      );
      final localScanId = withLocalScan.scans.single.id;

      final updated = await repo.upsertScanFromCloud(
        batchId: batch.id,
        scan: _scan('s_from_cloud_only'),
      );

      final ids = updated.scans.map((s) => s.id).toSet();
      expect(ids, {localScanId, 's_from_cloud_only'});
    });
  });
}
