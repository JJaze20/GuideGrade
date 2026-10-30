import 'sync_client.dart';
import 'sync_outcome.dart';

/// Verify business completion, not mobile's cloud-synced Archived label.
/// Fail closed before destroying local data or cloud images.
Future<SyncOutcome> checkBatchDeletionAllowed(
  SyncClient client,
  String batchId,
) async {
  try {
    final batches = await client.readCloudBatches();
    if (!batches.isSuccess) return batches.error!;
    final archives = await client.readBatchArchives();
    if (!archives.isSuccess) return archives.error!;
    if (batches.batches.any(
          (batch) => batch.id == batchId && batch.status == 'Completed',
        ) ||
        archives.archives.any((archive) => archive.batchId == batchId)) {
      return const SyncOutcome.permanent('completed_batch_protected');
    }
    return const SyncOutcome.success();
  } catch (_) {
    return const SyncOutcome.transient('batch_deletion_verification_failed');
  }
}

/// A batch may be deleted only while it holds no scanned sheet at all. This
/// counts every cloud `scans` row for the batch, soft-deleted ones included
/// (a soft-deleted scan is still a row in the batch), so a batch that ever
/// held scans is never deleted from the app.
///
/// Deliberately separate from [checkBatchDeletionAllowed]: that check also
/// guards deleting an individual scan or image inside a batch, which by
/// definition always has scans. Fails closed -- a client that cannot count
/// scan rows, or a failed read, blocks deletion.
Future<SyncOutcome> checkBatchEmptyForDeletion(
  SyncClient client,
  String batchId,
) async {
  if (client is! BatchScanRowCountClient) {
    return const SyncOutcome.transient('batch_deletion_verification_failed');
  }
  try {
    final read = await (client as BatchScanRowCountClient)
        .readAllScanRowCounts([batchId]);
    if (!read.isSuccess) return read.error!;
    if ((read.counts[batchId] ?? 0) > 0) {
      return const SyncOutcome.permanent('batch_has_scans');
    }
    return const SyncOutcome.success();
  } catch (_) {
    return const SyncOutcome.transient('batch_deletion_verification_failed');
  }
}
