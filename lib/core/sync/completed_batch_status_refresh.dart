import '../services/batch_repository.dart';
import 'sync_client.dart';

/// Pull only business completion into existing local batches. Never restore,
/// remove, rescore or overwrite local scans and never enqueue a cloud push.
Future<void> refreshCompletedBatchStatuses(
  BatchRepository repository,
  SyncClient client,
) async {
  final batches = await client.readCloudBatches();
  if (!batches.isSuccess) return;
  final archives = await client.readBatchArchives();
  if (!archives.isSuccess) return;
  final completed = {
    for (final batch in batches.batches)
      if (batch.status == 'Completed') batch.id,
    for (final archive in archives.archives) archive.batchId,
  };
  for (final local in await repository.getBatches()) {
    if (!local.isCompleted && completed.contains(local.id)) {
      await repository.upsertBatchFromCloud(
        local.copyWith(status: 'Completed'),
      );
    }
  }
}
