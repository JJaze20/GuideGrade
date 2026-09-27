import 'local_batch.dart';

/// The canonical applicant/examinee record — the person, not a single
/// examination event. One [ExamineeRecord] can be linked (via
/// `scans.examinee_id`) to many [LocalScan]s across QTM, TAT, and the
/// Admission Test. Every record originates from a specific scan (created
/// via the "Create Examinee Record from this Scan" workflow) — there is no
/// blank-record creation path anywhere in the app.
///
/// [temporaryExamineeId] is assigned atomically by PostgreSQL itself (a
/// sequence-backed column `DEFAULT` — see
/// `supabase/migrations/0001_create_examinees.sql`), never client-generated
/// and never copied from a scan's own `examinee_number` — immutable once
/// assigned, by design: this class exposes no way to change it after
/// construction, [withProfileEdits] does not accept it as a parameter, and
/// the database enforces the same rule independently via a trigger.
///
/// [officialStudentId] is the Registrar-assigned student number, assigned
/// only if/when the applicant enrolls. GuideGrade is not connected to the
/// Registrar and has no workflow that populates it — it is a dormant
/// nullable field kept only for future forward-compatibility and is never
/// shown or edited anywhere in the UI. Same posture for [birthDate] and
/// [lastAttendedSchool]: applicant-level fields with no established input
/// source yet (see `withProfileEdits`'s doc comment), kept on the model for
/// schema parity only.
class ExamineeRecord {
  const ExamineeRecord({
    required this.id,
    required this.temporaryExamineeId,
    this.officialStudentId,
    required this.firstName,
    this.middleName,
    required this.lastName,
    this.birthDate,
    this.lastAttendedSchool,
    required this.status,
    this.archivedAt,
    this.archivedByUid,
    required this.createdAt,
    required this.createdByUid,
    required this.updatedAt,
    required this.updatedByUid,
  });

  final String id;
  final String temporaryExamineeId;
  final String? officialStudentId;
  final String firstName;
  final String? middleName;
  final String lastName;
  final DateTime? birthDate;
  final String? lastAttendedSchool;

  /// `'active'` | `'archived'` — see [isActive]/[isArchived].
  final String status;

  final DateTime? archivedAt;
  final String? archivedByUid;
  final DateTime createdAt;
  final String createdByUid;
  final DateTime updatedAt;
  final String updatedByUid;

  bool get isActive => status == 'active';
  bool get isArchived => status == 'archived';

  /// "Last, First M." — same convention as [ExamineeInfo.displayName].
  String get displayName {
    final last = lastName.trim();
    final first = firstName.trim();
    final middle = (middleName ?? '').trim();
    final middleInitial = middle.isEmpty ? '' : ' ${middle[0].toUpperCase()}.';
    if (last.isNotEmpty && first.isNotEmpty) return '$last, $first$middleInitial';
    if (last.isNotEmpty) return last;
    if (first.isNotEmpty) return '$first$middleInitial';
    return 'Unnamed';
  }

  /// Applies a name-only correction (OCR misread fix) — the only kind of
  /// edit Guidance Council can make. Deliberately has no
  /// [temporaryExamineeId], `status`, `archivedAt`/`archivedByUid`,
  /// `createdAt`/`createdByUid`, [birthDate], [lastAttendedSchool], or
  /// [officialStudentId] parameter: the first four never change through
  /// this method (`status` changes only via [archived]/[restored]); the
  /// last three have no established input source yet (see the class doc
  /// comment) and are carried over unchanged from their current value.
  ExamineeRecord withProfileEdits({
    required String firstName,
    String? middleName,
    required String lastName,
    required DateTime updatedAt,
    required String updatedByUid,
  }) {
    return ExamineeRecord(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      officialStudentId: officialStudentId,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      birthDate: birthDate,
      lastAttendedSchool: lastAttendedSchool,
      status: status,
      archivedAt: archivedAt,
      archivedByUid: archivedByUid,
      createdAt: createdAt,
      createdByUid: createdByUid,
      updatedAt: updatedAt,
      updatedByUid: updatedByUid,
    );
  }

  /// Sets `status` to `'archived'` — never touches examination history, the
  /// linked scans, or any other field.
  ExamineeRecord archived({required DateTime at, required String byUid}) {
    return ExamineeRecord(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      officialStudentId: officialStudentId,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      birthDate: birthDate,
      lastAttendedSchool: lastAttendedSchool,
      status: 'archived',
      archivedAt: at,
      archivedByUid: byUid,
      createdAt: createdAt,
      createdByUid: createdByUid,
      updatedAt: at,
      updatedByUid: byUid,
    );
  }

  /// Sets `status` back to `'active'` — never touches examination history.
  ExamineeRecord restored({required DateTime at, required String byUid}) {
    return ExamineeRecord(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      officialStudentId: officialStudentId,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      birthDate: birthDate,
      lastAttendedSchool: lastAttendedSchool,
      status: 'active',
      archivedAt: null,
      archivedByUid: null,
      createdAt: createdAt,
      createdByUid: createdByUid,
      updatedAt: at,
      updatedByUid: byUid,
    );
  }
}

/// A [LocalScan] paired with the [LocalBatch] it belongs to (for exam code,
/// batch code, and date), so the UI never has to re-derive or recompute a
/// score: everything shown comes straight from these two existing,
/// already-scored models. Used both for one examinee's examination history
/// (a linked scan) and for the "Unlinked Scans" queue (a scan with no
/// examinee yet) — the pairing itself carries no assumption about whether
/// [scan] is linked to anyone.
class ExamineeHistoryItem {
  const ExamineeHistoryItem({
    required this.batch,
    required this.scan,
    this.attemptNo = 1,
    this.attemptStatus = 'active',
    this.archivedAt,
    this.archivedByName,
    this.archiveReason,
  });

  final LocalBatch batch;
  final LocalScan scan;

  /// Applicant Retake Management (additive) -- which attempt this is for its
  /// exam type (QTM is always 1; TAT/AT are 1 or 2), taken directly from the
  /// cloud `scans` row (see `CloudScanRow.attemptNo`), never recomputed
  /// here. Every item this app builds without a retake-aware read (there are
  /// none left after this feature) defaults to "attempt 1, active", so an
  /// older/legacy scan displays exactly as it always has.
  final int attemptNo;

  /// 'active' | 'archived'.
  final String attemptStatus;
  final DateTime? archivedAt;
  final String? archivedByName;
  final String? archiveReason;

  String get examCode => batch.examCode;
  LocalScanResult? get result => scan.result;
  bool get isGraded => scan.result?.status == 'Graded';

  /// Whether this is the previous attempt of an approved, archived retake --
  /// read-only, and must never be shown as the examinee's current result for
  /// [examCode].
  bool get isArchivedAttempt => attemptStatus.toUpperCase() == 'ARCHIVED';
}
