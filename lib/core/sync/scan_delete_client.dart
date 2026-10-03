import 'sync_outcome.dart';

/// [SyncOutcome.code] for [ScanDeleteClient.deleteUnlinkedScan]'s one
/// partial-success case: the `scans` row DELETE already committed, but
/// removing one or more of its Storage objects afterward failed. The row is
/// gone either way — a caller must treat this as "the scan is deleted" for
/// list/UI purposes, while still surfacing that Storage cleanup needs
/// attention, never as a plain retryable failure and never as a silent
/// success. [SyncOutcome.kind] is still `transient` or `permanent`
/// (whichever the Storage error itself was), matching every other cloud
/// operation's convention — only [SyncOutcome.code] is special-cased to this
/// value so a caller can distinguish it from every other failure.
const String scanDeletedStorageIncompleteCode = 'row_deleted_storage_incomplete';

/// The Guidance Council Web Console's "Delete" action for the Unlinked
/// Scans queue — deliberately its own tiny interface, not a method on
/// [SyncClient] itself, for exactly the reason `RetakeClient` is separate
/// (see its own doc comment): adding a method straight to [SyncClient]
/// would force every existing fake `implements SyncClient` across the test
/// suite to gain a stub for a capability almost none of them exercise.
/// [SupabaseSyncClient] implements this alongside `SyncClient`, using the
/// exact same guarded-call shape ([SupabaseSyncClient]'s own
/// `_guardPostgrest`/`_guardStorage`) as every other cloud operation.
abstract class ScanDeleteClient {
  /// Permanently deletes ONE scan row and its Storage images (original,
  /// rectified, and the three name-crop variants) — ONLY if the scan is
  /// still unlinked (`examinee_id IS NULL`) AND is not an archived
  /// historical attempt (`attempt_status` is not, case-insensitively,
  /// `'ARCHIVED'`) at the moment of the write.
  ///
  /// Both conditions are enforced by the DELETE statement itself (`batch_id`
  /// + `id` + `examinee_id IS NULL` + `attempt_status NOT ILIKE 'ARCHIVED'`),
  /// never assumed from an already-displayed snapshot or checked with a
  /// prior read — a scan that became linked to an examinee, or that is an
  /// archived attempt, between the Unlinked Scans list loading and this call
  /// is never deleted; there is no read-then-delete race window. The
  /// `ILIKE`-based comparison mirrors `CloudScanRow.isArchivedAttempt`'s own
  /// case-insensitive `'ARCHIVED'` comparison exactly, so this enforces the
  /// same rule the rest of the app already uses to mean "archived", not a
  /// new one. Exactly one row must be removed; zero rows (already deleted,
  /// missing, no longer unlinked, or an archived attempt) is reported as
  /// [SyncOutcome.conflict] (`scan_not_unlinked`), never success.
  ///
  /// A scan still referenced by `exam_retake_requests.previous_scan_id`
  /// (an `ON DELETE RESTRICT` foreign key) is rejected by the database
  /// itself — reported as [SyncOutcome.permanent] (`23503`), never
  /// bypassed or worked around here.
  ///
  /// Never writes `guidance_activity` — the existing `scan_deleted` audit
  /// event is produced by the database's own `trg_audit_scan_delete`
  /// trigger on every `scans` DELETE, this method included.
  ///
  /// If the row DELETE succeeds but removing its Storage objects
  /// afterward fails, this is reported with [scanDeletedStorageIncompleteCode]
  /// (see that constant's own doc) — never as a plain success, and never
  /// discarding the fact that the row itself is already gone.
  Future<SyncOutcome> deleteUnlinkedScan({
    required String batchId,
    required String scanId,
  });

  /// The 30-day-retention alternative to [deleteUnlinkedScan]: calls the
  /// `soft_delete_unlinked_scan` SECURITY DEFINER RPC, which re-enforces
  /// every precondition itself (caller is Guidance Council, [deletedByUid]
  /// matches the authenticated JWT `sub`, the scan exists/is unlinked/is
  /// not an archived attempt/is not already soft-deleted, a non-blank
  /// [deletionReason]) -- none of that is duplicated here. Sets
  /// `retention_until = now() + 30 days` and writes the `scan_soft_deleted`
  /// audit event, both inside the RPC. Never deletes the row, never
  /// touches Storage.
  Future<SyncOutcome> softDeleteUnlinkedScan({
    required String batchId,
    required String scanId,
    required String deletedByUid,
    String? deletedByName,
    required String deletionReason,
  });
}
