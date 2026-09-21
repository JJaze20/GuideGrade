import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/local_batch_repository.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/sync/cloud_batch_mapper.dart';
import '../../../core/sync/supabase_sync_client.dart';
import '../../../core/sync/sync_client.dart';
import '../../../core/sync/sync_outcome.dart';
import '../../../core/sync/sync_queue.dart' show SyncState;
import '../../../models/batch_archive.dart';
import '../../../models/local_batch.dart';

/// Thrown by [GuidanceWebArchiveService] on any failure. Carries only an
/// already-sanitized, user-safe message — never a raw exception, a Supabase
/// error code, or a stack trace.
class GuidanceWebArchiveException implements Exception {
  GuidanceWebArchiveException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Supabase access for the Guidance Council Web Archive.
///
/// "Archived" here means ONLY that a `batch_archives` marker row exists for
/// the batch. This service never writes `batches` (so the mobile app's
/// `batches.status`/`updated_at` are never touched), never touches scans,
/// images, answers or examinee links, and has no restore/unarchive method —
/// an archived batch simply stays archived and remains fully viewable
/// through the existing Results views.
class GuidanceWebArchiveService {
  GuidanceWebArchiveService({SyncClient? client})
      : _client = client ?? _buildDefaultClient();

  final SyncClient _client;

  /// Same reasoning as `GuidanceWebResultsService._buildDefaultClient`.
  static SyncClient _buildDefaultClient() {
    return SupabaseSyncClient(
      batches: LocalBatchRepository(),
      localStorage: LocalStorageService(),
      identity: _WebSyncIdentity(),
      getSyncState: () => SyncState(),
    );
  }

  /// Archives [batch]. Re-verifies against the database first: the batch
  /// must still exist, must be `Completed` (read only — the status is never
  /// changed), and must not already be archived. Only then is the marker
  /// inserted. The database enforces the same rules (Completed-only insert
  /// policy, primary key on `batch_id`), so a race is still safe.
  Future<void> archiveBatch(LocalBatch batch, {String? reason}) async {
    final batchesRead = await _client.readCloudBatches();
    if (!batchesRead.isSuccess) {
      throw GuidanceWebArchiveException(_readMessage(batchesRead.error));
    }
    final current = batchesRead.batches.where((b) => b.id == batch.id).toList();
    if (current.isEmpty) {
      throw GuidanceWebArchiveException(
        'This batch no longer exists, so it cannot be archived.',
      );
    }
    if (current.first.status != 'Completed') {
      throw GuidanceWebArchiveException(
        'Only completed batches can be archived. '
        'This batch is currently ${current.first.status}.',
      );
    }

    final archivesRead = await _client.readBatchArchives();
    if (!archivesRead.isSuccess) {
      throw GuidanceWebArchiveException(_readMessage(archivesRead.error));
    }
    if (archivesRead.archives.any((a) => a.batchId == batch.id)) {
      throw GuidanceWebArchiveException('This batch is already archived.');
    }

    final outcome = await _client.archiveBatch(batchId: batch.id, reason: reason);
    if (outcome.isSuccess) return;
    if (outcome.isPermanent && outcome.code == '23505') {
      throw GuidanceWebArchiveException('This batch is already archived.');
    }
    if (outcome.isPermanent && outcome.code == '42501') {
      throw GuidanceWebArchiveException(
        'This batch could not be archived. It may no longer be completed, '
        'or you may not have permission.',
      );
    }
    if (outcome.isTransient) {
      throw GuidanceWebArchiveException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    throw GuidanceWebArchiveException('Could not archive this batch. Please try again.');
  }

  /// Every archived batch with its marker and scan count, newest archive
  /// first. Batches are mapped by the same [mapCloudBatch] the Results page
  /// uses. A marker whose batch cannot be found is skipped (never shown with
  /// fabricated batch info).
  Future<List<ArchivedBatchEntry>> loadArchivedBatches() async {
    final archivesRead = await _client.readBatchArchives();
    if (!archivesRead.isSuccess) {
      throw GuidanceWebArchiveException(_readMessage(archivesRead.error));
    }
    if (archivesRead.archives.isEmpty) return const [];

    final batchesRead = await _client.readCloudBatches();
    if (!batchesRead.isSuccess) {
      throw GuidanceWebArchiveException(_readMessage(batchesRead.error));
    }
    final batchesById = {
      for (final b in batchesRead.batches) b.id: mapCloudBatch(b),
    };

    final wantedIds = [
      for (final a in archivesRead.archives)
        if (batchesById.containsKey(a.batchId)) a.batchId,
    ];
    final countsRead = await _client.readScanCounts(wantedIds);
    if (!countsRead.isSuccess) {
      throw GuidanceWebArchiveException(_readMessage(countsRead.error));
    }

    final entries = <ArchivedBatchEntry>[
      for (final a in archivesRead.archives)
        if (batchesById[a.batchId] != null)
          ArchivedBatchEntry(
            batch: batchesById[a.batchId]!,
            archive: BatchArchive(
              batchId: a.batchId,
              archivedAt: a.archivedAt,
              archivedByUid: a.archivedByUid,
              archivedByName: a.archivedByName,
              reason: a.reason,
            ),
            scanCount: countsRead.counts[a.batchId] ?? 0,
          ),
    ]..sort((x, y) => y.archive.archivedAt.compareTo(x.archive.archivedAt));
    return entries;
  }

  String _readMessage(SyncOutcome? outcome) {
    if (outcome != null && outcome.isTransient) {
      return 'Could not reach Supabase. Check your connection and try again.';
    }
    return 'Could not load archived batches. Please try again.';
  }
}

/// Same as the private identity in the other Guidance Web services —
/// duplicated rather than shared so this feature has no dependency on them.
class _WebSyncIdentity implements SyncIdentity {
  @override
  String? get uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  String? get displayName => FirebaseAuth.instance.currentUser?.displayName;

  @override
  Future<bool> refreshToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await user.getIdToken(true);
    return true;
  }
}
