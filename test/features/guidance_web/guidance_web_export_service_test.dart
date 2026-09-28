import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/cloud_batch_mapper.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/export/guidance_web_export_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_analytics_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/local_batch.dart';

/// Read-only stand-in for Supabase, shared by the injected
/// [GuidanceWebResultsService]/[GuidanceWebAnalyticsService] -- Export
/// itself never queries Supabase directly (see
/// `guidance_web_export_service.dart`'s own doc comment).
class _FakeClient implements SyncClient {
  final List<CloudBatchRow> batches = [];
  final Map<String, List<CloudScanRow>> scansByBatch = {};
  final Set<String> archivedIds = {};
  final Map<String, int> countsOverride = {};
  CloudAnswerKeyRead keyRead = const CloudAnswerKeyRead.absent();

  final List<String> calls = [];

  Never _no(String label) {
    calls.add(label);
    throw StateError('Export must never call $label');
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('readCloudBatches');
    return CloudBatchesRead.found(List.of(batches));
  }

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async {
    calls.add('readBatchArchives');
    return CloudBatchArchivesRead.found([
      for (final id in archivedIds)
        CloudBatchArchiveRow(batchId: id, archivedAt: DateTime.utc(2026, 3, 1), archivedByUid: 'u'),
    ]);
  }

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) async {
    calls.add('readScanCounts');
    return CloudScanCountsRead.found({
      for (final id in batchIds) id: countsOverride[id] ?? (scansByBatch[id] ?? const []).length,
    });
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    calls.add('readCloudScans:$batchId');
    return CloudScansRead.found(List.of(scansByBatch[batchId] ?? const []));
  }

  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    calls.add('readAnswerKey:$examCode');
    return keyRead;
  }

  // Everything below is a write or an unrelated read: forbidden for Export.
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
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) =>
      _no('downloadScanImage');
  @override
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) => _no('downloadNameCropImage');
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no('deleteScan');
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
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) => _no('readCloudScansForExaminee');
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no('readUnlinkedScans');
  @override
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason}) => _no('archiveBatch');
}

CloudBatchRow _batch(String id, String examCode, {int expectedCount = 100}) => CloudBatchRow(
      id: id,
      batchCode: 'CODE-$id',
      examCode: examCode,
      examTitle: 'Title $examCode',
      description: '',
      expectedCount: expectedCount,
      status: 'Completed',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

CloudScanRow _scan(
  String id,
  String batchId,
  String examCode, {
  int rawScore = 65,
  String? firstName = 'Juan',
  String? lastName = 'Dela Cruz',
  String? examineeNumber = 'EX-1',
  int attemptNo = 1,
  String attemptStatus = 'active',
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: rawScore,
      totalGraded: examCode == 'AT' ? 72 : 10,
      totalItems: examCode == 'AT' ? 72 : (examCode == 'QTM' ? 60 : 130),
      resultStatus: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'uid',
      processedByName: 'Officer',
      firstName: firstName,
      lastName: lastName,
      examineeNumber: examineeNumber,
      attemptNo: attemptNo,
      attemptStatus: attemptStatus,
    );

LocalBatch _batchLocal(String id, String examCode) => mapCloudBatch(_batch(id, examCode));

void main() {
  late _FakeClient client;
  late GuidanceWebResultsService results;
  late GuidanceWebAnalyticsService analytics;
  late GuidanceWebExportService service;

  setUp(() {
    client = _FakeClient();
    results = GuidanceWebResultsService(client: client);
    analytics = GuidanceWebAnalyticsService(client: client);
    service = GuidanceWebExportService(results: results, analytics: analytics);
  });

  test("buildDefaultExportDocument uses the Results service's filtered default scan set", () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s-old', 'b1', 'AT', attemptNo: 1, attemptStatus: 'archived', examineeNumber: 'EX-OLD'),
      _scan('s-new', 'b1', 'AT', attemptNo: 2, attemptStatus: 'active', examineeNumber: 'EX-NEW'),
    ];
    final batch = _batchLocal('b1', 'AT');

    final expected = await results.loadScansForBatch(batch);
    final document = await service.buildDefaultExportDocument(batch);

    expect(
      document.examinees.map((e) => e.examineeId),
      expected.map((s) => s.examinee?.examineeNumber),
    );
    expect(document.examinees.map((e) => e.examineeId), ['EX-NEW']); // archived scan excluded
  });

  test('archived Attempt 1 is excluded; active Attempt 2 is included', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s-old', 'b1', 'AT', attemptNo: 1, attemptStatus: 'archived', examineeNumber: 'EX-OLD'),
      _scan('s-new', 'b1', 'AT', attemptNo: 2, attemptStatus: 'active', examineeNumber: 'EX-NEW'),
    ];

    final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

    expect(document.examinees.map((e) => e.examineeId), ['EX-NEW']);
  });

  test('a normal non-retake Attempt 1 remains included', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s1', 'b1', 'AT', examineeNumber: 'EX-1'), // default: attempt 1, active
    ];

    final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

    expect(document.examinees.map((e) => e.examineeId), ['EX-1']);
  });

  test('QTM behavior is unchanged', () async {
    client.batches.add(_batch('q1', 'QTM'));
    client.scansByBatch['q1'] = [
      _scan('s1', 'q1', 'QTM', examineeNumber: 'EX-Q1'),
    ];

    final document = await service.buildDefaultExportDocument(_batchLocal('q1', 'QTM'));

    expect(document.examinees.map((e) => e.examineeId), ['EX-Q1']);
    expect(document.examinees.single.examLabel, contains('QTM'));
  });

  test('includeCertificates behavior is unchanged: off by default, on when requested', () async {
    client.batches.add(_batch('b1', 'AT'));
    final scan = _scan('s1', 'b1', 'AT', rawScore: 65);
    client.scansByBatch['b1'] = [scan];

    final without = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));
    expect(without.examinees.single.certificate, isNull);

    final with_ = await service.buildDefaultExportDocument(
      _batchLocal('b1', 'AT'),
      includeCertificates: true,
    );
    expect(with_.examinees.single.certificate, isNotNull);
  });

  test('includeSummary behavior is unchanged: false omits the batch section, true includes it', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [_scan('s1', 'b1', 'AT')];
    final scans = await results.loadScansForBatch(_batchLocal('b1', 'AT'));

    final noSummary = await service.buildExportDocument(
      batch: _batchLocal('b1', 'AT'),
      includeSummary: false,
      selected: scans,
      allScans: scans,
    );
    expect(noSummary.batch, isNull);

    final withSummary = await service.buildExportDocument(
      batch: _batchLocal('b1', 'AT'),
      includeSummary: true,
      selected: scans,
      allScans: scans,
    );
    expect(withSummary.batch, isNotNull);
  });

  group('archived-only batch (physically complete, nothing active)', () {
    test('the export clearly states no active attempts, instead of a misleading zero-stat page', () async {
      client.batches.add(_batch('b1', 'AT', expectedCount: 1));
      client.scansByBatch['b1'] = [
        _scan('s-old', 'b1', 'AT', attemptNo: 1, attemptStatus: 'archived', examineeNumber: 'EX-OLD'),
      ];

      final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

      expect(document.examinees, isEmpty); // the archived scan is not exported
      expect(document.batch, isNotNull);
      expect(
        document.batch!.unavailableNote,
        'All examination attempts in this batch are archived. '
        'No active attempts are included in this export.',
      );
      expect(document.batch!.stats, isEmpty);
      // Never the generic "could not be fully retrieved" message -- the
      // batch WAS fully retrieved; it is simply all-archived.
      expect(document.batch!.unavailableNote, isNot(contains('could not be fully retrieved')));
    });

    test('QTM archived-only batch gets the same clear message', () async {
      client.batches.add(_batch('q1', 'QTM', expectedCount: 1));
      client.scansByBatch['q1'] = [
        _scan('s-old', 'q1', 'QTM', attemptNo: 1, attemptStatus: 'archived'),
      ];

      final document = await service.buildDefaultExportDocument(_batchLocal('q1', 'QTM'));

      expect(document.examinees, isEmpty);
      expect(
        document.batch!.unavailableNote,
        'All examination attempts in this batch are archived. '
        'No active attempts are included in this export.',
      );
    });
  });

  test('never calls a push/upload/delete method while building an export document', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [_scan('s1', 'b1', 'AT')];

    await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

    for (final call in client.calls) {
      expect(call, isNot(startsWith('push')));
      expect(call, isNot(startsWith('upload')));
      expect(call, isNot(startsWith('delete')));
    }
  });
}
