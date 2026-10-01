import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/constants/app_colors.dart';
import 'package:guidegrade/core/sync/cloud_batch_mapper.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/export/guidance_web_export_service.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_export_batch_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/examinee_record.dart';
import 'package:guidegrade/models/local_batch.dart';

/// The manual-selection Export checklist's data source is
/// [GuidanceWebResultsService] (real service, fake [SyncClient] underneath --
/// same pattern the Results tests already use), so this test seeds the fake
/// exactly like `guidance_web_results_view_test.dart` does.
class _FakeSyncClient implements SyncClient {
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  final Map<String, CloudScansRead> scansByBatchId = {};
  CloudExamineesRead examineesToReturn = CloudExamineesRead.found(const []);

  Never _no(String label) => throw StateError('must never call $label');

  @override
  Future<CloudBatchesRead> readCloudBatches() async => batchesToReturn;
  @override
  Future<CloudScansRead> readCloudScans(String batchId) async =>
      scansByBatchId[batchId] ?? CloudScansRead.found(const []);
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async =>
      const CloudAnswerKeyRead.absent();
  @override
  Future<CloudExamineesRead> readCloudExaminees() async => examineesToReturn;
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
  }) => _no('downloadScanImage');
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
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) => _no('createExamineeFromScan');
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) => _no('updateCloudExaminee');
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) => _no('setExamineeArchived');
  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) => _no('linkScanToExaminee');
  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) => _no('unlinkScanFromExaminee');
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

/// Records exactly what [GuidanceWebExportBatchView] passes to [buildPdf] --
/// the manual-selection path never needs real PDF bytes/rendering for these
/// tests, only proof of which identity map/selection it used.
class _FakeExportService implements GuidanceWebExportService {
  List<LocalScan>? lastSelected;
  Map<String, ExamineeRecord>? lastLinkedExamineeByScanId;
  int buildPdfCalls = 0;

  @override
  Future<Uint8List> buildPdf({
    required LocalBatch batch,
    required bool includeSummary,
    required List<LocalScan> selected,
    required List<LocalScan> allScans,
    bool includeCertificates = false,
    Map<String, ExamineeRecord> linkedExamineeByScanId = const {},
  }) async {
    buildPdfCalls++;
    lastSelected = selected;
    lastLinkedExamineeByScanId = linkedExamineeByScanId;
    return Uint8List(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CloudBatchRow _batchRow() => CloudBatchRow(
  id: 'b1',
  batchCode: 'B-1',
  examCode: 'AT',
  examTitle: 'Admission Test',
  description: '',
  expectedCount: 3,
  status: 'Active',
  createdByUid: 'uid',
  createdByName: 'Officer',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

CloudScanRow _scanRow({
  required String id,
  String firstName = '',
  String lastName = '',
  String number = 'A-1',
  String? examineeId,
}) => CloudScanRow(
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
  examineeId: examineeId,
);

CloudExamineeRow _examineeRow({required String id, required String temporaryId, required String first, required String last}) =>
    CloudExamineeRow(
      id: id,
      temporaryExamineeId: temporaryId,
      firstName: first,
      lastName: last,
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid',
    );

void main() {
  late _FakeSyncClient client;
  late GuidanceWebResultsService resultsService;
  late _FakeExportService exportService;

  setUp(() {
    client = _FakeSyncClient();
    resultsService = GuidanceWebResultsService(client: client);
    exportService = _FakeExportService();
  });

  Future<void> pumpView(WidgetTester tester, {bool startInPreview = false}) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final batch = mapCloudBatch(_batchRow());
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.noScaling),
          child: Scaffold(
            body: GuidanceWebExportBatchView(
              batch: batch,
              onBack: () {},
              service: resultsService,
              exportService: exportService,
              startInPreview: startInPreview,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('manual-selection Export follows the same official-identity rule as the default Export', () {
    void seed() {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow()]);
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's_linked', number: 'A-1', examineeId: 'e1'),
        _scanRow(id: 's_unlinked', firstName: 'Ana', lastName: 'Lim', number: 'OLD-7'),
        _scanRow(id: 's_dangling', number: 'A-3', examineeId: 'e_gone'),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
      ]);
    }

    testWidgets('a linked selected scan is exported with its official identity mapped', (tester) async {
      seed();
      await pumpView(tester);

      // All three rows start checked by default (every row has some tag, or
      // is the generated number) -- tap "view output" to trigger buildPdf.
      await tester.tap(find.byKey(const Key('viewOutputButton')));
      await tester.pumpAndSettle();

      expect(exportService.buildPdfCalls, greaterThan(0));
      final linked = exportService.lastLinkedExamineeByScanId!;
      expect(linked.containsKey('s_linked'), isTrue);
      expect(linked['s_linked']!.displayName, 'Andulana, Merch');
    });

    testWidgets('an unlinked selected scan has no entry in the identity map -- never silently exported as official',
        (tester) async {
      seed();
      await pumpView(tester);

      await tester.tap(find.byKey(const Key('viewOutputButton')));
      await tester.pumpAndSettle();

      final linked = exportService.lastLinkedExamineeByScanId!;
      expect(linked.containsKey('s_unlinked'), isFalse);
      // The scan itself is still part of the selection/export (existing
      // selection semantics preserved) -- only its identity source differs.
      expect(exportService.lastSelected!.map((s) => s.id), contains('s_unlinked'));
    });

    testWidgets(
        'a dangling-examinee_id selected scan has no entry in the identity map -- never silently exported as '
        'official', (tester) async {
      seed();
      await pumpView(tester);

      await tester.tap(find.byKey(const Key('viewOutputButton')));
      await tester.pumpAndSettle();

      final linked = exportService.lastLinkedExamineeByScanId!;
      expect(linked.containsKey('s_dangling'), isFalse);
      expect(exportService.lastSelected!.map((s) => s.id), contains('s_dangling'));
    });

    testWidgets('the checklist shows the official name for a linked row, in the normal (dark) style', (tester) async {
      seed();
      await pumpView(tester);

      expect(find.text('Andulana, Merch'), findsOneWidget);
      final text = tester.widget<Text>(find.text('Andulana, Merch'));
      expect(text.style?.color, AppColors.textDark);
    });

    testWidgets('the checklist shows the OCR tag (not the official style) for an unlinked row', (tester) async {
      seed();
      await pumpView(tester);

      // The unlinked scan's own OCR tag is shown as plain scan information,
      // never invented, never upgraded to official styling.
      expect(find.text('Lim, Ana'), findsOneWidget);
    });

    testWidgets(
        'checklist pre-checking is unchanged (every scan with some tag or generated number starts checked), '
        'but the shown selection count reflects only exportable official-result scans, not the raw checked count',
        (tester) async {
      seed();
      await pumpView(tester);

      expect(find.byKey(const Key('selectionLabel')), findsOneWidget);
      final label = tester.widget<Text>(find.byKey(const Key('selectionLabel')));
      // All 3 rows start checked (unchanged pre-check behavior), but only
      // s_linked is officially linked -- the label must say 1, never 3.
      expect(label.data, contains('1 examinee'));
      expect(label.data, isNot(contains('3 examinee')));
    });

    testWidgets('export count only counts exportable official-result scans, even across multiple linked scans',
        (tester) async {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow()]);
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's_linked_1', number: 'A-1', examineeId: 'e1'),
        _scanRow(id: 's_linked_2', number: 'A-2', examineeId: 'e2'),
        _scanRow(id: 's_unlinked', firstName: 'Ana', lastName: 'Lim', number: 'OLD-7'),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: 'Merch', last: 'Andulana'),
        _examineeRow(id: 'e2', temporaryId: 'EX-000005', first: 'Maria', last: 'Santos'),
      ]);
      await pumpView(tester);

      final label = tester.widget<Text>(find.byKey(const Key('selectionLabel')));
      expect(label.data, contains('2 examinees'));
    });
  });
}
