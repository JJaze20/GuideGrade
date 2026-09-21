import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_manager.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/core/sync/syncing_batch_repository.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

// --- fixtures ---------------------------------------------------------------

LocalScan _scan(String id, {bool rectified = false, ExamineeInfo? examinee}) =>
    LocalScan(
      id: id,
      imageFileName: 'images/$id.jpg',
      rectifiedImageFileName: rectified ? 'images/${id}_rectified.jpg' : null,
      capturedAt: DateTime.utc(2026),
      decoded: const OmrScanResult(examCode: 'AT', items: []),
      examinee: examinee,
    );

const _examinee = ExamineeInfo(
  firstName: 'Juan',
  lastName: 'Test',
  examineeNumber: 'X-1',
);

LocalBatch _batch({String id = 'b1', List<LocalScan> scans = const []}) =>
    LocalBatch(
      id: id,
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: '',
      expectedCount: 10,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      scans: scans,
    );

const _decoded = OmrScanResult(examCode: 'AT', items: []);
final _result = LocalScanResult(
  rawScore: 1,
  totalGraded: 1,
  totalItems: 1,
  percentage: 100,
  status: 'Graded',
  scannedAt: DateTime.utc(2026),
  processedByUid: 'uid',
  processedByName: 'Officer',
);

/// Fake local repository: records calls, returns [batchResult], and can be
/// told to throw for a given method. No disk, no network.
class _FakeLocal implements LocalBatchRepository {
  final List<String> calls = [];
  final Map<String, Object> failWith = {};
  LocalBatch batchResult = _batch();
  void Function()? onDeleteBatch;

  void _maybeThrow(String method) {
    final err = failWith[method];
    if (err != null) throw err;
  }

  @override
  Directory? get rootOverride => null;

  @override
  Future<List<LocalBatch>> getBatches() async {
    calls.add('getBatches');
    return [batchResult];
  }

  @override
  Future<LocalBatch?> getBatchById(String id) async {
    calls.add('getBatchById:$id');
    return batchResult;
  }

  @override
  Future<List<LocalBatch>> getBatchesByExamCode(String examCode) async {
    calls.add('getBatchesByExamCode:$examCode');
    return [batchResult];
  }

  @override
  Future<Uint8List?> resolveScanImage(String batchId, LocalScan scan) async {
    calls.add('resolveScanImage:$batchId/${scan.id}');
    return Uint8List(0);
  }

  @override
  Future<Uint8List?> resolveScanRectifiedImage(String batchId, LocalScan scan) async {
    calls.add('resolveScanRectifiedImage:$batchId/${scan.id}');
    return null;
  }

  @override
  Future<Uint8List?> resolveScanNameCropLast(String batchId, LocalScan scan) async {
    calls.add('resolveScanNameCropLast:$batchId/${scan.id}');
    return null;
  }

  @override
  Future<Uint8List?> resolveScanNameCropFirst(String batchId, LocalScan scan) async {
    calls.add('resolveScanNameCropFirst:$batchId/${scan.id}');
    return null;
  }

  @override
  Future<Uint8List?> resolveScanNameCropMiddle(String batchId, LocalScan scan) async {
    calls.add('resolveScanNameCropMiddle:$batchId/${scan.id}');
    return null;
  }

  @override
  Future<LocalBatch> createBatch({
    required String batchCode,
    required String examCode,
    required String examTitle,
    required String description,
    required int expectedCount,
    required String createdByUid,
    required String createdByName,
  }) async {
    calls.add('createBatch');
    _maybeThrow('createBatch');
    return batchResult;
  }

  @override
  Future<LocalBatch> updateBatch(LocalBatch batch) async {
    calls.add('updateBatch:${batch.id}');
    _maybeThrow('updateBatch');
    return batchResult;
  }

  @override
  Future<void> deleteBatch(String id) async {
    calls.add('deleteBatch:$id');
    onDeleteBatch?.call();
    _maybeThrow('deleteBatch');
  }

  @override
  Future<LocalBatch> addScan({
    required String batchId,
    required OmrScanResult decoded,
    required File sourceImage,
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    File? nameCropLastImage,
    File? nameCropFirstImage,
    File? nameCropMiddleImage,
  }) async {
    calls.add('addScan:$batchId');
    _maybeThrow('addScan');
    return batchResult;
  }

  @override
  Future<LocalBatch> replaceScan({
    required String batchId,
    required String scanId,
    required OmrScanResult decoded,
    required File sourceImage,
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    File? nameCropLastImage,
    File? nameCropFirstImage,
    File? nameCropMiddleImage,
  }) async {
    calls.add('replaceScan:$batchId/$scanId');
    _maybeThrow('replaceScan');
    return batchResult;
  }

  @override
  Future<LocalBatch> attachResult({
    required String batchId,
    required String scanId,
    required LocalScanResult result,
  }) async {
    calls.add('attachResult:$batchId/$scanId');
    _maybeThrow('attachResult');
    return batchResult;
  }

  @override
  Future<LocalBatch> deleteScan({
    required String batchId,
    required String scanId,
  }) async {
    calls.add('deleteScan:$batchId/$scanId');
    _maybeThrow('deleteScan');
    return batchResult;
  }

  @override
  Future<LocalBatch> setScanExaminee({
    required String batchId,
    required String scanId,
    ExamineeInfo? examinee,
  }) async {
    calls.add('setScanExaminee:$batchId/$scanId');
    _maybeThrow('setScanExaminee');
    return batchResult;
  }

  /// Whether the fake treats updateScanCorrections as a real change (moves
  /// the batch revision) or a no-op (a repeated request).
  bool correctionsChangeBatch = true;

  @override
  Future<LocalBatch> updateScanCorrections({
    required String batchId,
    required String scanId,
    required List<AnswerCorrection> corrections,
    LocalScanResult? result,
  }) async {
    calls.add('updateScanCorrections:$batchId/$scanId');
    _maybeThrow('updateScanCorrections');
    if (correctionsChangeBatch) {
      batchResult = batchResult.copyWith(
        updatedAt: batchResult.updatedAt.add(const Duration(milliseconds: 1)),
      );
    }
    return batchResult;
  }

  @override
  Future<bool> confirmBatchArchived(String batchId, DateTime confirmedUpdatedAt) async {
    calls.add('confirmBatchArchived:$batchId');
    return true;
  }

  @override
  Future<LocalBatch> upsertBatchFromCloud(LocalBatch batch) async {
    calls.add('upsertBatchFromCloud:${batch.id}');
    _maybeThrow('upsertBatchFromCloud');
    return batchResult;
  }

  @override
  Future<LocalBatch> upsertScanFromCloud({
    required String batchId,
    required LocalScan scan,
  }) async {
    calls.add('upsertScanFromCloud:$batchId/${scan.id}');
    _maybeThrow('upsertScanFromCloud');
    return batchResult;
  }

  @override
  Future<void> writeRestoredScanImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  }) async {
    calls.add('writeRestoredScanImage:$batchId/$scanId');
    _maybeThrow('writeRestoredScanImage');
  }

  @override
  Future<void> writeRestoredScanRectifiedImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  }) async {
    calls.add('writeRestoredScanRectifiedImage:$batchId/$scanId');
    _maybeThrow('writeRestoredScanRectifiedImage');
  }
}

/// A [SyncClient] that must never be called by the repository.
class _NeverSyncClient implements SyncClient {
  final List<String> calls = [];

  Future<SyncOutcome> _rec(String method) async {
    calls.add(method);
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<SyncOutcome> pushBatch(String batchId) => _rec('pushBatch');
  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId,
          {Map<String, String> meta = const {}}) =>
      _rec('pushScan');
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _rec('uploadImage');
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) =>
      _rec('patchImageStatus');
  @override
  Future<SyncOutcome> pushAnswerKey(String examCode,
          {Map<String, String> meta = const {}}) =>
      _rec('pushAnswerKey');
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    calls.add('readAnswerKey');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('readCloudBatches');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    calls.add('readCloudScans');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) async {
    calls.add('downloadScanImage');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _rec('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _rec('deleteScan');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) =>
      _rec('deleteStoragePrefix');

  @override
  Future<CloudExamineesRead> readCloudExaminees() async {
    calls.add('readCloudExaminees');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    calls.add('createExamineeFromScan');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    calls.add('updateCloudExaminee');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) async {
    calls.add('setExamineeArchived');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) =>
      _rec('linkScanToExaminee');

  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) async {
    calls.add('unlinkScanFromExaminee');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async {
    calls.add('readBatchArchives');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<SyncOutcome> archiveBatch({
    required String batchId,
    String? reason,
  }) async {
    calls.add('archiveBatch');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) async {
    calls.add('readScanCounts');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) async {
    calls.add('readCloudScansForExaminee');
    throw StateError('SyncingBatchRepository must not call the network client');
  }

  @override
  Future<CloudScansRead> readUnlinkedScans() async {
    calls.add('readUnlinkedScans');
    throw StateError('SyncingBatchRepository must not call the network client');
  }
}

/// Real [SyncQueue] under the hood, but every drain entry point is stubbed
/// so a test can assert the repository never triggers processing.
class _SpySyncManager extends SyncManager {
  _SpySyncManager({
    required super.queue,
    required super.client,
    required super.batchRepository,
    required super.loadAnswerKeys,
  });

  int processQueueCalls = 0;
  int startCalls = 0;
  int syncNowCalls = 0;
  int wakeCalls = 0;

  /// When set, each [wake] call blocks on it — lets a test prove the
  /// repository does not await wake().
  Completer<void>? wakeGate;

  @override
  Future<void> processQueue() async => processQueueCalls++;
  @override
  Future<void> start() async => startCalls++;
  @override
  Future<void> syncNow() async => syncNowCalls++;
  @override
  Future<void> wake() async {
    wakeCalls++;
    final gate = wakeGate;
    if (gate != null) await gate.future;
  }
}

/// A [SyncQueue] whose enqueue/cancel always fail (disk-full simulation).
class _ThrowingQueue extends SyncQueue {
  _ThrowingQueue(Directory root) : super(rootOverride: root);

  @override
  Future<SyncJob?> enqueue(SyncJob job) async =>
      throw const FileSystemException('disk full');

  @override
  Future<int> cancelPushesForBatch(String batchId) async =>
      throw const FileSystemException('disk full');
}

void main() {
  late Directory tempDir;
  late SyncQueue queue;
  late _FakeLocal fakeLocal;
  late _NeverSyncClient neverClient;
  late _SpySyncManager spyManager;
  late SyncingBatchRepository repo;

  SyncQueue makeQueue([Directory? root]) => SyncQueue(
        rootOverride: root ?? Directory('${tempDir.path}/queue'),
        clock: () => DateTime.utc(2026),
      );

  void rebuild(SyncQueue q) {
    queue = q;
    spyManager = _SpySyncManager(
      queue: queue,
      client: neverClient,
      batchRepository: fakeLocal,
      loadAnswerKeys: () async => <String, AnswerKey>{},
    );
    repo = SyncingBatchRepository(local: fakeLocal, syncManager: spyManager);
  }

  Future<void> waitForJobs(int n) async {
    for (var i = 0; i < 400 && queue.jobs.length < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> waitForWake([int n = 1]) async {
    for (var i = 0; i < 400 && spyManager.wakeCalls < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A brief settle so a would-be *second* wake / extra enqueue would show.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  Future<void> waitUntil(bool Function() cond) async {
    for (var i = 0; i < 400 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  SyncJob? pushScanJobFor(String batchId, String scanId) {
    final matches = queue.jobs.where((j) =>
        j.type == SyncJobType.pushScan &&
        j.batchId == batchId &&
        j.scanId == scanId);
    return matches.isEmpty ? null : matches.first;
  }

  List<SyncJob> pushScanJobsFor(String batchId, String scanId) => queue.jobs
      .where((j) =>
          j.type == SyncJobType.pushScan &&
          j.batchId == batchId &&
          j.scanId == scanId)
      .toList();

  List<String> jobLabels() => queue.jobs.map((j) {
        final v = j.meta['variant'];
        return v == null ? j.type.name : '${j.type.name}:$v';
      }).toList();

  void expectNoNetworkOrDrain() {
    expect(neverClient.calls, isEmpty);
    expect(spyManager.processQueueCalls, 0);
    expect(spyManager.startCalls, 0);
    expect(spyManager.syncNowCalls, 0);
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('syncing_repo_test_');
    fakeLocal = _FakeLocal();
    neverClient = _NeverSyncClient();
    rebuild(makeQueue());
  });

  tearDown(() {
    spyManager.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {/* Windows may briefly hold a handle */}
  });

  test('1. read methods delegate to local and cause no queue/network work',
      () async {
    final scan = _scan('s1');
    await repo.getBatches();
    await repo.getBatchById('b1');
    await repo.getBatchesByExamCode('AT');
    await repo.resolveScanImage('b1', scan);
    await repo.resolveScanRectifiedImage('b1', scan);

    expect(fakeLocal.calls, [
      'getBatches',
      'getBatchById:b1',
      'getBatchesByExamCode:AT',
      'resolveScanImage:b1/s1',
      'resolveScanRectifiedImage:b1/s1',
    ]);
    expect(queue.jobs, isEmpty);
    expectNoNetworkOrDrain();
  });

  test('2. createBatch local success enqueues exactly PUSH_BATCH', () async {
    final batch = await repo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: '',
      expectedCount: 10,
      createdByUid: 'uid',
      createdByName: 'Officer',
    );
    await waitForJobs(1);

    expect(batch.id, 'b1');
    expect(jobLabels(), ['pushBatch']);
    expect(queue.jobs.single.batchId, 'b1');
    expectNoNetworkOrDrain();
  });

  test('3. createBatch local failure enqueues nothing', () async {
    fakeLocal.failWith['createBatch'] = Exception('local write failed');

    await expectLater(
      repo.createBatch(
        batchCode: 'B-1',
        examCode: 'AT',
        examTitle: 'Aptitude',
        description: '',
        expectedCount: 10,
        createdByUid: 'uid',
        createdByName: 'Officer',
      ),
      throwsA(isA<Exception>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(queue.jobs, isEmpty);
    expectNoNetworkOrDrain();
  });

  test('4. updateBatch enqueues exactly PUSH_BATCH', () async {
    await repo.updateBatch(_batch(id: 'b1'));
    await waitForJobs(1);

    expect(jobLabels(), ['pushBatch']);
    expect(queue.jobs.single.batchId, 'b1');
    expectNoNetworkOrDrain();
  });

  test('5. addScan enqueues PUSH_BATCH, PUSH_SCAN, UPLOAD original, '
      'UPLOAD rectified, PATCH — in order', () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', rectified: true)]);

    await repo.addScan(
      batchId: 'b1',
      decoded: _decoded,
      sourceImage: File('src.jpg'),
    );
    await waitForJobs(5);

    expect(jobLabels(), [
      'pushBatch',
      'pushScan',
      'uploadImage:original',
      'uploadImage:rectified',
      'patchImageStatus',
    ]);
    expect(queue.jobs[1].scanId, 's1');
    expectNoNetworkOrDrain();
  });

  test('5b. addScan without a rectified image omits the rectified upload',
      () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', rectified: false)]);

    await repo.addScan(
      batchId: 'b1',
      decoded: _decoded,
      sourceImage: File('src.jpg'),
    );
    await waitForJobs(4);

    expect(jobLabels(), [
      'pushBatch',
      'pushScan',
      'uploadImage:original',
      'patchImageStatus',
    ]);
    expectNoNetworkOrDrain();
  });

  test('6. addScan local failure (scan-limit) enqueues nothing', () async {
    fakeLocal.failWith['addScan'] = BatchScanLimitExceededException(5);

    await expectLater(
      repo.addScan(
        batchId: 'b1',
        decoded: _decoded,
        sourceImage: File('src.jpg'),
      ),
      throwsA(isA<BatchScanLimitExceededException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(queue.jobs, isEmpty);
    expectNoNetworkOrDrain();
  });

  test('7. replaceScan enqueues PUSH_SCAN, UPLOAD original, UPLOAD rectified, '
      'PATCH, PUSH_BATCH — in order (rectified always)', () async {
    await repo.replaceScan(
      batchId: 'b1',
      scanId: 's1',
      decoded: _decoded,
      sourceImage: File('src.jpg'),
    );
    await waitForJobs(5);

    expect(jobLabels(), [
      'pushScan',
      'uploadImage:original',
      'uploadImage:rectified',
      'patchImageStatus',
      'pushBatch',
    ]);
    expectNoNetworkOrDrain();
  });

  test('8. attachResult enqueues PUSH_SCAN then PUSH_BATCH', () async {
    await repo.attachResult(batchId: 'b1', scanId: 's1', result: _result);
    await waitForJobs(2);

    expect(jobLabels(), ['pushScan', 'pushBatch']);
    expect(queue.jobs.first.scanId, 's1');
    expectNoNetworkOrDrain();
  });

  test('9. setScanExaminee enqueues PUSH_SCAN then PUSH_BATCH', () async {
    await repo.setScanExaminee(
      batchId: 'b1',
      scanId: 's1',
      examinee: const ExamineeInfo(
        firstName: 'A',
        lastName: 'B',
        examineeNumber: '1',
      ),
    );
    await waitForJobs(2);

    expect(jobLabels(), ['pushScan', 'pushBatch']);
    expectNoNetworkOrDrain();
  });

  test('9b. a real answer correction enqueues PUSH_SCAN then PUSH_BATCH',
      () async {
    await repo.updateScanCorrections(
      batchId: 'b1',
      scanId: 's1',
      corrections: const [],
    );
    await waitForJobs(2);

    expect(jobLabels(), ['pushScan', 'pushBatch']);
    expectNoNetworkOrDrain();
  });

  test('9c. a repeated correction (no change) enqueues nothing', () async {
    fakeLocal.correctionsChangeBatch = false;
    await repo.updateScanCorrections(
      batchId: 'b1',
      scanId: 's1',
      corrections: const [],
    );

    expect(queue.jobs, isEmpty);
    expect(fakeLocal.calls, contains('updateScanCorrections:b1/s1'));
  });

  test('9d. confirming an archive is a pure delegation and never queues a job',
      () async {
    final ok = await repo.confirmBatchArchived('b1', DateTime.utc(2026));

    expect(ok, isTrue);
    expect(queue.jobs, isEmpty);
    expect(fakeLocal.calls, contains('confirmBatchArchived:b1'));
  });

  test('10. deleteBatch cancels pending content pushes before the local '
      'delete runs', () async {
    // Seed a pending content push for b1.
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's1',
      batchId: 'b1',
      scanId: 's1',
    ));
    expect(
      queue.jobs.where((j) => j.batchId == 'b1' && j.isBatchContentPush),
      hasLength(1),
    );

    int? pushesAtDeleteTime;
    fakeLocal.onDeleteBatch = () {
      pushesAtDeleteTime = queue.jobs
          .where((j) => j.batchId == 'b1' && j.isBatchContentPush)
          .length;
    };

    await repo.deleteBatch('b1');

    expect(pushesAtDeleteTime, 0); // cancelled before local delete
    expectNoNetworkOrDrain();
  });

  test('11. deleteBatch success enqueues DELETE_BATCH then '
      'DELETE_STORAGE_PREFIX', () async {
    await repo.deleteBatch('b1');
    await waitForJobs(2);

    expect(jobLabels(), ['deleteBatch', 'deleteStoragePrefix']);
    expect(queue.jobs.every((j) => j.batchId == 'b1'), isTrue);
    expectNoNetworkOrDrain();
  });

  test('11b. deleteScan success cancels that scan\'s pending pushes and '
      'enqueues DELETE_SCAN then PUSH_BATCH', () async {
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's1',
      batchId: 'b1',
      scanId: 's1',
    ));
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.uploadImage,
      entityId: 's1',
      batchId: 'b1',
      scanId: 's1',
      meta: const {'variant': 'original'},
    ));
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's2',
      batchId: 'b1',
      scanId: 's2',
    ));

    await repo.deleteScan(batchId: 'b1', scanId: 's1');
    await waitForJobs(3);

    expect(jobLabels(), ['pushScan', 'deleteScan', 'pushBatch']);
    final survivor = queue.jobs.firstWhere((j) => j.type == SyncJobType.pushScan);
    expect(survivor.scanId, 's2'); // an unrelated scan's push is untouched
    expect(
      queue.jobs.firstWhere((j) => j.type == SyncJobType.deleteScan).scanId,
      's1',
    );
    expectNoNetworkOrDrain();
  });

  test('11c. deleteScan local failure enqueues nothing', () async {
    fakeLocal.failWith['deleteScan'] = const FileSystemException('nope');

    await expectLater(
      repo.deleteScan(batchId: 'b1', scanId: 's1'),
      throwsA(isA<FileSystemException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(queue.jobs, isEmpty);
    expectNoNetworkOrDrain();
  });

  test('12. deleteBatch local failure enqueues no deletion jobs', () async {
    fakeLocal.failWith['deleteBatch'] = const FileSystemException('nope');

    await expectLater(
      repo.deleteBatch('b1'),
      throwsA(isA<FileSystemException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      queue.jobs.where((j) =>
          j.type == SyncJobType.deleteBatch ||
          j.type == SyncJobType.deleteStoragePrefix),
      isEmpty,
    );
    expectNoNetworkOrDrain();
  });

  test('13. an enqueue failure does not fail the successful local mutation',
      () async {
    rebuild(_ThrowingQueue(Directory('${tempDir.path}/throwing')));

    final batch = await repo.updateBatch(_batch(id: 'b1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(batch.id, 'b1'); // local result still returned, no throw
    expect(fakeLocal.calls, contains('updateBatch:b1'));
    expectNoNetworkOrDrain();
  });

  test('14. read methods never trigger the queue or a drain', () async {
    await repo.getBatches();
    await repo.getBatchById('b1');
    await repo.getBatchesByExamCode('AT');
    await repo.resolveScanImage('b1', _scan('s1'));
    await repo.resolveScanRectifiedImage('b1', _scan('s1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(queue.jobs, isEmpty);
    expectNoNetworkOrDrain();
  });

  test('15. no mutation causes the repository to call the network client or '
      'a drain method', () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', rectified: true)]);

    await repo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: '',
      expectedCount: 10,
      createdByUid: 'uid',
      createdByName: 'Officer',
    );
    await repo.updateBatch(_batch(id: 'b1'));
    await repo.addScan(
        batchId: 'b1', decoded: _decoded, sourceImage: File('s.jpg'));
    await repo.replaceScan(
        batchId: 'b1', scanId: 's1', decoded: _decoded, sourceImage: File('s.jpg'));
    await repo.attachResult(batchId: 'b1', scanId: 's1', result: _result);
    await repo.setScanExaminee(batchId: 'b1', scanId: 's1');
    await repo.deleteBatch('b1');
    // Let every fire-and-forget enqueue land before tearDown removes tempDir.
    await waitForJobs(3);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expectNoNetworkOrDrain();
  });

  // --- wake() wiring (Phase 9B-7C) --------------------------------------

  test('16. successful createBatch wakes the sync manager exactly once',
      () async {
    await repo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: '',
      expectedCount: 10,
      createdByUid: 'uid',
      createdByName: 'Officer',
    );
    await waitForWake();
    await settle();

    expect(jobLabels(), ['pushBatch']);
    expect(spyManager.wakeCalls, 1);
    expectNoNetworkOrDrain();
  });

  test('17. successful updateBatch wakes the sync manager exactly once',
      () async {
    await repo.updateBatch(_batch(id: 'b1'));
    await waitForWake();
    await settle();

    expect(jobLabels(), ['pushBatch']);
    expect(spyManager.wakeCalls, 1);
    expectNoNetworkOrDrain();
  });

  test('18. successful addScan wakes exactly once after all 5 jobs enqueue',
      () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', rectified: true)]);

    await repo.addScan(
        batchId: 'b1', decoded: _decoded, sourceImage: File('src.jpg'));
    await waitForJobs(5);
    await waitForWake();
    await settle();

    expect(jobLabels(), [
      'pushBatch',
      'pushScan',
      'uploadImage:original',
      'uploadImage:rectified',
      'patchImageStatus',
    ]);
    expect(spyManager.wakeCalls, 1); // one wake for the whole mutation
    expectNoNetworkOrDrain();
  });

  test('19. successful replaceScan wakes the sync manager exactly once',
      () async {
    await repo.replaceScan(
      batchId: 'b1',
      scanId: 's1',
      decoded: _decoded,
      sourceImage: File('src.jpg'),
    );
    await waitForJobs(5);
    await waitForWake();
    await settle();

    expect(jobLabels(), [
      'pushScan',
      'uploadImage:original',
      'uploadImage:rectified',
      'patchImageStatus',
      'pushBatch',
    ]);
    expect(spyManager.wakeCalls, 1);
    expectNoNetworkOrDrain();
  });

  test('20. successful attachResult wakes the sync manager exactly once',
      () async {
    await repo.attachResult(batchId: 'b1', scanId: 's1', result: _result);
    await waitForJobs(2);
    await waitForWake();
    await settle();

    expect(jobLabels(), ['pushScan', 'pushBatch']);
    expect(spyManager.wakeCalls, 1);
    expectNoNetworkOrDrain();
  });

  test('21. successful setScanExaminee wakes the sync manager exactly once',
      () async {
    await repo.setScanExaminee(batchId: 'b1', scanId: 's1');
    await waitForJobs(2);
    await waitForWake();
    await settle();

    expect(jobLabels(), ['pushScan', 'pushBatch']);
    expect(spyManager.wakeCalls, 1);
    expectNoNetworkOrDrain();
  });

  test('22. successful deleteBatch wakes once after the deletion jobs queue',
      () async {
    await repo.deleteBatch('b1');
    await waitForJobs(2);
    await waitForWake();
    await settle();

    expect(jobLabels(), ['deleteBatch', 'deleteStoragePrefix']);
    expect(spyManager.wakeCalls, 1);
    expectNoNetworkOrDrain();
  });

  test('23. a failed local mutation enqueues nothing and never wakes',
      () async {
    fakeLocal.failWith['addScan'] = BatchScanLimitExceededException(5);

    await expectLater(
      repo.addScan(
          batchId: 'b1', decoded: _decoded, sourceImage: File('src.jpg')),
      throwsA(isA<BatchScanLimitExceededException>()),
    );
    await settle();

    expect(queue.jobs, isEmpty);
    expect(spyManager.wakeCalls, 0);
    expectNoNetworkOrDrain();
  });

  test('24. a total enqueue failure keeps local success and does not wake',
      () async {
    rebuild(_ThrowingQueue(Directory('${tempDir.path}/throwing')));

    final batch = await repo.updateBatch(_batch(id: 'b1'));
    await settle();

    expect(batch.id, 'b1'); // local result still returned, no throw
    expect(fakeLocal.calls, contains('updateBatch:b1'));
    expect(spyManager.wakeCalls, 0); // no job landed -> no wake
    expectNoNetworkOrDrain();
  });

  test('25. the mutation returns without awaiting wake() (fire-and-forget)',
      () async {
    spyManager.wakeGate = Completer<void>();

    final batch = await repo
        .updateBatch(_batch(id: 'b1'))
        .timeout(const Duration(seconds: 2)); // would hang if wake were awaited

    expect(batch.id, 'b1');
    await waitForWake(); // wake was invoked...
    expect(spyManager.wakeCalls, 1);
    expect(spyManager.wakeGate!.isCompleted, isFalse); // ...and is still blocked

    spyManager.wakeGate!.complete(); // let the fire-and-forget finish
    await settle();
  });

  test('26. no mutation calls start / processQueue / syncNow — only wake',
      () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', rectified: true)]);

    await repo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: '',
      expectedCount: 10,
      createdByUid: 'uid',
      createdByName: 'Officer',
    );
    await repo.updateBatch(_batch(id: 'b1'));
    await repo.addScan(
        batchId: 'b1', decoded: _decoded, sourceImage: File('s.jpg'));
    await repo.replaceScan(
        batchId: 'b1',
        scanId: 's1',
        decoded: _decoded,
        sourceImage: File('s.jpg'));
    await repo.attachResult(batchId: 'b1', scanId: 's1', result: _result);
    await repo.setScanExaminee(batchId: 'b1', scanId: 's1');
    await repo.deleteBatch('b1');
    await waitForWake();
    await settle();

    expect(spyManager.startCalls, 0);
    expect(spyManager.processQueueCalls, 0);
    expect(spyManager.syncNowCalls, 0);
    expect(neverClient.calls, isEmpty);
    expect(spyManager.wakeCalls, greaterThan(0)); // wake IS the mechanism used
  });

  test('27. addScan is local-first: returns the local result with no network '
      'call and without awaiting wake()', () async {
    spyManager.wakeGate = Completer<void>(); // wake blocks if the repo awaits it
    fakeLocal.batchResult = _batch(scans: [_scan('s1')]);

    final batch = await repo
        .addScan(
            batchId: 'b1', decoded: _decoded, sourceImage: File('src.jpg'))
        .timeout(const Duration(seconds: 2));

    expect(batch.id, 'b1'); // local result, returned promptly
    expect(fakeLocal.calls, contains('addScan:b1'));
    expect(neverClient.calls, isEmpty); // no Supabase from the scanner path
    await waitForWake();
    expect(spyManager.wakeGate!.isCompleted, isFalse); // fired, not awaited

    spyManager.wakeGate!.complete();
    await settle();
  });

  // --- examinee tag-audit metadata (Phase 9B-7E) ------------------------

  test('28. setScanExaminee (tag) enqueues PUSH_SCAN with examinee_tag meta',
      () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', examinee: _examinee)]);

    await repo.setScanExaminee(
        batchId: 'b1', scanId: 's1', examinee: _examinee);
    await waitForJobs(2);
    await waitForWake();
    await settle();

    final job = pushScanJobFor('b1', 's1')!;
    expect(job.meta['operation'], 'examinee_tag');
    expect(DateTime.tryParse(job.meta['opAt'] ?? '')?.isUtc, isTrue);
    expect(jobLabels(), ['pushScan', 'pushBatch']); // order unchanged
    expect(spyManager.wakeCalls, 1);
    expectNoNetworkOrDrain();
  });

  test('29. setScanExaminee (clear) enqueues PUSH_SCAN with examinee_clear meta',
      () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1')]); // stored examinee == null

    await repo.setScanExaminee(batchId: 'b1', scanId: 's1', examinee: null);
    await waitForJobs(2);
    await settle();

    expect(pushScanJobFor('b1', 's1')!.meta['operation'], 'examinee_clear');
  });

  test('30. an all-blank ExamineeInfo is treated as examinee_clear', () async {
    // LocalBatchRepository clears an empty ExamineeInfo, so the stored scan
    // has examinee == null; the fake returns that.
    fakeLocal.batchResult = _batch(scans: [_scan('s1')]);

    await repo.setScanExaminee(
      batchId: 'b1',
      scanId: 's1',
      examinee: const ExamineeInfo(
          firstName: '', lastName: '', examineeNumber: ''),
    );
    await waitForJobs(2);
    await settle();

    expect(pushScanJobFor('b1', 's1')!.meta['operation'], 'examinee_clear');
  });

  test('31. PUSH_SCAN meta holds exactly {operation, opAt} and no PII',
      () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', examinee: _examinee)]);

    await repo.setScanExaminee(
        batchId: 'b1', scanId: 's1', examinee: _examinee);
    await waitForJobs(2);
    await settle();

    final meta = pushScanJobFor('b1', 's1')!.meta;
    expect(meta.keys.toSet(), {'operation', 'opAt'});
    final blob = meta.values.join('|').toLowerCase();
    for (final forbidden in const [
      'juan', 'test', 'x-1', 'uid', 'token', 'bearer',
      'first_name', 'last_name', 'examinee_number',
    ]) {
      expect(blob.contains(forbidden), isFalse,
          reason: 'meta must not contain "$forbidden"');
    }
  });

  test('32. a pending plain PUSH_SCAN for the scan is replaced by the tag job',
      () async {
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's1',
      batchId: 'b1',
      scanId: 's1',
    ));
    expect(pushScanJobsFor('b1', 's1'), hasLength(1));

    fakeLocal.batchResult = _batch(scans: [_scan('s1', examinee: _examinee)]);
    await repo.setScanExaminee(
        batchId: 'b1', scanId: 's1', examinee: _examinee);
    await waitUntil(
        () => pushScanJobFor('b1', 's1')?.meta['operation'] == 'examinee_tag');
    await settle();

    final scanJobs = pushScanJobsFor('b1', 's1');
    expect(scanJobs, hasLength(1)); // plain removed, tag added
    expect(scanJobs.single.meta['operation'], 'examinee_tag');
  });

  test('33. an inProgress PUSH_SCAN is preserved and a new tag job is added',
      () async {
    final plain = await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's1',
      batchId: 'b1',
      scanId: 's1',
    ));
    await queue.update(plain!.copyWith(status: SyncJobStatus.inProgress));

    fakeLocal.batchResult = _batch(scans: [_scan('s1', examinee: _examinee)]);
    await repo.setScanExaminee(
        batchId: 'b1', scanId: 's1', examinee: _examinee);
    await waitUntil(() => pushScanJobsFor('b1', 's1').length == 2);
    await settle();

    final scanJobs = pushScanJobsFor('b1', 's1');
    expect(scanJobs, hasLength(2));
    expect(
      scanJobs.any((j) =>
          j.status == SyncJobStatus.inProgress && j.meta.isEmpty),
      isTrue,
    );
    expect(
      scanJobs.any((j) =>
          j.status == SyncJobStatus.pending &&
          j.meta['operation'] == 'examinee_tag'),
      isTrue,
    );
  });

  test('34. tag pending then rescan: the tag meta survives coalescing',
      () async {
    fakeLocal.batchResult = _batch(scans: [_scan('s1', examinee: _examinee)]);
    await repo.setScanExaminee(
        batchId: 'b1', scanId: 's1', examinee: _examinee);
    await waitUntil(
        () => pushScanJobFor('b1', 's1')?.meta['operation'] == 'examinee_tag');

    await repo.replaceScan(
      batchId: 'b1',
      scanId: 's1',
      decoded: _decoded,
      sourceImage: File('src.jpg'),
    );
    await waitForJobs(5);
    await settle();

    final scanJobs = pushScanJobsFor('b1', 's1');
    expect(scanJobs, hasLength(1)); // rescan's plain PUSH_SCAN coalesced away
    expect(scanJobs.single.meta['operation'], 'examinee_tag'); // meta kept
  });

  test('35. rescan pending then tag: the plain PUSH_SCAN is replaced', () async {
    await repo.replaceScan(
      batchId: 'b1',
      scanId: 's1',
      decoded: _decoded,
      sourceImage: File('src.jpg'),
    );
    await waitForJobs(5);
    await waitUntil(() => pushScanJobFor('b1', 's1')?.meta.isEmpty ?? false);

    fakeLocal.batchResult = _batch(scans: [_scan('s1', examinee: _examinee)]);
    await repo.setScanExaminee(
        batchId: 'b1', scanId: 's1', examinee: _examinee);
    await waitUntil(
        () => pushScanJobFor('b1', 's1')?.meta['operation'] == 'examinee_tag');
    await settle();

    final scanJobs = pushScanJobsFor('b1', 's1');
    expect(scanJobs, hasLength(1));
    expect(scanJobs.single.meta['operation'], 'examinee_tag');
  });

  test('36. a failed local setScanExaminee enqueues nothing and never wakes',
      () async {
    fakeLocal.failWith['setScanExaminee'] = StateError('local write failed');

    await expectLater(
      repo.setScanExaminee(batchId: 'b1', scanId: 's1', examinee: _examinee),
      throwsA(isA<StateError>()),
    );
    await settle();

    expect(queue.jobs, isEmpty);
    expect(spyManager.wakeCalls, 0);
    expectNoNetworkOrDrain();
  });
}
