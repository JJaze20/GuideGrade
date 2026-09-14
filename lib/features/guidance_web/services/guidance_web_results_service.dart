import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/local_batch_repository.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/sync/cloud_batch_mapper.dart';
import '../../../core/sync/supabase_sync_client.dart';
import '../../../core/sync/sync_client.dart';
import '../../../core/sync/sync_outcome.dart';
import '../../../core/sync/sync_queue.dart' show SyncState;
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
/// existing `readCloudBatches`/`readCloudScans` — the exact same methods
/// [CloudRestoreService] itself uses — and returns plain, unpersisted,
/// in-memory [LocalBatch]/[LocalScan] objects for this browser session to
/// hold in widget state. Nothing here downloads a scan image; that stays
/// deferred to a later phase.
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
  /// inspection, neither `readCloudBatches` nor `readCloudScans` (the only
  /// two methods this service calls) ever reads them. Both constructors do
  /// no I/O (confirmed against their own source: no `dart:io` /
  /// `path_provider` / `flutter_secure_storage` call happens merely by
  /// constructing them), and no method is ever invoked on either instance,
  /// so this is safe on Web — it never touches a file, never mints/reads an
  /// encryption key, and never creates a second local copy of cloud data.
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
