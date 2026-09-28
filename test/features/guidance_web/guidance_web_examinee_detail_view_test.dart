import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/retake_client.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_examinee_detail_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_examinee_records_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/examinee_record.dart';

class _FakeSyncClient implements SyncClient, RetakeClient {
  final Map<String, List<CloudRetakeRequestRow>> retakeRequestsByKey = {};
  SyncOutcome createRetakeResult = const SyncOutcome.success();
  SyncOutcome reviewRetakeResult = const SyncOutcome.success();
  SyncOutcome archiveRetakeResult = const SyncOutcome.success();
  final List<Map<String, Object?>> retakeCalls = [];

  String _retakeKey(String examineeId, String examCode) => '$examineeId/$examCode';

  @override
  Future<CloudRetakeRequestsRead> readRetakeRequests({
    required String examineeId,
    required String examCode,
  }) async {
    calls.add('readRetakeRequests:${_retakeKey(examineeId, examCode)}');
    return CloudRetakeRequestsRead.found(
      retakeRequestsByKey[_retakeKey(examineeId, examCode)] ?? const [],
    );
  }

  @override
  Future<SyncOutcome> createRetakeRequest({
    required String examineeId,
    required String examCode,
    required String reason,
  }) async {
    calls.add('createRetakeRequest:${_retakeKey(examineeId, examCode)}');
    retakeCalls.add({'op': 'create', 'examineeId': examineeId, 'examCode': examCode, 'reason': reason});
    return createRetakeResult;
  }

  @override
  Future<SyncOutcome> reviewRetakeRequest({
    required String requestId,
    required bool approve,
    String? reviewNote,
  }) async {
    calls.add('reviewRetakeRequest:$requestId/$approve');
    retakeCalls.add({'op': 'review', 'requestId': requestId, 'approve': approve, 'reviewNote': reviewNote});
    return reviewRetakeResult;
  }

  @override
  Future<SyncOutcome> archiveRetakeAttempt({
    required String requestId,
    required String archiveReason,
  }) async {
    calls.add('archiveRetakeAttempt:$requestId');
    retakeCalls.add({'op': 'archive', 'requestId': requestId, 'archiveReason': archiveReason});
    return archiveRetakeResult;
  }
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByExamineeId = {};
  CloudScansRead unlinkedScansToReturn = CloudScansRead.found(const []);
  CloudExamineeWrite updateResultToReturn = const CloudExamineeWrite.failed(SyncOutcome.permanent('unset'));
  SyncOutcome linkResultToReturn = const SyncOutcome.success();
  final List<String> calls = [];
  Map<String, String?>? lastLinkArgs;

  /// What the database currently holds for the examinee the page shows (the
  /// link service re-reads it to confirm the examinee is still active).
  CloudExamineesRead examineesToReturn = CloudExamineesRead.found([
    CloudExamineeRow(
      id: 'e1',
      temporaryExamineeId: 'EX-00025',
      firstName: 'Juan',
      lastName: 'Dela Cruz',
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid1',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid1',
    ),
  ]);

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
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) async {
    calls.add('downloadNameCropImage:$batchId/$scanId/$variant');
    return const CloudImageRead.absent();
  }

  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no('deleteScan');
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
  String? firstName = 'Juan',
  String? lastName = 'Dela Cruz',
  String? examineeNumber = 'EX-1',
  int attemptNo = 1,
  String attemptStatus = 'active',
  String? archiveReason,
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
      firstName: firstName,
      lastName: lastName,
      examineeNumber: examineeNumber,
      attemptNo: attemptNo,
      attemptStatus: attemptStatus,
      archiveReason: archiveReason,
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

CloudRetakeRequestRow _retakeRequest({
  String id = 'r1',
  String examineeId = 'e1',
  String examCode = 'AT',
  String reason = 'Medical emergency',
  String status = 'PENDING',
  DateTime? eligibleOn,
}) =>
    CloudRetakeRequestRow(
      id: id,
      examineeId: examineeId,
      examCode: examCode,
      reason: reason,
      status: status,
      requestedAt: DateTime.utc(2026, 1, 2),
      eligibleOn: eligibleOn,
      createdAt: DateTime.utc(2026, 1, 2),
      updatedAt: DateTime.utc(2026, 1, 2),
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

  testWidgets(
      "opening a linked exam shows the canonical applicant (not the scan's blank tag) and keeps the scan number as Scan ID",
      (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-qtm', examCode: 'QTM')]);
    // The verified data shape: scan-level names NULL, generated scan number.
    client.scansByExamineeId['e1'] = CloudScansRead.found([
      _scanRow(
        id: 's1',
        batchId: 'b-qtm',
        examCode: 'QTM',
        firstName: null,
        lastName: null,
        examineeNumber: 'EX-1790006562335-3',
      ),
    ]);
    await pumpDetail(
      tester,
      examinee: ExamineeRecord(
        id: 'e1',
        temporaryExamineeId: 'EX-000004',
        firstName: 'Merch',
        middleName: 'Valdez',
        lastName: 'Andulana',
        status: 'active',
        createdAt: DateTime.utc(2026, 1, 1),
        createdByUid: 'uid1',
        updatedAt: DateTime.utc(2026, 1, 1),
        updatedByUid: 'uid1',
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'View'));
    await tester.pumpAndSettle();

    expect(find.text('Detailed Result'), findsOneWidget);
    expect(find.text('EX-000004'), findsOneWidget);
    expect(find.text('Merch'), findsOneWidget);
    expect(find.text('Valdez'), findsOneWidget);
    expect(find.text('Andulana'), findsOneWidget);
    expect(find.text('Scan ID'), findsOneWidget);
    expect(find.text('EX-1790006562335-3'), findsOneWidget);
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

  group('Archived examinee cannot Attach a Scan', () {
    Finder attachButton() => find.byKey(const Key('attachScanButton'));
    const hint = 'Archived examinees cannot be linked to new scans. Restore the examinee first.';

    testWidgets('an active examinee keeps a working Attach a Scan and shows no hint', (tester) async {
      await pumpDetail(tester);
      expect(tester.widget<TextButton>(attachButton()).onPressed, isNotNull);
      expect(find.text(hint), findsNothing);
    });

    testWidgets('an archived examinee: Attach is disabled, the reason is shown, nothing is opened or linked',
        (tester) async {
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's-tat', batchId: 'b-tat', examCode: 'TAT'),
      ]);
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-tat', examCode: 'TAT')]);
      await pumpDetail(tester, examinee: _examinee(status: 'archived'));

      expect(tester.widget<TextButton>(attachButton()).onPressed, isNull);
      expect(find.byKey(const Key('archivedAttachHint')), findsOneWidget);
      expect(find.text(hint), findsOneWidget);

      await tester.tap(attachButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Attach a Scan to Dela Cruz, Juan'), findsNothing);
      expect(client.calls, isNot(contains('readUnlinkedScans')));
      expect(client.calls.where((c) => c.startsWith('linkScanToExaminee')), isEmpty);
    });

    testWidgets('an archived examinee is still viewable: existing exams and Restore remain available',
        (tester) async {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-qtm', examCode: 'QTM')]);
      client.scansByExamineeId['e1'] = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b-qtm', examCode: 'QTM'),
      ]);
      await pumpDetail(tester, examinee: _examinee(status: 'archived'));

      expect(find.text('Archived'), findsWidgets);
      expect(find.text('QTM'), findsWidgets);
      expect(find.widgetWithText(TextButton, 'Restore'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Remove Link'), findsOneWidget);
    });

    testWidgets('Restore re-enables Attach a Scan and removes the hint', (tester) async {
      client.updateResultToReturn = CloudExamineeWrite.success(CloudExamineeRow(
        id: 'e1',
        temporaryExamineeId: 'EX-00025',
        firstName: 'Juan',
        lastName: 'Dela Cruz',
        status: 'active',
        createdAt: DateTime.utc(2026, 1, 1),
        createdByUid: 'uid1',
        updatedAt: DateTime.utc(2026, 3, 1),
        updatedByUid: 'uid2',
      ));
      await pumpDetail(tester, examinee: _examinee(status: 'archived'));
      expect(tester.widget<TextButton>(attachButton()).onPressed, isNull);

      await tester.tap(find.widgetWithText(TextButton, 'Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(client.calls, contains('setExamineeArchived:e1/false'));
      expect(tester.widget<TextButton>(attachButton()).onPressed, isNotNull);
      expect(find.text(hint), findsNothing);
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

group('Applicant Retake Management', () {
  testWidgets('QTM never offers Request Retake', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-qtm', examCode: 'QTM')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-qtm', batchId: 'b-qtm', examCode: 'QTM')]);
    await pumpDetail(tester);

    expect(find.byKey(const Key('requestRetake_s-qtm')), findsNothing);
  });

  testWidgets('AT Attempt 1 (active, graded, no request) offers Request Retake', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    await pumpDetail(tester);

    expect(find.byKey(const Key('requestRetake_s-at')), findsOneWidget);
    expect(find.textContaining('Attempt 1'), findsOneWidget);
  });

  testWidgets('a blank reason is rejected before a request is submitted', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    await pumpDetail(tester);

    await tester.tap(find.byKey(const Key('requestRetake_s-at')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit Request'));
    await tester.pumpAndSettle();

    expect(find.text('A reason is required'), findsOneWidget);
    expect(client.calls.where((c) => c.startsWith('createRetakeRequest')), isEmpty);
  });

  testWidgets('a valid reason submits the request via createRetakeRequest', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    await pumpDetail(tester);

    await tester.tap(find.byKey(const Key('requestRetake_s-at')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('retakeReasonField')), 'Family emergency during the exam');
    await tester.tap(find.widgetWithText(FilledButton, 'Submit Request'));
    await tester.pumpAndSettle();

    expect(client.retakeCalls.single['op'], 'create');
    expect(client.retakeCalls.single['reason'], 'Family emergency during the exam');
    expect(client.retakeCalls.single['examCode'], 'AT');
  });

  testWidgets('a pending request shows the review banner with Approve and Reject', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    client.retakeRequestsByKey['e1/AT'] = [_retakeRequest(status: 'PENDING')];
    await pumpDetail(tester);

    expect(find.text('A retake request must be reviewed and approved.'), findsOneWidget);
    expect(find.byKey(const Key('approveRetake_r1')), findsOneWidget);
    expect(find.byKey(const Key('rejectRetake_r1')), findsOneWidget);
    expect(find.byKey(const Key('requestRetake_s-at')), findsNothing);
  });

  testWidgets('Approve calls reviewRetakeRequest with approve: true', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    client.retakeRequestsByKey['e1/AT'] = [_retakeRequest(status: 'PENDING')];
    await pumpDetail(tester);

    await tester.tap(find.byKey(const Key('approveRetake_r1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(client.retakeCalls.single['op'], 'review');
    expect(client.retakeCalls.single['requestId'], 'r1');
    expect(client.retakeCalls.single['approve'], true);
  });

  testWidgets('a rejected request offers Request Retake again (the retake is not consumed)', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    client.retakeRequestsByKey['e1/AT'] = [_retakeRequest(status: 'REJECTED')];
    await pumpDetail(tester);

    expect(find.byKey(const Key('requestRetake_s-at')), findsOneWidget);
    expect(find.byKey(const Key('approveRetake_r1')), findsNothing);
  });

  testWidgets('an approved request not yet eligible shows the earliest eligible date and Archive Attempt', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    client.retakeRequestsByKey['e1/AT'] = [
      _retakeRequest(status: 'APPROVED', eligibleOn: DateTime.utc(2027, 3, 25)),
    ];
    await pumpDetail(tester);

    expect(find.textContaining('not yet eligible'), findsOneWidget);
    expect(find.textContaining('Mar 25, 2027'), findsOneWidget);
    expect(find.byKey(const Key('archiveAttempt_r1')), findsOneWidget);
  });

  testWidgets('Archive Attempt requires a reason and calls archiveRetakeAttempt', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] =
        CloudScansRead.found([_scanRow(id: 's-at', batchId: 'b-at', examCode: 'AT')]);
    client.retakeRequestsByKey['e1/AT'] = [
      _retakeRequest(status: 'APPROVED', eligibleOn: DateTime.utc(2027, 3, 25)),
    ];
    await pumpDetail(tester);

    await tester.tap(find.byKey(const Key('archiveAttempt_r1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Archive Attempt'));
    await tester.pumpAndSettle();
    expect(find.text('A reason is required'), findsOneWidget);
    expect(client.retakeCalls, isEmpty);

    await tester.enterText(find.byKey(const Key('archiveAttemptReasonField')), 'Approved retake, archiving the first attempt');
    await tester.tap(find.widgetWithText(FilledButton, 'Archive Attempt'));
    await tester.pumpAndSettle();

    expect(client.retakeCalls.single['op'], 'archive');
    expect(client.retakeCalls.single['requestId'], 'r1');
  });

  testWidgets('an archived attempt shows its badge and reason, and hides Remove Link', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b-at', examCode: 'AT')]);
    client.scansByExamineeId['e1'] = CloudScansRead.found([
      _scanRow(
        id: 's-at1',
        batchId: 'b-at',
        examCode: 'AT',
        attemptNo: 1,
        attemptStatus: 'archived',
        archiveReason: 'Approved retake -- previous attempt archived',
      ),
    ]);
    await pumpDetail(tester);

    expect(find.textContaining('Attempt 1'), findsOneWidget);
    expect(find.textContaining('Archived'), findsWidgets);
    expect(find.textContaining('Approved retake -- previous attempt archived'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Remove Link'), findsNothing);
  });

  testWidgets('Attempt 1 (archived) and Attempt 2 (active) both appear, and Attempt 2 shows the max-attempts notice', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([
      _batchRow(id: 'b-at1', examCode: 'AT'),
      _batchRow(id: 'b-at2', examCode: 'AT'),
    ]);
    client.scansByExamineeId['e1'] = CloudScansRead.found([
      _scanRow(
        id: 's-at1',
        batchId: 'b-at1',
        examCode: 'AT',
        attemptNo: 1,
        attemptStatus: 'archived',
        archiveReason: 'Approved retake',
      ),
      _scanRow(id: 's-at2', batchId: 'b-at2', examCode: 'AT', attemptNo: 2, attemptStatus: 'active'),
    ]);
    await pumpDetail(tester);

    expect(find.byKey(const Key('maxAttemptsNotice_s-at2')), findsOneWidget);
    expect(find.text('Maximum number of AT attempts has been reached.'), findsOneWidget);
    expect(find.byKey(const Key('requestRetake_s-at2')), findsNothing);
    // Both attempts are visible -- the same examinee, same examCode.
    expect(find.textContaining('Attempt 1'), findsOneWidget);
    expect(find.textContaining('Attempt 2'), findsOneWidget);
  });
});

}
