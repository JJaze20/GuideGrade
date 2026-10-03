import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/local_batch_repository.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/sync/cloud_batch_mapper.dart';
import '../../../core/sync/supabase_sync_client.dart';
import '../../../core/sync/sync_client.dart';
import '../../../core/sync/retake_client.dart';
import '../../../core/sync/scan_delete_client.dart';
import '../../../core/sync/scan_restore_client.dart';
import '../../../core/sync/sync_outcome.dart';
import '../../../core/sync/sync_queue.dart' show SyncState;
import '../../../models/exam_retake_request.dart';
import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart';

/// Thrown by [GuidanceWebExamineeRecordsService] on any failure. Carries
/// only an already-sanitized, user-safe message — never a raw exception, a
/// Supabase error code, or a stack trace. Mirrors
/// `GuidanceWebResultsException` exactly.
class GuidanceWebExamineeRecordsException implements Exception {
  GuidanceWebExamineeRecordsException(this.message, {this.scanWasDeleted = false});
  final String message;

  /// Set only by [GuidanceWebExamineeRecordsService.deleteUnlinkedScan] for
  /// its one partial-success case: the scan's database row was already
  /// permanently deleted before this exception was thrown (Storage cleanup
  /// afterward failed). A caller must still remove the scan from whatever
  /// list it is holding -- the database no longer has it -- even though this
  /// is an exception, not a plain successful return. False for every other
  /// throw site in this file.
  final bool scanWasDeleted;

  @override
  String toString() => message;
}

/// Shown wherever linking a scan to an archived examinee is refused (the
/// service rule and the Examinee Detail hint), so both say the same thing.
const String archivedExamineeLinkMessage =
    'Archived examinees cannot be linked to new scans. Restore the examinee first.';

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
  /// [retakeClient] is only for tests. In production, [SupabaseSyncClient]
  /// implements both `SyncClient` and [RetakeClient], so a caller that
  /// passes only [client] still gets real retake behavior when that
  /// [client] happens to be one (i.e. always, in production); [retakeClient]
  /// need only be supplied explicitly when a test's fake [client] does not
  /// also implement [RetakeClient].
  /// [scanDeleteClient] is only for tests, same reasoning as [retakeClient]
  /// -- see [_scanDeleteClient]'s doc comment.
  /// [scanRestoreClient] is only for tests, same reasoning as [retakeClient]
  /// / [scanDeleteClient] -- see [_scanRestoreClient]'s doc comment.
  /// [identity] is only for tests, same reasoning as [retakeClient] /
  /// [scanDeleteClient] -- see [_identity]'s own doc comment.
  GuidanceWebExamineeRecordsService({
    SyncClient? client,
    RetakeClient? retakeClient,
    ScanDeleteClient? scanDeleteClient,
    ScanRestoreClient? scanRestoreClient,
    SyncIdentity? identity,
  })  : _client = client ?? _buildDefaultClient(),
        _explicitRetakeClient = retakeClient,
        _explicitScanDeleteClient = scanDeleteClient,
        _explicitScanRestoreClient = scanRestoreClient,
        _explicitIdentity = identity;

  final SyncClient _client;
  final RetakeClient? _explicitRetakeClient;
  final ScanDeleteClient? _explicitScanDeleteClient;
  final ScanRestoreClient? _explicitScanRestoreClient;
  final SyncIdentity? _explicitIdentity;

  /// Same lazy-resolution reasoning as [_retakeClient]/[_scanDeleteClient]:
  /// a caller that supplies [_explicitIdentity] (every existing test) never
  /// pays for (or crashes on) building [_WebSyncIdentity], which reads
  /// `FirebaseAuth.instance` -- unavailable in a plain `flutter test` unit
  /// test with no Firebase app initialized. Production code never supplies
  /// it, so [softDeleteUnlinkedScan] keeps reading the real signed-in
  /// Firebase user exactly as before.
  late final SyncIdentity _identity = _explicitIdentity ?? _WebSyncIdentity();

  /// Resolved lazily (never at construction) so a caller that supplies
  /// neither [retakeClient] nor a [client] implementing [RetakeClient] --
  /// every existing caller and test, which never touches a retake method --
  /// never pays for (or crashes on) building a real [SupabaseSyncClient]
  /// just to satisfy this field.
  late final RetakeClient _retakeClient = _explicitRetakeClient ??
      (_client is RetakeClient ? _client as RetakeClient : _buildDefaultClient());

  /// Same lazy-resolution reasoning as [_retakeClient]: a caller that
  /// supplies neither [scanDeleteClient] nor a [client] implementing
  /// [ScanDeleteClient] -- every existing caller and test, which never
  /// touches [deleteUnlinkedScan] -- never pays for (or crashes on)
  /// building a real [SupabaseSyncClient] just to satisfy this field.
  late final ScanDeleteClient _scanDeleteClient = _explicitScanDeleteClient ??
      (_client is ScanDeleteClient ? _client as ScanDeleteClient : _buildDefaultClient());

  /// Same lazy-resolution reasoning as [_retakeClient]/[_scanDeleteClient]:
  /// a caller that supplies neither [scanRestoreClient] nor a [client]
  /// implementing [ScanRestoreClient] -- every existing caller and test,
  /// which never touches [loadRetainedSoftDeletedScans]/
  /// [requestScanRestoration] -- never pays for (or crashes on) building a
  /// real [SupabaseSyncClient] just to satisfy this field.
  late final ScanRestoreClient _scanRestoreClient = _explicitScanRestoreClient ??
      (_client is ScanRestoreClient ? _client as ScanRestoreClient : _buildDefaultClient());

  /// See `GuidanceWebResultsService._buildDefaultClient`'s doc comment —
  /// identical reasoning: [LocalBatchRepository]/[LocalStorageService] are
  /// required constructor params [SupabaseSyncClient] never actually reads
  /// for the methods this service calls.
  static SupabaseSyncClient _buildDefaultClient() {
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
      items.add(ExamineeHistoryItem(
        batch: batch,
        scan: mapCloudScan(row),
        attemptNo: row.attemptNo,
        attemptStatus: row.attemptStatus,
        archivedAt: row.archivedAt,
        archivedByName: row.archivedByName,
        archiveReason: row.archiveReason,
      ));
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
  ///
  /// Only an ACTIVE examinee can receive a scan; an archived one must be
  /// restored first. That is checked before anything is written, against the
  /// examinee's CURRENT status (not just the possibly-stale [examinee] the UI
  /// is holding), so the rule holds even if the page is out of date.
  Future<void> linkScanToExaminee({
    required String batchId,
    required LocalScan scan,
    required ExamineeRecord examinee,
    required String examCode,
  }) async {
    await _requireActiveExaminee(examinee);

    final existing = await _client.readCloudScansForExaminee(examinee.id);
    if (!existing.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(existing.error));
    }
    final wanted = examCode.trim().toUpperCase();
    final alreadyHasType = existing.scans.any(
      (s) =>
          s.examCode.trim().toUpperCase() == wanted &&
          !s.isArchivedAttempt &&
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

  /// "Delete" (Unlinked Scans tab only): permanently removes one unlinked
  /// scan's row and its Storage images. Both the unlinked condition
  /// (`scans.examinee_id IS NULL`) and the archived-attempt protection
  /// (`attempt_status` not, case-insensitively, `'ARCHIVED'`) are enforced
  /// by the database write itself -- see [ScanDeleteClient.deleteUnlinkedScan]
  /// -- never assumed from the caller's already-displayed snapshot, so a
  /// scan that became linked to an examinee, or that is an archived
  /// attempt, between page load and this call is never deleted.
  ///
  /// A scan still referenced by an `exam_retake_requests` row is rejected
  /// by the database's own foreign key and reported here as a specific,
  /// friendly message -- never bypassed, and `exam_retake_requests` is
  /// never touched by this method.
  Future<void> deleteUnlinkedScan({
    required String batchId,
    required String scanId,
  }) async {
    final outcome = await _scanDeleteClient.deleteUnlinkedScan(
      batchId: batchId,
      scanId: scanId,
    );
    if (outcome.isSuccess) return;
    // Checked before the isTransient/isPermanent branches below: this code
    // can arrive with either kind (whichever the Storage failure itself
    // was), and either way the row is ALREADY gone -- this must never fall
    // into the generic "could not delete" message, which would wrongly
    // imply nothing happened.
    if (outcome.code == scanDeletedStorageIncompleteCode) {
      throw GuidanceWebExamineeRecordsException(
        'The scan was deleted and will no longer appear in Unlinked Scans, '
        'but cleanup of one or more of its images in Storage failed. This '
        'cannot be retried from here -- please report it so the remaining '
        'image(s) can be removed manually.',
        scanWasDeleted: true,
      );
    }
    if (outcome.isConflict) {
      throw GuidanceWebExamineeRecordsException(
        'This scan is no longer unlinked or no longer exists. '
        'Refresh the Unlinked Scans list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '23503') {
      throw GuidanceWebExamineeRecordsException(
        'This scan cannot be deleted because it is referenced by an '
        'existing retake request. Resolve that retake request first.',
      );
    }
    if (outcome.isTransient) {
      throw GuidanceWebExamineeRecordsException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    throw GuidanceWebExamineeRecordsException(
      'Could not delete this scan. Please try again.',
    );
  }

  /// "Delete" with 30-day retention (Unlinked Scans tab only): soft-deletes
  /// one unlinked scan via the `soft_delete_unlinked_scan` RPC instead of
  /// [deleteUnlinkedScan]'s permanent row/Storage removal. Every business
  /// rule (unlinked, not archived, not already soft-deleted, caller
  /// identity, non-blank reason) is enforced by the RPC itself -- this
  /// method only translates its outcome into a friendly message, the same
  /// way [deleteUnlinkedScan] does for the hard-delete RPC. Never deletes
  /// Storage.
  ///
  /// The actor is read from the same Firebase-authenticated session every
  /// other write in this service already uses -- never a user-entered or
  /// otherwise client-supplied uid. The RPC independently re-verifies this
  /// uid against the authenticated JWT `sub`, so this value being wrong
  /// (or forged) could never let a caller impersonate someone else; the
  /// server remains the authority.
  Future<void> softDeleteUnlinkedScan({
    required String batchId,
    required String scanId,
    required String deletionReason,
  }) async {
    final uid = _identity.uid;
    if (uid == null || uid.isEmpty) {
      throw GuidanceWebExamineeRecordsException(
        'You must be signed in to delete this scan. Please sign in again.',
      );
    }
    final displayName = _identity.displayName;

    final outcome = await _scanDeleteClient.softDeleteUnlinkedScan(
      batchId: batchId,
      scanId: scanId,
      deletedByUid: uid,
      deletedByName: displayName,
      deletionReason: deletionReason,
    );
    if (outcome.isSuccess) return;
    if (outcome.isPermanent && outcome.code == 'P0002') {
      throw GuidanceWebExamineeRecordsException(
        'This scan no longer exists. Refresh the Unlinked Scans list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '42501') {
      throw GuidanceWebExamineeRecordsException(
        'This scan can no longer be deleted this way -- it may already be linked, '
        'archived, or already deleted. Refresh the Unlinked Scans list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '22023') {
      throw GuidanceWebExamineeRecordsException(
        'A reason is required to delete this scan.',
      );
    }
    if (outcome.isTransient) {
      throw GuidanceWebExamineeRecordsException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    throw GuidanceWebExamineeRecordsException(
      'Could not delete this scan. Please try again.',
    );
  }

  // ---------------------------------------------------------------------------
  // Soft-Deleted Scans tab -- Guidance Council read of retained (not-yet-
  // expired) soft-deleted scans, plus requesting their restoration. Neither
  // method here ever reaches a System-Admin-only RPC (review/restore remain
  // a later, separate phase); both go through [ScanRestoreClient], which
  // only ever calls Guidance-Council-gated RPCs.
  // ---------------------------------------------------------------------------

  /// Every retained soft-deleted unlinked scan visible to the current
  /// session, via `list_retained_soft_deleted_scans_for_guidance`. A scan
  /// whose retention window has since expired, or that has since been
  /// restored, simply stops appearing here on the next call -- this method
  /// never filters or recomputes that itself.
  Future<List<CloudRetainedDeletedScanRow>> loadRetainedSoftDeletedScans() async {
    final read = await _scanRestoreClient.listRetainedSoftDeletedScans();
    if (!read.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(read.error));
    }
    return read.scans;
  }

  /// Submits a PENDING restoration request for one retained soft-deleted
  /// scan via `create_scan_restore_request` -- the SAME existing RPC from
  /// 0009_create_unlinked_scan_soft_delete.sql already used nowhere else in
  /// this app until now. [reason] is required; the database alone decides
  /// every other eligibility rule (still within retention, no existing
  /// active request, still unlinked, actually soft-deleted).
  ///
  /// The actor is read from the same Firebase-authenticated session every
  /// other write in this service already uses -- never a user-entered or
  /// otherwise client-supplied uid. The RPC independently re-verifies this
  /// uid against the authenticated JWT `sub`, so this value being wrong
  /// (or forged) could never let a caller impersonate someone else; the
  /// server remains the authority.
  Future<void> requestScanRestoration({
    required String batchId,
    required String scanId,
    required String reason,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw GuidanceWebExamineeRecordsException(
        'A reason is required to request restoration of this scan.',
      );
    }

    final uid = _identity.uid;
    if (uid == null || uid.isEmpty) {
      throw GuidanceWebExamineeRecordsException(
        'You must be signed in to request a scan restoration. Please sign in again.',
      );
    }
    final displayName = _identity.displayName;

    final outcome = await _scanRestoreClient.createScanRestoreRequest(
      batchId: batchId,
      scanId: scanId,
      reason: trimmed,
      requestedByUid: uid,
      requestedByName: displayName,
    );
    if (outcome.isSuccess) return;
    if (outcome.isPermanent && outcome.code == 'P0002') {
      throw GuidanceWebExamineeRecordsException(
        'This scan no longer exists. Refresh the Soft-Deleted Scans list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '23505') {
      throw GuidanceWebExamineeRecordsException(
        'A restoration request has already been submitted for this scan.',
      );
    }
    if (outcome.isPermanent && outcome.code == '42501') {
      throw GuidanceWebExamineeRecordsException(
        'This scan can no longer be restored -- it may no longer be soft-deleted, '
        'may already be linked, or its 30-day retention window may have expired. '
        'Refresh the list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '22023') {
      throw GuidanceWebExamineeRecordsException(
        'A reason is required to request restoration of this scan.',
      );
    }
    if (outcome.isTransient) {
      throw GuidanceWebExamineeRecordsException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    throw GuidanceWebExamineeRecordsException(
      'Could not submit this restoration request. Please try again.',
    );
  }

  // ---------------------------------------------------------------------------
  // Applicant Retake Management -- additive. Every write below calls a
  // database SECURITY DEFINER function (see retake_client.dart); none of
  // these ever writes `exam_retake_requests` or a scan's attempt columns
  // directly. Max-attempts and the waiting period are never recomputed
  // here -- the database is the sole authority on eligibility; these
  // methods only report success/failure and the caller re-reads the
  // affected rows (the same "re-read the truth from the database"
  // convention [removeExamLink] already uses).
  // ---------------------------------------------------------------------------

  /// Every retake request recorded for [examineeId]/[examCode], newest
  /// first. Read-only.
  Future<List<ExamRetakeRequest>> retakeRequestsFor({
    required String examineeId,
    required String examCode,
  }) async {
    final read = await _retakeClient.readRetakeRequests(
      examineeId: examineeId,
      examCode: examCode,
    );
    if (!read.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(read.error));
    }
    return read.requests.map(examRetakeRequestFromCloudRow).toList();
  }

  /// Submits a PENDING retake request for [examineeId]/[examCode]. [reason]
  /// is required -- QTM is never a valid [examCode] here (QTM has no retake
  /// at all; the UI never offers this action for it, and the database would
  /// reject it too). The database alone decides whether this examinee may
  /// actually request a retake right now.
  Future<void> requestRetake({
    required String examineeId,
    required String examCode,
    required String reason,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw GuidanceWebExamineeRecordsException('A reason is required to request a retake.');
    }
    final outcome = await _retakeClient.createRetakeRequest(
      examineeId: examineeId,
      examCode: examCode,
      reason: trimmed,
    );
    if (!outcome.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_retakeMessageFor(outcome));
    }
  }

  /// Approves or rejects [requestId]. A rejected request does not consume
  /// the applicant's retake -- the database allows a fresh request to be
  /// submitted afterward, this method does not need to do anything special
  /// for that case.
  Future<void> reviewRetakeRequest({
    required String requestId,
    required bool approve,
    String? reviewNote,
  }) async {
    final trimmedNote = reviewNote?.trim();
    final outcome = await _retakeClient.reviewRetakeRequest(
      requestId: requestId,
      approve: approve,
      reviewNote: (trimmedNote == null || trimmedNote.isEmpty) ? null : trimmedNote,
    );
    if (!outcome.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_retakeMessageFor(outcome));
    }
  }

  /// Archives the previous attempt behind an approved [requestId].
  /// [archiveReason] is required. Never deletes the scan, its batch, or
  /// unlinks the examinee -- see [RetakeClient.archiveRetakeAttempt].
  Future<void> archiveRetakeAttempt({
    required String requestId,
    required String archiveReason,
  }) async {
    final trimmed = archiveReason.trim();
    if (trimmed.isEmpty) {
      throw GuidanceWebExamineeRecordsException('A reason is required to archive this attempt.');
    }
    final outcome = await _retakeClient.archiveRetakeAttempt(
      requestId: requestId,
      archiveReason: trimmed,
    );
    if (!outcome.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_retakeMessageFor(outcome));
    }
  }

  /// Deliberately generic -- the database is the authority on WHY a retake
  /// write was refused (max attempts reached, not yet eligible, wrong
  /// request status, ...); this never repeats a raw database code or
  /// message, matching [_messageFor]'s same convention.
  String _retakeMessageFor(SyncOutcome outcome) {
    if (outcome.isTransient) {
      return 'Could not reach Supabase. Check your connection and try again.';
    }
    if (outcome.isConflict) {
      return 'This request has already changed. Please refresh and try again.';
    }
    return 'This could not be completed. Please check the retake eligibility and try again.';
  }

  /// Throws unless [examinee] exists and is currently active. A held copy
  /// that is already archived is rejected without any read; otherwise the
  /// current row is looked up (one `examinees` read, the same one the page
  /// itself uses) because the copy may be stale -- e.g. archived in another
  /// session after this page loaded. Nothing is written here.
  Future<void> _requireActiveExaminee(ExamineeRecord examinee) async {
    if (examinee.isArchived) {
      throw GuidanceWebExamineeRecordsException(archivedExamineeLinkMessage);
    }
    final read = await _client.readCloudExaminees();
    if (!read.isSuccess) {
      throw GuidanceWebExamineeRecordsException(_messageFor(read.error));
    }
    final current = read.examinees.where((e) => e.id == examinee.id).firstOrNull;
    if (current == null) {
      throw GuidanceWebExamineeRecordsException(
        'This examinee record is no longer available. '
        'Refresh Examinee Records and try again.',
      );
    }
    if (_toExamineeRecord(current).isArchived) {
      throw GuidanceWebExamineeRecordsException(archivedExamineeLinkMessage);
    }
  }

  String _duplicateExamMessage(String examCode) {
    final code = examCode.trim().toUpperCase();
    final article = code == 'AT' ? 'an' : 'a';
    return 'Cannot link this examination.\n\n'
        'This examinee already has $article $code examination record.';
  }

  ExamineeRecord _toExamineeRecord(CloudExamineeRow row) =>
      examineeRecordFromCloudRow(row);

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

/// One `examinees` row as the canonical [ExamineeRecord]. Shared by the
/// Examinee Records page and the Results page, which resolves each scan's
/// linked examinee through it, so both read the same fields the same way.
ExamineeRecord examineeRecordFromCloudRow(CloudExamineeRow row) => ExamineeRecord(
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
