import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_crypto_service.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

class _FakeBatchCryptoService extends BatchCryptoService {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> decrypt(Uint8List packed) async => Uint8List.fromList(packed);
}

OmrScanResult _decoded({bool flagged = false}) => OmrScanResult(
      examCode: 'AT',
      items: [
        const OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: 'B'),
        OmrItemResult(sectionName: 'Section 1', itemNumber: 2, markedChoice: null, isAmbiguous: flagged),
      ],
    );

LocalScanResult _result(int raw) => LocalScanResult(
      rawScore: raw,
      totalGraded: 72,
      totalItems: 72,
      percentage: raw / 72 * 100,
      status: 'Graded',
      scannedAt: DateTime.utc(2026, 1, 1),
      processedByUid: 'scanner',
      processedByName: 'Scanner',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalBatchRepository repo;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_batch_delete_scan_test_');
    repo = LocalBatchRepository(
      rootOverride: Directory('${tempDir.path}/batches'),
      crypto: _FakeBatchCryptoService(),
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<LocalBatch> newBatch() => repo.createBatch(
        batchCode: 'B-1',
        examCode: 'AT',
        examTitle: 'Admission Test',
        description: '',
        expectedCount: 10,
        createdByUid: 'u',
        createdByName: 'Officer',
      );

  Future<LocalBatch> scan(String batchId, {required int score, bool flagged = false}) {
    final src = File('${tempDir.path}/src_$score.jpg')..writeAsBytesSync(const [1, 2, 3]);
    final rect = File('${tempDir.path}/rect_$score.jpg')..writeAsBytesSync(const [4, 5]);
    final crop = File('${tempDir.path}/crop_$score.jpg')..writeAsBytesSync(const [6]);
    return repo.addScan(
      batchId: batchId,
      decoded: _decoded(flagged: flagged),
      sourceImage: src,
      rectifiedImage: rect,
      nameCropLastImage: crop,
      result: _result(score),
    );
  }

  File imageFile(String batchId, String relPath) =>
      File('${tempDir.path}/batches/guidegrade_batches/$batchId/$relPath');

  test('removes only the chosen sheet and its files; counts and average follow', () async {
    final b = await newBatch();
    await scan(b.id, score: 60);
    await scan(b.id, score: 30);
    final three = await scan(b.id, score: 45);
    final doomed = three.scans[1];
    final kept = [three.scans[0], three.scans[2]];
    expect(three.scanCount, 3);

    final after = await repo.deleteScan(batchId: b.id, scanId: doomed.id);

    expect(after.scans.map((s) => s.id), kept.map((s) => s.id).toList());
    expect(after.scanCount, 2);
    expect(after.gradedCount, 2);
    expect(after.averagePercentage, closeTo((60 / 72 * 100 + 45 / 72 * 100) / 2, 1e-9));
    expect(imageFile(b.id, doomed.imageFileName).existsSync(), isFalse);
    expect(imageFile(b.id, doomed.rectifiedImageFileName!).existsSync(), isFalse);
    expect(imageFile(b.id, doomed.nameCropLastFileName!).existsSync(), isFalse);
    for (final s in kept) {
      expect(imageFile(b.id, s.imageFileName).existsSync(), isTrue, reason: 'other sheets keep their files');
      expect(imageFile(b.id, s.rectifiedImageFileName!).existsSync(), isTrue);
    }

    // What is on disk after a reload is the same thing that was returned.
    final reloaded = (await repo.getBatchById(b.id))!;
    expect(reloaded.scans.map((s) => s.id), after.scans.map((s) => s.id));
    expect(reloaded.updatedAt, after.updatedAt);
  });

  test('deleting a duplicate leaves its twin untouched', () async {
    final b = await newBatch();
    await scan(b.id, score: 50);
    final two = await scan(b.id, score: 50); // same answers scanned twice
    expect(two.likelyDuplicateScans, isNotEmpty);

    final after = await repo.deleteScan(batchId: b.id, scanId: two.scans[1].id);

    expect(after.scans.single.id, two.scans[0].id);
    expect(after.likelyDuplicateScans, isEmpty);
    expect(imageFile(b.id, two.scans[0].imageFileName).existsSync(), isTrue);
  });

  test('an Archived batch stays Archived, keeps its other scans, and its revision advances', () async {
    final b = await newBatch();
    await scan(b.id, score: 40);
    final two = await scan(b.id, score: 41);
    expect(await repo.confirmBatchArchived(b.id, two.updatedAt), isTrue);
    final archived = (await repo.getBatchById(b.id))!;
    expect(archived.isArchived, isTrue);

    final after = await repo.deleteScan(batchId: b.id, scanId: archived.scans.first.id);

    expect(after.isArchived, isTrue);
    expect(after.scanCount, 1);
    expect(after.updatedAt.isAfter(archived.updatedAt), isTrue, reason: 'a new revision, so it syncs');
    expect((await repo.getBatchById(b.id))!.isArchived, isTrue);
  });

  test('deleting the only flagged sheet clears the batch\'s needs-review state', () async {
    final b = await newBatch();
    await scan(b.id, score: 40, flagged: true);
    final two = await scan(b.id, score: 41);
    expect(two.needsReviewCount, 1);

    final after = await repo.deleteScan(batchId: b.id, scanId: two.scans.first.id);

    expect(after.needsReview, isFalse);
    expect((await repo.getBatchById(b.id))!.needsReviewCount, 0);
  });

  test('a missing sheet or batch fails loudly and changes nothing', () async {
    final b = await newBatch();
    final one = await scan(b.id, score: 40);

    await expectLater(repo.deleteScan(batchId: b.id, scanId: 'nope'), throwsStateError);
    await expectLater(repo.deleteScan(batchId: 'nope', scanId: 's'), throwsStateError);

    final unchanged = (await repo.getBatchById(b.id))!;
    expect(unchanged.updatedAt, one.updatedAt);
    expect(unchanged.scanCount, 1);
    expect(imageFile(b.id, one.scans.single.imageFileName).existsSync(), isTrue);
  });

  test('if the manifest cannot be written nothing is deleted and the error surfaces', () async {
    final b = await newBatch();
    final one = await scan(b.id, score: 40);
    final manifestDir = Directory('${tempDir.path}/batches/guidegrade_batches/${b.id}');
    // A directory squatting on the temp-manifest path makes the atomic write fail.
    Directory('${manifestDir.path}/batch.enc.tmp').createSync();

    await expectLater(
      repo.deleteScan(batchId: b.id, scanId: one.scans.single.id),
      throwsA(isA<FileSystemException>()),
    );

    Directory('${manifestDir.path}/batch.enc.tmp').deleteSync();
    final after = (await repo.getBatchById(b.id))!;
    expect(after.scanCount, 1, reason: 'the sheet is still there');
    expect(imageFile(b.id, one.scans.single.imageFileName).existsSync(), isTrue);
  });

  test('two deletes in quick succession both land (per-batch serialization)', () async {
    final b = await newBatch();
    await scan(b.id, score: 10);
    await scan(b.id, score: 20);
    final three = await scan(b.id, score: 30);

    await Future.wait([
      repo.deleteScan(batchId: b.id, scanId: three.scans[0].id),
      repo.deleteScan(batchId: b.id, scanId: three.scans[2].id),
    ]);

    final after = (await repo.getBatchById(b.id))!;
    expect(after.scans.map((s) => s.id), [three.scans[1].id]);
  });
}
