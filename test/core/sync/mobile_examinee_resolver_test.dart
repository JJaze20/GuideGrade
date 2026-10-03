import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/mobile_examinee_resolver.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';

/// Minimal fake [SyncClient] -- only `readCloudScans`/`readCloudExaminees`
/// are ever exercised by [resolveLinkedExaminees]; every other method
/// throws if called, so a test fails loudly if the resolver ever starts
/// writing or reading anything else.
class _FakeSyncClient implements SyncClient {
  Map<String, CloudScansRead> scansByBatchId = {};
  CloudExamineesRead examineesToReturn = CloudExamineesRead.found(const []);

  Never _no(String label) => throw StateError('must never call $label');

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async =>
      scansByBatchId[batchId] ?? CloudScansRead.found(const []);

  @override
  Future<CloudExamineesRead> readCloudExaminees() async => examineesToReturn;

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
  Future<CloudBatchArchivesRead> readBatchArchives() => _no('readBatchArchives');
  @override
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason}) => _no('archiveBatch');
  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) => _no('readScanCounts');
  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) => _no('readCloudScansForExaminee');
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no('readUnlinkedScans');
}

CloudScanRow _scan(String id, {String? examineeId}) => CloudScanRow(
      id: id,
      batchId: 'b1',
      examCode: 'AT',
      capturedAt: DateTime.utc(2026, 9, 1),
      decoded: const {},
      examineeId: examineeId,
    );

CloudExamineeRow _examinee(
  String id, {
  required String temporaryExamineeId,
  String firstName = 'Juan',
  String lastName = 'Dela Cruz',
}) =>
    CloudExamineeRow(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      firstName: firstName,
      lastName: lastName,
      status: 'active',
      createdAt: DateTime.utc(2026, 9, 1),
      createdByUid: 'u1',
      updatedAt: DateTime.utc(2026, 9, 1),
      updatedByUid: 'u1',
    );

void main() {
  group('resolveLinkedExaminees', () {
    test('1. a linked scan resolves canonical name + temporary Examinee ID', () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': CloudScansRead.found([_scan('s1', examineeId: 'ex-A')])}
        ..examineesToReturn =
            CloudExamineesRead.found([_examinee('ex-A', temporaryExamineeId: 'EX-000123')]);

      final resolved = await resolveLinkedExaminees(client, 'b1');

      expect(resolved['s1']?.temporaryExamineeId, 'EX-000123');
      expect(resolved['s1']?.displayName, 'Dela Cruz, Juan');
    });

    test('2. an unlinked scan (examinee_id null) has no entry', () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': CloudScansRead.found([_scan('s1')])}
        ..examineesToReturn = CloudExamineesRead.found(const []);

      final resolved = await resolveLinkedExaminees(client, 'b1');

      expect(resolved, isEmpty);
    });

    test('3. a readCloudScans failure returns an empty map, never throws', () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': const CloudScansRead.failed(SyncOutcome.transient('network'))};

      final resolved = await resolveLinkedExaminees(client, 'b1');

      expect(resolved, isEmpty);
    });

    test('3b. a readCloudExaminees failure (e.g. RLS denial) returns an empty map, never throws',
        () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': CloudScansRead.found([_scan('s1', examineeId: 'ex-A')])}
        ..examineesToReturn = const CloudExamineesRead.failed(SyncOutcome.permanent('42501'));

      final resolved = await resolveLinkedExaminees(client, 'b1');

      expect(resolved, isEmpty);
    });

    test('4. a dangling examinee_id (no matching examinees row) has no entry', () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': CloudScansRead.found([_scan('s1', examineeId: 'ex-GONE')])}
        ..examineesToReturn = CloudExamineesRead.found(const []);

      final resolved = await resolveLinkedExaminees(client, 'b1');

      expect(resolved, isEmpty);
    });

    test(
      '5. different batches/exam types linked to the same Examinee resolve to the same '
      'temporary Examinee ID',
      () async {
        final examinees = CloudExamineesRead.found([_examinee('ex-A', temporaryExamineeId: 'EX-000123')]);

        final qtmClient = _FakeSyncClient()
          ..scansByBatchId = {'QTM-001': CloudScansRead.found([_scan('qtm-s1', examineeId: 'ex-A')])}
          ..examineesToReturn = examinees;
        final tatClient = _FakeSyncClient()
          ..scansByBatchId = {'TAT-001': CloudScansRead.found([_scan('tat-s1', examineeId: 'ex-A')])}
          ..examineesToReturn = examinees;
        final atClient = _FakeSyncClient()
          ..scansByBatchId = {'AT-001': CloudScansRead.found([_scan('at-s1', examineeId: 'ex-A')])}
          ..examineesToReturn = examinees;

        final qtm = await resolveLinkedExaminees(qtmClient, 'QTM-001');
        final tat = await resolveLinkedExaminees(tatClient, 'TAT-001');
        final at = await resolveLinkedExaminees(atClient, 'AT-001');

        expect(qtm['qtm-s1']?.temporaryExamineeId, 'EX-000123');
        expect(tat['tat-s1']?.temporaryExamineeId, 'EX-000123');
        expect(at['at-s1']?.temporaryExamineeId, 'EX-000123');
      },
    );

    test('6. relinking to a different Examinee changes the resolved identity (no stale caching)',
        () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': CloudScansRead.found([_scan('s1', examineeId: 'ex-A')])}
        ..examineesToReturn = CloudExamineesRead.found([
          _examinee('ex-A', temporaryExamineeId: 'EX-000111', firstName: 'Ana'),
          _examinee('ex-B', temporaryExamineeId: 'EX-000222', firstName: 'Ben'),
        ]);

      final before = await resolveLinkedExaminees(client, 'b1');
      expect(before['s1']?.temporaryExamineeId, 'EX-000111');

      // Relink on the "server": the scan now points at Examinee B.
      client.scansByBatchId = {'b1': CloudScansRead.found([_scan('s1', examineeId: 'ex-B')])};

      final after = await resolveLinkedExaminees(client, 'b1');
      expect(after['s1']?.temporaryExamineeId, 'EX-000222');
      expect(after['s1']?.firstName, 'Ben');
    });

    test('7. removing the link makes the canonical identity disappear', () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': CloudScansRead.found([_scan('s1', examineeId: 'ex-A')])}
        ..examineesToReturn =
            CloudExamineesRead.found([_examinee('ex-A', temporaryExamineeId: 'EX-000123')]);

      final before = await resolveLinkedExaminees(client, 'b1');
      expect(before['s1']?.temporaryExamineeId, 'EX-000123');

      // Remove Link on the "server": examinee_id goes back to null.
      client.scansByBatchId = {'b1': CloudScansRead.found([_scan('s1')])};

      final after = await resolveLinkedExaminees(client, 'b1');
      expect(after, isEmpty);
    });

    test('8. a canonical name edit on the Examinee record is reflected on the next resolve',
        () async {
      final client = _FakeSyncClient()
        ..scansByBatchId = {'b1': CloudScansRead.found([_scan('s1', examineeId: 'ex-A')])}
        ..examineesToReturn = CloudExamineesRead.found(
          [_examinee('ex-A', temporaryExamineeId: 'EX-000123', firstName: 'Juan', lastName: 'Dela Cruz')],
        );

      final before = await resolveLinkedExaminees(client, 'b1');
      expect(before['s1']?.displayName, 'Dela Cruz, Juan');

      // Name corrected via Examinee Records on the "server" -- the ID never
      // changes.
      client.examineesToReturn = CloudExamineesRead.found(
        [_examinee('ex-A', temporaryExamineeId: 'EX-000123', firstName: 'Juan Carlos', lastName: 'Dela Cruz')],
      );

      final after = await resolveLinkedExaminees(client, 'b1');
      expect(after['s1']?.displayName, 'Dela Cruz, Juan Carlos');
      expect(after['s1']?.temporaryExamineeId, 'EX-000123');
    });
  });
}
