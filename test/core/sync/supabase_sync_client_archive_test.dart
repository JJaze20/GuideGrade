// Exercises the REAL SupabaseSyncClient Web Archive methods against a fake
// HTTP layer, asserting the exact PostgREST requests: the archive only ever
// INSERTs into `batch_archives` -- it never touches `batches` or `scans`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/sync/scan_delete_client.dart';
import 'package:guidegrade/core/sync/scan_restore_client.dart';
import 'package:guidegrade/core/sync/supabase_sync_client.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_queue.dart' show SyncState;
// ignore: depend_on_referenced_packages
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class _Recorded {
  _Recorded(this.method, this.url, this.body);
  final String method;
  final Uri url;
  final String body;
}

class _FakeHttp extends http.BaseClient {
  int status = 200;
  String responseBody = '[]';
  Map<String, String> extraHeaders = const {};
  final List<_Recorded> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(_Recorded(request.method, request.url, request is http.Request ? request.body : ''));
    return http.StreamedResponse(
      Stream.value(utf8.encode(responseBody)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8', ...extraHeaders},
      request: request,
    );
  }
}

class _Identity implements SyncIdentity {
  _Identity({this.uid = 'firebase-uid-1', this.displayName = 'Council Member'});
  @override
  final String? uid;
  @override
  final String? displayName;
  @override
  Future<bool> refreshToken() async => false;
}

SyncClient _client(_FakeHttp fake, {SyncIdentity? identity}) => SupabaseSyncClient(
      batches: LocalBatchRepository(),
      localStorage: LocalStorageService(),
      identity: identity ?? _Identity(),
      getSyncState: () => SyncState(),
      client: SupabaseClient('https://example.supabase.co', 'anon-key', httpClient: fake),
    );

void main() {
  group('archiveBatch', () {
    test('INSERTs only into batch_archives with the actor and reason -- never touches batches or scans',
        () async {
      final fake = _FakeHttp()..status = 201;
      final outcome = await _client(fake).archiveBatch(batchId: 'b1', reason: '  Batch processed  ');

      expect(outcome.isSuccess, isTrue);
      expect(fake.requests, hasLength(1));
      final r = fake.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rest/v1/batch_archives');
      expect(jsonDecode(r.body), {
        'batch_id': 'b1',
        'archived_by_uid': 'firebase-uid-1',
        'archived_by_name': 'Council Member',
        'reason': 'Batch processed',
      });
      // No archived_at (server default) and nothing aimed at batches/scans.
      expect((jsonDecode(r.body) as Map).containsKey('archived_at'), isFalse);
      expect(fake.requests.where((q) => q.url.path.contains('/batches')), isEmpty);
      expect(fake.requests.where((q) => q.url.path.contains('/scans')), isEmpty);
    });

    test('a blank reason and blank name are sent as null', () async {
      final fake = _FakeHttp()..status = 201;
      await _client(fake, identity: _Identity(displayName: '  ')).archiveBatch(batchId: 'b1', reason: '   ');
      final body = jsonDecode(fake.requests.single.body) as Map;
      expect(body['reason'], isNull);
      expect(body['archived_by_name'], isNull);
    });

    test('a duplicate archive (23505) is a permanent 23505 outcome', () async {
      final fake = _FakeHttp()
        ..status = 409
        ..responseBody = jsonEncode({'code': '23505', 'message': 'duplicate key', 'details': null, 'hint': null});
      final outcome = await _client(fake).archiveBatch(batchId: 'b1');
      expect(outcome.isSuccess, isFalse);
      expect(outcome.isPermanent, isTrue);
      expect(outcome.code, '23505');
    });

    test('an RLS rejection (e.g. batch not Completed) is a permanent 42501 outcome', () async {
      final fake = _FakeHttp()
        ..status = 403
        ..responseBody = jsonEncode({'code': '42501', 'message': 'new row violates row-level security policy'});
      final outcome = await _client(fake).archiveBatch(batchId: 'b1');
      expect(outcome.isPermanent, isTrue);
      expect(outcome.code, '42501');
    });

    test('no signed-in uid fails without sending any request', () async {
      final fake = _FakeHttp();
      final outcome = await _client(fake, identity: _Identity(uid: null)).archiveBatch(batchId: 'b1');
      expect(outcome.isSuccess, isFalse);
      expect(fake.requests, isEmpty);
    });

    test('the only write method the archive uses is POST -- never PATCH/DELETE (no restore, no batch update)',
        () async {
      final fake = _FakeHttp()..status = 201;
      await _client(fake).archiveBatch(batchId: 'b1');
      expect(fake.requests.map((r) => r.method), everyElement('POST'));
    });
  });

  group('readBatchArchives', () {
    test('GETs batch_archives and parses the rows', () async {
      final fake = _FakeHttp()
        ..responseBody = jsonEncode([
          {
            'batch_id': 'b1',
            'archived_at': '2026-03-01T08:00:00+00:00',
            'archived_by_uid': 'u1',
            'archived_by_name': 'Council Member',
            'reason': 'done',
          }
        ]);
      final read = await _client(fake).readBatchArchives();
      expect(read.isSuccess, isTrue);
      expect(read.archives.single.batchId, 'b1');
      expect(read.archives.single.archivedByName, 'Council Member');
      expect(read.archives.single.reason, 'done');
      expect(fake.requests.single.method, 'GET');
      expect(fake.requests.single.url.path, '/rest/v1/batch_archives');
    });

    test('a failure is a sanitized failed read, never a thrown error', () async {
      final fake = _FakeHttp()
        ..status = 404
        ..responseBody = jsonEncode({'code': 'PGRST205', 'message': 'table missing'});
      final read = await _client(fake).readBatchArchives();
      expect(read.isSuccess, isFalse);
      expect(read.archives, isEmpty);
    });
  });

  group('readScanCounts', () {
    test('reads an exact count per batch from the scans table (read-only)', () async {
      final fake = _FakeHttp()
        ..responseBody = '[{"id":"s1"}]'
        ..extraHeaders = {'content-range': '0-0/7'};
      final read = await _client(fake).readScanCounts(['b1']);
      expect(read.isSuccess, isTrue);
      expect(read.counts['b1'], 7);
      expect(fake.requests.single.method, 'GET');
      expect(fake.requests.single.url.queryParameters['batch_id'], 'eq.b1');
    });

    test(
      'readScanCounts counts ACTIVE scans only: batch_id filter kept, soft-deleted '
      '(deleted_at IS NOT NULL) rows excluded, for every requested batch',
      () async {
        final fake = _FakeHttp()
          ..responseBody = '[{"id":"s1"}]'
          ..extraHeaders = {'content-range': '0-0/3'};
        final read = await _client(fake).readScanCounts(['b1', 'b2']);

        expect(read.isSuccess, isTrue);
        expect(read.counts, {'b1': 3, 'b2': 3});
        expect(fake.requests, hasLength(2));
        for (final (index, id) in ['b1', 'b2'].indexed) {
          final r = fake.requests[index];
          expect(r.method, 'GET');
          expect(r.url.path, '/rest/v1/scans');
          expect(r.url.queryParameters['batch_id'], 'eq.$id');
          expect(r.url.queryParameters['deleted_at'], 'is.null');
        }
      },
    );
  });

  // readCloudScans and readUnlinkedScans both go through the same fake
  // http.Client as every test above -- no real network socket or Supabase
  // project is ever reached, and no Supabase credentials beyond the
  // placeholder 'anon-key' already used throughout this file are needed.
  group('readCloudScans excludes soft-deleted scans', () {
    test('readCloudScans excludes soft-deleted scans', () async {
      final fake = _FakeHttp()..responseBody = '[]';
      final read = await _client(fake).readCloudScans('b1');

      expect(read.isSuccess, isTrue);
      expect(fake.requests, hasLength(1));
      final r = fake.requests.single;
      expect(r.method, 'GET');
      expect(r.url.path, '/rest/v1/scans');
      expect(r.url.queryParameters['batch_id'], 'eq.b1');
      expect(r.url.queryParameters['deleted_at'], 'is.null');
    });
  });

  group('readUnlinkedScans excludes soft-deleted scans', () {
    test('readUnlinkedScans excludes soft-deleted scans', () async {
      final fake = _FakeHttp()..responseBody = '[]';
      final read = await _client(fake).readUnlinkedScans();

      expect(read.isSuccess, isTrue);
      expect(fake.requests, hasLength(1));
      final r = fake.requests.single;
      expect(r.method, 'GET');
      expect(r.url.path, '/rest/v1/scans');
      expect(r.url.queryParameters['examinee_id'], 'is.null');
      expect(r.url.queryParameters['deleted_at'], 'is.null');
    });
  });

  group('softDeleteUnlinkedScan', () {
    test(
      'calls the soft_delete_unlinked_scan RPC with exactly the five p_-prefixed params',
      () async {
        final fake = _FakeHttp()
          ..responseBody = jsonEncode([
            {
              'batch_id': 'b1',
              'scan_id': 's1',
              'deleted_at': '2026-03-01T08:00:00+00:00',
              'retention_until': '2026-03-31T08:00:00+00:00',
            },
          ]);
        final outcome = await (_client(fake) as ScanDeleteClient).softDeleteUnlinkedScan(
          batchId: 'b1',
          scanId: 's1',
          deletedByUid: 'firebase-uid-1',
          deletedByName: 'Council Member',
          deletionReason: 'Duplicate capture',
        );

        expect(outcome.isSuccess, isTrue);
        expect(fake.requests, hasLength(1));
        final r = fake.requests.single;
        expect(r.method, 'POST');
        expect(r.url.path, '/rest/v1/rpc/soft_delete_unlinked_scan');
        expect(jsonDecode(r.body), {
          'p_batch_id': 'b1',
          'p_scan_id': 's1',
          'p_deleted_by_uid': 'firebase-uid-1',
          'p_deleted_by_name': 'Council Member',
          'p_deletion_reason': 'Duplicate capture',
        });
      },
    );

    test(
      'a business-rule rejection (e.g. already linked/archived/soft-deleted) is a permanent 42501 outcome',
      () async {
        final fake = _FakeHttp()
          ..status = 403
          ..responseBody = jsonEncode({
            'code': '42501',
            'message': 'scan is linked to an examinee and is not eligible',
          });
        final outcome = await (_client(fake) as ScanDeleteClient).softDeleteUnlinkedScan(
          batchId: 'b1',
          scanId: 's1',
          deletedByUid: 'firebase-uid-1',
          deletedByName: 'Council Member',
          deletionReason: 'Duplicate capture',
        );
        expect(outcome.isSuccess, isFalse);
        expect(outcome.isPermanent, isTrue);
        expect(outcome.code, '42501');
      },
    );
  });

  group('listRetainedSoftDeletedScans', () {
    test(
      'calls the list_retained_soft_deleted_scans_for_guidance RPC with no '
      'parameters, mapping each row to the minimal typed model',
      () async {
        final fake = _FakeHttp()
          ..responseBody = jsonEncode([
            {
              'batch_id': 'b1',
              'scan_id': 's1',
              'exam_code': 'TAT',
              'deleted_at': '2026-03-01T08:00:00+00:00',
              'retention_until': '2026-03-31T08:00:00+00:00',
              'deletion_reason': 'Duplicate capture',
              'deleted_by_name': 'Council Member',
              'active_restore_request_status': null,
            },
          ]);
        final read =
            await (_client(fake) as ScanRestoreClient).listRetainedSoftDeletedScans();

        expect(read.isSuccess, isTrue);
        expect(fake.requests, hasLength(1));
        final r = fake.requests.single;
        expect(r.method, 'POST');
        expect(
          r.url.path,
          '/rest/v1/rpc/list_retained_soft_deleted_scans_for_guidance',
        );
        // No parameters sent -- a param-less rpc() call's body is `null`.
        expect(jsonDecode(r.body), isNull);

        expect(read.scans, hasLength(1));
        final row = read.scans.single;
        expect(row.batchId, 'b1');
        expect(row.scanId, 's1');
        expect(row.examCode, 'TAT');
        expect(row.deletedAt, DateTime.parse('2026-03-01T08:00:00+00:00').toUtc());
        expect(row.retentionUntil, DateTime.parse('2026-03-31T08:00:00+00:00').toUtc());
        expect(row.deletionReason, 'Duplicate capture');
        expect(row.deletedByName, 'Council Member');
        expect(row.activeRestoreRequestStatus, isNull);
        expect(row.hasActiveRestoreRequest, isFalse);
      },
    );

    test('missing or invalid required timestamps fail instead of fabricating values', () {
      final validRow = <String, dynamic>{
        'batch_id': 'b1',
        'scan_id': 's1',
        'exam_code': 'TAT',
        'deleted_at': '2026-03-01T08:00:00+00:00',
        'retention_until': '2026-03-31T08:00:00+00:00',
      };
      final invalidRows = [
        {...validRow}..remove('deleted_at'),
        {...validRow, 'deleted_at': null},
        {...validRow, 'deleted_at': 'not-a-timestamp'},
        {...validRow}..remove('retention_until'),
        {...validRow, 'retention_until': null},
        {...validRow, 'retention_until': 'not-a-timestamp'},
      ];

      for (final row in invalidRows) {
        expect(
          () => SupabaseSyncClient.parseCloudRetainedDeletedScanRow(row),
          throwsFormatException,
        );
      }
    });

    test(
      'a caller who is not Guidance Council (42501) is a sanitized failed read, never a thrown error',
      () async {
        final fake = _FakeHttp()
          ..status = 403
          ..responseBody = jsonEncode({
            'code': '42501',
            'message': 'caller is not an active Guidance Council user',
          });
        final read =
            await (_client(fake) as ScanRestoreClient).listRetainedSoftDeletedScans();
        expect(read.isSuccess, isFalse);
        expect(read.scans, isEmpty);
      },
    );
  });

  group('createScanRestoreRequest', () {
    test(
      'calls the create_scan_restore_request RPC with exactly the five p_-prefixed params',
      () async {
        final fake = _FakeHttp()
          ..responseBody = jsonEncode([
            {
              'request_id': 'req-1',
              'status': 'PENDING',
              'requested_at': '2026-03-02T00:00:00+00:00',
            },
          ]);
        final outcome = await (_client(fake) as ScanRestoreClient).createScanRestoreRequest(
          batchId: 'b1',
          scanId: 's1',
          reason: 'Need this scan back for review',
          requestedByUid: 'firebase-uid-1',
          requestedByName: 'Council Member',
        );

        expect(outcome.isSuccess, isTrue);
        expect(fake.requests, hasLength(1));
        final r = fake.requests.single;
        expect(r.method, 'POST');
        expect(r.url.path, '/rest/v1/rpc/create_scan_restore_request');
        expect(jsonDecode(r.body), {
          'p_batch_id': 'b1',
          'p_scan_id': 's1',
          'p_reason': 'Need this scan back for review',
          'p_requested_by_uid': 'firebase-uid-1',
          'p_requested_by_name': 'Council Member',
        });
      },
    );

    test(
      'an active-request conflict (23505) is a permanent 23505 outcome',
      () async {
        final fake = _FakeHttp()
          ..status = 409
          ..responseBody = jsonEncode({
            'code': '23505',
            'message': 'an active restore request already exists for this scan',
          });
        final outcome = await (_client(fake) as ScanRestoreClient).createScanRestoreRequest(
          batchId: 'b1',
          scanId: 's1',
          reason: 'Need this scan back',
          requestedByUid: 'firebase-uid-1',
        );
        expect(outcome.isSuccess, isFalse);
        expect(outcome.isPermanent, isTrue);
        expect(outcome.code, '23505');
      },
    );
  });
}
