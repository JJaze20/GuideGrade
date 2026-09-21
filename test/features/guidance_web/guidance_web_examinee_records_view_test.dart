import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_examinee_records_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_examinee_records_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';

class _FakeSyncClient implements SyncClient {
  CloudExamineesRead examineesToReturn = CloudExamineesRead.found(const []);
  CloudBatchesRead batchesToReturn = CloudBatchesRead.found(const []);
  CloudScansRead unlinkedScansToReturn = CloudScansRead.found(const []);
  final Map<String, CloudScansRead> scansByExamineeId = {};
  final List<String> calls = [];

  /// Bytes [downloadScanImage] returns; null means "no image".
  Uint8List? imageToReturn;

  /// Simulates PostgreSQL's atomic `nextval()` default for
  /// `temporary_examinee_id` — increments on every call, proving the ID
  /// comes from "the server", never from the client (whose
  /// `createExamineeFromScan` call carries no id-like parameter at all).
  int _serverSequence = 0;

  Never _no(String label) {
    calls.add(label);
    throw StateError('must never call $label');
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
  Future<CloudScansRead> readUnlinkedScans() async {
    calls.add('readUnlinkedScans');
    return unlinkedScansToReturn;
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
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    calls.add('createExamineeFromScan:$batchId/$scanId');
    _serverSequence++;
    return CloudExamineeWrite.success(CloudExamineeRow(
      id: 'new-$_serverSequence',
      temporaryExamineeId: 'EX-${_serverSequence.toString().padLeft(6, '0')}',
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
  }) =>
      _no('updateCloudExaminee');

  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) async {
    calls.add('setExamineeArchived:$id/$archived');
    final existing = examineesToReturn.examinees.firstWhere((e) => e.id == id);
    return CloudExamineeWrite.success(CloudExamineeRow(
      id: existing.id,
      temporaryExamineeId: existing.temporaryExamineeId,
      firstName: existing.firstName,
      middleName: existing.middleName,
      lastName: existing.lastName,
      status: archived ? 'archived' : 'active',
      archivedAt: archived ? DateTime.utc(2026, 2, 1) : null,
      archivedByUid: archived ? 'uid2' : null,
      createdAt: existing.createdAt,
      createdByUid: existing.createdByUid,
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
    return const SyncOutcome.success();
  }

  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) async {
    calls.add('unlinkScanFromExaminee:$batchId/$scanId/$examineeId');
    // Simulates the guarded UPDATE: the scan moves from the examinee to the
    // unlinked queue (never deleted); no match is a conflict.
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
    final bytes = imageToReturn;
    return bytes == null ? const CloudImageRead.absent() : CloudImageRead.found(bytes);
  }
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no('deleteScan');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
}

CloudExamineeRow _row({
  required String id,
  required String temporaryExamineeId,
  required String firstName,
  required String lastName,
  String status = 'active',
}) =>
    CloudExamineeRow(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      firstName: firstName,
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
  String? firstName,
  String? lastName,
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: {'examCode': examCode, 'items': <dynamic>[]},
      resultStatus: null,
      firstName: firstName,
      lastName: lastName,
      examineeNumber: (firstName == null && lastName == null) ? null : 'EX-legacy-1',
    );

void main() {
  late _FakeSyncClient client;

  setUp(() {
    client = _FakeSyncClient();
  });

  Future<void> pumpView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuidanceWebExamineeRecordsView(
            service: GuidanceWebExamineeRecordsService(client: client),
            resultsService: GuidanceWebResultsService(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders every loaded active examinee, hides archived by default', (tester) async {
    client.examineesToReturn = CloudExamineesRead.found([
      _row(id: 'e1', temporaryExamineeId: 'EX-1', firstName: 'Juan', lastName: 'Dela Cruz'),
      _row(id: 'e2', temporaryExamineeId: 'EX-2', firstName: 'Maria', lastName: 'Santos', status: 'archived'),
    ]);
    await pumpView(tester);

    expect(find.text('Dela Cruz, Juan'), findsOneWidget);
    expect(find.text('Santos, Maria'), findsNothing);
  });

  testWidgets('Status: Archived shows only archived examinees', (tester) async {
    client.examineesToReturn = CloudExamineesRead.found([
      _row(id: 'e1', temporaryExamineeId: 'EX-1', firstName: 'Juan', lastName: 'Dela Cruz'),
      _row(id: 'e2', temporaryExamineeId: 'EX-2', firstName: 'Maria', lastName: 'Santos', status: 'archived'),
    ]);
    await pumpView(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archived').last);
    await tester.pumpAndSettle();

    expect(find.text('Santos, Maria'), findsOneWidget);
    expect(find.text('Dela Cruz, Juan'), findsNothing);
  });

  testWidgets('search filters by Temporary Examinee ID', (tester) async {
    client.examineesToReturn = CloudExamineesRead.found([
      _row(id: 'e1', temporaryExamineeId: 'EX-1', firstName: 'Juan', lastName: 'Dela Cruz'),
      _row(id: 'e2', temporaryExamineeId: 'EX-2', firstName: 'Maria', lastName: 'Santos'),
    ]);
    await pumpView(tester);

    await tester.enterText(find.byType(TextField).first, 'EX-2');
    await tester.pumpAndSettle();

    expect(find.text('Santos, Maria'), findsOneWidget);
    expect(find.text('Dela Cruz, Juan'), findsNothing);
  });

  testWidgets('13/15. Archiving an active examinee updates its status and it disappears from the default (Active) view',
      (tester) async {
    client.examineesToReturn = CloudExamineesRead.found([
      _row(id: 'e1', temporaryExamineeId: 'EX-1', firstName: 'Juan', lastName: 'Dela Cruz'),
    ]);
    await pumpView(tester);
    expect(find.text('Dela Cruz, Juan'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
    await tester.pumpAndSettle();

    expect(find.text('Dela Cruz, Juan'), findsNothing);
    expect(client.calls, contains('setExamineeArchived:e1/true'));
  });

  testWidgets('14. Restoring an archived examinee brings it back without touching history (no scan call made)',
      (tester) async {
    client.examineesToReturn = CloudExamineesRead.found([
      _row(id: 'e1', temporaryExamineeId: 'EX-1', firstName: 'Juan', lastName: 'Dela Cruz', status: 'archived'),
    ]);
    await pumpView(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archived').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(client.calls, contains('setExamineeArchived:e1/false'));
    // Restoring never reads/writes a linked scan or touches the Unlinked
    // Scans queue's own linking machinery -- the initial page-load's own
    // (unrelated) readUnlinkedScans call is expected and not what this
    // guards against.
    expect(client.calls, isNot(contains(startsWith('readCloudScansForExaminee'))));
    expect(client.calls, isNot(contains(startsWith('linkScanToExaminee'))));
    expect(client.calls, isNot(contains(startsWith('createExamineeFromScan'))));
  });

  group('6. No Add Examinee / no blank-record creation', () {
    testWidgets('there is no Add Examinee button anywhere on the page', (tester) async {
      await pumpView(tester);
      expect(find.widgetWithText(FilledButton, 'Add Examinee'), findsNothing);
      expect(find.text('Add Examinee'), findsNothing);
    });
  });

  group('5. No Official Student ID anywhere in the Examinees list', () {
    testWidgets('the table has no Student ID column', (tester) async {
      client.examineesToReturn = CloudExamineesRead.found([
        _row(id: 'e1', temporaryExamineeId: 'EX-1', firstName: 'Juan', lastName: 'Dela Cruz'),
      ]);
      await pumpView(tester);
      expect(find.text('STUDENT ID'), findsNothing);
    });
  });

  group('1. Unlinked Scans tab', () {
    testWidgets('lists a scan with no examinee, "Unnamed" when OCR found nothing', (tester) async {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'QTM')]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examCode: 'QTM', firstName: null, lastName: null),
      ]);
      await pumpView(tester);

      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();

      expect(find.text('Unnamed'), findsOneWidget);
      expect(find.text('QTM'), findsWidgets);
      expect(find.text('B-QTM'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Confirm and Create Examinee'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Link to Existing'), findsOneWidget);
    });
  });

  group('View Image in Unlinked Scans', () {
    // A valid 1x1 PNG.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );

    testWidgets('clicking the previewed image opens a zoomable full-screen viewer that can be closed',
        (tester) async {
      client.imageToReturn = png;
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'QTM')]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examCode: 'QTM', firstName: 'Juan', lastName: 'Dela Cruz'),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'View Image'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scanPreviewImage')), findsOneWidget);
      expect(find.byKey(const Key('zoomableScanImage')), findsNothing);

      await tester.tap(find.byKey(const Key('scanPreviewImage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('zoomableScanImage')), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(find.byKey(const Key('zoomableScanImage')));
      expect(viewer.maxScale, greaterThan(1));

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('zoomableScanImage')), findsNothing);
      // Viewing never changed the scan.
      expect(client.calls, isNot(contains(startsWith('linkScanToExaminee'))));
    });
  });

  group('2. Create Examinee Record from this Scan', () {
    testWidgets('creates the record, shows it, and removes the scan from Unlinked Scans', (tester) async {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'QTM')]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examCode: 'QTM', firstName: 'Juan', lastName: 'Dela Cruz'),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Confirm and Create Examinee'));
      await tester.pumpAndSettle();

      expect(find.text('Create Examinee Record from this Scan'), findsOneWidget);

      // Pre-filled from the scan's own confirmed tag -- saved without
      // changing anything, so a successful create proves the pre-fill was
      // there (an empty name would fail nothing here since names aren't
      // required, but the resulting display name below proves the fields
      // carried 'Juan'/'Dela Cruz' through unedited).
      await tester.tap(find.widgetWithText(FilledButton, 'Create Examinee Record'));
      await tester.pumpAndSettle();

      expect(client.calls, contains('createExamineeFromScan:b1/s1'));
      // "show the new Examinee Record" -- navigated straight to its detail page.
      expect(find.text('Dela Cruz, Juan'), findsOneWidget);
      expect(find.text('EX-000001'), findsOneWidget);
    });
  });

  group('3. Link to Existing Examinee', () {
    testWidgets('never links without an explicit selection and a final confirmation', (tester) async {
      client.examineesToReturn = CloudExamineesRead.found([
        _row(id: 'e1', temporaryExamineeId: 'EX-000001', firstName: 'Juan', lastName: 'Dela Cruz'),
      ]);
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'TAT')]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examCode: 'TAT', firstName: 'Juan', lastName: 'Dela Cruz'),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Link to Existing'));
      await tester.pumpAndSettle();

      // Nothing is linked just by opening the dialog.
      expect(client.calls, isNot(contains(startsWith('linkScanToExaminee'))));

      await tester.tap(find.widgetWithText(ListTile, 'Dela Cruz, Juan').first);
      await tester.pumpAndSettle();

      // The confirmation names both sides explicitly.
      expect(find.textContaining('EX-000001'), findsWidgets);
      expect(find.textContaining('B-TAT'), findsWidgets);

      // Cancel (the confirmation dialog's own Cancel, the most recently
      // opened one) -> no change. The underlying "Link to Existing"
      // picker dialog is still open behind it.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
      expect(client.calls, isNot(contains(startsWith('linkScanToExaminee'))));

      // Select the same candidate again and this time confirm.
      await tester.tap(find.widgetWithText(ListTile, 'Dela Cruz, Juan').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Attach'));
      await tester.pumpAndSettle();

      expect(client.calls, contains('linkScanToExaminee:b1/s1/e1'));
    });
  });
}
