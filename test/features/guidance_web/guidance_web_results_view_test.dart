import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_results_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/local_batch.dart';

/// Phase 3 — the Results table's View button.
///
/// Covers requirement 11: the Detailed Result view opened by View must
/// correspond to the EXACT row clicked, never a different scan in the same
/// batch, and returning from it must never lose the selected batch or
/// trigger a reload.
class _FakeSyncClient implements SyncClient {
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByBatchId = {};
  CloudAnswerKeyRead answerKeyToReturn = const CloudAnswerKeyRead.absent();

  Never _no(String label) => throw StateError('must never call $label');

  @override
  Future<CloudBatchesRead> readCloudBatches() async => batchesToReturn;
  @override
  Future<CloudScansRead> readCloudScans(String batchId) async =>
      scansByBatchId[batchId] ?? CloudScansRead.found(const []);
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async => answerKeyToReturn;
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

CloudBatchRow _batchRow() => CloudBatchRow(
      id: 'b1',
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: '',
      expectedCount: 2,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

CloudScanRow _scanRow({
  required String id,
  required String firstName,
  required String lastName,
  required String number,
  int rawScore = 50,
  // Null reproduces a genuinely un-scored scan: mapCloudScan only builds a
  // LocalScanResult at all when resultStatus is non-null (see
  // cloud_batch_mapper.dart), so this must stay nullable rather than the
  // string 'Ungraded' (which still produces a real, zero-percent result).
  String? resultStatus = 'Graded',
}) =>
    CloudScanRow(
      id: id,
      batchId: 'b1',
      examCode: 'AT',
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: const {'examCode': 'AT', 'items': <dynamic>[]},
      rawScore: resultStatus == null ? null : rawScore,
      totalGraded: resultStatus == null ? null : 72,
      totalItems: resultStatus == null ? null : 72,
      resultStatus: resultStatus,
      scannedAt: resultStatus == null ? null : DateTime.utc(2026, 1, 1),
      processedByUid: resultStatus == null ? null : 'uid',
      processedByName: resultStatus == null ? null : 'Officer',
      firstName: firstName,
      lastName: lastName,
      examineeNumber: number,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSyncClient client;

  setUp(() {
    client = _FakeSyncClient();
    client.batchesToReturn = CloudBatchesRead.found([_batchRow()]);
    client.scansByBatchId['b1'] = CloudScansRead.found([
      _scanRow(id: 's1', firstName: 'Juan', lastName: 'Cruz', number: 'A-1'),
      _scanRow(id: 's2', firstName: 'Maria', lastName: 'Santos', number: 'A-2'),
    ]);
  });

  Future<void> pumpResultsView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GuidanceWebResultsView(service: GuidanceWebResultsService(client: client))),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectTheOnlyBatch(WidgetTester tester) async {
    // The AT dropdown is the first of the three exam-specific dropdowns.
    await tester.tap(find.byType(DropdownButtonFormField<LocalBatch>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('B-1 — Admission Test (Jan 1, 2026)').last);
    await tester.pumpAndSettle();
  }

  testWidgets(
      '11. View opens the Detailed Result for the EXACT row clicked, never a different scan',
      (tester) async {
    await pumpResultsView(tester);
    await selectTheOnlyBatch(tester);

    final viewButtons = find.widgetWithText(TextButton, 'View');
    expect(viewButtons, findsNWidgets(2));

    // Tap the SECOND row's View button (Maria Santos / A-2), not the first.
    await tester.tap(viewButtons.at(1));
    await tester.pumpAndSettle();

    expect(find.text('Detailed Result'), findsOneWidget);
    expect(find.text('A-2'), findsOneWidget);
    expect(find.text('Santos'), findsOneWidget);
    expect(find.text('A-1'), findsNothing);
    expect(find.text('Cruz'), findsNothing);
  });

  testWidgets('7. Back to Results preserves the selected batch and its result list, no reload',
      (tester) async {
    await pumpResultsView(tester);
    await selectTheOnlyBatch(tester);

    await tester.tap(find.widgetWithText(TextButton, 'View').first);
    await tester.pumpAndSettle();
    expect(find.text('Detailed Result'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Back to Results'));
    await tester.pumpAndSettle();

    expect(find.text('Detailed Result'), findsNothing);
    // Both rows are back, and the batch dropdown still shows the selection.
    expect(find.widgetWithText(TextButton, 'View'), findsNWidgets(2));
    expect(find.text('EXAMINEE'), findsOneWidget);
  });

  testWidgets(
      '19. The Results table no longer shows a NUMBER column or examinee numbers',
      (tester) async {
    await pumpResultsView(tester);
    await selectTheOnlyBatch(tester);

    expect(find.text('NUMBER'), findsNothing);
    // The examinee numbers themselves must not appear as table cells
    // while only the table (not the detail view) is showing.
    expect(find.text('A-1'), findsNothing);
    expect(find.text('A-2'), findsNothing);
    // The identity field is still read internally (search still works).
    expect(find.text('EXAMINEE'), findsOneWidget);
    expect(find.text('SCORE'), findsOneWidget);
  });

  group('18. Score sorting', () {
    Future<void> pumpWithScores(WidgetTester tester) async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', firstName: 'Juan', lastName: 'Cruz', number: 'A-1', rawScore: 30),
        _scanRow(id: 's2', firstName: 'Maria', lastName: 'Santos', number: 'A-2', rawScore: 80),
        _scanRow(id: 's3', firstName: 'Pedro', lastName: 'Reyes', number: 'A-3', rawScore: 50),
      ]);
      await pumpResultsView(tester);
      await selectTheOnlyBatch(tester);
    }

    double yOf(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dy;

    testWidgets('ascending = lowest to highest score', (tester) async {
      await pumpWithScores(tester);

      await tester.tap(find.byKey(const Key('scoreSortHeader'))); // -> ascending
      await tester.pumpAndSettle();

      final yCruz = yOf(tester, 'Cruz, Juan'); // 30
      final yReyes = yOf(tester, 'Reyes, Pedro'); // 50
      final ySantos = yOf(tester, 'Santos, Maria'); // 80
      expect(yCruz, lessThan(yReyes));
      expect(yReyes, lessThan(ySantos));
    });

    testWidgets('descending = highest to lowest score', (tester) async {
      await pumpWithScores(tester);

      await tester.tap(find.byKey(const Key('scoreSortHeader'))); // -> ascending
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scoreSortHeader'))); // -> descending
      await tester.pumpAndSettle();

      final yCruz = yOf(tester, 'Cruz, Juan'); // 30
      final yReyes = yOf(tester, 'Reyes, Pedro'); // 50
      final ySantos = yOf(tester, 'Santos, Maria'); // 80
      expect(ySantos, lessThan(yReyes));
      expect(yReyes, lessThan(yCruz));
    });

    testWidgets('a third tap returns to natural (unsorted) order', (tester) async {
      await pumpWithScores(tester);

      final naturalCruzY = yOf(tester, 'Cruz, Juan');
      final naturalSantosY = yOf(tester, 'Santos, Maria');
      expect(naturalCruzY, lessThan(naturalSantosY));

      await tester.tap(find.byKey(const Key('scoreSortHeader')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scoreSortHeader')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scoreSortHeader')));
      await tester.pumpAndSettle();

      expect(yOf(tester, 'Cruz, Juan'), naturalCruzY);
      expect(yOf(tester, 'Santos, Maria'), naturalSantosY);
    });

    testWidgets('ungraded scans always sort last regardless of direction', (tester) async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', firstName: 'Juan', lastName: 'Cruz', number: 'A-1', rawScore: 30),
        _scanRow(id: 's2', firstName: 'Maria', lastName: 'Santos', number: 'A-2', resultStatus: null),
      ]);
      await pumpResultsView(tester);
      await selectTheOnlyBatch(tester);

      await tester.tap(find.byKey(const Key('scoreSortHeader'))); // ascending
      await tester.pumpAndSettle();
      expect(yOf(tester, 'Cruz, Juan'), lessThan(yOf(tester, 'Santos, Maria')));

      await tester.tap(find.byKey(const Key('scoreSortHeader'))); // descending
      await tester.pumpAndSettle();
      expect(yOf(tester, 'Cruz, Juan'), lessThan(yOf(tester, 'Santos, Maria')));
    });
  });
}
