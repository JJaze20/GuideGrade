import '../../models/local_batch.dart';
import '../batch/batch_lifecycle.dart';

/// Decides when a batch becomes Archived: only after the cloud has confirmed
/// the batch's CURRENT saved revision. It reads the sync layer's own records
/// and never drives an upload, so upload progress, pending changes and
/// failures stay in the sync queue and do not change a batch's status.
///
/// Everything it needs is passed in as plain functions, so this file has no
/// Flutter, Supabase or storage dependency and its rules can be exercised
/// directly (see `tool/verify_batch_lifecycle.dart`).
class BatchArchiveCoordinator {
  BatchArchiveCoordinator({
    required this.cloudConfigured,
    required this.loadBatches,
    required this.outstandingJobsFor,
    required this.lastPushedUpdatedAt,
    required this.confirmArchived,
  });

  /// False when this build has no cloud data plane — nothing can be
  /// confirmed, so nothing is ever archived.
  final bool cloudConfigured;

  final Future<List<LocalBatch>> Function() loadBatches;

  /// How many sync jobs of ANY status (queued, running, retrying, blocked,
  /// permanently failed) exist for the batch.
  final int Function(String batchId) outstandingJobsFor;

  /// The `updatedAt` of the batch state the most recent successful push
  /// carried, or null if none has succeeded.
  final DateTime? Function(String batchId) lastPushedUpdatedAt;

  /// Compare-and-set archive: succeeds only if the batch's saved revision
  /// still equals the one passed (see BatchRepository.confirmBatchArchived).
  final Future<bool> Function(String batchId, DateTime confirmedUpdatedAt)
  confirmArchived;

  bool _running = false;
  bool _rerun = false;

  /// Checks every not-yet-archived batch. Safe to call as often as the sync
  /// state changes: overlapping calls are coalesced into one more pass, so
  /// two evaluations never race each other. Returns the ids archived by the
  /// pass that ran (empty when a pass was already running — the running pass
  /// will pick the change up).
  Future<List<String>> evaluateAll() async {
    if (_running) {
      _rerun = true;
      return const [];
    }
    _running = true;
    final archived = <String>[];
    try {
      do {
        _rerun = false;
        final batches = await loadBatches();
        for (final batch in batches) {
          if (await evaluate(batch)) archived.add(batch.id);
        }
      } while (_rerun);
    } finally {
      _running = false;
    }
    return archived;
  }

  /// Whether [batch] (a snapshot taken by the caller) is confirmed by the
  /// cloud for exactly its saved revision, and if so archives it.
  ///
  /// The confirmation is checked against [batch]'s own `updatedAt`, and the
  /// archive step re-checks that revision against the stored batch. A
  /// delayed acknowledgement for an older save therefore cannot archive a
  /// batch that was edited in the meantime: either the ledger is behind the
  /// new revision, jobs for the change are outstanding, or the stored
  /// revision no longer matches at the moment of the write.
  Future<bool> evaluate(LocalBatch batch) async {
    if (batch.isArchived || batch.isCompleted) return false;
    final problems = BatchLifecycle.problems(
      batchCode: batch.batchCode,
      examCode: batch.examCode,
      expectedCount: batch.expectedCount,
    );
    if (problems.isNotEmpty) return false; // an incomplete batch stays Draft
    final confirmed = BatchLifecycle.isCloudConfirmed(
      cloudConfigured: cloudConfigured,
      updatedAt: batch.updatedAt,
      lastPushedUpdatedAt: lastPushedUpdatedAt(batch.id),
      outstandingJobs: outstandingJobsFor(batch.id),
    );
    if (!confirmed) return false;
    return confirmArchived(batch.id, batch.updatedAt);
  }
}
