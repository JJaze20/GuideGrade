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
  })  : exists = true,
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
    this.imagePath,
    this.rectifiedImagePath,
    this.imageUploaded = false,
    this.rectifiedImageUploaded = false,
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

  /// Storage object keys, or null when no image was ever uploaded for this
  /// scan/variant.
  final String? imagePath;
  final String? rectifiedImagePath;
  final bool imageUploaded;
  final bool rectifiedImageUploaded;
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
  const CloudImageRead.absent()
      : bytes = null,
        error = null;

  const CloudImageRead.failed(this.error) : bytes = null;

  /// Raw downloaded bytes, or null for [absent]/[failed].
  final List<int>? bytes;

  /// Set only for [failed] -- never a raw exception.
  final SyncOutcome? error;
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

  Future<SyncOutcome> deleteBatch(String batchId);
  Future<SyncOutcome> deleteStoragePrefix(String batchId);
}
