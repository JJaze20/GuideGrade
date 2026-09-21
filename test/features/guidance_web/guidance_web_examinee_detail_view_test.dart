import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_examinee_detail_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_examinee_records_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/examinee_record.dart';

class _FakeSyncClient implements SyncClient {
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByExamineeId = {};
  CloudScansRead unlinkedScansToReturn = CloudScansRead.found(const []);
  CloudExamineeWrite updateResultToReturn = const CloudExamineeWrite.failed(SyncOutcome.permanent('unset'));
  SyncOutcome linkResultToReturn = const SyncOutcome.success();
  final List<String> calls = [];
  Map<String, String?>? lastLinkArgs;

  Never _no(String label) {
    calls.add(label);
    throw StateError('must never call $label');
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
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    calls.add('updateCloudExaminee:$id');
    return updateResultToReturn;
  }

  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) async {
    calls.add('setExamineeArchived:$id/$archived');
    return updateResultToReturn;
  }

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
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) async {
    calls.add('linkScanToExaminee:$batchId/$scanId/$examineeId');
    lastLinkArgs = {'batchId': batchId, 'scanId': scanId, 'examineeId': examineeId};
    return linkResultToReturn;
  }

  /// When set, [unlinkScanFromExaminee] returns it verbatim (and changes nothing).
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
    // Simulates the guarded UPDATE: the scan moves to the unlinked queue,
    // never deleted; no match is a conflict.
    final linked = scansByExamineeId[examineeId];
    final match = (linked == null)
        ? <CloudScanRow>[]
        : linked.scans.where((s) => s.batchId == batchId && s.id == scanId).toList();
    if (match.isEmpty) return const SyncOutcome.conflict('scan_not_linked_to_examinee');
    scansByExamineeId[examineeId] =
        CloudScansRead.found(linked!.scans.where((s) => s != match.first).toList());
    unlinkedScansToReturn =
        CloudScansRead.found([...unlinkedScansToReturn.scans, match.first]);
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
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    calls.add('readAnswerKey:$examCode');
    return const CloudAnswerKeyRead.absent();
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) => _no('readCloudScans');

  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) async {
    calls.add('downloadScanImage:$batchId/$scanId/$rectified');
    return const CloudImageRead.absent();
  }
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
}

CloudBatchRow _batchRow({String id = 'b-qtm', String examCode = 'QTM'}) => CloudBatchRow(
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
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: 50,
      totalGraded: 72,
      totalItems: 72,
      resultStatus: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'uid',
      processedByName: 'Officer',
      firstName: 'Juan',
      lastName: 'Dela Cruz',
      examineeNumber: 'EX-1',
    );

ExamineeRecord _examinee({String status = 'active'}) => ExamineeRecord(
      id: 'e1',
      temporaryExamineeId: 'EX-00025',
      firstName: 'Juan',
      lastName: 'Dela Cruz',
      status: status,
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid1',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid1',
    );

void main() {
  late _FakeSyncClient client;

  setUp(() {
    client = _FakeSyncClient();
  });

  int linksChangedCount = 0;

  Future<void> pumpDetail(WidgetTester tester, {ExamineeRecord? examinee}) async {
    linksChangedCount = 0;
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuidanceWebExamineeDetailView(
            examinee: examinee ?? _examinee(),
            service: GuidanceWebExamineeRecordsService(client: client),
            resultsService: GuidanceWebResultsService(client: client),
            onBack: () {},
            onExamineeUpdated: (_) {},
            onLinksChanged: () => linksChangedCount++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the stored record information verbatim -- name, Temporary ID, and status only', (tester) async {
    await pumpDetail(tester);

    expect(find.text('Dela Cruz, Juan'), findsOneWidget);
    expect(find.text('EX-00025'), findsOneWidget);
    expect(find.text('Active'), findsWidgets);
  });

  group('5. No Official Student ID / Birth Date / Last Attended School', () {
    testWidgets('none of them appear anywhere on the detail page', (tester) async {
      await pumpDetail(tester);
      expect(find.textContaining('Official Student'), findsNothing);
      expect(find.textContaining('Birth Date'), findsNothing);
      expect(find.textContaining('Last Attended School'), findsNothing);
    });
  });

  testWidgets('Tests Taken reflects the distinct exam codes in history', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-qtm', examCode: 'QTM')]);
    client.scansByExamineeId['e1'] = CloudScansRead.found([
      _scanRow(id: 's1', batchId: 'b-qtm', examCode: 'QTM'),
    ]);
    await pumpDetail(tester);

    expect(find.byIcon(Icons.check_circle), findsOneWidget); // only QTM taken
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2)); // TAT, AT not taken
  });

  testWidgets(
      '10/20. History lists each exam and opening one reuses the existing Result Detail view for that exact scan',
      (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-qtm', examCode: 'QTM')]);
    client.scansByExamineeId['e1'] = CloudScansRead.found([
      _scanRow(id: 's1', batchId: 'b-qtm', examCode: 'QTM'),
    ]);
    await pumpDetail(tester);

    expect(find.text('QTM'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'View'));
    await tester.pumpAndSettle();

    expect(find.text('Detailed Result'), findsOneWidget);
  });

  testWidgets('9/10. Editing saves canonical fields but the Temporary Examinee ID never changes', (tester) async {
    client.updateResultToReturn = CloudExamineeWrite.success(CloudExamineeRow(
      id: 'e1',
      temporaryExamineeId: 'EX-00025',
      firstName: 'Juanito',
      lastName: 'Dela Cruz',
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid1',
      updatedAt: DateTime.utc(2026, 2, 1),
      updatedByUid: 'uid2',
    ));
    await pumpDetail(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    // The Temporary Examinee ID is shown, explicitly marked not editable,
    // inside the edit dialog itself -- and there is no field to change it.
    expect(find.textContaining('not editable'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Juanito');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Dela Cruz, Juanito'), findsOneWidget);
    expect(find.text('EX-00025'), findsOneWidget);
  });

  testWidgets('13. Archiving from the detail page does not touch examination history', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-qtm', examCode: 'QTM')]);
    client.scansByExamineeId['e1'] = CloudScansRead.found([
      _scanRow(id: 's1', batchId: 'b-qtm', examCode: 'QTM'),
    ]);
    client.updateResultToReturn = CloudExamineeWrite.success(CloudExamineeRow(
      id: 'e1',
      temporaryExamineeId: 'EX-00025',
      firstName: 'Juan',
      lastName: 'Dela Cruz',
      status: 'archived',
      archivedAt: DateTime.utc(2026, 2, 1),
      archivedByUid: 'uid2',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid1',
      updatedAt: DateTime.utc(2026, 2, 1),
      updatedByUid: 'uid2',
    ));
    await pumpDetail(tester);
    expect(find.text('QTM'), findsWidgets);

    await tester.tap(find.widgetWithText(TextButton, 'Archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
    await tester.pumpAndSettle();

    expect(client.calls, contains('setExamineeArchived:e1/true'));
    // History is still shown -- archiving never deleted or hid it.
    expect(find.text('QTM'), findsWidgets);
  });

  group('Remove Link', () {
    void seedThreeExams() {
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(id: 'b-qtm', examCode: 'QTM'),
        _batchRow(id: 'b-tat', examCode: 'TAT'),
        _batchRow(id: 'b-at', examCode: 'AT'),
      ]);
      client.scansByExamineeId['e1'] = CloudScansRead.found([
        _scanRow(id: 's-qtm', batchId: 'b-qtm', examCode: 'QTM'),
        _scanRow(id: 's-tat', batchId: 'b-tat', examCode: 'TAT'),
        _scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT'),
      ]);
    }

    Finder removeButtonFor(String batchCode) => find.descendant(
          of: find.ancestor(of: find.text(batchCode), matching: find.byType(Row)).first,
          matching: find.widgetWithText(TextButton, 'Remove Link'),
        );

    testWidgets('every linked exam has a "Remove Link" button (never "Delete")', (tester) async {
      seedThreeExams();
      await pumpDetail(tester);
      expect(find.widgetWithText(TextButton, 'Remove Link'), findsNWidgets(3));
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('clicking Remove Link asks for confirmation naming the Test Type and does NOT unlink yet',
        (tester) async {
      seedThreeExams();
      await pumpDetail(tester);

      await tester.tap(removeButtonFor('B-TAT'));
      await tester.pumpAndSettle();

      expect(find.text('Remove TAT Link?'), findsOneWidget);
      expect(find.textContaining("remove the TAT examination from this examinee's records"), findsOneWidget);
      expect(find.textContaining('will not be deleted'), findsOneWidget);
      expect(client.calls, isNot(contains(startsWith('unlinkScanFromExaminee'))));
    });

    testWidgets('Cancel leaves everything untouched', (tester) async {
      seedThreeExams();
      await pumpDetail(tester);
      await tester.tap(removeButtonFor('B-TAT'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(client.calls, isNot(contains(startsWith('unlinkScanFromExaminee'))));
      expect(find.text('B-TAT'), findsOneWidget);
    });

    testWidgets('confirming unlinks exactly that batch+scan+examinee, refreshes, and keeps the other exams',
        (tester) async {
      seedThreeExams();
      await pumpDetail(tester);

      await tester.tap(removeButtonFor('B-TAT'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove Link'));
      await tester.pumpAndSettle();

      expect(client.lastUnlinkArgs, {'batchId': 'b-tat', 'scanId': 's-tat', 'examineeId': 'e1'});
      // Dialog closed; TAT gone; QTM + AT unchanged.
      expect(find.text('Remove TAT Link?'), findsNothing);
      expect(find.text('B-TAT'), findsNothing);
      expect(find.text('B-QTM'), findsOneWidget);
      expect(find.text('B-AT'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Remove Link'), findsNWidgets(2));
      // The detail re-read its history, and the caller was told to refresh
      // its Unlinked Scans queue.
      expect(client.calls.where((c) => c == 'readCloudScansForExaminee:e1').length, 2);
      expect(linksChangedCount, 1);
      // The scan still exists -- now in the unlinked queue -- and was never deleted.
      expect(client.unlinkedScansToReturn.scans.map((s) => s.id), ['s-tat']);
      expect(client.calls, isNot(contains(startsWith('delete'))));
      expect(client.calls, isNot(contains(startsWith('linkScanToExaminee'))));
    });

    testWidgets('a failed unlink does not report success and the exam stays listed', (tester) async {
      seedThreeExams();
      client.unlinkResultOverride = const SyncOutcome.permanent('42501');
      await pumpDetail(tester);

      await tester.tap(removeButtonFor('B-TAT'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove Link'));
      await tester.pumpAndSettle();

      expect(find.textContaining('link removed'), findsNothing);
      expect(find.textContaining('Could not remove this link'), findsOneWidget);
      expect(find.textContaining('42501'), findsNothing);
      expect(find.text('B-TAT'), findsOneWidget);
      expect(client.unlinkedScansToReturn.scans, isEmpty);
    });

    testWidgets('a conflict (scan no longer linked to this examinee) is not reported as success',
        (tester) async {
      seedThreeExams();
      client.unlinkResultOverride = const SyncOutcome.conflict('scan_not_linked_to_examinee');
      await pumpDetail(tester);

      await tester.tap(removeButtonFor('B-TAT'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove Link'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no longer linked'), findsOneWidget);
      expect(find.textContaining('link removed'), findsNothing);
    });
  });

  group('4. Attach a Scan (Workflow 4 -- reuses the same linking service as Link to Existing Examinee)', () {
    testWidgets('browses unlinked scans and links only after an explicit confirmation', (tester) async {
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's-tat', batchId: 'b-tat', examCode: 'TAT'),
      ]);
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-tat', examCode: 'TAT')]);
      await pumpDetail(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Attach a Scan'));
      await tester.pumpAndSettle();

      expect(client.calls, contains('readUnlinkedScans'));
      // Nothing linked just by opening the dialog.
      expect(client.calls, isNot(contains(startsWith('linkScanToExaminee'))));

      await tester.tap(find.widgetWithText(ListTile, 'Dela Cruz, Juan').first);
      await tester.pumpAndSettle();

      // The confirmation names both sides explicitly.
      expect(find.textContaining('EX-00025'), findsWidgets);
      expect(find.textContaining('B-TAT'), findsWidgets);

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Attach'));
      await tester.pumpAndSettle();

      expect(client.lastLinkArgs, {'batchId': 'b-tat', 'scanId': 's-tat', 'examineeId': 'e1'});
    });
  });
}
