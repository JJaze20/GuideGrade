import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_crypto_service.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/sync/cloud_batch_mapper.dart';
import 'package:guidegrade/core/sync/cloud_restore_service.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// Test-only crypto -- see sync_manager_test.dart's identical fake.
class _FakeBatchCryptoService extends BatchCryptoService {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async =>
      Uint8List.fromList(plaintext);
  @override
  Future<Uint8List> decrypt(Uint8List packed) async =>
      Uint8List.fromList(packed);
}

/// Fully configurable fake [SyncClient] for CloudRestoreService tests. Push
/// methods are never expected to be called by this feature and throw if
/// they are.
class _FakeCloudSyncClient implements SyncClient {
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByBatchId = {};
  final Map<String, List<int>> imagesByKey = {}; // '$batchId/$scanId/$rectified'
  final List<String> calls = [];

  Never _no() => throw StateError('push must not be called by CloudRestoreService');

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('readCloudBatches');
    return batchesToReturn;
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    calls.add('readCloudScans:$batchId');
    return scansByBatchId[batchId] ?? CloudScansRead.found(const []);
  }

  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) async {
    calls.add('downloadScanImage:$batchId/$scanId/$rectified');
    final bytes = imagesByKey['$batchId/$scanId/$rectified'];
    if (bytes == null) return const CloudImageRead.absent();
    return CloudImageRead.found(bytes);
  }

  @override
  Future<SyncOutcome> pushBatch(String batchId) => _no();
  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId,
          {Map<String, String> meta = const {}}) =>
      _no();
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _no();
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) => _no();
  @override
  Future<SyncOutcome> pushAnswerKey(String examCode,
          {Map<String, String> meta = const {}}) =>
      _no();
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) => _no();
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no();
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no();
  @override
  Future<CloudExamineesRead> readCloudExaminees() => _no();
  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no();
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no();
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) => _no();
  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) =>
      _no();
  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) =>
      _no();

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() =>
      _no();

  @override
  Future<SyncOutcome> archiveBatch({
    required String batchId,
    String? reason,
  }) =>
      _no();

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) =>
      _no();

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) => _no();
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no();
}

CloudBatchRow _cloudBatchRow({
  String id = 'b_cloud',
  String examCode = 'AT',
  DateTime? updatedAt,
}) =>
    CloudBatchRow(
      id: id,
      batchCode: 'B-CLOUD',
      examCode: examCode,
      examTitle: 'Aptitude',
      description: 'from cloud',
      expectedCount: 50,
      status: 'Active',
      createdByUid: 'cloud-uid',
      createdByName: 'Cloud Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
    );

CloudScanRow _cloudScanRow({
  required String id,
  required String batchId,
  String examCode = 'AT',
  int rawScore = 50,
  bool imageUploaded = false,
  bool rectifiedUploaded = false,
  String? rectifiedImagePath,
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: rawScore,
      totalGraded: 72,
      totalItems: 72,
      resultStatus: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'cloud-uid',
      processedByName: 'Cloud Officer',
      imagePath: 'batches/$batchId/scans/$id/original.jpg',
      imageUploaded: imageUploaded,
      rectifiedImagePath: rectifiedImagePath,
      rectifiedImageUploaded: rectifiedUploaded,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalBatchRepository batchRepo;
  late SyncQueue queue;
  late _FakeCloudSyncClient client;
  late CloudRestoreService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cloud_restore_service_test_');
    batchRepo = LocalBatchRepository(
      rootOverride: Directory('${tempDir.path}/batches'),
      crypto: _FakeBatchCryptoService(),
    );
    queue = SyncQueue(rootOverride: Directory('${tempDir.path}/queue'));
    client = _FakeCloudSyncClient();
    service = CloudRestoreService(
      client: client,
      repository: batchRepo,
      syncQueue: queue,
      loadAnswerKeys: () async => <String, AnswerKey>{},
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('1. cloud-only batch is restored, with SyncState seeded so it is never re-pushed', () async {
    final row = _cloudBatchRow();
    client.batchesToReturn = CloudBatchesRead.found([row]);
    client.scansByBatchId[row.id] = CloudScansRead.found([
      _cloudScanRow(id: 's1', batchId: row.id, imageUploaded: true),
    ]);

    final summary = await service.restoreAll();

    expect(summary.isSuccess, isTrue);
    expect(summary.cloudBatchesFound, 1);
    expect(summary.batchesRestored, 1);
    expect(summary.batchesUpdated, 0);
    expect(summary.scansRestored, 1);

    final local = await batchRepo.getBatchById(row.id);
    expect(local, isNotNull);
    expect(local!.scans, hasLength(1));

    // SyncState seeded -- no redundant PUSH after restore.
    expect(queue.state.batchLastPushedUpdatedAt(row.id), row.updatedAt);
    expect(queue.state.scanOriginalUploaded(row.id, 's1'), isTrue);
  });

  test('2. cloud batch + local batch: strictly-newer cloud metadata is merged, count reflects "updated"', () async {
    final created = await batchRepo.createBatch(
      batchCode: 'B-LOCAL',
      examCode: 'AT',
      examTitle: 'Local',
      description: 'd',
      expectedCount: 10,
      createdByUid: 'uid',
      createdByName: 'Officer',
    );
    final row = _cloudBatchRow(
      id: created.id,
      updatedAt: created.updatedAt.add(const Duration(minutes: 1)),
    );
    client.batchesToReturn = CloudBatchesRead.found([row]);

    final summary = await service.restoreAll();

    expect(summary.batchesRestored, 0);
    expect(summary.batchesUpdated, 1);
    final local = await batchRepo.getBatchById(created.id);
    expect(local!.batchCode, 'B-CLOUD');
  });

  test('3 & 4. cloud scan missing locally is added; local-only scan is preserved', () async {
    final row = _cloudBatchRow();
    await batchRepo.upsertBatchFromCloud(mapCloudBatch(row));
    final src = File('${tempDir.path}/local_only.jpg')..writeAsBytesSync(const [1, 2, 3]);
    await batchRepo.addScan(
      batchId: row.id,
      decoded: const OmrScanResult(examCode: 'AT', items: []),
      sourceImage: src,
    );
    final beforeLocal = await batchRepo.getBatchById(row.id);
    final localOnlyId = beforeLocal!.scans.single.id;

    client.batchesToReturn = CloudBatchesRead.found([row]);
    client.scansByBatchId[row.id] = CloudScansRead.found([
      _cloudScanRow(id: 's_from_cloud', batchId: row.id),
    ]);

    final summary = await service.restoreAll();
    expect(summary.scansRestored, 1);

    final after = await batchRepo.getBatchById(row.id);
    final ids = after!.scans.map((s) => s.id).toSet();
    expect(ids, {localOnlyId, 's_from_cloud'});
  });

  test('5. CRITICAL: duplicate scan id -- the existing local scan is never touched', () async {
    final row = _cloudBatchRow();
    await batchRepo.upsertBatchFromCloud(mapCloudBatch(row));
    final src = File('${tempDir.path}/local.jpg')..writeAsBytesSync(const [7, 7, 7]);
    final withScan = await batchRepo.addScan(
      batchId: row.id,
      decoded: const OmrScanResult(examCode: 'AT', items: []),
      sourceImage: src,
      examinee: const ExamineeInfo(firstName: 'Local', lastName: 'Kid', examineeNumber: 'L-1'),
    );
    final sharedId = withScan.scans.single.id;

    client.batchesToReturn = CloudBatchesRead.found([row]);
    client.scansByBatchId[row.id] = CloudScansRead.found([
      _cloudScanRow(id: sharedId, batchId: row.id, rawScore: 999),
    ]);

    final summary = await service.restoreAll();
    expect(summary.scansRestored, 0); // it already existed -- not "restored"

    final after = await batchRepo.getBatchById(row.id);
    expect(after!.scans, hasLength(1));
    expect(after.scans.single.examinee?.firstName, 'Local');
  });

  test('7. a batch with a pending DELETE_BATCH job is skipped entirely this pass', () async {
    final row = _cloudBatchRow();
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.deleteBatch,
      entityId: row.id,
      batchId: row.id,
    ));
    client.batchesToReturn = CloudBatchesRead.found([row]);

    final summary = await service.restoreAll();

    expect(summary.batchesSkippedPendingDelete, 1);
    expect(summary.batchesRestored, 0);
    expect(await batchRepo.getBatchById(row.id), isNull);
  });

  test('8. offline restore: readCloudBatches failure surfaces as a failed summary, writes nothing', () async {
    client.batchesToReturn = const CloudBatchesRead.failed(SyncOutcome.transient('network'));

    final summary = await service.restoreAll();

    expect(summary.isSuccess, isFalse);
    expect(summary.error, const SyncOutcome.transient('network'));
    expect(await batchRepo.getBatches(), isEmpty);
  });

  test('14. no redundant image upload after restore: SyncState only marks uploaded when the cloud row says so', () async {
    final row = _cloudBatchRow();
    client.batchesToReturn = CloudBatchesRead.found([row]);
    client.scansByBatchId[row.id] = CloudScansRead.found([
      _cloudScanRow(id: 's_incomplete', batchId: row.id, imageUploaded: false),
    ]);

    await service.restoreAll();

    // The cloud row itself reported an incomplete upload -- SyncState must
    // NOT be seeded as uploaded, so SyncManager still re-queues it.
    expect(queue.state.scanOriginalUploaded(row.id, 's_incomplete'), isFalse);
  });

  test('15. running restoreAll twice never duplicates batches or scans', () async {
    final row = _cloudBatchRow();
    client.batchesToReturn = CloudBatchesRead.found([row]);
    client.scansByBatchId[row.id] = CloudScansRead.found([
      _cloudScanRow(id: 's1', batchId: row.id),
    ]);

    await service.restoreAll();
    await service.restoreAll();

    final all = await batchRepo.getBatches();
    expect(all, hasLength(1));
    expect(all.single.scans.where((s) => s.id == 's1'), hasLength(1));
  });

  group('restoreImageIfMissing', () {
    test('9. downloads, encrypts, and writes when the local image is absent', () async {
      final row = _cloudBatchRow();
      final batch = await batchRepo.upsertBatchFromCloud(mapCloudBatch(row));
      final scan = (await batchRepo.upsertScanFromCloud(
        batchId: batch.id,
        scan: mapCloudScan(_cloudScanRow(id: 's_img', batchId: batch.id)),
      ))
          .scans
          .single;

      client.imagesByKey['${batch.id}/${scan.id}/false'] = [10, 20, 30];

      final before = await batchRepo.resolveScanImage(batch.id, scan);
      expect(before, isNull);

      final restored = await service.restoreImageIfMissing(
        batchId: batch.id,
        scan: scan,
        rectified: false,
      );
      expect(restored, isTrue);

      final after = await batchRepo.resolveScanImage(batch.id, scan);
      expect(after, [10, 20, 30]);
    });

    test('never re-downloads when the local image already exists', () async {
      final row = _cloudBatchRow();
      final batch = await batchRepo.upsertBatchFromCloud(mapCloudBatch(row));
      final src = File('${tempDir.path}/already_have.jpg')..writeAsBytesSync(const [1, 1, 1]);
      final withScan = await batchRepo.addScan(
        batchId: batch.id,
        decoded: const OmrScanResult(examCode: 'AT', items: []),
        sourceImage: src,
      );
      final scan = withScan.scans.single;

      final restored = await service.restoreImageIfMissing(
        batchId: batch.id,
        scan: scan,
        rectified: false,
      );

      expect(restored, isFalse);
      expect(client.calls.any((c) => c.startsWith('downloadScanImage')), isFalse);
    });

    test('10. missing image in Storage (absent) leaves the local file unwritten, no crash', () async {
      final row = _cloudBatchRow();
      final batch = await batchRepo.upsertBatchFromCloud(mapCloudBatch(row));
      final scan = (await batchRepo.upsertScanFromCloud(
        batchId: batch.id,
        scan: mapCloudScan(_cloudScanRow(id: 's_missing', batchId: batch.id)),
      ))
          .scans
          .single;

      // No entry seeded in client.imagesByKey -- downloadScanImage returns absent().
      final restored = await service.restoreImageIfMissing(
        batchId: batch.id,
        scan: scan,
        rectified: false,
      );

      expect(restored, isFalse);
      expect(await batchRepo.resolveScanImage(batch.id, scan), isNull);
    });

    test('rectified image with no rectifiedImageFileName is a no-op, never calls the network', () async {
      final row = _cloudBatchRow();
      final batch = await batchRepo.upsertBatchFromCloud(mapCloudBatch(row));
      final scan = (await batchRepo.upsertScanFromCloud(
        batchId: batch.id,
        scan: mapCloudScan(_cloudScanRow(id: 's_no_rect', batchId: batch.id)),
      ))
          .scans
          .single;
      expect(scan.rectifiedImageFileName, isNull);

      final restored = await service.restoreImageIfMissing(
        batchId: batch.id,
        scan: scan,
        rectified: true,
      );

      expect(restored, isFalse);
      expect(client.calls, isEmpty);
    });
  });
}
