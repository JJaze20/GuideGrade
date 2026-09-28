import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:guidegrade/core/services/batch_crypto_service.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

class _FakeBatchCryptoService extends BatchCryptoService {
  Future<void> Function(Uint8List)? beforeEncrypt;

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    await beforeEncrypt?.call(plaintext);
    return Uint8List.fromList(plaintext);
  }

  @override
  Future<Uint8List> decrypt(Uint8List packed) async => Uint8List.fromList(packed);
}

const _original = OmrScanResult(
  examCode: 'AT',
  items: [OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: 'B')],
);
const _replacement = OmrScanResult(
  examCode: 'AT',
  items: [OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: 'C')],
);

LocalScanResult _result(int raw, DateTime at) => LocalScanResult(
      rawScore: raw,
      totalGraded: 72,
      totalItems: 72,
      percentage: raw / 72 * 100,
      status: 'Graded',
      scannedAt: at,
      processedByUid: 'u',
      processedByName: 'Scanner',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalBatchRepository repo;
  late _FakeBatchCryptoService crypto;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('replace_scan_test_');
    crypto = _FakeBatchCryptoService();
    repo = LocalBatchRepository(
      rootOverride: Directory('${tempDir.path}/batches'),
      crypto: crypto,
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  File file(String name, List<int> bytes) => File('${tempDir.path}/$name')..writeAsBytesSync(bytes);

  String batchDir(String batchId) => '${tempDir.path}/batches/guidegrade_batches/$batchId';

  /// A batch with one tagged, scored, fully-imaged sheet.
  Future<({LocalBatch batch, LocalScan scan})> seeded() async {
    final b = await repo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: '',
      expectedCount: 5,
      createdByUid: 'u',
      createdByName: 'Officer',
    );
    var withScan = await repo.addScan(
      batchId: b.id,
      decoded: _original,
      sourceImage: file('orig.jpg', [1, 1, 1]),
      rectifiedImage: file('orig_rect.jpg', [2, 2]),
      nameCropLastImage: file('orig_last.jpg', [3]),
      nameCropFirstImage: file('orig_first.jpg', [4]),
      result: _result(50, DateTime.utc(2026, 8, 1)),
    );
    withScan = await repo.setScanExaminee(
      batchId: b.id,
      scanId: withScan.scans.single.id,
      examinee: const ExamineeInfo(
        firstName: 'Ana',
        lastName: 'Cruz',
        middleName: 'M',
        examineeNumber: 'EX-42',
      ),
    );
    return (batch: withScan, scan: withScan.scans.single);
  }

  test('replaces photo, decode, score and crops but keeps identity, id, position and the scan date', () async {
    final s = await seeded();

    final after = await repo.replaceScan(
      batchId: s.batch.id,
      scanId: s.scan.id,
      decoded: _replacement,
      sourceImage: file('new.jpg', [9, 9, 9, 9]),
      rectifiedImage: file('new_rect.jpg', [8]),
      nameCropLastImage: file('new_last.jpg', [7]),
      nameCropFirstImage: file('new_first.jpg', [6]),
      result: _result(60, DateTime.utc(2026, 8, 1)),
    );

    final scan = after.scans.single;
    expect(scan.id, s.scan.id);
    expect(scan.capturedAt, s.scan.capturedAt, reason: 'the sheet\'s own date is never moved by a rescan');
    expect(scan.rescannedAt, isNotNull, reason: 'the replacement time is recorded separately');
    expect(scan.rescannedAt!.isAfter(s.scan.capturedAt) || scan.rescannedAt == s.scan.capturedAt, isTrue);
    expect(s.scan.rescannedAt, isNull);
    expect(scan.examinee!.displayName, s.scan.examinee!.displayName);
    expect(scan.examinee!.examineeNumber, 'EX-42');
    expect(scan.captureRevision, 1);
    expect(scan.decoded.items.single.markedChoice, 'C');
    expect(scan.result!.rawScore, 60);
    expect((await repo.resolveScanImage(after.id, scan))!.toList(), [9, 9, 9, 9]);
    expect((await repo.resolveScanNameCropLast(after.id, scan))!.toList(), [7]);

    // The date survives a reload from disk.
    final reloaded = (await repo.getBatchById(after.id))!.scans.single;
    expect(reloaded.capturedAt, s.scan.capturedAt);
    expect(reloaded.rescannedAt, scan.rescannedAt);
  });

  test('a successful replacement leaves no staged files behind', () async {
    final s = await seeded();
    await repo.replaceScan(
      batchId: s.batch.id,
      scanId: s.scan.id,
      decoded: _replacement,
      sourceImage: file('new.jpg', [9]),
      result: _result(60, DateTime.utc(2026, 8, 1)),
    );
    final leftovers = Directory('${batchDir(s.batch.id)}/images')
        .listSync()
        .where((e) => e.path.endsWith('.new'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('all new files exist separately before the manifest commit; failure preserves originals', () async {
    final s = await seeded();
    final oldNames = Directory('${batchDir(s.batch.id)}/images')
        .listSync().map((f) => f.path).toSet();
    var inspected = false;
    crypto.beforeEncrypt = (plain) async {
      if (plain.first != 123) return; // the manifest JSON, not an image
      final proposed = LocalBatch.fromJson(jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
      final next = proposed.scans.single;
      expect(next.imageFileName, isNot(s.scan.imageFileName));
      expect((await repo.resolveScanImage(s.batch.id, next))!.toList(), [9]);
      expect((await repo.resolveScanRectifiedImage(s.batch.id, next))!.toList(), [8]);
      expect((await repo.resolveScanNameCropLast(s.batch.id, next))!.toList(), [7]);
      expect((await repo.resolveScanNameCropFirst(s.batch.id, next))!.toList(), [6]);
      expect((await repo.resolveScanNameCropMiddle(s.batch.id, next))!.toList(), [5]);
      final stored = (await repo.getBatchById(s.batch.id))!.scans.single;
      expect(stored.sameStoredStateAs(s.scan), isTrue);
      expect((await repo.resolveScanImage(s.batch.id, stored))!.toList(), [1, 1, 1]);
      expect((await repo.resolveScanNameCropLast(s.batch.id, stored))!.toList(), [3]);
      inspected = true;
      throw StateError('simulated commit failure');
    };
    await expectLater(repo.replaceScan(
      batchId: s.batch.id, scanId: s.scan.id, decoded: _replacement,
      sourceImage: file('next.jpg', [9]), rectifiedImage: file('next_rect.jpg', [8]),
      nameCropLastImage: file('next_last.jpg', [7]),
      nameCropFirstImage: file('next_first.jpg', [6]),
      nameCropMiddleImage: file('next_mi.jpg', [5]),
    ), throwsStateError);
    expect(inspected, isTrue);
    expect(Directory('${batchDir(s.batch.id)}/images').listSync().map((f) => f.path).toSet(), oldNames);
    expect((await repo.getBatchById(s.batch.id))!.scans.single.sameStoredStateAs(s.scan), isTrue);
  });

  test('a replacement image write failure never publishes new answers or deletes the old photo', () async {
    final s = await seeded();
    crypto.beforeEncrypt = (plain) async {
      if (plain.length != 1 || plain.single != 8) return;
      final written = Directory('${batchDir(s.batch.id)}/images').listSync()
          .whereType<File>().singleWhere((f) => f.path.contains('_r1_'));
      // Force the second image write to fail after the source was written.
      Directory(written.path.replaceFirst(RegExp(r'\.enc$'), '_rectified.enc')).createSync();
    };
    await expectLater(repo.replaceScan(
      batchId: s.batch.id, scanId: s.scan.id, decoded: _replacement,
      sourceImage: file('next.jpg', [9]), rectifiedImage: file('next_rect.jpg', [8]),
    ), throwsA(isA<FileSystemException>()));
    final stored = (await repo.getBatchById(s.batch.id))!.scans.single;
    expect(stored.sameStoredStateAs(s.scan), isTrue);
    expect((await repo.resolveScanImage(s.batch.id, stored))!.toList(), [1, 1, 1]);
    expect(Directory('${batchDir(s.batch.id)}/images').listSync()
        .whereType<File>().where((f) => f.path.contains('_r1_')), isEmpty);
  });

  test('replacement images and manifest use real authenticated encryption and survive reopening', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final realCrypto = BatchCryptoService();
    repo = LocalBatchRepository(rootOverride: Directory('${tempDir.path}/batches'), crypto: realCrypto);
    final s = await seeded();
    final after = await repo.replaceScan(
      batchId: s.batch.id, scanId: s.scan.id, decoded: _replacement,
      sourceImage: file('new.jpg', [9, 9, 9]), rectifiedImage: file('rect.jpg', [8]),
      nameCropLastImage: file('last.jpg', [7]), nameCropFirstImage: file('first.jpg', [6]),
      nameCropMiddleImage: file('mi.jpg', [5]),
    );
    final scan = after.scans.single;
    final images = <String, List<int>>{
      scan.imageFileName: [9, 9, 9], scan.rectifiedImageFileName!: [8],
      scan.nameCropLastFileName!: [7], scan.nameCropFirstFileName!: [6],
      scan.nameCropMiddleFileName!: [5],
    };
    for (final entry in images.entries) {
      expect(entry.key.endsWith('.enc'), isTrue);
      final bytes = await File('${batchDir(after.id)}/${entry.key}').readAsBytes();
      expect(bytes, isNot(orderedEquals(entry.value)));
      expect(await realCrypto.decrypt(bytes), orderedEquals(entry.value));
      final tampered = Uint8List.fromList(bytes)..[12] ^= 1;
      await expectLater(realCrypto.decrypt(tampered), throwsA(anything));
    }
    final manifest = await File('${batchDir(after.id)}/batch.enc').readAsBytes();
    expect(jsonDecode(utf8.decode(await realCrypto.decrypt(manifest))), after.toJson());
    final reopened = LocalBatchRepository(rootOverride: Directory('${tempDir.path}/batches'));
    final loaded = (await reopened.getBatchById(after.id))!.scans.single;
    expect(loaded.sameStoredStateAs(scan), isTrue);
    expect(await reopened.resolveScanImage(after.id, loaded), orderedEquals([9, 9, 9]));
  });

  test('a crop or rectified image the new capture did not produce is cleared, not kept stale', () async {
    final s = await seeded();
    final after = await repo.replaceScan(
      batchId: s.batch.id,
      scanId: s.scan.id,
      decoded: _replacement,
      sourceImage: file('new.jpg', [9]),
      result: _result(60, DateTime.utc(2026, 8, 1)),
    );
    final scan = after.scans.single;
    expect(scan.rectifiedImageFileName, isNull);
    expect(scan.nameCropLastFileName, isNull);
    expect(File('${batchDir(after.id)}/${s.scan.rectifiedImageFileName}').existsSync(), isFalse);
    expect(File('${batchDir(after.id)}/${s.scan.nameCropLastFileName}').existsSync(), isFalse);
  });

  group('a failed save leaves the original intact', () {
    test('when the manifest cannot be written: the original photo, crops and record are unchanged', () async {
      final s = await seeded();
      final before = await repo.getBatchById(s.batch.id);
      // A directory squatting on the temp-manifest path makes the commit write fail.
      Directory('${batchDir(s.batch.id)}/batch.enc.tmp').createSync();

      await expectLater(
        repo.replaceScan(
          batchId: s.batch.id,
          scanId: s.scan.id,
          decoded: _replacement,
          sourceImage: file('new.jpg', [9, 9, 9, 9]),
          rectifiedImage: file('new_rect.jpg', [8]),
          nameCropLastImage: file('new_last.jpg', [7]),
          nameCropFirstImage: file('new_first.jpg', [6]),
          result: _result(60, DateTime.utc(2026, 8, 1)),
        ),
        throwsA(isA<FileSystemException>()),
      );
      Directory('${batchDir(s.batch.id)}/batch.enc.tmp').deleteSync();

      final after = (await repo.getBatchById(s.batch.id))!;
      final scan = after.scans.single;
      expect(after.updatedAt, before!.updatedAt);
      expect(scan.captureRevision, 0);
      expect(scan.rescannedAt, isNull);
      expect(scan.decoded.items.single.markedChoice, 'B');
      expect(scan.result!.rawScore, 50);
      // The ORIGINAL bytes — the photo the reviewer compared against — are still there.
      expect((await repo.resolveScanImage(after.id, scan))!.toList(), [1, 1, 1]);
      expect((await repo.resolveScanRectifiedImage(after.id, scan))!.toList(), [2, 2]);
      expect((await repo.resolveScanNameCropLast(after.id, scan))!.toList(), [3]);
      expect((await repo.resolveScanNameCropFirst(after.id, scan))!.toList(), [4]);
      // ...and no half-written replacement files remain.
      expect(
        Directory('${batchDir(after.id)}/images').listSync().where((e) => e.path.endsWith('.new')),
        isEmpty,
      );
    });

    test('when the replacement photo is missing: nothing is written and the original stays', () async {
      final s = await seeded();
      await expectLater(
        repo.replaceScan(
          batchId: s.batch.id,
          scanId: s.scan.id,
          decoded: _replacement,
          sourceImage: File('${tempDir.path}/does_not_exist.jpg'),
          result: _result(60, DateTime.utc(2026, 8, 1)),
        ),
        throwsA(isA<FileSystemException>()),
      );
      final scan = (await repo.getBatchById(s.batch.id))!.scans.single;
      expect(scan.captureRevision, 0);
      expect((await repo.resolveScanImage(s.batch.id, scan))!.toList(), [1, 1, 1]);
    });
  });

  group('the original changing while a comparison is open', () {
    test('a correction/tag saved meanwhile blocks the replacement and changes nothing', () async {
      final s = await seeded();
      // Someone edits the student's tag after the reviewer opened the comparison.
      await repo.setScanExaminee(
        batchId: s.batch.id,
        scanId: s.scan.id,
        examinee: const ExamineeInfo(firstName: 'Bea', lastName: 'Diaz', examineeNumber: 'EX-42'),
      );

      await expectLater(
        repo.replaceScan(
          batchId: s.batch.id,
          scanId: s.scan.id,
          decoded: _replacement,
          sourceImage: file('new.jpg', [9]),
          result: _result(60, DateTime.utc(2026, 8, 1)),
          expectedOriginal: s.scan, // what the reviewer was shown
        ),
        throwsA(isA<RescanOriginalChangedException>().having((e) => e.deleted, 'deleted', isFalse)),
      );

      final scan = (await repo.getBatchById(s.batch.id))!.scans.single;
      expect(scan.captureRevision, 0);
      expect(scan.examinee!.lastName, 'Diaz', reason: 'the other edit is kept');
      expect((await repo.resolveScanImage(s.batch.id, scan))!.toList(), [1, 1, 1]);
    });

    test('a sheet deleted meanwhile is reported as deleted, not silently re-created', () async {
      final s = await seeded();
      await repo.deleteScan(batchId: s.batch.id, scanId: s.scan.id);

      await expectLater(
        repo.replaceScan(
          batchId: s.batch.id,
          scanId: s.scan.id,
          decoded: _replacement,
          sourceImage: file('new.jpg', [9]),
          result: _result(60, DateTime.utc(2026, 8, 1)),
          expectedOriginal: s.scan,
        ),
        throwsA(isA<RescanOriginalChangedException>().having((e) => e.deleted, 'deleted', isTrue)),
      );
      expect((await repo.getBatchById(s.batch.id))!.scans, isEmpty);
    });

    test('an unchanged original passes the check and is replaced', () async {
      final s = await seeded();
      final after = await repo.replaceScan(
        batchId: s.batch.id,
        scanId: s.scan.id,
        decoded: _replacement,
        sourceImage: file('new.jpg', [9]),
        result: _result(60, DateTime.utc(2026, 8, 1)),
        expectedOriginal: s.scan,
      );
      expect(after.scans.single.captureRevision, 1);
    });
  });

  test('manual corrections stay in the history but stop applying to the new capture (established behaviour)', () async {
    final s = await seeded();
    final after = await repo.replaceScan(
      batchId: s.batch.id,
      scanId: s.scan.id,
      decoded: _replacement,
      sourceImage: file('new.jpg', [9]),
      result: _result(60, DateTime.utc(2026, 8, 1)),
    );
    expect(after.scans.single.corrections, s.scan.corrections);
    expect(after.scans.single.activeCorrections, isEmpty);
  });
}
