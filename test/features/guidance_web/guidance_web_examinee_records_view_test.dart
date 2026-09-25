import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
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

  /// What [downloadNameCropImage] returns: `nameCropRead` when set (e.g. a
  /// failure), otherwise `nameCropBytes` (null = the crop was never uploaded).
  Uint8List? nameCropBytes;
  CloudImageRead? nameCropRead;

  /// When set, every crop download waits for it (a slow Storage).
  Completer<void>? nameCropGate;

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
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) async {
    calls.add('downloadNameCropImage:$batchId/$scanId/$variant');
    final gate = nameCropGate;
    if (gate != null) await gate.future;
    final read = nameCropRead;
    if (read != null) return read;
    final bytes = nameCropBytes;
    return bytes == null
        ? const CloudImageRead.absent()
        : CloudImageRead.found(bytes);
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
  DateTime? capturedAt,
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: capturedAt ?? DateTime.utc(2026, 1, 1),
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

  testWidgets('Unlinked Scans column headers line up with their row cells', (tester) async {
    client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'bq', examCode: 'QTM')]);
    client.unlinkedScansToReturn = CloudScansRead.found([
      _scanRow(id: 's1', batchId: 'bq', examCode: 'QTM', firstName: 'Juan', lastName: 'Cruz'),
    ]);
    await pumpView(tester);
    await tester.tap(find.textContaining('Unlinked Scans'));
    await tester.pumpAndSettle();

    double left(Finder f) => tester.getTopLeft(f).dx;
    expect(left(find.text('OCR NAME')), left(find.text('Cruz, Juan')));
    expect(left(find.text('EXAM')), left(find.text('QTM').last));
    expect(left(find.text('BATCH')), left(find.text('B-QTM')));
    expect(left(find.text('CAPTURED')), left(find.text('Jan 1, 2026')));
  });

  group('Unlinked Scans exam-type filter', () {
    Future<void> openUnlinked(WidgetTester tester) async {
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(id: 'bq', examCode: 'QTM'),
        _batchRow(id: 'bt', examCode: 'TAT'),
        _batchRow(id: 'ba', examCode: 'AT'),
      ]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'bq', examCode: 'QTM', firstName: 'Juan', lastName: 'Cruz'),
        _scanRow(id: 's2', batchId: 'bt', examCode: 'TAT', firstName: 'Maria', lastName: 'Santos'),
        _scanRow(id: 's3', batchId: 'ba', examCode: 'AT', firstName: 'Pedro', lastName: 'Reyes'),
        _scanRow(id: 's4', batchId: 'bt', examCode: 'TAT', firstName: 'Ana', lastName: 'Lopez'),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, String option) async {
      await tester.tap(find.byKey(const Key('unlinkedExamTypeFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    testWidgets('defaults to All and shows every unlinked scan', (tester) async {
      await openUnlinked(tester);
      expect(find.text('Cruz, Juan'), findsOneWidget);
      expect(find.text('Santos, Maria'), findsOneWidget);
      expect(find.text('Reyes, Pedro'), findsOneWidget);
      expect(find.text('Lopez, Ana'), findsOneWidget);
      expect(find.text('Showing 4 of 4'), findsOneWidget);
    });

    testWidgets('QTM / TAT / AT each show only that exam type, and All restores the full list',
        (tester) async {
      await openUnlinked(tester);

      await pick(tester, 'TAT');
      expect(find.text('Santos, Maria'), findsOneWidget);
      expect(find.text('Lopez, Ana'), findsOneWidget);
      expect(find.text('Cruz, Juan'), findsNothing);
      expect(find.text('Reyes, Pedro'), findsNothing);
      expect(find.text('Showing 2 of 4'), findsOneWidget);

      await pick(tester, 'QTM');
      expect(find.text('Cruz, Juan'), findsOneWidget);
      expect(find.text('Santos, Maria'), findsNothing);
      expect(find.text('Showing 1 of 4'), findsOneWidget);

      await pick(tester, 'AT');
      expect(find.text('Reyes, Pedro'), findsOneWidget);
      expect(find.text('Cruz, Juan'), findsNothing);

      await pick(tester, 'All');
      expect(find.text('Showing 4 of 4'), findsOneWidget);
      expect(find.text('Lopez, Ana'), findsOneWidget);
    });

    testWidgets('changing the filter is view-only: no reload and nothing linked',
        (tester) async {
      await openUnlinked(tester);
      client.calls.clear();
      client.unlinkedScansToReturn = CloudScansRead.found(const []);
      // Filter is view-only: switching it makes no request and links nothing.
      await pick(tester, 'AT');
      await pick(tester, 'QTM');
      expect(client.calls.where((c) => c == 'readUnlinkedScans' || c.startsWith('linkScanToExaminee')), isEmpty);
      expect(find.text('Cruz, Juan'), findsOneWidget);
    });

    testWidgets('a filter with no matches says so', (tester) async {
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'bt', examCode: 'TAT')]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's2', batchId: 'bt', examCode: 'TAT', firstName: 'Maria', lastName: 'Santos'),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();

      await pick(tester, 'QTM');
      expect(find.text('No unlinked QTM scans.'), findsOneWidget);
      expect(find.text('Showing 0 of 1'), findsOneWidget);
      expect(find.text('Santos, Maria'), findsNothing);
    });
  });

  group('Unlinked Scans date filter', () {
    // Days of the CURRENT month, so the date picker (which opens on this
    // month) needs no month navigation.
    DateTime day(int d) {
      final now = DateTime.now();
      return DateTime.utc(now.year, now.month, d);
    }

    Future<void> openUnlinked(WidgetTester tester) async {
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(id: 'bq', examCode: 'QTM'),
        _batchRow(id: 'bt', examCode: 'TAT'),
      ]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'bt', examCode: 'TAT', firstName: 'Juan', lastName: 'Cruz', capturedAt: day(9)),
        _scanRow(id: 's2', batchId: 'bt', examCode: 'TAT', firstName: 'Maria', lastName: 'Santos', capturedAt: day(10)),
        _scanRow(id: 's3', batchId: 'bq', examCode: 'QTM', firstName: 'Pedro', lastName: 'Reyes', capturedAt: day(15)),
        _scanRow(id: 's4', batchId: 'bt', examCode: 'TAT', firstName: 'Ana', lastName: 'Lopez', capturedAt: day(16)),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();
    }

    Future<void> pickDay(WidgetTester tester, String fieldKey, int dayOfMonth) async {
      await tester.tap(find.byKey(Key(fieldKey)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$dayOfMonth'));
      await tester.pumpAndSettle();
    }

    Future<void> pickRange(WidgetTester tester, int from, int to) async {
      await pickDay(tester, 'unlinkedDateFrom', from);
      await pickDay(tester, 'unlinkedDateTo', to);
    }

    testWidgets('defaults to All dates with every scan shown', (tester) async {
      await openUnlinked(tester);
      expect(find.text('Captured Date (MM/DD/YYYY)'), findsOneWidget);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('to'), findsOneWidget);
      expect(find.text('Showing 4 of 4'), findsOneWidget);
      expect(find.byKey(const Key('unlinkedDateClear')), findsNothing);
    });

    testWidgets('a date range keeps scans captured on or between its first and last day', (tester) async {
      await openUnlinked(tester);
      await pickRange(tester, 10, 15);

      expect(find.text('Santos, Maria'), findsOneWidget); // first day, inclusive
      expect(find.text('Reyes, Pedro'), findsOneWidget); // last day, inclusive
      expect(find.text('Cruz, Juan'), findsNothing); // day before
      expect(find.text('Lopez, Ana'), findsNothing); // day after
      expect(find.text('Showing 2 of 4'), findsOneWidget);
      expect(find.byKey(const Key('unlinkedDateClear')), findsOneWidget);
    });

    testWidgets('Clear brings every date back', (tester) async {
      await openUnlinked(tester);
      await pickRange(tester, 10, 15);
      await tester.tap(find.byKey(const Key('unlinkedDateClear')));
      await tester.pumpAndSettle();

      expect(find.text('From'), findsOneWidget);
      expect(find.text('to'), findsOneWidget);
      expect(find.text('Showing 4 of 4'), findsOneWidget);
      expect(find.text('Cruz, Juan'), findsOneWidget);
    });

    testWidgets('a From date alone means "on or after"; a To date alone means "on or before"', (tester) async {
      await openUnlinked(tester);

      await pickDay(tester, 'unlinkedDateFrom', 15);
      expect(find.text('Reyes, Pedro'), findsOneWidget);
      expect(find.text('Lopez, Ana'), findsOneWidget);
      expect(find.text('Santos, Maria'), findsNothing);
      expect(find.text('Showing 2 of 4'), findsOneWidget);

      await tester.tap(find.byKey(const Key('unlinkedDateClear')));
      await tester.pumpAndSettle();
      await pickDay(tester, 'unlinkedDateTo', 10);
      expect(find.text('Cruz, Juan'), findsOneWidget);
      expect(find.text('Santos, Maria'), findsOneWidget);
      expect(find.text('Reyes, Pedro'), findsNothing);
      expect(find.text('Showing 2 of 4'), findsOneWidget);
    });

    testWidgets('the fields show MM/DD/YYYY dates, and a From after To pulls To along', (tester) async {
      await openUnlinked(tester);
      final now = DateTime.now();
      String fmt(int d) =>
          '${now.month.toString().padLeft(2, '0')}/${d.toString().padLeft(2, '0')}/${now.year}';

      await pickRange(tester, 10, 15);
      expect(find.text(fmt(10)), findsOneWidget);
      expect(find.text(fmt(15)), findsOneWidget);

      await pickDay(tester, 'unlinkedDateFrom', 20); // after To (15)
      expect(find.text(fmt(20)), findsNWidgets(2)); // To follows: never inverted
    });

    testWidgets('the calendar opens under the field and closes on an outside tap without changing anything',
        (tester) async {
      await openUnlinked(tester);
      expect(find.byType(CalendarDatePicker), findsNothing);

      await tester.tap(find.byKey(const Key('unlinkedDateFrom')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      // Sits directly below the From field.
      expect(
        tester.getTopLeft(find.byType(CalendarDatePicker)).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const Key('unlinkedDateFrom'))).dy),
      );

      await tester.tapAt(const Offset(1300, 1500)); // outside the popover
      await tester.pumpAndSettle();
      expect(find.byType(CalendarDatePicker), findsNothing);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('Showing 4 of 4'), findsOneWidget);
    });

    testWidgets('month arrows and arrow keys in the calendar work with a mouse (desktop web) without assertions',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await openUnlinked(tester);
      await tester.tap(find.byKey(const Key('unlinkedDateFrom')));
      await tester.pumpAndSettle();

      Future<void> click(String tooltip) async {
        final at = tester.getCenter(find.byTooltip(tooltip));
        await mouse.moveTo(at); // hover shows the tooltip
        await tester.pump(const Duration(milliseconds: 700));
        await mouse.down(at);
        await mouse.up();
        await tester.pumpAndSettle();
      }

      await click('Next month');
      await click('Next month');
      await click('Previous month');
      await click('Previous month');
      await click('Previous month');
      expect(find.byType(CalendarDatePicker), findsOneWidget);

      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      // Must be unset before the test ends (the framework checks it).
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('combines with the Exam Type filter (both must match)', (tester) async {
      await openUnlinked(tester);
      await pickRange(tester, 10, 15);

      await tester.tap(find.byKey(const Key('unlinkedExamTypeFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TAT').last);
      await tester.pumpAndSettle();

      expect(find.text('Santos, Maria'), findsOneWidget); // TAT, in range
      expect(find.text('Reyes, Pedro'), findsNothing); // in range but QTM
      expect(find.text('Lopez, Ana'), findsNothing); // TAT but out of range
      expect(find.text('Showing 1 of 4'), findsOneWidget);
    });

    testWidgets('a range with no scans says so and changes nothing', (tester) async {
      await openUnlinked(tester);
      client.calls.clear();
      await pickRange(tester, 20, 21);

      expect(find.text('No unlinked scans match the selected filters.'), findsOneWidget);
      expect(find.text('Showing 0 of 4'), findsOneWidget);
      expect(client.calls.where((c) => c == 'readUnlinkedScans' || c.startsWith('linkScanToExaminee')), isEmpty);
    });
  });

  group('Unlinked Scans inline name crop', () {
    // A valid 1x1 PNG standing in for a handwritten-name crop.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );

    Future<void> openUnlinked(
      WidgetTester tester, {
      int scans = 1,
      bool settle = true,
    }) async {
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(id: 'bq', examCode: 'QTM'),
      ]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        for (var i = 1; i <= scans; i++)
          _scanRow(
            id: 's$i',
            batchId: 'bq',
            examCode: 'QTM',
            firstName: 'Juan$i',
            lastName: 'Cruz',
          ),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
        await tester.pump();
      }
    }

    int cropCalls() =>
        client.calls.where((c) => c.startsWith('downloadNameCropImage')).length;

    testWidgets(
      'there is a NAME CROP column, right after OCR NAME and before EXAM',
      (tester) async {
        await openUnlinked(tester);

        double left(String text) => tester.getTopLeft(find.text(text)).dx;
        expect(find.text('NAME CROP'), findsOneWidget);
        expect(left('OCR NAME'), lessThan(left('NAME CROP')));
        expect(left('NAME CROP'), lessThan(left('EXAM')));
        expect(left('EXAM'), lessThan(left('BATCH')));
        expect(left('BATCH'), lessThan(left('CAPTURED')));
      },
    );

    testWidgets(
      'the three crops (Last, First, MI) are shown inline, to the right of the OCR name and left of EXAM',
      (tester) async {
        client.nameCropBytes = png;
        await openUnlinked(tester);

        for (final v in ['name_last', 'name_first', 'name_mi']) {
          expect(find.byKey(Key('nameCropImage_$v')), findsOneWidget);
        }
        expect(find.text('Last'), findsOneWidget);
        expect(find.text('First'), findsOneWidget);
        expect(find.text('MI'), findsOneWidget);

        final nameRight = tester.getTopRight(find.text('Cruz, Juan1')).dx;
        final last = tester.getTopLeft(
          find.byKey(const Key('nameCropImage_name_last')),
        );
        final first = tester.getTopLeft(
          find.byKey(const Key('nameCropImage_name_first')),
        );
        final mi = tester.getTopLeft(
          find.byKey(const Key('nameCropImage_name_mi')),
        );
        final examLeft = tester.getTopLeft(find.text('QTM').last).dx;
        expect(last.dx, greaterThanOrEqualTo(nameRight));
        expect(last.dx, lessThan(first.dx));
        expect(first.dx, lessThan(mi.dx));
        expect(mi.dx, lessThan(examLeft));

        // Large enough to read in the table: all three share one height, the
        // long Last / First names get the widest boxes.
        final last0 = tester.getSize(
          find.byKey(const Key('nameCropImage_name_last')),
        );
        final first0 = tester.getSize(
          find.byKey(const Key('nameCropImage_name_first')),
        );
        final mi0 = tester.getSize(
          find.byKey(const Key('nameCropImage_name_mi')),
        );
        expect(first0.height, last0.height);
        expect(mi0.height, last0.height);
        expect(last0.height, greaterThanOrEqualTo(44));
        expect(last0.width, greaterThanOrEqualTo(140));
        expect(first0.width, last0.width);
        expect(mi0.width, lessThan(last0.width));

        // The header lines up with the first crop.
        expect(tester.getTopLeft(find.text('NAME CROP')).dx, last.dx);
      },
    );

    testWidgets(
      'the crops never overlap EXAM, BATCH, CAPTURED or the action buttons',
      (tester) async {
        client.nameCropBytes = png;
        await openUnlinked(tester);

        final miRight = tester
            .getTopRight(find.byKey(const Key('nameCropImage_name_mi')))
            .dx;
        final examLeft = tester.getTopLeft(find.text('QTM').last).dx;
        final batch = find.text('B-QTM');
        final captured = find.text('Jan 1, 2026');
        final actionsLeft = tester
            .getTopLeft(find.widgetWithText(TextButton, 'View Image'))
            .dx;
        expect(miRight, lessThan(examLeft));
        // Cells may touch the actions column edge but never cross it.
        expect(tester.getTopRight(batch).dx, lessThanOrEqualTo(actionsLeft));
        expect(tester.getTopRight(captured).dx, lessThanOrEqualTo(actionsLeft));
        // The OCR name and the other cells are all still visible.
        expect(find.text('Cruz, Juan1'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'no layout overflow');
      },
    );

    testWidgets('there is no "View Name Crop" button', (tester) async {
      client.nameCropBytes = png;
      await openUnlinked(tester);

      expect(find.text('View Name Crop'), findsNothing);
      expect(find.text('Handwritten Name Crops'), findsNothing);
      // Nothing is open until a crop is clicked.
      expect(find.byType(Dialog), findsNothing);
    });

    group('click to enlarge', () {
      Future<void> openZoom(WidgetTester tester, String variant) async {
        await tester.tap(find.byKey(Key('nameCropTap_$variant')));
        await tester.pumpAndSettle();
      }

      testWidgets('each crop opens ONLY its own enlarged image, with a title', (
        tester,
      ) async {
        client.nameCropBytes = png;
        await openUnlinked(tester);

        for (final (variant, title) in [
          ('name_last', 'Last Name'),
          ('name_first', 'First Name'),
          ('name_mi', 'Middle Initial'),
        ]) {
          await openZoom(tester, variant);
          expect(find.byType(Dialog), findsOneWidget);
          expect(find.byKey(const Key('nameCropZoomImage')), findsOneWidget);
          expect(
            find.text('$title — handwritten crop'),
            findsOneWidget,
            reason: 'the title says which crop this is',
          );
          // The enlarged image is far bigger than the table thumbnail.
          final zoomed = tester.getSize(
            find.byKey(const Key('nameCropZoomImage')),
          );
          final thumb = tester.getSize(
            find.byKey(Key('nameCropImage_$variant')),
          );
          expect(zoomed.height, greaterThan(thumb.height * 3));

          await tester.tap(find.byKey(const Key('nameCropZoomClose')));
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsNothing);
        }
      });

      testWidgets('closing returns to the table with everything intact', (
        tester,
      ) async {
        client.nameCropBytes = png;
        await openUnlinked(tester);
        await openZoom(tester, 'name_last');

        await tester.tap(find.byKey(const Key('nameCropZoomClose')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('nameCropZoomImage')), findsNothing);
        expect(find.text('Cruz, Juan1'), findsOneWidget);
        expect(find.text('Showing 1 of 1'), findsOneWidget);
        expect(
          find.byKey(const Key('nameCropImage_name_last')),
          findsOneWidget,
        );
      });

      testWidgets('Escape and a click outside also close it', (tester) async {
        client.nameCropBytes = png;
        await openUnlinked(tester);

        await openZoom(tester, 'name_first');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);

        await openZoom(tester, 'name_first');
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      });

      testWidgets(
        'the crops look clickable: pointer cursor and a hover highlight',
        (tester) async {
          client.nameCropBytes = png;
          await openUnlinked(tester);

          final region = tester.widgetList<MouseRegion>(
            find.ancestor(
              of: find.byKey(const Key('nameCropTap_name_last')),
              matching: find.byType(MouseRegion),
            ),
          );
          expect(
            region.any((r) => r.cursor == SystemMouseCursors.click),
            isTrue,
          );

          expect(
            find.byKey(const Key('nameCropHover_name_last')),
            findsNothing,
          );
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          await mouse.moveTo(
            tester.getCenter(find.byKey(const Key('nameCropImage_name_last'))),
          );
          await tester.pump();
          expect(
            find.byKey(const Key('nameCropHover_name_last')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('nameCropHover_name_first')),
            findsNothing,
          );
          await mouse.moveTo(Offset.zero);
          await tester.pump();
          expect(
            find.byKey(const Key('nameCropHover_name_last')),
            findsNothing,
          );
        },
      );

      testWidgets('a missing or failed crop is not clickable', (tester) async {
        client.nameCropBytes = null;
        await openUnlinked(tester);

        expect(find.byKey(const Key('nameCropTap_name_last')), findsNothing);
        await tester.tap(find.byKey(const Key('nameCropMissing_name_last')));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      });

      testWidgets('the row actions still work after using the zoom', (
        tester,
      ) async {
        client.nameCropBytes = png;
        client.examineesToReturn = CloudExamineesRead.found([
          _row(
            id: 'e1',
            temporaryExamineeId: 'EX-000001',
            firstName: 'Juan1',
            lastName: 'Cruz',
          ),
        ]);
        await openUnlinked(tester);
        await openZoom(tester, 'name_last');
        await tester.tap(find.byKey(const Key('nameCropZoomClose')));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, 'Link to Existing'));
        await tester.pumpAndSettle();
        expect(find.text('Link to Existing Examinee'), findsOneWidget);
      });
    });

    testWidgets('the existing actions are all still there', (tester) async {
      await openUnlinked(tester);

      expect(find.widgetWithText(TextButton, 'View Image'), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, 'Link to Existing'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextButton, 'Confirm and Create Examinee'),
        findsOneWidget,
      );
    });

    testWidgets(
      'Link to Existing still opens the picker from a row with crops',
      (tester) async {
        client.nameCropBytes = png;
        client.examineesToReturn = CloudExamineesRead.found([
          _row(
            id: 'e1',
            temporaryExamineeId: 'EX-000001',
            // The picker starts its search from the scan's own OCR name.
            firstName: 'Juan1',
            lastName: 'Cruz',
          ),
        ]);
        await openUnlinked(tester);

        await tester.tap(find.widgetWithText(TextButton, 'Link to Existing'));
        await tester.pumpAndSettle();

        expect(find.text('Link to Existing Examinee'), findsOneWidget);
        expect(find.widgetWithText(ListTile, 'Cruz, Juan1'), findsOneWidget);
      },
    );

    testWidgets(
      'Confirm and Create Examinee still opens its dialog from a row with crops',
      (tester) async {
        client.nameCropBytes = png;
        await openUnlinked(tester);

        await tester.tap(
          find.widgetWithText(TextButton, 'Confirm and Create Examinee'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Create Examinee Record'), findsWidgets);
      },
    );

    testWidgets(
      'a crop that was never uploaded shows a small N/A and the row is intact',
      (tester) async {
        client.nameCropBytes = null; // 404 -> absent, not an error
        await openUnlinked(tester);

        for (final v in ['name_last', 'name_first', 'name_mi']) {
          expect(find.byKey(Key('nameCropMissing_$v')), findsOneWidget);
        }
        expect(find.text('N/A'), findsNWidgets(3));
        expect(find.text('Cruz, Juan1'), findsOneWidget);
        expect(find.text('QTM'), findsWidgets);
        expect(find.text('B-QTM'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'View Image'), findsOneWidget);
        // Missing is a normal state: no error box, no page-level error.
        expect(find.byKey(const Key('nameCropError_name_last')), findsNothing);
      },
    );

    testWidgets(
      'a failed download shows a compact retry box; the row is intact and retry reloads',
      (tester) async {
        client.nameCropRead = const CloudImageRead.failed(
          SyncOutcome.transient('network'),
        );
        await openUnlinked(tester);

        expect(
          find.byKey(const Key('nameCropError_name_last')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('nameCropError_name_first')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('nameCropError_name_mi')), findsOneWidget);
        expect(find.text('Cruz, Juan1'), findsOneWidget);
        expect(
          find.widgetWithText(TextButton, 'Link to Existing'),
          findsOneWidget,
        );
        final before = cropCalls();

        // Storage recovers; clicking one crop retries just that one.
        client.nameCropRead = null;
        client.nameCropBytes = png;
        await tester.tap(find.byKey(const Key('nameCropError_name_last')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('nameCropImage_name_last')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('nameCropError_name_first')),
          findsOneWidget,
        );
        expect(cropCalls(), before + 1);
      },
    );

    testWidgets(
      'undecodable crop bytes fall back to N/A instead of breaking the row',
      (tester) async {
        client.nameCropBytes = Uint8List.fromList([1, 2, 3, 4]);
        await openUnlinked(tester);

        expect(find.text('Cruz, Juan1'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'View Image'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'slow crops never block the list: rows, filters and actions work while they load',
      (tester) async {
        client.nameCropGate = Completer<void>();
        client.nameCropBytes = png;
        await openUnlinked(tester, scans: 3, settle: false);

        // Nothing has come back yet, but the whole table is already usable.
        expect(find.text('Cruz, Juan1'), findsOneWidget);
        expect(find.text('Cruz, Juan3'), findsOneWidget);
        expect(find.text('Showing 3 of 3'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'View Image'), findsNWidgets(3));
        expect(
          find.byKey(const Key('nameCropLoading_name_last')),
          findsNWidgets(3),
        );
        expect(find.byKey(const Key('nameCropImage_name_last')), findsNothing);

        // Filtering still works while crops are in flight.
        await tester.tap(find.byKey(const Key('unlinkedExamTypeFilter')));
        await tester.pump();
        await tester.tap(find.text('TAT').last);
        await tester.pump();
        expect(find.text('Showing 0 of 3'), findsOneWidget);

        // Storage answers: the crops fill in.
        client.nameCropGate!.complete();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('unlinkedExamTypeFilter')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('All').last);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('nameCropImage_name_last')),
          findsNWidgets(3),
        );
      },
    );

    testWidgets(
      'crops load lazily: only the rows being shown are downloaded, once, and more load on scroll',
      (tester) async {
        client.nameCropBytes = png;
        await openUnlinked(tester, scans: 80);

        final atStart = cropCalls();
        expect(atStart, greaterThan(0));
        expect(atStart, lessThan(3 * 80), reason: 'not every row at page load');
        expect(
          atStart % 3,
          0,
          reason: 'a row loads all three of its crops together',
        );
        expect(
          client.calls.where(
            (c) => c == 'downloadNameCropImage:bq/s80/name_last',
          ),
          isEmpty,
          reason: 'a row far below the fold is not downloaded yet',
        );

        // Scroll to the bottom: the last rows now load...
        await tester.drag(find.byType(ListView).last, const Offset(0, -100000));
        await tester.pumpAndSettle();
        expect(
          client.calls.where(
            (c) => c == 'downloadNameCropImage:bq/s80/name_last',
          ),
          hasLength(1),
        );
        expect(cropCalls(), greaterThan(atStart));

        // ...and scrolling back does not download the first row again.
        await tester.drag(find.byType(ListView).last, const Offset(0, 100000));
        await tester.pumpAndSettle();
        expect(
          client.calls.where(
            (c) => c == 'downloadNameCropImage:bq/s1/name_last',
          ),
          hasLength(1),
        );
      },
    );
  });

  group('3. Link to Existing Examinee', () {
    testWidgets('the picker lists only ACTIVE examinees and says archived ones must be restored first',
        (tester) async {
      client.examineesToReturn = CloudExamineesRead.found([
        _row(id: 'e1', temporaryExamineeId: 'EX-000001', firstName: 'Juan', lastName: 'Dela Cruz'),
        _row(id: 'e2', temporaryExamineeId: 'EX-000002', firstName: 'Maria', lastName: 'Santos', status: 'archived'),
      ]);
      client.batchesToReturn = CloudBatchesRead.found([_batchRow(id: 'b1', examCode: 'TAT')]);
      client.unlinkedScansToReturn = CloudScansRead.found([
        _scanRow(id: 's1', batchId: 'b1', examCode: 'TAT', firstName: null, lastName: null),
      ]);
      await pumpView(tester);
      await tester.tap(find.textContaining('Unlinked Scans'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Link to Existing'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ListTile, 'Dela Cruz, Juan'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Santos, Maria'), findsNothing);
      expect(find.byKey(const Key('linkPickerActiveOnlyHint')), findsOneWidget);
      expect(
        find.text('Only active examinees can be linked to a scan. Restore an archived examinee first.'),
        findsOneWidget,
      );

      // Searching for the archived examinee's name / ID still does not offer it.
      await tester.enterText(find.byType(TextField), 'Santos');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Santos, Maria'), findsNothing);
      expect(find.text('No matching Examinee Records.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'EX-000002');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Santos, Maria'), findsNothing);
    });

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
