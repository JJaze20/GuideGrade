import 'dart:typed_data';

import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../services/batch_repository.dart';
import 'cloud_batch_mapper.dart';
import 'sync_client.dart';
import 'sync_job.dart';
import 'sync_outcome.dart';
import 'sync_queue.dart';

/// Plain counts for the manual-restore UI. No PII.
class RestoreSummary {
  const RestoreSummary({
    required this.cloudBatchesFound,
    required this.batchesRestored,
    required this.batchesUpdated,
    required this.scansRestored,
    required this.batchesSkippedPendingDelete,
    this.error,
  });

  const RestoreSummary.failed(SyncOutcome outcome)
      : cloudBatchesFound = 0,
        batchesRestored = 0,
        batchesUpdated = 0,
        scansRestored = 0,
        batchesSkippedPendingDelete = 0,
        error = outcome;

  final int cloudBatchesFound;
  final int batchesRestored;
  final int batchesUpdated;
  final int scansRestored;

  /// Cloud batches skipped this pass because a `DELETE_BATCH` /
  /// `DELETE_STORAGE_PREFIX` job for that id was still pending/in-flight
  /// locally — see [CloudRestoreService]'s doc comment.
  final int batchesSkippedPendingDelete;

  /// Set only when the batch-list read itself failed (e.g. offline) —
  /// never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// Orchestrates Supabase → GuideGrade retrieval: read cloud batches/scans
/// via [SyncClient], map them to the existing local models, and write them
/// through [BatchRepository] — additive to the existing push-sync design.
///
/// Deliberately NOT a [SyncManager] job: this is a one-shot, manually
/// triggered operation with no persisted queue state, no retry/backoff of
/// its own, and it never touches [SyncManager]'s dispatch loop or
/// [SyncJob]/[SyncJobStatus]. It only calls [SyncQueue.state]'s existing
/// public setters, exactly the way [SupabaseSyncClient]'s push methods
/// already do, so that `SyncManager._reconcile()` never mistakes freshly
/// restored data for something that still needs pushing.
///
/// v1 rules (see the individual methods for detail):
///  * An existing local scan is never overwritten or merged, regardless of
///    which side is newer — cloud data only ever fills a gap.
///  * A cloud batch with a pending local delete job is skipped entirely
///    this pass, so a delete-in-flight can never be "resurrected" by a
///    restore that raced it.
///  * Images are never downloaded here — see [restoreImageIfMissing],
///    called lazily by a screen only when it actually needs one.
///  * TAT's per-test breakdown is recomputed from the current answer key
///    (via `cloud_batch_mapper.dart`) because the cloud `scans` row has no
///    column for it. If that answer key has changed since the scan was
///    originally graded, the recomputed breakdown can legitimately differ
///    from what was shown at grading time — a known, accepted limitation
///    (there is no answer-key version history in the current schema), not
///    something this service can detect or fix.
class CloudRestoreService {
  CloudRestoreService({
    required this.client,
    required this.repository,
    required this.syncQueue,
    required this.loadAnswerKeys,
  });

  final SyncClient client;
  final BatchRepository repository;
  final SyncQueue syncQueue;

  /// Reads the current local answer keys — same capability already
  /// injected into [SyncManager] as `loadAnswerKeys`.
  final Future<Map<String, AnswerKey>> Function() loadAnswerKeys;

  /// Runs the full manual restore: batch metadata, then each batch's
  /// scans. Never downloads a single image byte (see class doc comment).
  Future<RestoreSummary> restoreAll() async {
    final batchesRead = await client.readCloudBatches();
    if (!batchesRead.isSuccess) {
      return RestoreSummary.failed(batchesRead.error!);
    }

    final answerKeys = await loadAnswerKeys();

    var batchesRestored = 0;
    var batchesUpdated = 0;
    var scansRestored = 0;
    var batchesSkippedPendingDelete = 0;

    for (final cloudBatch in batchesRead.batches) {
      if (_hasActivePendingDelete(cloudBatch.id)) {
        batchesSkippedPendingDelete++;
        continue;
      }

      final existingLocal = await repository.getBatchById(cloudBatch.id);
      final upserted =
          await repository.upsertBatchFromCloud(mapCloudBatch(cloudBatch));

      if (existingLocal == null) {
        batchesRestored++;
      } else if (!upserted.updatedAt.isAtSameMomentAs(existingLocal.updatedAt)) {
        batchesUpdated++;
      }

      // Seed SyncState immediately so SyncManager._reconcile() never
      // mistakes this already-cloud-correct batch for one needing a push.
      syncQueue.state.setBatchPushed(upserted.id, upserted.updatedAt);

      final scansRead = await client.readCloudScans(cloudBatch.id);
      if (!scansRead.isSuccess) {
        // Best-effort: this batch's metadata is still restored; its scans
        // simply weren't reachable this pass (e.g. a transient network
        // blip) and will be picked up on a future restore.
        continue;
      }

      final localScanIds = upserted.scans.map((s) => s.id).toSet();
      final answerKey = answerKeys[cloudBatch.examCode];

      for (final cloudScan in scansRead.scans) {
        // CRITICAL v1 rule: an existing local scan is never overwritten or
        // merged, regardless of which side is newer.
        if (localScanIds.contains(cloudScan.id)) continue;

        await repository.upsertScanFromCloud(
          batchId: cloudBatch.id,
          scan: mapCloudScan(cloudScan, answerKey: answerKey),
        );
        scansRestored++;

        // Only mark an image "already uploaded" when the cloud row itself
        // reports it uploaded -- a genuinely incomplete upload on the
        // pushing device must still be correctly re-queued by
        // SyncManager, not silently treated as done.
        if (cloudScan.imageUploaded) {
          syncQueue.state.setScanUploaded(cloudBatch.id, cloudScan.id, original: true);
        }
        if (cloudScan.rectifiedImagePath != null && cloudScan.rectifiedImageUploaded) {
          syncQueue.state.setScanUploaded(cloudBatch.id, cloudScan.id, rectified: true);
        }
      }
    }

    await syncQueue.saveState();

    return RestoreSummary(
      cloudBatchesFound: batchesRead.batches.length,
      batchesRestored: batchesRestored,
      batchesUpdated: batchesUpdated,
      scansRestored: scansRestored,
      batchesSkippedPendingDelete: batchesSkippedPendingDelete,
    );
  }

  /// True when a `DELETE_BATCH`/`DELETE_STORAGE_PREFIX` job for [batchId]
  /// is currently pending or in flight — the one case a timestamp
  /// comparison alone cannot protect against, since the batch is about to
  /// disappear entirely rather than merely go stale.
  bool _hasActivePendingDelete(String batchId) {
    return syncQueue.jobs.any((j) =>
        j.batchId == batchId &&
        (j.type == SyncJobType.deleteBatch ||
            j.type == SyncJobType.deleteStoragePrefix) &&
        (j.status == SyncJobStatus.pending ||
            j.status == SyncJobStatus.inProgress));
  }

  /// Downloads and locally restores [scan]'s original (or, if [rectified],
  /// perspective-corrected) image, but only if the local copy is actually
  /// missing — never re-downloads an image [repository.resolveScanImage]/
  /// [resolveScanRectifiedImage] can already resolve. Bytes are encrypted
  /// via the repository's own [BatchRepository.writeRestoredScanImage] /
  /// [BatchRepository.writeRestoredScanRectifiedImage] before ever
  /// touching disk — nothing is written unencrypted.
  ///
  /// Called lazily by a screen (never by [restoreAll]) when
  /// [resolveScanImage]/[resolveScanRectifiedImage] return null for a
  /// restored scan. Returns true iff an image was actually downloaded and
  /// written this call.
  Future<bool> restoreImageIfMissing({
    required String batchId,
    required LocalScan scan,
    required bool rectified,
  }) async {
    if (rectified && scan.rectifiedImageFileName == null) {
      return false; // nothing was ever produced for this scan to restore.
    }

    final existing = rectified
        ? await repository.resolveScanRectifiedImage(batchId, scan)
        : await repository.resolveScanImage(batchId, scan);
    if (existing != null) return false; // already present locally.

    final read = await client.downloadScanImage(
      batchId: batchId,
      scanId: scan.id,
      rectified: rectified,
    );
    final rawBytes = read.bytes;
    if (rawBytes == null) return false; // absent in Storage, or read failed.

    final bytes = Uint8List.fromList(rawBytes);
    if (rectified) {
      await repository.writeRestoredScanRectifiedImage(
        batchId: batchId,
        scanId: scan.id,
        bytes: bytes,
      );
    } else {
      await repository.writeRestoredScanImage(
        batchId: batchId,
        scanId: scan.id,
        bytes: bytes,
      );
    }
    return true;
  }
}
