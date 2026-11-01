import 'sync_client.dart';
import 'sync_outcome.dart';

/// Applicant details and the exam date, written only from the Guidance
/// Council Web Console (Examinee Records).
///
/// A separate small interface (like [RetakeClient] / [ScanDeleteClient]) so
/// the large [SyncClient] contract -- which many fakes implement member by
/// member -- is not widened. `SupabaseSyncClient` implements both; a caller
/// that is handed only a [SyncClient] gets these when that client happens to
/// be one (always, in production).
///
/// Backed by migration `0013_add_examinee_details_and_scan_exam_date.sql`:
///  * `examinees.birth_date` / `last_attended_school` / `gender` -- person
///    level, one value per examinee.
///  * `scans.exam_date` -- sitting level, so a retake keeps its own date.
///
/// Dates are calendar dates (`YYYY-MM-DD`) with no time or zone to shift.
abstract class ExamineeDetailsClient {
  /// "Create Examinee Record from this Scan" with the details saved in the
  /// same all-or-nothing transaction
  /// (`create_examinee_from_scan_with_details`). Returns the new row.
  Future<CloudExamineeWrite> createExamineeFromScanWithDetails({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
    DateTime? birthDate,
    String? lastAttendedSchool,
    String? gender,
    DateTime? examDate,
  });

  /// Updates only birth date, last school attended and gender of an existing
  /// examinee (a null value clears that field). Names, the Temporary
  /// Examinee ID, status and every other column are left exactly as they
  /// were. Returns the row as it now stands.
  Future<CloudExamineeWrite> updateExamineeDetails({
    required String id,
    DateTime? birthDate,
    String? lastAttendedSchool,
    String? gender,
  });

  /// Sets (or, with a null [examDate], clears) the exam date of one scan via
  /// `set_scan_exam_date`. Only `scans.exam_date` changes.
  Future<SyncOutcome> setScanExamDate({
    required String batchId,
    required String scanId,
    DateTime? examDate,
  });
}
