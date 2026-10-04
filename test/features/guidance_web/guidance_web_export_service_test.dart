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

  /// `examinee_id`s that must NOT resolve when [readCloudExaminees] is
  /// called -- simulates a dangling link (row deleted/RLS-hidden) even
  /// though a scan still carries that id. Every other `examinee_id` found
  /// across [scansByBatch] resolves automatically, so existing tests that
  /// never mention linkage keep working unchanged.
  final Set<String> danglingExamineeIds = {};

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
  Future<CloudExamineesRead> readCloudExaminees() async {
    calls.add('readCloudExaminees');
    final ids = <String>{
      for (final scans in scansByBatch.values)
        for (final s in scans)
          if (s.examineeId != null && !danglingExamineeIds.contains(s.examineeId)) s.examineeId!,
    };
    return CloudExamineesRead.found([
      for (final id in ids)
        CloudExamineeRow(
          id: id,
          temporaryExamineeId: 'TMP-$id',
          firstName: 'Official-$id',
          lastName: 'Record',
          status: 'active',
          createdAt: DateTime.utc(2026, 1, 1),
          createdByUid: 'uid',
          updatedAt: DateTime.utc(2026, 1, 1),
          updatedByUid: 'uid',
        ),
    ]);
  }
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

/// Sentinel default for [_scan]'s `examineeId`: "not specified by this
/// caller", distinct from an explicitly-passed `null` (unlinked).
const Object _autoLink = Object();

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
  // Official-result filter fixture: omitted (the default) auto-links this
  // scan to its own resolvable examinee (`examinee-<id>`), so every
  // pre-existing test that never mentions linkage is unaffected. Pass
  // `null` for an unlinked scan, or a specific id (registered in
  // [_FakeClient.danglingExamineeIds] for a dangling one) to test the
  // official-identity rule directly.
  Object? examineeId = _autoLink,
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
      examineeId: identical(examineeId, _autoLink) ? 'examinee-$id' : examineeId as String?,
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

  test(
    'TAT examinee export includes five clusters and preserves 160-point score',
    () async {
      client.batches.add(_batch('t1', 'TAT'));
      client.scansByBatch['t1'] = [_scan('t-scan', 't1', 'TAT', rawScore: 160)];
      final doc = await service.buildDefaultExportDocument(
        _batchLocal('t1', 'TAT'),
      );
      final examinee = doc.examinees.single;
      expect(examinee.score, '160 / 160');
      expect(examinee.clusterRows, hasLength(5));
      expect(examinee.clusterRows!.map((r) => r.total), [15, 15, 40, 40, 20]);
      expect(examinee.clusterRows!.every((r) => r.right == null), isTrue);
      expect(examinee.clusterNote, contains('130 items'));
      expect(examinee.clusterNote, contains('160 points'));
    },
  );

  test("buildDefaultExportDocument uses the Results service's official-linked scan set", () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s-old', 'b1', 'AT', attemptNo: 1, attemptStatus: 'archived', examineeId: 'e-old'),
      _scan('s-new', 'b1', 'AT', attemptNo: 2, attemptStatus: 'active', examineeId: 'e-new'),
    ];
    final batch = _batchLocal('b1', 'AT');

    final expected = await results.loadResultsForBatch(batch);
    final document = await service.buildDefaultExportDocument(batch);

    expect(document.examinees.length, expected.scans.length);
    expect(document.examinees.map((e) => e.examineeId), ['TMP-e-new']); // archived scan excluded
  });

  test('archived Attempt 1 is excluded; active Attempt 2 is included', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s-old', 'b1', 'AT', attemptNo: 1, attemptStatus: 'archived', examineeId: 'e-old'),
      _scan('s-new', 'b1', 'AT', attemptNo: 2, attemptStatus: 'active', examineeId: 'e-new'),
    ];

    final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

    expect(document.examinees.map((e) => e.examineeId), ['TMP-e-new']);
  });

  test('a normal non-retake Attempt 1 remains included', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s1', 'b1', 'AT', examineeId: 'e-1'), // default: attempt 1, active
    ];

    final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

    expect(document.examinees.map((e) => e.examineeId), ['TMP-e-1']);
  });

  test('QTM behavior is unchanged', () async {
    client.batches.add(_batch('q1', 'QTM'));
    client.scansByBatch['q1'] = [
      _scan('s1', 'q1', 'QTM', examineeId: 'e-q1'),
    ];

    final document = await service.buildDefaultExportDocument(_batchLocal('q1', 'QTM'));

    expect(document.examinees.map((e) => e.examineeId), ['TMP-e-q1']);
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

  group('Official-result filter (examinee_id must resolve to a real examinee)', () {
    test('a linked scan is exported', () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [_scan('s1', 'b1', 'AT', examineeId: 'e-1')];

      final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

      expect(document.examinees, hasLength(1));
    });

    test('an unlinked scan (examinee_id IS NULL) is not exported', () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [
        _scan('linked', 'b1', 'AT', examineeId: 'e-1'),
        _scan('unlinked', 'b1', 'AT', examineeId: null),
      ];

      final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

      expect(document.examinees, hasLength(1));
      expect(document.examinees.single.examineeId, 'TMP-e-1');
    });

    test(
        'regression: default Export still excludes an unlinked scan even though '
        'GuidanceWebResultsService.loadResultsForBatch now returns it too -- Export narrows to the '
        'official-linked subset itself, so Results now showing unlinked scans never leaks into Export',
        () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [
        _scan('linked', 'b1', 'AT', examineeId: 'e-1'),
        _scan('unlinked', 'b1', 'AT', examineeId: null),
      ];

      // Confirm the premise: Results itself now returns BOTH scans.
      final allResults = await results.loadResultsForBatch(_batchLocal('b1', 'AT'));
      expect(allResults.scans, hasLength(2));

      // Export still only produces one examinee page.
      final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));
      expect(document.examinees, hasLength(1));
      expect(document.batch!.stats, contains(('Total', '1')));
    });

    test('a dangling examinee_id (row missing/RLS-hidden) is not exported', () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [
        _scan('linked', 'b1', 'AT', examineeId: 'e-1'),
        _scan('dangling', 'b1', 'AT', examineeId: 'e-deleted'),
      ];
      client.danglingExamineeIds.add('e-deleted');

      final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

      expect(document.examinees, hasLength(1));
      expect(document.examinees.single.examineeId, 'TMP-e-1');
    });

    test('the official ExamineeRecord is exported, never the scan\'s own OCR/staff-tagged name or number',
        () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [
        _scan(
          's1',
          'b1',
          'AT',
          examineeId: 'e-1',
          // The OCR/staff tag deliberately disagrees with the official
          // record built by _FakeClient.readCloudExaminees (Official-e-1
          // Record / TMP-e-1) -- the export must show the official values.
          firstName: 'OcrFirst',
          lastName: 'OcrLast',
          examineeNumber: 'OCR-NUMBER',
        ),
      ];

      final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

      final e = document.examinees.single;
      expect(e.examineeId, 'TMP-e-1');
      expect(e.firstName, 'Official-e-1');
      expect(e.lastName, 'Record');
      expect(e.examineeId, isNot('OCR-NUMBER'));
      expect(e.firstName, isNot('OcrFirst'));
    });

    test('the embedded Batch Analytics section counts only the same officially-linked scans as the exported pages',
        () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [
        _scan('linked-1', 'b1', 'AT', rawScore: 60, examineeId: 'e-1'),
        _scan('linked-2', 'b1', 'AT', rawScore: 70, examineeId: 'e-2'),
        _scan('unlinked', 'b1', 'AT', rawScore: 10, examineeId: null),
      ];

      final document = await service.buildDefaultExportDocument(_batchLocal('b1', 'AT'));

      expect(document.examinees, hasLength(2));
      expect(document.batch!.stats, contains(('Total', '2')));
    });

    test('multiple exam types for the same official Examinee each resolve independently', () async {
      client.batches.add(_batch('a1', 'AT'));
      client.scansByBatch['a1'] = [_scan('a-scan', 'a1', 'AT', examineeId: 'shared')];
      client.batches.add(_batch('q1', 'QTM'));
      client.scansByBatch['q1'] = [_scan('q-scan', 'q1', 'QTM', examineeId: 'shared')];

      final atDoc = await service.buildDefaultExportDocument(_batchLocal('a1', 'AT'));
      final qtmDoc = await service.buildDefaultExportDocument(_batchLocal('q1', 'QTM'));

      expect(atDoc.examinees.single.examineeId, 'TMP-shared');
      expect(qtmDoc.examinees.single.examineeId, 'TMP-shared');
    });

    test(
        'buildExportDocument drops an unlinked scan from `selected` even when the caller passes it in -- '
        'enforced in the service itself, not merely by a caller pre-filtering, so a stale or hand-built '
        'selection can never bypass the official-result rule', () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [
        _scan('linked', 'b1', 'AT', examineeId: 'e-1'),
        _scan('unlinked', 'b1', 'AT', firstName: 'Ana', lastName: 'Lim', examineeId: null),
      ];
      final batch = _batchLocal('b1', 'AT');
      final allResults = await results.loadResultsForBatch(batch);
      expect(allResults.scans, hasLength(2)); // Results shows both.

      // Deliberately pass the FULL, unfiltered scan list as `selected` --
      // simulating a stale selection or a caller that didn't pre-filter.
      final document = await service.buildExportDocument(
        batch: batch,
        includeSummary: false,
        selected: allResults.scans,
        allScans: allResults.scans,
        linkedExamineeByScanId: allResults.linkedExamineeByScanId,
      );

      expect(document.examinees, hasLength(1));
      expect(document.examinees.single.examineeId, 'TMP-e-1');
      // The OCR name never appears anywhere in the output.
      expect(document.examinees.any((e) => e.firstName == 'Ana'), isFalse);
    });

    test(
        'buildExportDocument drops a dangling-examinee_id scan from `selected` the same way, even when the '
        'caller passes it in', () async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [
        _scan('linked', 'b1', 'AT', examineeId: 'e-1'),
        _scan('dangling', 'b1', 'AT', examineeNumber: 'OLD-7', examineeId: 'e-deleted'),
      ];
      client.danglingExamineeIds.add('e-deleted');
      final batch = _batchLocal('b1', 'AT');
      final allResults = await results.loadResultsForBatch(batch);
      expect(allResults.scans, hasLength(2));

      final document = await service.buildExportDocument(
        batch: batch,
        includeSummary: false,
        selected: allResults.scans,
        allScans: allResults.scans,
        linkedExamineeByScanId: allResults.linkedExamineeByScanId,
      );

      expect(document.examinees, hasLength(1));
      expect(document.examinees.single.examineeId, 'TMP-e-1');
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
