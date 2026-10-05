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
  CloudExamineesRead examineesToReturn = CloudExamineesRead.found(const []);
  int examineeReads = 0;

  Never _no(String label) => throw StateError('must never call $label');

  @override
  Future<CloudBatchesRead> readCloudBatches() async => batchesToReturn;
  @override
  Future<CloudScansRead> readCloudScans(String batchId) async =>
      scansByBatchId[batchId] ?? CloudScansRead.found(const []);
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async =>
      answerKeyToReturn;
  @override
  Future<SyncOutcome> pushBatch(String batchId) => _no('pushBatch');
  @override
  Future<SyncOutcome> pushScan(
    String batchId,
    String scanId, {
    Map<String, String> meta = const {},
  }) => _no('pushScan');
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _no('uploadImage');
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) =>
      _no('patchImageStatus');
  @override
  Future<SyncOutcome> pushAnswerKey(
    String examCode, {
    Map<String, String> meta = const {},
  }) => _no('pushAnswerKey');
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
  Future<SyncOutcome> deleteScan(String batchId, String scanId) =>
      _no('deleteScan');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) =>
      _no('deleteStoragePrefix');
  @override
  Future<CloudExamineesRead> readCloudExaminees() async {
    examineeReads++;
    return examineesToReturn;
  }

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
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) =>
      _no('setExamineeArchived');
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
  Future<CloudBatchArchivesRead> readBatchArchives() async =>
      CloudBatchArchivesRead.found(const []);

  @override
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason}) =>
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

CloudBatchRow _batchRow({
  String description = '',
  String id = 'b1',
  String batchCode = 'B-1',
  String examCode = 'AT',
  String examTitle = 'Admission Test',
}) => CloudBatchRow(
  id: id,
  batchCode: batchCode,
  examCode: examCode,
  examTitle: examTitle,
  description: description,
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
  String? examineeId,
  String batchId = 'b1',
  String examCode = 'AT',
  int attemptNo = 1,
  String attemptStatus = 'active',
}) => CloudScanRow(
  id: id,
  batchId: batchId,
  examCode: examCode,
  capturedAt: DateTime.utc(2026, 1, 1),
  decoded: {'examCode': examCode, 'items': <dynamic>[]},
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
  attemptNo: attemptNo,
  attemptStatus: attemptStatus,
  examineeId: examineeId,
);

CloudExamineeRow _examineeRow({
  required String id,
  required String temporaryId,
  required String first,
  String? middle,
  required String last,
}) => CloudExamineeRow(
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

  setUp(() {
    client = _FakeSyncClient();
    client.batchesToReturn = CloudBatchesRead.found([_batchRow()]);
    // Linked by default (examineeId set + a matching examinee registered),
    // so every test in this file that isn't specifically about linking
    // still sees its rows in Results -- see the "linked examinees" group
    // below for the tests that exercise the official-identity filter itself.
    client.scansByBatchId['b1'] = CloudScansRead.found([
      _scanRow(
        id: 's1',
        firstName: 'Juan',
        lastName: 'Cruz',
        number: 'A-1',
        examineeId: 'e1',
      ),
      _scanRow(
        id: 's2',
        firstName: 'Maria',
        lastName: 'Santos',
        number: 'A-2',
        examineeId: 'e2',
      ),
    ]);
    client.examineesToReturn = CloudExamineesRead.found([
      _examineeRow(
        id: 'e1',
        temporaryId: 'EX-000001',
        first: 'Juan',
        last: 'Cruz',
      ),
      _examineeRow(
        id: 'e2',
        temporaryId: 'EX-000002',
        first: 'Maria',
        last: 'Santos',
      ),
    ]);
  });

  Future<void> pumpResultsView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuidanceWebResultsView(
            service: GuidanceWebResultsService(client: client),
            refreshInterval: null,
          ),
        ),
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
    'linked and unlinked groups use canonical resolution and preserve search',
    (tester) async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(
          id: 's1',
          firstName: 'Juan',
          lastName: 'Cruz',
          number: 'A-1',
          examineeId: 'e1',
        ),
        _scanRow(id: 's2', firstName: 'Ana', lastName: 'Lim', number: 'U-1'),
        _scanRow(
          id: 's3',
          firstName: 'Missing',
          lastName: 'Link',
          number: 'U-2',
          examineeId: 'missing',
        ),
      ]);
      await pumpResultsView(tester);
      await selectTheOnlyBatch(tester);
      await tester.tap(find.byKey(const Key('resultsIdentityExaminee')));
      await tester.pumpAndSettle();
      expect(find.text('Cruz, Juan'), findsOneWidget);
      expect(find.text('Lim, Ana'), findsNothing);
      await tester.tap(
        find.byKey(const Key('resultsIdentityUnlinked Examinee')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cruz, Juan'), findsNothing);
      expect(find.text('Lim, Ana'), findsOneWidget);
      expect(find.text('Link, Missing'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('resultsSearch')), 'Ana');
      await tester.pumpAndSettle();
      expect(find.text('Lim, Ana'), findsOneWidget);
      expect(find.text('Link, Missing'), findsNothing);
    },
  );

  for (final width in [320.0, 390.0, 768.0, 1280.0]) {
    testWidgets('Results controls and rows remain usable at $width', (
      tester,
    ) async {
      await pumpResultsView(tester);
      await selectTheOnlyBatch(tester);
      tester.view.physicalSize = Size(width, 900);
      if (width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 1.8;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(Key(width < 648 ? 'resultsCards' : 'resultsTable')),
        findsOneWidget,
      );
      final view = find.widgetWithText(TextButton, 'View').first;
      expect(tester.getSize(view).height, greaterThanOrEqualTo(44));
      await tester.enterText(
        find.byKey(const Key('resultsSearch')),
        'no-matching-person',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No results match your search or filter.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Clear filters').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('2 of 2 results'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'refresh preserves the selected batch when the same batch is reloaded as a new LocalBatch instance',
    (tester) async {
      const refreshedDescription =
          'Updated room assignment for the morning session';
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(description: 'Original batch description'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceWebResultsView(
              service: GuidanceWebResultsService(client: client),
              refreshInterval: const Duration(milliseconds: 25),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<LocalBatch>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('B-1 — Admission Test (Jan 1, 2026)').last);
      await tester.pumpAndSettle();

      final dropdownBefore = tester.widget<DropdownButton<LocalBatch>>(
        find.byType(DropdownButton<LocalBatch>).first,
      );
      expect(dropdownBefore.value, isNotNull);
      expect(dropdownBefore.value!.description, 'Original batch description');

      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(description: refreshedDescription),
      ]);

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      final dropdownAfter = tester.widget<DropdownButton<LocalBatch>>(
        find.byType(DropdownButton<LocalBatch>).first,
      );
      expect(tester.takeException(), isNull);
      expect(dropdownAfter.value, isNotNull);
      expect(dropdownAfter.value!.id, 'b1');
      expect(dropdownAfter.value!.description, refreshedDescription);
    },
  );

  group('Batch Description', () {
    const description = 'Morning session, Room 204 - BSED applicants';

    void seedBatchWith(String value) {
      client.batchesToReturn = CloudBatchesRead.found([
        _batchRow(description: value),
      ]);
    }

    testWidgets(
      'a selected batch shows its own description under the dropdowns, results unaffected',
      (tester) async {
        seedBatchWith(description);
        await pumpResultsView(tester);
        expect(
          find.byKey(const Key('batchDescription')),
          findsNothing,
          reason: 'nothing selected yet',
        );

        await selectTheOnlyBatch(tester);

        expect(find.byKey(const Key('batchDescription')), findsOneWidget);
        expect(find.text('Batch Description'), findsOneWidget);
        expect(find.text(description), findsOneWidget);
        // The existing table, search and filter are all still there.
        expect(find.widgetWithText(TextButton, 'View'), findsNWidgets(2));
        expect(find.byKey(const Key('archiveBatchButton')), findsOneWidget);
      },
    );

    testWidgets(
      'the open dropdown lists the description under each batch, so similar batches are distinguishable',
      (tester) async {
        seedBatchWith(description);
        await pumpResultsView(tester);
        expect(find.text(description), findsNothing);

        await tester.tap(
          find.byType(DropdownButtonFormField<LocalBatch>).first,
        );
        await tester.pumpAndSettle();

        expect(find.text('B-1 — Admission Test (Jan 1, 2026)'), findsWidgets);
        expect(
          find.text(description),
          findsOneWidget,
          reason: 'shown as the option\'s second line',
        );
      },
    );

    testWidgets(
      'the description is the visual focus: larger and bolder than the batch name, in the open menu, '
      'the closed field and the strip',
      (tester) async {
        seedBatchWith(description);
        await pumpResultsView(tester);
        const nameLine = 'B-1 — Admission Test (Jan 1, 2026)';

        // Open menu: description on top, batch name below it and smaller.
        await tester.tap(
          find.byType(DropdownButtonFormField<LocalBatch>).first,
        );
        await tester.pumpAndSettle();
        final menuDescription = tester
            .widget<Text>(find.text(description))
            .style!;
        final menuName = tester.widget<Text>(find.text(nameLine).last).style!;
        expect(menuDescription.fontWeight, FontWeight.w700);
        expect(menuDescription.fontSize!, greaterThan(menuName.fontSize!));
        expect(
          menuName.fontSize!,
          greaterThanOrEqualTo(10),
          reason: 'the batch name stays clearly readable',
        );

        await tester.tap(find.text(nameLine).last);
        await tester.pumpAndSettle();

        // Closed field: one line, description first (larger, bold), name after it (smaller).
        final closed = tester.widget<Text>(
          find.byWidgetPredicate(
            (w) =>
                w is Text &&
                w.textSpan != null &&
                w.textSpan!.toPlainText().contains(description),
          ),
        );
        expect(closed.maxLines, 1);
        final spans = (closed.textSpan! as TextSpan).children!.cast<TextSpan>();
        expect(spans.first.text, description);
        expect(spans.first.style!.fontWeight, FontWeight.w700);
        expect(
          spans.first.style!.fontSize!,
          greaterThan(spans.last.style!.fontSize!),
        );
        expect(
          spans.last.text,
          contains(nameLine),
          reason: 'the batch name is still shown',
        );

        // Strip under the dropdowns: the largest, boldest text in the batch area.
        final strip = find.byKey(const Key('batchDescription'));
        final stripDescription = tester
            .widget<Text>(
              find.descendant(of: strip, matching: find.text(description)),
            )
            .style!;
        expect(stripDescription.fontWeight, FontWeight.w800);
        expect(stripDescription.fontSize!, greaterThanOrEqualTo(16));
        expect(
          stripDescription.fontSize!,
          greaterThan(menuDescription.fontSize!),
        );
        final caption = tester
            .widget<Text>(
              find.descendant(
                of: strip,
                matching: find.text('Batch Description'),
              ),
            )
            .style!;
        expect(stripDescription.fontSize!, greaterThan(caption.fontSize!));
      },
    );

    testWidgets(
      'a batch with no description keeps a readable single name line',
      (tester) async {
        seedBatchWith('');
        await pumpResultsView(tester);
        await tester.tap(
          find.byType(DropdownButtonFormField<LocalBatch>).first,
        );
        await tester.pumpAndSettle();
        final name = tester
            .widget<Text>(find.text('B-1 — Admission Test (Jan 1, 2026)').last)
            .style!;
        expect(
          name.fontSize,
          13,
          reason: 'batch names remain readable without a description',
        );
      },
    );

    testWidgets(
      'a batch with no description (or only spaces) adds nothing to the layout',
      (tester) async {
        for (final blank in ['', '   ']) {
          seedBatchWith(blank);
          await pumpResultsView(tester);
          await selectTheOnlyBatch(tester);

          expect(find.byKey(const Key('batchDescription')), findsNothing);
          expect(find.text('Batch Description'), findsNothing);
          expect(find.widgetWithText(TextButton, 'View'), findsNWidgets(2));
        }
      },
    );

    testWidgets(
      'an archived batch opened from the Web Archive shows its description too',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final batch = LocalBatch(
          id: 'b1',
          batchCode: 'B-1',
          examCode: 'AT',
          examTitle: 'Admission Test',
          description: description,
          expectedCount: 2,
          status: 'Completed',
          createdByUid: 'uid',
          createdByName: 'Officer',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GuidanceWebResultsView(
                service: GuidanceWebResultsService(client: client),
                archivedBatch: batch,
                onBackToArchive: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('(Archived)'), findsOneWidget);
        expect(find.byKey(const Key('batchDescription')), findsOneWidget);
        expect(find.text(description), findsOneWidget);
      },
    );
  });

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
    },
  );

  testWidgets(
    '7. Back to Results preserves the selected batch and its result list, no reload',
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
    },
  );

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
    },
  );

  group('18. Score sorting', () {
    Future<void> pumpWithScores(WidgetTester tester) async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(
          id: 's1',
          firstName: 'Juan',
          lastName: 'Cruz',
          number: 'A-1',
          rawScore: 30,
          examineeId: 'e1',
        ),
        _scanRow(
          id: 's2',
          firstName: 'Maria',
          lastName: 'Santos',
          number: 'A-2',
          rawScore: 80,
          examineeId: 'e2',
        ),
        _scanRow(
          id: 's3',
          firstName: 'Pedro',
          lastName: 'Reyes',
          number: 'A-3',
          rawScore: 50,
          examineeId: 'e3',
        ),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(
          id: 'e1',
          temporaryId: 'EX-000001',
          first: 'Juan',
          last: 'Cruz',
        ),
        _examineeRow(
          id: 'e2',
          temporaryId: 'EX-000002',
          first: 'Maria',
          last: 'Santos',
        ),
        _examineeRow(
          id: 'e3',
          temporaryId: 'EX-000003',
          first: 'Pedro',
          last: 'Reyes',
        ),
      ]);
      await pumpResultsView(tester);
      await selectTheOnlyBatch(tester);
    }

    double yOf(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dy;

    testWidgets('ascending = lowest to highest score', (tester) async {
      await pumpWithScores(tester);

      await tester.tap(
        find.byKey(const Key('scoreSortHeader')),
      ); // -> ascending
      await tester.pumpAndSettle();

      final yCruz = yOf(tester, 'Cruz, Juan'); // 30
      final yReyes = yOf(tester, 'Reyes, Pedro'); // 50
      final ySantos = yOf(tester, 'Santos, Maria'); // 80
      expect(yCruz, lessThan(yReyes));
      expect(yReyes, lessThan(ySantos));
    });

    testWidgets('descending = highest to lowest score', (tester) async {
      await pumpWithScores(tester);

      await tester.tap(
        find.byKey(const Key('scoreSortHeader')),
      ); // -> ascending
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('scoreSortHeader')),
      ); // -> descending
      await tester.pumpAndSettle();

      final yCruz = yOf(tester, 'Cruz, Juan'); // 30
      final yReyes = yOf(tester, 'Reyes, Pedro'); // 50
      final ySantos = yOf(tester, 'Santos, Maria'); // 80
      expect(ySantos, lessThan(yReyes));
      expect(yReyes, lessThan(yCruz));
    });

    testWidgets('a third tap returns to natural (unsorted) order', (
      tester,
    ) async {
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

    testWidgets('ungraded scans always sort last regardless of direction', (
      tester,
    ) async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(
          id: 's1',
          firstName: 'Juan',
          lastName: 'Cruz',
          number: 'A-1',
          rawScore: 30,
          examineeId: 'e1',
        ),
        _scanRow(
          id: 's2',
          firstName: 'Maria',
          lastName: 'Santos',
          number: 'A-2',
          resultStatus: null,
          examineeId: 'e2',
        ),
      ]);
      // client.examineesToReturn keeps setUp()'s default e1/e2 registration.
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
  group('linked examinees (scans.examinee_id -> examinees)', () {
    // The verified data shape: a linked scan keeps its OWN blank tag (the
    // mobile app auto-tags with a generated number and no names); the name
    // lives on the examinees row.
    void seedLinkedBatch() {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(
          id: 's1',
          firstName: '',
          lastName: '',
          number: 'EX-1790006562335-3',
          examineeId: 'e1',
        ),
        _scanRow(
          id: 's2',
          firstName: '',
          lastName: '',
          number: 'EX-1790006562335-4',
          examineeId: 'e2',
        ),
        _scanRow(
          id: 's3',
          firstName: 'Juan',
          lastName: 'Cruz',
          number: 'OLD-7',
        ),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(
          id: 'e1',
          temporaryId: 'EX-000004',
          first: 'Merch',
          middle: 'Valdez',
          last: 'Andulana',
        ),
        _examineeRow(
          id: 'e2',
          temporaryId: 'EX-000005',
          first: 'Maria',
          last: 'Santos',
        ),
      ]);
    }

    testWidgets(
      '1. UNLINKED SCAN NOW SHOWN -- a scan linked to an existing examinee, '
      'and one created with Confirm and Create, show the official examinee\'s '
      'name; an unlinked scan (with its own OCR/staff tag and a score) now '
      'appears too, with that tag shown as plain scan information and a '
      '"not linked" badge -- never styled as though it were official',
      (tester) async {
        seedLinkedBatch();
        await pumpResultsView(tester);
        await selectTheOnlyBatch(tester);

        expect(find.text('Andulana, Merch V.'), findsOneWidget);
        expect(find.text('Santos, Maria'), findsOneWidget);
        expect(
          find.text('Cruz, Juan'),
          findsOneWidget,
          reason:
              'the unlinked scan now appears, with its OCR/staff tag '
              'shown as plain scan information, never an official identity',
        );
        // Exactly one row (the unlinked one) carries the "not linked" badge.
        expect(find.byKey(const Key('notLinkedBadge')), findsOneWidget);
      },
    );

    testWidgets('an unlinked scan with no OCR/staff tag at all shows a plain '
        'placeholder, never an invented name -- and no examinees request is '
        'made since nothing in the batch is linked', (tester) async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(id: 's1', firstName: '', lastName: '', number: ''),
      ]);
      await pumpResultsView(tester);
      await selectTheOnlyBatch(tester);

      expect(find.text('No name on file'), findsOneWidget);
      expect(find.byKey(const Key('notLinkedBadge')), findsOneWidget);
      expect(
        client.examineeReads,
        0,
        reason: 'nothing linked -> no examinees request',
      );
    });

    testWidgets(
      'search matches the linked examinee\'s name and Temporary Examinee ID',
      (tester) async {
        seedLinkedBatch();
        await pumpResultsView(tester);
        await selectTheOnlyBatch(tester);

        await tester.enterText(find.byType(TextField), 'andulana');
        await tester.pumpAndSettle();
        expect(find.text('Andulana, Merch V.'), findsOneWidget);
        expect(find.text('Santos, Maria'), findsNothing);

        await tester.enterText(find.byType(TextField), 'EX-000005');
        await tester.pumpAndSettle();
        expect(find.text('Santos, Maria'), findsOneWidget);
        expect(find.text('Andulana, Merch V.'), findsNothing);
      },
    );

    testWidgets(
      'View opens the Detailed Result with the canonical examinee and the scan number as Scan ID',
      (tester) async {
        seedLinkedBatch();
        await pumpResultsView(tester);
        await selectTheOnlyBatch(tester);

        await tester.tap(find.widgetWithText(TextButton, 'View').first);
        await tester.pumpAndSettle();

        expect(find.text('Detailed Result'), findsOneWidget);
        expect(find.text('EX-000004'), findsOneWidget);
        expect(find.text('Merch'), findsOneWidget);
        expect(find.text('Valdez'), findsOneWidget);
        expect(find.text('Andulana'), findsOneWidget);
        expect(find.text('Scan ID'), findsOneWidget);
        expect(find.text('EX-1790006562335-3'), findsOneWidget);
      },
    );

    testWidgets(
      '3. OFFICIAL IDENTITY USED -- a scan linked to a resolvable examinee '
      'whose record has no usable name still appears (it IS officially '
      'linked, so it gets no "not linked" badge) but shows a plain '
      'placeholder, never falling back to the scan\'s own OCR/staff tag -- '
      'that fallback only ever applies to a scan with NO link at all',
      (tester) async {
        client.scansByBatchId['b1'] = CloudScansRead.found([
          _scanRow(
            id: 's1',
            firstName: 'Juan',
            lastName: 'Cruz',
            number: 'EX-9',
            examineeId: 'e1',
          ),
        ]);
        client.examineesToReturn = CloudExamineesRead.found([
          _examineeRow(id: 'e1', temporaryId: 'EX-000004', first: '', last: ''),
        ]);
        await pumpResultsView(tester);
        await selectTheOnlyBatch(tester);

        expect(find.text('Cruz, Juan'), findsNothing);
        expect(find.text('No name on file'), findsOneWidget);
        expect(
          find.byKey(const Key('notLinkedBadge')),
          findsNothing,
          reason:
              'the scan IS linked -- a blank official name is not the '
              'same as being unlinked, and must not show the "not linked" badge',
        );
      },
    );

    testWidgets(
      'if the examinee lookup fails the page reports it instead of showing linked scans as Unnamed',
      (tester) async {
        seedLinkedBatch();
        client.examineesToReturn = const CloudExamineesRead.failed(
          SyncOutcome.transient('network'),
        );
        await pumpResultsView(tester);
        await selectTheOnlyBatch(tester);

        expect(find.textContaining('Could not reach Supabase'), findsOneWidget);
        expect(find.text('Unnamed'), findsNothing);
      },
    );
  });

  group(
    'Applicant Retake Management -- archived attempts excluded by default',
    () {
      testWidgets(
        'an archived Attempt 1 does not appear in the Results table',
        (tester) async {
          client.scansByBatchId['b1'] = CloudScansRead.found([
            _scanRow(
              id: 's-old',
              firstName: 'Juan',
              lastName: 'Cruz',
              number: 'A-1',
              attemptNo: 1,
              attemptStatus: 'archived',
            ),
          ]);
          await pumpResultsView(tester);
          await selectTheOnlyBatch(tester);

          expect(find.text('Cruz, Juan'), findsNothing);
        },
      );

      testWidgets('an active Attempt 2 appears in the Results table', (
        tester,
      ) async {
        client.scansByBatchId['b1'] = CloudScansRead.found([
          _scanRow(
            id: 's-old',
            firstName: 'Juan',
            lastName: 'Cruz',
            number: 'A-1',
            attemptNo: 1,
            attemptStatus: 'archived',
          ),
          _scanRow(
            id: 's-new',
            firstName: 'Juan',
            lastName: 'Cruz',
            number: 'A-1',
            attemptNo: 2,
            attemptStatus: 'active',
            examineeId: 'e1',
          ),
        ]);
        // client.examineesToReturn keeps setUp()'s default e1 = Juan Cruz.
        await pumpResultsView(tester);
        await selectTheOnlyBatch(tester);

        expect(find.text('Cruz, Juan'), findsOneWidget);
      });

      testWidgets(
        'an ordinary active Attempt 1 (no retake) appears, exactly as before',
        (tester) async {
          client.scansByBatchId['b1'] = CloudScansRead.found([
            _scanRow(
              id: 's1',
              firstName: 'Juan',
              lastName: 'Cruz',
              number: 'A-1',
              examineeId: 'e1',
            ), // default: attempt 1, active
          ]);
          // client.examineesToReturn keeps setUp()'s default e1 = Juan Cruz.
          await pumpResultsView(tester);
          await selectTheOnlyBatch(tester);

          expect(find.text('Cruz, Juan'), findsOneWidget);
        },
      );

      testWidgets('QTM behavior is unchanged', (tester) async {
        client.batchesToReturn = CloudBatchesRead.found([
          _batchRow(
            id: 'q1',
            batchCode: 'Q-1',
            examCode: 'QTM',
            examTitle: 'QTM',
          ),
        ]);
        client.scansByBatchId['q1'] = CloudScansRead.found([
          _scanRow(
            id: 'sq1',
            firstName: 'Ana',
            lastName: 'Reyes',
            number: 'Q-A1',
            batchId: 'q1',
            examCode: 'QTM',
            examineeId: 'e_qtm',
          ),
        ]);
        client.examineesToReturn = CloudExamineesRead.found([
          _examineeRow(
            id: 'e_qtm',
            temporaryId: 'EX-Q1',
            first: 'Ana',
            last: 'Reyes',
          ),
        ]);
        await pumpResultsView(tester);

        await tester.tap(find.byKey(const Key('examTab_QTM')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byType(DropdownButtonFormField<LocalBatch>).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Q-1 — QTM (Jan 1, 2026)').last);
        await tester.pumpAndSettle();

        expect(find.text('Reyes, Ana'), findsOneWidget);
      });
    },
  );

  group('8. Archived Results -- the shared GuidanceWebResultsView/'
      'GuidanceWebResultsService linked/unlinked identity resolution applies '
      'identically for an archived batch', () {
    Future<void> pumpArchivedBatch(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final batch = LocalBatch(
        id: 'b1',
        batchCode: 'B-1',
        examCode: 'AT',
        examTitle: 'Admission Test',
        description: '',
        expectedCount: 2,
        status: 'Completed',
        createdByUid: 'uid',
        createdByName: 'Officer',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceWebResultsView(
              service: GuidanceWebResultsService(client: client),
              archivedBatch: batch,
              onBackToArchive: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a linked scan is shown with its official identity, and an '
        'unlinked scan is shown too with its OCR tag and a "not linked" '
        'badge, exactly as in the normal (non-archived) Results view -- no '
        'special-case archive behavior exists or is needed', (tester) async {
      client.scansByBatchId['b1'] = CloudScansRead.found([
        _scanRow(
          id: 's_linked',
          firstName: '',
          lastName: '',
          number: 'EX-1',
          examineeId: 'e1',
        ),
        _scanRow(
          id: 's_unlinked',
          firstName: 'Ana',
          lastName: 'Lim',
          number: 'OLD-7',
        ),
      ]);
      client.examineesToReturn = CloudExamineesRead.found([
        _examineeRow(
          id: 'e1',
          temporaryId: 'EX-000004',
          first: 'Merch',
          last: 'Andulana',
        ),
      ]);

      await pumpArchivedBatch(tester);

      expect(find.text('Andulana, Merch'), findsOneWidget);
      expect(find.text('Lim, Ana'), findsOneWidget);
      expect(find.byKey(const Key('notLinkedBadge')), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'View'), findsNWidgets(2));
    });
  });
}
