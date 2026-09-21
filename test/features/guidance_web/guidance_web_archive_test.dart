import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/cloud_batch_mapper.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_archive_view.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_results_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_archive_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_examinee_records_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/examinee_record.dart';
import 'package:guidegrade/models/local_batch.dart';

/// A stateful stand-in for Supabase: `batches`, `scans`, and `batch_archives`.
/// [archiveBatch] only ever adds a `batch_archives` row -- it has no access to
/// `batches`/`scans` state at all, mirroring the real INSERT.
class _FakeClient implements SyncClient {
  final List<CloudBatchRow> batches = [];
  final Map<String, List<CloudScanRow>> scansByBatch = {};
  final List<CloudBatchArchiveRow> archives = [];
  final Map<String, CloudScansRead> scansByExamineeId = {};
  CloudScansRead unlinkedScans = CloudScansRead.found(const []);

  /// When set, [archiveBatch] returns it verbatim (and adds no row).
  SyncOutcome? archiveOverride;
  String? lastArchiveBatchId;
  String? lastArchiveReason;
  final List<String> calls = [];

  Never _no(String label) {
    calls.add(label);
    throw StateError('must never call $label');
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('readCloudBatches');
    return CloudBatchesRead.found(List.of(batches));
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    calls.add('readCloudScans:$batchId');
    return CloudScansRead.found(List.of(scansByBatch[batchId] ?? const []));
  }

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async {
    calls.add('readBatchArchives');
    return CloudBatchArchivesRead.found(List.of(archives));
  }

  @override
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason}) async {
    calls.add('archiveBatch:$batchId');
    lastArchiveBatchId = batchId;
    lastArchiveReason = reason;
    if (archiveOverride != null) return archiveOverride!;
    // The real database's insert policy / primary key.
    final batch = batches.where((b) => b.id == batchId).toList();
    if (batch.isEmpty || batch.first.status != 'Completed') {
      return const SyncOutcome.permanent('42501');
    }
    if (archives.any((a) => a.batchId == batchId)) {
      return const SyncOutcome.permanent('23505');
    }
    archives.add(CloudBatchArchiveRow(
      batchId: batchId,
      archivedAt: DateTime.utc(2026, 3, 1),
      archivedByUid: 'uid-1',
      archivedByName: 'Council Member',
      reason: reason,
    ));
    return const SyncOutcome.success();
  }

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) async {
    calls.add('readScanCounts');
    return CloudScanCountsRead.found({
      for (final id in batchIds) id: (scansByBatch[id] ?? const []).length,
    });
  }

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) async {
    calls.add('readCloudScansForExaminee:$examineeId');
    return scansByExamineeId[examineeId] ?? CloudScansRead.found(const []);
  }

  @override
  Future<CloudScansRead> readUnlinkedScans() async {
    calls.add('readUnlinkedScans');
    return unlinkedScans;
  }

  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    calls.add('readAnswerKey:$examCode');
    return const CloudAnswerKeyRead.absent();
  }

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
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
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
}

CloudBatchRow _batch({
  required String id,
  String code = '',
  String examCode = 'AT',
  String status = 'Completed',
}) =>
    CloudBatchRow(
      id: id,
      batchCode: code.isEmpty ? 'B-$id' : code,
      examCode: examCode,
      examTitle: 'Title $examCode',
      description: '',
      expectedCount: 10,
      status: status,
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 2),
    );

CloudScanRow _scan(String id, String batchId, {String examCode = 'AT', int rawScore = 50, String first = 'Juan'}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: rawScore,
      totalGraded: 72,
      totalItems: 72,
      resultStatus: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'uid',
      processedByName: 'Officer',
      firstName: first,
      lastName: 'Dela Cruz',
      examineeNumber: 'EX-legacy-$id',
    );

void main() {
  late _FakeClient client;
  late GuidanceWebArchiveService archiveService;
  late GuidanceWebResultsService resultsService;

  setUp(() {
    client = _FakeClient();
    archiveService = GuidanceWebArchiveService(client: client);
    resultsService = GuidanceWebResultsService(client: client);
  });

  void seed() {
    client.batches.addAll([
      _batch(id: 'b1', code: 'BATCH-ONE'),
      _batch(id: 'b2', code: 'BATCH-TWO'),
      _batch(id: 'b3', code: 'BATCH-ACTIVE', status: 'Active'),
      _batch(id: 'b4', code: 'BATCH-DRAFT', status: 'Draft'),
    ]);
    client.scansByBatch['b1'] = [_scan('s1', 'b1', rawScore: 61), _scan('s2', 'b1', first: 'Maria')];
    client.scansByBatch['b2'] = [_scan('s3', 'b2')];
  }

  Future<dynamic> localBatch(String id) async =>
      (await resultsService.loadBatches()).firstWhere((b) => b.id == id);

  group('Archive eligibility', () {
    test('a Completed batch can be archived (marker inserted with the reason)', () async {
      seed();
      await archiveService.archiveBatch(await localBatch('b1'), reason: 'Batch processed');
      expect(client.archives.single.batchId, 'b1');
      expect(client.lastArchiveReason, 'Batch processed');
    });

    for (final status in ['Active', 'Draft']) {
      test('a $status batch cannot be archived and no marker is written', () async {
        seed();
        final id = status == 'Active' ? 'b3' : 'b4';
        await expectLater(
          archiveService.archiveBatch(await localBatch(id)),
          throwsA(isA<GuidanceWebArchiveException>().having(
              (e) => e.message, 'message', contains('Only completed batches can be archived'))),
        );
        expect(client.archives, isEmpty);
        expect(client.calls.where((c) => c.startsWith('archiveBatch')), isEmpty);
      });
    }

    test('eligibility is re-verified against the database, not a stale in-memory status', () async {
      seed();
      final stale = await localBatch('b1'); // loaded while Completed
      final i = client.batches.indexWhere((b) => b.id == 'b1');
      client.batches[i] = _batch(id: 'b1', code: 'BATCH-ONE', status: 'Active'); // changed since
      await expectLater(
        archiveService.archiveBatch(stale),
        throwsA(isA<GuidanceWebArchiveException>()),
      );
      expect(client.archives, isEmpty);
    });

    test('an already archived batch cannot be archived twice', () async {
      seed();
      final batch = await localBatch('b1');
      await archiveService.archiveBatch(batch);
      await expectLater(
        archiveService.archiveBatch(batch),
        throwsA(isA<GuidanceWebArchiveException>()
            .having((e) => e.message, 'message', contains('already archived'))),
      );
      expect(client.archives, hasLength(1));
    });

    test('a database duplicate (race) becomes a friendly message, never a raw code', () async {
      seed();
      client.archiveOverride = const SyncOutcome.permanent('23505');
      Object? error;
      try {
        await archiveService.archiveBatch(await localBatch('b1'));
      } catch (e) {
        error = e;
      }
      final message = (error as GuidanceWebArchiveException).message;
      expect(message, contains('already archived'));
      expect(message, isNot(contains('23505')));
    });

    test('a batch that no longer exists cannot be archived', () async {
      seed();
      final batch = await localBatch('b1');
      client.batches.removeWhere((b) => b.id == 'b1');
      await expectLater(
        archiveService.archiveBatch(batch),
        throwsA(isA<GuidanceWebArchiveException>()
            .having((e) => e.message, 'message', contains('no longer exists'))),
      );
    });
  });

  group('After archiving', () {
    test('the batch is listed in Archive and marked archived, with scan count and actor', () async {
      seed();
      await archiveService.archiveBatch(await localBatch('b1'));
      final entries = await archiveService.loadArchivedBatches();
      expect(entries, hasLength(1));
      expect(entries.single.batch.id, 'b1');
      expect(entries.single.scanCount, 2);
      expect(entries.single.archive.archivedByName, 'Council Member');
      expect((await resultsService.loadArchivedBatchIds()), {'b1'});
    });

    test('the underlying batch, its status, scans, scores and answers are untouched', () async {
      seed();
      final before = client.batches.map((b) => (b.id, b.status, b.updatedAt)).toList();
      final scansBefore = (await resultsService.loadScansForBatch(await localBatch('b1')))
          .map((s) => (s.id, s.result?.rawScore, s.decoded.items.length))
          .toList();

      await archiveService.archiveBatch(await localBatch('b1'));

      // batches.status / updated_at exactly as before (the marker is separate).
      expect(client.batches.map((b) => (b.id, b.status, b.updatedAt)).toList(), before);
      expect(client.batches.firstWhere((b) => b.id == 'b1').status, 'Completed');
      // Still readable through the same calls Results uses -- no unarchive step.
      expect((await resultsService.loadBatches()).any((b) => b.id == 'b1'), isTrue);
      final scansAfter = (await resultsService.loadScansForBatch(await localBatch('b1')))
          .map((s) => (s.id, s.result?.rawScore, s.decoded.items.length))
          .toList();
      expect(scansAfter, scansBefore);
      expect(scansAfter.first.$2, 61);
    });

    test('archiving performs no push, upload, delete, or link operation', () async {
      seed();
      await archiveService.archiveBatch(await localBatch('b1'));
      await archiveService.loadArchivedBatches();
      for (final call in client.calls) {
        expect(call, isNot(startsWith('push')));
        expect(call, isNot(startsWith('upload')));
        expect(call, isNot(startsWith('delete')));
        expect(call, isNot(contains('link')));
      }
    });

    test('the marker is independent of batches.status: a later mobile status change leaves it archived',
        () async {
      seed();
      await archiveService.archiveBatch(await localBatch('b1'));
      // Simulate a mobile sync pushing a different status for the batch.
      final i = client.batches.indexWhere((b) => b.id == 'b1');
      client.batches[i] = _batch(id: 'b1', code: 'BATCH-ONE', status: 'Archived');
      expect(await resultsService.loadArchivedBatchIds(), {'b1'});
      expect((await archiveService.loadArchivedBatches()).single.batch.status, 'Archived');
    });
  });

  group('Examinee Records and Unlinked Scans keep archived-batch data', () {
    test('examinee history still includes scans from an archived batch', () async {
      seed();
      await archiveService.archiveBatch(await localBatch('b1'));
      client.scansByExamineeId['e1'] = CloudScansRead.found([client.scansByBatch['b1']!.first]);
      client.calls.clear(); // only what the Examinee Records service does from here
      final service = GuidanceWebExamineeRecordsService(client: client);
      final history = await service.loadHistoryFor(ExamineeRecord(
        id: 'e1',
        temporaryExamineeId: 'EX-000001',
        firstName: 'Juan',
        lastName: 'Dela Cruz',
        status: 'active',
        createdAt: DateTime.utc(2026, 1, 1),
        createdByUid: 'u',
        updatedAt: DateTime.utc(2026, 1, 1),
        updatedByUid: 'u',
      ));
      expect(history.single.scan.id, 's1');
      expect(history.single.batch.id, 'b1');
      expect(client.calls, isNot(contains('readBatchArchives')));
    });

    test('Unlinked Scans still lists an unlinked scan whose batch is archived', () async {
      seed();
      await archiveService.archiveBatch(await localBatch('b1'));
      client.unlinkedScans = CloudScansRead.found([client.scansByBatch['b1']!.last]);
      client.calls.clear();
      final unlinked = await GuidanceWebExamineeRecordsService(client: client).loadUnlinkedScans();
      expect(unlinked.single.scan.id, 's2');
      expect(unlinked.single.batch.id, 'b1');
      expect(client.calls, isNot(contains('readBatchArchives')));
    });
  });

  group('Web Results page', () {
    Future<void> pumpResults(WidgetTester tester, {Widget? home}) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: home ??
              GuidanceWebResultsView(service: resultsService, archiveService: archiveService, refreshInterval: null),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> pickAtBatch(WidgetTester tester, String code) async {
      await tester.tap(find.byType(DropdownButtonFormField<LocalBatch>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(code).last);
      await tester.pumpAndSettle();
    }

    testWidgets('archived batches are excluded from the normal Results list', (tester) async {
      seed();
      client.archives.add(CloudBatchArchiveRow(
        batchId: 'b1',
        archivedAt: DateTime.utc(2026, 3, 1),
        archivedByUid: 'u',
      ));
      await pumpResults(tester);

      await tester.tap(find.byType(DropdownButtonFormField<LocalBatch>).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('BATCH-TWO'), findsWidgets);
      expect(find.textContaining('BATCH-ONE'), findsNothing);
    });

    testWidgets('a Completed batch: confirmation, then it leaves Results and joins Archive', (tester) async {
      seed();
      await pumpResults(tester);
      await pickAtBatch(tester, 'BATCH-ONE');

      await tester.tap(find.byKey(const Key('archiveBatchButton')));
      await tester.pumpAndSettle();
      expect(find.text('Archive this completed batch?'), findsOneWidget);
      expect(find.textContaining('removed from the normal Results list and moved to Archive'), findsOneWidget);
      expect(client.calls.where((c) => c.startsWith('archiveBatch')), isEmpty); // not yet

      await tester.enterText(find.byKey(const Key('archiveReasonField')), 'Done');
      await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
      await tester.pumpAndSettle();

      expect(client.lastArchiveBatchId, 'b1');
      expect(client.lastArchiveReason, 'Done');
      expect(client.archives.single.batchId, 'b1');
      // Gone from the normal list.
      await tester.tap(find.byType(DropdownButtonFormField<LocalBatch>).first);
      await tester.pumpAndSettle();
      final items = find.byType(DropdownMenuItem<LocalBatch>);
      expect(find.descendant(of: items, matching: find.textContaining('BATCH-ONE')), findsNothing);
      expect(find.descendant(of: items, matching: find.textContaining('BATCH-TWO')), findsWidgets);
      // The batch and its scans still exist.
      expect(client.batches.any((b) => b.id == 'b1'), isTrue);
      expect(client.scansByBatch['b1'], hasLength(2));
    });

    testWidgets('Cancel leaves the batch un-archived', (tester) async {
      seed();
      await pumpResults(tester);
      await pickAtBatch(tester, 'BATCH-ONE');
      await tester.tap(find.byKey(const Key('archiveBatchButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(client.archives, isEmpty);
      expect(client.calls.where((c) => c.startsWith('archiveBatch')), isEmpty);
    });

    testWidgets('an Active batch cannot be archived and the user is told why', (tester) async {
      seed();
      await pumpResults(tester);
      await pickAtBatch(tester, 'BATCH-ACTIVE');
      await tester.tap(find.byKey(const Key('archiveBatchButton')));
      await tester.pumpAndSettle();

      expect(find.text('Cannot Archive This Batch'), findsOneWidget);
      expect(find.textContaining('Only completed batches can be archived'), findsOneWidget);
      expect(client.calls.where((c) => c.startsWith('archiveBatch')), isEmpty);
      expect(client.archives, isEmpty);
    });

    testWidgets('a failed archive keeps the batch in Results and shows a friendly message', (tester) async {
      seed();
      client.archiveOverride = const SyncOutcome.permanent('42501');
      await pumpResults(tester);
      await pickAtBatch(tester, 'BATCH-ONE');
      await tester.tap(find.byKey(const Key('archiveBatchButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be archived'), findsOneWidget);
      expect(find.textContaining('42501'), findsNothing);
      expect(client.archives, isEmpty);
    });

    testWidgets('an archived batch opened in archive mode reuses the Results table and has no Archive action',
        (tester) async {
      seed();
      final batch = await localBatch('b1');
      await pumpResults(
        tester,
        home: GuidanceWebResultsView(
          service: resultsService,
          archivedBatch: batch,
          onBackToArchive: () {},
        ),
      );
      expect(find.textContaining('(Archived)'), findsOneWidget);
      expect(find.text('Back to Archive'), findsOneWidget);
      expect(find.text('Dela Cruz, Juan'), findsWidgets); // the same scan table
      expect(find.byKey(const Key('archiveBatchButton')), findsNothing);
      expect(find.text('Restore'), findsNothing);
    });
  });

  group('Web Archive page', () {
    Future<void> pumpArchive(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GuidanceWebArchiveView(service: archiveService, resultsService: resultsService),
        ),
      ));
      await tester.pumpAndSettle();
    }

    void archiveTwo() {
      seed();
      client.batches.add(_batch(id: 'b5', code: 'BATCH-TAT', examCode: 'TAT'));
      client.archives
        ..add(CloudBatchArchiveRow(
            batchId: 'b1', archivedAt: DateTime.utc(2026, 3, 1), archivedByUid: 'u', archivedByName: 'Council Member'))
        ..add(CloudBatchArchiveRow(batchId: 'b5', archivedAt: DateTime.utc(2026, 3, 2), archivedByUid: 'u'));
    }

    testWidgets('lists archived batches with code, exam, scans, status, date and archived by', (tester) async {
      archiveTwo();
      await pumpArchive(tester);
      expect(find.text('BATCH-ONE'), findsOneWidget);
      expect(find.text('BATCH-TAT'), findsOneWidget);
      expect(find.text('BATCH-TWO'), findsNothing); // not archived
      expect(find.text('Mar 1, 2026'), findsOneWidget);
      expect(find.text('Council Member'), findsOneWidget);
      expect(find.text('Completed'), findsWidgets);
    });

    testWidgets('search and exam-type filter narrow the list', (tester) async {
      archiveTwo();
      await pumpArchive(tester);
      await tester.enterText(find.byType(TextField), 'TAT');
      await tester.pumpAndSettle();
      expect(find.text('BATCH-TAT'), findsOneWidget);
      expect(find.text('BATCH-ONE'), findsNothing);
    });

    testWidgets('View opens the existing Results table for that batch; Back returns', (tester) async {
      archiveTwo();
      await pumpArchive(tester);
      await tester.tap(find.widgetWithText(TextButton, 'View').first);
      await tester.pumpAndSettle();
      // newest archive first -> BATCH-TAT; open BATCH-ONE instead for scans
      await tester.tap(find.text('Back to Archive'));
      await tester.pumpAndSettle();
      final rows = find.widgetWithText(TextButton, 'View');
      await tester.tap(rows.last);
      await tester.pumpAndSettle();
      expect(find.text('Dela Cruz, Juan'), findsWidgets);
      expect(find.text('Dela Cruz, Maria'), findsWidgets);

      await tester.tap(find.text('Back to Archive'));
      await tester.pumpAndSettle();
      expect(find.text('BATCH-ONE'), findsOneWidget);
    });

    testWidgets('shows an empty state when nothing is archived', (tester) async {
      seed();
      await pumpArchive(tester);
      expect(find.text('No archived batches yet.'), findsOneWidget);
    });

    testWidgets('an archive list has no Restore or Unarchive button', (tester) async {
      archiveTwo();
      await pumpArchive(tester);
      expect(find.textContaining('Restore'), findsNothing);
      expect(find.textContaining('Unarchive'), findsNothing);
    });
  });

  group('No Restore workflow anywhere in the Web Archive', () {
    test('the archive service, view, and migration contain no restore/unarchive logic', () {
      for (final path in [
        'lib/features/guidance_web/services/guidance_web_archive_service.dart',
        'lib/features/guidance_web/screens/guidance_web_archive_view.dart',
        'lib/models/batch_archive.dart',
        'supabase/migrations/0007_create_batch_archives.sql',
      ]) {
        final text = File(path).readAsStringSync().toLowerCase();
        // Comments may say "there is no restore"; forbid actual restore
        // identifiers/actions instead.
        expect(text, isNot(contains('restorebatch')), reason: path);
        expect(text, isNot(contains('unarchivebatch')), reason: path);
        expect(text, isNot(contains('batch_restored')), reason: path);
        expect(text, isNot(contains("'restore'")), reason: path);
        expect(text, isNot(contains('child: const text(\'restore')), reason: path);
      }
    });
  });

  test('mapCloudBatch keeps the cloud status untouched (Web Archive never rewrites it)', () {
    final mapped = mapCloudBatch(_batch(id: 'x', status: 'Completed'));
    expect(mapped.status, 'Completed');
  });
}
