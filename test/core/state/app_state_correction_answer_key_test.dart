import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_crypto_service.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_manager.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/models/activity_model.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// Fix under test: a manual answer correction must never be recorded as if
/// it were scored when there is no [AnswerKey] to score it against.
/// [AppState._changeCorrection] must first guarantee (via the EXISTING
/// [AppState.readCloudAnswerKey] / [AppState.adoptAnswerKeyFromCloud] pair —
/// the same one `AnswerKeyEntryScreen`'s own "load from cloud" action uses)
/// that a key is available before it saves anything, and must throw
/// (leaving the scan/result untouched, nothing enqueued) when it genuinely
/// cannot be made available.
///
/// Uses a plain (undecorated) [LocalBatchRepository] as
/// `AppState.batchRepository` — [SyncingBatchRepository]'s own enqueue
/// behavior on a correction is already covered by
/// `syncing_batch_repository_test.dart` ("9b"/"9c"); these tests are about
/// the new answer-key gate itself, not re-proving the sync queue.
class _FakeAnswerKeySyncClient implements SyncClient {
  CloudAnswerKeyRead answerKeyToReturn = const CloudAnswerKeyRead.absent();
  int readAnswerKeyCalls = 0;

  Never _no(String label) => throw StateError('must never call $label in this test');

  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    readAnswerKeyCalls++;
    return answerKeyToReturn;
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
  Future<CloudBatchesRead> readCloudBatches() => _no('readCloudBatches');
  @override
  Future<CloudScansRead> readCloudScans(String batchId) => _no('readCloudScans');
  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) =>
      _no('downloadScanImage');
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no('deleteScan');
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
  @override
  Future<CloudBatchArchivesRead> readBatchArchives() => _no('readBatchArchives');
  @override
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason}) => _no('archiveBatch');
  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) => _no('readScanCounts');
  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) => _no('readCloudScansForExaminee');
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no('readUnlinkedScans');
}

/// Test-only crypto (the real one needs a platform channel) — same fake
/// `local_batch_repository_corrections_test.dart` uses.
class _FakeBatchCryptoService extends BatchCryptoService {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> decrypt(Uint8List packed) async => Uint8List.fromList(packed);
}

/// In-memory [LocalStorageService] — no SharedPreferences/platform channel.
class _FakeLocalStorage implements LocalStorageService {
  final List<Map<String, AnswerKey>> savedAnswerKeys = [];

  @override
  Future<void> saveAnswerKeys(Map<String, AnswerKey> answerKeys) async {
    savedAnswerKeys.add(Map.of(answerKeys));
  }

  @override
  Future<Map<String, AnswerKey>> loadAnswerKeys() async => {};

  @override
  Future<List<ActivityModel>> loadActivities() async => [];

  @override
  Future<void> saveActivities(List<ActivityModel> activities) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalBatchRepository repo;
  late _FakeAnswerKeySyncClient client;
  late _FakeLocalStorage localStorage;
  late SyncManager syncManager;
  late AppState appState;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_state_correction_answer_key_test_');
    repo = LocalBatchRepository(
      rootOverride: Directory('${tempDir.path}/repo'),
      crypto: _FakeBatchCryptoService(),
    );
    client = _FakeAnswerKeySyncClient();
    localStorage = _FakeLocalStorage();
    syncManager = SyncManager(
      queue: SyncQueue(rootOverride: Directory('${tempDir.path}/queue'), clock: () => DateTime.utc(2026)),
      client: client,
      batchRepository: repo,
      loadAnswerKeys: () async => <String, AnswerKey>{},
    );
    appState = AppState(batchRepository: repo, syncManager: syncManager, localStorage: localStorage);
  });

  tearDown(() {
    syncManager.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {/* Windows may briefly hold a handle */}
  });

  // AT: item 1 blank, item 2 wrong ('B', key 'A'), item 3 correct ('A').
  // computeExamScore's AT branch counts isCorrect across ALL items with no
  // section-name dependency, so an arbitrary section name is fine here.
  const atSection = 'Section A';
  final atKey = AnswerKey(examCode: 'AT', correctChoices: {
    AnswerKey.keyFor(atSection, 1): 'A',
    AnswerKey.keyFor(atSection, 2): 'A',
    AnswerKey.keyFor(atSection, 3): 'A',
  });
  const atDecoded = OmrScanResult(examCode: 'AT', items: [
    OmrItemResult(sectionName: atSection, itemNumber: 1, markedChoice: null), // blank
    OmrItemResult(sectionName: atSection, itemNumber: 2, markedChoice: 'B'), // wrong
    OmrItemResult(sectionName: atSection, itemNumber: 3, markedChoice: 'A'), // correct
  ]);
  // Baseline (before any correction): only item 3 correct -> rawScore 1.

  Future<LocalBatch> seedAtBatch() async {
    final b = await repo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: '',
      expectedCount: 10,
      createdByUid: 'u',
      createdByName: 'Officer',
    );
    final src = File('${tempDir.path}/src.jpg')..writeAsBytesSync(const [1, 2, 3]);
    return repo.addScan(
      batchId: b.id,
      decoded: atDecoded,
      sourceImage: src,
      result: LocalScanResult(
        rawScore: 1,
        totalGraded: 3,
        totalItems: 72,
        percentage: 1 / 72 * 100,
        status: 'Graded',
        scannedAt: DateTime.utc(2026, 1, 1),
        processedByUid: 'scanner',
        processedByName: 'Scanner',
      ),
    );
  }

  group('answer-key gate (the fix)', () {
    test('6. an already-cached key is used as-is: no cloud read, correction proceeds', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      appState.answerKeys['AT'] = atKey; // already cached locally

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 1,
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r1',
      );

      expect(client.readAnswerKeyCalls, 0, reason: 'a locally-cached key must never trigger a network read');
      expect(outcome.changed, isTrue);
      expect(outcome.scoreRecalculated, isTrue);
      expect(outcome.scan.result!.rawScore, 2);
    });

    test('2. a missing key is auto-loaded from the cloud, then the correction proceeds', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      // answerKeys['AT'] is deliberately left empty.
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: atKey.correctChoices,
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 1,
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r2',
      );

      expect(client.readAnswerKeyCalls, 1);
      expect(appState.answerKeys['AT'], isNotNull, reason: 'the loaded key is adopted for later corrections too');
      expect(outcome.changed, isTrue);
      expect(outcome.scoreRecalculated, isTrue);
      expect(outcome.scan.result!.rawScore, 2);
    });

    test('5a. missing key, no cloud row for this exam: correction is refused, nothing is saved', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      client.answerKeyToReturn = const CloudAnswerKeyRead.absent();

      await expectLater(
        appState.correctScanAnswer(
          batchId: b.id,
          scanId: scanId,
          sectionName: atSection,
          itemNumber: 1,
          value: const CorrectedAnswer.choice('A'),
          requestId: 'r3',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          AppState.answerKeyUnavailableForCorrectionMessage,
        )),
      );

      final reloaded = (await repo.getBatchById(b.id))!.scans.single;
      expect(reloaded.corrections, isEmpty, reason: 'a refused correction must record nothing');
      expect(reloaded.result!.rawScore, 1, reason: 'the original score must be left exactly as it was');
      expect(appState.answerKeys.containsKey('AT'), isFalse);
    });

    test('5b. missing key, no cloud data plane at all: correction is refused, nothing is saved', () async {
      final localOnly = AppState(batchRepository: repo); // syncManager: null
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;

      await expectLater(
        localOnly.correctScanAnswer(
          batchId: b.id,
          scanId: scanId,
          sectionName: atSection,
          itemNumber: 1,
          value: const CorrectedAnswer.choice('A'),
          requestId: 'r4',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          AppState.answerKeyUnavailableForCorrectionMessage,
        )),
      );

      final reloaded = (await repo.getBatchById(b.id))!.scans.single;
      expect(reloaded.corrections, isEmpty);
      expect(reloaded.result!.rawScore, 1);
    });

    test('a genuinely no-op request (resetting an item with no active correction) '
        'never needs the answer key at all', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      client.answerKeyToReturn = const CloudAnswerKeyRead.absent(); // would refuse if ever consulted

      final outcome = await appState.resetScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 1,
        requestId: 'r5',
      );

      expect(outcome.changed, isFalse);
      expect(client.readAnswerKeyCalls, 0, reason: 'a no-op must never attempt a cloud read');
    });
  });

  group('score recalculation (per correction direction)', () {
    test('1. BLANK -> correct answer increases the score', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      appState.answerKeys['AT'] = atKey;

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 1, // was blank
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r6',
      );

      expect(outcome.scan.result!.rawScore, 2, reason: '1 (baseline) + item 1 now correct');
      expect(outcome.scan.result!.percentage, closeTo(2 / 72 * 100, 0.0001), reason: 'AT has an official percentage');
      expect(outcome.scan.effectiveDecoded.items.firstWhere((i) => i.itemNumber == 1).markedChoice, 'A');
      expect(outcome.scan.decoded.items.firstWhere((i) => i.itemNumber == 1).markedChoice, isNull,
          reason: 'the machine-detected answer itself is never overwritten');
    });

    test('2. wrong -> correct increases the score', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      appState.answerKeys['AT'] = atKey;

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 2, // was 'B' (wrong)
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r7',
      );

      expect(outcome.scan.result!.rawScore, 2);
    });

    test('3. correct -> wrong decreases the score', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      appState.answerKeys['AT'] = atKey;

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 3, // was 'A' (correct)
        value: const CorrectedAnswer.choice('B'),
        requestId: 'r8',
      );

      expect(outcome.scan.result!.rawScore, 0);
    });

    test('4. multiple corrections all contribute to the final recalculated result', () async {
      final b = await seedAtBatch();
      final scanId = b.scans.single.id;
      appState.answerKeys['AT'] = atKey;

      final first = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 1,
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r9a',
      );
      expect(first.scan.result!.rawScore, 2);

      final second = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: scanId,
        sectionName: atSection,
        itemNumber: 2,
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r9b',
      );

      expect(second.scan.result!.rawScore, 3, reason: 'both corrections must contribute together');
      expect(second.scan.corrections, hasLength(2));
    });
  });

  group('per exam type', () {
    test('7. TAT: a correction inside Test I still applies the unchanged x2 rule; '
        'Test II/III scoring is untouched', () async {
      const key = 'A';
      final tatKey = AnswerKey(examCode: 'TAT', correctChoices: {
        AnswerKey.keyFor('Test I', 1): key,
        AnswerKey.keyFor('Test II', 1): key,
        AnswerKey.keyFor('Test III', 1): key,
      });
      const decoded = OmrScanResult(examCode: 'TAT', items: [
        OmrItemResult(sectionName: 'Test I', itemNumber: 1, markedChoice: null), // blank
        OmrItemResult(sectionName: 'Test II', itemNumber: 1, markedChoice: 'B'), // wrong
        OmrItemResult(sectionName: 'Test III', itemNumber: 1, markedChoice: 'A'), // correct
      ]);
      final b = await repo.createBatch(
        batchCode: 'B-TAT',
        examCode: 'TAT',
        examTitle: 'Teaching Aptitude',
        description: '',
        expectedCount: 10,
        createdByUid: 'u',
        createdByName: 'Officer',
      );
      final src = File('${tempDir.path}/tat.jpg')..writeAsBytesSync(const [1, 2, 3]);
      final seeded = await repo.addScan(batchId: b.id, decoded: decoded, sourceImage: src);
      appState.answerKeys['TAT'] = tatKey;

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: seeded.scans.single.id,
        sectionName: 'Test I',
        itemNumber: 1,
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r10',
      );

      final result = outcome.scan.result!;
      expect(result.tatTest1Correct, 1);
      expect(result.tatTest1Score, 2, reason: 'Test I is scored correct x 2, unchanged');
      expect(result.tatTest2Correct, 0);
      expect(result.tatTest2Score, 0, reason: 'Test II (max(0, correct-wrong)) is untouched by the Test I edit');
      expect(result.tatTest3Correct, 1);
      expect(result.tatTest3Score, 1, reason: 'Test III is untouched by the Test I edit');
      expect(result.rawScore, 3, reason: 'tatTotal = 2 (Test I) + 0 (Test II) + 1 (Test III)');
    });

    test('8. QTM: a correction changes the stored result', () async {
      final key = AnswerKey(examCode: 'QTM', correctChoices: {
        AnswerKey.keyFor('Section 1', 1): 'A',
      });
      const decoded = OmrScanResult(examCode: 'QTM', items: [
        OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: null), // blank
      ]);
      final b = await repo.createBatch(
        batchCode: 'B-QTM',
        examCode: 'QTM',
        examTitle: 'Quantitative Math Test',
        description: '',
        expectedCount: 10,
        createdByUid: 'u',
        createdByName: 'Officer',
      );
      final src = File('${tempDir.path}/qtm.jpg')..writeAsBytesSync(const [1, 2, 3]);
      final seeded = await repo.addScan(batchId: b.id, decoded: decoded, sourceImage: src);
      appState.answerKeys['QTM'] = key;

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: seeded.scans.single.id,
        sectionName: 'Section 1',
        itemNumber: 1,
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r11',
      );

      expect(outcome.scan.result!.rawScore, 1);
      expect(outcome.scan.result!.totalGraded, 1);
      expect(outcome.scan.result!.status, 'Graded');
    });

    test('9. AT: a correction changes the stored result (rawScore and the official percentage)', () async {
      final b = await seedAtBatch();
      appState.answerKeys['AT'] = atKey;

      final outcome = await appState.correctScanAnswer(
        batchId: b.id,
        scanId: b.scans.single.id,
        sectionName: atSection,
        itemNumber: 1,
        value: const CorrectedAnswer.choice('A'),
        requestId: 'r12',
      );

      expect(outcome.scan.result!.rawScore, 2);
      expect(outcome.scan.result!.percentage, closeTo(2 / 72 * 100, 0.0001));
      expect(outcome.scan.result!.status, 'Graded');
    });
  });
}
