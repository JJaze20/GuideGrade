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

/// The set of cloud sync operations that `SyncManager` dispatches to, plus
/// the read-only `readAnswerKey` used by the answer-key conflict flow.
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

  Future<SyncOutcome> deleteBatch(String batchId);
  Future<SyncOutcome> deleteStoragePrefix(String batchId);
}
