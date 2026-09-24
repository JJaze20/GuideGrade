import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/local_batch_repository.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/sync/cloud_batch_mapper.dart';
import '../../../core/sync/supabase_sync_client.dart';
import '../../../core/sync/sync_client.dart';
import '../../../core/sync/sync_outcome.dart';
import '../../../core/sync/sync_queue.dart' show SyncState;
import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart';

/// Thrown by [GuidanceWebExamineeRecordsService] on any failure. Carries
/// only an already-sanitized, user-safe message — never a raw exception, a
/// Supabase error code, or a stack trace. Mirrors
/// `GuidanceWebResultsException` exactly.
class GuidanceWebExamineeRecordsException implements Exception {
  GuidanceWebExamineeRecordsException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Supabase access for the Guidance Council Web Console's Examinee Records
/// page — the canonical applicant/examinee record (`examinees`) and the
/// examination history built from it.
///
/// Like [GuidanceWebResultsService], this never calls
/// `BatchRepository.upsertBatchFromCloud`/`upsertScanFromCloud`, never seeds
/// `SyncState`, and never writes to the mobile encrypted local store — it
/// only calls [SyncClient]'s read/write methods and returns plain,
/// unpersisted, in-memory objects for this browser session to hold.
///
/// Examination history is never a second scoring implementation: every
/// [ExamineeHistoryItem] is built from [mapCloudScan] (the exact same pure
/// function the Results page and `CloudRestoreService` already use), so a
/// history entry's score/percentage/status is always identical to what the
/// existing Result Detail view would show for that same scan.
class GuidanceWebExamineeRecordsService {
  GuidanceWebExamineeRecordsService({SyncClient? client})
      : _client = client ?? _buildDefaultClient();

  final SyncClient _client;

  /// See `GuidanceWebResultsService._buildDefaultClient`'s doc comment —
  /// identical reasoning: [LocalBatchRepository]/[LocalStorageService] are
  /// required constructor params [SupabaseSyncClient] never actually reads
  /// for the methods this service calls.
  static SyncClient _buildDefaultClient() {
    return SupabaseSyncClient(
      batches: LocalBatchRepository(),
      localStorage: LocalStorageService(),
      identity: _WebSyncIdentity(),
      getSyncState: () => SyncState(),
    );
  }

  /// Every examinee visible to the current session under Supabase RLS.
  /// Search/status/exam filters are applied by the caller over this list in
  /// memory (mirrors the Results page's own filtering convention) — never a
  /// second Supabase request per filter change.
  Future<List<ExamineeRecord>> loadExaminees() async {
    final read = await _client.readCloudExaminees();
    if (!read.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(read.error));
    }
    return read.examinees.map(_toExamineeRecord).toList();
  }

  /// [examinee]'s full examination history: every scan linked to it via
  /// `scans.examinee_id`, paired with the batch it belongs to (for exam
  /// code, batch code, and date). A scan whose batch can no longer be found
  /// (e.g. deleted) is skipped — never shown with fabricated batch info.
  Future<List<ExamineeHistoryItem>> loadHistoryFor(
    ExamineeRecord examinee,
  ) async {
    final scansRead = await _client.readCloudScansForExaminee(examinee.id);
    if (!scansRead.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(scansRead.error));
    }
    return _joinScansToBatches(scansRead.scans);
  }

  /// Every scan with no examinee behind it yet (`scans.examinee_id IS
  /// NULL`) — the "Unlinked Scans" queue. This is a pure read: nothing here
  /// creates, links, or guesses anything. Newest first, same convention as
  /// [loadHistoryFor].
  Future<List<ExamineeHistoryItem>> loadUnlinkedScans() async {
    final scansRead = await _client.readUnlinkedScans();
    if (!scansRead.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(scansRead.error));
    }
    return _joinScansToBatches(scansRead.scans);
  }

  /// Shared by [loadHistoryFor] and [loadUnlinkedScans]: joins already-read
  /// [CloudScanRow]s to their batch (one extra `readCloudBatches` call,
  /// never one per scan), newest scan first. A scan whose batch can no
  /// longer be found (e.g. deleted) is skipped — never shown with
  /// fabricated batch info.
  Future<List<ExamineeHistoryItem>> _joinScansToBatches(
    List<CloudScanRow> scans,
  ) async {
    if (scans.isEmpty) return const [];

    final batchesRead = await _client.readCloudBatches();
    if (!batchesRead.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(batchesRead.error));
    }
    final batchesById = {
      for (final b in batchesRead.batches) b.id: mapCloudBatch(b),
    };

    final items = <ExamineeHistoryItem>[];
    for (final row in scans) {
      final batch = batchesById[row.batchId];
      if (batch == null) continue;
      items.add(ExamineeHistoryItem(batch: batch, scan: mapCloudScan(row)));
    }
    items.sort((a, b) => b.scan.capturedAt.compareTo(a.scan.capturedAt));
    return items;
  }

  /// Workflow 1 — "Create Examinee Record from this Scan." Atomically
  /// creates a new canonical examinee AND links [scan] (in [batchId]) to it
  /// in one database transaction (see
  /// [SyncClient.createExamineeFromScan]/`create_examinee_from_scan`) — the
  /// only way an examinee is ever created anywhere in this app; there is no
  /// blank-record creation path. [ExamineeRecord.temporaryExamineeId] is
  /// never generated or influenced here — it comes back already assigned by
  /// the database's sequence-backed `DEFAULT`.
  Future<ExamineeRecord> createExamineeFromScan({
    required String batchId,
    required LocalScan scan,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    final write = await _client.createExamineeFromScan(
      batchId: batchId,
      scanId: scan.id,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
    );
    if (!write.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(write.error));
    }
    return _toExamineeRecord(write.examinee!);
  }

  /// Applies a name-only correction (OCR misread fix) — never changes
  /// [ExamineeRecord.temporaryExamineeId] (not a parameter here at all) or
  /// any of the still-unsourced birth date / last attended school /
  /// official student id fields.
  Future<ExamineeRecord> updateExamineeProfile(
    ExamineeRecord examinee, {
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    final write = await _client.updateCloudExaminee(
      id: examinee.id,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
    );
    if (!write.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(write.error));
    }
    return _toExamineeRecord(write.examinee!);
  }

  /// Archives [examinee] — a `status` flip only, never deletes it or
  /// touches its examination history.
  Future<ExamineeRecord> archiveExaminee(ExamineeRecord examinee) async {
    final write = await _client.setExamineeArchived(examinee.id, true);
    if (!write.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(write.error));
    }
    return _toExamineeRecord(write.examinee!);
  }

  /// Restores [examinee] back to `active` — never touches its examination
  /// history.
  Future<ExamineeRecord> restoreExaminee(ExamineeRecord examinee) async {
    final write = await _client.setExamineeArchived(examinee.id, false);
    if (!write.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(write.error));
    }
    return _toExamineeRecord(write.examinee!);
  }

  /// Links [scan] (identified by [batchId]/[scan]'s id) to [examinee] —
  /// called only AFTER Guidance Council has explicitly confirmed the link
  /// (an OCR-suggested match, or a manual pick); this method itself performs
  /// no matching, no suggestion, and no automatic merge of any kind.
  ///
  /// One examinee may hold at most one scan per exam type (QTM/TAT/AT).
  /// That is checked here BEFORE the write, using [examCode]; the database
  /// unique index (a separate, not-yet-applied migration) is the final
  /// protection against races, and its violation (23505) is translated to
  /// the same friendly message — a raw database error is never shown. On
  /// any rejection the scan is left untouched (still unlinked).
  Future<void> linkScanToExaminee({
    required String batchId,
    required LocalScan scan,
    required ExamineeRecord examinee,
    required String examCode,
  }) async {
    final existing = await _client.readCloudScansForExaminee(examinee.id);
    if (!existing.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(existing.error));
    }
    final wanted = examCode.trim().toUpperCase();
    final alreadyHasType = existing.scans.any(
      (s) =>
          s.examCode.trim().toUpperCase() == wanted &&
          !(s.batchId == batchId && s.id == scan.id),
    );
    if (alreadyHasType) {
      throw GuidanceWebExamineeRecordsException(_duplicateExamMessage(examCode));
    }

    final outcome = await _client.linkScanToExaminee(
      batchId: batchId,
      scanId: scan.id,
      examineeId: examinee.id,
    );
    if (!outcome.isSuccess) {
      if (outcome.isConflict) {
        // Guarded update matched no unlinked row: someone else already
        // linked this scan (or it is gone). Nothing was overwritten.
        throw GuidanceWebExamineeRecordsException(
          'This examination is already linked to an examinee or is no longer '
          'available. Refresh the Unlinked Scans list and try again.',
        );
      }
      if (outcome.isPermanent && outcome.code == '23505') {
        throw GuidanceWebExamineeRecordsException(_duplicateExamMessage(examCode));
      }
      throw GuidanceWebExamineeRecordsException(_messageFor(outcome));
    }
  }

  /// "Remove Link": detaches one scan from [examineeId] (`scans.examinee_id`
  /// -> NULL) and NOTHING else — the scan, its data, and its batch are never
  /// deleted, and it simply reappears in the Unlinked Scans queue. Never
  /// creates an examinee and never relinks the scan anywhere. The write is
  /// guarded by batch + scan + the current examinee, so a scan that is
  /// already unlinked or belongs to someone else is not modified and is
  /// reported as a failure, not success.
  Future<void> removeExamLink({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) async {
    final outcome = await _client.unlinkScanFromExaminee(
      batchId: batchId,
      scanId: scanId,
      examineeId: examineeId,
    );
    if (outcome.isSuccess) return;
    if (outcome.isConflict) {
      throw GuidanceWebExamineeRecordsException(
        'This examination is no longer linked to this examinee. '
        'The page has been refreshed.',
      );
    }
    if (outcome.isTransient) {
      throw GuidanceWebExamineeRecordsException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    throw GuidanceWebExamineeRecordsException(
      'Could not remove this link. Please try again.',
    );
  }

  String _duplicateExamMessage(String examCode) {
    final code = examCode.trim().toUpperCase();
    final article = code == 'AT' ? 'an' : 'a';
    return 'Cannot link this examination.\n\n'
        'This examinee already has $article $code examination record.';
  }

  ExamineeRecord _toExamineeRecord(CloudExamineeRow row) => ExamineeRecord(
        id: row.id,
        temporaryExamineeId: row.temporaryExamineeId,
        officialStudentId: row.officialStudentId,
        firstName: row.firstName,
        middleName: row.middleName,
        lastName: row.lastName,
        birthDate: row.birthDate,
        lastAttendedSchool: row.lastAttendedSchool,
        status: row.status,
        archivedAt: row.archivedAt,
        archivedByUid: row.archivedByUid,
        createdAt: row.createdAt,
        createdByUid: row.createdByUid,
        updatedAt: row.updatedAt,
        updatedByUid: row.updatedByUid,
      );

  String _messageFor(SyncOutcome? outcome) {
    if (outcome != null && outcome.isTransient) {
      return 'Could not reach Supabase. Check your connection and try again.';
    }
    return 'Could not load examinee data. Please try again.';
  }
}

/// Identical to `GuidanceWebResultsService`'s private `_WebSyncIdentity` —
/// duplicated rather than shared so this feature has no dependency on that
/// unrelated service file.
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
