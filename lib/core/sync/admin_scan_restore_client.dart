import 'sync_outcome.dart';

/// One soft-deleted unlinked scan as returned by
/// `list_soft_deleted_unlinked_scans_for_admin` (see
/// 0009_create_unlinked_scan_soft_delete.sql, section E). System-Admin-only,
/// and deliberately NOT retention-filtered the way the Guidance Council
/// equivalent (`CloudRetainedDeletedScanRow`) is -- this listing includes
/// scans whose retention window has already expired too, since a System
/// Admin needs full lifecycle visibility, not just what is still
/// actionable. Carries ONLY the same minimal identifying/lifecycle metadata
/// the RPC itself returns -- no `decoded`, score, result, or image field
/// exists on this class.
class CloudAdminSoftDeletedScanRow {
  const CloudAdminSoftDeletedScanRow({
    required this.batchId,
    required this.scanId,
    required this.examCode,
    required this.deletedAt,
    required this.retentionUntil,
    this.deletionReason,
    this.deletedByName,
  });

  final String batchId;
  final String scanId;
  final String examCode;
  final DateTime deletedAt;
  final DateTime retentionUntil;
  final String? deletionReason;
  final String? deletedByName;

  /// Purely a local, read-only convenience computed from [retentionUntil]
  /// -- never written back anywhere, and never a substitute for the RPC's
  /// own retention check (`restoreApprovedScan`'s eligibility is always
  /// re-verified server-side, not decided by this getter).
  bool get isRetentionExpired => !retentionUntil.isAfter(DateTime.now());
}

/// The result of [AdminScanRestoreClient.listDeletedScansForAdmin].
class CloudAdminSoftDeletedScansRead {
  CloudAdminSoftDeletedScansRead.found(this.scans) : error = null;

  const CloudAdminSoftDeletedScansRead.failed(this.error) : scans = const [];

  final List<CloudAdminSoftDeletedScanRow> scans;

  /// Set only when the read failed -- never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// One `scan_restore_requests` row as returned by
/// `list_scan_restore_requests_for_admin`. [status] is one of PENDING /
/// APPROVED / REJECTED / RESTORED / PURGED, exactly as the database's own
/// `scan_restore_requests.status` CHECK constraint allows (see
/// 0009_create_unlinked_scan_soft_delete.sql). Deliberately carries no
/// requester/reviewer UID (only their display names) -- the RPC itself
/// never returns the UIDs, matching the "no unnecessary requester/reviewer
/// metadata" instruction 0011 already followed for its own Guidance
/// Council-facing listing.
class CloudAdminRestoreRequestRow {
  const CloudAdminRestoreRequestRow({
    required this.requestId,
    required this.batchId,
    required this.scanId,
    required this.examCode,
    required this.status,
    required this.reason,
    this.requestedByName,
    required this.requestedAt,
    this.reviewedByName,
    this.reviewedAt,
    this.reviewNote,
  });

  final String requestId;
  final String batchId;
  final String scanId;
  final String examCode;
  final String status;
  final String reason;
  final String? requestedByName;
  final DateTime requestedAt;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final String? reviewNote;

  bool get isPending => status.toUpperCase() == 'PENDING';
  bool get isApproved => status.toUpperCase() == 'APPROVED';
  bool get isRejected => status.toUpperCase() == 'REJECTED';
  bool get isRestored => status.toUpperCase() == 'RESTORED';
  bool get isPurged => status.toUpperCase() == 'PURGED';
}

/// The result of [AdminScanRestoreClient.listRestoreRequestsForAdmin].
class CloudAdminRestoreRequestsRead {
  CloudAdminRestoreRequestsRead.found(this.requests) : error = null;

  const CloudAdminRestoreRequestsRead.failed(this.error) : requests = const [];

  final List<CloudAdminRestoreRequestRow> requests;

  /// Set only when the read failed -- never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// The System Admin restore-management workflow (Part of a separate, later
/// phase from the Guidance Council side -- see [ScanDeleteClient]/
/// [ScanRestoreClient]) -- deliberately its own tiny interface, never a
/// method on [SyncClient], for exactly the reason those two interfaces are
/// separate from it (see their own doc comments): adding these four methods
/// to [SyncClient] would force every existing fake `implements SyncClient`
/// across the test suite to gain stubs for a capability almost none of them
/// exercise. [SupabaseSyncClient] implements this alongside `SyncClient`,
/// `RetakeClient`, `ScanDeleteClient` and `ScanRestoreClient`, using the
/// exact same guarded-call shape (`SupabaseSyncClient`'s own
/// `_guardPostgrest`) as every other cloud operation.
///
/// Every method here calls a System-Admin-only RPC --
/// `auth.jwt() ->> 'user_role' = 'system_admin'` is enforced by the
/// database itself (0009), never re-checked or duplicated here. None of
/// these methods is ever reachable from, or exposes anything to, the
/// Guidance Council side of this app.
abstract class AdminScanRestoreClient {
  /// Every soft-deleted unlinked scan (retained or already expired), via
  /// `list_soft_deleted_unlinked_scans_for_admin` -- read-only, no
  /// parameters.
  Future<CloudAdminSoftDeletedScansRead> listDeletedScansForAdmin();

  /// Every restore request ever filed, via
  /// `list_scan_restore_requests_for_admin` -- read-only, no parameters.
  Future<CloudAdminRestoreRequestsRead> listRestoreRequestsForAdmin();

  /// Approves or rejects a PENDING request via `review_scan_restore_request`
  /// (`p_action` is the literal `'APPROVE'`/`'REJECT'` that function
  /// accepts). The database alone decides whether [requestId] is still
  /// PENDING and reviewable -- never assumed or re-checked here.
  /// [reviewerUid] can never be used to impersonate someone else: the RPC
  /// independently re-verifies it against the authenticated JWT `sub`.
  /// Approval is explicitly NOT restoration -- see [restoreApprovedScan].
  Future<SyncOutcome> reviewRestoreRequest({
    required String requestId,
    required bool approve,
    required String reviewerUid,
    String? reviewerName,
    String? reviewNote,
  });

  /// Restores the scan behind an APPROVED [requestId] via
  /// `restore_soft_deleted_scan`. The database alone decides whether the
  /// request is still APPROVED and the scan is still within its retention
  /// window -- never assumed or re-checked here. Never touches Storage.
  /// [reviewerUid] can never be used to impersonate someone else: the RPC
  /// independently re-verifies it against the authenticated JWT `sub`.
  Future<SyncOutcome> restoreApprovedScan({
    required String requestId,
    required String reviewerUid,
    String? reviewerName,
  });
}
