import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/cloud_batch_mapper.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_examinee_records_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';

/// Records whether any push/write method is ever called -- the Web
/// Results service must ONLY ever call readCloudBatches/readCloudScans.
class _FakeSyncClient implements SyncClient {
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByBatchId = {};
  CloudAnswerKeyRead answerKeyToReturn = const CloudAnswerKeyRead.absent();
  CloudImageRead imageToReturn = const CloudImageRead.absent();
  CloudExamineesRead examineesToReturn = CloudExamineesRead.found(const []);
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
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) async {
    calls.add('downloadNameCropImage:$batchId:$scanId:$variant');
    return imageToReturn;
  }

  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no('deleteScan');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
  @override
  Future<CloudExamineesRead> readCloudExaminees() async {
    calls.add('readCloudExaminees');
    return examineesToReturn;
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

/// A STATEFUL fake, unlike [_FakeSyncClient] above: [createExamineeFromScan]
/// actually mutates its own [scans]/[examinees] the way the real
/// `create_examinee_from_scan` transaction does (new examinees row +
/// scans.examinee_id set, atomically, from the caller's point of view) --
/// used to prove the real Confirm & Create -> Results-visibility state
/// transition through the actual public
/// GuidanceWebExamineeRecordsService/GuidanceWebResultsService APIs, no
/// private-method or reflection hack.
class _StatefulFakeSyncClient implements SyncClient {
  final List<CloudScanRow> scans;
  final List<CloudExamineeRow> examinees = [];
  int _nextExamineeSeq = 1;

  _StatefulFakeSyncClient(this.scans);

  Never _no(String label) => throw StateError('must never call $label');

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async =>
      CloudScansRead.found(scans.where((s) => s.batchId == batchId).toList());

  @override
  Future<CloudExamineesRead> readCloudExaminees() async =>
      CloudExamineesRead.found(List.of(examinees));

  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    final index = scans.indexWhere((s) => s.batchId == batchId && s.id == scanId);
    if (index == -1) return const CloudExamineeWrite.failed(SyncOutcome.permanent('23503'));
    final newId = 'e_new_${_nextExamineeSeq++}';
    final examinee = CloudExamineeRow(
      id: newId,
      temporaryExamineeId: 'EX-NEW-$newId',
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid',
    );
    examinees.add(examinee);
    // The atomic part the real RPC does in one transaction: the same scan
    // row, now with examinee_id set -- never a second/different scan.
    final old = scans[index];
    scans[index] = CloudScanRow(
      id: old.id,
      batchId: old.batchId,
      examCode: old.examCode,
      capturedAt: old.capturedAt,
      decoded: old.decoded,
      rawScore: old.rawScore,
      totalGraded: old.totalGraded,
      totalItems: old.totalItems,
      resultStatus: old.resultStatus,
      scannedAt: old.scannedAt,
      processedByUid: old.processedByUid,
      processedByName: old.processedByName,
      firstName: old.firstName,
      lastName: old.lastName,
      middleName: old.middleName,
      examineeNumber: old.examineeNumber,
      examineeId: newId,
      imagePath: old.imagePath,
      rectifiedImagePath: old.rectifiedImagePath,
      imageUploaded: old.imageUploaded,
      rectifiedImageUploaded: old.rectifiedImageUploaded,
      attemptNo: old.attemptNo,
      attemptStatus: old.attemptStatus,
      archivedAt: old.archivedAt,
      archivedByUid: old.archivedByUid,
      archivedByName: old.archivedByName,
      archiveReason: old.archiveReason,
    );
    return CloudExamineeWrite.success(examinee);
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() => _no('readCloudBatches');
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
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) =>
      _no('downloadNameCropImage');
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no('deleteScan');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
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
  Future<CloudBatchArchivesRead> readBatchArchives() async => CloudBatchArchivesRead.found(const []);
  @override
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason}) => _no('archiveBatch');
  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) => _no('readScanCounts');
  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) => _no('readCloudScansForExaminee');
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
  String? examineeId,
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
      totalGraded: totalItems,
      totalItems: totalItems,
      resultStatus: resultStatus,
      scannedAt: resultStatus == null ? null : DateTime.utc(2026, 1, 1),
      processedByUid: resultStatus == null ? null : 'uid',
      processedByName: resultStatus == null ? null : 'Officer',
      firstName: firstName,
      lastName: lastName,
      examineeNumber: examineeNumber,
      examineeId: examineeId,
      attemptNo: attemptNo,
      attemptStatus: attemptStatus,
    );

CloudExamineeRow _examineeRow({
  required String id,
  required String temporaryId,
  required String first,
  String? middle,
  required String last,
}) =>
    CloudExamineeRow(
      id: id,
      temporaryExamineeId: temporaryId,
      firstName: first,
      middleName: middle,
      lastName: last,
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid',
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

  group('loadNameCropImage', () {
    test(
      'returns the crop bytes and calls the crop download API with the variant',
      () async {
        client.imageToReturn = CloudImageRead.found([4, 5, 6]);

        final bytes = await service.loadNameCropImage(
          'b1',
          's1',
          variant: 'name_last',
        );

        expect(bytes, [4, 5, 6]);
        expect(client.calls, ['downloadNameCropImage:b1:s1:name_last']);
      },
    );

    test(
      'sanitizes a crop download failure into GuidanceWebResultsException',
      () async {
        client.imageToReturn = const CloudImageRead.failed(
          SyncOutcome.transient('network'),
        );

        expect(
          () => service.loadNameCropImage('b1', 's1', variant: 'name_first'),
          throwsA(
            isA<GuidanceWebResultsException>().having(
              (e) => e.message,
              'message',
              isNot(contains('network')),
            ),
          ),
        );
      },
    );
  });

  test('never calls any push/write/delete/image method for a full batches+scans load', () async {
    final row = _batchRow(id: 'b1');
    client.batchesToReturn = CloudBatchesRead.found([row]);
    client.scansByBatchId['b1'] = CloudScansRead.found([_scanRow(id: 's1', batchId: 'b1')]);

    final batches = await service.loadBatches();
    await service.loadScansForBatch(batches.first);

    expect(client.calls, ['readCloudBatches', 'readCloudScans:b1']);
  });
  group('loadResultsForBatch -- resolves each scan\'s examinee through scans.examinee_id', () {
    final batch = mapCloudBatch(_batchRow());

    test('every scan is returned (linked, confirm-and-created, and genuinely unlinked alike); '
        'linkedExamineeByScanId has an entry ONLY for a resolvable link; the scan itself is '
        'not modified', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        // The verified data shape: scan-level names NULL, generated scan number.
        _scanRow(id: 's_linked', batchId: 'b1', examineeNumber: 'EX-1790006562335-3', examineeId: 'e1'),
        _scanRow(id: 's_created', batchId: 'b1', examineeNumber: 'EX-1790006562335-4', examineeId: 'e2'),
        _scanRow(id: 's_unlinked', batchId: 'b1', firstName: 'Ana', lastName: 'Lim', examineeNumber: 'OLD-7'),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', middle: 'Valdez', last: 'Andulana'),
        _examineeRow(id: 'e2', temporaryId: 'EX-000005', first: 'Maria', last: 'Santos'),
        _examineeRow(id: 'e_other', temporaryId: 'EX-000009', first: 'Nobody', last: 'Linked'),
      ]);

      final results = await service.loadResultsForBatch(batch);

      // 1. EVERY scan is present -- s_unlinked (examinee_id null) appears
      // too, now that Results shows unlinked scans as well.
      expect(results.scans.map((s) => s.id), unorderedEquals(['s_linked', 's_created', 's_unlinked']));
      // Only the two resolvable links get an entry here.
      expect(results.linkedExamineeByScanId.keys, unorderedEquals(['s_linked', 's_created']));
      final linked = results.linkedExamineeByScanId['s_linked']!;
      expect(linked.temporaryExamineeId, 'EX-000004');
      expect(linked.firstName, 'Merch');
      expect(linked.middleName, 'Valdez');
      expect(linked.lastName, 'Andulana');
      expect(results.linkedExamineeByScanId['s_created']!.displayName, 'Santos, Maria');
      expect(results.linkedExamineeByScanId.containsKey('s_unlinked'), isFalse);
      // Reference only: the scan's own tag is exactly what the row held --
      // linking/this resolution never writes to or clears it.
      final linkedScan = results.scans.firstWhere((s) => s.id == 's_linked');
      expect(linkedScan.examinee?.examineeNumber, 'EX-1790006562335-3');
      expect(linkedScan.examinee?.firstName, '');
      // The unlinked scan's own OCR tag is still there too, untouched.
      final unlinkedScan = results.scans.firstWhere((s) => s.id == 's_unlinked');
      expect(unlinkedScan.examinee?.firstName, 'Ana');
      expect(unlinkedScan.examinee?.lastName, 'Lim');
    });

    test('a batch with no linked scans never reads the examinees table, but still '
        'returns every (unlinked) scan', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', firstName: 'Ana', lastName: 'Lim', examineeNumber: 'OLD-7'),
      ]);

      final results = await service.loadResultsForBatch(batch);

      // The unlinked scan is still returned; it simply has no official
      // identity resolved for it (the examinee_id IS NULL case).
      expect(results.scans.map((s) => s.id), ['s1']);
      expect(results.linkedExamineeByScanId, isEmpty);
      expect(client.calls, isNot(contains('readCloudExaminees')));
    });

    test('4. DANGLING/MISSING EXAMINEE RECORD -- a scan pointing at an '
        'examinee that cannot be found is still returned, but never shown with '
        'the dangling link as a valid official identity', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examineeNumber: 'EX-1', examineeId: 'e_gone'),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
      ]);

      final results = await service.loadResultsForBatch(batch);

      // examinee_id was set (non-empty), so the examinees table IS read --
      // the dangling link is distinguished from a null one internally --
      // but the scan ends up with no entry in linkedExamineeByScanId either
      // way, which is all a Results caller needs to know.
      expect(client.calls, contains('readCloudExaminees'));
      expect(results.scans.map((s) => s.id), ['s1']);
      expect(results.linkedExamineeByScanId, isEmpty);
    });

    test('a genuinely unlinked scan (examinee_id IS NULL) and a dangling one both end up with '
        'no linkedExamineeByScanId entry, indistinguishably, in the same batch', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's_null', batchId: 'b1'), // examinee_id never set
        _scanRow(id: 's_dangling', batchId: 'b1', examineeId: 'e_gone'),
        _scanRow(id: 's_linked', batchId: 'b1', examineeId: 'e1'),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
      ]);

      final results = await service.loadResultsForBatch(batch);

      expect(results.scans.map((s) => s.id), unorderedEquals(['s_null', 's_dangling', 's_linked']));
      expect(results.linkedExamineeByScanId.keys, ['s_linked']);
    });

    test('2. LINKED SCAN INCLUDED -- a scan whose examinee_id resolves to an '
        'existing ExamineeRecord appears in Results', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examineeNumber: 'EX-1', examineeId: 'e1'),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
      ]);

      final results = await service.loadResultsForBatch(batch);

      expect(results.scans.map((s) => s.id), ['s1']);
      expect(results.linkedExamineeByScanId['s1']!.id, 'e1');
    });

    test('3. OFFICIAL IDENTITY USED -- when the OCR/staff tag differs from '
        'the official ExamineeRecord, the official record is what resolves', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        // Scan-level tag says "Ana Lim" -- deliberately different from the
        // official record it is linked to, simulating a corrected/updated
        // official name after linking.
        _scanRow(
          id: 's1',
          batchId: 'b1',
          firstName: 'Ana',
          lastName: 'Lim',
          examineeNumber: 'OLD-TAG',
          examineeId: 'e1',
        ),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
      ]);

      final results = await service.loadResultsForBatch(batch);

      expect(results.scans.map((s) => s.id), ['s1']);
      final official = results.linkedExamineeByScanId['s1']!;
      expect(official.firstName, 'Merch');
      expect(official.lastName, 'Andulana');
      // The scan's own (stale) tag is untouched, but is never what Results
      // should read -- resultExamineeName (view-level) only ever reads
      // linkedExamineeByScanId, never scan.examinee, for a Results row.
      final scan = results.scans.single;
      expect(scan.examinee?.firstName, 'Ana');
      expect(scan.examinee?.lastName, 'Lim');
    });

    test('6. MULTIPLE EXAM TYPES -- the same ExamineeRecord resolves '
        'correctly for QTM, TAT and AT results independently', () async {
      client.scansByBatchId['b_qtm'] = CloudScansRead.found([
        _scanRow(id: 's_qtm', batchId: 'b_qtm', examCode: 'QTM', examineeId: 'e1'),
      ]);
      client.scansByBatchId['b_tat'] = CloudScansRead.found([
        _scanRow(id: 's_tat', batchId: 'b_tat', examCode: 'TAT', examineeId: 'e1'),
      ]);
      client.scansByBatchId['b_at'] = CloudScansRead.found([
        _scanRow(id: 's_at', batchId: 'b_at', examCode: 'AT', examineeId: 'e1'),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
      ]);

      final qtmResults = await service.loadResultsForBatch(
        mapCloudBatch(_batchRow(id: 'b_qtm', examCode: 'QTM')),
      );
      final tatResults = await service.loadResultsForBatch(
        mapCloudBatch(_batchRow(id: 'b_tat', examCode: 'TAT')),
      );
      final atResults = await service.loadResultsForBatch(
        mapCloudBatch(_batchRow(id: 'b_at', examCode: 'AT')),
      );

      // Same official examinee id resolves identically across all three
      // independent exam-type batches -- never a second/different record.
      expect(qtmResults.linkedExamineeByScanId['s_qtm']!.id, 'e1');
      expect(tatResults.linkedExamineeByScanId['s_tat']!.id, 'e1');
      expect(atResults.linkedExamineeByScanId['s_at']!.id, 'e1');
      expect(
        {
          qtmResults.linkedExamineeByScanId['s_qtm']!.displayName,
          tatResults.linkedExamineeByScanId['s_tat']!.displayName,
          atResults.linkedExamineeByScanId['s_at']!.displayName,
        },
        {'Andulana, Merch'},
        reason: 'all three resolve to the exact same official identity',
      );
    });

    test('7. UNLINKED SCANS query (readUnlinkedScans) is never called by '
        'GuidanceWebResultsService -- showing unlinked scans in Results never '
        'touches the separate Unlinked Scans data path', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examineeId: 'e1'),
        _scanRow(id: 's2', batchId: 'b1'), // unlinked
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
      ]);

      final results = await service.loadResultsForBatch(batch);

      expect(results.scans.map((s) => s.id), unorderedEquals(['s1', 's2']));
      expect(client.calls, isNot(contains('readUnlinkedScans')));
    });

    test('a failed examinee lookup fails loudly instead of silently showing linked scans as Unnamed', () async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examineeNumber: 'EX-1', examineeId: 'e1'),
      ]);
      client.examineesToReturn = const CloudExamineesRead.failed(SyncOutcome.transient('network'));

      await expectLater(
        service.loadResultsForBatch(batch),
        throwsA(isA<GuidanceWebResultsException>().having((e) => e.message, 'message', contains('Supabase'))),
      );
    });
  });


group('Applicant Retake Management -- archived attempts excluded by default', () {
  test('loadScansForBatch excludes an archived attempt by default', () async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'AT')]);
    client.scansByBatchId['b1'] = CloudScansRead.found([
      _scanRow(id: 's-old', batchId: 'b1', attemptNo: 1, attemptStatus: 'archived'),
      _scanRow(id: 's-new', batchId: 'b1', attemptNo: 2, attemptStatus: 'active'),
    ]);

    final scans = await service.loadScansForBatch(mapCloudBatch(_batchRow(id: 'b1', examCode: 'AT')));

    expect(scans.map((s) => s.id), ['s-new']);
  });

  test('loadScansForBatch includes an archived attempt when explicitly asked', () async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'AT')]);
    client.scansByBatchId['b1'] = CloudScansRead.found([
      _scanRow(id: 's-old', batchId: 'b1', attemptNo: 1, attemptStatus: 'archived'),
      _scanRow(id: 's-new', batchId: 'b1', attemptNo: 2, attemptStatus: 'active'),
    ]);

    final scans = await service.loadScansForBatch(
      mapCloudBatch(_batchRow(id: 'b1', examCode: 'AT')),
      includeArchivedAttempts: true,
    );

    expect(scans.map((s) => s.id).toSet(), {'s-old', 's-new'});
  });

  test('loadResultsForBatch excludes an archived attempt by default, including its examinee lookup', () async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'AT')]);
    client.scansByBatchId['b1'] = CloudScansRead.found([
      _scanRow(id: 's-old', batchId: 'b1', attemptNo: 1, attemptStatus: 'archived', examineeId: 'e1'),
      _scanRow(id: 's-new', batchId: 'b1', attemptNo: 2, attemptStatus: 'active', examineeId: 'e1'),
    ]);
    client.examineesToReturn = CloudExamineesRead.found([
      _examineeRow(id: 'e1', temporaryId: 'EX-1', first: 'Juan', last: 'Dela Cruz'),
    ]);

    final results = await service.loadResultsForBatch(mapCloudBatch(_batchRow(id: 'b1', examCode: 'AT')));

    expect(results.scans.map((s) => s.id), ['s-new']);
    expect(results.linkedExamineeByScanId.keys, ['s-new']);
  });

  test('an applicant with only Attempt 1 (no retake) is unchanged -- still shown', () async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'AT')]);
    client.scansByBatchId['b1'] = CloudScansRead.found([
      _scanRow(id: 's1', batchId: 'b1'), // defaults: attempt 1, active
    ]);

    final scans = await service.loadScansForBatch(mapCloudBatch(_batchRow(id: 'b1', examCode: 'AT')));

    expect(scans.map((s) => s.id), ['s1']);
  });

  test('QTM (never archived) is unchanged', () async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'QTM')]);
    client.scansByBatchId['b1'] = CloudScansRead.found([
      _scanRow(id: 's1', batchId: 'b1', examCode: 'QTM'),
    ]);

    final scans = await service.loadScansForBatch(mapCloudBatch(_batchRow(id: 'b1', examCode: 'QTM')));

    expect(scans.map((s) => s.id), ['s1']);
  });
});

group('5. CONFIRM & CREATE PATH -- Confirm & Create Examinee makes the '
    'result visible in Results, through the real public service APIs '
    '(GuidanceWebExamineeRecordsService.createExamineeFromScan then '
    'GuidanceWebResultsService.loadResultsForBatch), never a reflection/'
    'private-method hack', () {
  test('unlinked scored scan -> excluded; Confirm & Create -> official '
      'ExamineeRecord created and linked -> Results reload includes it '
      'under the official identity, never the OCR/staff tag', () async {
    // Starting state: a scored, unlinked scan with only OCR/staff-tagged
    // identity information -- examinee_id is null.
    final sharedClient = _StatefulFakeSyncClient([
      CloudScanRow(
        id: 's_unlinked',
        batchId: 'b1',
        examCode: 'AT',
        capturedAt: DateTime.utc(2026, 1, 1),
        decoded: const {'examCode': 'AT', 'items': <dynamic>[]},
        rawScore: 54,
        totalGraded: 72,
        totalItems: 72,
        resultStatus: 'Graded',
        scannedAt: DateTime.utc(2026, 1, 1),
        processedByUid: 'uid',
        processedByName: 'Officer',
        firstName: 'Ana',
        lastName: 'Lim',
        examineeNumber: 'OCR-TAG-1',
        // examineeId intentionally omitted -- unlinked.
      ),
    ]);
    final resultsService = GuidanceWebResultsService(client: sharedClient);
    final examineeRecordsService =
        GuidanceWebExamineeRecordsService(client: sharedClient);
    final batch = mapCloudBatch(_batchRow(id: 'b1', examCode: 'AT'));

    // G. Results visibility BEFORE creation: the scan is present (Results
    // now shows unlinked scans too), but with no official identity resolved.
    final before = await resultsService.loadResultsForBatch(batch);
    expect(before.scans.map((s) => s.id), ['s_unlinked']);
    expect(before.linkedExamineeByScanId, isEmpty);

    // D. Exercise the actual Confirm & Create action through the real,
    // public service method -- the same one the UI calls.
    final localScan = mapCloudScan(sharedClient.scans.single);
    final created = await examineeRecordsService.createExamineeFromScan(
      batchId: 'b1',
      scan: localScan,
      firstName: 'Maria', // deliberately different from the OCR tag
      lastName: 'Santos', // ("Ana Lim") to prove which identity wins
    );

    // E. Resulting Examinee ID: a new, official examinees.id exists.
    expect(created.id, isNotEmpty);
    expect(sharedClient.examinees.single.id, created.id);
    expect(created.firstName, 'Maria');
    expect(created.lastName, 'Santos');

    // F. Resulting scan link state: the SAME scan row now carries that
    // official examinee_id -- proven by reading it back through the fake's
    // own state (the atomic part of the real RPC), not asserted separately.
    expect(sharedClient.scans.single.id, 's_unlinked');
    expect(sharedClient.scans.single.examineeId, created.id);
    // The OCR/staff tag columns are untouched by linking (same invariant
    // proven elsewhere for Link-to-Existing).
    expect(sharedClient.scans.single.firstName, 'Ana');
    expect(sharedClient.scans.single.lastName, 'Lim');

    // H. Results visibility AFTER creation (a fresh reload, exactly what
    // the UI does after Confirm & Create completes): included.
    final after = await resultsService.loadResultsForBatch(batch);
    expect(after.scans.map((s) => s.id), ['s_unlinked']);

    // I. Official identity assertion: the resolved ExamineeRecord is the
    // one just created.
    final resolved = after.linkedExamineeByScanId['s_unlinked']!;
    expect(resolved.id, created.id);
    expect(resolved.firstName, 'Maria');
    expect(resolved.lastName, 'Santos');

    // J. OCR identity assertion: the original OCR/staff tag ("Ana Lim")
    // never becomes -- and is not shown as -- the authoritative identity.
    expect(resolved.firstName, isNot('Ana'));
    expect(resolved.lastName, isNot('Lim'));
    expect(after.scans.single.examinee?.firstName, 'Ana',
        reason: 'the OCR tag itself is still there on the scan (never '
            'erased) -- it is simply not what Results treats as official');
  });
});

}
