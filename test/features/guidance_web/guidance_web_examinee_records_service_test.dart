import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_examinee_records_service.dart';
import 'package:guidegrade/models/examinee_record.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

class _FakeSyncClient implements SyncClient {
  CloudExamineesRead examineesToReturn = CloudExamineesRead.found(const []);
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByExamineeId = {};
  CloudScansRead unlinkedScansToReturn = CloudScansRead.found(const []);

  /// Simulates PostgreSQL's atomic `nextval()`: increments on every
  /// [createExamineeFromScan] call, so sequential creates always get a
  /// distinct, server-assigned, zero-padded ID ('EX-000001', 'EX-000002',
  /// ...) that the CLIENT never chose or sent. When [createResultOverride]
  /// is set, that is returned verbatim instead (for failure-path tests).
  int _serverSequence = 0;
  CloudExamineeWrite? createResultOverride;

  /// When null, [updateCloudExaminee] echoes back a row built from its own
  /// arguments (a believable "the server accepted this update" response).
  CloudExamineeWrite? updateResultOverride;

  /// When null, [setExamineeArchived] echoes back a row reflecting the
  /// requested status flip.
  CloudExamineeWrite? archiveResultOverride;
  SyncOutcome linkResultToReturn = const SyncOutcome.success();

  /// When true, [linkScanToExaminee] behaves like the real guarded UPDATE:
  /// a scan that is not in the unlinked queue matches zero rows -> conflict.
  bool simulateLinkGuard = false;

  final List<String> calls = [];
  String? lastUpdateId;
  Map<String, String?>? lastLinkArgs;
  Map<String, String>? lastCreateFromScanArgs;

  Never _no(String label) {
    calls.add(label);
    throw StateError('GuidanceWebExamineeRecordsService must never call $label');
  }

  @override
  Future<CloudExamineesRead> readCloudExaminees() async {
    calls.add('readCloudExaminees');
    return examineesToReturn;
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('readCloudBatches');
    return batchesToReturn;
  }

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() =>
      _no('readBatchArchives');

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
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) async {
    calls.add('readCloudScansForExaminee:$examineeId');
    return scansByExamineeId[examineeId] ?? CloudScansRead.found(const []);
  }

  @override
  Future<CloudScansRead> readUnlinkedScans() async {
    calls.add('readUnlinkedScans');
    return unlinkedScansToReturn;
  }

  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    calls.add('createExamineeFromScan:$batchId/$scanId');
    lastCreateFromScanArgs = {
      'batchId': batchId,
      'scanId': scanId,
      'firstName': firstName,
      'middleName': middleName ?? '',
      'lastName': lastName,
    };
    if (createResultOverride != null) return createResultOverride!;
    _serverSequence++;
    final assignedId = 'EX-${_serverSequence.toString().padLeft(6, '0')}';
    return CloudExamineeWrite.success(CloudExamineeRow(
      id: 'server-$_serverSequence',
      temporaryExamineeId: assignedId,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid1',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid1',
    ));
  }

  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    calls.add('updateCloudExaminee:$id');
    lastUpdateId = id;
    return updateResultOverride ??
        CloudExamineeWrite.success(CloudExamineeRow(
          id: id,
          temporaryExamineeId: 'EX-1',
          firstName: firstName,
          middleName: middleName,
          lastName: lastName,
          status: 'active',
          createdAt: DateTime.utc(2026, 1, 1),
          createdByUid: 'uid1',
          updatedAt: DateTime.utc(2026, 2, 1),
          updatedByUid: 'uid2',
        ));
  }

  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) async {
    calls.add('setExamineeArchived:$id/$archived');
    return archiveResultOverride ??
        CloudExamineeWrite.success(CloudExamineeRow(
          id: id,
          temporaryExamineeId: 'EX-1',
          firstName: 'Juan',
          lastName: 'Dela Cruz',
          status: archived ? 'archived' : 'active',
          archivedAt: archived ? DateTime.utc(2026, 2, 1) : null,
          archivedByUid: archived ? 'uid2' : null,
          createdAt: DateTime.utc(2026, 1, 1),
          createdByUid: 'uid1',
          updatedAt: DateTime.utc(2026, 2, 1),
          updatedByUid: 'uid2',
        ));
  }

  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) async {
    calls.add('linkScanToExaminee:$batchId/$scanId/$examineeId');
    lastLinkArgs = {'batchId': batchId, 'scanId': scanId, 'examineeId': examineeId};
    if (linkResultToReturn.isSuccess && examineeId != null) {
      // Simulates the guarded UPDATE ... WHERE batch_id AND id AND
      // examinee_id IS NULL: the scan leaves the unlinked queue and joins
      // the examinee's linked scans.
      final match = unlinkedScansToReturn.scans
          .where((s) => s.batchId == batchId && s.id == scanId)
          .toList();
      if (match.isEmpty && simulateLinkGuard) {
        // Not unlinked any more (or missing) -> zero rows -> conflict.
        return const SyncOutcome.conflict('scan_already_linked');
      }
      if (match.isNotEmpty) {
        unlinkedScansToReturn = CloudScansRead.found(
          unlinkedScansToReturn.scans.where((s) => s != match.first).toList(),
        );
        scansByExamineeId[examineeId] = CloudScansRead.found([
          ...?scansByExamineeId[examineeId]?.scans,
          match.first,
        ]);
      }
    }
    return linkResultToReturn;
  }

  /// When set, [unlinkScanFromExaminee] returns it verbatim.
  SyncOutcome? unlinkResultOverride;
  Map<String, String>? lastUnlinkArgs;

  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) async {
    calls.add('unlinkScanFromExaminee:$batchId/$scanId/$examineeId');
    lastUnlinkArgs = {'batchId': batchId, 'scanId': scanId, 'examineeId': examineeId};
    if (unlinkResultOverride != null) return unlinkResultOverride!;
    // Simulates `UPDATE scans SET examinee_id = NULL WHERE batch_id = ? AND
    // id = ? AND examinee_id = ?` -- zero matching rows is a conflict, and
    // the scan row itself is never removed, only moved to the unlinked queue.
    final linked = scansByExamineeId[examineeId];
    final match = (linked == null)
        ? <CloudScanRow>[]
        : linked.scans.where((s) => s.batchId == batchId && s.id == scanId).toList();
    if (match.isEmpty) return const SyncOutcome.conflict('scan_not_linked_to_examinee');
    scansByExamineeId[examineeId] = CloudScansRead.found(
      linked!.scans.where((s) => s != match.first).toList(),
    );
    unlinkedScansToReturn = CloudScansRead.found([
      ...unlinkedScansToReturn.scans,
      match.first,
    ]);
    return const SyncOutcome.success();
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
  Future<CloudScansRead> readCloudScans(String batchId) => _no('readCloudScans');
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
}

CloudExamineeRow _examineeRow({
  String id = 'e1',
  String temporaryExamineeId = 'EX-1',
  String? officialStudentId,
  String firstName = 'Juan',
  String? middleName,
  String lastName = 'Dela Cruz',
  String status = 'active',
}) =>
    CloudExamineeRow(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      officialStudentId: officialStudentId,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      status: status,
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid1',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid1',
    );

CloudBatchRow _batchRow({String id = 'b1', String examCode = 'AT'}) => CloudBatchRow(
      id: id,
      batchCode: 'B-$examCode',
      examCode: examCode,
      examTitle: examCode,
      description: '',
      expectedCount: 1,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

CloudScanRow _scanRow({
  required String id,
  required String batchId,
  required String examCode,
  DateTime? capturedAt,
  int rawScore = 50,
  int totalItems = 72,
  String? firstName = 'Juan',
  String? lastName = 'Dela Cruz',
  String? examineeNumber = 'EX-legacy-1',
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: capturedAt ?? DateTime.utc(2026, 1, 1),
      decoded: {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: rawScore,
      totalGraded: totalItems,
      totalItems: totalItems,
      resultStatus: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'uid',
      processedByName: 'Officer',
      firstName: firstName,
      lastName: lastName,
      examineeNumber: examineeNumber,
    );

/// A minimal [LocalScan], the shape [GuidanceWebExamineeRecordsService]'s
/// scan-scoped methods take (mirrors the scan a `mapCloudScan`'d row would
/// produce).
LocalScan _localScan({required String id, String? firstName, String? lastName}) => LocalScan(
      id: id,
      imageFileName: 'images/$id.enc',
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: OmrScanResult(examCode: 'AT', items: const []),
      examinee: (firstName == null && lastName == null)
          ? null
          : ExamineeInfo(firstName: firstName ?? '', lastName: lastName ?? '', examineeNumber: 'EX-legacy-1'),
    );

ExamineeRecord _examinee({
  String id = 'e1',
  String temporaryExamineeId = 'EX-1',
  String status = 'active',
}) =>
    ExamineeRecord(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      firstName: 'Juan',
      lastName: 'Dela Cruz',
      status: status,
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid',
    );

void main() {
  late _FakeSyncClient client;
  late GuidanceWebExamineeRecordsService service;

  setUp(() {
    client = _FakeSyncClient();
    // The examinees the link tests use are ACTIVE rows in the database --
    // linkScanToExaminee now checks the examinee's current status.
    client.examineesToReturn = CloudExamineesRead.found([
      _examineeRow(id: 'e1'),
      _examineeRow(id: 'e2', temporaryExamineeId: 'EX-2'),
      _examineeRow(id: 'e5', temporaryExamineeId: 'EX-000005'),
    ]);
    service = GuidanceWebExamineeRecordsService(client: client);
  });

  group('loadExaminees', () {
    test('maps every cloud examinee row, including nullable fields', () async {
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', officialStudentId: null),
        _examineeRow(id: 'e2', officialStudentId: '2026-12345', status: 'archived'),
      ]);
      final result = await service.loadExaminees();
      expect(result, hasLength(2));
      expect(result[0].officialStudentId, isNull);
      expect(result[1].officialStudentId, '2026-12345');
      expect(result[1].isArchived, isTrue);
    });

    test('throws a sanitized GuidanceWebExamineeRecordsException on failure', () async {
      client.examineesToReturn = const CloudExamineesRead.failed(SyncOutcome.permanent('rls_denied'));
      expect(
        () => service.loadExaminees(),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
    });
  });

  group('5. loadHistoryFor groups scans by examinee, joined to their batch', () {
    test('returns one history item per linked scan, newest first', () async {
      final examinee = _examinee();
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(id: 'b-qtm', examCode: 'QTM'),
        _batchRow(id: 'b-tat', examCode: 'TAT'),
      ]);
      client.scansByExamineeId['e1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b-qtm', examCode: 'QTM', capturedAt: DateTime.utc(2026, 1, 1)),
        _scanRow(id: 's2', batchId: 'b-tat', examCode: 'TAT', capturedAt: DateTime.utc(2026, 2, 1)),
      ]);

      final history = await service.loadHistoryFor(examinee);

      expect(history, hasLength(2));
      // Newest capturedAt first.
      expect(history[0].examCode, 'TAT');
      expect(history[1].examCode, 'QTM');
    });

    test('a scan whose batch cannot be found is skipped, never shown with fabricated batch info', () async {
      final examinee = _examinee();
      client.batchesToReturn = CloudBatchesRead.found(const []);
      client.scansByExamineeId['e1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'missing-batch', examCode: 'QTM'),
      ]);

      final history = await service.loadHistoryFor(examinee);
      expect(history, isEmpty);
    });
  });

  group('Unlinked Scans queue', () {
    test('loadUnlinkedScans joins scans.examinee_id IS NULL rows to their batch, newest first', () async {
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(id: 'b-qtm', examCode: 'QTM'),
        _batchRow(id: 'b-tat', examCode: 'TAT'),
      ]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b-qtm', examCode: 'QTM', capturedAt: DateTime.utc(2026, 1, 1)),
        _scanRow(id: 's2', batchId: 'b-tat', examCode: 'TAT', capturedAt: DateTime.utc(2026, 2, 1)),
      ]);

      final unlinked = await service.loadUnlinkedScans();

      expect(client.calls, contains('readUnlinkedScans'));
      expect(unlinked, hasLength(2));
      expect(unlinked[0].examCode, 'TAT');
      expect(unlinked[1].examCode, 'QTM');
    });

    test('an unlinked scan with no OCR name at all is still returned -- OCR failure never blocks the queue', () async {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'AT')]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examCode: 'AT', firstName: null, lastName: null, examineeNumber: null),
      ]);

      final unlinked = await service.loadUnlinkedScans();
      expect(unlinked, hasLength(1));
      expect(unlinked.first.scan.examinee, isNull);
    });

    test('throws a sanitized exception on failure', () async {
      client.unlinkedScansToReturn = const CloudScansRead.failed(SyncOutcome.permanent('rls_denied'));
      expect(() => service.loadUnlinkedScans(), throwsA(isA<GuidanceWebExamineeRecordsException>()));
    });
  });

  group('3. createExamineeFromScan (Workflow 1 -- no blank-record creation exists)', () {
    test('the Temporary Examinee ID comes back from the server, never invented client-side', () async {
      final scan = _localScan(id: 's1');
      final created = await service.createExamineeFromScan(
        batchId: 'b1',
        scan: scan,
        firstName: 'Juan',
        lastName: 'Dela Cruz',
      );
      expect(client.calls, contains('createExamineeFromScan:b1/s1'));
      // The fake's server-side sequence assigned this -- the method's own
      // signature has no id-like parameter at all, so there is no way for
      // the service to have sent or influenced it.
      expect(created.temporaryExamineeId, 'EX-000001');
    });

    test('never copies the scan\'s own examinee_number into the new Temporary Examinee ID', () async {
      // The triggering scan's LocalScan carries no raw examinee_number at
      // all (mapCloudScan never mirrors that column onto LocalScan/
      // ExamineeInfo) -- createExamineeFromScan only ever forwards
      // batchId/scanId/name fields, confirmed by what the fake recorded.
      final scan = _localScan(id: 's1', firstName: 'Juan', lastName: 'Dela Cruz');
      await service.createExamineeFromScan(batchId: 'b1', scan: scan, firstName: 'Juan', lastName: 'Dela Cruz');
      expect(client.lastCreateFromScanArgs, isNot(contains('examineeNumber')));
      expect(client.lastCreateFromScanArgs!['scanId'], 's1');
    });

    test('16. two different scans, even with the identical name, get distinct sequence-assigned IDs -- never merged',
        () async {
      final first = await service.createExamineeFromScan(
        batchId: 'b1',
        scan: _localScan(id: 's1'),
        firstName: 'Juan',
        lastName: 'Dela Cruz',
      );
      final second = await service.createExamineeFromScan(
        batchId: 'b1',
        scan: _localScan(id: 's2'),
        firstName: 'Juan',
        lastName: 'Dela Cruz',
      );

      expect(first.temporaryExamineeId, 'EX-000001');
      expect(second.temporaryExamineeId, 'EX-000002');
      expect(first.temporaryExamineeId, isNot(second.temporaryExamineeId));
    });

    test('OCR failure (blank names) does not prevent creation', () async {
      final created = await service.createExamineeFromScan(
        batchId: 'b1',
        scan: _localScan(id: 's1'),
        firstName: '',
        lastName: '',
      );
      expect(created.temporaryExamineeId, isNotEmpty);
    });

    test('throws a sanitized exception on failure', () async {
      client.createResultOverride = const CloudExamineeWrite.failed(SyncOutcome.permanent('rls_denied'));
      expect(
        () => service.createExamineeFromScan(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          firstName: 'Juan',
          lastName: 'Dela Cruz',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
    });
  });

  group('4. linkScanToExaminee (Workflow 3/4 -- the one shared linking mechanism)', () {
    test('links the exact scan/batch to the exact examinee, no matching logic of its own', () async {
      final examinee = _examinee(id: 'e5', temporaryExamineeId: 'EX-000005');
      await service.linkScanToExaminee(
        batchId: 'b1',
        scan: _localScan(id: 's1'),
        examinee: examinee,
        examCode: 'AT',
      );
      expect(client.lastLinkArgs, {'batchId': 'b1', 'scanId': 's1', 'examineeId': 'e5'});
    });

    test('throws a sanitized exception on failure', () async {
      client.linkResultToReturn = const SyncOutcome.permanent('rls_denied');
      expect(
        () => service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(),
          examCode: 'AT',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
    });
  });

  group('Archived examinees cannot receive a new scan', () {
    void seedUnlinkedScan() {
      client.unlinkedScansToReturn =
          CloudScansRead.found([_scanRow(id: 's1', batchId: 'b1', examCode: 'AT')]);
    }

    void expectNothingLinked() {
      expect(client.calls.where((c) => c.startsWith('linkScanToExaminee')), isEmpty);
      expect(client.lastLinkArgs, isNull);
      // The scan is still in the unlinked queue and nobody gained a scan.
      expect(client.unlinkedScansToReturn.scans.map((s) => s.id), ['s1']);
      expect(client.scansByExamineeId, isEmpty);
    }

    test('an active examinee is linked through the existing flow', () async {
      seedUnlinkedScan();
      await service.linkScanToExaminee(
        batchId: 'b1',
        scan: _localScan(id: 's1'),
        examinee: _examinee(id: 'e1'),
        examCode: 'AT',
      );
      expect(client.lastLinkArgs, {'batchId': 'b1', 'scanId': 's1', 'examineeId': 'e1'});
      expect(client.unlinkedScansToReturn.scans, isEmpty);
    });

    test('an examinee held as archived is rejected before any read or write', () async {
      seedUnlinkedScan();
      await expectLater(
        service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(id: 'e1', status: 'archived'),
          examCode: 'AT',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>().having(
          (e) => e.message,
          'message',
          'Archived examinees cannot be linked to new scans. Restore the examinee first.',
        )),
      );
      expect(client.calls, isEmpty);
      expectNothingLinked();
    });

    test('a stale active copy is rejected when the database row is now archived', () async {
      seedUnlinkedScan();
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', status: 'archived'),
      ]);
      await expectLater(
        service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(id: 'e1'), // the page still thinks it is active
          examCode: 'AT',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>().having(
          (e) => e.message,
          'message',
          contains('Restore the examinee first'),
        )),
      );
      expectNothingLinked();
    });

    test('an examinee that no longer exists is rejected without linking', () async {
      seedUnlinkedScan();
      client.examineesToReturn = CloudExamineesRead.found(const []);
      await expectLater(
        service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(id: 'e1'),
          examCode: 'AT',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>().having(
          (e) => e.message,
          'message',
          contains('no longer available'),
        )),
      );
      expectNothingLinked();
    });

    test('a failed status lookup blocks the link instead of guessing', () async {
      seedUnlinkedScan();
      client.examineesToReturn = CloudExamineesRead.failed(const SyncOutcome.transient('network'));
      await expectLater(
        service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(id: 'e1'),
          examCode: 'AT',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
      expectNothingLinked();
    });

    test('after Restore the same examinee can be linked again', () async {
      seedUnlinkedScan();
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', status: 'archived'),
      ]);
      await expectLater(
        service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(id: 'e1', status: 'archived'),
          examCode: 'AT',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );

      final restored = await service.restoreExaminee(_examinee(id: 'e1', status: 'archived'));
      expect(restored.isActive, isTrue);
      client.examineesToReturn = CloudExamineesRead.found([_examineeRow(id: 'e1')]);

      await service.linkScanToExaminee(
        batchId: 'b1',
        scan: _localScan(id: 's1'),
        examinee: restored,
        examCode: 'AT',
      );
      expect(client.lastLinkArgs, {'batchId': 'b1', 'scanId': 's1', 'examineeId': 'e1'});
    });

    test('archiving keeps existing linked scans linked (only the status call is made)', () async {
      client.scansByExamineeId['e1'] = CloudScansRead.found([
        _scanRow(id: 's-old', batchId: 'b1', examCode: 'TAT'),
      ]);
      final archived = await service.archiveExaminee(_examinee(id: 'e1'));
      expect(archived.isArchived, isTrue);
      expect(client.calls, ['setExamineeArchived:e1/true']);
      expect(client.scansByExamineeId['e1']!.scans.map((s) => s.id), ['s-old']);
    });
  });

  group('Guarded link (only while the scan is still unlinked)', () {
    setUp(() => client.simulateLinkGuard = true);

    test('1. a currently unlinked scan links successfully and leaves the unlinked queue', () async {
      client.unlinkedScansToReturn =
          CloudScansRead.found([_scanRow(id: 's1', batchId: 'b1', examCode: 'TAT', rawScore: 61)]);
      await service.linkScanToExaminee(
        batchId: 'b1',
        scan: _localScan(id: 's1'),
        examinee: _examinee(id: 'e1'),
        examCode: 'TAT',
      );
      expect(client.unlinkedScansToReturn.scans, isEmpty);
      final linked = client.scansByExamineeId['e1']!.scans.single;
      expect(linked.id, 's1');
      expect(linked.rawScore, 61); // same row moved, data untouched
    });

    test('2/3. an already-linked scan is NOT overwritten: zero rows -> conflict, not success', () async {
      // s1 is already linked to e1 (so it is not in the unlinked queue).
      client.scansByExamineeId['e1'] =
          CloudScansRead.found([_scanRow(id: 's1', batchId: 'b1', examCode: 'TAT')]);

      await expectLater(
        service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(id: 'e2'),
          examCode: 'TAT',
        ),
        throwsA(isA<GuidanceWebExamineeRecordsException>()
            .having((e) => e.message, 'message', contains('already linked'))),
      );
      // e1 keeps its scan; e2 got nothing.
      expect(client.scansByExamineeId['e1']!.scans.single.id, 's1');
      expect(client.scansByExamineeId['e2'], isNull);
    });

    test('a conflict message never exposes a database code', () async {
      client.linkResultToReturn = const SyncOutcome.conflict('scan_already_linked');
      Object? error;
      try {
        await service.linkScanToExaminee(
          batchId: 'b1',
          scan: _localScan(id: 's1'),
          examinee: _examinee(),
          examCode: 'AT',
        );
      } catch (e) {
        error = e;
      }
      final message = (error as GuidanceWebExamineeRecordsException).message;
      expect(message, isNot(contains('scan_already_linked')));
      expect(message, isNot(contains('23505')));
    });

    test('5. no scan is deleted by a rejected or successful link', () async {
      client.unlinkedScansToReturn =
          CloudScansRead.found([_scanRow(id: 's1', batchId: 'b1', examCode: 'AT')]);
      await service.linkScanToExaminee(
          batchId: 'b1', scan: _localScan(id: 's1'), examinee: _examinee(), examCode: 'AT');
      await expectLater(
        service.linkScanToExaminee(
            batchId: 'b1', scan: _localScan(id: 's1'), examinee: _examinee(id: 'e2'), examCode: 'AT'),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
      expect(client.calls.where((c) => c.startsWith('delete')), isEmpty);
    });

    test('4. the client-side duplicate exam-code check still runs first (no write attempted)', () async {
      client.scansByExamineeId['e1'] =
          CloudScansRead.found([_scanRow(id: 'old', batchId: 'b0', examCode: 'TAT')]);
      client.unlinkedScansToReturn =
          CloudScansRead.found([_scanRow(id: 's-new', batchId: 'b-new', examCode: 'TAT')]);
      await expectLater(
        service.linkScanToExaminee(
            batchId: 'b-new', scan: _localScan(id: 's-new'), examinee: _examinee(), examCode: 'TAT'),
        throwsA(isA<GuidanceWebExamineeRecordsException>()
            .having((e) => e.message, 'message', contains('already has a TAT examination record'))),
      );
      expect(client.calls.where((c) => c.startsWith('linkScanToExaminee')), isEmpty);
      expect(client.unlinkedScansToReturn.scans.single.id, 's-new'); // still unlinked
    });
  });

  group('Duplicate exam type is rejected before linking', () {
    void seedLinked(String examineeId, Map<String, String> batchToCode) {
      client.scansByExamineeId[examineeId] = CloudScansRead.found([
        for (final e in batchToCode.entries)
          _scanRow(id: 'linked-${e.value}', batchId: e.key, examCode: e.value),
      ]);
    }

    Future<String> messageOf(String examCode) async {
      try {
        await service.linkScanToExaminee(
          batchId: 'b-new',
          scan: _localScan(id: 's-new'),
          examinee: _examinee(),
          examCode: examCode,
        );
      } on GuidanceWebExamineeRecordsException catch (e) {
        return e.message;
      }
      return '';
    }

    test('TAT when the examinee already has a TAT', () async {
      seedLinked('e1', {'b-tat': 'TAT'});
      expect(
        await messageOf('TAT'),
        'Cannot link this examination.\n\nThis examinee already has a TAT examination record.',
      );
      expect(client.calls.where((c) => c.startsWith('linkScanToExaminee')), isEmpty);
    });

    test('QTM message uses "a QTM"', () async {
      seedLinked('e1', {'b-qtm': 'QTM'});
      expect(
        await messageOf('QTM'),
        'Cannot link this examination.\n\nThis examinee already has a QTM examination record.',
      );
    });

    test('AT message uses "an AT"', () async {
      seedLinked('e1', {'b-at': 'AT'});
      expect(
        await messageOf('AT'),
        'Cannot link this examination.\n\nThis examinee already has an AT examination record.',
      );
    });

    test('the rejected scan stays unlinked and is never deleted', () async {
      seedLinked('e1', {'b-tat': 'TAT'});
      client.unlinkedScansToReturn =
          CloudScansRead.found([_scanRow(id: 's-new', batchId: 'b-new', examCode: 'TAT')]);
      await messageOf('TAT');
      expect(client.unlinkedScansToReturn.scans.map((s) => s.id), ['s-new']);
      expect(client.calls.where((c) => c.startsWith('delete')), isEmpty);
    });

    test('different exam types can coexist on one examinee (QTM + TAT + AT)', () async {
      seedLinked('e1', {'b-qtm': 'QTM'});
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's-tat', batchId: 'b-tat', examCode: 'TAT'),
        _scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT'),
      ]);
      await service.linkScanToExaminee(
          batchId: 'b-tat', scan: _localScan(id: 's-tat'), examinee: _examinee(), examCode: 'TAT');
      await service.linkScanToExaminee(
          batchId: 'b-at', scan: _localScan(id: 's-at'), examinee: _examinee(), examCode: 'AT');
      expect(client.scansByExamineeId['e1']!.scans.map((s) => s.examCode).toSet(), {'QTM', 'TAT', 'AT'});
    });

    test('a database 23505 (race) becomes the same friendly message, never the raw code', () async {
      client.linkResultToReturn = const SyncOutcome.permanent('23505');
      final message = await messageOf('TAT');
      expect(message, contains('already has a TAT examination record'));
      expect(message, isNot(contains('23505')));
      expect(message.toLowerCase(), isNot(contains('duplicate key')));
    });

    test('fails closed (no link attempted) when the existing scans cannot be read', () async {
      client.scansByExamineeId['e1'] = const CloudScansRead.failed(SyncOutcome.transient('network'));
      expect(await messageOf('TAT'), isNotEmpty);
      expect(client.calls.where((c) => c.startsWith('linkScanToExaminee')), isEmpty);
    });
  });

  group('Remove Link (removeExamLink)', () {
    void seedThreeExams() {
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(id: 'b-qtm', examCode: 'QTM'),
        _batchRow(id: 'b-tat', examCode: 'TAT'),
        _batchRow(id: 'b-at', examCode: 'AT'),
      ]);
      client.scansByExamineeId['e1'] = CloudScansRead.found([
        _scanRow(id: 's-qtm', batchId: 'b-qtm', examCode: 'QTM'),
        _scanRow(id: 's-tat', batchId: 'b-tat', examCode: 'TAT', rawScore: 77),
        _scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT'),
      ]);
    }

    test('1/2. calls the dedicated unlink operation with batchId + scanId + examineeId', () async {
      seedThreeExams();
      await service.removeExamLink(batchId: 'b-tat', scanId: 's-tat', examineeId: 'e1');
      expect(client.lastUnlinkArgs, {'batchId': 'b-tat', 'scanId': 's-tat', 'examineeId': 'e1'});
      // Never reuses the link method for unlinking.
      expect(client.calls.where((c) => c.startsWith('linkScanToExaminee')), isEmpty);
    });

    test('other exams remain; the removed one leaves the examinee history', () async {
      seedThreeExams();
      await service.removeExamLink(batchId: 'b-tat', scanId: 's-tat', examineeId: 'e1');
      final history = await service.loadHistoryFor(_examinee());
      expect(history.map((h) => h.examCode).toSet(), {'QTM', 'AT'});
    });

    test('the scan is not deleted: it reappears as an unlinked scan with its data intact', () async {
      seedThreeExams();
      await service.removeExamLink(batchId: 'b-tat', scanId: 's-tat', examineeId: 'e1');
      final unlinked = await service.loadUnlinkedScans();
      expect(unlinked, hasLength(1));
      expect(unlinked.single.scan.id, 's-tat');
      expect(unlinked.single.examCode, 'TAT');
      expect(unlinked.single.scan.result!.rawScore, 77); // score unchanged
      for (final call in client.calls) {
        expect(call, isNot(startsWith('delete')));
        expect(call, isNot(startsWith('push')));
        expect(call, isNot(startsWith('upload')));
      }
    });

    test('an unlinked scan can be explicitly linked again to the correct examinee', () async {
      seedThreeExams();
      await service.removeExamLink(batchId: 'b-tat', scanId: 's-tat', examineeId: 'e1');
      await service.linkScanToExaminee(
        batchId: 'b-tat',
        scan: _localScan(id: 's-tat'),
        examinee: _examinee(id: 'e2', temporaryExamineeId: 'EX-000002'),
        examCode: 'TAT',
      );
      expect(client.lastLinkArgs, {'batchId': 'b-tat', 'scanId': 's-tat', 'examineeId': 'e2'});
      expect(client.scansByExamineeId['e2']!.scans.single.id, 's-tat');
      expect(client.unlinkedScansToReturn.scans, isEmpty);
    });

    test('8. cannot unlink using the wrong examinee id -- nothing changes', () async {
      seedThreeExams();
      await expectLater(
        service.removeExamLink(batchId: 'b-tat', scanId: 's-tat', examineeId: 'e-other'),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
      expect(client.scansByExamineeId['e1']!.scans, hasLength(3));
      expect(client.unlinkedScansToReturn.scans, isEmpty);
    });

    test('an already-unlinked scan is reported as a failure, not success', () async {
      client.unlinkedScansToReturn = CloudScansRead.found([_scanRow(id: 's-x', batchId: 'b-x', examCode: 'TAT')]);
      await expectLater(
        service.removeExamLink(batchId: 'b-x', scanId: 's-x', examineeId: 'e1'),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
    });

    test('the same scan id in a different batch is not touched (batch is part of the key)', () async {
      seedThreeExams();
      await expectLater(
        service.removeExamLink(batchId: 'b-OTHER', scanId: 's-tat', examineeId: 'e1'),
        throwsA(isA<GuidanceWebExamineeRecordsException>()),
      );
      expect(client.scansByExamineeId['e1']!.scans.map((s) => s.id), contains('s-tat'));
    });

    test('a failed unlink throws a sanitized message and changes nothing', () async {
      seedThreeExams();
      client.unlinkResultOverride = const SyncOutcome.permanent('42501');
      Object? error;
      try {
        await service.removeExamLink(batchId: 'b-tat', scanId: 's-tat', examineeId: 'e1');
      } catch (e) {
        error = e;
      }
      expect(error, isA<GuidanceWebExamineeRecordsException>());
      expect((error as GuidanceWebExamineeRecordsException).message, isNot(contains('42501')));
      expect(client.scansByExamineeId['e1']!.scans, hasLength(3));
    });

    test('a transient failure reports a connection message', () async {
      seedThreeExams();
      client.unlinkResultOverride = const SyncOutcome.transient('network');
      await expectLater(
        service.removeExamLink(batchId: 'b-tat', scanId: 's-tat', examineeId: 'e1'),
        throwsA(isA<GuidanceWebExamineeRecordsException>()
            .having((e) => e.message, 'message', contains('Could not reach Supabase'))),
      );
    });
  });

  group('updateExamineeProfile (name-only correction)', () {
    test('never changes the Temporary Examinee ID', () async {
      final existing = _examinee();
      final updated = await service.updateExamineeProfile(
        existing,
        firstName: 'Juanito',
        lastName: 'Dela Cruz',
      );
      expect(updated.temporaryExamineeId, 'EX-1');
      expect(updated.firstName, 'Juanito');
      expect(client.lastUpdateId, 'e1');
    });
  });

  group('11/12. archive / restore', () {
    test('archiveExaminee flips status to archived via setExamineeArchived(true)', () async {
      final archived = await service.archiveExaminee(_examinee());
      expect(archived.isArchived, isTrue);
      expect(client.calls, contains('setExamineeArchived:e1/true'));
    });

    test('restoreExaminee flips status back via setExamineeArchived(false)', () async {
      final restored = await service.restoreExaminee(_examinee(status: 'archived'));
      expect(restored.isActive, isTrue);
      expect(client.calls, contains('setExamineeArchived:e1/false'));
    });
  });

  test('never calls a push/upload/delete method for any Examinee Records operation', () async {
    client.examineesToReturn = CloudExamineesRead.found([_examineeRow()]);
    await service.loadExaminees();
    await service.loadUnlinkedScans();
    await service.createExamineeFromScan(
      batchId: 'b1',
      scan: _localScan(id: 's1'),
      firstName: 'Juan',
      lastName: 'Dela Cruz',
    );
    await service.updateExamineeProfile(_examinee(), firstName: 'Juan', lastName: 'Dela Cruz');
    await service.archiveExaminee(_examinee());
    await service.linkScanToExaminee(
      batchId: 'b1',
      scan: _localScan(id: 's2'),
      examinee: _examinee(),
      examCode: 'AT',
    );

    for (final call in client.calls) {
      expect(call, isNot(startsWith('push')));
      expect(call, isNot(startsWith('upload')));
      expect(call, isNot(startsWith('delete')));
    }
  });
}
