import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_manager.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/features/exam/screens/answer_key_entry_screen.dart';
import 'package:guidegrade/models/activity_model.dart';
import 'package:guidegrade/models/answer_key.dart';

/// Regression coverage for a real bug found during the system audit:
/// AnswerKeyEntryScreen's sync-status chip could go stale after Save,
/// because AppState._onSyncStateChanged only propagated SyncManager's own
/// notifyListeners() onward to AppState's listeners when a batch had just
/// been confirmed archived -- which an answer-key-only push never does.
///
/// Unlike answer_key_entry_screen_test.dart (which fakes AppState entirely,
/// overriding answerKeySyncStatusFor to a fixed field, and so never
/// exercises the real SyncManager -> AppState notification bridge), these
/// tests use the REAL [AppState] wired to a spied [SyncManager] -- the same
/// pattern test/core/state/app_state_sync_test.dart already uses -- so the
/// fix is proven against the actual production wiring, not a stand-in.
class _SpySyncManager extends SyncManager {
  _SpySyncManager({
    required super.queue,
    required super.client,
    required super.batchRepository,
    required super.loadAnswerKeys,
  });

  /// Simulates SyncManager's own private `_notify()` -- called internally
  /// on every real job-state transition (job started, job settled). Tests
  /// use this instead of running the real network/processing loop.
  void fireStateChanged() => notifyListeners();

  @override
  Future<void> start() async {}
  @override
  void pause() {}
  @override
  Future<void> processQueue() async {}
  @override
  Future<void> wake() async {}
}

class _ThrowingSyncClient implements SyncClient {
  Never _no() => throw StateError('no network in this test');
  @override
  noSuchMethod(Invocation invocation) => _no();
}

class _FakeLocalStorage implements LocalStorageService {
  final saved = <Map<String, AnswerKey>>[];
  @override
  Future<void> saveAnswerKeys(Map<String, AnswerKey> answerKeys) async =>
      saved.add(Map.of(answerKeys));
  @override
  Future<Map<String, AnswerKey>> loadAnswerKeys() async =>
      saved.isEmpty ? {} : Map.of(saved.last);
  @override
  Future<List<ActivityModel>> loadActivities() async => [];
  @override
  Future<void> saveActivities(List<ActivityModel> activities) async {}
}

void main() {
  late Directory tempDir;
  late _SpySyncManager spy;
  late AppState appState;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ak_sync_refresh_test_');
    final repo = LocalBatchRepository(rootOverride: Directory('${tempDir.path}/repo'));
    spy = _SpySyncManager(
      queue: SyncQueue(
        rootOverride: Directory('${tempDir.path}/queue'),
        clock: () => DateTime.utc(2026),
      ),
      client: _ThrowingSyncClient(),
      batchRepository: repo,
      loadAnswerKeys: () async => <String, AnswerKey>{},
    );
    appState = AppState(
      batchRepository: repo,
      syncManager: spy,
      localStorage: _FakeLocalStorage(),
    );
  });

  tearDown(() {
    spy.dispose();
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {/* Windows may briefly hold a handle */}
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppStateScope(notifier: appState, child: const AnswerKeyEntryScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('1. the screen initially shows the correct local/sync status',
      (tester) async {
    // No answer key saved yet for the active exam code -> "Not set".
    await pumpScreen(tester);
    expect(find.text('Not set'), findsOneWidget);
  });

  testWidgets(
      '2. after Save, a sync-state change (job settles) refreshes the screen '
      'without any other trigger', (tester) async {
    // Real file I/O (SyncQueue/LocalStorageService both write to disk) must
    // run via tester.runAsync -- awaiting it directly inside a testWidgets
    // body, before any pump has ever run, can stall forever under
    // AutomatedTestWidgetsFlutterBinding's fake-async zone. This mirrors
    // how every other real-I/O call below is wrapped too.
    await tester.runAsync(() => appState.setAnswerKey(
        AnswerKey(examCode: 'AT', correctChoices: const {'Test I|1': 'A'})));
    await pumpScreen(tester);

    // A PUSH_ANSWER_KEY job is pending right after Save.
    expect(find.text('Syncing'), findsOneWidget);

    // Simulate the job succeeding, exactly as SyncManager._applyOutcome
    // does on a successful push: remove the job, then notify -- the same
    // _notify() call a real push would make.
    final job = spy.queue.jobs.single;
    await tester.runAsync(() => spy.queue.remove(job.id));
    spy.fireStateChanged();
    await tester.pump();

    expect(find.text('Synced'), findsOneWidget);
    expect(find.text('Syncing'), findsNothing);
  });

  testWidgets(
      '3. an answer-key-only sync updates the status even though no batch '
      'was archived', (tester) async {
    // No batch exists at all in this test's repository -- proves the
    // refresh does not depend on BatchArchiveCoordinator finding anything
    // to archive; only an answer-key job changes here.
    final batches = await tester.runAsync(() => appState.batchRepository.getBatches());
    expect(batches, isEmpty);

    await tester.runAsync(() => appState.setAnswerKey(
        AnswerKey(examCode: 'AT', correctChoices: const {'Test I|1': 'A'})));
    await pumpScreen(tester);
    expect(find.text('Syncing'), findsOneWidget);

    final job = spy.queue.jobs.single;
    await tester.runAsync(() => spy.queue.remove(job.id));
    spy.fireStateChanged();
    await tester.pump();

    expect(find.text('Synced'), findsOneWidget);
  });

  testWidgets(
      '4. a job parked as blockedConflict after Save still shows the '
      'conflict banner -- conflict handling is unchanged', (tester) async {
    await tester.runAsync(() => appState.setAnswerKey(
        AnswerKey(examCode: 'AT', correctChoices: const {'Test I|1': 'A'})));
    await pumpScreen(tester);
    expect(find.byKey(const Key('answerKeyConflictBanner')), findsNothing);

    final job = spy.queue.jobs.single;
    await tester.runAsync(() => spy.queue.update(job.copyWith(
          status: SyncJobStatus.blockedConflict,
          lastErrorCode: 'answer_key_changed',
        )));
    spy.fireStateChanged();
    await tester.pump();

    expect(find.text('Conflict'), findsOneWidget);
    expect(find.byKey(const Key('answerKeyConflictBanner')), findsOneWidget);
  });
}
