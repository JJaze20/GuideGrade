import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_manager.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/models/activity_model.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';
import 'package:guidegrade/models/user.dart';

/// Spy over the real [SyncManager]: counts start/pause/processQueue/wake and
/// never runs any of them.
class _SpySyncManager extends SyncManager {
  _SpySyncManager({
    required super.queue,
    required super.client,
    required super.batchRepository,
    required super.loadAnswerKeys,
  });

  int startCalls = 0;
  int pauseCalls = 0;
  int processQueueCalls = 0;
  int wakeCalls = 0;

  @override
  Future<void> start() async => startCalls++;
  @override
  void pause() => pauseCalls++;
  @override
  Future<void> processQueue() async => processQueueCalls++;
  @override
  Future<void> wake() async => wakeCalls++;
}

/// A [SyncQueue] whose `enqueue` always fails (disk-full simulation).
class _ThrowingQueue extends SyncQueue {
  _ThrowingQueue(Directory root) : super(rootOverride: root);

  @override
  Future<SyncJob?> enqueue(SyncJob job) async =>
      throw const FileSystemException('disk full');
}

/// In-memory [LocalStorageService] — no SharedPreferences, no platform
/// channel. Records answer-key saves and can be told to throw.
class _FakeLocalStorage implements LocalStorageService {
  final List<Map<String, AnswerKey>> savedAnswerKeys = [];
  Object? throwOnSaveAnswerKeys;

  @override
  Future<void> saveAnswerKeys(Map<String, AnswerKey> answerKeys) async {
    final err = throwOnSaveAnswerKeys;
    if (err != null) throw err;
    savedAnswerKeys.add(Map.of(answerKeys));
  }

  @override
  Future<Map<String, AnswerKey>> loadAnswerKeys() async =>
      savedAnswerKeys.isEmpty ? {} : Map.of(savedAnswerKeys.last);

  @override
  Future<List<ActivityModel>> loadActivities() async => [];

  @override
  Future<void> saveActivities(List<ActivityModel> activities) async {}
}

class _ThrowingSyncClient implements SyncClient {
  Future<SyncOutcome> _no() async =>
      throw StateError('no network in AppState sync-wiring tests');

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
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async =>
      throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<CloudBatchesRead> readCloudBatches() async =>
      throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<CloudScansRead> readCloudScans(String batchId) async =>
      throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) async =>
      throw StateError('no network in AppState sync-wiring tests');

  @override
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) async => throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no();
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no();
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no();
  @override
  Future<CloudExamineesRead> readCloudExaminees() async =>
      throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async =>
      throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async =>
      throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) async =>
      throw StateError('no network in AppState sync-wiring tests');
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
  }) async =>
      throw StateError('no network in AppState sync-wiring tests');

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async =>
      throw StateError('no network in AppState sync-wiring tests');

  @override
  Future<SyncOutcome> archiveBatch({
    required String batchId,
    String? reason,
  }) async =>
      throw StateError('no network in AppState sync-wiring tests');

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) async =>
      throw StateError('no network in AppState sync-wiring tests');

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) async =>
      throw StateError('no network in AppState sync-wiring tests');
  @override
  Future<CloudScansRead> readUnlinkedScans() async =>
      throw StateError('no network in AppState sync-wiring tests');
}

UserModel _user({required String role, bool active = true}) => UserModel(
      userId: 'u1',
      email: 'x@example.com',
      displayName: 'User',
      role: role,
      isActive: active,
      createdAt: DateTime.utc(2026),
    );

LocalBatch _batch() => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: '',
      expectedCount: 10,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  late Directory tempDir;
  late _SpySyncManager spy;
  late LocalBatchRepository repo;
  late _FakeLocalStorage fakeStorage;
  late AppState appState;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_state_sync_test_');
    repo = LocalBatchRepository(rootOverride: Directory('${tempDir.path}/repo'));
    fakeStorage = _FakeLocalStorage();
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
      localStorage: fakeStorage,
    );
  });

  tearDown(() {
    spy.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {/* Windows may briefly hold a handle */}
  });

  test('1. an active Guidance Council user starts sync', () {
    appState.setCurrentUser(_user(role: 'guidance_council'));
    expect(spy.startCalls, 1);
    expect(spy.pauseCalls, 0);
  });

  test('2. a System Administrator keeps sync paused', () {
    appState.setCurrentUser(_user(role: 'system_admin'));
    expect(spy.startCalls, 0);
    expect(spy.pauseCalls, 1);
  });

  test('2b. an inactive Guidance Council user does not start sync', () {
    appState.setCurrentUser(_user(role: 'guidance_council', active: false));
    expect(spy.startCalls, 0);
    expect(spy.pauseCalls, 1);
  });

  test('3. a null user (logout) pauses sync', () {
    appState.setCurrentUser(null);
    expect(spy.startCalls, 0);
    expect(spy.pauseCalls, 1);
  });

  test('4. a user transition pauses the old session and starts a new '
      'guidance session', () {
    appState.setCurrentUser(_user(role: 'guidance_council')); // start
    appState.setCurrentUser(_user(role: 'system_admin')); // pause
    appState.setCurrentUser(_user(role: 'guidance_council')); // start
    expect(spy.startCalls, 2);
    expect(spy.pauseCalls, 1);

    appState.setCurrentUser(null); // pause
    expect(spy.startCalls, 2);
    expect(spy.pauseCalls, 2);
  });

  test('5. no non-login AppState method drives the sync manager, and the '
      'batchRepository seam is untouched', () async {
    expect(identical(appState.batchRepository, repo), isTrue);

    appState.startScanSession(_batch());
    appState.setActiveExamCode('QTM');
    appState.resetScanProgress();
    appState.clearScanSession();
    final rescanned = await appState.finishRescan(
      expectedOriginal: LocalScan(
        id: 's',
        imageFileName: 'images/s.enc',
        capturedAt: DateTime.utc(2026),
        decoded: const OmrScanResult(examCode: 'AT', items: []),
      ),
      identityVerified: true,
    );

    expect(rescanned, isFalse); // guard intact: no active session
    expect(spy.startCalls, 0);
    expect(spy.pauseCalls, 0);
    expect(spy.processQueueCalls, 0);
  });

  test('6. sync wiring is a harmless no-op when there is no SyncManager', () {
    final localOnly = AppState(batchRepository: repo); // syncManager: null
    localOnly.setCurrentUser(_user(role: 'guidance_council'));
    localOnly.setCurrentUser(null);
    expect(localOnly.syncManager, isNull);
  });

  // --- answer-key sync wiring (Phase 10A) ------------------------------

  group('setAnswerKey → PUSH_ANSWER_KEY', () {
    AnswerKey key([String code = 'AT']) => AnswerKey(
          examCode: code,
          correctChoices: const {'Test I|1': 'A', 'Test I|2': 'C'},
        );

    List<SyncJob> answerKeyJobs(SyncQueue q) =>
        q.jobs.where((j) => j.type == SyncJobType.pushAnswerKey).toList();

    test('7. a successful local save enqueues exactly one PUSH_ANSWER_KEY '
        'keyed by exam code, with empty meta', () async {
      await appState.setAnswerKey(key('AT'));

      final jobs = answerKeyJobs(spy.queue);
      expect(jobs, hasLength(1));
      expect(jobs.single.entityId, 'AT'); // identity = examCode
      expect(jobs.single.batchId, isNull);
      expect(jobs.single.scanId, isNull);
      expect(jobs.single.meta, isEmpty); // meta = {}
      expect(jobs.single.dedupeKey, 'PUSH_ANSWER_KEY:AT');
    });

    test('8. a successful local save wakes the sync manager exactly once',
        () async {
      await appState.setAnswerKey(key('AT'));

      expect(spy.wakeCalls, 1);
      expect(spy.startCalls, 0);
      expect(spy.processQueueCalls, 0);
    });

    test('9. a local-save failure propagates and enqueues / wakes nothing',
        () async {
      fakeStorage.throwOnSaveAnswerKeys =
          const FileSystemException('prefs unavailable');

      await expectLater(
        appState.setAnswerKey(key('AT')),
        throwsA(isA<FileSystemException>()),
      );

      expect(spy.queue.jobs, isEmpty);
      expect(spy.wakeCalls, 0);
    });

    test('10. a queue-enqueue failure preserves the local save and does not '
        'wake or throw', () async {
      final throwingSpy = _SpySyncManager(
        queue: _ThrowingQueue(Directory('${tempDir.path}/throwing')),
        client: _ThrowingSyncClient(),
        batchRepository: repo,
        loadAnswerKeys: () async => <String, AnswerKey>{},
      );
      final app = AppState(
        batchRepository: repo,
        syncManager: throwingSpy,
        localStorage: fakeStorage,
      );

      await app.setAnswerKey(key('AT')); // must NOT throw

      expect(app.answerKeys.containsKey('AT'), isTrue); // in-memory kept
      expect(fakeStorage.savedAnswerKeys.last.containsKey('AT'),
          isTrue); // persisted
      expect(throwingSpy.wakeCalls, 0); // enqueue failed -> no wake
      throwingSpy.dispose();
    });

    test('11. setAnswerKey makes no Supabase / network / client call',
        () async {
      // _ThrowingSyncClient throws on every method; reaching it fails the test.
      await appState.setAnswerKey(key('AT'));

      expect(spy.processQueueCalls, 0);
      expect(spy.startCalls, 0);
    });

    test('12. exam code is the job entity identifier', () async {
      await appState.setAnswerKey(key('QTM'));

      final job = answerKeyJobs(spy.queue).single;
      expect(job.entityId, 'QTM');
      expect(job.dedupeKey, 'PUSH_ANSWER_KEY:QTM');
    });

    test('13. the local flat answer-key JSON is unchanged (correctChoices '
        'round-trips verbatim)', () async {
      final k = AnswerKey(
        examCode: 'AT',
        correctChoices: const {
          'Test I|1': 'A',
          'Test I|2': 'C',
          'Test II|3': 'B',
        },
      );

      await appState.setAnswerKey(k);

      const expected = {'Test I|1': 'A', 'Test I|2': 'C', 'Test II|3': 'B'};
      expect(appState.answerKeys['AT']!.correctChoices, expected);
      expect(fakeStorage.savedAnswerKeys.last['AT']!.correctChoices, expected);
      expect(fakeStorage.savedAnswerKeys.last['AT']!.toJson(), {
        'examCode': 'AT',
        'correctChoices': expected,
      });
    });

    test('14. with no SyncManager the local save still succeeds and nothing '
        'is enqueued', () async {
      final localOnly =
          AppState(batchRepository: repo, localStorage: fakeStorage);

      await localOnly.setAnswerKey(key('AT'));

      expect(localOnly.answerKeys.containsKey('AT'), isTrue);
      expect(fakeStorage.savedAnswerKeys.last.containsKey('AT'), isTrue);
      expect(localOnly.syncManager, isNull);
    });
  });

  // --- answer-key conflict resolution core (Phase 10E-1) --------------

  group('answer-key conflict resolution', () {
    const cloudAnswers = {'Test I|1': 'B', 'Test I|2': 'D'};

    List<SyncJob> answerKeyJobs(SyncQueue q) =>
        q.jobs.where((j) => j.type == SyncJobType.pushAnswerKey).toList();

    /// Enqueue a `PUSH_ANSWER_KEY` for [code] and park it as
    /// `blockedConflict`, mimicking a `conflict('answer_key_changed')`.
    Future<SyncJob> blockedJob([String code = 'AT']) async {
      await spy.queue.enqueue(SyncJob.create(
        type: SyncJobType.pushAnswerKey,
        entityId: code,
      ));
      final job = answerKeyJobs(spy.queue).single;
      await spy.queue.update(job.copyWith(
        status: SyncJobStatus.blockedConflict,
        lastErrorCode: 'answer_key_changed',
      ));
      return answerKeyJobs(spy.queue).single;
    }

    test('15. answerKeySyncStatusFor reflects the queue: notConfigured / '
        'upToDate / pending / conflict', () async {
      // No SyncManager -> notConfigured.
      final localOnly =
          AppState(batchRepository: repo, localStorage: fakeStorage);
      expect(localOnly.answerKeySyncStatusFor('AT'),
          AnswerKeySyncStatus.notConfigured);

      // No jobs -> upToDate.
      expect(
          appState.answerKeySyncStatusFor('AT'), AnswerKeySyncStatus.upToDate);

      // A plain pending job -> pending.
      await spy.queue.enqueue(SyncJob.create(
        type: SyncJobType.pushAnswerKey,
        entityId: 'AT',
      ));
      expect(
          appState.answerKeySyncStatusFor('AT'), AnswerKeySyncStatus.pending);

      // Parked as blockedConflict -> conflict (wins over pending).
      final job = answerKeyJobs(spy.queue).single;
      await spy.queue.update(job.copyWith(
        status: SyncJobStatus.blockedConflict,
        lastErrorCode: 'answer_key_changed',
      ));
      expect(
          appState.answerKeySyncStatusFor('AT'), AnswerKeySyncStatus.conflict);
    });

    test('16. adoptAnswerKeyFromCloud overwrites the local key, sets the '
        'baseline to the cloud version/timestamp, removes the blocked job, '
        'and enqueues nothing', () async {
      await blockedJob('AT');
      final updatedAt = DateTime.utc(2026, 5, 5, 9, 30);

      await appState.adoptAnswerKeyFromCloud(
        'AT',
        cloudVersion: 7,
        answers: cloudAnswers,
        updatedAt: updatedAt,
      );

      // Local key is now the cloud copy, persisted.
      expect(appState.answerKeys['AT']!.correctChoices, cloudAnswers);
      expect(fakeStorage.savedAnswerKeys.last['AT']!.correctChoices,
          cloudAnswers);

      // Baseline adopted from the cloud row.
      expect(spy.queue.state.answerKeyLastPushedVersion('AT'), 7);
      expect(spy.queue.state.answerKeyLastPushedUpdatedAt('AT'), updatedAt);

      // Blocked job gone; nothing new enqueued; no push attempted.
      expect(answerKeyJobs(spy.queue), isEmpty);
      expect(spy.wakeCalls, 0);
      expect(spy.processQueueCalls, 0);
      expect(appState.answerKeySyncStatusFor('AT'),
          AnswerKeySyncStatus.upToDate);
    });

    test('17. prepareAnswerKeyForcePush drops the blocked job, enqueues one '
        'fresh pending force job, wakes once, and leaves the local key '
        'untouched', () async {
      final blocked = await blockedJob('AT');
      appState.answerKeys['AT'] = AnswerKey(
        examCode: 'AT',
        correctChoices: const {'Test I|1': 'A'},
      );

      await appState.prepareAnswerKeyForcePush('AT', 5);

      final jobs = answerKeyJobs(spy.queue);
      expect(jobs, hasLength(1));
      final job = jobs.single;
      expect(job.id, isNot(blocked.id)); // a brand-new job
      expect(job.status, SyncJobStatus.pending);
      expect(job.attempts, 0);
      expect(job.entityId, 'AT');

      expect(spy.wakeCalls, 1);
      // Local key is unchanged by a force *prepare*.
      expect(appState.answerKeys['AT']!.correctChoices, {'Test I|1': 'A'});
    });

    test('18. the force job meta carries ONLY force + expectedCloudVersion '
        '(no PII)', () async {
      await blockedJob('QTM');

      await appState.prepareAnswerKeyForcePush('QTM', 42);

      final job = answerKeyJobs(spy.queue).single;
      expect(job.meta, {'force': 'true', 'expectedCloudVersion': '42'});
      expect(job.meta.keys.toSet(), {'force', 'expectedCloudVersion'});
      expect(job.batchId, isNull);
      expect(job.scanId, isNull);
    });
  });
}
