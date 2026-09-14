import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/cloud_batch_mapper.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';

/// Records whether any push/write method is ever called -- the Web
/// Results service must ONLY ever call readCloudBatches/readCloudScans.
class _FakeSyncClient implements SyncClient {
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByBatchId = {};
  final List<String> calls = [];

  Never _no(String label) {
    calls.add(label);
    throw StateError('GuidanceWebResultsService must never call $label');
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('readCloudBatches');
    return batchesToReturn;
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    calls.add('readCloudScans:$batchId');
    return scansByBatchId[batchId] ?? CloudScansRead.found(const []);
  }

  @override
  Future<SyncOutcome> pushBatch(String batchId) => _no('pushBatch');
  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId, {Map<String, String> meta = const {}}) =>
      _no('pushScan');
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _no('uploadImage');
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) => _no('patchImageStatus');
  @override
  Future<SyncOutcome> pushAnswerKey(String examCode, {Map<String, String> meta = const {}}) =>
      _no('pushAnswerKey');
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) => _no('readAnswerKey');
  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) =>
      _no('downloadScanImage');
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
}

CloudBatchRow _batchRow({
  String id = 'b1',
  String examCode = 'AT',
  DateTime? updatedAt,
}) =>
    CloudBatchRow(
      id: id,
      batchCode: 'B-1',
      examCode: examCode,
      examTitle: 'Aptitude',
      description: 'd',
      expectedCount: 10,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
    );

CloudScanRow _scanRow({
  required String id,
  required String batchId,
  String examCode = 'AT',
  int rawScore = 54,
  int totalItems = 72,
  String? resultStatus = 'Graded',
  String? firstName,
  String? lastName,
  String? examineeNumber,
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: rawScore,
      totalGraded: totalItems,
      totalItems: totalItems,
      resultStatus: resultStatus,
      scannedAt: resultStatus == null ? null : DateTime.utc(2026, 1, 1),
      processedByUid: resultStatus == null ? null : 'uid',
      processedByName: resultStatus == null ? null : 'Officer',
      firstName: firstName,
      lastName: lastName,
      examineeNumber: examineeNumber,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSyncClient client;
  late GuidanceWebResultsService service;

  setUp(() {
    client = _FakeSyncClient();
    service = GuidanceWebResultsService(client: client);
  });

  group('loadBatches', () {
    test('maps every cloud batch via the existing mapper, never touches push methods', () async {
      final row = _batchRow(id: 'b1', examCode: 'QTM');
      client.batchesToReturn = CloudBatchesRead.found([row]);

      final batches = await service.loadBatches();

      expect(batches, hasLength(1));
      expect(batches.single.id, 'b1');
      expect(batches.single.examCode, 'QTM');
      expect(batches.single.scans, isEmpty);
      expect(client.calls, ['readCloudBatches']);
    });

    test('throws a sanitized GuidanceWebResultsException on failure, never a raw exception', () async {
      client.batchesToReturn = const CloudBatchesRead.failed(SyncOutcome.transient('network'));

      expect(
        () => service.loadBatches(),
        throwsA(isA<GuidanceWebResultsException>().having(
          (e) => e.message,
          'message',
          isNot(contains('network'))),
        ),
      );
    });
  });

  group('loadScansForBatch', () {
    test('maps cloud scans with the official recomputed percentage, never the legacy column', () async {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'AT')]);
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', rawScore: 54, totalItems: 72,
            firstName: 'Juan', lastName: 'Dela Cruz', examineeNumber: 'A-1'),
      ]);

      final mapped = await service.loadBatches();
      final scans = await service.loadScansForBatch(mapped.first);

      expect(scans, hasLength(1));
      final scan = scans.single;
      expect(scan.result!.rawScore, 54);
      expect(scan.result!.percentage, closeTo(75.0, 0.0001)); // 54/72*100
      expect(scan.examinee!.displayName, contains('Dela Cruz'));
    });

    test('an untagged scan maps to a null examinee, never an invented identity', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's_untagged', batchId: 'b1', resultStatus: null),
      ]);

      final scans = await service.loadScansForBatch(mapCloudBatch(_batchRow(id: 'b1')));

      expect(scans.single.examinee, isNull);
      expect(scans.single.result, isNull);
    });

    test('throws a sanitized GuidanceWebResultsException on failure', () async {
      final batch = mapCloudBatch(_batchRow(id: 'b_missing'));
      client.scansByBatchId['b_missing'] = const CloudScansRead.failed(SyncOutcome.permanent('42501'));

      expect(
        () => service.loadScansForBatch(batch),
        throwsA(isA<GuidanceWebResultsException>()),
      );
    });
  });

  test('never calls any push/write/delete/image method for a full batches+scans load', () async {
    final row = _batchRow(id: 'b1');
    client.batchesToReturn = CloudBatchesRead.found([row]);
    client.scansByBatchId['b1'] = CloudScansRead.found([_scanRow(id: 's1', batchId: 'b1')]);

    final batches = await service.loadBatches();
    await service.loadScansForBatch(batches.first);

    expect(client.calls, ['readCloudBatches', 'readCloudScans:b1']);
  });
}
