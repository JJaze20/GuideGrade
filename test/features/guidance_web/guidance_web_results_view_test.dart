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
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
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

CloudScanRow _scanRow({required String id, required String firstName, required String lastName, required String number}) =>
    CloudScanRow(
      id: id,
      batchId: 'b1',
      examCode: 'AT',
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: const {'examCode': 'AT', 'items': <dynamic>[]},
      rawScore: 50,
      totalGraded: 72,
      totalItems: 72,
      resultStatus: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'uid',
      processedByName: 'Officer',
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
}
