import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/sync/cloud_restore_service.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/features/archive/screens/cloud_archive_screen.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';

/// Nothing here should ever be called -- [_SpyCloudRestoreService]
/// overrides [CloudRestoreService.restoreAll] entirely.
class _NeverSyncClient implements SyncClient {
  Never _no() => throw StateError('must not be called');
  @override
  Future<SyncOutcome> pushBatch(String batchId) => _no();
  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId, {Map<String, String> meta = const {}}) => _no();
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _no();
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) => _no();
  @override
  Future<SyncOutcome> pushAnswerKey(String examCode, {Map<String, String> meta = const {}}) => _no();
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) => _no();
  @override
  Future<CloudBatchesRead> readCloudBatches() => _no();
  @override
  Future<CloudScansRead> readCloudScans(String batchId) => _no();
  @override
  Future<CloudImageRead> downloadScanImage({required String batchId, required String scanId, required bool rectified}) => _no();
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no();
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no();
  @override
  Future<CloudExamineesRead> readCloudExaminees() => _no();
  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no();
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no();
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) => _no();
  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) =>
      _no();
  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) =>
      _no();

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() =>
      _no();

  @override
  Future<SyncOutcome> archiveBatch({
    required String batchId,
    String? reason,
  }) =>
      _no();

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) =>
      _no();

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) => _no();
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no();
}

class _FakeBatchRepository implements BatchRepository {
  @override
  Future<List<LocalBatch>> getBatches() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records how many times [restoreAll] was called and returns a
/// configurable [RestoreSummary] -- no real client/repository/queue I/O.
class _SpyCloudRestoreService extends CloudRestoreService {
  _SpyCloudRestoreService({required Directory tempDir})
      : super(
          client: _NeverSyncClient(),
          repository: _FakeBatchRepository(),
          syncQueue: SyncQueue(rootOverride: tempDir),
          loadAnswerKeys: () async => const <String, AnswerKey>{},
        );

  int restoreAllCalls = 0;
  RestoreSummary summaryToReturn = const RestoreSummary(
    cloudBatchesFound: 3,
    batchesRestored: 2,
    batchesUpdated: 1,
    scansRestored: 5,
    batchesSkippedPendingDelete: 0,
  );

  @override
  Future<RestoreSummary> restoreAll() async {
    restoreAllCalls++;
    return summaryToReturn;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cloud_archive_restore_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester, AppState appState) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: const CloudArchiveScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no restore button when cloudRestoreService is not configured', (tester) async {
    final appState = AppState(batchRepository: _FakeBatchRepository());
    await pumpScreen(tester, appState);

    expect(find.byTooltip('Restore from Cloud'), findsNothing);
  });

  testWidgets('tapping the button, then confirming, calls restoreAll and shows the summary', (tester) async {
    final spy = _SpyCloudRestoreService(tempDir: tempDir);
    final appState = AppState(
      batchRepository: _FakeBatchRepository(),
      cloudRestoreService: spy,
    );
    await pumpScreen(tester, appState);

    expect(find.byTooltip('Restore from Cloud'), findsOneWidget);

    await tester.tap(find.byTooltip('Restore from Cloud'));
    await tester.pumpAndSettle();

    expect(find.text('Restore from Cloud?'), findsOneWidget);
    expect(spy.restoreAllCalls, 0);

    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(spy.restoreAllCalls, 1);
    expect(find.textContaining('3 cloud batches found'), findsOneWidget);
    expect(find.textContaining('2 new, 1 updated, 5 scans restored'), findsOneWidget);
  });

  testWidgets('cancelling the confirmation dialog never calls restoreAll', (tester) async {
    final spy = _SpyCloudRestoreService(tempDir: tempDir);
    final appState = AppState(
      batchRepository: _FakeBatchRepository(),
      cloudRestoreService: spy,
    );
    await pumpScreen(tester, appState);

    await tester.tap(find.byTooltip('Restore from Cloud'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(spy.restoreAllCalls, 0);
  });
}
