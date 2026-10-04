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
