import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/local_batch_repository.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/sync/cloud_batch_mapper.dart';
import '../../../core/sync/supabase_sync_client.dart';
import '../../../core/sync/sync_client.dart';
import '../../../core/sync/sync_outcome.dart';
import '../../../core/sync/sync_queue.dart' show SyncState;
import '../../../models/answer_key.dart';
import '../../../models/local_batch.dart';

/// Thrown by [GuidanceWebResultsService] on any read failure. Carries only
/// an already-sanitized, user-safe message — never a raw exception, a
/// Supabase error code, or a stack trace.
class GuidanceWebResultsException implements Exception {
  GuidanceWebResultsException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Read-only Supabase access for the Guidance Council WEB Results page.
///
/// Deliberately NOT [CloudRestoreService]: this never calls
/// `BatchRepository.upsertBatchFromCloud`/`upsertScanFromCloud`, never
/// seeds `SyncState`, and never writes anything to the mobile encrypted
/// local store ([LocalBatchRepository]). It only calls [SyncClient]'s
/// existing `readCloudBatches`/`readCloudScans`/`readAnswerKey`/
/// `downloadScanImage` — the same read-only methods [CloudRestoreService]/
/// the answer-key conflict flow already use — and returns plain,
/// unpersisted, in-memory [LocalBatch]/[LocalScan]/[AnswerKey]/image-bytes
/// objects for this browser session to hold in widget state. A downloaded
/// scan image is never written anywhere — not encrypted to disk (no
/// [BatchCryptoService]), not upserted into any repository — it exists only
/// as bytes in memory for as long as the Detailed Result view holds them.
///
/// Percentages are never recomputed here — [mapCloudScan] (the same pure
/// function `CloudRestoreService` already uses) already reconstructs the
/// exam's official percentage (`raw/72*100` for AT, `qtmPercentage` for
/// QTM, `tatPercentage(tatTotal)` for TAT) and never the cloud's legacy
/// `score_percentage` column, since [CloudScanRow] doesn't even expose one.
class GuidanceWebResultsService {
  GuidanceWebResultsService({SyncClient? client}) : _client = client ?? _buildDefaultClient();

  final SyncClient _client;

  /// Builds the real [SupabaseSyncClient]. [LocalBatchRepository] and
  /// [LocalStorageService] are constructed here ONLY because
  /// [SupabaseSyncClient]'s constructor requires them as fields — by
  /// inspection, none of the four methods this service calls
  /// (`readCloudBatches`/`readCloudScans`/`readAnswerKey`/
  /// `downloadScanImage`) ever reads them; `downloadScanImage` in
  /// particular only touches `_client.storage`, never the injected
  /// repository. Both constructors do no I/O (confirmed against their own
  /// source: no `dart:io` / `path_provider` / `flutter_secure_storage` call
  /// happens merely by constructing them), and no method is ever invoked on
  /// either instance, so this is safe on Web — it never touches a file,
  /// never mints/reads an encryption key, and never creates a second local
  /// copy of cloud data.
  static SyncClient _buildDefaultClient() {
    return SupabaseSyncClient(
      batches: LocalBatchRepository(),
      localStorage: LocalStorageService(),
      identity: _WebSyncIdentity(),
      getSyncState: () => SyncState(),
    );
  }

  /// Every cloud batch visible to the current session under Supabase RLS —
  /// metadata only, no scans (mirrors [mapCloudBatch]'s own contract).
  /// Throws [GuidanceWebResultsException] on failure.
  Future<List<LocalBatch>> loadBatches() async {
    final read = await _client.readCloudBatches();
    if (!read.isSuccess) {
      throw GuidanceWebResultsException(_messageFor(read.error));
    }
    return read.batches.map(mapCloudBatch).toList();
  }

  /// Ids of every batch archived in the Web application (a `batch_archives`
  /// marker exists). Used ONLY by the normal Results page to leave archived
  /// batches out of its own batch list — never to hide scans or history from
  /// Examinee Records, examinee history, or Unlinked Scans. Read-only.
  /// Throws [GuidanceWebResultsException] on failure.
  Future<Set<String>> loadArchivedBatchIds() async {
    final read = await _client.readBatchArchives();
    if (!read.isSuccess) {
      throw GuidanceWebResultsException(_messageFor(read.error));
    }
    return {for (final a in read.archives) a.batchId};
  }

  /// Every scan belonging to [batch], mapped the same way
  /// [CloudRestoreService] maps a scan — recomputed official percentage,
  /// TAT breakdown left null here (no answer key is fetched for this list
  /// view; the headline `rawScore`/`totalItems`/percentage/status are
  /// always authoritative regardless — see [mapCloudScan]'s doc comment).
  /// Throws [GuidanceWebResultsException] on failure.
  Future<List<LocalScan>> loadScansForBatch(LocalBatch batch) async {
    final read = await _client.readCloudScans(batch.id);
    if (!read.isSuccess) {
      throw GuidanceWebResultsException(_messageFor(read.error));
    }
    return read.scans.map(mapCloudScan).toList();
  }

  /// The current cloud answer key for [examCode] (Phase 3's Detailed Result
  /// view), or `null` when none has been entered yet — a normal, expected
  /// state ([CloudAnswerKeyRead.absent], not an error). Read-only: never
  /// writes, never touches [SyncState] or the answer-key push/conflict
  /// machinery. Throws [GuidanceWebResultsException] only on an actual read
  /// failure, matching [loadBatches]/[loadScansForBatch].
  Future<AnswerKey?> loadAnswerKey(String examCode) async {
    final read = await _client.readAnswerKey(examCode);
    if (read.error != null) {
      throw GuidanceWebResultsException(_messageFor(read.error));
    }
    if (!read.exists) return null;
    return AnswerKey(examCode: examCode, correctChoices: read.answers ?? const {});
  }

  /// One scan's image bytes straight from the private `scanned-sheets`
  /// Storage bucket (Phase 3's Scanned Answer Sheet card), via the existing
  /// [SyncClient.downloadScanImage] — the same platform-agnostic method
  /// [CloudRestoreService] already uses, called here with no local write of
  /// any kind: no [BatchRepository], no [BatchCryptoService], no encrypted
  /// disk copy, no [SyncState]. Bytes are held only in the caller's memory.
  ///
  /// `null` means the image simply isn't there yet ([CloudImageRead.absent],
  /// e.g. a rectified copy that was never produced, or an old scan with no
  /// upload at all) — a normal, expected state, not an error. Throws
  /// [GuidanceWebResultsException] only for a genuine retrieval failure
  /// (network/permission/storage), sanitized the same way
  /// [loadAnswerKey]/[loadBatches] already are.
  ///
  /// [batchId]/[scanId] are used to reconstruct the Storage key via the
  /// existing [SupabaseSyncClient.originalImageKey]/`rectifiedImageKey`
  /// (done inside [SyncClient.downloadScanImage] itself) — never
  /// `LocalScan.imageFileName`/`rectifiedImageFileName`, which are a local
  /// encrypted-file naming convention with no meaning in Supabase Storage.
  Future<Uint8List?> loadScanImage(
    String batchId,
    String scanId, {
    required bool rectified,
  }) async {
    final read = await _client.downloadScanImage(
      batchId: batchId,
      scanId: scanId,
      rectified: rectified,
    );
    if (read.error != null) {
      throw GuidanceWebResultsException(_messageFor(read.error));
    }
    final bytes = read.bytes;
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  String _messageFor(SyncOutcome? outcome) {
    if (outcome != null && outcome.isTransient) {
      return 'Could not reach Supabase. Check your connection and try again.';
    }
    return 'Could not load examination data. Please try again.';
  }
}

/// Minimal [SyncIdentity] for the Web Results page's read-only client —
/// functionally identical to `main.dart`'s private `_FirebaseSyncIdentity`
/// (same two fields, same force-refresh-on-401 behavior) but defined
/// independently here so this feature has no dependency on `main.dart`.
/// Read-only: never signs in or out.
class _WebSyncIdentity implements SyncIdentity {
  @override
  String? get uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  String? get displayName => FirebaseAuth.instance.currentUser?.displayName;

  @override
  Future<bool> refreshToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await user.getIdToken(true);
    return true;
  }
}
