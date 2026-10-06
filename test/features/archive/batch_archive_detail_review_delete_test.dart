import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_manager.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/features/archive/screens/batch_archive_detail_screen.dart';
import 'package:guidegrade/features/guidance/widgets/batch_list_item.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

OmrScanResult _decoded({required bool flagged}) => OmrScanResult(
  examCode: 'AT',
  items: [
    const OmrItemResult(
      sectionName: 'Section 1',
      itemNumber: 1,
      markedChoice: 'B',
    ),
    OmrItemResult(
      sectionName: 'Section 1',
      itemNumber: 2,
      markedChoice: null,
      isAmbiguous: flagged,
    ),
  ],
);

LocalScan _scan(String id, {bool flagged = false, String? first}) => LocalScan(
  id: id,
  imageFileName: 'images/$id.enc',
  capturedAt: DateTime.utc(2026, 9, 1),
  decoded: _decoded(flagged: flagged),
  examinee: first == null
      ? null
      : ExamineeInfo(
          firstName: first,
          lastName: 'Cruz',
          middleName: '',
          examineeNumber: 'X-$id',
        ),
);

LocalBatch _batch(List<LocalScan> scans, {String status = 'Archived'}) =>
    LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: 'Morning batch',
      expectedCount: 10,
      status: status,
      createdByUid: 'u',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
      scans: scans,
    );

class _Repo implements BatchRepository {
  _Repo(this.batch);
  LocalBatch batch;
  bool failDelete = false;
  final deleted = <String>[];

  /// The exact deletion metadata the screen passed through for the most
  /// recent (successful or attempted) delete call -- null until a delete is
  /// attempted.
  Map<String, String?>? lastDeleteCall;

  @override
  Future<LocalBatch?> getBatchById(String id) async => batch;

  @override
  Future<LocalBatch> deleteScan({
    required String batchId,
    required String scanId,
    String? deletedByUid,
    String? deletedByName,
    String? reason,
  }) async {
    lastDeleteCall = {
      'batchId': batchId,
      'scanId': scanId,
      'deletedByUid': deletedByUid,
      'deletedByName': deletedByName,
      'reason': reason,
    };
    if (failDelete) throw StateError('disk full');
    deleted.add(scanId);
    batch = batch.copyWith(
      scans: batch.scans.where((s) => s.id != scanId).toList(),
      updatedAt: batch.updatedAt.add(const Duration(milliseconds: 1)),
    );
    return batch;
  }

  @override
  Future<Uint8List?> resolveScanImage(String batchId, LocalScan scan) async =>
      null;
  @override
  Future<Uint8List?> resolveScanRectifiedImage(
    String batchId,
    LocalScan scan,
  ) async => null;
  @override
  Future<Uint8List?> resolveScanNameCropLast(
    String batchId,
    LocalScan scan,
  ) async => null;
  @override
  Future<Uint8List?> resolveScanNameCropFirst(
    String batchId,
    LocalScan scan,
  ) async => null;
  @override
  Future<Uint8List?> resolveScanNameCropMiddle(
    String batchId,
    LocalScan scan,
  ) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal fake [SyncClient] for the canonical-Examinee-display tests below
/// -- only `readCloudScans`/`readCloudExaminees` are ever exercised by
/// [resolveLinkedExaminees] (see `mobile_examinee_resolver_test.dart` for
/// the resolver's own focused unit tests); every other method throws.
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
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) =>
      _no('readAnswerKey');
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
  Future<CloudBatchArchivesRead> readBatchArchives() =>
      _no('readBatchArchives');
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

CloudScanRow _cloudScan(String id, {String? examineeId}) => CloudScanRow(
  id: id,
  batchId: 'b1',
  examCode: 'AT',
  capturedAt: DateTime.utc(2026, 9, 1),
  decoded: const {},
  examineeId: examineeId,
);

CloudExamineeRow _cloudExaminee(
  String id, {
  required String temporaryExamineeId,
}) => CloudExamineeRow(
  id: id,
  temporaryExamineeId: temporaryExamineeId,
  firstName: 'Juan Carlos',
  lastName: 'Dela Cruz',
  status: 'active',
  createdAt: DateTime.utc(2026, 9, 1),
  createdByUid: 'u1',
  updatedAt: DateTime.utc(2026, 9, 1),
  updatedByUid: 'u1',
);

void main() {
  Future<void> pump(
    WidgetTester tester,
    _Repo repo, {
    SyncManager? syncManager,
  }) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appState = AppState(batchRepository: repo, syncManager: syncManager);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppStateScope(notifier: appState, child: child!),
        home: const BatchArchiveDetailScreen(batchId: 'b1'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Completed scans keep View Scan but hide modification actions', (
    tester,
  ) async {
    final repo = _Repo(_batch([_scan('s1')], status: 'Completed'));
    await pump(tester, repo);
    expect(find.text('Edit student'), findsNothing);
    expect(find.text('Tag student'), findsNothing);
    expect(find.text('Rescan'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    expect(find.text('View Scan'), findsOneWidget);
    expect(repo.deleted, isEmpty);
  });

  testWidgets('Active batch deletion requires opening its action menu', (
    tester,
  ) async {
    var deleted = false;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatchListItem(
            batch: _batch([], status: 'Active'),
            onTap: () => opened = true,
            onDelete: () => deleted = true,
          ),
        ),
      ),
    );
    expect(find.text('Delete batch'), findsNothing);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(deleted, isFalse);
    expect(opened, isFalse);
    await tester.tap(find.text('Delete batch'));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
    expect(opened, isFalse);
  });

  testWidgets('Completed batch exposes no deletion menu', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatchListItem(
            batch: _batch([], status: 'Completed'),
            onTap: () {},
            onDelete: () {},
          ),
        ),
      ),
    );
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
  });

  group('batch card', () {
    testWidgets(
      'shows a Needs review indicator with the affected-sheet count',
      (tester) async {
        final batch = _batch([
          _scan('s1', flagged: true),
          _scan('s2', flagged: true),
          _scan('s3'),
        ]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BatchListItem(batch: batch, onTap: () {}, onDelete: () {}),
            ),
          ),
        );
        expect(find.text('Needs review · 2'), findsOneWidget);
        expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      },
    );

    testWidgets('a batch with only wrong/blank answers shows no indicator', (
      tester,
    ) async {
      final batch = _batch([_scan('s1'), _scan('s2')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatchListItem(batch: batch, onTap: () {}, onDelete: () {}),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('needs-review-chip')), findsNothing);
    });
  });

  group('archived batch detail', () {
    testWidgets('lists the sheets that need review', (tester) async {
      final repo = _Repo(
        _batch([
          _scan('s1', first: 'Ana'),
          _scan('s2', flagged: true, first: 'Ben'),
          _scan('s3'),
        ]),
      );
      await pump(tester, repo);

      final banner = find.byKey(const ValueKey('needs-review-banner'));
      expect(banner, findsOneWidget);
      expect(
        find.descendant(
          of: banner,
          matching: find.textContaining('1 sheet needs review'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: banner, matching: find.textContaining('Ben')),
        findsOneWidget,
      );
    });

    Future<void> enterReasonAndSubmit(
      WidgetTester tester,
      String reason,
    ) async {
      await tester.enterText(
        find.byKey(const Key('mobileSoftDeleteReasonField')),
        reason,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'delete asks first, names the sheet, requires a reason, and Cancel deletes nothing',
      (tester) async {
        final repo = _Repo(
          _batch([_scan('s1', first: 'Ana'), _scan('s2', first: 'Ben')]),
        );
        await pump(tester, repo);

        await tester.tap(find.byKey(const ValueKey('delete-scan-s2')));
        await tester.pumpAndSettle();

        expect(find.text('Delete This Sheet?'), findsOneWidget);
        expect(find.textContaining('Sheet 2'), findsWidgets);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining(
              repo.batch.scans[1].examinee!.displayName,
            ),
          ),
          findsOneWidget,
        );
        // Copy no longer claims an immediate permanent cloud deletion -- it
        // explicitly says the opposite ("not permanently deleted right away").
        expect(find.textContaining('permanently deleted from'), findsNothing);
        expect(find.textContaining('retained for 30 days'), findsOneWidget);
        expect(
          find.byKey(const Key('mobileSoftDeleteReasonField')),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(repo.deleted, isEmpty);
        expect(repo.lastDeleteCall, isNull);
        expect(find.byKey(const ValueKey('delete-scan-s2')), findsOneWidget);
      },
    );

    testWidgets('a blank/whitespace-only reason cannot be submitted', (
      tester,
    ) async {
      final repo = _Repo(_batch([_scan('s1', first: 'Ana')]));
      await pump(tester, repo);

      await tester.tap(find.byKey(const ValueKey('delete-scan-s1')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('mobileSoftDeleteReasonField')),
        '   ',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('A reason is required'), findsOneWidget);
      expect(
        find.text('Delete This Sheet?'),
        findsOneWidget,
      ); // dialog still open
      expect(repo.deleted, isEmpty);
      expect(repo.lastDeleteCall, isNull);
    });

    testWidgets(
      'confirming with a valid reason deletes only that sheet; warning and counts update; '
      'status stays Archived',
      (tester) async {
        final repo = _Repo(
          _batch([
            _scan('s1', first: 'Ana'),
            _scan('s2', flagged: true, first: 'Ben'),
          ]),
        );
        await pump(tester, repo);
        expect(
          find.byKey(const ValueKey('needs-review-banner')),
          findsOneWidget,
        );
        expect(find.text('Archived'), findsWidgets);

        await tester.tap(find.byKey(const ValueKey('delete-scan-s2')));
        await tester.pumpAndSettle();
        await enterReasonAndSubmit(tester, 'Duplicate capture');

        expect(repo.deleted, ['s2']);
        expect(find.byKey(const ValueKey('delete-scan-s1')), findsOneWidget);
        expect(find.byKey(const ValueKey('delete-scan-s2')), findsNothing);
        expect(
          find.byKey(const ValueKey('needs-review-banner')),
          findsNothing,
          reason: 'no flagged sheet is left',
        );
        expect(find.text('Archived'), findsWidgets);
        expect(find.text('Sheet 2 removed from this device.'), findsOneWidget);
      },
    );

    testWidgets(
      'the entered reason (trimmed) reaches the repository, along with a non-user-entered '
      'actor uid',
      (tester) async {
        final repo = _Repo(_batch([_scan('s1', first: 'Ana')]));
        await pump(tester, repo);

        await tester.tap(find.byKey(const ValueKey('delete-scan-s1')));
        await tester.pumpAndSettle();
        await enterReasonAndSubmit(tester, '  Duplicate capture  ');

        expect(repo.lastDeleteCall, isNotNull);
        final call = repo.lastDeleteCall!;
        expect(call['batchId'], 'b1');
        expect(call['scanId'], 's1');
        expect(call['reason'], 'Duplicate capture');
        // No Firebase app is initialized in this widget test, so the
        // try/catch-guarded identity resolution falls back to an empty uid --
        // never a value typed anywhere in this test (there is no UID input
        // field on this dialog at all).
        expect(call['deletedByUid'], '');
      },
    );

    testWidgets(
      'a failed delete says so, keeps the sheet, and never reports success',
      (tester) async {
        final repo = _Repo(_batch([_scan('s1', first: 'Ana')]))
          ..failDelete = true;
        await pump(tester, repo);

        await tester.tap(find.byKey(const ValueKey('delete-scan-s1')));
        await tester.pumpAndSettle();
        await enterReasonAndSubmit(tester, 'Duplicate capture');

        expect(
          find.textContaining('Could not delete this sheet'),
          findsOneWidget,
        );
        expect(find.textContaining('removed from this device'), findsNothing);
        expect(find.byKey(const ValueKey('delete-scan-s1')), findsOneWidget);
      },
    );
  });

  group('canonical Examinee display (read-time overlay, never persisted)', () {
    SyncManager buildSyncManager(_FakeSyncClient client) => SyncManager(
      queue: SyncQueue(),
      client: client,
      batchRepository: LocalBatchRepository(),
      loadAnswerKeys: () async => {},
    );

    testWidgets(
      'a linked scan shows the canonical name and Temporary Examinee ID, '
      'not the scan-level tag',
      (tester) async {
        final repo = _Repo(_batch([_scan('s1', first: 'Juan')]));
        final client = _FakeSyncClient()
          ..scansByBatchId = {
            'b1': CloudScansRead.found([_cloudScan('s1', examineeId: 'ex-A')]),
          }
          ..examineesToReturn = CloudExamineesRead.found([
            _cloudExaminee('ex-A', temporaryExamineeId: 'EX-000123'),
          ]);

        await pump(tester, repo, syncManager: buildSyncManager(client));

        expect(find.text('Dela Cruz, Juan Carlos'), findsOneWidget);
        expect(find.text('Temporary Examinee ID: EX-000123'), findsOneWidget);
        // The scan's own OCR/tagged name is superseded on screen, but never
        // altered -- the underlying LocalScan.examinee is untouched (only the
        // display changes; see batch_archive_detail_screen.dart's own doc
        // comment on this).
        expect(find.text('Cruz, Juan'), findsNothing);
      },
    );

    testWidgets(
      'an unlinked scan keeps showing its own scan-level tag, with no '
      'Temporary Examinee ID',
      (tester) async {
        final repo = _Repo(_batch([_scan('s1', first: 'Juan')]));
        final client = _FakeSyncClient()
          ..scansByBatchId = {
            'b1': CloudScansRead.found([_cloudScan('s1')]),
          };

        await pump(tester, repo, syncManager: buildSyncManager(client));

        expect(find.text('Cruz, Juan'), findsOneWidget);
        expect(find.textContaining('Temporary Examinee ID'), findsNothing);
      },
    );

    testWidgets(
      'a failed canonical lookup (e.g. offline/RLS) falls back to the scan-level '
      'tag; the screen stays fully usable',
      (tester) async {
        final repo = _Repo(_batch([_scan('s1', first: 'Juan')]));
        final client = _FakeSyncClient()
          ..scansByBatchId = {
            'b1': const CloudScansRead.failed(SyncOutcome.transient('network')),
          };

        await pump(tester, repo, syncManager: buildSyncManager(client));

        expect(find.text('Cruz, Juan'), findsOneWidget);
        expect(find.textContaining('Temporary Examinee ID'), findsNothing);
        // No error of any kind reaches the screen -- the sheet's own card and
        // its Delete/Tag/Rescan actions remain present and usable.
        expect(find.byKey(const ValueKey('delete-scan-s1')), findsOneWidget);
      },
    );

    testWidgets(
      'no SyncManager configured (no cloud data plane this run) behaves exactly '
      'like today: scan-level tag only',
      (tester) async {
        final repo = _Repo(_batch([_scan('s1', first: 'Juan')]));

        await pump(
          tester,
          repo,
        ); // syncManager omitted -- same as every other test above.

        expect(find.text('Cruz, Juan'), findsOneWidget);
        expect(find.textContaining('Temporary Examinee ID'), findsNothing);
      },
    );
  });
}
