import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import '../services/batch_repository.dart';
import '../services/local_batch_repository.dart';
import 'sync_job.dart';
import 'sync_manager.dart';
import 'sync_queue.dart' show SyncQueue;

/// A [BatchRepository] decorator that keeps device storage the source of
/// truth and mirrors every mutation to the cloud **asynchronously**.
///
/// Contract:
///  * Reads (A) delegate straight to [LocalBatchRepository] and never touch
///    the network.
///  * A mutation (B) first `await`s the local repository. If that throws,
///    the exception propagates and **no** [SyncJob] is enqueued. On success
///    the matching jobs are handed to the durable queue — local/disk work
///    only, fire-and-forget — then, iff at least one job was actually
///    enqueued, `unawaited(syncManager.wake())` nudges the drain. The local
///    result is returned immediately; the scanner path never waits on the
///    queue, on `wake()`, or on the network.
///  * A failure while enqueuing is swallowed (only a sanitized note is
///    logged); [SyncManager]'s startup reconcile re-derives any lost job
///    from local truth. If nothing was enqueued, `wake()` is not called.
///  * `wake()` is itself fire-and-forget and cannot throw to the caller;
///    it only (re)starts the existing drain — it runs no sync logic here.
///
/// This class makes **no** Supabase / Storage / Firebase calls and never
/// invokes [SyncManager.processQueue] / [SyncManager.start] /
/// [SyncManager.syncNow] — only [SyncManager.wake].
class SyncingBatchRepository implements BatchRepository {
  SyncingBatchRepository({
    required this.local,
    required this.syncManager,
  });

  final LocalBatchRepository local;
  final SyncManager syncManager;

  /// The durable job queue, reached only through [SyncManager]'s public
  /// `queue` field — no private state is touched, and all dedupe/coalescing
  /// stays inside [SyncQueue.enqueue].
  SyncQueue get _queue => syncManager.queue;

  // ---------------------------------------------------------------------------
  // A. reads — pure delegation, never any queue or network activity
  // ---------------------------------------------------------------------------

  @override
  Future<List<LocalBatch>> getBatches() => local.getBatches();

  @override
  Future<LocalBatch?> getBatchById(String id) => local.getBatchById(id);

  @override
  Future<List<LocalBatch>> getBatchesByExamCode(String examCode) =>
      local.getBatchesByExamCode(examCode);

  @override
  Future<Uint8List?> resolveScanImage(String batchId, LocalScan scan) =>
      local.resolveScanImage(batchId, scan);

  @override
  Future<Uint8List?> resolveScanRectifiedImage(String batchId, LocalScan scan) =>
      local.resolveScanRectifiedImage(batchId, scan);

  @override
  Future<Uint8List?> resolveScanNameCropLast(String batchId, LocalScan scan) =>
      local.resolveScanNameCropLast(batchId, scan);

  @override
  Future<Uint8List?> resolveScanNameCropFirst(String batchId, LocalScan scan) =>
      local.resolveScanNameCropFirst(batchId, scan);

  @override
  Future<Uint8List?> resolveScanNameCropMiddle(String batchId, LocalScan scan) =>
      local.resolveScanNameCropMiddle(batchId, scan);

  // ---------------------------------------------------------------------------
  // B2. Cloud restore -- pure delegation, same as the reads above: no
  // SyncJob is enqueued. This data just came FROM Supabase, so pushing it
  // straight back would be a pointless round trip (and could race a
  // concurrent edit) -- see CloudRestoreService, the only caller.
  // ---------------------------------------------------------------------------

  @override
  Future<LocalBatch> upsertBatchFromCloud(LocalBatch batch) =>
      local.upsertBatchFromCloud(batch);

  @override
  Future<LocalBatch> upsertScanFromCloud({
    required String batchId,
    required LocalScan scan,
  }) =>
      local.upsertScanFromCloud(batchId: batchId, scan: scan);

  @override
  Future<void> writeRestoredScanImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  }) =>
      local.writeRestoredScanImage(batchId: batchId, scanId: scanId, bytes: bytes);

  @override
  Future<void> writeRestoredScanRectifiedImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  }) =>
      local.writeRestoredScanRectifiedImage(batchId: batchId, scanId: scanId, bytes: bytes);

  // ---------------------------------------------------------------------------
  // C. createBatch
  // ---------------------------------------------------------------------------

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
    final batch = await local.createBatch(
      batchCode: batchCode,
      examCode: examCode,
      examTitle: examTitle,
      description: description,
      expectedCount: expectedCount,
      createdByUid: createdByUid,
      createdByName: createdByName,
    );
    _fireEnqueue([_pushBatch(batch.id)]);
    return batch;
  }

  // ---------------------------------------------------------------------------
  // D. updateBatch
  // ---------------------------------------------------------------------------

  @override
  Future<LocalBatch> updateBatch(LocalBatch batch) async {
    final saved = await local.updateBatch(batch);
    _fireEnqueue([_pushBatch(saved.id)]);
    return saved;
  }

  // ---------------------------------------------------------------------------
  // E. addScan — the scanner hot path
  // ---------------------------------------------------------------------------

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
    final batch = await local.addScan(
      batchId: batchId,
      decoded: decoded,
      sourceImage: sourceImage,
      rectifiedImage: rectifiedImage,
      result: result,
      examinee: examinee,
      // Name crops are a device-local convenience only, for staff to read
      // while manually tagging a scan — forwarded to the local store, but
      // deliberately never uploaded to the cloud below (see
      // supabase_sync_client.dart's upload/column builders, which this
      // method never touches).
      nameCropLastImage: nameCropLastImage,
      nameCropFirstImage: nameCropFirstImage,
      nameCropMiddleImage: nameCropMiddleImage,
    );

    // The scan LocalBatchRepository just appended is the last one.
    if (batch.scans.isEmpty) {
      _fireEnqueue([_pushBatch(batchId)]);
      return batch;
    }
    final scan = batch.scans.last;
    final jobs = <SyncJob>[
      _pushBatch(batchId),
      _pushScan(batchId, scan.id),
      _uploadImage(batchId, scan.id, _variantOriginal),
    ];
    if (scan.rectifiedImageFileName != null) {
      jobs.add(_uploadImage(batchId, scan.id, _variantRectified));
    }
    jobs.add(_patchImageStatus(batchId, scan.id));
    _fireEnqueue(jobs);
    return batch;
  }

  // ---------------------------------------------------------------------------
  // F. replaceScan — rescan
  // ---------------------------------------------------------------------------

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
    final batch = await local.replaceScan(
      batchId: batchId,
      scanId: scanId,
      decoded: decoded,
      sourceImage: sourceImage,
      rectifiedImage: rectifiedImage,
      result: result,
      examinee: examinee,
      nameCropLastImage: nameCropLastImage,
      nameCropFirstImage: nameCropFirstImage,
      nameCropMiddleImage: nameCropMiddleImage,
    );
    _fireEnqueue([
      _pushScan(batchId, scanId),
      _uploadImage(batchId, scanId, _variantOriginal),
      // Always enqueued: SupabaseSyncClient deletes the stale cloud object
      // when the local rectified image is now missing/null.
      _uploadImage(batchId, scanId, _variantRectified),
      _patchImageStatus(batchId, scanId),
      _pushBatch(batchId),
    ]);
    return batch;
  }

  // ---------------------------------------------------------------------------
  // G. attachResult
  // ---------------------------------------------------------------------------

  @override
  Future<LocalBatch> attachResult({
    required String batchId,
    required String scanId,
    required LocalScanResult result,
  }) async {
    final batch = await local.attachResult(
      batchId: batchId,
      scanId: scanId,
      result: result,
    );
    _fireEnqueue([_pushScan(batchId, scanId), _pushBatch(batchId)]);
    return batch;
  }

  // ---------------------------------------------------------------------------
  // H. setScanExaminee
  // ---------------------------------------------------------------------------

  @override
  Future<LocalBatch> setScanExaminee({
    required String batchId,
    required String scanId,
    ExamineeInfo? examinee,
  }) async {
    final batch = await local.setScanExaminee(
      batchId: batchId,
      scanId: scanId,
      examinee: examinee,
    );

    // Operation is derived from what LocalBatchRepository ACTUALLY stored
    // (it clears when examinee == null || examinee.isEmpty), not from the
    // argument — so an all-blank ExamineeInfo is treated as a clear.
    final stored = _examineeOf(batch, scanId);
    final operation =
        stored == null ? 'examinee_clear' : 'examinee_tag';
    final opAt = DateTime.now().toUtc().toIso8601String();

    // Make this operation's meta the one the drain sees: synchronously drop
    // any NON-inProgress PUSH_SCAN already queued for this scan so the
    // fresh job below cannot be coalesced onto a stale one (which would
    // keep the stale job's meta). Existing public SyncQueue API only.
    final scanKey = SyncJob.dedupeKeyFor(
      type: SyncJobType.pushScan,
      batchId: batchId,
      scanId: scanId,
      entityId: scanId,
    );
    for (final job in _queue.jobsWithDedupeKey(scanKey)) {
      if (job.status != SyncJobStatus.inProgress) {
        unawaited(_safeRemove(job.id));
      }
    }

    _fireEnqueue([
      _pushScan(batchId, scanId,
          meta: {'operation': operation, 'opAt': opAt}),
      _pushBatch(batchId),
    ]);
    return batch;
  }

  ExamineeInfo? _examineeOf(LocalBatch batch, String scanId) {
    for (final scan in batch.scans) {
      if (scan.id == scanId) return scan.examinee;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // I. deleteBatch
  // ---------------------------------------------------------------------------

  @override
  Future<void> deleteBatch(String id) async {
    // 1. Drop queued content pushes for this batch before the local data
    //    goes (best-effort; never blocks the delete).
    await _cancelPendingPushes(id);
    // 2. Local delete. If it throws, the exception propagates and no
    //    deletion jobs are enqueued.
    await local.deleteBatch(id);
    // 3. Local delete succeeded: enqueue the cloud teardown, in order.
    _fireEnqueue([_deleteBatch(id), _deleteStoragePrefix(id)]);
  }

  // ---------------------------------------------------------------------------
  // Job builders (entity-id convention matches SyncManager._reconcile:
  // batch id for batch/delete jobs, scan id for scan/image jobs).
  // ---------------------------------------------------------------------------

  static const String _variantOriginal = 'original';
  static const String _variantRectified = 'rectified';

  SyncJob _pushBatch(String batchId) => SyncJob.create(
        type: SyncJobType.pushBatch,
        entityId: batchId,
        batchId: batchId,
      );

  SyncJob _pushScan(
    String batchId,
    String scanId, {
    Map<String, String> meta = const {},
  }) =>
      SyncJob.create(
        type: SyncJobType.pushScan,
        entityId: scanId,
        batchId: batchId,
        scanId: scanId,
        meta: meta,
      );

  SyncJob _uploadImage(String batchId, String scanId, String variant) =>
      SyncJob.create(
        type: SyncJobType.uploadImage,
        entityId: scanId,
        batchId: batchId,
        scanId: scanId,
        meta: {'variant': variant},
      );

  SyncJob _patchImageStatus(String batchId, String scanId) => SyncJob.create(
        type: SyncJobType.patchImageStatus,
        entityId: scanId,
        batchId: batchId,
        scanId: scanId,
      );

  SyncJob _deleteBatch(String batchId) => SyncJob.create(
        type: SyncJobType.deleteBatch,
        entityId: batchId,
        batchId: batchId,
      );

  SyncJob _deleteStoragePrefix(String batchId) => SyncJob.create(
        type: SyncJobType.deleteStoragePrefix,
        entityId: batchId,
        batchId: batchId,
      );

  // ---------------------------------------------------------------------------
  // Enqueue plumbing — local/disk only, never blocks the caller, never
  // fails the already-successful local mutation.
  // ---------------------------------------------------------------------------

  void _fireEnqueue(List<SyncJob> jobs) {
    // Job ids are assigned synchronously here, in order, so the queue keeps
    // them in dependency order regardless of when each disk write lands.
    unawaited(_enqueueThenWake(jobs));
  }

  /// Enqueues [jobs] one at a time, then — iff at least one landed — wakes
  /// the sync drain exactly once. Fully off the caller's critical path
  /// (invoked via `unawaited`); a queue or wake failure is swallowed.
  Future<void> _enqueueThenWake(List<SyncJob> jobs) async {
    var enqueuedAny = false;
    try {
      for (final job in jobs) {
        await _queue.enqueue(job);
        enqueuedAny = true;
      }
    } catch (error) {
      _logSyncFailure(error);
    }
    if (enqueuedAny) {
      await _safeWake();
    }
  }

  /// Fire-and-forget nudge to [SyncManager.wake] — never `start()`,
  /// `processQueue()`, `syncNow()`, or Supabase. `wake()` is already
  /// internally guarded; the try/catch here is belt-and-suspenders so an
  /// unforeseen throw can never reach the (already-successful) mutation.
  Future<void> _safeWake() async {
    try {
      await syncManager.wake();
    } catch (error) {
      _logSyncFailure(error);
    }
  }

  Future<void> _cancelPendingPushes(String batchId) async {
    try {
      await _queue.cancelPushesForBatch(batchId);
    } catch (error) {
      _logSyncFailure(error);
    }
  }

  /// Removes one queued job by id (the in-memory removal is synchronous;
  /// only the persist is awaited). A failure is swallowed — the stale job
  /// merely survives and the next examinee operation re-attempts the drop.
  Future<void> _safeRemove(String jobId) async {
    try {
      await _queue.remove(jobId);
    } catch (error) {
      _logSyncFailure(error);
    }
  }

  void _logSyncFailure(Object error) {
    // Type only — a raw message may carry a file path or payload.
    // ignore: avoid_print
    print('SyncingBatchRepository: background sync step failed '
        '(${error.runtimeType})');
  }
}
