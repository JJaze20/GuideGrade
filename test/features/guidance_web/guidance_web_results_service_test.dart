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
  CloudAnswerKeyRead answerKeyToReturn = const CloudAnswerKeyRead.absent();
  CloudImageRead imageToReturn = const CloudImageRead.absent();
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
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    calls.add('readAnswerKey:$examCode');
    return answerKeyToReturn;
  }
  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) async {
    calls.add('downloadScanImage:$batchId:$scanId:${rectified ? 'rectified' : 'original'}');
    return imageToReturn;
  }
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
  @override
  Future<CloudExamineesRead> readCloudExaminees() => _no('readCloudExaminees');
  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no('createExamineeFromScan');
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no('updateCloudExaminee');
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) => _no('setExamineeArchived');
  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) =>
      _no('linkScanToExaminee');
  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) =>
      _no('unlinkScanFromExaminee');

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async =>
      CloudBatchArchivesRead.found(const []);

  @override
  Future<SyncOutcome> archiveBatch({
    required String batchId,
    String? reason,
  }) =>
      _no('archiveBatch');

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) =>
      _no('readScanCounts');

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) =>
      _no('readCloudScansForExaminee');
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no('readUnlinkedScans');
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

  group('loadAnswerKey (Phase 3)', () {
    test('1. a found cloud row is converted into the existing AnswerKey model', () async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 3,
        answers: {'Answer Document|1': 'A', 'Answer Document|2': 'B'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      final key = await service.loadAnswerKey('AT');

      expect(key, isNotNull);
      expect(key!.examCode, 'AT');
      expect(key.correctChoices, {'Answer Document|1': 'A', 'Answer Document|2': 'B'});
      expect(client.calls, ['readAnswerKey:AT']);
    });

    test('2. a missing (absent) cloud row returns null, never an exception', () async {
      client.answerKeyToReturn = const CloudAnswerKeyRead.absent();

      final key = await service.loadAnswerKey('QTM');

      expect(key, isNull);
    });

    test('an actual read failure throws a sanitized GuidanceWebResultsException, never a raw one', () async {
      client.answerKeyToReturn = const CloudAnswerKeyRead.failed(SyncOutcome.transient('network'));

      expect(
        () => service.loadAnswerKey('TAT'),
        throwsA(isA<GuidanceWebResultsException>().having(
          (e) => e.message,
          'message',
          isNot(contains('network')),
        )),
      );
    });

    test('never calls a push/write method', () async {
      client.answerKeyToReturn = const CloudAnswerKeyRead.absent();

      await service.loadAnswerKey('AT');

      expect(client.calls, ['readAnswerKey:AT']);
    });
  });

  group('loadScanImage (Phase 3 scanned-sheet viewing)', () {
    test('1. returns the downloaded bytes when the read succeeds', () async {
      client.imageToReturn = CloudImageRead.found([1, 2, 3]);

      final bytes = await service.loadScanImage('b1', 's1', rectified: false);

      expect(bytes, [1, 2, 3]);
      expect(client.calls, ['downloadScanImage:b1:s1:original']);
    });

    test('2. returns null (never throws) when the image is absent', () async {
      client.imageToReturn = const CloudImageRead.absent();

      final bytes = await service.loadScanImage('b1', 's1', rectified: true);

      expect(bytes, isNull);
      expect(client.calls, ['downloadScanImage:b1:s1:rectified']);
    });

    test('3. sanitizes a genuine download failure into GuidanceWebResultsException', () async {
      client.imageToReturn = const CloudImageRead.failed(SyncOutcome.transient('network'));

      expect(
        () => service.loadScanImage('b1', 's1', rectified: false),
        throwsA(isA<GuidanceWebResultsException>().having(
          (e) => e.message,
          'message',
          isNot(contains('network')),
        )),
      );
    });

    test('4. performs no write operation', () async {
      client.imageToReturn = CloudImageRead.found([9]);

      await service.loadScanImage('b1', 's1', rectified: false);

      expect(client.calls, ['downloadScanImage:b1:s1:original']);
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
