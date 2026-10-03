import 'sync_outcome.dart';

/// One retained (not-yet-expired) soft-deleted UNLINKED scan, as returned by
/// the `list_retained_soft_deleted_scans_for_guidance` RPC (see
/// 0011_list_retained_soft_deleted_scans_for_guidance.sql). Deliberately
/// carries ONLY the minimal identifying/lifecycle metadata that RPC itself
/// returns -- no `decoded`, `raw_score`, `total_graded`, `total_items`,
/// `score_percentage`, `result_status`, image path, or any other
/// answer/result/Storage-object field; none of that is ever queried by this
/// read path.
class CloudRetainedDeletedScanRow {
  const CloudRetainedDeletedScanRow({
    required this.batchId,
    required this.scanId,
    required this.examCode,
    required this.deletedAt,
    required this.retentionUntil,
    this.deletionReason,
    this.deletedByName,
    this.activeRestoreRequestStatus,
  });

  final String batchId;
  final String scanId;
  final String examCode;
  final DateTime deletedAt;
  final DateTime retentionUntil;
  final String? deletionReason;
  final String? deletedByName;

  /// `'PENDING'` | `'APPROVED'` | null, exactly as the RPC returns it (a
  /// left join against `scan_restore_requests` filtered to those two
  /// statuses). Null means no active request exists yet for this scan --
  /// "Request Restore" may be offered; a non-null value means one already
  /// does, and the UI must not offer a second one.
  final String? activeRestoreRequestStatus;

  bool get hasActiveRestoreRequest => activeRestoreRequestStatus != null;
}

/// The result of [ScanRestoreClient.listRetainedSoftDeletedScans].
class CloudRetainedDeletedScansRead {
  CloudRetainedDeletedScansRead.found(this.scans) : error = null;

  const CloudRetainedDeletedScansRead.failed(this.error) : scans = const [];

  final List<CloudRetainedDeletedScanRow> scans;

  /// Set only when the read failed -- never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// The Guidance Council Web Console's "Soft-Deleted Scans" tab -- deliberately
/// its own tiny interface, not a method on [SyncClient] or [ScanDeleteClient]
/// (same reasoning as `ScanDeleteClient`'s own doc comment: adding these to a
/// broader interface would force every existing fake `implements SyncClient`
/// across the test suite to gain stubs for a capability almost none of them
/// exercise). [SupabaseSyncClient] implements this alongside `SyncClient`,
/// `RetakeClient` and `ScanDeleteClient`, using the exact same guarded-call
/// shape (`SupabaseSyncClient`'s own `_guardPostgrest`) as every other cloud
/// operation.
///
/// Both methods call a Guidance-Council-only RPC --
/// `auth.jwt() ->> 'user_role' = 'guidance_council'` is enforced by the
/// database itself (0009/0011), never re-checked or duplicated here. Neither
/// method is a System-Admin-only RPC, and neither ever exposes one.
abstract class ScanRestoreClient {
  /// Every retained (`deleted_at IS NOT NULL AND retention_until > now()`),
  /// still-unlinked scan, via `list_retained_soft_deleted_scans_for_guidance`
  /// -- read-only, no parameters. A scan whose retention window has expired,
  /// or that has since been restored, simply stops appearing here -- this
  /// client never filters or recomputes that itself; the RPC's own `WHERE`
  /// clause is the sole authority.
  Future<CloudRetainedDeletedScansRead> listRetainedSoftDeletedScans();

  /// Queues a restoration request for one retained scan via
  /// `create_scan_restore_request`. The database alone decides eligibility
  /// (still within retention, no existing active request, still unlinked,
  /// caller identity) -- a request for an ineligible scan fails with a
  /// permanent [SyncOutcome], never silently succeeds. [requestedByUid] can
  /// never be used to impersonate someone else: the RPC independently
  /// re-verifies it against the authenticated JWT `sub`.
  Future<SyncOutcome> createScanRestoreRequest({
    required String batchId,
    required String scanId,
    required String reason,
    required String requestedByUid,
    String? requestedByName,
  });
}
