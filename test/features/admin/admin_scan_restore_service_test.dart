import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/admin_scan_restore_client.dart';
import 'package:guidegrade/core/sync/supabase_sync_client.dart' show SyncIdentity;
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/admin/services/admin_scan_restore_service.dart';

class _FakeAdminScanRestoreClient implements AdminScanRestoreClient {
  CloudAdminSoftDeletedScansRead? deletedScansResult;
  List<CloudAdminSoftDeletedScanRow> deletedScansToReturn = const [];
  final List<String> calls = [];

  @override
  Future<CloudAdminSoftDeletedScansRead> listDeletedScansForAdmin() async {
    calls.add('listDeletedScansForAdmin');
    return deletedScansResult ?? CloudAdminSoftDeletedScansRead.found(deletedScansToReturn);
  }

  CloudAdminRestoreRequestsRead? restoreRequestsResult;
  List<CloudAdminRestoreRequestRow> restoreRequestsToReturn = const [];

  @override
  Future<CloudAdminRestoreRequestsRead> listRestoreRequestsForAdmin() async {
    calls.add('listRestoreRequestsForAdmin');
    return restoreRequestsResult ?? CloudAdminRestoreRequestsRead.found(restoreRequestsToReturn);
  }

  SyncOutcome? reviewResult;
  final List<Map<String, Object?>> reviewCalls = [];

  @override
  Future<SyncOutcome> reviewRestoreRequest({
    required String requestId,
    required bool approve,
    required String reviewerUid,
    String? reviewerName,
    String? reviewNote,
  }) async {
    calls.add('reviewRestoreRequest:$requestId/$approve');
    reviewCalls.add({
      'requestId': requestId,
      'approve': approve,
      'reviewerUid': reviewerUid,
      'reviewerName': reviewerName,
      'reviewNote': reviewNote,
    });
    return reviewResult ?? const SyncOutcome.success();
  }

  SyncOutcome? restoreResult;
  final List<Map<String, String?>> restoreCalls = [];

  @override
  Future<SyncOutcome> restoreApprovedScan({
    required String requestId,
    required String reviewerUid,
    String? reviewerName,
  }) async {
    calls.add('restoreApprovedScan:$requestId');
    restoreCalls.add({
      'requestId': requestId,
      'reviewerUid': reviewerUid,
      'reviewerName': reviewerName,
    });
    return restoreResult ?? const SyncOutcome.success();
  }
}

CloudAdminSoftDeletedScanRow _deletedScanRow({String scanId = 's1'}) => CloudAdminSoftDeletedScanRow(
      batchId: 'b1',
      scanId: scanId,
      examCode: 'TAT',
      deletedAt: DateTime.utc(2026, 3, 1),
      retentionUntil: DateTime.utc(2026, 3, 31),
      deletionReason: 'Duplicate capture',
      deletedByName: 'Council Member',
    );

CloudAdminRestoreRequestRow _requestRow({
  String requestId = 'req-1',
  String status = 'PENDING',
}) =>
    CloudAdminRestoreRequestRow(
      requestId: requestId,
      batchId: 'b1',
      scanId: 's1',
      examCode: 'TAT',
      status: status,
      reason: 'Need this scan back',
      requestedByName: 'Council Member',
      requestedAt: DateTime.utc(2026, 3, 2),
    );

/// Test-only [SyncIdentity] so [AdminScanRestoreService] never reaches
/// `FirebaseAuth.instance` (which has no app initialized in a plain
/// `flutter test` unit test) -- same shape as the `_Identity` fakes already
/// used across this app's other service tests.
class _Identity implements SyncIdentity {
  _Identity({this.uid = 'admin-uid-1', this.displayName = 'System Administrator'});
  @override
  final String? uid;
  @override
  final String? displayName;
  @override
  Future<bool> refreshToken() async => false;
}

void main() {
  late _FakeAdminScanRestoreClient client;
  late AdminScanRestoreService service;

  setUp(() {
    client = _FakeAdminScanRestoreClient();
    service = AdminScanRestoreService(client: client, identity: _Identity());
  });

  group('loadDeletedScans', () {
    test('a successful listing returns the client\'s rows unchanged', () async {
      client.deletedScansToReturn = [_deletedScanRow()];
      final scans = await service.loadDeletedScans();
      expect(client.calls, contains('listDeletedScansForAdmin'));
      expect(scans, hasLength(1));
      expect(scans.single.scanId, 's1');
    });

    test('a listing failure is translated to a friendly AdminScanRestoreException', () async {
      client.deletedScansResult =
          const CloudAdminSoftDeletedScansRead.failed(SyncOutcome.permanent('42501'));
      await expectLater(
        service.loadDeletedScans(),
        throwsA(isA<AdminScanRestoreException>()),
      );
    });

    test('an empty result is never mistaken for a failure', () async {
      client.deletedScansToReturn = const [];
      final scans = await service.loadDeletedScans();
      expect(scans, isEmpty);
    });
  });

  group('loadRestoreRequests', () {
    test('a successful listing returns the client\'s rows unchanged', () async {
      client.restoreRequestsToReturn = [_requestRow()];
      final requests = await service.loadRestoreRequests();
      expect(client.calls, contains('listRestoreRequestsForAdmin'));
      expect(requests, hasLength(1));
      expect(requests.single.requestId, 'req-1');
    });

    test('a transient failure is reported as a retry-suggesting message', () async {
      client.restoreRequestsResult =
          const CloudAdminRestoreRequestsRead.failed(SyncOutcome.transient('network'));
      await expectLater(
        service.loadRestoreRequests(),
        throwsA(
          isA<AdminScanRestoreException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach Supabase'),
          ),
        ),
      );
    });

    test('an empty result is never mistaken for a failure', () async {
      client.restoreRequestsToReturn = const [];
      final requests = await service.loadRestoreRequests();
      expect(requests, isEmpty);
    });
  });

  group('reviewRestoreRequest (approve / reject)', () {
    test('a successful approve calls the RPC-backed client with the signed-in reviewer\'s identity',
        () async {
      await service.reviewRestoreRequest(requestId: 'req-1', approve: true, reviewNote: 'Looks fine');
      expect(client.reviewCalls, hasLength(1));
      final call = client.reviewCalls.single;
      expect(call['requestId'], 'req-1');
      expect(call['approve'], true);
      expect(call['reviewerUid'], 'admin-uid-1');
      expect(call['reviewerName'], 'System Administrator');
      expect(call['reviewNote'], 'Looks fine');
    });

    test('a successful reject calls the RPC-backed client with approve: false', () async {
      await service.reviewRestoreRequest(requestId: 'req-1', approve: false, reviewNote: 'Not eligible');
      expect(client.reviewCalls.single['approve'], false);
    });

    test('a blank review note never reaches the client, and throws before any RPC call', () async {
      await expectLater(
        service.reviewRestoreRequest(requestId: 'req-1', approve: true, reviewNote: '   '),
        throwsA(
          isA<AdminScanRestoreException>().having(
            (e) => e.message,
            'message',
            contains('review note is required'),
          ),
        ),
      );
      expect(client.reviewCalls, isEmpty);
    });

    test('a signed-out reviewer (no uid) never reaches the client', () async {
      service = AdminScanRestoreService(client: client, identity: _Identity(uid: null));
      await expectLater(
        service.reviewRestoreRequest(requestId: 'req-1', approve: true, reviewNote: 'x'),
        throwsA(
          isA<AdminScanRestoreException>().having(
            (e) => e.message,
            'message',
            contains('signed in'),
          ),
        ),
      );
      expect(client.reviewCalls, isEmpty);
    });

    test('a request that is no longer reviewable (42501) is a sanitized, friendly message', () async {
      client.reviewResult = const SyncOutcome.permanent('42501');
      Object? error;
      try {
        await service.reviewRestoreRequest(requestId: 'req-1', approve: true, reviewNote: 'x');
      } catch (e) {
        error = e;
      }
      expect(error, isA<AdminScanRestoreException>());
      final message = (error as AdminScanRestoreException).message;
      expect(message, isNot(contains('42501')));
      expect(message, isNotEmpty);
    });

    test('a missing request (P0002) is reported as a specific, friendly message', () async {
      client.reviewResult = const SyncOutcome.permanent('P0002');
      await expectLater(
        service.reviewRestoreRequest(requestId: 'req-1', approve: true, reviewNote: 'x'),
        throwsA(
          isA<AdminScanRestoreException>().having(
            (e) => e.message,
            'message',
            contains('no longer exists'),
          ),
        ),
      );
    });

    test(
      'a concurrent/stale approval -- a second reviewer already acted on this request before '
      'this call reached the server, reported by the RPC as the existing 42501 -- returns the '
      'existing friendly error and produces no fabricated success',
      () async {
        // Simulates: Admin A loads the list while it is still PENDING; Admin B
        // approves/rejects it first; Admin A's own review attempt then reaches
        // review_scan_restore_request() with the request no longer PENDING,
        // which the RPC reports via its existing 42501 errcode (see
        // 0009_create_unlinked_scan_soft_delete.sql's `v_status <> 'PENDING'`
        // check) -- no new error code is invented here.
        client.reviewResult = const SyncOutcome.permanent('42501');

        await expectLater(
          service.reviewRestoreRequest(requestId: 'req-1', approve: true, reviewNote: 'Looks fine'),
          throwsA(isA<AdminScanRestoreException>()),
        );

        // The call was attempted exactly once, and nothing in the fake client
        // (which only ever returns a success/failure SyncOutcome, never
        // mutates state) was told the review succeeded -- the thrown
        // exception is the only outcome; no success value is ever produced.
        expect(client.calls, ['reviewRestoreRequest:req-1/true']);
      },
    );
  });

  group('restoreApprovedScan', () {
    test('a successful restore calls the RPC-backed client with the signed-in reviewer\'s identity',
        () async {
      await service.restoreApprovedScan(requestId: 'req-1');
      expect(client.restoreCalls, hasLength(1));
      final call = client.restoreCalls.single;
      expect(call['requestId'], 'req-1');
      expect(call['reviewerUid'], 'admin-uid-1');
      expect(call['reviewerName'], 'System Administrator');
    });

    test('a signed-out reviewer (no uid) never reaches the client', () async {
      service = AdminScanRestoreService(client: client, identity: _Identity(uid: null));
      await expectLater(
        service.restoreApprovedScan(requestId: 'req-1'),
        throwsA(isA<AdminScanRestoreException>()),
      );
      expect(client.restoreCalls, isEmpty);
    });

    test('an expired/not-approved rejection (42501) is a sanitized, friendly message mentioning '
        'retention', () async {
      client.restoreResult = const SyncOutcome.permanent('42501');
      await expectLater(
        service.restoreApprovedScan(requestId: 'req-1'),
        throwsA(
          isA<AdminScanRestoreException>().having(
            (e) => e.message,
            'message',
            contains('retention window'),
          ),
        ),
      );
    });

    test('a missing request (P0002) is reported as a specific, friendly message', () async {
      client.restoreResult = const SyncOutcome.permanent('P0002');
      await expectLater(
        service.restoreApprovedScan(requestId: 'req-1'),
        throwsA(
          isA<AdminScanRestoreException>().having(
            (e) => e.message,
            'message',
            contains('no longer exists'),
          ),
        ),
      );
    });

    test('a transient failure is reported as a retry-suggesting message', () async {
      client.restoreResult = const SyncOutcome.transient('network');
      await expectLater(
        service.restoreApprovedScan(requestId: 'req-1'),
        throwsA(
          isA<AdminScanRestoreException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach Supabase'),
          ),
        ),
      );
    });

    test(
      'a concurrent/stale restore -- the request is no longer APPROVED by the time this call '
      'reaches the server (already restored, or its approval was superseded), reported by the '
      'RPC as the existing 42501 -- returns the existing friendly error and produces no success',
      () async {
        // Simulates: Admin A loads an APPROVED request; Admin B restores it
        // (or it expires) first; Admin A's own "Restore Scan" attempt then
        // reaches restore_soft_deleted_scan() with the request no longer
        // APPROVED, which the RPC reports via its existing 42501 errcode (see
        // 0009_create_unlinked_scan_soft_delete.sql's `v_status <> 'APPROVED'`
        // check) -- no new error code is invented here.
        client.restoreResult = const SyncOutcome.permanent('42501');

        await expectLater(
          service.restoreApprovedScan(requestId: 'req-1'),
          throwsA(isA<AdminScanRestoreException>()),
        );

        // The call was attempted exactly once, and the fake client (which
        // only ever returns a success/failure SyncOutcome, never mutates
        // state) was never told the restore succeeded -- the thrown
        // exception is the only outcome.
        expect(client.calls, ['restoreApprovedScan:req-1']);
      },
    );
  });
}
