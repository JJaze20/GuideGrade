// Exercises the REAL SupabaseSyncClient link/unlink methods against a fake
// HTTP layer, so the exact PostgREST request (filters, body, read-back) is
// asserted -- not just a fake SyncClient's simulation of it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/sync/supabase_sync_client.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
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

class _RecordingHttpClient extends http.BaseClient {
  /// The JSON the fake "server" answers every request with.
  String responseBody = '[]';
  final List<_Recorded> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    requests.add(_Recorded(request.method, request.url, body));
    return http.StreamedResponse(
      Stream.value(utf8.encode(responseBody)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }
}

class _Identity implements SyncIdentity {
  @override
  String? get uid => 'uid';
  @override
  String? get displayName => 'Tester';
  @override
  Future<bool> refreshToken() async => false;
}

void main() {
  late _RecordingHttpClient http0;
  late SyncClient client;

  setUp(() {
    http0 = _RecordingHttpClient();
    client = SupabaseSyncClient(
      batches: LocalBatchRepository(),
      localStorage: LocalStorageService(),
      identity: _Identity(),
      getSyncState: () => SyncState(),
      client: SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: http0,
      ),
    );
  });

  group('linkScanToExaminee (guarded: only while examinee_id IS NULL)', () {
    test('sends UPDATE ... WHERE batch_id AND id AND examinee_id IS NULL, writing ONLY examinee_id',
        () async {
      http0.responseBody = '[{"id":"s1"}]';
      final outcome = await client.linkScanToExaminee(
        batchId: 'b1',
        scanId: 's1',
        examineeId: 'e1',
      );

      expect(outcome.isSuccess, isTrue);
      expect(http0.requests, hasLength(1));
      final r = http0.requests.single;
      expect(r.method, 'PATCH'); // an UPDATE, never a DELETE/POST
      expect(r.url.path, '/rest/v1/scans');
      expect(r.url.queryParameters['batch_id'], 'eq.b1');
      expect(r.url.queryParameters['id'], 'eq.s1');
      expect(r.url.queryParameters['examinee_id'], 'is.null'); // the guard
      expect(r.url.queryParameters['select'], 'id'); // read-back of changed rows
      expect(jsonDecode(r.body), {'examinee_id': 'e1'}); // no other column
    });

    test('zero rows changed (already linked / missing / RLS-hidden) is a conflict, not success',
        () async {
      http0.responseBody = '[]';
      final outcome = await client.linkScanToExaminee(
        batchId: 'b1',
        scanId: 's1',
        examineeId: 'e2',
      );

      expect(outcome.isSuccess, isFalse);
      expect(outcome.isConflict, isTrue);
      expect(outcome, const SyncOutcome.conflict('scan_already_linked'));
    });

    test('an already-linked scan is protected by the IS NULL filter, so it cannot be overwritten',
        () async {
      http0.responseBody = '[]'; // what Postgres returns when examinee_id is NOT null
      await client.linkScanToExaminee(batchId: 'b1', scanId: 's1', examineeId: 'e-new');

      // The overwrite is prevented by the WHERE clause itself, not by a
      // client-side pre-read: the request can only match unlinked rows.
      expect(http0.requests.single.url.queryParameters['examinee_id'], 'is.null');
    });
  });

  group('unlinkScanFromExaminee (guarded: only the CURRENT examinee)', () {
    test('sends UPDATE examinee_id = NULL WHERE batch_id AND id AND examinee_id = current', () async {
      http0.responseBody = '[{"id":"s1"}]';
      final outcome = await client.unlinkScanFromExaminee(
        batchId: 'b1',
        scanId: 's1',
        examineeId: 'e1',
      );

      expect(outcome.isSuccess, isTrue);
      final r = http0.requests.single;
      expect(r.method, 'PATCH');
      expect(r.url.queryParameters['batch_id'], 'eq.b1');
      expect(r.url.queryParameters['id'], 'eq.s1');
      expect(r.url.queryParameters['examinee_id'], 'eq.e1');
      expect(jsonDecode(r.body), {'examinee_id': null});
    });

    test('zero rows changed is a conflict, not success', () async {
      http0.responseBody = '[]';
      final outcome = await client.unlinkScanFromExaminee(
        batchId: 'b1',
        scanId: 's1',
        examineeId: 'wrong-examinee',
      );
      expect(outcome, const SyncOutcome.conflict('scan_not_linked_to_examinee'));
    });
  });

  test('neither operation ever issues a DELETE request', () async {
    http0.responseBody = '[{"id":"s1"}]';
    await client.linkScanToExaminee(batchId: 'b1', scanId: 's1', examineeId: 'e1');
    await client.unlinkScanFromExaminee(batchId: 'b1', scanId: 's1', examineeId: 'e1');
    expect(http0.requests.map((r) => r.method), everyElement('PATCH'));
  });
}
