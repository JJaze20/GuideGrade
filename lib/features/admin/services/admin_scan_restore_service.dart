import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/local_batch_repository.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/sync/admin_scan_restore_client.dart';
import '../../../core/sync/supabase_sync_client.dart';
import '../../../core/sync/sync_outcome.dart';
import '../../../core/sync/sync_queue.dart' show SyncState;

/// Thrown by [AdminScanRestoreService] on any failure. Carries only an
/// already-sanitized, user-safe message -- never a raw exception, a
/// Supabase error code, or a stack trace. Mirrors
/// `GuidanceWebExamineeRecordsException` exactly, kept as its own separate
/// class (not shared) so this System Admin feature has no dependency on the
/// unrelated Guidance Council Web Console feature module.
class AdminScanRestoreException implements Exception {
  AdminScanRestoreException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// System Admin restore-management: lists soft-deleted scans and restore
/// requests (metadata only -- see [CloudAdminSoftDeletedScanRow]/
/// [CloudAdminRestoreRequestRow]'s own doc comments for exactly what is and
/// is not included), and submits APPROVE/REJECT reviews and the final
/// restore action. Every write here goes through a SECURITY DEFINER
/// database function (see [AdminScanRestoreClient]) -- none of these ever
/// writes `scans`/`scan_restore_requests` directly, and none ever touches
/// Storage. Deliberately kept out of `GuidanceWebExamineeRecordsService`:
/// this is a distinct, System-Admin-only workflow that a Guidance Council
/// session must never be able to reach through this app's code, even
/// indirectly via a shared service class.
class AdminScanRestoreService {
  /// [client] is only for tests; the app uses the real
  /// [SupabaseSyncClient]. [identity] is only for tests, same reasoning as
  /// [GuidanceWebExamineeRecordsService]'s own `_identity` -- see
  /// [_identity]'s doc comment.
  AdminScanRestoreService({
    AdminScanRestoreClient? client,
    SyncIdentity? identity,
  })  : _client = client ?? _buildDefaultClient(),
        _explicitIdentity = identity;

  final AdminScanRestoreClient _client;
  final SyncIdentity? _explicitIdentity;

  /// Resolved lazily (never at construction) so a caller that supplies
  /// [_explicitIdentity] (every existing test) never pays for (or crashes
  /// on) building [_AdminSyncIdentity], which reads `FirebaseAuth.instance`
  /// -- unavailable in a plain `flutter test` unit test with no Firebase
  /// app initialized. Production code never supplies it, so every write
  /// method below keeps reading the real signed-in Firebase user.
  late final SyncIdentity _identity = _explicitIdentity ?? _AdminSyncIdentity();

  /// [LocalBatchRepository]/[LocalStorageService] are required constructor
  /// params [SupabaseSyncClient] never actually reads for the methods this
  /// service calls -- same reasoning as
  /// `GuidanceWebExamineeRecordsService._buildDefaultClient`.
  static SupabaseSyncClient _buildDefaultClient() {
    return SupabaseSyncClient(
      batches: LocalBatchRepository(),
      localStorage: LocalStorageService(),
      identity: _AdminSyncIdentity(),
      getSyncState: () => SyncState(),
    );
  }

  /// Every soft-deleted unlinked scan (retained or already expired),
  /// metadata only.
  Future<List<CloudAdminSoftDeletedScanRow>> loadDeletedScans() async {
    final read = await _client.listDeletedScansForAdmin();
    if (!read.isSuccess) {
      throw AdminScanRestoreException(_messageFor(read.error));
    }
    return read.scans;
  }

  /// Every restore request ever filed, metadata only.
  Future<List<CloudAdminRestoreRequestRow>> loadRestoreRequests() async {
    final read = await _client.listRestoreRequestsForAdmin();
    if (!read.isSuccess) {
      throw AdminScanRestoreException(_messageFor(read.error));
    }
    return read.requests;
  }

  /// Approves or rejects a PENDING restore request. [reviewNote] is
  /// required by THIS app's own policy (stricter than the RPC's own
  /// nullable `p_review_note`) -- every review should leave a stated
  /// reason, matching this feature's "every lifecycle action records a
  /// reason" convention elsewhere (soft-delete, restore request). The
  /// database alone decides whether [requestId] is still PENDING and
  /// reviewable. Approval is explicitly NOT restoration -- see
  /// [restoreApprovedScan] for the separate, later step.
  Future<void> reviewRestoreRequest({
    required String requestId,
    required bool approve,
    required String reviewNote,
  }) async {
    final trimmed = reviewNote.trim();
    if (trimmed.isEmpty) {
      throw AdminScanRestoreException('A review note is required.');
    }

    final uid = _identity.uid;
    if (uid == null || uid.isEmpty) {
      throw AdminScanRestoreException(
        'You must be signed in to review this request. Please sign in again.',
      );
    }
    final displayName = _identity.displayName;

    final outcome = await _client.reviewRestoreRequest(
      requestId: requestId,
      approve: approve,
      reviewerUid: uid,
      reviewerName: displayName,
      reviewNote: trimmed,
    );
    if (outcome.isSuccess) return;
    if (outcome.isPermanent && outcome.code == 'P0002') {
      throw AdminScanRestoreException(
        'This request no longer exists. Refresh the list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '42501') {
      throw AdminScanRestoreException(
        'This request can no longer be reviewed -- it may have already been '
        'reviewed, or the scan behind it may no longer exist. Refresh the '
        'list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '22023') {
      throw AdminScanRestoreException(
        'This review could not be submitted. Please try again.',
      );
    }
    if (outcome.isTransient) {
      throw AdminScanRestoreException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    throw AdminScanRestoreException(
      'Could not submit this review. Please try again.',
    );
  }

  /// Restores the scan behind an APPROVED request. The database alone
  /// decides whether [requestId] is still APPROVED and the scan is still
  /// within its 30-day retention window -- this method only calls the RPC
  /// and translates its outcome; it never modifies `scans` or
  /// `scan_restore_requests` directly, and never touches Storage.
  Future<void> restoreApprovedScan({required String requestId}) async {
    final uid = _identity.uid;
    if (uid == null || uid.isEmpty) {
      throw AdminScanRestoreException(
        'You must be signed in to restore this scan. Please sign in again.',
      );
    }
    final displayName = _identity.displayName;

    final outcome = await _client.restoreApprovedScan(
      requestId: requestId,
      reviewerUid: uid,
      reviewerName: displayName,
    );
    if (outcome.isSuccess) return;
    if (outcome.isPermanent && outcome.code == 'P0002') {
      throw AdminScanRestoreException(
        'This request no longer exists. Refresh the list and try again.',
      );
    }
    if (outcome.isPermanent && outcome.code == '42501') {
      throw AdminScanRestoreException(
        'This scan can no longer be restored -- the request may no longer be '
        'approved, or its 30-day retention window may have expired.',
      );
    }
    if (outcome.isTransient) {
      throw AdminScanRestoreException(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    throw AdminScanRestoreException(
      'Could not restore this scan. Please try again.',
    );
  }

  String _messageFor(SyncOutcome? outcome) {
    if (outcome != null && outcome.isTransient) {
      return 'Could not reach Supabase. Check your connection and try again.';
    }
    return 'Could not load restore-management data. Please try again.';
  }
}

/// Identical in shape to `GuidanceWebExamineeRecordsService`'s private
/// `_WebSyncIdentity` -- duplicated rather than shared so this feature has
/// no dependency on that unrelated feature module.
class _AdminSyncIdentity implements SyncIdentity {
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
