import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_manager.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/models/answer_key.dart';

/// A [SyncClient] the reconnect path must never reach — every op throws.
class _NeverSyncClient implements SyncClient {
  Never _no() => throw StateError('reconnect sync must not call the network');

  @override
  Future<SyncOutcome> pushBatch(String batchId) => _no();
  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId,
          {Map<String, String> meta = const {}}) =>
      _no();
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _no();
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) => _no();
  @override
  Future<SyncOutcome> pushAnswerKey(String examCode,
          {Map<String, String> meta = const {}}) =>
      _no();
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) => _no();
  @override
  Future<CloudBatchesRead> readCloudBatches() => _no();
  @override
  Future<CloudScansRead> readCloudScans(String batchId) => _no();
  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) =>
      _no();
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

/// Spy over the real [SyncManager]: counts `syncNow` / `wake`, lets a test
/// toggle `isActive`, and runs no real drain.
class _SpySyncManager extends SyncManager {
  _SpySyncManager({
    required super.queue,
    required super.client,
    required super.batchRepository,
    required super.loadAnswerKeys,
  });

  bool activeOverride = true;
  int syncNowCalls = 0;
  int wakeCalls = 0;

  @override
  bool get isActive => activeOverride;
  @override
  Future<void> syncNow() async => syncNowCalls++;
  @override
  Future<void> wake() async => wakeCalls++;
  @override
  Future<void> start() async {}
  @override
  void pause() {}
}

void main() {
  late Directory tempDir;

  // Short enough that the tests don't really wait, non-zero so the one-shot
  // Timer path (and its cancellation) is genuinely exercised.
  const debounce = Duration(milliseconds: 20);
  const pastDebounce = Duration(milliseconds: 120);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_state_reconnect_test_');
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {/* Windows may briefly hold a handle */}
  });

  _SpySyncManager makeSpy() => _SpySyncManager(
        queue: SyncQueue(
          rootOverride: Directory('${tempDir.path}/queue'),
          clock: () => DateTime.utc(2026),
        ),
        client: _NeverSyncClient(),
        batchRepository:
            LocalBatchRepository(rootOverride: Directory('${tempDir.path}/repo')),
        loadAnswerKeys: () async => <String, AnswerKey>{},
      );

  StreamController<List<ConnectivityResult>> makeController() {
    final controller = StreamController<List<ConnectivityResult>>();
    // Fire-and-forget: `close()` on a controller that was never listened to
    // (the null-SyncManager case) returns a future that never completes, so
    // it must not be awaited here.
    addTearDown(() => unawaited(controller.close()));
    return controller;
  }

  AppState wire(
    StreamController<List<ConnectivityResult>> controller, {
    _SpySyncManager? spy,
  }) {
    final appState = AppState(
      batchRepository:
          LocalBatchRepository(rootOverride: Directory('${tempDir.path}/repo')),
      syncManager: spy,
      connectivityStream: controller.stream,
      reconnectSyncDebounce: debounce,
    );
    addTearDown(appState.dispose);
    if (spy != null) addTearDown(spy.dispose);
    return appState;
  }

  test('A. a disconnected -> connected transition triggers syncNow() once, '
      'after the debounce', () async {
    final controller = makeController();
    final spy = makeSpy();
    wire(controller, spy: spy);

    controller.add(const [ConnectivityResult.none]); // go offline
    await pumpEventQueue();
    expect(spy.syncNowCalls, 0);

    controller.add(const [ConnectivityResult.wifi]); // back online -> edge
    await pumpEventQueue();
    expect(spy.syncNowCalls, 0, reason: 'debounced, not fired yet');

    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 1);
    expect(spy.wakeCalls, 0, reason: 'reconnect uses syncNow(), not wake()');
  });

  test('B. connected -> connected (e.g. wifi -> mobile) does not trigger sync',
      () async {
    final controller = makeController();
    final spy = makeSpy();
    wire(controller, spy: spy);

    // Establish and drain one offline -> online edge.
    controller.add(const [ConnectivityResult.none]);
    await pumpEventQueue();
    controller.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 1);

    // Now only connected -> connected changes.
    controller.add(const [ConnectivityResult.mobile]);
    controller.add(const [ConnectivityResult.wifi, ConnectivityResult.vpn]);
    controller.add(const [ConnectivityResult.ethernet]);
    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 1, reason: 'no new offline -> online edge');
  });

  test('C. disconnected -> disconnected never triggers sync', () async {
    final controller = makeController();
    final spy = makeSpy();
    wire(controller, spy: spy);

    controller.add(const [ConnectivityResult.none]);
    controller.add(const [ConnectivityResult.none]);
    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 0);
  });

  test('D. a null SyncManager: no connectivity subscription is created and '
      'nothing crashes', () async {
    final controller = makeController();
    final appState = wire(controller); // no spy -> syncManager == null

    expect(controller.hasListener, isFalse,
        reason: 'no SyncManager -> nothing to drain -> no subscription');
    expect(() => appState.dispose(), returnsNormally);
  });

  test('E. an inactive (paused) SyncManager is not asked to sync on reconnect',
      () async {
    final controller = makeController();
    final spy = makeSpy()..activeOverride = false; // paused
    wire(controller, spy: spy);

    controller.add(const [ConnectivityResult.none]);
    await pumpEventQueue();
    controller.add(const [ConnectivityResult.wifi]); // edge, but paused
    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 0, reason: 'isActive == false');

    // Becomes active later; a fresh reconnect edge then does fire.
    spy.activeOverride = true;
    controller.add(const [ConnectivityResult.none]);
    await pumpEventQueue();
    controller.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 1);
  });

  test('F. dispose() cancels the pending debounce timer and the subscription',
      () async {
    final controller = makeController();
    final spy = makeSpy();
    final appState = wire(controller, spy: spy);

    controller.add(const [ConnectivityResult.none]);
    await pumpEventQueue();
    controller.add(const [ConnectivityResult.wifi]); // arms the debounce timer
    await pumpEventQueue();

    appState.dispose(); // before the timer elapses

    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 0, reason: 'timer was cancelled by dispose()');

    // A post-dispose connectivity event must not reach the disposed state.
    controller.add(const [ConnectivityResult.none]);
    controller.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(pastDebounce);
    expect(spy.syncNowCalls, 0);
  });
}
