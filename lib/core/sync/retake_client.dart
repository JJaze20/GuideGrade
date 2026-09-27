import 'sync_outcome.dart';

/// One `exam_retake_requests` row, read-only — the retake workflow's ledger
/// (see `create_exam_retake_request` / `review_exam_retake_request` /
/// `archive_approved_retake_attempt`). Guidance Council only ever reads this
/// table directly (RLS grants SELECT); every write goes through those
/// SECURITY DEFINER functions — this class never appears as an
/// INSERT/UPDATE payload, only as something [RetakeClient.readRetakeRequests]
/// returns.
class CloudRetakeRequestRow {
  const CloudRetakeRequestRow({
    required this.id,
    required this.examineeId,
    required this.examCode,
    this.previousScanBatchId,
    this.previousScanId,
    required this.reason,
    required this.status,
    this.requestedByUid,
    this.requestedByName,
    required this.requestedAt,
    this.reviewedByUid,
    this.reviewedByName,
    this.reviewedAt,
    this.reviewNote,
    this.eligibleOn,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String examineeId;
  final String examCode;
  final String? previousScanBatchId;
  final String? previousScanId;
  final String reason;

  /// 'PENDING' | 'APPROVED' | 'REJECTED' | 'USED', as written by the
  /// database functions. Compared case-insensitively everywhere this app
  /// reads it (see [isPending] etc.), so a casing difference in the actual
  /// stored value can never silently misclassify a request.
  final String status;

  final String? requestedByUid;
  final String? requestedByName;
  final DateTime requestedAt;
  final String? reviewedByUid;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final String? reviewNote;

  /// Set once known (by the review/create function) — the earliest date the
  /// retake may be linked, computed and stored by the database, never by
  /// this app. Null before it is known.
  final DateTime? eligibleOn;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isPending => status.toUpperCase() == 'PENDING';
  bool get isApproved => status.toUpperCase() == 'APPROVED';
  bool get isRejected => status.toUpperCase() == 'REJECTED';
  bool get isUsed => status.toUpperCase() == 'USED';

  /// A request that can still lead to a retake being linked — approved, but
  /// not yet consumed. Used to decide whether "Request Retake" should be
  /// offered again (it should not, while one of these is open) and whether
  /// "Archive Attempt" applies.
  bool get isOpen => isPending || isApproved;
}

/// The result of [RetakeClient.readRetakeRequests].
class CloudRetakeRequestsRead {
  CloudRetakeRequestsRead.found(this.requests) : error = null;

  const CloudRetakeRequestsRead.failed(this.error) : requests = const [];

  final List<CloudRetakeRequestRow> requests;

  /// Set only when the read failed — never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// Applicant Retake Management — additive, Guidance-Council-only, and kept
/// as its OWN small interface (rather than added to [SyncClient]) so this
/// new capability does not force every existing `implements SyncClient`
/// fake across the test suite to grow four unrelated stub methods.
/// [SupabaseSyncClient] implements this alongside `SyncClient`, using the
/// exact same guarded-call shape ([SupabaseSyncClient]'s own
/// `_guardPostgrest`) as every other cloud operation.
///
/// Every WRITE here goes through a SECURITY DEFINER database function —
/// never a plain insert/update on `exam_retake_requests` or the `scans`
/// attempt columns (both are blocked for direct client mutation). The
/// actor's uid/name are resolved from the signed-in identity inside the
/// implementation, exactly like [SyncClient.archiveBatch] does for the Web
/// Batch Archive — never passed in by the caller.
///
/// None of these methods returns the RPC's own result row: the functions'
/// exact return shape has not been verified against the live database, so
/// rather than guess at it, a write here reports only success/failure and
/// the caller re-reads the affected rows with [readRetakeRequests] (the
/// same pattern [GuidanceWebExamineeRecordsService] already uses after
/// Remove Link — "success or conflict alike, re-read the truth from the
/// database").
abstract class RetakeClient {
  /// Every `exam_retake_requests` row for [examineeId]/[examCode], newest
  /// first — read-only (Guidance Council RLS). Used to show the current
  /// request for an attempt (if any) and its `eligible_on` once known.
  Future<CloudRetakeRequestsRead> readRetakeRequests({
    required String examineeId,
    required String examCode,
  });

  /// Creates a PENDING retake request via `create_exam_retake_request`.
  /// The database is the sole judge of whether [examineeId] may actually
  /// request a retake of [examCode] (attempt count, an already-open
  /// request, ...); a request for an ineligible attempt fails with a
  /// permanent [SyncOutcome], never silently succeeds.
  Future<SyncOutcome> createRetakeRequest({
    required String examineeId,
    required String examCode,
    required String reason,
  });

  /// Approves or rejects [requestId] via `review_exam_retake_request`
  /// (`p_action` is the literal `'APPROVE'` or `'REJECT'` that function
  /// accepts). A rejected request does not consume the applicant's retake
  /// and can be re-requested later — enforced by the database, not by this
  /// client.
  Future<SyncOutcome> reviewRetakeRequest({
    required String requestId,
    required bool approve,
    String? reviewNote,
  });

  /// Archives the previous attempt behind an APPROVED [requestId] via
  /// `archive_approved_retake_attempt`. Never deletes the scan, its batch,
  /// or its examinee link — it only flips the previous attempt to archived
  /// with [archiveReason] recorded (the database itself blocks any other
  /// way of changing those columns).
  Future<SyncOutcome> archiveRetakeAttempt({
    required String requestId,
    required String archiveReason,
  });
}
