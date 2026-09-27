import '../core/sync/retake_client.dart';

/// A retake request, cloud-independent — built from a [CloudRetakeRequestRow]
/// by [examRetakeRequestFromCloudRow], the same convention
/// `examineeRecordFromCloudRow` (`guidance_web_examinee_records_service.dart`)
/// already uses for [ExamineeRecord]. Kept in `models/` (never a raw
/// [CloudRetakeRequestRow]) so the UI layer stays decoupled from the
/// Supabase row shape.
///
/// This never represents a write: every mutation of the applicant's retake
/// state goes through `GuidanceWebExamineeRecordsService`'s
/// `requestRetake` / `reviewRetakeRequest` / `archiveRetakeAttempt`, which
/// call the database's own SECURITY DEFINER functions — this class only
/// ever appears as something already read back from `exam_retake_requests`.
class ExamRetakeRequest {
  const ExamRetakeRequest({
    required this.id,
    required this.examineeId,
    required this.examCode,
    required this.reason,
    required this.status,
    this.requestedByName,
    required this.requestedAt,
    this.reviewedByName,
    this.reviewedAt,
    this.reviewNote,
    this.eligibleOn,
  });

  final String id;
  final String examineeId;
  final String examCode;
  final String reason;

  /// 'PENDING' | 'APPROVED' | 'REJECTED' | 'USED' — see [isPending] etc.
  final String status;

  final String? requestedByName;
  final DateTime requestedAt;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final String? reviewNote;

  /// Set once known — the earliest date the retake may be linked. Always
  /// database-computed, never derived here.
  final DateTime? eligibleOn;

  bool get isPending => status.toUpperCase() == 'PENDING';
  bool get isApproved => status.toUpperCase() == 'APPROVED';
  bool get isRejected => status.toUpperCase() == 'REJECTED';
  bool get isUsed => status.toUpperCase() == 'USED';

  /// A request that can still lead to a retake — approved but not yet
  /// consumed, or still awaiting review. While one of these is open for an
  /// exam type, a new request for the same attempt is not offered again.
  bool get isOpen => isPending || isApproved;

  /// Whether [eligibleOn] has been reached, by wall-clock date (never time
  /// of day) as of [now]. False when [eligibleOn] is not yet known — this
  /// is a display convenience only; the database re-checks eligibility
  /// itself at link time regardless of what this returns.
  bool isEligibleOn(DateTime now) {
    final date = eligibleOn;
    if (date == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    final eligible = DateTime(date.year, date.month, date.day);
    return !today.isBefore(eligible);
  }
}

/// One `exam_retake_requests` row as the canonical [ExamRetakeRequest].
ExamRetakeRequest examRetakeRequestFromCloudRow(CloudRetakeRequestRow row) =>
    ExamRetakeRequest(
      id: row.id,
      examineeId: row.examineeId,
      examCode: row.examCode,
      reason: row.reason,
      status: row.status,
      requestedByName: row.requestedByName,
      requestedAt: row.requestedAt,
      reviewedByName: row.reviewedByName,
      reviewedAt: row.reviewedAt,
      reviewNote: row.reviewNote,
      eligibleOn: row.eligibleOn,
    );
