// SupabaseSyncClient.uploadImage for the optional handwritten-name crops
// (name_last / name_first / name_mi), against a real LocalBatchRepository and a
// fake HTTP layer:
//  * a successful upload is recorded per variant in SyncState (so the startup
//    reconcile can tell which crops still need uploading),
//  * a scan that never had the crop is a no-op success,
//  * a crop the scan RECORDS but whose local file is gone is a permanent,
//    visible failure -- not a silent success that makes the job vanish,
//  * a Storage refusal is a permanent failure and records nothing.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_crypto_service.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/sync/supabase_sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_queue.dart' show SyncState;
// ignore: depend_on_referenced_packages
import 'package:http/http.dart' as http;
import 'package:guidegrade/models/omr_scan_result.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeCrypto extends BatchCryptoService {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> decrypt(Uint8List packed) async => Uint8List.fromList(packed);
}

class _Recorded {
  _Recorded(this.method, this.url);
  final String method;
  final Uri url;
}

class _FakeHttp extends http.BaseClient {
  int status = 200;
  String body = '{"Key":"scanned-sheets/x","Id":"1"}';
  final List<_Recorded> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(_Recorded(request.method, request.url));
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }
}

class _Identity implements SyncIdentity {
  @override
  String? get uid => 'firebase-uid-1';
  @override
  String? get displayName => 'Council Member';
  @override
  Future<bool> refreshToken() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalBatchRepository repo;
  late _FakeHttp http_;
  late SyncState state;
  late SupabaseSyncClient client;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('name_crop_upload_');
    repo = LocalBatchRepository(
      rootOverride: Directory('${tempDir.path}/batches'),
      crypto: _FakeCrypto(),
    );
    http_ = _FakeHttp();
    state = SyncState();
    client = SupabaseSyncClient(
      batches: repo,
      localStorage: LocalStorageService(),
      identity: _Identity(),
      getSyncState: () => state,
      client: SupabaseClient('https://example.supabase.co', 'anon-key', httpClient: http_),
    );
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {/* Windows may briefly hold a handle */}
  });

  /// One scan with the requested crops on disk. Returns (batchId, scanId).
  Future<(String, String)> seedScan({bool last = false, bool first = false, bool mi = false}) async {
    final batch = await repo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: 'd',
      expectedCount: 10,
      createdByUid: 'uid',
      createdByName: 'Officer',
    );
    File file(String name) => File('${tempDir.path}/$name.jpg')..writeAsBytesSync(const [7, 7, 7]);
    final updated = await repo.addScan(
      batchId: batch.id,
      decoded: const OmrScanResult(examCode: 'AT', items: []),
      sourceImage: file('src'),
      nameCropLastImage: last ? file('last') : null,
      nameCropFirstImage: first ? file('first') : null,
      nameCropMiddleImage: mi ? file('mi') : null,
    );
    return (batch.id, updated.scans.single.id);
  }

  SyncJob job(String batchId, String scanId, String variant) => SyncJob.create(
        type: SyncJobType.uploadImage,
        entityId: scanId,
        batchId: batchId,
        scanId: scanId,
        meta: {'variant': variant},
      );

  List<_Recorded> storageWrites() =>
      http_.requests.where((r) => r.url.path.contains('/storage/v1/object/')).toList();

  test('uploads a recorded crop to its deterministic key and records it as uploaded', () async {
    final (batchId, scanId) = await seedScan(last: true);

    final outcome = await client.uploadImage(job(batchId, scanId, 'name_last'));

    expect(outcome.isSuccess, isTrue);
    expect(storageWrites(), hasLength(1));
    expect(
      storageWrites().single.url.path,
      endsWith('/batches/$batchId/scans/$scanId/name_last.jpg'),
    );
    expect(state.scanNameCropUploaded(batchId, scanId, 'name_last'), isTrue);
    // Only that variant is recorded.
    expect(state.scanNameCropUploaded(batchId, scanId, 'name_first'), isFalse);
    expect(state.scanNameCropUploaded(batchId, scanId, 'name_mi'), isFalse);
  });

  test('a scan that never had this crop is a no-op success: no upload, nothing recorded', () async {
    final (batchId, scanId) = await seedScan(last: true);

    final outcome = await client.uploadImage(job(batchId, scanId, 'name_first'));

    expect(outcome.isSuccess, isTrue);
    expect(storageWrites(), isEmpty);
    expect(state.scanNameCropUploaded(batchId, scanId, 'name_first'), isFalse);
  });

  test('a crop the scan records but whose local file is gone is a permanent failure', () async {
    final (batchId, scanId) = await seedScan(first: true);
    final scan = (await repo.getBatchById(batchId))!.scans.single;
    File('${tempDir.path}/batches/guidegrade_batches/$batchId/${scan.nameCropFirstFileName}').deleteSync();

    final outcome = await client.uploadImage(job(batchId, scanId, 'name_first'));

    expect(outcome.isSuccess, isFalse);
    expect(outcome.isPermanent, isTrue);
    expect(outcome.code, 'local_file_missing');
    expect(storageWrites(), isEmpty);
    expect(state.scanNameCropUploaded(batchId, scanId, 'name_first'), isFalse);
  });

  test('a Storage refusal (403) is permanent and records nothing', () async {
    final (batchId, scanId) = await seedScan(mi: true);
    http_
      ..status = 403
      ..body = jsonEncode({'statusCode': '403', 'error': 'Unauthorized', 'message': 'new row violates RLS'});

    final outcome = await client.uploadImage(job(batchId, scanId, 'name_mi'));

    expect(outcome.isSuccess, isFalse);
    expect(outcome.isPermanent, isTrue);
    expect(state.scanNameCropUploaded(batchId, scanId, 'name_mi'), isFalse);
  });

  test('a network-level 503 is transient (retried) and records nothing', () async {
    final (batchId, scanId) = await seedScan(last: true);
    http_
      ..status = 503
      ..body = jsonEncode({'statusCode': '503', 'error': 'Service Unavailable', 'message': 'try later'});

    final outcome = await client.uploadImage(job(batchId, scanId, 'name_last'));

    expect(outcome.isSuccess, isFalse);
    expect(outcome.isTransient, isTrue);
    expect(state.scanNameCropUploaded(batchId, scanId, 'name_last'), isFalse);
  });

  group('SyncState crop flags', () {
    test('default to not uploaded, are per variant, and survive a JSON round trip', () {
      final s = SyncState()..setScanNameCropUploaded('b1', 's1', 'name_last', true);
      expect(s.scanNameCropUploaded('b1', 's1', 'name_last'), isTrue);
      expect(s.scanNameCropUploaded('b1', 's1', 'name_first'), isFalse);
      expect(s.scanNameCropUploaded('b1', 's2', 'name_last'), isFalse);

      final restored = SyncState.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(restored.scanNameCropUploaded('b1', 's1', 'name_last'), isTrue);
    });

    test('do not disturb the photo flags in the same entry, and vice versa', () {
      final s = SyncState()
        ..setScanUploaded('b1', 's1', original: true)
        ..setScanNameCropUploaded('b1', 's1', 'name_mi', true)
        ..setScanUploaded('b1', 's1', rectified: true);
      expect(s.scanOriginalUploaded('b1', 's1'), isTrue);
      expect(s.scanRectifiedUploaded('b1', 's1'), isTrue);
      expect(s.scanNameCropUploaded('b1', 's1', 'name_mi'), isTrue);
    });

    test('can be cleared, and forgetBatch drops them with the batch', () {
      final s = SyncState()..setScanNameCropUploaded('b1', 's1', 'name_last', true);
      s.setScanNameCropUploaded('b1', 's1', 'name_last', false);
      expect(s.scanNameCropUploaded('b1', 's1', 'name_last'), isFalse);

      s.setScanNameCropUploaded('b1', 's1', 'name_last', true);
      s.forgetBatch('b1');
      expect(s.scanNameCropUploaded('b1', 's1', 'name_last'), isFalse);
    });
  });
}
