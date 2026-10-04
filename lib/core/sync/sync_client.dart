import 'sync_job.dart';
import 'sync_outcome.dart';

/// The result of [SyncClient.readAnswerKey]: the current cloud `answer_keys`
/// row for one exam code, or an explanation of why it is absent / could not
/// be read.
///
/// It deliberately never carries `updated_by_uid`, an email, or any token —
/// only the version, the flat answers map, the human `updated_by_name`, and
/// the `updated_at` timestamp the resolution UI needs.
class CloudAnswerKeyRead {
  /// A row was found.
  CloudAnswerKeyRead.found({
    required this.version,
    required this.answers,
    required this.updatedByName,
    required this.updatedAt,
  }) : exists = true,
       error = null;

  /// No row exists for this exam code (not an error).
  const CloudAnswerKeyRead.absent()
    : exists = false,
      version = null,
      answers = null,
      updatedByName = null,
      updatedAt = null,
      error = null;

  /// The read failed; [error] is a sanitized [SyncOutcome]
  /// (transient / permanent) — never a raw exception.
  const CloudAnswerKeyRead.failed(this.error)
    : exists = false,
      version = null,
      answers = null,
      updatedByName = null,
      updatedAt = null;

  /// True only for [CloudAnswerKeyRead.found].
  final bool exists;

  final int? version;
  final Map<String, String>? answers;
  final String? updatedByName;

  /// ISO-8601 UTC string, or null.
  final String? updatedAt;

  /// Set only for [CloudAnswerKeyRead.failed].
  final SyncOutcome? error;
}

/// One cloud `batches` row, as returned by [SyncClient.readCloudBatches].
/// Metadata only — never scans or images. Field-for-field the same set
/// [SupabaseSyncClient.pushBatch] writes.
class CloudBatchRow {
  const CloudBatchRow({
    required this.id,
    required this.batchCode,
    required this.examCode,
    required this.examTitle,
    required this.description,
    required this.expectedCount,
    required this.status,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String batchCode;
  final String examCode;
  final String examTitle;
  final String description;
  final int expectedCount;
  final String status;
  final String createdByUid;
  final String createdByName;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// The result of [SyncClient.readCloudBatches].
class CloudBatchesRead {
  CloudBatchesRead.found(this.batches) : error = null;

  const CloudBatchesRead.failed(this.error) : batches = const [];

  final List<CloudBatchRow> batches;

  /// Set only when the read failed — never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// One cloud `scans` row, as returned by [SyncClient.readCloudScans].
/// Deliberately has no `score_percentage` field: that column is the legacy
/// generic percentage for QTM/TAT, never the official one, and must never
/// be read into a restored result — see `cloud_batch_mapper.dart`.
class CloudScanRow {
  const CloudScanRow({
    required this.id,
    required this.batchId,
    required this.examCode,
    required this.capturedAt,
    required this.decoded,
    this.rawScore,
    this.totalGraded,
    this.totalItems,
    this.resultStatus,
    this.scannedAt,
    this.processedByUid,
    this.processedByName,
    this.firstName,
    this.lastName,
    this.middleName,
    this.examineeNumber,
    this.examineeId,
    this.imagePath,
    this.rectifiedImagePath,
    this.imageUploaded = false,
    this.rectifiedImageUploaded = false,
    this.attemptNo = 1,
    this.attemptStatus = 'active',
    this.archivedAt,
    this.archivedByUid,
    this.archivedByName,
    this.archiveReason,
  });

  final String id;
  final String batchId;
  final String examCode;
  final DateTime capturedAt;

  /// Raw `decoded` jsonb, in exactly the shape `OmrScanResult.toJson()`
  /// produces — pass to `OmrScanResult.fromJson` to reconstruct it.
  final Map<String, dynamic> decoded;

  final int? rawScore;
  final int? totalGraded;
  final int? totalItems;

  /// `'Graded'` | `'Ungraded'` | null (no result was ever attached).
  final String? resultStatus;
  final DateTime? scannedAt;
  final String? processedByUid;
  final String? processedByName;

  /// The examinee identity trio — all null, or all non-null (mirrors the
  /// cloud's own all-or-nothing constraint).
  final String? firstName;
  final String? lastName;
  final String? examineeNumber;

  /// Optional middle name -- NOT part of the trio's all-or-nothing
  /// constraint (mirrors [ExamineeInfo.middleName], never required for
  /// completeness); may be null/blank even when the trio above is set.
  final String? middleName;

  /// `scans.examinee_id` -- the canonical `examinees` row this scan is linked
  /// to (by "Link to Existing Examinee" or "Confirm and Create Examinee"), or
  /// null for an unlinked / legacy scan. Only populated by reads that select
  /// it ([SyncClient.readCloudScans]); null everywhere else. This is a
  /// reference only: it is never copied into [LocalScan] and the scan's own
  /// tag columns above are never changed by linking.
  final String? examineeId;

  /// Storage object keys, or null when no image was ever uploaded for this
  /// scan/variant.
  final String? imagePath;
  final String? rectifiedImagePath;
  final bool imageUploaded;
  final bool rectifiedImageUploaded;

  /// Applicant Retake Management (additive; see `retake_client.dart`). Which
  /// attempt this scan is for the examinee/exam-code pair it is linked to --
  /// QTM is always 1 (no retake); TAT/AT are 1 or 2. Defaults to 1 for any
  /// row selected without these columns, so this class stays backward
  /// compatible with every existing call site.
  final int attemptNo;

  /// 'active' | 'archived' (default 'active'). Compared case-insensitively
  /// via [isArchivedAttempt] -- see that getter's doc comment.
  final String attemptStatus;
  final DateTime? archivedAt;
  final String? archivedByUid;
  final String? archivedByName;
  final String? archiveReason;

  /// Whether this attempt has been archived as part of an approved retake --
  /// the previous attempt in the Maria-style example. An archived attempt is
  /// read-only (the database blocks changing its score/OMR data/image/tag
  /// columns and its examinee link) and must never be re-shown as the
  /// examinee's current result for its exam type.
  bool get isArchivedAttempt => attemptStatus.toUpperCase() == 'ARCHIVED';
}

/// The result of [SyncClient.readCloudScans].
class CloudScansRead {
  CloudScansRead.found(this.scans) : error = null;

  const CloudScansRead.failed(this.error) : scans = const [];

  final List<CloudScanRow> scans;

  /// Set only when the read failed — never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// The result of [SyncClient.downloadScanImage].
class CloudImageRead {
  CloudImageRead.found(this.bytes) : error = null;

  /// No object exists at that Storage path -- a normal "not restored yet"
  /// state, never an error.
  const CloudImageRead.absent() : bytes = null, error = null;

  const CloudImageRead.failed(this.error) : bytes = null;

  /// Raw downloaded bytes, or null for [absent]/[failed].
  final List<int>? bytes;

  /// Set only for [failed] -- never a raw exception.
  final SyncOutcome? error;
}

/// One cloud `batch_archives` row — the Guidance Council Web Archive marker
/// (see `0007_create_batch_archives.sql`). Its existence means "this batch is
/// archived in the Web application"; it is entirely separate from
/// `batches.status`, which belongs to the mobile app.
class CloudBatchArchiveRow {
  const CloudBatchArchiveRow({
    required this.batchId,
    required this.archivedAt,
    required this.archivedByUid,
    this.archivedByName,
    this.reason,
  });

  final String batchId;
  final DateTime archivedAt;
  final String archivedByUid;
  final String? archivedByName;
  final String? reason;
}

/// The result of [SyncClient.readBatchArchives].
class CloudBatchArchivesRead {
  CloudBatchArchivesRead.found(this.archives) : error = null;

  const CloudBatchArchivesRead.failed(this.error) : archives = const [];

  final List<CloudBatchArchiveRow> archives;

  /// Set only when the read failed — never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// The result of [SyncClient.readScanCounts]: scan count per batch id.
class CloudScanCountsRead {
  CloudScanCountsRead.found(this.counts) : error = null;

  const CloudScanCountsRead.failed(this.error) : counts = const {};

  final Map<String, int> counts;

  /// Set only when the read failed — never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// One cloud `examinees` row — the canonical applicant record, as returned
/// by [SyncClient.readCloudExaminees] / [SyncClient.createExamineeFromScan].
/// Field-for-field the same set `SupabaseSyncClient`'s examinee write
/// methods use — see `lib/models/examinee_record.dart` (`ExamineeRecord`)
/// for the app's canonical, cloud-independent model built from this row.
class CloudExamineeRow {
  const CloudExamineeRow({
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

  /// `'active'` | `'archived'`.
  final String status;

  final DateTime? archivedAt;
  final String? archivedByUid;
  final DateTime createdAt;
  final String createdByUid;
  final DateTime updatedAt;
  final String updatedByUid;
}

/// The result of [SyncClient.readCloudExaminees].
class CloudExamineesRead {
  CloudExamineesRead.found(this.examinees) : error = null;

  const CloudExamineesRead.failed(this.error) : examinees = const [];

  final List<CloudExamineeRow> examinees;

  /// Set only when the read failed — never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// The result of [SyncClient.createExamineeFromScan] /
/// [SyncClient.updateCloudExaminee] / [SyncClient.setExamineeArchived] — all
/// three return the server's own post-write row (never a bare success flag),
/// so the caller's in-memory [CloudExamineeRow]/`ExamineeRecord` reflects
/// the database's authoritative `updated_at`/`updated_by_uid`/
/// `archived_at`/`archived_by_uid` instead of reconstructing them
/// client-side.
class CloudExamineeWrite {
  CloudExamineeWrite.success(this.examinee) : error = null;

  const CloudExamineeWrite.failed(this.error) : examinee = null;

  /// The row after the write (with its server-set `id`/timestamps), or null
  /// on failure.
  final CloudExamineeRow? examinee;

  /// Set only on failure — never a raw exception.
  final SyncOutcome? error;

  bool get isSuccess => error == null;
}

/// The set of cloud sync operations that `SyncManager` dispatches to, plus
/// the read-only `readAnswerKey` used by the answer-key conflict flow, and
/// the read-only `readCloudBatches`/`readCloudScans` used by cloud
/// retrieval ([CloudRestoreService]) — additive, never dispatched by
/// `SyncManager`.
///
/// `SupabaseSyncClient` implements this directly. Kept in its own file so
/// neither `SyncManager` nor `SupabaseSyncClient` depends on the other, and
/// so the manager is unit-testable with a fake and never imports
/// `supabase_flutter`.
abstract class SyncClient {
  Future<SyncOutcome> pushBatch(String batchId);

  /// [meta] carries operation hints from the `PUSH_SCAN` job — currently
  /// `{"operation": "examinee_tag"|"examinee_clear", "opAt": "<UTC ISO>"}`
  /// for a tag/clear-triggered push, and empty for every other push. It
  /// never contains PII.
  Future<SyncOutcome> pushScan(
    String batchId,
    String scanId, {
    Map<String, String> meta = const {},
  });

  Future<SyncOutcome> uploadImage(SyncJob job);
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId);

  /// [meta] may carry `{"force": "true", "expectedCloudVersion": "<int>"}`
  /// for a user-confirmed force-resolution push; empty for a normal
  /// (version-guarded) push. It never contains PII.
  Future<SyncOutcome> pushAnswerKey(
    String examCode, {
    Map<String, String> meta = const {},
  });

  /// Read-only fetch of the current cloud `answer_keys` row for [examCode].
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode);

  /// Read-only, metadata-only fetch of every cloud `batches` row visible to
  /// the current session under RLS. No scans, no images. Used only by
  /// [CloudRestoreService] — never called by [SyncManager].
  Future<CloudBatchesRead> readCloudBatches();

  /// Read-only fetch of the cloud `scans` rows for [batchId]. Used only by
  /// [CloudRestoreService] — never called by [SyncManager].
  Future<CloudScansRead> readCloudScans(String batchId);

  /// Downloads one scan's image bytes from private Storage, or reports it
  /// absent (a 404 -- nothing has been restored there yet, not an error).
  /// Used only by [CloudRestoreService.restoreImageIfMissing] — never
  /// called by [SyncManager]. The caller is responsible for encrypting the
  /// returned bytes before writing them to disk; this method never touches
  /// local storage.
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  });

  /// Downloads a handwritten-name crop image from private Storage, or
  /// reports it absent (a 404 -- the crop was never uploaded or no longer
  /// exists, not an error). This follows the same authenticated read-only
  /// contract as [downloadScanImage].
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) async {
    return const CloudImageRead.failed(
      SyncOutcome.permanent('not_implemented'),
    );
  }

  /// Removes one scan's cloud row and its Storage image objects (original and
  /// rectified). Idempotent: a row or object that is already gone is success.
  Future<SyncOutcome> deleteScan(String batchId, String scanId);

  Future<SyncOutcome> deleteBatch(String batchId);
  Future<SyncOutcome> deleteStoragePrefix(String batchId);

  // ---------------------------------------------------------------------
  // Examinee Records — additive, never dispatched by SyncManager. Used only
  // by GuidanceWebExamineeRecordsService.
  // ---------------------------------------------------------------------

  /// Read-only fetch of every cloud `examinees` row visible under RLS
  /// (Guidance Council only — see `0001_create_examinees.sql`).
  Future<CloudExamineesRead> readCloudExaminees();

  /// Atomically creates a new `examinees` row AND links [scanId] (in
  /// [batchId]) to it, in one database transaction (the
  /// `create_examinee_from_scan` RPC — see
  /// `0004_create_examinee_from_scan_function.sql`). There is deliberately
  /// no plain "create a blank examinee" method on this interface at all —
  /// every examinee must originate from a specific scan, never a blank
  /// form.
  ///
  /// `temporary_examinee_id` is never a parameter — it is assigned
  /// atomically by PostgreSQL itself (a sequence-backed column `DEFAULT`,
  /// see `0001_create_examinees.sql`), never copied from the scan's own
  /// `examinee_number` and never generated client-side, so two concurrent
  /// creates from different devices/sessions can never collide. Once
  /// created, no method on this interface can ever change it.
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  });

  /// Updates only the editable canonical fields of an existing examinee —
  /// name-only, for correcting an OCR misread. Never touches
  /// `temporary_examinee_id`, `status`, `archived_at`/`archived_by_uid`, any
  /// `created_*` column, or the still-unsourced `birth_date`/
  /// `last_attended_school`/`official_student_id` fields (left exactly as
  /// they were). Returns the row as it now stands in the database.
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  });

  /// Sets `status` to `'archived'` ([archived] = true) or back to
  /// `'active'` ([archived] = false, i.e. restore). Never deletes the row,
  /// never touches any linked scan/result. Returns the row as it now stands
  /// in the database.
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived);

  /// Links one scan to [examineeId], but ONLY if the scan is still unlinked
  /// (`examinee_id IS NULL`) at the time of the update, and only if exactly
  /// one row changes. An already-linked, missing, or RLS-hidden scan is
  /// never overwritten and is reported as [SyncOutcome.conflict]
  /// (`scan_already_linked`), never success. Writes only `examinee_id`.
  /// Performs no matching or suggestion logic of its own — the caller
  /// (Guidance Council, after an explicit pick and confirmation) decides
  /// which examinee a scan belongs to. Clearing a link is
  /// [unlinkScanFromExaminee], not this method.
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  });

  /// Removes ONLY the link between one scan and one examinee — sets
  /// `scans.examinee_id` to NULL and touches nothing else. Never deletes the
  /// scan, its images, score, decoded answers, or batch.
  ///
  /// The scan is identified by the full `(batch_id, id)` key and the update
  /// is additionally guarded by the CURRENT [examineeId], and exactly one
  /// row must change. Zero rows (already unlinked, linked to a different
  /// examinee, missing, or hidden by RLS) is reported as
  /// [SyncOutcome.conflict] with code `scan_not_linked_to_examinee` — never
  /// as success, and no other examinee's scan is ever modified.
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  });

  /// Every cloud `scans` row linked to [examineeId], across ALL batches —
  /// the examination-history join (`examinees.id` -> `scans.examinee_id` ->
  /// `scans.batch_id` -> `batches.id`). Rows are parsed with the exact same
  /// [CloudScanRow]/`parseCloudScanRow` used by [readCloudScans].
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId);

  /// Every cloud `scans` row with `examinee_id IS NULL`, across ALL
  /// batches — the "Unlinked Scans" queue. Read-only and does no matching
  /// of its own: the caller (Guidance Council) decides, per scan, whether
  /// to create a new examinee from it or link it to an existing one.
  Future<CloudScansRead> readUnlinkedScans();

  // ---------------------------------------------------------------------
  // Guidance Council WEB Archive (`batch_archives`). Independent of the
  // mobile app's `batches.status` / sync: none of these methods reads or
  // writes `batches`, and there is deliberately NO restore/unarchive method.
  // ---------------------------------------------------------------------

  /// Every `batch_archives` marker visible under RLS. A batch with a marker
  /// is archived in the Web application; without one it is not.
  Future<CloudBatchArchivesRead> readBatchArchives();

  /// Creates the archive marker for [batchId] (an INSERT into
  /// `batch_archives` only — the batch, its scans and `batches.status` are
  /// never touched). The actor uid/name come from the signed-in identity.
  /// A batch that already has a marker fails with a permanent `23505`; the
  /// database also rejects a batch that is not Completed.
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason});

  /// Scan count for each of [batchIds] (exact counts, read-only).
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds);
}

/// Optional Web completion capability, unused by mobile synchronization.
abstract class BatchCompletionClient {
  Future<SyncOutcome> completeBatchForArchive(CloudBatchRow expected);
}
